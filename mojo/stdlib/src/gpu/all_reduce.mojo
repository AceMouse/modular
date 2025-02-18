# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from math import ceildiv
from memory import stack_allocation
from memory.pointer import _GPUAddressSpace
from sys import simdwidthof

from buffer import Buffer, NDBuffer
from gpu import barrier, block_dim, block_idx, grid_dim, thread_idx
from gpu.host import DeviceBuffer, DeviceContext
from gpu.intrinsics import (
    load_acquire,
    load_volatile,
    store_release,
    store_volatile,
)
from utils.index import StaticTuple
from utils.numerics import get_accum_type

# Comments from the original implementation:
# Block and grid default configs are results after careful grid search. Using
# 36 blocks give the best or close to the best runtime on the devices I
# tried: A100, A10, A30, T4, V100. You'll notice that NCCL kernels also only
# take a small amount of SMs. Not quite sure the underlying reason, but my
# guess is that too many SMs will cause contention on NVLink bus.
alias MAX_BLOCK = 36
alias MAX_GPUS = 8
# Counter may overflow, but it's fine since unsigned int overflow is
# well-defined behavior.
alias flag_t = DType.uint32


@value
@register_passable("trivial")
struct Signal:
    # Shape of self_counter is (MAX_BLOCK, MAX_GPUS)
    var self_counter: StaticTuple[
        StaticTuple[Scalar[flag_t], MAX_GPUS], MAX_BLOCK
    ]
    # Shape of peer_counter is (2, MAX_BLOCK, MAX_GPUS)
    # Two sets of peer counters are needed for two syncs. The reason is that
    # it's possible for peer GPU block to arrive at the second sync point while
    # the current GPU block hasn't passed the first sync point. Thus, peer GPU
    # may write counter + 1 while current GPU is busy waiting for counter. We use
    # alternating counter array to avoid this possibility.
    var peer_counter: StaticTuple[
        StaticTuple[StaticTuple[Scalar[flag_t], MAX_GPUS], MAX_BLOCK], 2
    ]


fn naive_reduce_kernel[
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

    Arguments:
        dst_buf: Destination buffer to accumulate results
        src_buf: Source buffer containing values to add
        num_elements: Number of elements to process

    Each thread handles multiple elements with striding for coalesced memory access.
    """
    var tid = global_idx.x
    var stride = grid_dim.x * block_dim.x

    # Each thread handles multiple elements with striding
    for i in range(tid, num_elements, stride):
        dst_buf[i] += src_buf[i]


fn can_enable_p2p(ctxs: List[DeviceContext]) raises -> Bool:
    """
    Checks and enables peer-to-peer access between all GPU pairs.

    Arguments:
        ctxs: List of device contexts representing different GPUs.

    Returns:
        Bool indicating if P2P access is possible between all GPU pairs

    Enables peer access between all GPU pairs that support it.
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
fn all_reduce_naive[
    type: DType,
    rank: Int,
    ngpus: Int, //,
](
    ctxs: List[DeviceContext],
    list_of_in_bufs: StaticTuple[NDBuffer[type, rank], ngpus],
    list_of_out_bufs: StaticTuple[NDBuffer[type, rank], ngpus],
) raises:
    """
    Performs all-reduce across GPUs without using peer-to-peer access.

    Parameters:
        type: DType - The data type of tensor elements.
        rank: Int - Number of dimensions in input tensors.
        ngpus: Int - Number of GPUs participating in all-reduce.

    Arguments:
        ctxs: List of device contexts for participating GPUs
        list_of_in_bufs: Input buffers from each GPU
        list_of_out_bufs: Output buffers for each GPU

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
                curr_ctx.enqueue_copy_device_to_device(
                    tmp_buffer,
                    device_buffer_list[i],  # Source buffer from GPU i
                )

        # Launch reduction kernels
        alias BLOCK_SIZE = 256
        var grid_size = min(MAX_BLOCK, ceildiv(num_elements, BLOCK_SIZE))

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
                curr_ctx.enqueue_copy_device_to_device(
                    curr_out_buf.data, src_buffer_ptr, num_elements
                )
            else:
                curr_ctx.enqueue_function[naive_reduce_kernel[type]](
                    curr_out_buf.data,
                    src_buffer_ptr,
                    num_elements,
                    grid_dim=grid_size,
                    block_dim=BLOCK_SIZE,
                )


@always_inline
fn multi_gpu_barrier[
    ngpus: Int,
    is_start: Bool,
    need_fence: Bool = False,
](
    rank_sigs: StaticTuple[
        UnsafePointer[Signal], MAX_GPUS
    ],  # all-to-all table of signals
    self_sg: UnsafePointer[Signal],
    my_rank: Int,
):
    """
    Implements a barrier synchronization across multiple GPUs.

    Parameters:
        ngpus: Int - Number of GPUs participating in barrier.
        is_start: Bool - Whether this is the start barrier.
        need_fence: Bool - Whether memory fence is needed.

    Arguments:
        rank_sigs: Signal pointers for all GPUs
        self_sg: Signal pointer for current GPU
        my_rank: Current GPU rank

    Uses atomic counters and memory fences to ensure all GPUs reach barrier before proceeding.
    Implementation ported from VLLM's multi_gpu_barrier in
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
            Scalar[flag_t]
        ]() + bid * MAX_GPUS + my_gpu
        var val = internal_counter_ptr[] + 1
        internal_counter_ptr[] = val

        # Get the number of flags in self_counter to skip over it
        alias peer_counter_offset = sizeof[
            StaticTuple[StaticTuple[Scalar[flag_t], MAX_GPUS], MAX_BLOCK]
        ]() // sizeof[flag_t]()

        # this line should compute &rank_sigs[my_gpu]->peer_counter[val % 2][bid][my_rank]
        var peer_counter_ptr = (
            rank_sigs[my_gpu].bitcast[Scalar[flag_t]]()
            + peer_counter_offset
            + (val % 2) * (MAX_BLOCK * MAX_GPUS)
            + bid * MAX_GPUS
            + my_rank
        )
        # this line should compute &self_sg->peer_counter[val % 2][bid][my_gpu]
        var self_counter_ptr = (
            self_sg.bitcast[Scalar[flag_t]]()
            + peer_counter_offset
            + (val % 2) * (MAX_BLOCK * MAX_GPUS)
            + bid * MAX_GPUS
            + my_gpu
        )

        # Write the expected counter value to peer and wait for correct value from
        # peer.
        @parameter
        if need_fence:
            # broadcast the value to all peers that I reached the barrier
            store_release(peer_counter_ptr, val)
            # print("rank: ", my_rank, " waiting for val @peer num", my_gpu, ":", load_acquire(self_counter_ptr), "to be: ", val)
            while load_acquire(self_counter_ptr) != val:
                continue
            # print("rank: ", my_rank, " other gpu updated val @peer num", my_gpu, ":", load_acquire(self_counter_ptr))
        else:
            # TODO: (KERN-1207) get rid of these inlined assembly intrinsics to use ptr.store/load[volatile=True]
            # currently using store_volatile/load_volatile because they're much faster
            store_volatile(peer_counter_ptr, val)
            while load_volatile(self_counter_ptr) != val:
                continue

    @parameter
    if is_start or need_fence:
        barrier()


fn allreduce_2stage_kernel[
    type: DType, rank: Int, ngpus: Int
](
    result: UnsafePointer[Scalar[type]],
    src_bufs: StaticTuple[NDBuffer[type, rank], ngpus],
    rank_sigs: StaticTuple[UnsafePointer[Signal], MAX_GPUS],
    my_rank: Int,
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

    Arguments:
        result: Output buffer for reduced values.
        src_bufs: Input buffers from all GPUs.
        rank_sigs: Signal pointers for synchronization.
            IMPORTANT: the signal pointers have trailing buffers for
            communication, which must be at least `ngpus * sizeof(payload)`.
            | -- sizeof(Signal) -- | ------ a few MB ----- |
        my_rank: Current GPU rank.
        num_elements: Number of elements to reduce.
    """
    alias accum_type = get_accum_type[type]()
    alias simd_width = simdwidthof[type]()

    # --- Thread Indexing and Vector Setup ---
    var global_tid = global_idx.x

    # Stride equals total threads in grid dimension for grid-strided loops.
    var stride = grid_dim.x * block_dim.x
    var my_sig: UnsafePointer[Signal] = rank_sigs[my_rank]

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
        ptrs[i] = src_bufs[target].data

        # Skip Signal header.
        tmps[i] = (rank_sigs[target] + 1).bitcast[Scalar[type]]()

    # Current rank's output buffer.
    var tmp_out = tmps[0]

    # --- Stage 1: Reduce-Scatter Phase ---
    # Uses two-phase synchronization protocol with release-acquire semantics:
    # 1. Initial barrier establishes happens-before relationship.
    # 2. Memory fence ensures visibility of partial reductions.
    multi_gpu_barrier[ngpus, is_start=True](rank_sigs, my_sig, my_rank)

    # Grid-strided loop with vectorized reduction:
    # - Each thread processes partition elements using 128-bit accesses.
    # - Accumulates in higher precision (float32) for numerical stability.
    for idx in range(start + global_tid, end, stride):
        # float32 accumulator for numerical stability.
        var elem_idx = idx * simd_width
        var accum = ptrs[0].load[width=simd_width](elem_idx).cast[accum_type]()

        @parameter
        for gpu_idx in range(1, ngpus):
            accum += (
                ptrs[gpu_idx]
                .load[width=simd_width](elem_idx)
                .cast[accum_type]()
            )

        # Convert back to the element index before storing.
        var elem_start = start * simd_width
        tmp_out.store(elem_idx - elem_start, accum.cast[type]())

    # Second barrier with memory ordering guarantees.
    multi_gpu_barrier[ngpus, is_start=False, need_fence=True](
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
                result.store(
                    elem_dst_idx, tmps[gpu_idx].load[width=simd_width](elem_idx)
                )


fn allreduce_1stage_kernel[
    type: DType, rank: Int, ngpus: Int
](
    result: UnsafePointer[Scalar[type]],
    src_bufs: StaticTuple[NDBuffer[type, rank], ngpus],
    rank_sigs: StaticTuple[UnsafePointer[Signal], MAX_GPUS],
    my_rank: Int,
    num_elements: Int,
):
    """
    Kernel implementing all-reduce using peer-to-peer access between GPUs.

    Parameters:
        type: DType - Data type of tensor elements.
        rank: Int - Number of dimensions in tensors.
        ngpus: Int - Number of GPUs participating.

    Arguments:
        result: Output buffer for reduced values
        src_bufs: Input buffers from all GPUs
        rank_sigs: Signal pointers for synchronization
        my_rank: Current GPU rank
        num_elements: Number of elements to reduce

    Uses P2P access to directly read from other GPU buffers and perform reduction.
    Synchronizes using multi_gpu_barrier before and after reduction.
    """
    alias accum_type = get_accum_type[type]()
    alias simd_width = simdwidthof[type]()

    var global_tid = global_idx.x
    var stride = grid_dim.x * block_dim.x
    var my_sig: UnsafePointer[Signal] = rank_sigs[my_rank]
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
        ptrs[i] = src_bufs[target].data

    multi_gpu_barrier[ngpus, is_start=True](rank_sigs, my_sig, my_rank)

    # Vectorized grid-strided loop with SIMD loads.
    for idx in range(global_tid, num_simd_vectors, stride):
        var elem_idx = idx * simd_width
        var accum = ptrs[0].load[width=simd_width](elem_idx).cast[accum_type]()

        @parameter
        for _id in range(1, ngpus):
            accum += (
                ptrs[_id].load[width=simd_width](elem_idx).cast[accum_type]()
            )

        result.store(elem_idx, accum.cast[type]())

    multi_gpu_barrier[ngpus, is_start=False](rank_sigs, my_sig, my_rank)


@always_inline
fn all_reduce_p2p[
    type: DType,
    rank: Int,
    ngpus: Int, //,
](
    ctxs: List[DeviceContext],
    list_of_in_bufs: StaticTuple[NDBuffer[type, rank], ngpus],
    list_of_out_bufs: StaticTuple[NDBuffer[type, rank], ngpus],
    rank_sigs: StaticTuple[UnsafePointer[Signal], MAX_GPUS],
) raises:
    """
    Performs all-reduce using peer-to-peer access between GPUs.

    Parameters:
        type: DType - Data type of tensor elements.
        rank: Int - Number of dimensions in tensors.
        ngpus: Int - Number of GPUs participating.

    Arguments:
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

    for i in range(ngpus):
        var curr_ctx = ctxs[i]
        var curr_out_buf = list_of_out_bufs[i]

        alias BLOCK_SIZE = 256
        var grid_size = min(MAX_BLOCK, ceildiv(num_elements, BLOCK_SIZE))

        alias rank_4_byte_threshold = 512 * 1024
        alias rank_8_byte_threshold = 256 * 1024
        var payload_bytecount = list_of_in_bufs[0].bytecount()
        if (rank <= 4 and (payload_bytecount < rank_4_byte_threshold)) or (
            rank <= 8 and (payload_bytecount < rank_8_byte_threshold)
        ):
            # Use the 1-stage allreduce when transfer is latency bound.
            curr_ctx.enqueue_function[
                allreduce_1stage_kernel[type, rank, ngpus]
            ](
                curr_out_buf.data,
                list_of_in_bufs,
                rank_sigs,
                i,
                num_elements,
                grid_dim=grid_size,
                block_dim=BLOCK_SIZE,
            )
        else:
            # Otherwise, use 2-stage allreduce for the bandwidth bound regime.
            curr_ctx.enqueue_function[
                allreduce_2stage_kernel[type, rank, ngpus]
            ](
                curr_out_buf.data,
                list_of_in_bufs,
                rank_sigs,
                i,
                num_elements,
                grid_dim=grid_size,
                block_dim=BLOCK_SIZE,
            )


fn all_reduce[
    type: DType,
    rank: Int,
    ngpus: Int, //,
](
    ctxs: List[DeviceContext],
    list_of_in_bufs: StaticTuple[NDBuffer[type, rank], ngpus],
    list_of_out_bufs: StaticTuple[NDBuffer[type, rank], ngpus],
    rank_sigs: StaticTuple[UnsafePointer[Signal], MAX_GPUS],
) raises:
    """
    Main entry point for performing all-reduce across multiple GPUs.

    Parameters:
        type: DType - Data type of tensor elements.
        rank: Int - Number of dimensions in tensors.
        ngpus: Int - Number of GPUs participating.

    Arguments:
        ctxs: List of device contexts for participating GPUs
        list_of_in_bufs: Input buffers from each GPU
        list_of_out_bufs: Output buffers for each GPU
        rank_sigs: Signal pointers for synchronization

    Checks if P2P access is possible and uses appropriate implementation.
    Falls back to naive implementation if P2P is not available.
    """
    var can_p2p = can_enable_p2p(ctxs)

    if not can_p2p:
        return all_reduce_naive(ctxs, list_of_in_bufs, list_of_out_bufs)
    else:
        return all_reduce_p2p(
            ctxs, list_of_in_bufs, list_of_out_bufs, rank_sigs
        )
