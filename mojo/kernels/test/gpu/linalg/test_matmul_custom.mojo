# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo-no-debug %s | FileCheck %s

from math import ceildiv, isclose
from random import random_float64

from buffer import NDBuffer
from buffer.list import DimList
from gpu.host.device_context import DeviceBuffer, DeviceContext
from linalg.bmm import _batched_matmul_gpu
from linalg.matmul_gpu import _matmul_gpu, matmul_kernel_naive
from memory.unsafe import DTypePointer
from testing import assert_almost_equal

from utils.index import Index


fn run_matmul_naive(ctx: DeviceContext, M: Int, N: Int, K: Int) raises:
    print("== run_matmul naive kernel")

    var a_host = Pointer[BFloat16].alloc(M * K)
    var b_host = Pointer[BFloat16].alloc(K * N)
    var c_host = Pointer[BFloat16].alloc(M * N)
    var a_host_n = Pointer[Float32].alloc(M * K)
    var b_host_n = Pointer[Float32].alloc(K * N)
    var c_host_n = Pointer[Float32].alloc(M * N)

    var rand_min = -1.0
    var rand_max = 1.0

    for i in range(M * K):
        var val = random_float64(rand_min, rand_max).cast[DType.float32]()
        a_host[i] = val.cast[DType.bfloat16]()
        a_host_n[i] = a_host[i].cast[DType.float32]()

    for i in range(K * N):
        var val = random_float64(rand_min, rand_max).cast[DType.float32]()
        b_host[i] = val.cast[DType.bfloat16]()
        b_host_n[i] = b_host[i].cast[DType.float32]()

    for i in range(M * N):
        c_host[i] = 0
        c_host_n[i] = 0

    var a_device = ctx.create_buffer[DType.bfloat16](M * K)
    var b_device = ctx.create_buffer[DType.bfloat16](K * N)
    var c_device = ctx.create_buffer[DType.bfloat16](M * N)
    var a_device_n = ctx.create_buffer[DType.float32](M * K)
    var b_device_n = ctx.create_buffer[DType.float32](K * N)
    var c_device_n = ctx.create_buffer[DType.float32](M * N)

    ctx.enqueue_copy_to_device(a_device, a_host)
    ctx.enqueue_copy_to_device(b_device, b_host)

    alias BLOCK_DIM = 16
    var func_gemm_bf16 = ctx.compile_function[
        matmul_kernel_naive[
            DType.bfloat16,
            DType.bfloat16,
            DType.bfloat16,
            BLOCK_DIM,
        ]
    ]()

    @always_inline
    @parameter
    fn run_func_bf16() raises:
        ctx.enqueue_function(
            func_gemm_bf16,
            c_device,
            a_device,
            b_device,
            M,
            N,
            K,
            grid_dim=(ceildiv(M, BLOCK_DIM), ceildiv(N, BLOCK_DIM)),
            block_dim=(BLOCK_DIM, BLOCK_DIM),
        )

    run_func_bf16()

    ctx.enqueue_copy_from_device(c_host, c_device)

    # running naive
    ctx.enqueue_copy_to_device(a_device_n, a_host_n)
    ctx.enqueue_copy_to_device(b_device_n, b_host_n)

    var func_gemm_fp32 = ctx.compile_function[
        matmul_kernel_naive[
            DType.float32,
            DType.float32,
            DType.float32,
            BLOCK_DIM,
        ]
    ]()

    @always_inline
    @parameter
    fn run_func_fp32() raises:
        ctx.enqueue_function(
            func_gemm_fp32,
            c_device_n,
            a_device_n,
            b_device_n,
            M,
            N,
            K,
            grid_dim=(ceildiv(M, BLOCK_DIM), ceildiv(N, BLOCK_DIM)),
            block_dim=(BLOCK_DIM, BLOCK_DIM),
        )

    run_func_fp32()

    ctx.enqueue_copy_from_device(c_host_n, c_device_n)

    for i in range(M * N):
        var out_val = c_host[i]
        var out_ref = c_host_n[i].cast[DType.bfloat16]()
        assert_almost_equal(out_val, out_ref)

    _ = a_device
    _ = b_device
    _ = c_device

    _ = a_device_n
    _ = b_device_n
    _ = c_device_n

    _ = a_host
    _ = b_host
    _ = c_host

    _ = a_host_n
    _ = b_host_n
    _ = c_host_n

    _ = func_gemm_bf16^
    _ = func_gemm_fp32^


fn run_matmul[
    type: DType, M: Int, N: Int, K: Int
](
    ctx: DeviceContext,
    rtol: Scalar[type] = 1e-05,
    rng_width: Float64 = Float64(100.0),
    debug: Bool = False,
) raises:
    print("== run_matmul kernel => ", str(type), M, N, K)

    var a_host = Pointer[Scalar[type]].alloc(M * K)
    var b_host = Pointer[Scalar[type]].alloc(K * N)
    var c_host = Pointer[Scalar[type]].alloc(M * N)
    var a_host_n = Pointer[Scalar[type]].alloc(M * K)
    var b_host_n = Pointer[Scalar[type]].alloc(K * N)
    var c_host_n = Pointer[Scalar[type]].alloc(M * N)

    var rand_min = -1 * rng_width
    var rand_max = rng_width

    for i in range(M * K):
        var val = random_float64(rand_min, rand_max).cast[DType.float32]()
        a_host[i] = val.cast[type]()
        a_host_n[i] = a_host[i]

    for i in range(K * N):
        var val = random_float64(rand_min, rand_max).cast[DType.float32]()
        b_host[i] = val.cast[type]()
        b_host_n[i] = b_host[i]

    for i in range(M * N):
        var val = Float32(0)
        c_host[i] = val.cast[type]()
        c_host_n[i] = c_host[i]

    alias a_shape = DimList(M, K)
    alias b_shape = DimList(K, N)
    alias c_shape = DimList(M, N)

    var a_device = ctx.create_buffer[type](M * K)
    var b_device = ctx.create_buffer[type](K * N)
    var c_device = ctx.create_buffer[type](M * N)
    var a_buf = NDBuffer[type, 2, a_shape](a_device.ptr, Index(M, K))
    var b_buf = NDBuffer[type, 2, b_shape](b_device.ptr, Index(K, N))
    var c_buf = NDBuffer[type, 2, c_shape](c_device.ptr, Index(M, N))

    var a_device_n = ctx.create_buffer[type](M * K)
    var b_device_n = ctx.create_buffer[type](K * N)
    var c_device_n = ctx.create_buffer[type](M * N)

    ctx.enqueue_copy_to_device(a_device, a_host)
    ctx.enqueue_copy_to_device(b_device, b_host)

    _matmul_gpu(c_buf, a_buf, b_buf, ctx)
    ctx.enqueue_copy_from_device(c_host, c_device)

    # running naive
    ctx.enqueue_copy_to_device(a_device_n, a_host_n)
    ctx.enqueue_copy_to_device(b_device_n, b_host_n)

    alias BLOCK_DIM = 16
    var func_gemm_naive = ctx.compile_function[
        matmul_kernel_naive[
            type,
            type,
            type,
            BLOCK_DIM,
        ]
    ]()

    @always_inline
    @parameter
    fn run_func_naive() raises:
        ctx.enqueue_function(
            func_gemm_naive,
            c_device_n,
            a_device_n,
            b_device_n,
            M,
            N,
            K,
            grid_dim=(ceildiv(M, BLOCK_DIM), ceildiv(N, BLOCK_DIM)),
            block_dim=(BLOCK_DIM, BLOCK_DIM),
        )

    run_func_naive()

    ctx.enqueue_copy_from_device(c_host_n, c_device_n)
    ctx.synchronize()

    for i in range(M * N):
        var out_val = c_host[i]
        var out_ref = c_host_n[i]
        if debug:
            if not isclose(out_val, out_ref, rtol=rtol):
                print(i, out_val, out_ref)
        assert_almost_equal(out_val, out_ref, rtol=rtol)

    _ = a_device
    _ = b_device
    _ = c_device

    _ = a_device_n
    _ = b_device_n
    _ = c_device_n

    _ = a_host
    _ = b_host
    _ = c_host

    _ = a_host_n
    _ = b_host_n
    _ = c_host_n

    _ = func_gemm_naive^


fn run_batched_matmul(
    ctx: DeviceContext, B: Int, M: Int, N: Int, K: Int
) raises:
    print("== test_batched_matmul")

    var a_host = Pointer[BFloat16].alloc(B * M * K)
    var b_host = Pointer[BFloat16].alloc(B * K * N)
    var c_host = Pointer[BFloat16].alloc(B * M * N)
    var a_host_n = Pointer[Float32].alloc(B * M * K)
    var b_host_n = Pointer[Float32].alloc(B * K * N)
    var c_host_n = Pointer[Float32].alloc(B * M * N)

    var rand_min = -100.0
    var rand_max = 100.0

    for i in range(B * M * K):
        var val = random_float64(rand_min, rand_max)
        a_host[i] = val.cast[DType.bfloat16]()
        a_host_n[i] = a_host[i].cast[DType.float32]()

    for i in range(B * K * N):
        var val = random_float64(rand_min, rand_max)
        b_host[i] = val.cast[DType.bfloat16]()
        b_host_n[i] = b_host[i].cast[DType.float32]()

    for i in range(B * M * N):
        c_host[i] = 0
        c_host_n[i] = 0

    var a_device = ctx.create_buffer[DType.bfloat16](B * M * K)
    var b_device = ctx.create_buffer[DType.bfloat16](B * K * N)
    var c_device = ctx.create_buffer[DType.bfloat16](B * M * N)
    var a_buf = NDBuffer[DType.bfloat16, 3](a_device.ptr, Index(B, M, K))
    var b_buf = NDBuffer[DType.bfloat16, 3](b_device.ptr, Index(B, K, N))
    var c_buf = NDBuffer[DType.bfloat16, 3](c_device.ptr, Index(B, M, N))

    var a_device_n = ctx.create_buffer[DType.float32](B * M * K)
    var b_device_n = ctx.create_buffer[DType.float32](B * K * N)
    var c_device_n = ctx.create_buffer[DType.float32](B * M * N)
    var a_buf_n = NDBuffer[DType.float32, 3](a_device_n.ptr, Index(B, M, K))
    var b_buf_n = NDBuffer[DType.float32, 3](b_device_n.ptr, Index(B, K, N))
    var c_buf_n = NDBuffer[DType.float32, 3](c_device_n.ptr, Index(B, M, N))

    ctx.enqueue_copy_to_device(a_device, a_host)
    ctx.enqueue_copy_to_device(b_device, b_host)

    @always_inline
    @__copy_capture(c_buf)
    @parameter
    fn elementwise_epilogue_fn1[
        c_type: DType, width: Int, rank: Int
    ](idx: StaticIntTuple[rank], val: SIMD[c_type, width]) -> None:
        c_buf[(idx[0], idx[1], idx[2])] = rebind[BFloat16](val) + BFloat16(2.0)

    _batched_matmul_gpu[
        rank=3,
        a_type = DType.bfloat16,
        b_type = DType.bfloat16,
        c_type = DType.bfloat16,
        transpose_b=False,
        elementwise_epilogue_fn=elementwise_epilogue_fn1,
    ](c_buf, a_buf, b_buf, ctx)

    ctx.enqueue_copy_from_device(c_host, c_device)

    ctx.enqueue_copy_to_device(a_device_n, a_host_n)
    ctx.enqueue_copy_to_device(b_device_n, b_host_n)

    @always_inline
    @__copy_capture(c_buf_n)
    @parameter
    fn elementwise_epilogue_fn2[
        c_type: DType, width: Int, rank: Int
    ](idx: StaticIntTuple[rank], val: SIMD[c_type, width]) -> None:
        c_buf_n[(idx[0], idx[1], idx[2])] = rebind[Float32](val) + 2.0

    _batched_matmul_gpu[
        rank=3,
        a_type = DType.float32,
        b_type = DType.float32,
        c_type = DType.float32,
        transpose_b=False,
        elementwise_epilogue_fn=elementwise_epilogue_fn2,
    ](c_buf_n, a_buf_n, b_buf_n, ctx)

    ctx.enqueue_copy_from_device(c_host_n, c_device_n)
    ctx.synchronize()

    for i in range(B * M * N):
        var out_val = c_host[i]
        var out_ref = c_host_n[i].cast[DType.bfloat16]()
        assert_almost_equal(out_val, out_ref, rtol=1e-02)

    _ = a_device
    _ = b_device
    _ = c_device

    _ = a_device_n
    _ = b_device_n
    _ = c_device_n

    _ = a_host
    _ = b_host
    _ = c_host

    _ = a_host_n
    _ = b_host_n
    _ = c_host_n


# CHECK-NOT: CUDA_ERROR
def main():
    try:
        with DeviceContext() as ctx:
            run_matmul_naive(ctx, 32, 32, 32)

            run_matmul[DType.bfloat16, 128, 128, 128](ctx)
            run_matmul[DType.bfloat16, 32, 32, 32](ctx)
            run_matmul[DType.bfloat16, 1024, 1, 1024](ctx)
            run_matmul[DType.bfloat16, 1, 1024, 1024](ctx)

            run_matmul[DType.float16, 128, 128, 128](ctx, rng_width=10.0)
            run_matmul[DType.float16, 32, 32, 32](ctx, rng_width=10.0)
            run_matmul[DType.float16, 1024, 1, 1024](ctx, 1e-03, rng_width=10.0)
            run_matmul[DType.float16, 1, 1024, 1024](ctx, 1e-01, rng_width=10.0)

            run_batched_matmul(ctx, 3, 32, 32, 32)

    except e:
        print("CUDA_ERROR:", e)
