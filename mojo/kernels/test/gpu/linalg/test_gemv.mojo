# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo-no-debug %s | FileCheck %s

from math import ceildiv
from random import randn, seed

from buffer import NDBuffer
from gpu import WARP_SIZE
from gpu.host import DeviceContext
from linalg.gemv import (
    gemv_kernel,
    gevm_kernel,
    ReductionMethod,
)
from linalg.matmul_gpu import matmul_kernel, matmul_kernel_naive
from memory import UnsafePointer

from utils import StaticIntTuple
from utils.index import Index
from utils.numerics import isnan


fn run_matvec[
    reduction_method: ReductionMethod
](M: Int, N: Int, K: Int, *, ctx: DeviceContext) raises:
    print("== run_matvec kernel")

    var iterations = 100
    var a_host = UnsafePointer[Float32].alloc(M * K)
    var b_host = UnsafePointer[Float32].alloc(K * N)
    var c_host = UnsafePointer[Float32].alloc(M * N)
    var c_host_naive = UnsafePointer[Float32].alloc(M * N)

    for i in range(M * K):
        a_host[i] = i

    for i in range(K * N):
        b_host[i] = i + 1

    for i in range(M * N):
        c_host[i] = 0

    for i in range(M * N):
        c_host_naive[i] = 0

    var a_device = ctx.create_buffer[DType.float32](M * K)
    var b_device = ctx.create_buffer[DType.float32](K * N)
    var c_device = ctx.create_buffer[DType.float32](M * N)

    ctx.enqueue_copy_to_device(a_device, a_host)
    ctx.enqueue_copy_to_device(b_device, b_host)

    alias WARPS_PER_BLOCK = 32
    var func_gemv = ctx.compile_function[
        gemv_kernel[
            DType.float32,
            DType.float32,
            DType.float32,
            reduction_method=reduction_method,
        ]
    ]()

    var func_gevm = ctx.compile_function[
        gevm_kernel[
            DType.float32,
            DType.float32,
            DType.float32,
            tile_size = WARP_SIZE * WARPS_PER_BLOCK,
        ]
    ]()

    @always_inline
    @parameter
    fn run_func_gemv(ctx: DeviceContext) raises:
        ctx.enqueue_function(
            func_gemv,
            c_device,
            a_device,
            b_device,
            M,
            N,
            K,
            grid_dim=ceildiv(M, WARPS_PER_BLOCK),
            block_dim=WARP_SIZE * WARPS_PER_BLOCK,
        )

    @always_inline
    @parameter
    fn run_func_gevm(ctx: DeviceContext) raises:
        ctx.enqueue_function(
            func_gevm,
            c_device,
            a_device,
            b_device,
            M,
            N,
            K,
            grid_dim=ceildiv(N, WARPS_PER_BLOCK),
            block_dim=WARP_SIZE * WARPS_PER_BLOCK,
        )

    var nstime = 0.0
    var kernelType = ""
    if N == 1:
        nstime = ctx.execution_time[run_func_gemv](iterations)
        kernelType = "GEMV"
    elif M == 1:
        nstime = ctx.execution_time[run_func_gevm](iterations)
        kernelType = "GEVM"
    else:
        print("Incorrect input shape [MNK]")
        return
    var flops = 2 * M * N * K
    var sectime = ((nstime / iterations) / 1000000000)
    print(kernelType, "KERNEL:")
    print(sectime, "sec")
    print(flops * 1e-9 / sectime, " GFLOPS")
    print()

    ctx.enqueue_copy_from_device(c_host, c_device)

    # running naive
    ctx.enqueue_copy_to_device(a_device, a_host)
    ctx.enqueue_copy_to_device(b_device, b_host)

    alias BLOCK_DIM = 16
    var func_naive = ctx.compile_function[
        matmul_kernel[
            DType.float32,
            DType.float32,
            DType.float32,
            BLOCK_DIM,
        ]
    ]()

    @always_inline
    @parameter
    fn run_func_naive(ctx: DeviceContext) raises:
        ctx.enqueue_function(
            func_naive,
            c_device,
            a_device,
            b_device,
            M,
            N,
            K,
            grid_dim=(ceildiv(M, BLOCK_DIM), ceildiv(N, BLOCK_DIM)),
            block_dim=(BLOCK_DIM, BLOCK_DIM),
        )

    nstime = 0.0
    nstime = ctx.execution_time[run_func_naive](iterations)
    var sectime2 = ((nstime / iterations) / 1000000000)
    print("SHMEM MATMUL:")
    print(sectime2, "sec")
    print(flops * 1e-9 / sectime2, " GFLOPS")
    print()

    ctx.enqueue_copy_from_device(c_host_naive, c_device)

    # Due to varied pattern of FP32 arith the accumulated sum isn't exactly
    # accurate. Hence relative tolerance needs to be checked.
    alias errorTolerance = 0.0001
    var failed = False
    for i in range(M * N):
        var outVal = c_host[i]
        var outRef = c_host_naive[i]
        var relDiff = (max(outVal, outRef) / min(outVal, outRef)) - 1.0
        if (relDiff > errorTolerance) or isnan(outVal) or isnan(outRef):
            failed = True

    # CHECK: Success
    if not failed:
        print("Success 🎉: results match")
        print(
            "Performance warp-shuffle matvec vs. shmem matmul: ",
            sectime2 / sectime,
            "x",
        )
    else:
        print("Failed ❌: results mismatch")

    _ = a_device
    _ = b_device
    _ = c_device

    _ = a_host
    _ = b_host
    _ = c_host
    _ = c_host_naive

    _ = func_gemv^
    _ = func_gevm^
    _ = func_naive^


fn test_gevm_with_epilogue_fn[
    reduction_method: ReductionMethod
](M: Int, N: Int, K: Int, *, ctx: DeviceContext) raises:
    alias c_stride = 5
    alias seed_val = 42

    var iterations = 100
    var a_host = UnsafePointer[Float32].alloc(M * K)
    var b_host = UnsafePointer[Float32].alloc(K * N)

    seed(seed_val)

    # over-allocate C to simulate a view tensor
    var c_host = UnsafePointer[Float32].alloc(M * N * c_stride)
    var c_host_naive = UnsafePointer[Float32].alloc(M * N * c_stride)

    randn(a_host, M * K)

    randn(b_host, K * N)

    for i in range(M * N * c_stride):
        c_host[i] = 0

    for i in range(M * N * c_stride):
        c_host_naive[i] = 0

    var a_device = ctx.create_buffer[DType.float32](M * K)
    var b_device = ctx.create_buffer[DType.float32](K * N)
    var c_device = ctx.create_buffer[DType.float32](M * N * c_stride)

    var c_device_nd = NDBuffer[DType.float32, 2](
        c_device.ptr, Index(M, N), Index(N * c_stride, c_stride)
    )
    ctx.enqueue_copy_to_device(a_device, a_host)
    ctx.enqueue_copy_to_device(b_device, b_host)

    @parameter
    @always_inline
    @__copy_capture(c_device_nd)
    fn epilogue_fn[
        type: DType, width: Int
    ](idx: StaticIntTuple[2], val: SIMD[type, width]):
        c_device_nd.store[width=width](
            idx, rebind[SIMD[DType.float32, width]](val + 4.0)
        )

    alias WARPS_PER_BLOCK = 32
    var func_gemv = ctx.compile_function[
        gemv_kernel[
            DType.float32,
            DType.float32,
            DType.float32,
            reduction_method=reduction_method,
            elementwise_lambda_fn=epilogue_fn,
        ]
    ]()

    var func_gevm = ctx.compile_function[
        gevm_kernel[
            DType.float32,
            DType.float32,
            DType.float32,
            tile_size = WARP_SIZE * WARPS_PER_BLOCK,
            elementwise_lambda_fn=epilogue_fn,
        ]
    ]()

    @always_inline
    @parameter
    fn run_func_gemv(ctx: DeviceContext) raises:
        ctx.enqueue_function(
            func_gemv,
            c_device,
            a_device,
            b_device,
            M,
            N,
            K,
            grid_dim=ceildiv(M, WARPS_PER_BLOCK),
            block_dim=WARP_SIZE * WARPS_PER_BLOCK,
        )

    @always_inline
    @parameter
    fn run_func_gevm(ctx: DeviceContext) raises:
        ctx.enqueue_function(
            func_gevm,
            c_device,
            a_device,
            b_device,
            M,
            N,
            K,
            grid_dim=ceildiv(N, WARPS_PER_BLOCK),
            block_dim=WARP_SIZE * WARPS_PER_BLOCK,
        )

    ctx.enqueue_copy_to_device(c_device, c_host)

    var nstime = 0.0
    var kernelType = ""
    if N == 1:
        nstime = ctx.execution_time[run_func_gemv](iterations)
        kernelType = "GEMV"
    elif M == 1:
        nstime = ctx.execution_time[run_func_gevm](iterations)
        kernelType = "GEVM"
    else:
        print("Incorrect input shape [MNK]")
        return

    var flops = 2 * M * N * K
    var sectime = ((nstime / iterations) / 1000000000)

    print(kernelType, "KERNEL:")
    print(sectime, "sec")
    print(flops * 1e-9 / sectime, " GFLOPS")
    print()

    ctx.enqueue_copy_from_device(c_host, c_device)

    # running naive
    ctx.enqueue_copy_to_device(a_device, a_host)
    ctx.enqueue_copy_to_device(b_device, b_host)

    alias BLOCK_DIM = 16
    var func_naive = ctx.compile_function[
        matmul_kernel_naive[
            DType.float32,
            DType.float32,
            DType.float32,
            BLOCK_DIM,
            elementwise_lambda_fn=epilogue_fn,
        ]
    ]()

    @always_inline
    @parameter
    fn run_func_naive(ctx: DeviceContext) raises:
        ctx.enqueue_function(
            func_naive,
            c_device,
            a_device,
            b_device,
            M,
            N,
            K,
            grid_dim=(ceildiv(M, BLOCK_DIM), ceildiv(N, BLOCK_DIM)),
            block_dim=(BLOCK_DIM, BLOCK_DIM),
        )

    ctx.enqueue_copy_to_device(c_device, c_host_naive)

    nstime = ctx.execution_time[run_func_naive](iterations)
    var sectime2 = ((nstime / iterations) / 1000000000)
    print("NAIVE MATMUL:")
    print(sectime2, "sec")
    print(flops * 1e-9 / sectime2, " GFLOPS")
    print()

    ctx.enqueue_copy_from_device(c_host_naive, c_device)

    # Due to varied pattern of FP32 arith the accumulated sum isn't exactly
    # accurate. Hence relative tolerance needs to be checked.
    alias errorTolerance = 0.005
    var failed = False
    for i in range(M * N * c_stride):
        var outVal = c_host.load(i)
        var outRef = c_host_naive.load(i)
        var relDiff = (max(outVal, outRef) / min(outVal, outRef)) - 1.0
        if (relDiff > errorTolerance) or isnan(outVal) or isnan(outRef):
            print(i, relDiff, outVal, outRef)
            failed = True

    # CHECK: Success
    if not failed:
        print("Success 🎉: results match")
        print(
            "Performance warp-shuffle matvec vs. shmem matmul: ",
            sectime2 / sectime,
            "x",
        )
    else:
        print("Failed ❌: results mismatch")

    _ = a_device
    _ = b_device
    _ = c_device

    _ = a_host
    _ = b_host
    _ = c_host
    _ = c_host_naive

    _ = func_gevm^
    _ = func_gemv^
    _ = func_naive^


def main():
    with DeviceContext() as ctx:

        @parameter
        for i in range(2):
            alias reduction_method = List[ReductionMethod](
                ReductionMethod.WARP, ReductionMethod.TENSOR_CORE
            )[i]
            # gemv for matrix vector multiply and gevm for vector matrix multiply
            run_matvec[reduction_method=reduction_method](
                4096, 1, 4096, ctx=ctx
            )
            run_matvec[reduction_method=reduction_method](
                1, 4096, 4096, ctx=ctx
            )
            test_gevm_with_epilogue_fn[reduction_method=reduction_method](
                1, 4096, 4096, ctx=ctx
            )
            test_gevm_with_epilogue_fn[reduction_method=reduction_method](
                4096, 1, 4096, ctx=ctx
            )
