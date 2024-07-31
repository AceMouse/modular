# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# TODO(#31429): Restore `--debug-level full` here
# RUN: %mojo %s

from math import ceildiv
from random import random_float64

from buffer import DimList, NDBuffer
from gpu import BlockDim, BlockIdx, ThreadIdx
from gpu.cublas.cublas import *
from gpu.host import DeviceContext
from linalg.cublas import cublas_matmul
from linalg.matmul_gpu import matmul_kernel_naive
from memory import UnsafePointer
from testing import assert_almost_equal, assert_equal

from utils.index import Index


fn test_cublas(ctx: DeviceContext) raises:
    print("== test_cublas")

    alias M = 63
    alias N = 65
    alias K = 66
    alias type = DType.float32

    var a_host = UnsafePointer[Scalar[type]].alloc(M * K)
    var b_host = UnsafePointer[Scalar[type]].alloc(K * N)
    var c_host = UnsafePointer[Scalar[type]].alloc(M * N)
    var c_host_ref = UnsafePointer[Scalar[type]].alloc(M * N)

    for m in range(M):
        for k in range(K):
            a_host[m * K + k] = random_float64(-1, 1).cast[type]()

    for k in range(K):
        for n in range(N):
            b_host[k * N + n] = random_float64(-1, 1).cast[type]()

    var a_device = ctx.create_buffer[type](M * K)
    var b_device = ctx.create_buffer[type](K * N)
    var c_device = ctx.create_buffer[type](M * N)
    var c_device_ref = ctx.create_buffer[type](M * N)

    ctx.enqueue_copy_to_device(a_device, a_host)
    ctx.enqueue_copy_to_device(b_device, b_host)

    var a = NDBuffer[type, 2, DimList(M, K)](a_device.ptr)
    var b = NDBuffer[type, 2, DimList(K, N)](b_device.ptr)
    var c = NDBuffer[type, 2, DimList(M, N)](c_device.ptr)
    var c_ref = NDBuffer[type, 2, DimList(M, N)](c_device_ref.ptr)

    var handle = UnsafePointer[cublasContext]()
    check_cublas_error(cublasCreate(UnsafePointer.address_of(handle)))
    check_cublas_error(cublas_matmul(handle, c, a, b, c_row_major=True))
    check_cublas_error(cublasDestroy(handle))

    ctx.enqueue_copy_from_device(c_host, c_device)

    alias BLOCK_DIM = 16
    alias gemm_naive = matmul_kernel_naive[type, type, type, BLOCK_DIM]
    var func_naive = ctx.compile_function[gemm_naive](threads_per_block=256)
    ctx.enqueue_function(
        func_naive,
        c_ref,
        a,
        b,
        M,
        N,
        K,
        grid_dim=(ceildiv(M, BLOCK_DIM), ceildiv(N, BLOCK_DIM), 1),
        block_dim=(BLOCK_DIM, BLOCK_DIM, 1),
    )

    ctx.enqueue_copy_from_device(c_host_ref, c_device_ref)

    for i in range(M * N):
        assert_almost_equal(c_host[i], c_host_ref[i], atol=1e-4, rtol=1e-4)

    _ = a_device
    _ = b_device
    _ = c_device
    _ = c_device_ref

    a_host.free()
    b_host.free()
    c_host.free()
    c_host_ref.free()


def test_cublas_result_format():
    assert_equal(str(Result.SUCCESS), "SUCCESS")
    assert_equal(str(Result.LICENSE_ERROR), "LICENSE_ERROR")


def main():
    test_cublas_result_format()

    with DeviceContext() as ctx:
        test_cublas(ctx)
