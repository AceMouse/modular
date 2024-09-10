# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo-no-debug %s | FileCheck %s

from algorithm import elementwise
from buffer import Buffer, NDBuffer
from buffer.dimlist import Dim, DimList
from memory import stack_allocation
from nn.slice import slice_dim_as_view

from utils.index import Index, StaticIntTuple


fn print_elements[type: DType, in_rank: Int](tensor: NDBuffer[type, in_rank]):
    print("New shape:", tensor.dynamic_shape)
    print("New strides:", tensor.dynamic_stride)

    @always_inline
    @parameter
    fn print_elements_lambda[
        simd_width: Int, rank: Int
    ](idx: StaticIntTuple[rank]):
        var index = rebind[StaticIntTuple[in_rank]](idx)
        print(tensor[index])

    elementwise[print_elements_lambda, 1](tensor.dynamic_shape)


# slice_dim
fn test_slice_dim[
    dtype: DType, numelems: Int, outer_rank: Int, dim: Int
](dims: DimList, start: Int, stop: Int, step: Int):
    # Isn't always used but is used for the output buffer if we copy.
    var output_mem = stack_allocation[numelems, dtype, 1]()

    var memory1 = stack_allocation[numelems, dtype, 1]()
    var in_tensor = NDBuffer[
        dtype,
        outer_rank,
    ](memory1, dims)

    print("In shape:", in_tensor.dynamic_shape)
    print("In strides:", in_tensor.dynamic_stride)

    for i in range(numelems):
        in_tensor.data[i] = i

    # Perform the slice even if we are testing the copy so we get the target size.
    var sliced = slice_dim_as_view[dtype, outer_rank, dim](
        in_tensor,
        start,
        stop,
        step,
    )

    print_elements[dtype, outer_rank](sliced)


# CHECK-LABEL: == test_slice_dim_basic
fn test_slice_dim_basic():
    print("== test_slice_dim_basic")

    # CHECK-NEXT: In shape: (4, 4)
    # CHECK-NEXT: In strides: (4, 1)
    # CHECK-NEXT: New shape: (2, 4)
    # CHECK-NEXT: New strides: (4, 1)
    # CHECK-NEXT: 8.0
    # CHECK-NEXT: 9.0
    # CHECK-NEXT: 10.0
    # CHECK-NEXT: 11.0
    # CHECK-NEXT: 12.0
    # CHECK-NEXT: 13.0
    # CHECK-NEXT: 14.0
    # CHECK-NEXT: 15.0

    # print(torch.arange(0, 16).reshape(4, 4)[2:4:1, :].flatten())
    test_slice_dim[DType.float32, 16, 2, 0](DimList(4, 4), 2, 4, 1)

    # CHECK-NEXT: In shape: (4, 4)
    # CHECK-NEXT: In strides: (4, 1)
    # CHECK-NEXT: New shape: (4, 2)
    # CHECK-NEXT: New strides: (4, 1)
    # CHECK-NEXT: 2.0
    # CHECK-NEXT: 3.0
    # CHECK-NEXT: 6.0
    # CHECK-NEXT: 7.0
    # CHECK-NEXT: 10.0
    # CHECK-NEXT: 11.0
    # CHECK-NEXT: 14.0
    # CHECK-NEXT: 15.0

    # print(torch.arange(0, 16).reshape(4, 4)[:, 2:4:1].flatten())
    test_slice_dim[DType.float32, 16, 2, 1](DimList(4, 4), 2, 4, 1)


fn main():
    test_slice_dim_basic()
