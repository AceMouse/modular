# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo %s | FileCheck %s

from math import ceildiv
from pathlib import Path

from gpu import AddressSpace, barrier
from gpu.host import DeviceContext
from gpu.id import BlockIdx, ThreadIdx
from gpu.memory import (
    async_copy_commit_group,
    async_copy_wait_all,
    async_copy_wait_group,
)
from layout import *
from layout._utils import ManagedLayoutTensor, gpu_free, gpu_managed_alloc
from layout.layout_tensor import (
    LayoutTensor,
    copy_dram_to_sram_async,
    copy_sram_to_dram,
)
from layout.swizzle import Swizzle
from memory import UnsafePointer
from testing import assert_almost_equal


fn async_copy_kernel[
    input_layout: Layout,
    BM: Int,
    BN: Int,
](input: LayoutTensor[DType.float32, input_layout]):
    var input_tile = input.tile[BM, BN](BlockIdx.y(), BlockIdx.x())

    var smem_tile = LayoutTensor[
        DType.float32,
        Layout(IntTuple(BM, BN)),
        address_space = AddressSpace.SHARED,
    ].stack_allocation()

    smem_tile.copy_from_async(input_tile)
    async_copy_wait_all()

    var tx = ThreadIdx.x()
    var ty = ThreadIdx.y()
    smem_tile[tx, ty] += ty

    input_tile.copy_from(smem_tile)


fn test_async_copy(ctx: DeviceContext) raises:
    print("=== test_async_copy")
    # Matrix dimension
    alias M = 6
    alias N = 6
    # Block dimension
    alias BM = 2
    alias BN = 3

    alias input_layout = Layout(IntTuple(M, N), IntTuple(N, 1))
    var input = ManagedLayoutTensor[
        DType.float32, input_layout, gpu_managed_alloc, gpu_free
    ]()

    input.tensor.linspace()

    alias kernel_type = async_copy_kernel[input_layout, BM, BN]

    var kernel = ctx.compile_function[kernel_type]()

    ctx.enqueue_function(
        kernel,
        input,
        grid_dim=(M // BM, N // BN),
        block_dim=(BM, BN),
    )

    ctx.synchronize()
    print(input.tensor)

    _ = input^


fn multistage_copy[
    type: DType,
    a_layout: Layout,
    b_layout: Layout,
    BM: Int,
    BK: Int,
    num_threads: Int,
    num_pipeline_stages: Int,
](a: LayoutTensor[type, a_layout], b: LayoutTensor[type, b_layout]):
    constrained[num_pipeline_stages >= 2, "Require at least 2 stages."]()

    alias simd_size = simdwidthof[type]()

    var M = a.dim[0]()
    var K = a.dim[1]()

    # Double buffer in shared memory.
    var a_smem_tiles = LayoutTensor[
        type,
        Layout.row_major((num_pipeline_stages - 1) * BM, BK),
        address_space = AddressSpace.SHARED,
    ].stack_allocation().split[num_pipeline_stages - 1]()

    alias thread_layout = Layout.row_major(
        num_threads * simd_size // BK, BK // simd_size
    )

    # Prefetch (num_pipeline_stages - 1) stages.
    @parameter
    for stage in range(num_pipeline_stages - 1):
        copy_dram_to_sram_async[
            src_thread_layout=thread_layout,
            dst_thread_layout=thread_layout,
        ](
            a_smem_tiles[stage].vectorize[1, simd_size](),
            a.tile[BM, BK](BlockIdx.x(), stage).vectorize[1, simd_size](),
        )

        async_copy_commit_group()

    # Guard stage 0.
    async_copy_wait_group(num_pipeline_stages - 2)
    barrier()

    var num_k_tiles = ceildiv(K, BK)

    for k_tile_id in range(num_k_tiles):
        var stage = k_tile_id % (num_pipeline_stages - 1)

        # Write current stage to global memory.
        var b_gmem_tile = b.tile[BM, BK](BlockIdx.x(), k_tile_id)
        var b_gmem_frag = b_gmem_tile.vectorize[1, simd_size]().distribute[
            thread_layout
        ](ThreadIdx.x())
        var a_smem_frag = a_smem_tiles[stage].vectorize[
            1, simd_size
        ]().distribute[thread_layout](ThreadIdx.x())
        b_gmem_frag.copy_from(a_smem_frag)

        # Prefetch stage $(current + num_pipeline_stages - 1)
        # When the prefetch goes OOB, Cutlass sets src_in_bytes to 0 and does
        # zero fill (zfill) for dst. We circulate the global address for now
        # because llvm instrinsic doesn't have src_in_bytes.
        var prefetch_tile_id = k_tile_id + num_pipeline_stages - 1
        var prefetch_stage = prefetch_tile_id % (num_pipeline_stages - 1)

        copy_dram_to_sram_async[
            src_thread_layout=thread_layout,
            dst_thread_layout=thread_layout,
        ](
            a_smem_tiles[prefetch_stage].vectorize[1, simd_size](),
            a.tile[BM, BK](
                BlockIdx.x(), prefetch_tile_id % num_k_tiles
            ).vectorize[1, simd_size](),
        )

        async_copy_commit_group()

        async_copy_wait_group(num_pipeline_stages - 2)
        barrier()


fn test_multistage_copy(ctx: DeviceContext) raises:
    print("=== test_multistage_copy")
    alias num_threads = 256
    alias num_pipeline_stages = 4
    alias M = 128
    alias K = 128
    alias BM = 128
    alias BK = 16

    constrained[
        K // BK >= num_pipeline_stages,
        "Require more k tiles than pipeline stages.",
    ]()

    alias a_layout = Layout.row_major(M, K)
    alias b_layout = Layout.row_major(M, K)

    var a_host = UnsafePointer[Float32].alloc(M * K)
    var b_host = UnsafePointer[Float32].alloc(M * K)

    for i in range(M * K):
        a_host[i] = i
        b_host[i] = 0

    var a_device = ctx.create_buffer[DType.float32](M * K)
    var b_device = ctx.create_buffer[DType.float32](M * K)

    ctx.enqueue_copy_to_device(a_device, a_host)

    var a_tensor = LayoutTensor[DType.float32, a_layout](a_device.ptr)
    var b_tensor = LayoutTensor[DType.float32, b_layout](b_device.ptr)

    alias copy = multistage_copy[
        DType.float32,
        a_layout,
        b_layout,
        BM,
        BK,
        num_threads,
        num_pipeline_stages,
    ]
    var func = ctx.compile_function[copy](threads_per_block=num_threads)

    ctx.enqueue_function(
        func,
        a_tensor,
        b_tensor,
        grid_dim=(ceildiv(M, BM), 1, 1),
        block_dim=(num_threads, 1, 1),
    )

    ctx.synchronize()

    ctx.enqueue_copy_from_device(b_host, b_device)

    for i in range(M * K):
        assert_almost_equal(a_host[i], b_host[i])

    _ = a_device
    _ = b_device

    a_host.free()
    b_host.free()


fn swizzle_copy[
    type: DType,
    a_layout: Layout,
    b_layout: Layout,
    BM: Int,
    BK: Int,
    num_threads: Int,
](a: LayoutTensor[type, a_layout], b: LayoutTensor[type, b_layout]):
    alias simd_size = simdwidthof[type]()

    var M = a.dim[0]()
    var K = a.dim[1]()

    # Double buffer in shared memory.
    var a_smem_tile = LayoutTensor[
        type,
        Layout.row_major(BM, BK),
        address_space = AddressSpace.SHARED,
    ].stack_allocation()

    alias thread_layout = Layout.row_major(
        num_threads * simd_size // BK, BK // simd_size
    )

    # Mask ^ tid's 2 least significant and every 8 threads share one mask.
    # This reproduces the thread map in Cutlass when BK=16.
    @always_inline
    fn xor_2bits_per8T[type: DType](tid: Scalar[type]) -> Scalar[type]:
        return Swizzle[2, 0, 3]()(tid)

    copy_dram_to_sram_async[
        src_thread_layout=thread_layout,
        dst_thread_layout=thread_layout,
        swizzle=xor_2bits_per8T,
    ](
        a_smem_tile.vectorize[1, simd_size](),
        a.tile[BM, BK](BlockIdx.x(), 0).vectorize[1, simd_size](),
    )

    async_copy_wait_all()
    barrier()

    # Write current stage to global memory.
    var b_gmem_tile = b.tile[BM, BK](BlockIdx.x(), 0)
    var b_gmem_frag = b_gmem_tile.vectorize[1, simd_size]().distribute[
        thread_layout
    ](ThreadIdx.x())
    var a_smem_frag = a_smem_tile.vectorize[1, simd_size]().distribute[
        thread_layout
    ](ThreadIdx.x())
    b_gmem_frag.copy_from(a_smem_frag)


fn test_swizzle_copy(ctx: DeviceContext) raises:
    print("=== test_swizzle_copy")
    alias num_threads = 32
    alias M = 8
    alias K = 16
    alias BM = 8
    alias BK = 16

    alias a_layout = Layout.row_major(M, K)
    alias b_layout = Layout.row_major(M, K)

    var a_host = UnsafePointer[Float32].alloc(M * K)
    var b_host = UnsafePointer[Float32].alloc(M * K)

    for i in range(M * K):
        a_host[i] = i
        b_host[i] = 0

    var a_device = ctx.create_buffer[DType.float32](M * K)
    var b_device = ctx.create_buffer[DType.float32](M * K)

    ctx.enqueue_copy_to_device(a_device, a_host)

    var a_tensor = LayoutTensor[DType.float32, a_layout](a_device.ptr)
    var b_tensor = LayoutTensor[DType.float32, b_layout](b_device.ptr)

    alias copy = swizzle_copy[
        DType.float32,
        a_layout,
        b_layout,
        BM,
        BK,
        num_threads,
    ]
    var func = ctx.compile_function[copy](threads_per_block=num_threads)

    ctx.enqueue_function(
        func,
        a_tensor,
        b_tensor,
        grid_dim=(ceildiv(M, BM), 1, 1),
        block_dim=(num_threads, 1, 1),
    )

    ctx.synchronize()

    ctx.enqueue_copy_from_device(b_host, b_device)

    for m in range(M):
        for k in range(K):
            print(b_host[m * K + k], end=" ")
        print()

    _ = a_device
    _ = b_device

    a_host.free()
    b_host.free()


fn test_masked_async_copy(ctx: DeviceContext) raises:
    print("=== test_masked_async_copy")

    alias M = 8
    alias N = 8
    alias num_rows = 7
    # alias num_threads = thread_layout.size()

    var input = ManagedLayoutTensor[
        DType.float32, Layout.row_major(M, N), gpu_managed_alloc, gpu_free
    ]()

    input.tensor.linspace()

    @always_inline
    fn masked_copy_kernel[
        layout: Layout
    ](input: LayoutTensor[DType.float32, layout]):
        alias thread_layout = Layout.row_major(4, 2)

        var smem_tile = LayoutTensor[
            DType.float32, layout, address_space = AddressSpace.SHARED
        ].stack_allocation().fill(-1.0)

        copy_dram_to_sram_async[thread_layout=thread_layout, masked=True](
            smem_tile.vectorize[1, 4](), input.vectorize[1, 4](), num_rows
        )

        async_copy_commit_group()
        async_copy_wait_all()

        copy_sram_to_dram[thread_layout=thread_layout](
            input.vectorize[1, 4]().bitcast[
                DType.float32, address_space = AddressSpace.GENERIC
            ](),
            smem_tile.vectorize[1, 4](),
        )

    alias kernel_type = masked_copy_kernel[Layout.row_major(M, N)]
    var kernel = ctx.compile_function[kernel_type]()

    ctx.enqueue_function(
        kernel,
        input,
        grid_dim=(1,),
        block_dim=(8,),
    )

    ctx.synchronize()
    print(input.tensor)

    _ = input^


fn main() raises:
    with DeviceContext() as ctx:
        # CHECK: === test_async_copy
        # CHECK: 0.0   2.0   4.0   3.0   5.0   7.0
        # CHECK: 6.0   8.0   10.0   9.0   11.0   13.0
        # CHECK: 12.0   14.0   16.0   15.0   17.0   19.0
        # CHECK: 18.0   20.0   22.0   21.0   23.0   25.0
        # CHECK: 24.0   26.0   28.0   27.0   28.0   29.0
        # CHECK: 30.0   31.0   32.0   33.0   34.0   35.0
        test_async_copy(ctx)

        # CHECK: === test_multistage_copy
        test_multistage_copy(ctx)

        # CHECK: === test_swizzle_copy
        # CHECK: 0.0 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0 11.0 12.0 13.0 14.0 15.0
        # CHECK: 16.0 17.0 18.0 19.0 20.0 21.0 22.0 23.0 24.0 25.0 26.0 27.0 28.0 29.0 30.0 31.0
        # CHECK: 36.0 37.0 38.0 39.0 32.0 33.0 34.0 35.0 44.0 45.0 46.0 47.0 40.0 41.0 42.0 43.0
        # CHECK: 52.0 53.0 54.0 55.0 48.0 49.0 50.0 51.0 60.0 61.0 62.0 63.0 56.0 57.0 58.0 59.0
        # CHECK: 72.0 73.0 74.0 75.0 76.0 77.0 78.0 79.0 64.0 65.0 66.0 67.0 68.0 69.0 70.0 71.0
        # CHECK: 88.0 89.0 90.0 91.0 92.0 93.0 94.0 95.0 80.0 81.0 82.0 83.0 84.0 85.0 86.0 87.0
        # CHECK: 108.0 109.0 110.0 111.0 104.0 105.0 106.0 107.0 100.0 101.0 102.0 103.0 96.0 97.0 98.0 99.0
        # CHECK: 124.0 125.0 126.0 127.0 120.0 121.0 122.0 123.0 116.0 117.0 118.0 119.0 112.0 113.0 114.0 115.0
        test_swizzle_copy(ctx)

        # CHECK: === test_masked_async_copy
        # CHECK: 0.0 1.0 2.0 3.0 4.0 5.0 6.0 7.0
        # CHECK: 8.0 9.0 10.0 11.0 12.0 13.0 14.0 15.0
        # CHECK: 16.0 17.0 18.0 19.0 20.0 21.0 22.0 23.0
        # CHECK: 24.0 25.0 26.0 27.0 28.0 29.0 30.0 31.0
        # CHECK: 32.0 33.0 34.0 35.0 36.0 37.0 38.0 39.0
        # CHECK: 40.0 41.0 42.0 43.0 44.0 45.0 46.0 47.0
        # CHECK: 48.0 49.0 50.0 51.0 52.0 53.0 54.0 55.0
        # CHECK: 0.0 0.0 0.0 0.0 0.0 0.0 0.0 0.0
        test_masked_async_copy(ctx)
