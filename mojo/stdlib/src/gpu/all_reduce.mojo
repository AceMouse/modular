# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Multi-GPU allreduce implementation for efficient tensor reduction across GPUs.

This module provides an optimized implementation of allreduce operations across multiple GPUs,
supporting both peer-to-peer (P2P) and non-P2P communication patterns. The implementation
automatically selects between two approaches based on hardware capabilities:

1. P2P-based implementation (when P2P access is available):
   - Uses direct GPU-to-GPU memory access for better performance
   - Implements both single-stage and two-stage algorithms:
     - Single-stage for latency-bound transfers (small tensors)
     - Two-stage (reduce-scatter + all-gather) for bandwidth-bound transfers (large tensors)
   - Optimized for NVLink bandwidth utilization
   - Uses vectorized memory access and higher precision accumulation

2. Non-P2P fallback implementation:
   - Copies data through host memory when direct GPU access isn't possible
   - Simple but functional approach for systems without P2P support

The implementation is tuned for common GPU architectures (A100, H100) and includes
parameters that can be adjusted for different hardware configurations.

Limitations:
- Number of elements must be a multiple of SIMD width
- Maximum of 8 GPUs supported
- All input/output buffers must have identical shapes
"""

from collections import InlineArray
from math import ceildiv
from memory import stack_allocation
from memory.pointer import _GPUAddressSpace
from sys import simdwidthof

from buffer import NDBuffer
from gpu import (
    barrier,
    block_dim,
    block_idx,
    grid_dim,
    thread_idx,
    MAX_THREADS_PER_BLOCK_METADATA,
)
from gpu.host import DeviceBuffer, DeviceContext
from gpu.intrinsics import (
    load_acquire,
    load_volatile,
    store_release,
    store_volatile,
)
from utils.index import StaticTuple
from utils.numerics import get_accum_type


alias elementwise_epilogue_type = fn[
    input_index: Int, type: DType, rank: Int, width: Int, *, alignment: Int
] (IndexList[rank], SIMD[type, size=width]) capturing -> None


# NOTE: the above result was true on A100, but on H100 we need more SMs to
# sature the NVLink in the bandwidth-bound regime.
# TODO(bduke): Dispatch based on device after completing parameter sweep.

alias MAX_NUM_BLOCKS_DEFAULT = 128
"""Maximum number of thread blocks to use for reduction kernels.

This value has been empirically optimized through grid search across different GPU architectures.
While this value is optimal for A100 GPUs, H100 GPUs may benefit from more blocks to fully
saturate NVLink bandwidth.
"""

alias MAX_GPUS = 8
"""Maximum number of GPUs supported in the allreduce implementation.

This constant sets the upper bound for the number of GPUS supported in this algorithm.
"""

# Counter may overflow, but it's fine since unsigned int overflow is
# well-defined behavior.
alias _flag_t = DType.uint32


@value
@register_passable("trivial")
struct Signal[max_num_blocks: Int]:
    """A synchronization primitive for coordinating GPU thread blocks across multiple devices.

    This struct provides counter-based synchronization between thread blocks on different GPUs.
    It maintains two sets of counters:
    1. self_counter: Used by blocks on the current GPU to signal their progress
    2. peer_counter: Used to track progress of blocks on other GPUs

    Parameters:
        max_num_blocks: The maximum number of thread blocks that will synchronize.

    Note:
        The counters use unsigned integers that may overflow, but this is safe since
        unsigned integer overflow has well-defined behavior.
    """

    var self_counter: StaticTuple[
        StaticTuple[Scalar[_flag_t], MAX_GPUS], Self.max_num_blocks
    ]
    """
    A 2D array of counters with shape (max_num_blocks, MAX_GPUS).
    Each counter tracks the progress of a specific thread block on the current GPU.
    Thread blocks increment their corresponding counter to signal completion of a phase,
    allowing other GPUs to detect when synchronization points are reached.
    The counters use atomic operations to ensure proper synchronization across devices.
    """

    var peer_counter: StaticTuple[
        StaticTuple[
            StaticTuple[Scalar[_flag_t], MAX_GPUS], Self.max_num_blocks
        ],
        2,
    ]
    """
    A 3D array of counters with shape (2, max_num_blocks, MAX_GPUS).
    Contains two sets of counters to handle two synchronization points safely.
    The dual counter design prevents race conditions where a peer block arrives
    at the second sync point before the current block passes the first sync point.
    """


fn _naive_reduce_kernel[
    type: DType
](
    dst_buf: UnsafePointer[Scalar[type]],
    src_buf: UnsafePointer[Scalar[type]],
    num_elements: Int,
):
    """
    A simple reduction kernel that adds source buffer values to destination buffer.

    Parameters:
        type: DType - The data type of the values being reduced.

    Args:
        dst_buf: Destination buffer to accumulate results.
        src_buf: Source buffer containing values to add.
        num_elements: Number of elements to process.

    Each thread handles multiple elements with striding for coalesced memory access.
    """
    var tid = global_idx.x
    var stride = grid_dim.x * block_dim.x

    # Each thread handles multiple elements with striding
    for i in range(tid, num_elements, stride):
        dst_buf[i] += src_buf[i]


fn can_enable_p2p(ctxs: List[DeviceContext]) raises -> Bool:
    """
    If peer-to-peer access is supported, enables it between all GPU pairs.

    Args:
        ctxs: List of device contexts representing different GPUs.

    Returns:
        True if P2P access is possible between all GPU pairs, False otherwise.
    """
    for i in range(len(ctxs)):
        for j in range(i + 1, len(ctxs)):
            if not ctxs[i].can_access(ctxs[j]):
                return False
            try:
                ctxs[i].enable_peer_access(ctxs[j])
                ctxs[j].enable_peer_access(ctxs[i])
            except e:
                # Temporary workaround to skip
                # `CUDA_ERROR_PEER_ACCESS_ALREADY_ENABLED`
                continue

    return True


@always_inline
fn _all_reduce_naive[
    type: DType,
    rank: Int,
    ngpus: Int, //,
    max_num_blocks: Int,
](
    ctxs: List[DeviceContext],
    list_of_in_bufs: InlineArray[NDBuffer[type, rank], ngpus],
    list_of_out_bufs: InlineArray[NDBuffer[type, rank], ngpus],
) raises:
    """
    Performs allreduce across GPUs without using peer-to-peer access.

    Parameters:
        type: The data type of tensor elements.
        rank: Number of dimensions in input tensors.
        ngpus: Number of GPUs participating in allreduce.
        max_num_blocks: Maximum number of thread blocks to launch.

    Args:
        ctxs: List of device contexts for participating GPUs.
        list_of_in_bufs: Input buffers from each GPU.
        list_of_out_bufs: Output buffers for each GPU.

    This implementation copies all data to each GPU and performs local reduction.
    Used as fallback when P2P access is not available.
    """
    var num_elements = list_of_in_bufs[0].num_elements()

    var device_buffer_list = List[DeviceBuffer[type]](capacity=ngpus)
    # Assemble input buffer structures from all devices
    for i in range(ngpus):
        device_buffer_list.append(
            DeviceBuffer(
                ctxs[i], list_of_in_bufs[i].data, num_elements, owning=False
            )
        )

    # Iterate over each device (GPU)
    for device_idx in range(ngpus):
        var curr_ctx = ctxs[device_idx]
        var curr_out_buf = list_of_out_bufs[device_idx]

        # Create temporary buffers on the current device to store data from other devices
        var tmp_buffer_list = List[DeviceBuffer[type]](capacity=ngpus)
        for i in range(ngpus):
            # Skip allocating a copy for the current device
            if i != device_idx:
                var tmp_buffer = curr_ctx.enqueue_create_buffer[type](
                    num_elements
                )
                tmp_buffer_list.append(tmp_buffer)

                # Copy data from other devices to the temporary buffer on the current device
                curr_ctx.enqueue_copy(
                    tmp_buffer,
                    device_buffer_list[i],  # Source buffer from GPU i
                )

        # Launch reduction kernels
        alias BLOCK_SIZE = 256
        var grid_size = min(max_num_blocks, ceildiv(num_elements, BLOCK_SIZE))

        src_index = 0
        for i in range(ngpus):
            var src_buffer_ptr: UnsafePointer[Scalar[type]]
            if i == device_idx:
                src_buffer_ptr = device_buffer_list[i].unsafe_ptr()
            else:
                src_buffer_ptr = tmp_buffer_list[src_index].unsafe_ptr()
                src_index += 1

            if i == 0:
                # Initialize the output buffer with the first buffer
                curr_ctx.enqueue_copy(
                    curr_out_buf.data, src_buffer_ptr, num_elements
                )
            else:
                curr_ctx.enqueue_function[_naive_reduce_kernel[type]](
                    curr_out_buf.data,
                    src_buffer_ptr,
                    num_elements,
                    grid_dim=grid_size,
                    block_dim=BLOCK_SIZE,
                )


@always_inline
fn _multi_gpu_barrier[
    max_num_blocks: Int, //,
    ngpus: Int,
    is_start: Bool,
    need_fence: Bool = False,
](
    rank_sigs: InlineArray[
        UnsafePointer[Signal[max_num_blocks]], MAX_GPUS
    ],  # all-to-all table of Signals
    self_sg: UnsafePointer[Signal[max_num_blocks]],
    my_rank: Int,
):
    """
    Implements a barrier synchronization across multiple GPUs to ensure all GPU blocks
    reach a certain point before proceeding.

    Parameters:
        max_num_blocks: Maximum number of thread blocks to launch.
        ngpus: Number of GPUs participating in barrier.
        is_start: Whether this is the start barrier.
        need_fence: Whether memory fence is needed.
            If True, uses release/acquire semantics.
            If False, uses volatile memory operations for faster communication.

    Args:
        rank_sigs: Signal pointers for all GPUs.
        self_sg: Signal pointer for current GPU.
        my_rank: Current GPU rank.

    Uses atomic counters and memory fences to ensure all GPUs reach barrier before proceeding.
    Implementation ported from VLLM's _multi_gpu_barrier in
    https://github.com/vllm-project/vllm/blob/main/csrc/custom_all_reduce.cuh#L169-L198
    """

    @parameter
    if not is_start:
        barrier()

    constrained[
        not (need_fence and is_start), "Start barrier should not need fence"
    ]()
    var bid = block_idx.x

    if thread_idx.x < ngpus:
        # NOTE: (MOCO-1431) the use of pointer arithmetic here is a temporary workaround
        # to avoid functional issues that arise with increased register pressure when
        # dealing with static tuples
        var my_gpu = thread_idx.x
        # Each thread increments its own counter
        # Technically we only need one counter, but we use
        # multiple per block to eliminate the need to share the counter via smem.
        var internal_counter_ptr = self_sg.bitcast[
            Scalar[_flag_t]
        ]() + bid * MAX_GPUS + my_gpu
        var val = internal_counter_ptr[] + 1
        internal_counter_ptr[] = val

        # Get the number of flags in self_counter to skip over it
        alias peer_counter_offset = sizeof[
            StaticTuple[StaticTuple[Scalar[_flag_t], MAX_GPUS], max_num_blocks]
        ]() // sizeof[_flag_t]()

        # this line should compute &rank_sigs[my_gpu]->peer_counter[val % 2][bid][my_rank]
        var peer_counter_ptr = (
            rank_sigs[my_gpu].bitcast[Scalar[_flag_t]]()
            + peer_counter_offset
            + (val % 2) * (max_num_blocks * MAX_GPUS)
            + bid * MAX_GPUS
            + my_rank
        )
        # this line should compute &self_sg->peer_counter[val % 2][bid][my_gpu]
        var self_counter_ptr = (
            self_sg.bitcast[Scalar[_flag_t]]()
            + peer_counter_offset
            + (val % 2) * (max_num_blocks * MAX_GPUS)
            + bid * MAX_GPUS
            + my_gpu
        )

        # Write the expected counter value to peer and wait for correct value from
        # peer.
        @parameter
        if need_fence:
            # broadcast the value to all peers that I reached the barrier
            store_release(peer_counter_ptr, val)
            while load_acquire(self_counter_ptr) != val:
                continue
        else:
            # TODO: (KERN-1207) get rid of these inlined assembly intrinsics to use ptr.store/load[volatile=True]
            # currently using store_volatile/load_volatile because they're much faster
            store_volatile(peer_counter_ptr, val)
            while load_volatile(self_counter_ptr) != val:
                continue

    @parameter
    if is_start or need_fence:
        barrier()


@__llvm_metadata(
    MAX_THREADS_PER_BLOCK_METADATA=StaticTuple[Int32, 1](BLOCK_SIZE)
)
fn _allreduce_2stage_kernel[
    type: DType,
    rank: Int,
    ngpus: Int,
    max_num_blocks: Int,
    my_rank: Int,
    *,
    BLOCK_SIZE: Int,
    outputs_lambda: elementwise_epilogue_type,
](
    result: NDBuffer[type, rank],
    src_ptrs: InlineArray[UnsafePointer[Scalar[type]], ngpus],
    rank_sigs: InlineArray[UnsafePointer[Signal[max_num_blocks]], MAX_GPUS],
    num_elements: Int,
):
    """2-stage allreduce algorithm for bandwidth-bound transfers.

    This kernel implements a reduce-scatter + all-gather algorithm that is
    bandwidth optimal.

    Parameters:
        type: Data type of tensor elements.
        rank: Number of dimensions in tensors.
            Note that `rank` is overloaded here to mean both device id and
            number of dimensions.
        ngpus: Number of GPUs participating.
        max_num_blocks: Maximum number of thread blocks to launch.
        my_rank: Current GPU rank.
        BLOCK_SIZE: Number of threads per block.
        outputs_lambda: An elementwise output lambda function.

    Args:
        result: Output buffer for reduced values.
        src_ptrs: Input buffers from all GPUs.
        rank_sigs: Signal pointers for synchronization.
            IMPORTANT: the Signal pointers have trailing buffers for
            communication, which must be at least `ngpus * sizeof(payload)`.
            | -- sizeof(Signal) -- | ------ a few MB ----- |
        num_elements: Number of elements to reduce.
    """
    alias accum_type = get_accum_type[type]()
    alias simd_width = simdwidthof[type]()
    alias alignment = alignof[SIMD[type, simd_width]]()

    # --- Thread Indexing and Vector Setup ---
    var global_tid = global_idx.x

    # Stride equals total threads in grid dimension for grid-strided loops.
    var stride = grid_dim.x * BLOCK_SIZE
    var my_sig: UnsafePointer[Signal[max_num_blocks]] = rank_sigs[my_rank]

    # --- Data Partitioning ---
    # Block cyclic distribution using 128-bit packed vectors.
    # Divide workload into `ngpus` partitions with last rank handling
    # remainder.
    # NOTE: `part`, `start`, and `end` are in units of SIMD widths.
    var num_simd_vectors = num_elements // simd_width
    var part = num_simd_vectors // ngpus
    var start = my_rank * part
    var end = num_simd_vectors if my_rank == ngpus - 1 else start + part
    var largest_part = part + (num_simd_vectors % ngpus)

    # --- Memory Pointer Configuration ---
    # Round-robin access pattern to balance NVLink traffic across GPUs.
    var ptrs = stack_allocation[
        ngpus,
        UnsafePointer[Scalar[type]],
        address_space = _GPUAddressSpace.LOCAL,
    ]()
    var tmps = stack_allocation[
        ngpus,
        UnsafePointer[Scalar[type]],
        address_space = _GPUAddressSpace.LOCAL,
    ]()

    @parameter
    for i in range(ngpus):
        # Round-robin pattern, for 8 GPUs for example:
        # Rank 0 accesses: 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7.
        # Rank 1 accesses: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 0.
        var target = (my_rank + i) % ngpus
        ptrs[i] = src_ptrs[target]

        # Skip Signal header.
        tmps[i] = (rank_sigs[target] + 1).bitcast[Scalar[type]]()

    # Current rank's output buffer.
    var tmp_out = tmps[0]

    # --- Stage 1: Reduce-Scatter Phase ---
    # Uses two-phase synchronization protocol with release-acquire semantics:
    # 1. Initial barrier establishes happens-before relationship.
    # 2. Memory fence ensures visibility of partial reductions.
    _multi_gpu_barrier[ngpus, is_start=True](rank_sigs, my_sig, my_rank)

    # Grid-strided loop with vectorized reduction:
    # - Each thread processes partition elements using 128-bit accesses.
    # - Accumulates in higher precision (float32) for numerical stability.
    for idx in range(start + global_tid, end, stride):
        # float32 accumulator for numerical stability.
        var elem_idx = idx * simd_width
        var accum = ptrs[0].load[width=simd_width, alignment=alignment](
            elem_idx
        ).cast[accum_type]()

        @parameter
        for gpu_idx in range(1, ngpus):
            accum += (
                ptrs[gpu_idx]
                .load[width=simd_width, alignment=alignment](elem_idx)
                .cast[accum_type]()
            )

        # Convert back to the element index before storing.
        var elem_start = start * simd_width
        tmp_out.store[alignment=alignment](
            elem_idx - elem_start, accum.cast[type]()
        )

    # Second barrier with memory ordering guarantees.
    _multi_gpu_barrier[ngpus, is_start=False, need_fence=True](
        rank_sigs, my_sig, my_rank
    )

    # --- Stage 2: All-Gather Phase ---
    # Maintains thread index consistency to satisfy memory model:
    # The same tid guarantees visibility of prior writes.
    # So if thread `idx` computes the sum of `start + idx` in the first stage,
    # then thread `idx` also gathers `start + idx` from all ranks.
    for idx in range(global_tid, largest_part, stride):
        var elem_idx = idx * simd_width

        @parameter
        for gpu_idx in range(ngpus):
            var gather_from_rank = (my_rank + gpu_idx) % ngpus

            # Handle edge cases for non-uniform partitions, where
            # the final rank may have larger partition size.
            if (gather_from_rank == (ngpus - 1)) or idx < part:
                var dst_idx = (gather_from_rank * part) + idx
                var elem_dst_idx = dst_idx * simd_width

                outputs_lambda[
                    input_index=my_rank, width=simd_width, alignment=alignment
                ](
                    result.get_nd_index(elem_dst_idx),
                    tmps[gpu_idx].load[width=simd_width, alignment=alignment](
                        elem_idx
                    ),
                )


@__llvm_metadata(
    MAX_THREADS_PER_BLOCK_METADATA=StaticTuple[Int32, 1](BLOCK_SIZE)
)
fn _allreduce_1stage_kernel[
    type: DType,
    rank: Int,
    ngpus: Int,
    max_num_blocks: Int,
    my_rank: Int,
    *,
    BLOCK_SIZE: Int,
    outputs_lambda: elementwise_epilogue_type,
](
    result: NDBuffer[type, rank],
    src_ptrs: InlineArray[UnsafePointer[Scalar[type]], ngpus],
    rank_sigs: InlineArray[UnsafePointer[Signal[max_num_blocks]], MAX_GPUS],
    num_elements: Int,
):
    """
    Kernel implementing allreduce using peer-to-peer access between GPUs.

    Parameters:
        type: Data type of tensor elements.
        rank: Number of dimensions in tensors.
        ngpus: Number of GPUs participating.
        max_num_blocks: Maximum number of thread blocks to launch.
        my_rank: Current GPU rank
        BLOCK_SIZE: Number of threads per block.
        outputs_lambda: An elementwise output lambda function.

    Args:
        result: Output buffer for reduced values
        src_ptrs: Input buffers from all GPUs
        rank_sigs: Signal pointers for synchronization
        num_elements: Number of elements to reduce

    Uses P2P access to directly read from other GPU buffers and perform reduction.
    Synchronizes using _multi_gpu_barrier before and after reduction.
    """
    alias accum_type = get_accum_type[type]()
    alias simd_width = simdwidthof[type]()
    alias alignment = alignof[SIMD[type, simd_width]]()

    var global_tid = global_idx.x
    var stride = grid_dim.x * BLOCK_SIZE
    var my_sig: UnsafePointer[Signal[max_num_blocks]] = rank_sigs[my_rank]
    var num_simd_vectors = num_elements // simd_width

    # Round-robin access pattern to balance NVLink traffic across GPUs.
    var ptrs = stack_allocation[
        ngpus,
        UnsafePointer[Scalar[type]],
        address_space = _GPUAddressSpace.LOCAL,
    ]()

    @parameter
    for i in range(ngpus):
        # Round-robin pattern, for 8 GPUs for example:
        # Rank 0 accesses: 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7.
        # Rank 1 accesses: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 0.
        var target = (my_rank + i) % ngpus
        ptrs[i] = src_ptrs[target]

    _multi_gpu_barrier[ngpus, is_start=True](rank_sigs, my_sig, my_rank)

    # Vectorized grid-strided loop with SIMD loads.
    for idx in range(global_tid, num_simd_vectors, stride):
        var elem_idx = idx * simd_width
        var accum = ptrs[0].load[width=simd_width, alignment=alignment](
            elem_idx
        ).cast[accum_type]()

        @parameter
        for _id in range(1, ngpus):
            accum += (
                ptrs[_id]
                .load[width=simd_width, alignment=alignment](elem_idx)
                .cast[accum_type]()
            )

        outputs_lambda[
            input_index=my_rank, width=simd_width, alignment=alignment
        ](
            result.get_nd_index(elem_idx),
            rebind[SIMD[type, simd_width]](accum.cast[type]()),
        )

    _multi_gpu_barrier[ngpus, is_start=False](rank_sigs, my_sig, my_rank)


@always_inline
fn _all_reduce_p2p[
    type: DType,
    rank: Int,
    ngpus: Int,
    max_num_blocks: Int, //,
    outputs_lambda: OptionalReg[elementwise_epilogue_type] = None,
](
    ctxs: List[DeviceContext],
    list_of_in_bufs: InlineArray[NDBuffer[type, rank], ngpus],
    list_of_out_bufs: InlineArray[NDBuffer[type, rank], ngpus],
    rank_sigs: InlineArray[UnsafePointer[Signal[max_num_blocks]], MAX_GPUS],
) raises:
    """
    Performs allreduce using peer-to-peer access between GPUs.

    Parameters:
        type: Data type of tensor elements.
        rank: Number of dimensions in tensors.
        ngpus: Number of GPUs participating.
        max_num_blocks: Maximum number of thread blocks to launch.
        outputs_lambda: An optional output elementwise lambda.

    Args:
        ctxs: List of device contexts for participating GPUs
        list_of_in_bufs: Input buffers from each GPU
        list_of_out_bufs: Output buffers for each GPU
        rank_sigs: Signal pointers for synchronization

    Launches P2P reduction kernel on each GPU to perform direct reduction.
    """
    var num_elements = list_of_in_bufs[0].num_elements()
    if num_elements % simdwidthof[type]() != 0:
        raise Error(
            "non SIMD-width multiple number of elements unsupported by"
            " allreduce"
        )

    # Pass a stack-allocated array of pointers to the device kernel, which
    # doesn't need dynamic tensor spec info from NDBuffer.
    var list_of_in_ptrs = InlineArray[UnsafePointer[Scalar[type]], ngpus](
        UnsafePointer[Scalar[type]]()
    )

    @parameter
    for i in range(ngpus):
        list_of_in_ptrs[i] = list_of_in_bufs[i].data

    @parameter
    for i in range(ngpus):
        var curr_ctx = ctxs[i]
        var curr_out_buf = list_of_out_bufs[i]

        alias BLOCK_SIZE = 512
        var grid_size = min(max_num_blocks, ceildiv(num_elements, BLOCK_SIZE))

        alias rank_4_byte_threshold = 512 * 1024
        alias rank_8_byte_threshold = 256 * 1024
        var payload_bytecount = list_of_in_bufs[0].bytecount()

        alias lambdas = outputs_lambda.value()
        if (rank <= 4 and (payload_bytecount < rank_4_byte_threshold)) or (
            rank <= 8 and (payload_bytecount < rank_8_byte_threshold)
        ):
            # Use the 1-stage allreduce when transfer is latency bound.
            curr_ctx.enqueue_function[
                _allreduce_1stage_kernel[
                    type,
                    rank,
                    ngpus,
                    max_num_blocks,
                    my_rank=i,
                    BLOCK_SIZE=BLOCK_SIZE,
                    outputs_lambda=lambdas,
                ]
            ](
                curr_out_buf,
                list_of_in_ptrs,
                rank_sigs,
                num_elements,
                grid_dim=grid_size,
                block_dim=BLOCK_SIZE,
            )
        else:
            # Otherwise, use 2-stage allreduce for the bandwidth bound regime.
            curr_ctx.enqueue_function[
                _allreduce_2stage_kernel[
                    type,
                    rank,
                    ngpus,
                    max_num_blocks,
                    my_rank=i,
                    BLOCK_SIZE=BLOCK_SIZE,
                    outputs_lambda=lambdas,
                ]
            ](
                curr_out_buf,
                list_of_in_ptrs,
                rank_sigs,
                num_elements,
                grid_dim=grid_size,
                block_dim=BLOCK_SIZE,
            )


fn all_reduce[
    type: DType,
    rank: Int,
    ngpus: Int,
    max_num_blocks: Int, //,
    outputs_lambda: OptionalReg[elementwise_epilogue_type] = None,
](
    ctxs: List[DeviceContext],
    input_buffers: InlineArray[NDBuffer[type, rank], ngpus],
    output_buffers: InlineArray[NDBuffer[type, rank], ngpus],
    rank_sigs: InlineArray[UnsafePointer[Signal[max_num_blocks]], MAX_GPUS],
) raises:
    """Performs an allreduce operation across multiple GPUs.

    This function serves as the main entry point for performing allreduce operations
    across multiple GPUs. It automatically selects between two implementations:
    - A peer-to-peer (P2P) based implementation when P2P access is possible between GPUs
    - A naive implementation as fallback when P2P access is not available

    The allreduce operation combines values from all GPUs using element-wise addition
    and distributes the result back to all GPUs.

    Parameters:
        type: The data type of the tensor elements (e.g. DType.float32).
        rank: The number of dimensions in the input/output tensors.
        ngpus: The number of GPUs participating in the allreduce.
        max_num_blocks: The maximum number of thread blocks to launch per GPU.
        outputs_lambda: An optional output elementwise lambda.

    Args:
        ctxs: List of device contexts for each participating GPU.
        input_buffers: Array of input tensors from each GPU, one per GPU.
        output_buffers: Array of output tensors for each GPU to store results.
        rank_sigs: Array of Signal pointers used for cross-GPU synchronization.

    Note:
        - Input and output buffers must have identical shapes across all GPUs.
        - The number of elements must be identical across all input/output buffers.
        - Performance is typically better with P2P access enabled between GPUs.
    """
    var can_p2p = can_enable_p2p(ctxs)

    if not can_p2p:

        @parameter
        if outputs_lambda:
            raise Error(
                "elementwise lambda fusion unsupported by allreduce naive path"
            )

        return _all_reduce_naive[max_num_blocks](
            ctxs, input_buffers, output_buffers
        )
    else:
        return _all_reduce_p2p[outputs_lambda=outputs_lambda](
            ctxs, input_buffers, output_buffers, rank_sigs
        )
