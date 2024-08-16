# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #


from math import align_down, ceildiv, exp, iota, recip
from os import abort
from sys import alignof, simdwidthof

from algorithm import elementwise
from buffer import Buffer, NDBuffer
from buffer.dimlist import DimList
from gpu import (
    WARP_SIZE,
    BlockDim,
    BlockIdx,
    ThreadIdx,
    barrier,
    lane_id,
    shuffle_xor,
    warp_reduce,
)
from gpu.host import DeviceContext, FuncAttribute
from gpu.memory import AddressSpace, dynamic_shared_memory
from layout.int_tuple import IntTuple
from layout.layout import *
from layout.layout_tensor import (
    LayoutTensor,
    LayoutTensorIter,
    copy_dram_to_sram,
    copy_local_to_dram,
    copy_local_to_sram,
    copy_sram_to_dram,
)
from layout.tensor_core import get_accum_type, get_fragment_size, get_mma_shape
from linalg._multistage_gemm_gpu import multistage_mma
from linalg.bmm import batched_matmul
from linalg.matmul import matmul
from linalg.transpose import transpose
from memory import UnsafePointer, stack_allocation
from memory.reference import AddressSpace as _AddressSpace
from memory.unsafe import bitcast
from runtime.asyncrt import MojoCallContextPtr

from utils.index import Index, StaticIntTuple
from utils.numerics import min_or_neg_inf, neg_inf
from utils.static_tuple import StaticTuple

from .softmax import _online_softmax_iter_for_mma_output, _softmax_gpu, softmax

# ===----------------------------------------------------------------------===#
# Multi-Head Attention
# ===----------------------------------------------------------------------===#


fn fused_attention[
    rank: Int,
    q_shape: DimList,
    k_shape: DimList,
    v_shape: DimList,
    mask_shape: DimList,
    output_shape: DimList,
    q_type: DType,
    k_type: DType,
    v_type: DType,
    mask_type: DType,
    output_type: DType,
    transpose_k: Bool = False,
    add_attn_mask: Bool = True,
    add_causal_mask: Bool = False,
](
    output: NDBuffer[output_type, rank, output_shape],
    q: NDBuffer[q_type, rank, q_shape],
    k: NDBuffer[k_type, rank, k_shape],
    v: NDBuffer[v_type, rank, v_shape],
    mask: NDBuffer[mask_type, rank, mask_shape],
    scale: Float32,
    causal_mask_value: Float32,
) raises:
    """Multi-head Attention with fusion.
    Compute:
        (1) P = Bmm(Q, K), P is also called "score";
        (2) P = P * scale + attention_mask + causal_mask;
        (3) P = softmax(P);
        (4) output = Bmm(P, V).

    Q, V, and the output have shape BHSD. K has shape BHDS if transposed=false
    and  otherwise BHSD. B, S, H, D denote batch size, sequence length, head
    count and depth, respectively.

    (2) and (3) can be fused into (1) as elementwise and row-wise epilogue.

    The causal mask is implicitly set as (j <= i ? 0.0 : mask_value). Some
    models do the same thing but in various patterns, making it tricky to match.

    """

    constrained[rank == 3 or rank == 4, "Only support rank 3 and 4."]()

    alias simd_size = simdwidthof[output_type]()

    var score_size: Int
    var M: Int
    var N: Int
    var K: Int
    var flatten_batch_size: Int

    @parameter
    if rank == 4:
        # q shape is [batch size, # heads, seq_len, depth]
        M = q.dim[2]()
        N = k.dim[2]() if transpose_k else k.dim[3]()
        K = q.dim[3]()
        score_size = q.dim[0]() * q.dim[1]() * M * N
        flatten_batch_size = q.dim[0]() * q.dim[1]()
    else:
        # q shape is [batch size * # heads, seq_len, depth]
        M = q.dim[1]()
        N = k.dim[1]() if transpose_k else k.dim[2]()
        K = q.dim[2]()
        flatten_batch_size = q.dim[0]()
        score_size = q.dim[0]() * M * N

    alias score_type = output_type
    var score_ptr = UnsafePointer[Scalar[score_type]].alloc(score_size)

    var score_shape: StaticIntTuple[rank]

    @parameter
    if rank == 4:
        score_shape = rebind[StaticIntTuple[rank]](
            Index(q.dim[0](), q.dim[1](), M, N)
        )
    else:
        score_shape = rebind[StaticIntTuple[rank]](Index(q.dim[0](), M, N))
    # fmt: on
    var score = NDBuffer[score_type, rank](score_ptr, score_shape)

    @__copy_capture(M, N, score)
    @parameter
    @always_inline
    fn fuse_elementwise_fn[
        inner_type: DType, width: Int, _rank: Int
    ](_out_coords: StaticIntTuple[_rank], out_val: SIMD[inner_type, width]):
        var seq_offset = M - N
        var fused_val = out_val

        fused_val *= rebind[SIMD[inner_type, 1]](scale)

        @parameter
        if add_causal_mask:
            var vec_indices = iota[inner_type, width](_out_coords[_rank - 1])
            var vec_mask = vec_indices <= (_out_coords[_rank - 2] - seq_offset)
            fused_val = vec_mask.select(
                fused_val,
                rebind[SIMD[inner_type, width]](
                    SIMD[DType.float32, width](causal_mask_value),
                ),
            )

        @parameter
        if add_attn_mask:
            var idx = rebind[StaticIntTuple[rank]](_out_coords)
            fused_val += mask.load[width=width](idx).cast[inner_type]()

        score.store[width=width](
            rebind[StaticIntTuple[rank]](_out_coords),
            fused_val.cast[score_type](),
        )

    # The transpose of Q K V swaps batch and matmul dimensions,
    # e.x. 1x128x12x64 -> 1x12x128x64, which batched_matmul can't handle.
    # They are properly transposed before this kernel.
    batched_matmul[
        rank,
        q_type,
        k_type,
        score_type,
        transpose_k,
        fuse_elementwise_fn,
    ](
        score.make_dims_unknown(),
        q.make_dims_unknown(),
        k.make_dims_unknown(),
    )

    softmax[score_type, simd_size, rank](score, score, rank - 1)

    # NOTE: synchronous, so the stack allocated score_mem is safe.
    batched_matmul[rank, score_type, v_type, output_type, transpose_b=False](
        output.make_dims_unknown(),
        score.make_dims_unknown(),
        v.make_dims_unknown(),
    )

    # We did not reuse the output buffer, so we have to free the allocate
    # intermediate buffer.
    if score_ptr != output.data.bitcast[score_type]():
        score_ptr.free()


# ===----------------------------------------------------------------------===#
# Flash attention
# ===----------------------------------------------------------------------===#

# Using 32 bits index for GPU kernel.


fn flash_attention[
    rank: Int,
    mask_rank: Int,
    q_shape: DimList,
    k_shape: DimList,
    v_shape: DimList,
    mask_shape: DimList,
    output_shape: DimList,
    q_type: DType,
    k_type: DType,
    v_type: DType,
    mask_type: DType,
    output_type: DType,
    # llama 2 has attention mask but not causal mask.
    add_attn_mask: Bool = True,
    target: StringLiteral = "cpu",
    use_tensor_core: Bool = False,
](
    output: NDBuffer[output_type, rank, output_shape],
    q: NDBuffer[q_type, rank, q_shape],
    k: NDBuffer[k_type, rank, k_shape],
    v: NDBuffer[v_type, rank, v_shape],
    mask: NDBuffer[mask_type, mask_rank, mask_shape],
    scale: Float32,
    context: MojoCallContextPtr = MojoCallContextPtr(),
) raises:
    """Flash attention 2 algorithm.
    Compute:
        (1) Transpose (Q) BSHD -> BHSD;
        (2) Transpose (K) BSHD -> BHSD;
        (3) Transpose (V) BSHD -> BHSD;
        (4) P = Bmm(Q, K), P is also called "score";
        (5) P = P * scale + mask;
        (6) P = softmax(P);
        (7) O = Bmm(P, V)
        (8) Output = Transpose(O).

    B, S, H, D denote batch size, sequence length, head count and depth, respectively.
    (1), (2), (3) happens while loading the data into shared memory.
    (8) happens when writing output to global memory.

    All inputs (query, key, and value) must have BSHD layout. The mask can be
    BSS or BHSS.

    This kernel also handles grouped attention optimization. In this case the shape of
    K and V are BShD where h = H / num_groups.
    """
    constrained["cuda" in target, "only valid on Nvidia GPUs"]()
    constrained[rank == 4, "only support rank 4 inputs."]()
    constrained[mask_rank in (3, 4), "only support rank 3 or 4 mask."]()
    constrained[
        q_type == k_type == v_type == output_type,
        "Q, K, V, output should have same type.",
    ]()
    constrained[
        q_type == DType.float32 or q_type.is_half_float(),
        "Only support single and half precision.",
    ]()

    var ctx = context.get_device_context()

    # Runtime dimensions.
    var batch_size = q.dim[0]()
    var seq_len = q.dim[1]()
    var num_keys = k.dim[1]()

    @parameter
    if q_shape.all_known[2, 4]() and k_shape.has_value[2]():
        alias num_heads = q_shape.get[2]()
        alias depth = q_shape.get[3]()
        alias k_num_heads = k_shape.get[2]()
        alias group = num_heads // k_num_heads

        flash_attention_impl[
            rank,
            mask_rank,
            q_type,
            k_type,
            v_type,
            mask_type,
            output_type,
            depth,
            num_heads,
            group,
            add_attn_mask,
            target,
            use_tensor_core,
        ](
            output.data,
            q.data,
            k.data,
            v.data,
            mask.data,
            scale,
            batch_size,
            seq_len,
            num_keys,
            ctx,
        )

    else:
        var num_heads = q.dim[2]()
        var depth = q.dim[3]()
        var group = q.dim[2]() // k.dim[2]()

        mha_gpu_naive[
            mask_rank, q_type, k_type, v_type, mask_type, output_type
        ](
            q.data,
            k.data,
            v.data,
            mask.data,
            output.data,
            scale,
            batch_size,
            seq_len,
            num_keys,
            num_heads,
            depth,
            group,
            ctx,
        )


fn flash_attention_impl[
    rank: Int,
    mask_rank: Int,
    q_type: DType,
    k_type: DType,
    v_type: DType,
    mask_type: DType,
    output_type: DType,
    depth: Int,
    num_heads: Int,
    group: Int = 1,
    add_attn_mask: Bool = True,
    target: StringLiteral = "cpu",
    use_tensor_core: Bool = False,
](
    output: UnsafePointer[Scalar[output_type]],
    q: UnsafePointer[Scalar[q_type]],
    k: UnsafePointer[Scalar[k_type]],
    v: UnsafePointer[Scalar[v_type]],
    mask: UnsafePointer[Scalar[mask_type]],
    scale: Float32,
    batch_size: Int,
    seq_len: Int,
    num_keys: Int,
    ctx: DeviceContext,
) raises:
    try:

        @parameter
        if use_tensor_core and depth == 128:
            # Choose matmul parameters based on dtype.
            alias BM = 32 if q_type is DType.float32 else 64
            alias BN = depth
            alias BK = 16 if q_type is DType.float32 else 32
            alias WM = 32 if q_type is DType.float32 else 16
            alias WN = 32 if q_type is DType.float32 else depth
            # num warps in M and N, multipled by warp size.
            alias num_threads = (BM // WM) * (BN // WN) * WARP_SIZE

            if seq_len == num_keys and seq_len % 128 == 0:
                var func = ctx.compile_function[
                    mha[
                        mask_rank,
                        q_type,
                        k_type,
                        v_type,
                        mask_type,
                        output_type,
                        BM=BM,
                        BN=BN,
                        BK=BK,
                        WM=WM,
                        WN=WN,
                        depth=depth,
                        num_heads=num_heads,
                        num_threads=num_threads,
                        num_pipeline_stages=4,
                        group=group,
                    ]
                ](
                    # TODO: Avoid hard coding shared memory needed. KERN-747
                    func_attribute=FuncAttribute.MAX_DYNAMIC_SHARED_SIZE_BYTES(
                        80 * 1024
                    )
                )

                ctx.enqueue_function(
                    func,
                    q,
                    k,
                    v,
                    mask,
                    output,
                    scale,
                    batch_size,
                    seq_len,
                    grid_dim=(
                        ceildiv(seq_len, BM),
                        num_heads,
                        batch_size,
                    ),
                    block_dim=(num_threads, 1, 1),
                    shared_mem_bytes=80 * 1024,
                )

                return

        @parameter
        if q_type in (DType.float16, DType.bfloat16) and depth == 128:
            # Choose matmul parameters based on dtype.
            alias BM = 16
            alias BN = depth
            alias BK = 16 if q_type is DType.float32 else 32
            alias WM = BM
            alias WN = 32
            # num warps in M and N, multipled by warp size.
            alias num_threads = (BM // WM) * (BN // WN) * WARP_SIZE

            if seq_len == 1:
                var func = ctx.compile_function[
                    mha_decoding[
                        mask_rank,
                        q_type,
                        k_type,
                        v_type,
                        mask_type,
                        output_type,
                        BM=BM,
                        BN=BN,
                        BK=BK,
                        WM=WM,
                        WN=WN,
                        depth=depth,
                        num_heads=num_heads,
                        num_threads=num_threads,
                        num_pipeline_stages=4,
                        group=group,
                    ]
                ](
                    # TODO: Avoid hard coding shared memory needed.
                    func_attribute=FuncAttribute.MAX_DYNAMIC_SHARED_SIZE_BYTES(
                        80 * 1024
                    ),
                )

                ctx.enqueue_function(
                    func,
                    q,
                    k,
                    v,
                    mask,
                    output,
                    scale,
                    batch_size,
                    num_keys,
                    grid_dim=(1, num_heads, batch_size),
                    block_dim=(num_threads, 1, 1),
                    shared_mem_bytes=80 * 1024,
                )

                return

        mha_gpu_naive[mask_rank](
            q,
            k,
            v,
            mask,
            output,
            scale,
            batch_size,
            seq_len,
            num_keys,
            num_heads,
            depth,
            group,
            ctx,
        )

    except e:
        abort(e)


# ===----------------------------------------------------------------------===#
# Flash attention for context encoding
# ===----------------------------------------------------------------------===#


@__llvm_metadata(`nvvm.maxntid`=StaticTuple[Int32, 1](num_threads))
fn mha[
    mask_rank: Int,
    q_type: DType,
    k_type: DType,
    v_type: DType,
    mask_type: DType,
    output_type: DType,
    BM: Int,  # number of queries per block
    BN: Int,  # number of keys per block
    BK: Int,  # tile size in depth dimension
    WM: Int,
    WN: Int,
    depth: Int,
    num_heads: Int,
    num_threads: Int,
    num_pipeline_stages: Int,
    group: Int = 1,
](
    q_ptr: UnsafePointer[Scalar[q_type]],
    k_ptr: UnsafePointer[Scalar[k_type]],
    v_ptr: UnsafePointer[Scalar[v_type]],
    mask_ptr: UnsafePointer[Scalar[mask_type]],
    output_ptr: UnsafePointer[Scalar[output_type]],
    scale: Float32,
    batch_size: Int,
    seq_len: Int,
):
    var batch_idx = BlockIdx.z()
    var q_batch_offset = depth * num_heads * seq_len * batch_idx
    var kv_batch_offset = depth * (num_heads // group) * seq_len * batch_idx
    var mask_batch_offset = batch_idx * seq_len * seq_len * (
        num_heads if mask_rank == 4 else 1
    )

    mha_single_batch[
        mask_rank,
        BM=BM,
        BN=BN,
        BK=BK,
        WM=WM,
        WN=WN,
        depth=depth,
        num_heads=num_heads,
        num_threads=num_threads,
        num_pipeline_stages=num_pipeline_stages,
        group=group,
    ](
        q_ptr.offset(q_batch_offset),
        k_ptr.offset(kv_batch_offset),
        v_ptr.offset(kv_batch_offset),
        mask_ptr.offset(mask_batch_offset),
        output_ptr.offset(q_batch_offset),
        scale,
        seq_len,
    )


@__llvm_metadata(`nvvm.maxntid`=StaticTuple[Int32, 1](num_threads))
fn mha_single_batch[
    mask_rank: Int,
    q_type: DType,
    k_type: DType,
    v_type: DType,
    mask_type: DType,
    output_type: DType,
    *,
    BM: Int,  # number of queries per block
    BN: Int,  # number of keys per block
    BK: Int,  # tile size in depth dimension
    WM: Int,
    WN: Int,
    depth: Int,
    num_heads: Int,
    num_threads: Int,
    num_pipeline_stages: Int,
    group: Int = 1,
](
    q_ptr: UnsafePointer[Scalar[q_type]],
    k_ptr: UnsafePointer[Scalar[k_type]],
    v_ptr: UnsafePointer[Scalar[v_type]],
    mask_ptr: UnsafePointer[Scalar[mask_type]],
    output_ptr: UnsafePointer[Scalar[output_type]],
    scale: Float32,
    seq_len: Int,
):
    """MHA for token gen where seqlen = 1 and num_keys >= 1.

    The general data layout and steps conform to flash attention. Two exceptions:

    1 Partition across B, H, and num_keys (TODO).  The last one is split-K and
      will need a separate reduction kernel at the end.

    2 Frist bmm becomes gemv and second bmm becomes gevm.
      TODO: use more optimized kernels for them

    """
    constrained[q_type == k_type and k_type == v_type]()

    alias simd_size = simdwidthof[q_type]()

    alias num_warps_m = BM // WM
    alias num_warps_n = BN // WN

    constrained[
        num_warps_m * num_warps_n == (num_threads // WARP_SIZE),
        "Number of warps doesn't match warp tile sizes.",
    ]()

    var tid = ThreadIdx.x()
    var warp_id = (tid // WARP_SIZE)
    var lane = lane_id()

    # Coordinates of the current warp.
    var warp_x: UInt
    var warp_y: UInt
    warp_y, warp_x = divmod(warp_id, UInt(num_warps_n))

    # The entire query block (BM x depth) is tiled in shared memory.
    alias q_smem_size = BM * depth
    var q_smem = dynamic_shared_memory[
        Scalar[q_type], alignment = alignof[SIMD[q_type, simd_size]]()
    ]()
    var q_smem_iter = LayoutTensorIter[
        q_type, Layout.row_major(BM, BK), AddressSpace.SHARED
    ](q_smem, q_smem_size)

    # There is one pre-allocated dynamic shared buffer.
    # Need to explicitly offset key after at query's end.
    alias k_smem_size = num_pipeline_stages * BN * BK
    var k_smem = (q_smem + q_smem_size).bitcast[Scalar[k_type]]()
    var k_smem_iter = LayoutTensorIter[
        k_type, Layout.row_major(BN, BK), AddressSpace.SHARED, circular=True
    ](k_smem, k_smem_size)

    var head_idx = BlockIdx.y()
    var q_tile_idx = BlockIdx.x()

    # Query global memory iterator
    var q_offset = depth * (head_idx + num_heads * q_tile_idx * BM)
    var q_gmem_block = LayoutTensor[
        q_type, Layout(IntTuple(BM, depth), IntTuple(num_heads * depth, 1))
    ](q_ptr + q_offset)
    var q_gmem_iter = q_gmem_block.tiled_iterator[BM, BK, axis=1](0, 0)

    alias mma_shape = get_mma_shape[q_type, get_accum_type[q_type]()]()
    alias MMA_M = mma_shape[0]
    alias MMA_N = mma_shape[1]
    alias MMA_K = mma_shape[2]
    alias num_m_mmas = WM // MMA_M
    alias num_n_mmas = WN // MMA_N

    alias accum_type = get_accum_type[q_type]()
    alias frag_size = get_fragment_size[mma_shape]()
    alias p_frag_size = frag_size[2]
    alias p_frag_simdwidth = p_frag_size // 2

    var p_reg_tile = LayoutTensor[
        accum_type,
        Layout.row_major(num_m_mmas * num_n_mmas, p_frag_size),
        address_space = AddressSpace.LOCAL,
    ].stack_allocation()

    var output_reg_tile = LayoutTensor[
        accum_type,
        Layout.row_major(num_m_mmas * num_n_mmas, p_frag_size),
        address_space = AddressSpace.LOCAL,
    ].stack_allocation().fill(0)

    # Rowwise max and sum for online softmax
    var rowmax = stack_allocation[WM, accum_type]()
    var rowsum = stack_allocation[WM, accum_type]()

    @parameter
    for i in range(WM):
        rowmax[i] = min_or_neg_inf[accum_type]()
        rowsum[i] = 0.0

    # Scratch shared memory for reduction across warps.
    var warp_scratch = LayoutTensor[
        accum_type,
        Layout.row_major(num_warps_n, BM),
        address_space = AddressSpace.SHARED,
    ]((k_smem + k_smem_size).bitcast[Scalar[accum_type]]())

    # Share memory tile for Value, reuse K's shared memory tile.
    alias v_smem_size = num_pipeline_stages * BN * BK
    var v_smem = k_smem.bitcast[Scalar[v_type]]()
    var v_smem_iter = LayoutTensorIter[
        v_type, Layout.row_major(BK, BN), AddressSpace.SHARED, circular=True
    ](v_smem, v_smem_size)

    # Shared memory for P = Q * K^t
    # This overlaps key tile but are used at the same time i.e. no race condition.
    var p_smem = (v_smem + v_smem_size).bitcast[Scalar[v_type]]()
    alias p_smem_size = BM * BN
    var p_smem_tile = LayoutTensor[
        v_type,
        Layout.row_major(BM, BN),
        address_space = AddressSpace.SHARED,
    ](p_smem)
    var p_smem_warp_tile = p_smem_tile.tile[WM, WN](warp_y, warp_x)
    var p_smem_iter = p_smem_tile.tiled_iterator[BM, BK, axis=1](0, 0)

    # Mask global memory iterator.
    var mask_offset = q_tile_idx * BM * seq_len + (
        Int(head_idx * seq_len * seq_len) if mask_rank == 4 else 0
    )
    var warp_offset = warp_y * WM * seq_len + warp_x * WN
    var mask_warp_ptr = mask_ptr + Int(mask_offset) + Int(warp_offset)

    # Account for group query.
    alias kv_num_heads = num_heads // group
    var kv_offset = depth * (head_idx // group)

    for kv_tile_start_row in range(0, seq_len, BN):
        var k_gmem_block = LayoutTensor[
            k_type,
            Layout(IntTuple(BN, depth), IntTuple(kv_num_heads * depth, 1)),
        ](k_ptr + kv_offset + kv_tile_start_row * kv_num_heads * depth)
        var k_gmem_iter = k_gmem_block.tiled_iterator[BN, BK, axis=1](0, 0)

        _ = p_reg_tile.fill(0)

        # First iteration load q from global memory to shared memory.
        if kv_tile_start_row == 0:
            multistage_mma[
                BM,
                BN,
                BK,
                WM,
                WN,
                num_threads,
                num_pipeline_stages,
                True,  # transpose_b
            ](
                p_reg_tile,
                q_gmem_iter,
                k_gmem_iter,
                q_smem_iter,
                k_smem_iter,
                depth // BK,
            )
        # Subsequent iterations just use q in share memory.
        # TODO: Figure out a better function interface instead of passing in
        # shared memory iterator twice.
        else:
            multistage_mma[
                BM,
                BN,
                BK,
                WM,
                WN,
                num_threads,
                num_pipeline_stages,
                True,  # transpose_b
            ](
                p_reg_tile,
                # Pass shared memory iterator to hint not loading from global memory.
                q_smem_iter,
                k_gmem_iter,
                q_smem_iter,
                k_smem_iter,
                depth // BK,
            )

        # Vectorize by 2.
        var p_reg_vec2 = p_reg_tile.vectorize[1, p_frag_simdwidth]()

        # The dimension of mask are assumed dynamic here so still using index calculation.
        # TODO: check if the explicit index calculation can be avoided.
        @parameter
        for m_mma in range(num_m_mmas):

            @parameter
            for n_mma in range(num_n_mmas):
                var frag_offset = m_mma * MMA_M * seq_len + n_mma * MMA_N
                var mask_frag_ptr = mask_warp_ptr + frag_offset

                var frag_lane_row = int(lane // (MMA_N // p_frag_simdwidth))
                var frag_lane_col = int(lane * p_frag_simdwidth % MMA_N)

                alias mask_align = alignof[SIMD[mask_type, p_frag_simdwidth]]()

                @parameter
                for i in range(2):
                    var mask_vec = (
                        mask_frag_ptr
                        + (frag_lane_row + i * MMA_M // 2) * seq_len
                        + frag_lane_col
                    ).load[width=p_frag_simdwidth, alignment=mask_align]()

                    p_reg_vec2[n_mma * num_m_mmas + m_mma, i] = p_reg_vec2[
                        n_mma * num_m_mmas + m_mma, i
                    ] * scale.cast[accum_type]() + rebind[
                        p_reg_vec2.element_type
                    ](
                        mask_vec.cast[accum_type]()
                    )
        # Increment mask to next BM x BN block.
        mask_warp_ptr += BN

        _online_softmax_iter_for_mma_output[
            num_m_mmas, num_n_mmas, num_warps_n, mma_shape
        ](
            output_reg_tile,
            p_reg_tile,
            warp_scratch.tile[num_warps_n, WM](0, warp_y),
            rowmax,
            rowsum,
        )

        var v_gmem_block = LayoutTensor[
            v_type,
            Layout(IntTuple(BN, depth), IntTuple(kv_num_heads * depth, 1)),
        ](v_ptr + kv_offset + kv_tile_start_row * kv_num_heads * depth)
        var v_gmem_iter = v_gmem_block.tiled_iterator[BK, BN, axis=0](0, 0)

        @parameter
        if num_warps_n > 1:
            copy_local_to_sram[thread_layout = Layout.row_major(8, 4)](
                p_smem_warp_tile.vectorize[1, 2](),
                p_reg_tile.vectorize[1, 2]().transpose(),
            )
            barrier()

            multistage_mma[
                BM,
                BN,
                BK,
                WM,
                WN,
                num_threads,
                num_pipeline_stages,
                False,  # transpose_b
                swizzle_a=False,
            ](
                output_reg_tile,
                p_smem_iter,
                v_gmem_iter,
                p_smem_iter,
                v_smem_iter,
                BN // BK,
            )
        else:
            # Reuse 1st mma output (MMA_M, MMA_N) as 2nd mma's input (MMA_M, MMA_K).
            # The num_n_mmas dim becomes "num_k_mmas" for 2nd mma.
            var p_reg_iter = p_reg_tile.tiled_iterator[
                MMA_K // MMA_N * num_m_mmas, p_frag_size
            ](0, 0)

            multistage_mma[
                BM,
                BN,
                BK,
                WM,
                WN,
                num_threads,
                num_pipeline_stages,
                False,  # transpose_b
                swizzle_a=False,
                static_num_iters = BN // BK,
            ](
                output_reg_tile,
                p_reg_iter,
                v_gmem_iter,
                p_smem_iter,
                v_smem_iter,
                BN // BK,
            )

    # Apply softmax denumerator.
    @parameter
    for m_mma in range(num_m_mmas):
        var rowsum_inv0 = recip(rowsum[2 * m_mma])
        var rowsum_inv1 = recip(rowsum[2 * m_mma + 1])

        @parameter
        for n_mma in range(num_n_mmas):

            @parameter
            for i in range(p_frag_size // 2):
                output_reg_tile[n_mma * num_m_mmas + m_mma, i] *= rowsum_inv0
                output_reg_tile[
                    n_mma * num_m_mmas + m_mma, i + p_frag_size // 2
                ] *= rowsum_inv1

    var output_gmem_tile = LayoutTensor[
        output_type,
        Layout(IntTuple(BM, depth), IntTuple(num_heads * depth, 1)),
    ](output_ptr + q_offset)
    var output_gmem_warp_tile = output_gmem_tile.tile[WM, WN](warp_y, warp_x)

    # Write to global memory.
    @parameter
    if output_type.is_half_float():
        # Reuse a_smem for c tile in smem
        var accum_smem_tile = LayoutTensor[
            accum_type,
            Layout.row_major(BM, depth),
            address_space = AddressSpace.SHARED,
        ](q_smem.bitcast[Scalar[accum_type]]())
        var accum_smem_warp_tile = accum_smem_tile.tile[WM, WN](warp_y, warp_x)
        copy_local_to_sram[thread_layout = Layout.row_major(8, 4)](
            accum_smem_warp_tile.vectorize[1, 2](),
            output_reg_tile.vectorize[1, 2]().transpose(),
        )

        # Guard writing to shared memory.
        barrier()

        # Vectorized copy from shared to global memory, during which every 2 FP32
        # are cast to 2 BF16 so that 2 4xFP32 vectors are merged into 1 8xBF16
        # vector and stored using 16B store instruction.
        copy_sram_to_dram[
            thread_layout = Layout.row_major(
                num_threads * simd_size // depth, depth // simd_size
            )
        ](
            output_gmem_tile.vectorize[1, simd_size](),
            accum_smem_tile.vectorize[1, simd_size](),
        )
    else:
        copy_local_to_dram[dst_thread_layout = Layout.row_major(8, 4)](
            output_gmem_warp_tile.vectorize[1, 2](),
            output_reg_tile.bitcast[output_type]()
            .vectorize[1, 2]()
            .transpose(),
        )


# ===----------------------------------------------------------------------===#
# Flash decoding for token generation
# ===----------------------------------------------------------------------===#


@__llvm_metadata(`nvvm.maxntid`=StaticTuple[Int32, 1](num_threads))
fn mha_decoding[
    mask_rank: Int,
    q_type: DType,
    k_type: DType,
    v_type: DType,
    mask_type: DType,
    output_type: DType,
    BM: UInt,  # number of queries per block
    BN: UInt,  # number of keys per block
    BK: UInt,  # tile size in depth dimension
    WM: UInt,
    WN: UInt,
    depth: UInt,
    num_heads: UInt,
    num_threads: UInt,
    num_pipeline_stages: UInt,
    group: UInt = 1,
](
    q_ptr: UnsafePointer[Scalar[q_type]],
    k_ptr: UnsafePointer[Scalar[k_type]],
    v_ptr: UnsafePointer[Scalar[v_type]],
    mask_ptr: UnsafePointer[Scalar[mask_type]],
    output_ptr: UnsafePointer[Scalar[output_type]],
    scale: Float32,
    batch_size: Int,
    num_keys: Int,
):
    var batch_idx = BlockIdx.z()
    var q_batch_offset = depth * num_heads * batch_idx
    var kv_batch_offset = depth * (num_heads // group) * num_keys * batch_idx
    var mask_batch_offset = batch_idx * num_keys * (
        num_heads if mask_rank == 4 else 1
    )

    mha_decoding_single_batch[
        mask_rank,
        BM=BM,
        BN=BN,
        BK=BK,
        WM=WM,
        WN=WN,
        depth=depth,
        num_heads=num_heads,
        num_threads=num_threads,
        num_pipeline_stages=num_pipeline_stages,
        group=group,
    ](
        q_ptr.offset(q_batch_offset),
        k_ptr.offset(kv_batch_offset),
        v_ptr.offset(kv_batch_offset),
        mask_ptr.offset(mask_batch_offset),
        output_ptr.offset(q_batch_offset),
        scale,
        num_keys,
    )


@always_inline
fn scale_and_mask_helper[
    p_type: DType,
    p_layout: Layout,
    mask_type: DType,
    num_n_mmas: Int,
    WN: Int,
    MMA_N: Int,
    simd_width: Int,
](
    p_reg_tile: LayoutTensor[
        p_type, p_layout, address_space = AddressSpace.LOCAL
    ],
    mask_warp_ptr: UnsafePointer[Scalar[mask_type]],
    scale: Float32,
    num_keys: UInt,
    bound: UInt,
    lane: UInt,
    warp: UInt,
):
    # Apply mask and scale to mma result. Only the first row (lane 0-3) has
    # meaningful data, other fragments are zero. The mask is an 1D vector.
    # The dimension of mask are assumed dynamic here so still using index calculation.
    # TODO: check if the explicit index calculation can be avoided.

    # For mma output, thread 0-3 are on the first row.
    if lane >= 4:
        return

    # Use vector load for mask if the entire warp fit in valid context length.
    # Also num_keys should be aligned for vector load.
    if (warp + 1) * WN <= bound and num_keys % simd_width == 0:
        # Vectorize by 2.
        var p_reg_vec2 = p_reg_tile.vectorize[1, simd_width]()

        @parameter
        for n_mma in range(Int(num_n_mmas)):
            var frag_offset = n_mma * MMA_N
            var mask_frag_ptr = mask_warp_ptr + frag_offset

            var frag_lane_col = int(lane * simd_width)

            alias mask_align = alignof[SIMD[mask_type, simd_width]]()

            var mask_vec = (mask_frag_ptr + frag_lane_col).load[
                width=simd_width, alignment=mask_align
            ]()

            p_reg_vec2[n_mma, 0] = p_reg_vec2[n_mma, 0] * scale.cast[
                p_type
            ]() + rebind[p_reg_vec2.element_type](mask_vec.cast[p_type]())

    # Use scalar load for mask and manually mask out padded elements.
    else:
        var warp_offset = warp * WN

        @parameter
        for n_mma in range(Int(num_n_mmas)):
            # offset in fragment
            var frag_offset = n_mma * MMA_N
            # Current thread's offset mapped in num_keys dim
            var key_offset = warp_offset + frag_offset
            # Current thread's index in current mma tile, e.g. T1 is 2 in 16x8 mma output.
            var frag_lane_col = int(lane * simd_width)

            var mask_frag_ptr = mask_warp_ptr + frag_offset

            @parameter
            for i in range(simd_width):
                if key_offset + frag_lane_col + i < bound:
                    p_reg_tile[n_mma, i] = (
                        p_reg_tile[n_mma, i] * scale.cast[p_type]()
                        + mask_frag_ptr[frag_lane_col + i].cast[p_type]()
                    )
                else:
                    p_reg_tile[n_mma, i] = min_or_neg_inf[p_type]()


fn mha_decoding_single_batch[
    mask_rank: Int,
    q_type: DType,
    k_type: DType,
    v_type: DType,
    mask_type: DType,
    output_type: DType,
    *,
    BM: UInt,  # number of queries per block
    BN: UInt,  # number of keys per block
    BK: UInt,  # tile size in depth dimension
    WM: UInt,
    WN: UInt,
    depth: UInt,
    num_heads: UInt,
    num_threads: UInt,
    num_pipeline_stages: UInt,
    group: UInt = 1,
](
    q_ptr: UnsafePointer[Scalar[q_type]],
    k_ptr: UnsafePointer[Scalar[k_type]],
    v_ptr: UnsafePointer[Scalar[v_type]],
    mask_ptr: UnsafePointer[Scalar[mask_type]],
    output_ptr: UnsafePointer[Scalar[output_type]],
    scale: Float32,
    num_keys: UInt,
):
    """Flash attention v2 algorithm."""
    constrained[q_type == k_type and k_type == v_type]()

    alias simd_size = simdwidthof[q_type]()

    alias num_warps_m = BM // WM
    alias num_warps_n = BN // WN

    constrained[
        num_warps_m * num_warps_n == (num_threads // WARP_SIZE),
        "Number of warps doesn't match warp tile sizes.",
    ]()

    var tid = ThreadIdx.x()
    var warp_id = (tid // WARP_SIZE)
    var lane = lane_id()

    # Coordinates of the current warp.
    var warp_x: UInt
    var warp_y: UInt
    warp_y, warp_x = divmod(warp_id, UInt(num_warps_n))

    # The entire query block (BM x depth) is tiled in shared memory.
    alias q_smem_size = BM * depth
    var q_smem = dynamic_shared_memory[
        Scalar[q_type], alignment = alignof[SIMD[q_type, simd_size]]()
    ]()
    var q_smem_iter = LayoutTensorIter[
        q_type, Layout.row_major(BM, BK), AddressSpace.SHARED
    ](q_smem, q_smem_size)

    # There is one pre-allocated dynamic shared buffer.
    # Need to explicitly offset key after at query's end.
    alias k_smem_size = num_pipeline_stages * BN * BK
    var k_smem = (q_smem + q_smem_size).bitcast[Scalar[k_type]]()
    var k_smem_iter = LayoutTensorIter[
        k_type, Layout.row_major(BN, BK), AddressSpace.SHARED, circular=True
    ](k_smem, k_smem_size)

    var head_idx = BlockIdx.y()

    alias mma_shape = get_mma_shape[q_type, get_accum_type[q_type]()]()
    alias MMA_M = mma_shape[0]
    alias MMA_N = mma_shape[1]
    alias MMA_K = mma_shape[2]
    alias num_m_mmas = WM // MMA_M
    alias num_n_mmas = WN // MMA_N

    alias accum_type = get_accum_type[q_type]()
    alias frag_size = get_fragment_size[mma_shape]()
    alias p_frag_size = frag_size[2]
    alias p_frag_simdwidth = p_frag_size // 2

    var p_reg_tile = LayoutTensor[
        accum_type,
        Layout.row_major(num_m_mmas * num_n_mmas, p_frag_size),
        address_space = AddressSpace.LOCAL,
    ].stack_allocation()

    var output_reg_tile = LayoutTensor[
        accum_type,
        Layout.row_major(num_m_mmas * num_n_mmas, p_frag_size),
        address_space = AddressSpace.LOCAL,
    ].stack_allocation().fill(0.0)

    # Rowwise max and sum for online softmax
    var rowmax = stack_allocation[WM, accum_type]()
    var rowsum = stack_allocation[WM, accum_type]()

    @parameter
    for i in range(Int(WM)):
        rowmax[i] = min_or_neg_inf[accum_type]()
        rowsum[i] = 0.0

    # Scratch shared memory for reduction across warps.
    var warp_scratch = LayoutTensor[
        accum_type,
        Layout.row_major(num_warps_n, BM),
        address_space = AddressSpace.SHARED,
    ]((k_smem + k_smem_size).bitcast[Scalar[accum_type]]())

    # Share memory tile for Value, reuse K's shared memory tile.
    alias v_smem_size = num_pipeline_stages * BN * BK
    var v_smem = k_smem.bitcast[Scalar[v_type]]()
    var v_smem_iter = LayoutTensorIter[
        v_type, Layout.row_major(BK, BN), AddressSpace.SHARED, circular=True
    ](v_smem, v_smem_size)

    # Shared memory for P = Q * K^t
    # This overlaps key tile but are used at the same time i.e. no race condition.
    var p_smem = (v_smem + v_smem_size).bitcast[Scalar[v_type]]()
    alias p_smem_size = BM * BN
    var p_smem_tile = LayoutTensor[
        v_type,
        Layout.row_major(BM, BN),
        address_space = AddressSpace.SHARED,
    ](p_smem)
    var p_smem_warp_tile = p_smem_tile.tile[WM, WN](warp_y, warp_x)
    var p_smem_iter = p_smem_tile.tiled_iterator[BM, BK, axis=1](0, 0)

    # Mask global memory iterator, seq_len = 1
    var mask_offset = Int(head_idx * num_keys) if mask_rank == 4 else 0
    var warp_offset = warp_y * WM * num_keys + warp_x * WN
    var mask_warp_ptr = mask_ptr + Int(mask_offset) + Int(warp_offset)

    # Account for group query.
    alias kv_num_heads = num_heads // group
    var kv_offset = depth * (head_idx // group)

    # Load q from global to shared memory. q is a 1D vector of size `depth`.
    # This is hard coded for depth < warp_size * simd_width
    # TODO: generalize with layout tensor's masked copy
    var q_offset = depth * head_idx

    for i in range(tid * simd_size, BM * depth, BlockDim.x() * simd_size):
        var vec = SIMD[q_type, simd_size](0.0)
        if i < depth:
            vec = q_ptr.load[
                width=simd_size, alignment = alignof[SIMD[q_type, simd_size]]()
            ](q_offset + i)
        var row: UInt
        var col: UInt
        row, col = divmod(i, depth)
        var chunk_id: UInt
        var in_chunk_id: UInt
        chunk_id, in_chunk_id = divmod(col, BK)
        if i < BM * depth:
            q_smem.store[alignment = alignof[SIMD[q_type, simd_size]]()](
                chunk_id * BM * BK + row * BK + in_chunk_id,
                vec,
            )

    # @parameter
    # for i in range(Int(depth // BK)):
    #     if tid < BK // simd_size:
    #         var vec = q_ptr.load[
    #             width=simd_size, alignment = alignof[SIMD[q_type, simd_size]]()
    #         ](q_offset + i * BK + tid * simd_size)
    #         (q_smem + i * BM * BK + tid * simd_size).store[
    #             alignment = alignof[SIMD[q_type, simd_size]]()
    #         ](vec)
    #     elif tid < BM * BK // simd_size:
    #         q_smem.store[alignment = alignof[SIMD[q_type, simd_size]]()](
    #             i * BM * BK + tid * simd_size,
    #             SIMD[q_type, simd_size](0.0),
    #         )

    # Loop over Key and Value tiles
    for kv_tile_start_row in range(0, num_keys, BN):
        var k_gmem_block = LayoutTensor[
            k_type,
            Layout(
                IntTuple(Int(BN), Int(depth)),
                IntTuple(Int(kv_num_heads * depth), 1),
            ),
        ](k_ptr + kv_offset + kv_tile_start_row * kv_num_heads * depth)
        var k_gmem_iter = k_gmem_block.tiled_iterator[BN, BK, axis=1](0, 0)

        var kv_tile_num_rows = min(BN, num_keys - kv_tile_start_row)

        _ = p_reg_tile.fill(0)

        multistage_mma[
            BM,
            BN,
            BK,
            WM,
            WN,
            num_threads,
            num_pipeline_stages,
            True,  # transpose_b
        ](
            p_reg_tile,
            # Pass shared memory iterator to hint not loading from global memory.
            q_smem_iter,
            k_gmem_iter,
            q_smem_iter,
            k_smem_iter,
            depth // BK,
            num_a_rows=None,
            num_b_rows=Int(kv_tile_num_rows),
        )

        # Apply scale and mask
        scale_and_mask_helper[
            num_n_mmas=num_n_mmas,
            WN=WN,
            MMA_N=MMA_N,
            simd_width=p_frag_simdwidth,
        ](
            p_reg_tile,
            mask_warp_ptr,
            scale,
            num_keys,
            kv_tile_num_rows,
            lane,
            warp_id,
        )
        # Increment mask to next BM x BN block.
        mask_warp_ptr += BN

        _online_softmax_iter_for_mma_output[
            num_m_mmas, num_n_mmas, num_warps_n, mma_shape
        ](
            output_reg_tile,
            p_reg_tile,
            warp_scratch.tile[num_warps_n, WM](0, warp_y),
            rowmax,
            rowsum,
        )

        var v_gmem_block = LayoutTensor[
            v_type,
            Layout(
                IntTuple(Int(BN), Int(depth)),
                IntTuple(Int(kv_num_heads * depth), 1),
            ),
        ](v_ptr + kv_offset + kv_tile_start_row * kv_num_heads * depth)
        var v_gmem_iter = v_gmem_block.tiled_iterator[BK, BN, axis=0](0, 0)

        copy_local_to_sram[thread_layout = Layout.row_major(8, 4)](
            p_smem_warp_tile.vectorize[1, 2](),
            p_reg_tile.vectorize[1, 2]().transpose(),
        )
        barrier()

        multistage_mma[
            BM,
            BN,
            BK,
            WM,
            WN,
            num_threads,
            num_pipeline_stages,
            False,  # transpose_b
            swizzle_a=False,
        ](
            output_reg_tile,
            p_smem_iter,
            v_gmem_iter,
            p_smem_iter,
            v_smem_iter,
            BN // BK,
            num_a_rows=None,
            num_b_rows=Int(kv_tile_num_rows),
        )

    # Apply softmax denumerator.
    @parameter
    for m_mma in range(Int(num_m_mmas)):
        var rowsum_inv0 = 1.0 / rowsum[2 * m_mma]

        @parameter
        for n_mma in range(Int(num_n_mmas)):
            output_reg_tile[n_mma, 0] *= rowsum_inv0
            output_reg_tile[n_mma, 1] *= rowsum_inv0

    # Write to global memory.
    var accum_smem_tile = LayoutTensor[
        accum_type,
        Layout.row_major(BM, depth),
        address_space = AddressSpace.SHARED,
    ](q_smem.bitcast[Scalar[accum_type]]())
    var accum_smem_warp_tile = accum_smem_tile.tile[WM, WN](warp_y, warp_x)
    copy_local_to_sram[thread_layout = Layout.row_major(8, 4)](
        accum_smem_warp_tile.vectorize[1, 2](),
        output_reg_tile.vectorize[1, 2]().transpose(),
    )

    # Guard writing to shared memory.
    barrier()

    # Vectorized copy from shared to global memory, during which every 2 FP32
    # are cast to 2 BF16 so that 2 4xFP32 vectors are merged into 1 8xBF16
    # vector and stored using 16B store instruction.
    var output_gmem_tile = LayoutTensor[output_type, Layout.row_major(depth)](
        output_ptr + q_offset
    )
    var output_smem_tile = LayoutTensor[
        accum_type, Layout.row_major(depth), address_space = AddressSpace.SHARED
    ](q_smem.bitcast[accum_type]())

    if tid < depth // simd_size:
        copy_sram_to_dram[thread_layout = Layout.row_major(depth // simd_size)](
            output_gmem_tile.vectorize[simd_size](),
            output_smem_tile.vectorize[simd_size](),
        )


# ===----------------------------------------------------------------------===#
# Naive GPU multihead attention supporting flexible dimensions.
# ===----------------------------------------------------------------------===#


fn mha_gpu_naive[
    mask_rank: Int,
    q_type: DType,
    k_type: DType,
    v_type: DType,
    mask_type: DType,
    output_type: DType,
](
    q_ptr: UnsafePointer[Scalar[q_type]],
    k_ptr: UnsafePointer[Scalar[k_type]],
    v_ptr: UnsafePointer[Scalar[v_type]],
    mask_ptr: UnsafePointer[Scalar[mask_type]],
    output_ptr: UnsafePointer[Scalar[output_type]],
    scale: Float32,
    batch_size: Int,
    seq_len: Int,
    num_keys: Int,
    num_heads: Int,
    depth: Int,
    group: Int,
    ctx: DeviceContext,
) raises:
    alias p_type = get_accum_type[q_type]()
    var p_device = ctx.create_buffer[p_type](
        batch_size * num_heads * seq_len * num_keys
    )
    var p_ptr = p_device.ptr
    var p_buffer = NDBuffer[p_type, 3](
        p_ptr, Index(batch_size * num_heads, seq_len, num_keys)
    )

    var bmm0_func = ctx.compile_function[
        _bmm0[mask_rank, q_type, k_type, p_type, mask_type]
    ]()
    ctx.enqueue_function(
        bmm0_func,
        p_ptr,
        q_ptr,
        k_ptr,
        mask_ptr,
        scale,
        batch_size,
        seq_len,
        num_keys,
        num_heads,
        depth,
        group,
        grid_dim=(
            ceildiv(num_keys, 32),
            ceildiv(seq_len, 16),
            num_heads * batch_size,
        ),
        block_dim=(32, 16, 1),
    )

    @parameter
    @__copy_capture(p_buffer)
    fn input_fn_device[
        _simd_width: Int, _rank: Int
    ](coords: StaticIntTuple[_rank]) -> SIMD[p_type, _simd_width]:
        return p_buffer.load[width=_simd_width](
            rebind[StaticIntTuple[3]](coords)
        )

    _softmax_gpu[p_type, 1, 3, DimList.create_unknown[3](), input_fn_device](
        Index(batch_size * num_heads, seq_len, num_keys),
        p_buffer,
        2,
        ctx,
    )

    var bmm1_func = ctx.compile_function[_bmm1[p_type, v_type, output_type]]()

    ctx.enqueue_function(
        bmm1_func,
        output_ptr,
        p_ptr,
        v_ptr,
        seq_len,
        num_keys,
        num_heads,
        depth,
        group,
        grid_dim=(
            ceildiv(depth, 32),
            ceildiv(seq_len, 16),
            num_heads * batch_size,
        ),
        block_dim=(32, 16, 1),
    )

    _ = p_device


@always_inline
fn _bmm0[
    mask_rank: Int,
    q_type: DType,
    k_type: DType,
    p_type: DType,
    mask_type: DType,
](
    p_ptr: UnsafePointer[Scalar[p_type]],
    q_ptr: UnsafePointer[Scalar[q_type]],
    k_ptr: UnsafePointer[Scalar[k_type]],
    mask_ptr: UnsafePointer[Scalar[mask_type]],
    scale: Float32,
    batch_size: Int,
    seq_len: Int,
    num_keys: Int,
    num_heads: Int,
    depth: Int,
    group: Int,
):
    var x = BlockIdx.x() * BlockDim.x() + ThreadIdx.x()
    var y = BlockIdx.y() * BlockDim.y() + ThreadIdx.y()
    if x >= num_keys or y >= seq_len:
        return

    var batch_head = BlockIdx.z()
    var batch: UInt
    var head: UInt
    batch, head = divmod(batch_head, UInt(num_heads))

    var q_offset = int(depth * (head + num_heads * seq_len * batch))
    var q = q_ptr + q_offset

    var kv_num_heads = num_heads // group
    var kv_offset = int(
        depth * (head // group + kv_num_heads * num_keys * batch)
    )
    var k = k_ptr + kv_offset

    var p_offset = batch_head * seq_len * num_keys
    var p = p_ptr + Int(p_offset)

    var mask_offset = (
        batch if mask_rank == 3 else batch_head
    ) * seq_len * num_keys
    var mask = mask_ptr + Int(mask_offset)

    var accum = SIMD[p_type, 1](0.0)

    for d in range(UInt(depth)):
        accum += (
            q[y * num_heads * depth + d].cast[k_type]()
            * k[x * kv_num_heads * depth + d]
        ).cast[p_type]()

    p[y * num_keys + x] = (
        accum * scale.cast[p_type]() + mask[y * num_keys + x].cast[p_type]()
    )


@always_inline
fn _bmm1[
    p_type: DType,
    v_type: DType,
    output_type: DType,
](
    output_ptr: UnsafePointer[Scalar[output_type]],
    p_ptr: UnsafePointer[Scalar[p_type]],
    v_ptr: UnsafePointer[Scalar[v_type]],
    seq_len: Int,
    num_keys: Int,
    num_heads: Int,
    depth: Int,
    group: Int,
):
    var x = BlockIdx.x() * BlockDim.x() + ThreadIdx.x()
    var y = BlockIdx.y() * BlockDim.y() + ThreadIdx.y()
    if x >= depth or y >= seq_len:
        return

    var batch_head = BlockIdx.z()
    var batch: UInt
    var head: UInt
    batch, head = divmod(batch_head, UInt(num_heads))

    var p_offset = batch_head * seq_len * num_keys
    var p = p_ptr + p_offset

    var kv_num_heads = num_heads // group
    var kv_offset = int(
        depth * (head // group + kv_num_heads * num_keys * batch)
    )
    var v = v_ptr + kv_offset

    var output_offset = depth * (head + num_heads * seq_len * batch)
    var output = output_ptr + Int(output_offset)

    var accum = SIMD[DType.float32, 1](0.0)

    for i in range(num_keys):
        accum += (
            p[y * num_keys + i].cast[v_type]() * v[i * kv_num_heads * depth + x]
        ).cast[DType.float32]()

    output[y * num_heads * depth + x] = accum.cast[output_type]()


# ===----------------------------------------------------------------------===#
# Naive CPU MHA as reference
# ===----------------------------------------------------------------------===#


fn _naive_attention_with_transpose[
    type: DType,
    transpose_k: Bool = False,
](
    output: NDBuffer[type, 4],
    q: NDBuffer[type, 4],
    k: NDBuffer[type, 4],
    v: NDBuffer[type, 4],
    mask: NDBuffer[type, 2],
    scale: Float32,
):
    """This kernel provides reference values for flash attention in llama 2.
    It can't be used in any model.
    Layouts:
        q: BSHD
        k, v: BKHD
        output: BSHD
        mask: SK
    B, S, K, H, D stand for batch size, sequence length, number of keys,
    number of heads, and depth per head, respectively.
    """
    alias simd_size = simdwidthof[type]()

    var batch_size = q.dim[0]()
    var seq_len = q.dim[1]()
    var num_keys = k.dim[1]()
    var num_heads = q.dim[2]()
    var depth = q.dim[3]()

    # Q, K, V transposed
    var qt_ptr = UnsafePointer[Scalar[type]].alloc(q.num_elements())
    var kt_ptr = UnsafePointer[Scalar[type]].alloc(k.num_elements())
    var vt_ptr = UnsafePointer[Scalar[type]].alloc(v.num_elements())
    # Score = softmax(Q * K)
    var score_size = batch_size * num_heads * seq_len * num_keys
    var score_ptr = UnsafePointer[Scalar[type]].alloc(score_size)
    # O = Score * V. It's transposed and will be transposed back to output.
    var ot_ptr = UnsafePointer[Scalar[type]].alloc(output.num_elements())

    var qt = NDBuffer[type, 4](
        qt_ptr, Index(batch_size, num_heads, seq_len, depth)
    )
    var kt = NDBuffer[type, 4](
        kt_ptr, Index(batch_size, num_heads, depth, num_keys)
    )
    var vt = NDBuffer[type, 4](
        vt_ptr, Index(batch_size, num_heads, num_keys, depth)
    )
    var score = NDBuffer[type, 4](
        score_ptr, Index(batch_size, num_heads, seq_len, num_keys)
    )
    var ot = NDBuffer[type, 4](
        ot_ptr, Index(batch_size, num_heads, seq_len, depth)
    )

    # BSHD -> BHSD
    var q_perm = Buffer[DType.index, 4].stack_allocation()
    q_perm[0] = 0
    q_perm[1] = 2
    q_perm[2] = 1
    q_perm[3] = 3

    # BSHD -> BHDS
    var k_perm = Buffer[DType.index, 4].stack_allocation()
    k_perm[0] = 0
    k_perm[1] = 2
    k_perm[2] = 3
    k_perm[3] = 1

    # BHSD -> BSHD
    var o_perm = Buffer[DType.index, 4].stack_allocation()
    o_perm[0] = 0
    o_perm[1] = 2
    o_perm[2] = 1
    o_perm[3] = 3

    try:
        transpose(qt, q, q_perm.data)
    except e:
        abort(e)

    try:
        transpose(kt, k, k_perm.data)
    except e:
        abort(e)

    try:
        transpose(vt, v, q_perm.data)
    except e:
        abort(e)

    _naive_attention[type, transpose_k](ot, qt, kt, vt, mask, scale)

    try:
        transpose(output, ot, o_perm.data)
    except e:
        abort(e)

    qt_ptr.free()
    kt_ptr.free()
    vt_ptr.free()
    score_ptr.free()
    ot_ptr.free()


fn _naive_attention[
    type: DType,
    transpose_k: Bool = False,
](
    output: NDBuffer[type, 4],
    q: NDBuffer[type, 4],
    k: NDBuffer[type, 4],
    v: NDBuffer[type, 4],
    mask: NDBuffer[type, 2],
    scale: Float32,
):
    """This kernel provides reference values for flash attention in llama 2.
    It can't be used in any model.
    """
    alias simd_size = simdwidthof[type]()

    var batch_size = q.dim[0]()
    var num_heads = q.dim[1]()
    var seq_len = q.dim[2]()
    var num_keys = v.dim[2]()
    var depth = q.dim[3]()

    # Allocate intermediate memory buffer.
    var score_size = batch_size * num_heads * seq_len * num_keys
    var score_ptr = UnsafePointer[Scalar[type]].alloc(score_size)
    var score = NDBuffer[type, 4](
        score_ptr, Index(batch_size, num_heads, seq_len, num_keys)
    )

    batched_matmul[4, type, type, type, transpose_k](score, q, k)

    @__copy_capture(score)
    @parameter
    @always_inline
    fn scale_and_mask[width: Int, _rank: Int](coords: StaticIntTuple[_rank]):
        var vec = score.load[width=width](rebind[StaticIntTuple[4]](coords))
        vec = vec * scale.cast[type]()
        vec = vec + mask.load[width=width](
            Index(coords[_rank - 2], coords[_rank - 1])
        )
        score.store[width=width](rebind[StaticIntTuple[4]](coords), vec)

    elementwise[scale_and_mask, simd_size](score.dynamic_shape)

    try:
        softmax[type, simd_size, 4](
            score,
            score,
            axis=3,
        )
    except e:
        abort(e)

    batched_matmul[4, type, type, type, transpose_b=False](output, score, v)

    score_ptr.free()
