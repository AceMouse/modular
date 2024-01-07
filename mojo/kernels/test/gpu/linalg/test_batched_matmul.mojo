# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo -debug-level full %s | FileCheck %s


from BatchedMatmul import batched_matmul

from gpu.host import Context, synchronize
from gpu.host.memory import _malloc, _copy_host_to_device, _copy_device_to_host
from memory.buffer import NDBuffer

from runtime.llcl import OutputChainPtr

from tensor import Tensor
from utils.index import Index, StaticIntTuple


# CHECK-LABEL: test_batched_matmul
fn test_batched_matmul() raises:
    print("== test_batched_matmul")

    alias b = 2
    alias m = 2
    alias n = 2
    alias k = 4

    var lhs_host = Tensor[DType.float32](b, m, k)
    var rhs_host = Tensor[DType.float32](b, k, n)
    var dst_host = Tensor[DType.float32](b, m, n)

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

    let lhs_device = _malloc[DType.float32](lhs_host.num_elements())
    let rhs_device = _malloc[DType.float32](rhs_host.num_elements())
    let dst_device = _malloc[DType.float32](dst_host.num_elements())

    let lhs_buffer = NDBuffer[3, DimList.create_unknown[3](), DType.float32](
        rhs_device, Index(b, m, k)
    )
    let rhs_buffer = NDBuffer[3, DimList.create_unknown[3](), DType.float32](
        lhs_device, Index(b, k, n)
    )
    let dst_buffer = NDBuffer[3, DimList.create_unknown[3](), DType.float32](
        dst_device, Index(b, m, n)
    )

    _copy_host_to_device(lhs_device, lhs_host.data(), lhs_host.num_elements())
    _copy_host_to_device(rhs_device, rhs_host.data(), rhs_host.num_elements())
    _copy_host_to_device(dst_device, dst_host.data(), dst_host.num_elements())

    @always_inline
    @parameter
    fn elementwise_epilogue_empty_fn[
        c_type: DType, width: Int, rank: Int
    ](idx: StaticIntTuple[rank], val: SIMD[c_type, width]) -> None:
        dst_buffer[Index(idx[0], idx[1], idx[2])] = (
            rebind[SIMD[DType.float32, 1]](val) + 2.0
        )

    fn rowwise_epilogue_empty(
        a: Int,
        b: Int,
        c: NDBuffer[2, DimList.create_unknown[2](), DType.float32],
    ) -> None:
        pass

    batched_matmul[
        rank=3,
        a_type = DType.float32,
        b_type = DType.float32,
        c_type = DType.float32,
        adj_a=False,
        adj_b=False,
        elementwise_epilogue_enabled=False,
        elementwise_epilogue_fn=elementwise_epilogue_empty_fn,
        rowwise_epilogue_enabled=False,
        saturated_vnni=False,
        target="cuda",
    ](
        dst_buffer,
        lhs_buffer,
        rhs_buffer,
        rowwise_epilogue_empty,
        OutputChainPtr(),
    )
    synchronize()

    _copy_device_to_host(dst_host.data(), dst_device, dst_host.num_elements())

    #      CHECK: Tensor(
    # CHECK-SAME: 30.0, 36.0
    # CHECK-NEXT: 78.0, 100.0
    # CHECK-NEXT: 430.0, 468.0
    # CHECK-NEXT: 606.0, 660.0
    print(dst_host)

    _ = lhs_host ^
    _ = rhs_host ^
    _ = dst_host ^


# CHECK-NOT: CUDA_ERROR
fn main():
    try:
        with Context() as ctx:
            test_batched_matmul()
    except e:
        print("CUDA_ERROR:", e)
