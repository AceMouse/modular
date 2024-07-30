# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
from collections import OptionalReg
from math import align_up, align_down, ceildiv
from sys.info import alignof

from algorithm.functional import tile_and_unswitch
from buffer.buffer import NDBuffer
from buffer.dimlist import DimList
from gpu import WARP_SIZE, BlockDim, BlockIdx, ThreadIdx, barrier, lane_id
from gpu.host import DeviceContext, FuncAttribute
from gpu.memory import (
    AddressSpace,
    async_copy_commit_group,
    async_copy_wait_all,
    async_copy_wait_group,
    dynamic_shared_memory,
)
from gpu.mma import ld_matrix, mma
from gpu.shuffle import shuffle_down, shuffle_idx, warp_reduce
from gpu.tensor_ops import (
    tc_reduce,
    tc_reduce_vector,
    tc_reduce_gevm_4x,
    tc_reduce_gevm_8x,
)
from layout._utils import ManagedLayoutTensor, gpu_free, gpu_managed_alloc
from layout.int_tuple import IntTuple
from layout.layout import *
from layout.layout_tensor import (
    LayoutTensor,
    _swizzle_signature,
    copy_dram_to_sram_async,
    copy_local_to_dram,
    copy_sram_to_local,
    outer_product_acc,
)
from layout.nd_buffer_stub import copy_from_nd_buffer, distribute, vectorize
from layout.swizzle import Swizzle
from memory import stack_allocation, UnsafePointer

from utils.index import Index
from utils.numerics import get_accum_type
from utils.static_tuple import InlineArray, StaticTuple

from sys import llvm_intrinsic

from ._multistage_gemm_gpu import multistage_gemm
from .utils import GemmShape, apply_epilogue, elementwise_epilogue_type
from gpu.host._compile import _get_nvptx_target


@always_inline
fn __nvvm_ldg_f4[type: DType](x: UnsafePointer[Scalar[type]]) -> SIMD[type, 4]:
    # Load a register variable from global state space via non-coherent cache.

    alias alignment = Int32(alignof[SIMD[type, 4]]())

    @parameter
    if type == DType.float32:
        return bitcast[type, 4](
            llvm_intrinsic[
                "llvm.nvvm.ldg.global.f.v4f32.p0v4f32", SIMD[DType.float32, 4]
            ](x.bitcast[DType.float32](), alignment)
        )
    elif type == DType.bfloat16:
        return bitcast[type, 4](
            llvm_intrinsic[
                "llvm.nvvm.ldg.global.f.v4bf16.p0v4bf16",
                SIMD[DType.bfloat16, 4],
            ](x.bitcast[DType.bfloat16](), alignment)
        )
    elif type == DType.float16:
        return bitcast[type, 4](
            llvm_intrinsic[
                "llvm.nvvm.ldg.global.f.v4f16.p0v4f16",
                SIMD[DType.float16, 4],
            ](x.bitcast[DType.float16](), alignment)
        )
    else:
        constrained[False, "Unhandled DType"]()
        return 0


# BM: The threadblock size for M dimension SMEM caching.
# BN: The threadblock size for N dimension SMEM caching.
# BK: The threadblock size for K dimension SMEM caching.
# WM: M dim of continuous tile computed by each warp.
# WN: N dim of continuous tile computed by each warp.
# WMITER: The number of subwarp tiling steps in M dimension.
# WNITER: The number of subwarp tiling steps in N dimension.
# TM: The per-thread tile size for M dimension.
# TN: The per-thread tile size for N dimension.
@__llvm_metadata(`nvvm.maxntid`=StaticTuple[Int32, 1](NUM_THREADS))
fn sgemm_warp_tiling_kernel[
    c_type: DType,
    c_shape: DimList,
    a_type: DType,
    a_shape: DimList,
    b_type: DType,
    b_shape: DimList,
    BM: Int,
    BN: Int,
    BK: Int,
    WM: Int,
    WN: Int,
    WMITER: Int,
    WNITER: Int,
    TM: Int,
    TN: Int,
    NUM_THREADS: Int,
    elementwise_lambda_fn: OptionalReg[elementwise_epilogue_type] = None,
](
    mat_c: NDBuffer[c_type, 2, c_shape],
    mat_a: NDBuffer[a_type, 2, a_shape],
    mat_b: NDBuffer[b_type, 2, b_shape],
    alpha: Scalar[c_type],
    beta: Scalar[c_type],
):
    var M = mat_c.dim(0)
    var K = mat_a.dim(1)
    var N = mat_c.dim(1)

    var c_row = BlockIdx.y()
    var c_col = BlockIdx.x()

    # Placement of the warp in the threadblock tile.
    var warp_idx = ThreadIdx.x() // WARP_SIZE  # the warp this thread is in
    var warp_col = warp_idx % (BN // WN)
    var warp_row = warp_idx // (BN // WN)

    # Size of the warp subtile.
    alias w_sub_m = WM // WMITER  # 64/2=32
    alias w_sub_n = WN // WNITER  # 32/2=16

    # Placement of the thread in the warp subtile.
    var thread_Idx_In_warp = ThreadIdx.x() % WARP_SIZE  # [0, 31]
    var thread_col_in_warp = thread_Idx_In_warp % (w_sub_n // TN)  # i%(16/4)
    var thread_row_in_warp = thread_Idx_In_warp // (w_sub_n // TN)  # i/4

    # Allocate space for the current blocktile in SMEM.
    # Pad the A tile in share memory to avoid bank conflicts.
    # Use 4 to comply with f4 alignment used in accumulation.
    alias sram_bank_padding_size = 4
    alias BM_padded = BM + sram_bank_padding_size
    var a_sram = NDBuffer[
        a_type,
        1,
        DimList(int(BK * BM_padded)),
        address_space = AddressSpace.SHARED,
    ].stack_allocation()
    var b_sram = NDBuffer[
        b_type,
        1,
        DimList(int(BK * BN)),
        address_space = AddressSpace.SHARED,
    ].stack_allocation()

    # Move blocktile to beginning of A's row and B's column.
    var aa_ptr = mat_a._offset(Index(c_row * BM, 0))
    var bb_ptr = mat_b._offset(Index(0, c_col * BN))
    # Move C_ptr to warp's output tile
    var M_offset_warp = c_row * BM + warp_row * WM
    var N_offset_warp = c_col * BN + warp_col * WN
    var cc_ptr = mat_c._offset(Index(M_offset_warp, N_offset_warp))

    # Calculate the indices that this thread will load into SMEM.
    # We load 128bit / 32bit = 4 elements per thread at each step.
    var inner_row_a = ThreadIdx.x() // (BK // 4)
    var inner_col_a = ThreadIdx.x() % (BK // 4)
    alias row_stride_a = (NUM_THREADS * 4) // BK
    var inner_row_b = ThreadIdx.x() // (BN // 4)
    var inner_co_ib = ThreadIdx.x() % (BN // 4)
    alias row_stride_b = NUM_THREADS // (BN // 4)

    # TODO: We want these to be register-allocated!
    # Allocate thread-local cache for results in register file.
    var thread_results = NDBuffer[
        c_type,
        4,
        DimList(int(WMITER), int(WNITER), int(TM), int(TN)),
    ]().stack_allocation()
    thread_results.zero()

    # We cache into registers on the warptile level.
    var reg_m = NDBuffer[
        a_type, 2, DimList(int(WMITER), int(TM))
    ]().stack_allocation()
    reg_m.zero()

    var reg_n = NDBuffer[
        b_type, 2, DimList(int(WNITER), int(TN))
    ]().stack_allocation()
    reg_n.zero()

    # Outer-most loop over block tiles.
    for bk_idx in range(0, int(K), int(BK)):
        for offset in range(0, int(BM - row_stride_a + 1), int(row_stride_a)):
            # Load 4 elements at a time and store to shared memory.
            var tmp = __nvvm_ldg_f4[a_type](
                aa_ptr.offset(int((inner_row_a + offset) * K + inner_col_a * 4))
            )

            @parameter
            for i in range(4):
                a_sram[
                    int(
                        (inner_col_a * 4 + i) * BM_padded + inner_row_a + offset
                    )
                ] = tmp[i]

        for offset in range(0, int(BK - row_stride_b + 1), int(row_stride_b)):
            # Load 4 elements at a time and store to shared memory.
            var tmp = __nvvm_ldg_f4[b_type](
                bb_ptr.offset(int((inner_row_b + offset) * N + inner_co_ib * 4))
            )
            b_sram.store[width=4, alignment=16](
                Index((inner_row_b + offset) * BN + inner_co_ib * 4),
                tmp,
            )

        barrier()

        for dot_idx in range(BK):
            # Populate registers for whole warptile.
            @parameter
            for w_sub_row_idx in range(WMITER):

                @parameter
                for i in range(0, int(TM), 4):
                    var vec = a_sram.load[width=4, alignment=16](
                        int(
                            (dot_idx * BM_padded)
                            + warp_row * WM
                            + w_sub_row_idx * w_sub_m
                            + thread_row_in_warp * TM
                            + i
                        )
                    )
                    reg_m.store(Index(w_sub_row_idx, i), vec)

            @parameter
            for w_sub_col_idx in range(WNITER):

                @parameter
                for i in range(0, int(TN), 4):
                    var vec = b_sram.load[width=4, alignment=16](
                        int(
                            (dot_idx * BN)
                            + warp_col * WN
                            + w_sub_col_idx * w_sub_n
                            + thread_col_in_warp * TN
                        )
                    )
                    reg_n.store(Index(w_sub_col_idx, i), vec)

            # Execute warptile matmul.
            @parameter
            for w_sub_row_idx in range(WMITER):

                @parameter
                for w_sub_col_idx in range(WNITER):
                    # Calculate per-thread results.
                    @parameter
                    for res_idx_m in range(TM):

                        @parameter
                        for res_idx_n in range(TN):
                            thread_results[
                                Index(
                                    w_sub_row_idx,
                                    w_sub_col_idx,
                                    res_idx_m,
                                    res_idx_n,
                                )
                            ] += (
                                reg_m[w_sub_row_idx, res_idx_m].cast[c_type]()
                                * reg_n[w_sub_col_idx, res_idx_n].cast[c_type]()
                            )
        aa_ptr = aa_ptr.offset(int(BK))  # move BK columns to right
        bb_ptr = bb_ptr.offset(int(BK * N))  # move BK rows down
        barrier()

    # Write out the results.
    @parameter
    for w_sub_row_idx in range(WMITER):

        @parameter
        for w_sub_col_idx in range(WNITER):
            # Move C pointer to current warp subtile.
            var M_offset_subtile = w_sub_row_idx * w_sub_m
            var N_offset_subtile = w_sub_col_idx * w_sub_n
            var C_interim = cc_ptr.offset(
                int((M_offset_subtile) * N + N_offset_subtile)
            )

            @parameter
            for res_idx_m in range(TM):

                @parameter
                for res_idx_n in range(0, int(TN), 4):
                    var M_offset_val = thread_row_in_warp * TM + res_idx_m
                    var N_offset_val = thread_col_in_warp * TN + res_idx_n
                    var c_idx = M_offset_val * N + N_offset_val
                    var result_vec = thread_results.load[width=4](
                        Index(
                            w_sub_row_idx,
                            w_sub_col_idx,
                            res_idx_m,
                            res_idx_n,
                        )
                    )

                    var vec = alpha * result_vec + beta * C_interim.load[
                        width=4, alignment=16
                    ](int(c_idx))

                    @parameter
                    if elementwise_lambda_fn:
                        alias elementwise_lambda = elementwise_lambda_fn.value()
                        elementwise_lambda[c_type, 4](
                            Index(
                                M_offset_warp + M_offset_subtile + M_offset_val,
                                N_offset_warp + N_offset_subtile + N_offset_val,
                            ),
                            vec,
                        )
                    else:
                        C_interim.store[width=4][alignment=16](int(c_idx), vec)


# Matrix-Column Vector Multiplication
fn gemv_kernel[
    c_type: DType,
    a_type: DType,
    b_type: DType,
    elementwise_lambda_fn: OptionalReg[elementwise_epilogue_type] = None,
    s_type: DType = get_accum_type[c_type](),
](
    c: UnsafePointer[Scalar[c_type]],
    a: UnsafePointer[Scalar[a_type]],
    b: UnsafePointer[Scalar[b_type]],
    m: Int,
    n: Int,
    k: Int,
):
    var x = BlockIdx.x() * BlockDim.x() + ThreadIdx.x()
    var warpId = x // WARP_SIZE
    var accum = SIMD[s_type, 1]()

    if warpId < m:
        # Every warp processes a single row of the resultant vector
        for i in range(ceildiv(k, WARP_SIZE)):
            var idx = i * WARP_SIZE + lane_id()
            var val = SIMD[s_type, 1]()
            if idx < k:
                val = (
                    a.load(Int(warpId) * k + Int(idx)).cast[s_type]()
                    * b.load(Int(idx)).cast[s_type]()
                )

            @parameter
            fn reduce_add[
                type: DType,
                width: Int,
            ](x: SIMD[type, width], y: SIMD[type, width]) -> SIMD[type, width]:
                return x + y

            val = warp_reduce[shuffle_down, reduce_add](val)

            if lane_id() == 0:
                accum += val

        if lane_id() == 0:

            @parameter
            if elementwise_lambda_fn:
                alias elementwise_lambda = elementwise_lambda_fn.value()
                elementwise_lambda[c_type, 1](
                    Index(Int(warpId), 0), accum.cast[c_type]()
                )
            else:
                c[warpId] = accum.cast[c_type]()


# Matrix-Column Vector Multiplication utilizing Tensor Cores
fn gemv_tc_kernel[
    c_type: DType,
    a_type: DType,
    b_type: DType,
    elementwise_lambda_fn: OptionalReg[elementwise_epilogue_type] = None,
    s_type: DType = get_accum_type[c_type](),
](
    c: UnsafePointer[Scalar[c_type]],
    a: UnsafePointer[Scalar[a_type]],
    b: UnsafePointer[Scalar[b_type]],
    m: Int,
    n: Int,
    k: Int,
):
    var x = BlockIdx.x() * BlockDim.x() + ThreadIdx.x()
    var warpId = x // WARP_SIZE
    var accum = Scalar[s_type]()

    if warpId < m:
        # Every warp processes a single row of the resultant vector
        for i in range(ceildiv(k, WARP_SIZE)):
            var idx = i * WARP_SIZE + lane_id()
            var val = Scalar[s_type]()
            if idx < k:
                val = (
                    a.load(warpId * k + idx).cast[s_type]()
                    * b.load(idx).cast[s_type]()
                )

            var out_val = Scalar[s_type]()
            out_val = tc_reduce[s_type, a_type](val.cast[a_type]())

            if lane_id() == 0:
                accum += out_val

        if lane_id() == 0:

            @parameter
            if elementwise_lambda_fn:
                alias elementwise_lambda = elementwise_lambda_fn.value()
                elementwise_lambda[c_type, 1](
                    Index(Int(warpId), 0), accum.cast[c_type]()
                )
            else:
                c[warpId] = accum.cast[c_type]()


# Matrix-Column Vector Multiplication utilizing Tensor Cores
fn gemv_tc_kernel_vector[
    c_type: DType,
    a_type: DType,
    b_type: DType,
    simd_width: Int,
    elementwise_lambda_fn: OptionalReg[elementwise_epilogue_type] = None,
    s_type: DType = get_accum_type[c_type](),
](
    c: NDBuffer[c_type, 2],
    a: NDBuffer[a_type, 2],
    b: NDBuffer[b_type, 2],
    m: Int,
    n: Int,
    k: Int,
):
    alias align_a = alignof[SIMD[a_type, simd_width]]()
    alias align_b = alignof[SIMD[b_type, simd_width]]()
    var x = BlockIdx.x() * BlockDim.x() + ThreadIdx.x()
    var warpId = x // WARP_SIZE
    var accum = SIMD[s_type, 1]()

    if warpId < m:
        # Every warp processes a single row of the resultant vector
        for i in range(ceildiv(k // simd_width, WARP_SIZE)):
            var idx = (i * WARP_SIZE * simd_width) + lane_id() * simd_width
            var val = SIMD[a_type, simd_width]()
            if idx < k:
                var ax = a.load[width=simd_width, alignment=align_a](
                    Index(warpId, idx)
                )
                var bx = b.load[width=simd_width, alignment=align_b](
                    Index(idx, 0)
                ).cast[a_type]()

                # Do simd vector loads in ax,bx to multiply element wise for matrix row and vector column
                val = ax * bx

            # Do a fast tensor core and warp shuffle based reduce operation
            var out_val = tc_reduce_vector[s_type, a_type, simd_width](val)

            if lane_id() == 0:
                accum += out_val

        if lane_id() == 0:

            @parameter
            if elementwise_lambda_fn:
                alias elementwise_lambda = elementwise_lambda_fn.value()
                elementwise_lambda[c_type, 1](
                    Index(warpId, 0), accum.cast[c_type]()
                )
            else:
                c.store(Index(warpId, 0), accum.cast[c_type]())


# Row Vector-Matrix multiplication
fn gevm_kernel[
    c_type: DType,
    a_type: DType,
    b_type: DType,
    tile_size: Int,
    elementwise_lambda_fn: OptionalReg[elementwise_epilogue_type] = None,
    s_type: DType = get_accum_type[c_type](),
](
    c: UnsafePointer[Scalar[c_type]],
    a: UnsafePointer[Scalar[a_type]],
    b: UnsafePointer[Scalar[b_type]],
    m: Int,
    n: Int,
    k: Int,
):
    var warpsPerBlock = BlockDim.x() // WARP_SIZE
    var warpId = ThreadIdx.x() // WARP_SIZE
    var accum = SIMD[s_type, 1]()
    var col = BlockIdx.x() * WARP_SIZE + lane_id()
    var tid = BlockIdx.x() * BlockDim.x() + ThreadIdx.x()
    var globalWarpId = tid // WARP_SIZE

    var x_shared = stack_allocation[
        tile_size,
        s_type,
        address_space = AddressSpace.SHARED,
    ]()

    # Every block computes warp size length of output values
    for i in range(ceildiv(UInt(k), warpsPerBlock)):
        var row = i * warpsPerBlock + warpId
        var lhs = a.load(row)
        var rhs = b.load(row * n + col)
        accum += lhs.cast[s_type]() * rhs.cast[s_type]()

    x_shared[lane_id() * WARP_SIZE + warpId] = accum
    barrier()

    @parameter
    fn reduce_add[
        type: DType,
        width: Int,
    ](x: SIMD[type, width], y: SIMD[type, width]) -> SIMD[type, width]:
        return x + y

    var total = SIMD[s_type, 1]()
    total = x_shared.load(ThreadIdx.x()).cast[s_type]()
    total = warp_reduce[shuffle_down, reduce_add](total)

    if lane_id() == 0:

        @parameter
        if elementwise_lambda_fn:
            alias elementwise_lambda = elementwise_lambda_fn.value()
            elementwise_lambda[c_type, 1](
                Index(UInt(0), globalWarpId), total.cast[c_type]()
            )
        else:
            c[globalWarpId] = total.cast[c_type]()


fn gevm_tc_kernel_vector_8x[
    c_type: DType,
    a_type: DType,
    b_type: DType,
    tile_size: Int,
    simd_width: Int,
    elementwise_lambda_fn: OptionalReg[elementwise_epilogue_type] = None,
    s_type: DType = get_accum_type[c_type](),
](
    c: NDBuffer[c_type, 2],
    a: NDBuffer[a_type, 2],
    b: NDBuffer[b_type, 2],
    m: UInt,
    n: UInt,
    k: UInt,
):
    alias align_b = alignof[SIMD[b_type, simd_width]]()
    alias align_x = alignof[SIMD[s_type, simd_width]]()

    var warpsPerBlock = BlockDim.x() // WARP_SIZE
    var warpId = ThreadIdx.x() // WARP_SIZE
    var accum = SIMD[s_type, simd_width]()
    var col = BlockIdx.x() * WARP_SIZE * simd_width + lane_id() * simd_width
    var tid = BlockIdx.x() * BlockDim.x() + ThreadIdx.x()
    var globalWarpId = tid // WARP_SIZE

    var x_shared = stack_allocation[
        tile_size,
        a_type,
        address_space = AddressSpace.SHARED,
    ]()

    # Every block computes warp size * simd_width length of output values
    for i in range(ceildiv(k, warpsPerBlock)):
        var row = i * warpsPerBlock + warpId
        if row < k and col < n:
            var lhs = a.load(Index(0, row))
            var rhs = b.load[width=simd_width, alignment=align_b](
                Index(row, col)
            )
            accum += lhs.cast[s_type]() * rhs.cast[s_type]()

    var xs = warpId * WARP_SIZE * simd_width + lane_id() * simd_width

    @parameter
    for x in range(simd_width):
        x_shared[xs + x] = accum[x].cast[a_type]()

    barrier()

    var val1 = SIMD[s_type, simd_width // 2]()
    var val2 = SIMD[s_type, simd_width // 2]()

    # indexing to fetch correctly from shared memory
    var stride = 256
    var mma_tile_width = 8
    var mma_col_elem_width = 4
    var target_row = (lane_id() % mma_col_elem_width) * mma_col_elem_width
    var target_col = warpId * mma_tile_width + (lane_id() // mma_col_elem_width)

    @parameter
    for i in range(simd_width // 2):
        val1[i] = x_shared[(target_row + i) * stride + target_col].cast[
            s_type
        ]()
        val2[i] = x_shared[(target_row + 16 + i) * stride + target_col].cast[
            s_type
        ]()

    # Doing tensor core reduction to get final results in first row
    var res = tc_reduce_gevm_8x[s_type, a_type, simd_width // 2](
        val1.cast[a_type](), val2.cast[a_type]()
    )

    if lane_id() < 4:
        var final = res.split()

        @parameter
        if elementwise_lambda_fn:
            alias elementwise_lambda = elementwise_lambda_fn.value()
            elementwise_lambda[c_type, (simd_width // 2) // 2](
                Index(UInt(0), globalWarpId * simd_width + lane_id() * 2),
                final[0].cast[c_type](),
            )
        else:
            c.store[
                width = (simd_width // 2) // 2,
                alignment = alignof[SIMD[c_type, (simd_width // 2) // 2]](),
            ](
                Index(UInt(0), globalWarpId * simd_width + lane_id() * 2),
                final[0].cast[c_type](),
            )


fn matmul_kernel[
    c_type: DType,
    a_type: DType,
    b_type: DType,
    tile_size: Int,
    elementwise_lambda_fn: OptionalReg[elementwise_epilogue_type] = None,
    s_type: DType = get_accum_type[c_type](),
](
    c_ptr: UnsafePointer[Scalar[c_type]],
    a_ptr: UnsafePointer[Scalar[a_type]],
    b_ptr: UnsafePointer[Scalar[b_type]],
    m: Int,
    n: Int,
    k: Int,
):
    """Matrix Multiplication using shared memory.
    This version loads blocks of size tile_size x tile_size from A and B
    and updates a tile_size x tile_size in C.

    The thread block should have shape (tile_size, tile_size, 1). Each
    thread is mapped one element in C. The grid should have shape
    (N/tile_size, M/tile_size, 1). N is the first dimension for coalesced
    access.
    """
    var a = NDBuffer[a_type, 2](a_ptr, Index(m, k))
    var b = NDBuffer[b_type, 2](b_ptr, Index(k, n))
    var c = NDBuffer[c_type, 2](c_ptr, Index(m, n))

    # Allocate A, B tile in shared memory.
    var a_shared = stack_allocation[
        tile_size * tile_size,
        a_type,
        address_space = AddressSpace.SHARED,
    ]()
    var b_shared = stack_allocation[
        tile_size * tile_size,
        b_type,
        address_space = AddressSpace.SHARED,
    ]()

    # Global index in C.
    # These are the same indices in A and B when loading to SRAM.
    # Map thread x to column for coalesced access in B.
    var col = BlockIdx.x() * BlockDim.x() + ThreadIdx.x()
    var row = BlockIdx.y() * BlockDim.y() + ThreadIdx.y()

    # Local index in the c sub-matrix updated by current block.
    var localCol = ThreadIdx.x()
    var localRow = ThreadIdx.y()

    # Result of current thread in C.
    var result = SIMD[s_type, 1](0.0)

    var K_roundbytile = align_down(k, tile_size)
    # Can't use 0 as tile size so set to 1 when the remainder is 0.
    var K_remainder = k - K_roundbytile if k - K_roundbytile > 0 else 1

    @parameter
    @__copy_capture(row, localCol, a, b, localRow, col, a_shared, b_shared)
    @always_inline
    fn update_tile[full_tile: Bool](offset: Int, end: Int, tile_size: Int):
        # If K is not multiple of tile_size, the last tile contains less than
        # tile_size elements. The thread block needs to take addition bound check
        # when loading elements into shared memory.

        # Load A tile into shared memory.
        var a_val: SIMD[a_type, 1]

        @parameter
        if not full_tile:
            a_val = a[row, offset + localCol] if (
                row < m and offset + localCol < k
            ) else 0.0
        else:
            a_val = a[row, offset + localCol] if row < m else 0.0
        a_shared[localRow * tile_size + localCol] = a_val

        # Load B tile into shared memory.
        var b_val: SIMD[b_type, 1]

        @parameter
        if not full_tile:
            b_val = b[offset + localRow, col] if (
                col < n and offset + localRow < k
            ) else 0.0
        else:
            b_val = b[offset + localRow, col] if col < n else 0.0
        b_shared[localRow * tile_size + localCol] = b_val

        barrier()

        for kk in range(tile_size):
            result += (
                a_shared[localRow * tile_size + kk].cast[s_type]()
                * b_shared[kk * tile_size + localCol].cast[s_type]()
            )

        barrier()

    tile_and_unswitch[update_tile](
        0, k, VariadicList[Int](tile_size, K_remainder)
    )

    if row < m and col < n:

        @parameter
        if elementwise_lambda_fn:
            alias elementwise_lambda = elementwise_lambda_fn.value()
            elementwise_lambda[c_type, 1](
                Index(row, col), result.cast[c_type]()
            )
        else:
            c[Index(row, col)] = result.cast[c_type]()


fn sgemm_double_buffer_kernel[
    c_type: DType,
    a_type: DType,
    b_type: DType,
    b_layout: Layout,
    BM: Int,
    BN: Int,
    BK: Int,
    WM: Int,
    WN: Int,
    TM: Int,
    TN: Int,
    NUM_THREADS: Int,
    elementwise_lambda_fn: OptionalReg[elementwise_epilogue_type] = None,
](
    m: Int,
    c: UnsafePointer[Scalar[c_type]],
    a: UnsafePointer[Scalar[a_type]],
    b: LayoutTensor[b_type, b_layout],
):
    alias simd_size = simdwidthof[c_type]()

    alias N = b.dim[1]()
    alias K = b.dim[0]()

    alias num_warps_m = BM // WM
    alias num_warps_n = BN // WN

    var tid = ThreadIdx.x()
    var warp_id = tid // WARP_SIZE
    var lane_id = lane_id()

    # Coordinates of the current warp.
    var warp_x = warp_id % num_warps_n
    var warp_y = warp_id // num_warps_n

    # Warp shape in 2D.
    alias warp_dim_x = WN // TN
    alias warp_dim_y = WM // TM
    constrained[
        warp_dim_x * warp_dim_y == WARP_SIZE,
        "Warp 2d shape doesn't match 32 threads",
    ]()

    # Pad BM to avoid back conflict
    alias pad_avoid_bank_conflict = 4
    alias BM_padded = BM + pad_avoid_bank_conflict

    # Double buffer in shared memory.
    alias a_smem_size = BK * BM_padded
    var a_smem_tile = LayoutTensor[
        a_type,
        Layout.row_major(2 * BK, BM_padded),
        address_space = AddressSpace.SHARED,
    ].stack_allocation().slice[:, :BM]().split[2]()

    # Align the address by the maximum async copy size (16 bytes).
    alias b_smem_size = BK * BN
    var b_smem_tile = LayoutTensor[
        b_type,
        Layout.row_major(2 * BK, BN),
        address_space = AddressSpace.SHARED,
    ].stack_allocation().split[2]()

    # Global memory tile.
    alias a_gmem_layout = Layout(IntTuple(BM, BK), IntTuple(K, 1))
    var a_offset = BlockIdx.y() * BM * K
    var a_gmem_tile = LayoutTensor[a_type, a_gmem_layout](a.offset(a_offset))
    var b_gmem_tile = b.tile[BK, BN](0, BlockIdx.x())

    # Load A tile from global memory to shared.
    # Row major thread layout for coalesced access.
    alias thread_loada_gmem_layout = Layout.row_major(NUM_THREADS // BK, BK)
    alias thread_storea_smem_layout = Layout.col_major(BK, NUM_THREADS // BK)
    copy_dram_to_sram_async[
        src_thread_layout=thread_loada_gmem_layout,
        dst_thread_layout=thread_storea_smem_layout,
    ](a_smem_tile[0], a_gmem_tile)

    # Load B tile from global memory to shared.
    # Row major thread layout for coalesced access.
    alias thread_layout_loadb = Layout.row_major(
        (NUM_THREADS // BN) * simd_size, BN // simd_size
    )
    copy_dram_to_sram_async[
        src_thread_layout=thread_layout_loadb,
        dst_thread_layout=thread_layout_loadb,
    ](
        b_smem_tile[0].vectorize[1, simd_size](),
        b_gmem_tile.vectorize[1, simd_size](),
    )

    async_copy_wait_all()
    barrier()

    # Advance A and B to next k tile.
    a_gmem_tile = LayoutTensor[a_type, a_gmem_layout](a.offset(a_offset + BK))
    b_gmem_tile = b.tile[BK, BN](1, BlockIdx.x())

    # Double buffer in registers (fragments in nvidia terms).
    var a_reg = InlineArray[_, 2](
        LayoutTensor[a_type, Layout(TM)].stack_allocation(),
        LayoutTensor[a_type, Layout(TM)].stack_allocation(),
    )
    var b_reg = InlineArray[_, 2](
        LayoutTensor[b_type, Layout(TN)].stack_allocation(),
        LayoutTensor[b_type, Layout(TN)].stack_allocation(),
    )
    var c_reg = LayoutTensor[
        c_type, Layout.row_major(TM, TN)
    ].stack_allocation()
    c_reg.fill(0)

    # Thread swizzling
    # Warp has 2D Layout [warp_dim_x, warp_dim_y]. Current thread is mapped to
    # (mma_x, mma_y) in this layout as follow (the number is thread id).
    # 0  2  4  6  8  10 12 14
    # 1  3  5  7  9  11 13 15
    # 16 18 20 22 24 26 28 30
    # 17 19 21 23 25 27 29 31
    alias thread_layout = Layout(
        IntTuple(IntTuple(2, 2), 8), IntTuple(IntTuple(1, 16), 2)
    )

    # Load A fragments to the first buffer.
    var a_smem_warp_tile = a_smem_tile[0].tile[BK, WM](0, warp_y)
    var a_smem_warp_row = a_smem_warp_tile.tile[1, WM](0, 0).coalesce()
    copy_sram_to_local[src_warp_layout=thread_layout, axis=0](
        a_reg[0].vectorize[simd_size](), a_smem_warp_row.vectorize[simd_size]()
    )

    # Load B fragments to the first buffer.
    var b_smem_warp_tile = b_smem_tile[0].tile[BK, WN](0, warp_x)
    var b_smem_warp_row = b_smem_warp_tile.tile[1, WN](0, 0).coalesce()
    copy_sram_to_local[src_warp_layout=thread_layout, axis=1](
        b_reg[0].vectorize[simd_size](), b_smem_warp_row.vectorize[simd_size]()
    )

    var num_k_tiles = ceildiv(K, BK)

    # Update (num_k_tile - 1) tiles while switching buffers.
    # for k_tile_id in range(num_k_tiles - 1):
    for k_tile_id in range(num_k_tiles):
        # The shared memory buffer to be prefetched
        var prefetch_id = 1 if k_tile_id % 2 == 0 else 0

        @parameter
        for k in range(BK):
            var next_k = (k + 1) % BK

            # Buffer id for the double register buffers. They alternate.
            var buffer_id = k & 1
            var next_buffer_id = (k + 1) & 1

            if k == BK - 1:
                async_copy_wait_all()
                barrier()

                a_smem_warp_tile = a_smem_tile[prefetch_id].tile[BK, WM](
                    0, warp_y
                )
                b_smem_warp_tile = b_smem_tile[prefetch_id].tile[BK, WN](
                    0, warp_x
                )

            # Fill the other A fragments buffer using the next row in A.
            var a_smem_warp_row = a_smem_warp_tile.tile[1, WM](
                next_k, 0
            ).coalesce()
            copy_sram_to_local[src_warp_layout=thread_layout, axis=0](
                a_reg[next_buffer_id].vectorize[simd_size](),
                a_smem_warp_row.vectorize[simd_size](),
            )

            var b_smem_warp_row = b_smem_warp_tile.tile[1, WN](
                next_k, 0
            ).coalesce()
            copy_sram_to_local[src_warp_layout=thread_layout, axis=1](
                b_reg[next_buffer_id].vectorize[simd_size](),
                b_smem_warp_row.vectorize[simd_size](),
            )

            # Load next k tile from global memory to shared memory.
            if k == 0 and k_tile_id < num_k_tiles - 1:
                a_gmem_tile = LayoutTensor[a_type, a_gmem_layout](
                    a.offset(
                        BlockIdx.y() * UInt(BM) * UInt(K)
                        + (k_tile_id + 1) * UInt(BK)
                    )
                )
                copy_dram_to_sram_async[
                    src_thread_layout=thread_loada_gmem_layout,
                    dst_thread_layout=thread_storea_smem_layout,
                ](a_smem_tile[prefetch_id], a_gmem_tile)

                b_gmem_tile = b.tile[BK, BN](k_tile_id + 1, BlockIdx.x())
                copy_dram_to_sram_async[
                    src_thread_layout=thread_layout_loadb,
                    dst_thread_layout=thread_layout_loadb,
                ](
                    b_smem_tile[prefetch_id].vectorize[1, simd_size](),
                    b_gmem_tile.vectorize[1, simd_size](),
                )

            outer_product_acc(c_reg, a_reg[buffer_id], b_reg[buffer_id])

    # Map global memory tile down to thread.
    var c_offset = BlockIdx.y() * BM * N + BlockIdx.x() * BN
    alias c_gmem_layout = Layout(IntTuple(BM, BN), IntTuple(N, 1))
    var c_gmem_tile = LayoutTensor[c_type, c_gmem_layout](
        c.offset(Int(c_offset))
    )
    var c_gmem_warp_tile = c_gmem_tile.tile[WM, WN](warp_y, warp_x)

    # Copy results to global memory.
    # Vectorize by [simd_size, simd_size] because the outer product results are
    # implicitly organized by simd_size x simd_size tiles.

    @parameter
    if elementwise_lambda_fn:
        var c_gmem_frag = c_gmem_warp_tile.vectorize[
            simd_size, simd_size
        ]().distribute[thread_layout](ThreadIdx.x())

        alias epilogue = elementwise_lambda_fn.value()

        apply_epilogue[
            epilogue, c_gmem_frag.layout, c_gmem_frag.element_layout
        ](
            c_reg.vectorize[simd_size, simd_size](),
            c_gmem_frag.distance(c),
        )

    else:
        copy_local_to_dram[dst_thread_layout=thread_layout](
            c_gmem_warp_tile.vectorize[simd_size, simd_size](),
            c_reg.vectorize[simd_size, simd_size](),
        )


fn matmul_kernel_naive[
    c_type: DType,
    a_type: DType,
    b_type: DType,
    BLOCK_DIM: Int,
    transpose_b: Bool = False,
    elementwise_lambda_fn: OptionalReg[elementwise_epilogue_type] = None,
    s_type: DType = get_accum_type[c_type](),
](
    c_ptr: UnsafePointer[Scalar[c_type]],
    a_ptr: UnsafePointer[Scalar[a_type]],
    b_ptr: UnsafePointer[Scalar[b_type]],
    m: Int,
    n: Int,
    k: Int,
):
    var x = BlockIdx.x() * BlockDim.x() + ThreadIdx.x()
    var y = BlockIdx.y() * BlockDim.y() + ThreadIdx.y()

    if x >= m or y >= n:
        return

    var a = NDBuffer[a_type, 2](a_ptr, Index(m, k))
    var accum = SIMD[s_type, 1]()

    @parameter
    if transpose_b:
        var b = NDBuffer[b_type, 2](b_ptr, Index(n, k))
        for i in range(k):
            accum = a[x, i].cast[s_type]() * b[y, i].cast[s_type]() + accum

    else:
        var b = NDBuffer[b_type, 2](b_ptr, Index(k, n))
        for i in range(k):
            accum = a[x, i].cast[s_type]() * b[i, y].cast[s_type]() + accum

    var c = NDBuffer[c_type, 2](c_ptr, Index(m, n))

    @parameter
    if elementwise_lambda_fn:
        alias elementwise_lambda = elementwise_lambda_fn.value()
        elementwise_lambda[c_type, 1](Index(x, y), accum.cast[c_type]())
    else:
        c[Index(x, y)] = accum.cast[c_type]()


@always_inline
fn _matmul_gpu[
    use_tensor_core: Bool = False,
    transpose_b: Bool = False,
    elementwise_lambda_fn: OptionalReg[elementwise_epilogue_type] = None,
    single_thread_blocking_override: Bool = False,
](
    c: NDBuffer[_, 2, _],
    a: NDBuffer[_, 2, _],
    b: NDBuffer[_, 2, _],
    ctx: DeviceContext,
    experimental: Bool = False,
):
    # HACK HACK HACK https://github.com/modularml/modular/issues/22959
    # single_thread_blocking_override should not be allowed, but the graph
    # compiler has a special case that does not insert the
    # on the GPU
    # constrained[
    #     not single_thread_blocking_override,
    #     "single_thread_blocking_override not applicable",
    # ]()

    var shape = GemmShape.get[transpose_b=False](c, a, b)
    var m = shape.M
    var n = shape.N
    var k = shape.K

    @parameter
    if elementwise_lambda_fn:
        _matmul_gpu_dispatch[
            a.type,
            a.shape,
            b.type,
            b.shape,
            c.type,
            c.shape,
            transpose_b=transpose_b,
            use_tensor_core=use_tensor_core,
            elementwise_lambda_fn=elementwise_lambda_fn,
        ](c, a, b, ctx, experimental)

    else:
        _matmul_gpu_dispatch[
            a.type,
            a.shape,
            b.type,
            b.shape,
            c.type,
            c.shape,
            transpose_b=transpose_b,
            use_tensor_core=use_tensor_core,
        ](c, a, b, ctx, experimental)


@always_inline
fn _matmul_gpu_dispatch[
    a_type: DType,
    a_shape: DimList,
    b_type: DType,
    b_shape: DimList,
    c_type: DType,
    c_shape: DimList,
    transpose_b: Bool = False,
    use_tensor_core: Bool = False,
    elementwise_lambda_fn: OptionalReg[elementwise_epilogue_type] = None,
](
    c: NDBuffer[c_type, 2, c_shape],
    a: NDBuffer[a_type, 2, a_shape],
    b: NDBuffer[b_type, 2, b_shape],
    ctx: DeviceContext,
    experimental: Bool = False,
):
    var shape = GemmShape.get[transpose_b=False](c, a, b)
    var m = shape.M
    var n = shape.N
    var k = shape.K
    try:
        alias s_type = DType.float32 if (
            a_type == DType.bfloat16 or a_type == DType.float16
        ) else c_type

        # Currently sgemm_warp_tiling_kernel is supportred only for float32 and
        # no elementwise_epilogue, fallback to generic matmul_kernel.
        var warp_tiled_matmul_supported_shape = (
            m % 128 == 0 and n % 128 == 0 and k % 128 == 0
        )
        alias matmul_supported_format = (
            a_type in (DType.float32, DType.bfloat16)
            and b_type in (DType.float32, DType.bfloat16)
            and c_type in (DType.float32, DType.bfloat16)
        )
        alias buffer_matmul_supported_format = (
            a_type == DType.float32
            and b_type == DType.float32
            and c_type == DType.float32
        )
        var double_buffer_supported_cond = (
            m % 128 == 0 and n % 128 == 0 and k % 16 == 0 and k < m and k < n
        )

        # TODO: m is set to multiple of 128 (thread block tile) for now due to CI mismatches.
        var multi_gemm_cond = (
            (m % 128 == 0 or (m > 1 and experimental))
            and n % 128 == 0
            and k % 16 == 0
        )

        @parameter
        if (
            matmul_supported_format
            and use_tensor_core
            and b_shape.all_known[2]()
        ):
            if multi_gemm_cond:
                alias num_pipeline_stages = 4
                alias BM = 128
                alias BN = 128
                alias BK = 32 if a_type == DType.bfloat16 else 16
                alias WM = 64
                alias WN = 64
                alias shared_mem_bytes = 80 * 1024
                alias num_threads = (BM // WM) * (BN // WN) * WARP_SIZE

                alias mgemm = multistage_gemm[
                    c_type,
                    c_shape,
                    a_type,
                    a_shape,
                    b_type,
                    b_shape,
                    transpose_b,
                    BM,
                    BN,
                    BK,
                    WM,
                    WN,
                    num_threads,
                    num_pipeline_stages,
                    elementwise_lambda_fn,
                ]
                # TODO: The cache config doesn't really help here, see #38391.

                var multistage_func = ctx.compile_function[mgemm](
                    threads_per_block=num_threads,
                    func_attribute=FuncAttribute.MAX_DYNAMIC_SHARED_SIZE_BYTES(
                        shared_mem_bytes
                    ),
                )
                ctx.enqueue_function(
                    multistage_func,
                    c,
                    a,
                    b,
                    grid_dim=(ceildiv(n, BN), ceildiv(m, BM), 1),
                    block_dim=(num_threads, 1, 1),
                    shared_mem_bytes=shared_mem_bytes,
                )
                return

        # Dispatch bouble buffer gemm for FP32, constant B, and certain shapes.
        @parameter
        if buffer_matmul_supported_format and b_shape.all_known[2]():
            if double_buffer_supported_cond:
                # TODO: Add shape constraints for K << M and K << N.
                alias NUM_THREADS = 256
                alias K = b_shape.get[0]()
                alias N = b_shape.get[1]()
                alias BM = 128
                alias BN = 128
                alias BK = 16
                alias WM = 32
                alias WN = 64
                alias TM = 8
                alias TN = 8
                alias b_layout = Layout.row_major(K, N)

                var b_tsr = LayoutTensor[b_type, b_layout](b.data)

                alias dbuffgemm = sgemm_double_buffer_kernel[
                    c_type,
                    a_type,
                    b_type,
                    b_layout,
                    BM,
                    BN,
                    BK,
                    WM,
                    WN,
                    TM,
                    TN,
                    NUM_THREADS,
                    elementwise_lambda_fn=elementwise_lambda_fn,
                ]
                var gpu_func = ctx.compile_function[dbuffgemm](
                    threads_per_block=NUM_THREADS
                )
                ctx.enqueue_function(
                    gpu_func,
                    m,
                    c.data,
                    a.data,
                    b_tsr,
                    grid_dim=(ceildiv(n, BN), ceildiv(m, BM), 1),
                    block_dim=(NUM_THREADS, 1, 1),
                )
                return

        if warp_tiled_matmul_supported_shape and buffer_matmul_supported_format:
            # TODO: Auto tune these for A100.
            # TODO: NUM_THREADS need to vary as M, N varies.
            alias NUM_THREADS = 128
            alias BN = 128
            alias BM = 128
            alias BK = 16
            alias WN = 64
            alias WM = 64
            alias WNITER = 4
            alias TN = 4
            alias TM = 8
            alias WMITER = (WM * WN) // (WARP_SIZE * TM * TN * WNITER)
            alias mm = sgemm_warp_tiling_kernel[
                c_type,
                c_shape,
                a_type,
                a_shape,
                b_type,
                b_shape,
                BM=BM,
                BN=BN,
                BK=BK,
                WM=WM,
                WN=WN,
                WMITER=WMITER,
                WNITER=WNITER,
                TM=TM,
                TN=TN,
                NUM_THREADS=NUM_THREADS,
                elementwise_lambda_fn=elementwise_lambda_fn,
            ]
            var gpu_func = ctx.compile_function[mm](
                threads_per_block=NUM_THREADS
            )
            ctx.enqueue_function(
                gpu_func,
                c,
                a,
                b,
                Scalar[c_type](1),
                Scalar[c_type](0),
                grid_dim=(ceildiv(n, BN), ceildiv(m, BM)),
                block_dim=(NUM_THREADS),
            )
        elif n == 1:

            @parameter
            if a_type == DType.bfloat16:
                alias WARPS_PER_BLOCK = 32
                alias simd_width = simdwidthof[
                    DType.bfloat16, target = _get_nvptx_target()
                ]()
                if k % simd_width == 0:
                    var block_dim = min(
                        align_up(k // simd_width, WARP_SIZE),
                        WARP_SIZE * WARPS_PER_BLOCK,
                    )
                    var gpu_func = ctx.compile_function[
                        gemv_tc_kernel_vector[
                            c_type,
                            a_type,
                            b_type,
                            simd_width,
                            elementwise_lambda_fn=elementwise_lambda_fn,
                        ]
                    ]()
                    ctx.enqueue_function(
                        gpu_func,
                        c,
                        a,
                        b,
                        m,
                        n,
                        k,
                        grid_dim=ceildiv(m, block_dim // WARP_SIZE),
                        block_dim=block_dim,
                    )
                else:
                    alias WARPS_PER_BLOCK = 32
                    var gpu_func = ctx.compile_function[
                        gemv_tc_kernel[
                            c_type,
                            a_type,
                            b_type,
                            elementwise_lambda_fn=elementwise_lambda_fn,
                        ]
                    ]()
                    ctx.enqueue_function(
                        gpu_func,
                        c.data,
                        a.data,
                        b.data,
                        m,
                        n,
                        k,
                        grid_dim=ceildiv(m, WARPS_PER_BLOCK),
                        block_dim=WARP_SIZE * WARPS_PER_BLOCK,
                    )
            else:
                alias WARPS_PER_BLOCK = 32
                var gpu_func = ctx.compile_function[
                    gemv_kernel[
                        c_type,
                        a_type,
                        b_type,
                        elementwise_lambda_fn=elementwise_lambda_fn,
                    ]
                ]()
                ctx.enqueue_function(
                    gpu_func,
                    c.data,
                    a.data,
                    b.data,
                    m,
                    n,
                    k,
                    grid_dim=ceildiv(m, WARPS_PER_BLOCK),
                    block_dim=WARP_SIZE * WARPS_PER_BLOCK,
                )
        elif m == 1 and n % WARP_SIZE == 0 and k % WARP_SIZE == 0:

            @parameter
            if a_type == DType.bfloat16:
                alias simd_width = simdwidthof[
                    DType.bfloat16, target = _get_nvptx_target()
                ]()
                alias max_warps_per_block = 32

                if (
                    k >= 4096
                    and n >= 4096
                    and k % simd_width == 0
                    and n % simd_width == 0
                ):
                    var gpu_func = ctx.compile_function[
                        gevm_tc_kernel_vector_8x[
                            c_type,
                            a_type,
                            b_type,
                            WARP_SIZE * max_warps_per_block * simd_width,
                            simd_width,
                            elementwise_lambda_fn=elementwise_lambda_fn,
                        ]
                    ]()
                    ctx.enqueue_function(
                        gpu_func,
                        c,
                        a,
                        b,
                        m,
                        n,
                        k,
                        grid_dim=ceildiv(n, WARP_SIZE * simd_width),
                        block_dim=WARP_SIZE * max_warps_per_block,
                    )
                else:
                    alias WARPS_PER_BLOCK = 32
                    var gpu_func = ctx.compile_function[
                        gevm_kernel[
                            c_type,
                            a_type,
                            b_type,
                            WARP_SIZE * WARPS_PER_BLOCK,
                            elementwise_lambda_fn=elementwise_lambda_fn,
                        ]
                    ]()
                    ctx.enqueue_function(
                        gpu_func,
                        c.data,
                        a.data,
                        b.data,
                        m,
                        n,
                        k,
                        grid_dim=ceildiv(n, WARPS_PER_BLOCK),
                        block_dim=WARP_SIZE * WARPS_PER_BLOCK,
                    )
            else:
                alias WARPS_PER_BLOCK = 32
                var gpu_func = ctx.compile_function[
                    gevm_kernel[
                        c_type,
                        a_type,
                        b_type,
                        WARP_SIZE * WARPS_PER_BLOCK,
                        elementwise_lambda_fn=elementwise_lambda_fn,
                    ]
                ]()
                ctx.enqueue_function(
                    gpu_func,
                    c.data,
                    a.data,
                    b.data,
                    m,
                    n,
                    k,
                    grid_dim=ceildiv(n, WARPS_PER_BLOCK),
                    block_dim=WARP_SIZE * WARPS_PER_BLOCK,
                )
        else:
            # Tile size for tiling in shared memory.
            # Thread block would have shape (tile_size, tile_size, 1)
            # If k < tile_size use naive version.
            alias tile_size = 16
            if k >= tile_size:
                var gpu_func = ctx.compile_function[
                    matmul_kernel[
                        c_type,
                        a_type,
                        b_type,
                        tile_size,
                        elementwise_lambda_fn=elementwise_lambda_fn,
                    ]
                ]()
                ctx.enqueue_function(
                    gpu_func,
                    c.data,
                    a.data,
                    b.data,
                    m,
                    n,
                    k,
                    grid_dim=(ceildiv(n, tile_size), ceildiv(m, tile_size)),
                    block_dim=(tile_size, tile_size),
                )
            else:
                alias BLOCK_DIM = 16
                var gpu_func = ctx.compile_function[
                    matmul_kernel_naive[
                        a_type,
                        b_type,
                        c_type,
                        BLOCK_DIM,
                        elementwise_lambda_fn=elementwise_lambda_fn,
                    ]
                ]()
                ctx.enqueue_function(
                    gpu_func,
                    c.data,
                    a.data,
                    b.data,
                    m,
                    n,
                    k,
                    grid_dim=(ceildiv(m, BLOCK_DIM), ceildiv(n, BLOCK_DIM)),
                    block_dim=(BLOCK_DIM, BLOCK_DIM),
                )
    except e:
        abort(e)
