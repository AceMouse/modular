# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo-no-debug %s | FileCheck %s


from buffer import DimList, NDBuffer
from gpu.host.device_context import DeviceContext
from linalg.bmm import _batched_matmul_gpu

from utils.index import Index, StaticIntTuple


# CHECK-LABEL: test_batched_matmul
fn test_batched_matmul(ctx: DeviceContext) raises:
    print("== test_batched_matmul")

    alias b = 2
    alias m = 2
    alias n = 2
    alias k = 4

    var lhs_host = NDBuffer[
        DType.float32, 3, DimList(b, m, k)
    ].stack_allocation()
    var rhs_host = NDBuffer[
        DType.float32, 3, DimList(b, k, n)
    ].stack_allocation()
    var dst_host = NDBuffer[
        DType.float32, 3, DimList(b, m, n)
    ].stack_allocation()

    var csum = 0.0
    for bi in range(b):
        for mi in range(m):
            for ki in range(k):
                lhs_host[Index(bi, mi, ki)] = csum
                csum += 1.0

    csum = 0.0
    for bi in range(b):
        for ki in range(k):
            for ni in range(n):
                rhs_host[Index(bi, ki, ni)] = csum
                csum += 1.0

    csum = 0.0
    for bi in range(b):
        for mi in range(m):
            for ni in range(n):
                dst_host[Index(bi, mi, ni)] = 0.0

    var lhs_device = ctx.create_buffer[DType.float32](lhs_host.num_elements())
    var rhs_device = ctx.create_buffer[DType.float32](rhs_host.num_elements())
    var dst_device = ctx.create_buffer[DType.float32](dst_host.num_elements())

    var lhs_buffer = NDBuffer[DType.float32, 3](rhs_device.ptr, Index(b, m, k))
    var rhs_buffer = NDBuffer[DType.float32, 3](lhs_device.ptr, Index(b, k, n))
    var dst_buffer = NDBuffer[DType.float32, 3](dst_device.ptr, Index(b, m, n))

    ctx.enqueue_copy_to_device(lhs_device, lhs_host.data)
    ctx.enqueue_copy_to_device(rhs_device, rhs_host.data)
    ctx.enqueue_copy_to_device(dst_device, dst_host.data)

    @always_inline
    @__copy_capture(dst_buffer)
    @parameter
    fn elementwise_epilogue_empty_fn[
        c_type: DType, width: Int, rank: Int
    ](idx: StaticIntTuple[rank], val: SIMD[c_type, width]) -> None:
        dst_buffer[(idx[0], idx[1], idx[2])] = rebind[Float32](val) + 2.0

    _batched_matmul_gpu[
        rank=3,
        a_type = DType.float32,
        b_type = DType.float32,
        c_type = DType.float32,
        transpose_b=False,
        elementwise_epilogue_fn=elementwise_epilogue_empty_fn,
    ](dst_buffer, lhs_buffer, rhs_buffer, ctx)

    ctx.synchronize()

    ctx.enqueue_copy_from_device(dst_host.data, dst_device)

    # CHECK: [30.0, 36.0],
    # CHECK: [78.0, 100.0]],
    # CHECK: [430.0, 468.0],
    # CHECK: [606.0, 660.0]
    print(dst_host)


# CHECK-NOT: CUDA_ERROR
fn main():
    try:
        with DeviceContext() as ctx:
            test_batched_matmul(ctx)
    except e:
        print("CUDA_ERROR:", e)
