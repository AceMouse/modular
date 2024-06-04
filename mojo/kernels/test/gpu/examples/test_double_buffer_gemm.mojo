# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo-no-debug %s

from math import ceildiv, isclose
from sys import argv

from buffer import NDBuffer
from buffer.list import DimList
from gpu import WARP_SIZE, BlockIdx, ThreadIdx, barrier, lane_id
from gpu.host import Context, CudaInstance, Device, Function, Stream
from gpu.host.event import time_function
from gpu.memory import async_copy_wait_all
from layout.int_tuple import IntTuple
from layout.layout import *
from layout.layout_tensor import (
    LayoutTensor,
    copy_dram_to_sram_async,
    copy_local_to_dram,
    copy_sram_to_local,
    outer_product_acc,
)
from LinAlg.MatmulGPU import matmul_kernel_naive
from memory.reference import _GPUAddressSpace as AddressSpace
from memory.unsafe import DTypePointer
from testing import assert_almost_equal

from utils import InlineArray, unroll


fn is_benchmark() -> Bool:
    for arg in argv():
        if arg == "--benchmark" or arg == "-benchmark":
            return True
    return False


fn sgemm_double_buffer[
    c_type: DType,
    c_layout: Layout,
    a_type: DType,
    a_layout: Layout,
    b_type: DType,
    b_layout: Layout,
    itype: DType,
    BM: Int,
    BN: Int,
    BK: Int,
    WM: Int,
    WN: Int,
    TM: Int,
    TN: Int,
    NUM_THREADS: Int,
](
    c: LayoutTensor[c_type, c_layout],
    a: LayoutTensor[a_type, a_layout],
    b: LayoutTensor[b_type, b_layout],
):
    alias _uint = Scalar[itype]

    alias simd_size = simdwidthof[c_type]()

    var M = c.dim[0]()
    var N = c.dim[1]()
    var K = a.dim[1]()

    alias num_warps_m = BM // WM
    alias num_warps_n = BN // WN

    var tid = ThreadIdx.x()
    var warp_id = tid // WARP_SIZE
    var lane_id = tid % WARP_SIZE

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
    var a_gmem_tile = a.tile[BM, BK](BlockIdx.y(), 0)
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
    a_gmem_tile = a.tile[BM, BK](BlockIdx.y(), 1)
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
            var buffer_id = k % 2
            var next_buffer_id = (k + 1) % 2

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
                a_gmem_tile = a.tile[BM, BK](BlockIdx.y(), k_tile_id + 1)
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
    var c_gmem_tile = c.tile[BM, BN](BlockIdx.y(), BlockIdx.x())
    var c_gmem_warp_tile = c_gmem_tile.tile[WM, WN](warp_y, warp_x)
    # Copy results to global memory.
    # Vectorize by [simd_size, simd_size] because the outer product results are
    # implicitly organized by simd_size x simd_size tiles.
    copy_local_to_dram[dst_thread_layout=thread_layout](
        c_gmem_warp_tile.vectorize[simd_size, simd_size](),
        c_reg.vectorize[simd_size, simd_size](),
    )


fn test(ctx: Context) raises:
    alias NUM_THREADS = 256
    alias M = 8192
    alias N = 8192
    alias K = 128
    alias BM = 128
    alias BN = 128
    alias BK = 16
    alias WM = 32
    alias WN = 64
    alias TM = 8
    alias TN = 8

    var stream = Stream(ctx)

    alias a_layout = Layout(IntTuple(M, K), IntTuple(K, 1))
    alias b_layout = Layout(IntTuple(K, N), IntTuple(N, 1))
    alias c_layout = Layout(IntTuple(M, N), IntTuple(N, 1))

    var a_host = DTypePointer[DType.float32].alloc(M * K)
    var b_host = DTypePointer[DType.float32].alloc(K * N)
    var c_host = DTypePointer[DType.float32].alloc(M * N)
    var c_host_ref = DTypePointer[DType.float32].alloc(M * N)

    for i in range(M * K):
        a_host[i] = i

    for i in range(K * N):
        b_host[i] = i

    var a_device = ctx.malloc[Float32](M * K)
    var b_device = ctx.malloc[Float32](K * N)
    var c_device = ctx.malloc[Float32](M * N)
    var c_device_ref = ctx.malloc[Float32](M * N)

    ctx.copy_host_to_device(a_device, a_host, M * K)
    ctx.copy_host_to_device(b_device, b_host, K * N)

    var c_buffer = NDBuffer[DType.float32, 2, DimList(M, N)](c_device)
    var a_buffer = NDBuffer[DType.float32, 2, DimList(M, K)](a_device)
    var b_buffer = NDBuffer[DType.float32, 2, DimList(K, N)](b_device)

    var c_tensor = LayoutTensor[DType.float32, c_layout](c_device)
    var a_tensor = LayoutTensor[DType.float32, a_layout](a_device)
    var b_tensor = LayoutTensor[DType.float32, b_layout](b_device)

    alias gemm = sgemm_double_buffer[
        DType.float32,
        c_layout,
        DType.float32,
        a_layout,
        DType.float32,
        b_layout,
        DType.uint32,
        BM,
        BN,
        BK,
        WM,
        WN,
        TM,
        TN,
        NUM_THREADS,
    ]
    var func = Function[gemm](ctx, threads_per_block=NUM_THREADS)

    if is_benchmark():
        alias nrun = 200
        alias nwarmup = 2

        @always_inline
        @parameter
        fn run_func(stream: Stream) raises:
            for i in range(nrun):
                func(
                    c_tensor,
                    a_tensor,
                    b_tensor,
                    grid_dim=(ceildiv(N, BN), ceildiv(M, BM), 1),
                    block_dim=(NUM_THREADS, 1, 1),
                    stream=stream,
                )

        # Warmup
        for i in range(nwarmup):
            run_func(stream)

        var nstime = time_function[run_func](stream) / nrun
        var sectime = nstime * 1e-9
        var TFlop = 2.0 * M * N * K * 1e-12
        print(nrun, "runs avg(s)", sectime, "TFlops/s", TFlop / sectime)

    func(
        c_tensor,
        a_tensor,
        b_tensor,
        grid_dim=(ceildiv(N, BN), ceildiv(M, BM), 1),
        block_dim=(NUM_THREADS, 1, 1),
        stream=stream,
    )

    ctx.synchronize()

    ctx.copy_device_to_host(c_host, c_device, M * N)

    # Naive gemm.
    alias BLOCK_DIM = 16
    alias gemm_naive = matmul_kernel_naive[
        DType.float32, DType.float32, DType.float32, BLOCK_DIM
    ]
    var func_naive = Function[gemm_naive](ctx, threads_per_block=NUM_THREADS)
    var c_buffer_ref = NDBuffer[DType.float32, 2, DimList(M, N)](c_device_ref)
    func_naive(
        c_buffer_ref,
        a_buffer,
        b_buffer,
        M,
        N,
        K,
        grid_dim=(ceildiv(M, BLOCK_DIM), ceildiv(N, BLOCK_DIM), 1),
        block_dim=(BLOCK_DIM, BLOCK_DIM, 1),
    )

    ctx.synchronize()
    ctx.copy_device_to_host(c_host_ref, c_device_ref, M * N)

    for i in range(M * N):
        if not isclose(c_host[i], c_host_ref[i]):
            print(i, c_host[i], c_host_ref[i])
        assert_almost_equal(c_host[i], c_host_ref[i])

    ctx.free(c_device)
    ctx.free(c_device_ref)
    ctx.free(a_device)
    ctx.free(b_device)

    c_host.free()
    c_host_ref.free()
    a_host.free()
    b_host.free()

    _ = func^
    _ = func_naive^
    _ = stream^


def main():
    try:
        with CudaInstance() as instance:
            with Context(Device(instance)) as ctx:
                test(ctx)
    except e:
        print("ERROR:", e)
