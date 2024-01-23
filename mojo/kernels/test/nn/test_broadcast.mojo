# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo -debug-level full %s | FileCheck %s

from NN.Broadcast import broadcast
from memory.buffer import NDBuffer

from utils.index import StaticIntTuple
from utils.list import DimList


# CHECK-LABEL: test_broadcast_empty_shape
fn test_broadcast_empty_shape():
    print("== test_broadcast_empty_shape")

    # parameters
    alias input_shape = DimList(1)
    alias output_shape = DimList(0)

    # Create a 1D tensor of shape (1), of the form [1]
    var input = NDBuffer[
        1,
        input_shape,
        DType.index,
    ].stack_allocation()
    input[0] = 1

    # Create a 1D tensor of shape (0)
    var output = NDBuffer[1, output_shape, DType.index].stack_allocation()

    broadcast(output, input)
    # output tensor will have the form:
    # []

    # CHECK: 1
    print(input[0])

    # test shouldn't crash


# CHECK-LABEL: test_broadcast_same_shape
fn test_broadcast_same_shape():
    print("== test_broadcast_same_shape")

    # parameters
    alias input_shape = DimList(1, 2, 1)
    alias output_shape = DimList(1, 2, 1)

    # Create a 3D tensor of shape (1, 2, 1), of the form
    # [[[1], [2]]]
    var input = NDBuffer[
        3,
        input_shape,
        DType.index,
    ].stack_allocation()
    input[StaticIntTuple[3](0, 0, 0)] = 1
    input[StaticIntTuple[3](0, 1, 0)] = 2

    # Create a 3D tensor of shape (1, 2, 1)
    var output = NDBuffer[3, output_shape, DType.index].stack_allocation()
    output.fill(0)

    broadcast(output, input)
    # output tensor will have the form:
    # [[[1], [2]]]

    # CHECK: 1
    print(input[0, 0, 0])
    # CHECK: 2
    print(input[0, 1, 0])

    # CHECK: 1
    print(output[0, 0, 0])
    # CHECK: 2
    print(output[0, 1, 0])


# CHECK-LABEL: test_broadcast_single_axis
fn test_broadcast_single_axis():
    print("== test_broadcast_single_axis")

    # parameters
    alias input_shape = DimList(1, 2)
    alias output_shape = DimList(3, 2)

    # Create a 2D tensor of shape (1, 2), of the form
    # [[1, 2]]
    var input = NDBuffer[
        2,
        input_shape,
        DType.index,
    ].stack_allocation()

    input[StaticIntTuple[2](0, 0)] = 1
    input[StaticIntTuple[2](0, 1)] = 2

    # Create a 2D tensor of shape (3, 2)
    var output = NDBuffer[2, output_shape, DType.index].stack_allocation()
    output.fill(0)

    broadcast(output, input)
    # output tensor will have the form:
    # [[1, 2], [1, 2], [1, 2]]

    # CHECK: 1
    print(input[0, 0])
    # CHECK: 2
    print(input[0, 1])

    # CHECK: 1
    print(output[0, 0])
    # CHECK: 2
    print(output[0, 1])
    # CHECK: 1
    print(output[1, 0])
    # CHECK: 2
    print(output[1, 1])
    # CHECK: 1
    print(output[2, 0])
    # CHECK: 2
    print(output[2, 1])


# CHECK-LABEL: test_broadcast_multi_axes
fn test_broadcast_multi_axes():
    print("== test_broadcast_multi_axes")

    # parameters
    alias input_shape = DimList(1, 2, 1)
    alias output_shape = DimList(2, 2, 3)

    # Create a 3D tensor of shape (1, 2, 1), of the form
    # [[[1], [2]]]
    var input = NDBuffer[
        3,
        input_shape,
        DType.index,
    ].stack_allocation()

    input[StaticIntTuple[3](0, 0, 0)] = 1
    input[StaticIntTuple[3](0, 1, 0)] = 2

    # Create a 3D tensor of shape (2, 2, 3)
    var output = NDBuffer[3, output_shape, DType.index].stack_allocation()
    output.fill(0)

    broadcast(output, input)
    # output tensor will have the form:
    # [[[1, 1, 1], [2, 2, 2]],
    #  [[1, 1, 1], [2, 2, 2]]]

    # CHECK: 1
    print(input[0, 0, 0])
    # CHECK: 2
    print(input[0, 1, 0])

    # CHECK: 1
    print(output[0, 0, 0])
    # CHECK: 2
    print(output[0, 1, 0])
    # CHECK: 1
    print(output[0, 0, 1])
    # CHECK: 2
    print(output[0, 1, 1])
    # CHECK: 1
    print(output[0, 0, 2])
    # CHECK: 2
    print(output[0, 1, 2])
    # CHECK: 1
    print(output[1, 0, 0])
    # CHECK: 2
    print(output[1, 1, 0])
    # CHECK: 1
    print(output[1, 0, 1])
    # CHECK: 2
    print(output[1, 1, 1])
    # CHECK: 1
    print(output[1, 0, 2])
    # CHECK: 2
    print(output[1, 1, 2])


fn test_broadcast_multi_axes_nested():
    # parameters
    alias input_shape = DimList(2, 1, 2, 1, 2)
    alias output_shape = DimList(2, 2, 2, 2, 2)

    # Create a 5D tensor of shape (2, 1, 2, 1, 2), of the form
    # [[[[[1, 2]], [[3, 4]]]], [[[[5, 6]], [[7, 8]]]]]
    var input = NDBuffer[
        5,
        input_shape,
        DType.index,
    ].stack_allocation()

    input[StaticIntTuple[5](0, 0, 0, 0, 0)] = 1
    input[StaticIntTuple[5](0, 0, 0, 0, 1)] = 2
    input[StaticIntTuple[5](0, 0, 1, 0, 0)] = 3
    input[StaticIntTuple[5](0, 0, 1, 0, 1)] = 4
    input[StaticIntTuple[5](1, 0, 0, 0, 0)] = 5
    input[StaticIntTuple[5](1, 0, 0, 0, 1)] = 6
    input[StaticIntTuple[5](1, 0, 1, 0, 0)] = 7
    input[StaticIntTuple[5](1, 0, 1, 0, 1)] = 8

    # Create a 5D tensor of shape (2, 2, 2, 2, 2)
    var output = NDBuffer[5, output_shape, DType.index].stack_allocation()
    output.fill(0)

    broadcast(output, input)

    # CHECK: 1
    print(output[0, 0, 0, 0, 0])
    # CHECK: 2
    print(output[0, 0, 0, 0, 1])
    # CHECK: 1
    print(output[0, 0, 0, 1, 0])
    # CHECK: 2
    print(output[0, 0, 0, 1, 1])
    # CHECK: 3
    print(output[0, 0, 1, 0, 0])
    # CHECK: 4
    print(output[0, 0, 1, 0, 1])
    # CHECK: 3
    print(output[0, 0, 1, 1, 0])
    # CHECK: 4
    print(output[0, 0, 1, 1, 1])

    # CHECK: 1
    print(output[0, 1, 0, 0, 0])
    # CHECK: 2
    print(output[0, 1, 0, 0, 1])
    # CHECK: 1
    print(output[0, 1, 0, 1, 0])
    # CHECK: 2
    print(output[0, 1, 0, 1, 1])
    # CHECK: 3
    print(output[0, 1, 1, 0, 0])
    # CHECK: 4
    print(output[0, 1, 1, 0, 1])
    # CHECK: 3
    print(output[0, 1, 1, 1, 0])
    # CHECK: 4
    print(output[0, 1, 1, 1, 1])

    # CHECK: 5
    print(output[1, 0, 0, 0, 0])
    # CHECK: 6
    print(output[1, 0, 0, 0, 1])
    # CHECK: 5
    print(output[1, 0, 0, 1, 0])
    # CHECK: 6
    print(output[1, 0, 0, 1, 1])
    # CHECK: 7
    print(output[1, 0, 1, 0, 0])
    # CHECK: 8
    print(output[1, 0, 1, 0, 1])
    # CHECK: 7
    print(output[1, 0, 1, 1, 0])
    # CHECK: 8
    print(output[1, 0, 1, 1, 1])

    # CHECK: 5
    print(output[1, 1, 0, 0, 0])
    # CHECK: 6
    print(output[1, 1, 0, 0, 1])
    # CHECK: 5
    print(output[1, 1, 0, 1, 0])
    # CHECK: 6
    print(output[1, 1, 0, 1, 1])
    # CHECK: 7
    print(output[1, 1, 1, 0, 0])
    # CHECK: 8
    print(output[1, 1, 1, 0, 1])
    # CHECK: 7
    print(output[1, 1, 1, 1, 0])
    # CHECK: 8
    print(output[1, 1, 1, 1, 1])


fn main():
    test_broadcast_empty_shape()
    test_broadcast_same_shape()
    test_broadcast_single_axis()
    test_broadcast_multi_axes()
    test_broadcast_multi_axes_nested()
