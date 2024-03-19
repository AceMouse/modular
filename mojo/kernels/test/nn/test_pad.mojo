# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo -debug-level full %s | FileCheck %s

from buffer import Buffer, NDBuffer
from nn.pad import pad_constant, pad_reflect, pad_repeat

from utils.index import StaticIntTuple
from buffer.list import DimList


# CHECK-LABEL: test_pad_1d
fn test_pad_1d():
    print("== test_pad_1d")

    alias in_shape = DimList(3)
    alias out_shape = DimList(6)

    # Create an input matrix of the form
    # [1, 2, 3]
    var input = NDBuffer[DType.index, 1, in_shape].stack_allocation()
    input[StaticIntTuple[1](0)] = 1
    input[StaticIntTuple[1](1)] = 2
    input[StaticIntTuple[1](2)] = 3

    # Create a padding array of the form
    # [1, 2]
    var paddings = Buffer[DType.index, 2].stack_allocation()
    paddings[0] = 1
    paddings[1] = 2

    # Create an output matrix of the form
    # [0, 0, 0, 0, 0, 0]
    var output = NDBuffer[DType.index, 1, out_shape].stack_allocation()
    output.fill(0)

    var constant = Scalar[DType.index](5)

    # pad
    pad_constant(output, input, paddings.data, constant)

    # output should have form
    # [5, 1, 2, 3, 5, 5]

    # CHECK: 5
    print(output[0])
    # CHECK: 1
    print(output[1])
    # CHECK: 2
    print(output[2])
    # CHECK: 3
    print(output[3])
    # CHECK: 5
    print(output[4])
    # CHECK: 5
    print(output[5])


# CHECK-LABEL: test_pad_reflect_1d
fn test_pad_reflect_1d():
    print("== test_pad_reflect_1d")

    alias in_shape = DimList(3)
    alias out_shape = DimList(8)

    # Create an input matrix of the form
    # [1, 2, 3]
    var input = NDBuffer[DType.index, 1, in_shape].stack_allocation()
    input[StaticIntTuple[1](0)] = 1
    input[StaticIntTuple[1](1)] = 2
    input[StaticIntTuple[1](2)] = 3

    # Create an output matrix of the form
    # [0, 0, 0, 0, 0, 0, 0, 0]
    var output = NDBuffer[DType.index, 1, out_shape].stack_allocation()
    output.fill(0)

    # Create a padding array of the form
    # [3, 2]
    var paddings = Buffer[DType.index, 2].stack_allocation()
    paddings[0] = 3
    paddings[1] = 2

    # pad
    pad_reflect(output, input, paddings.data)

    # output should have form
    # [2, 3, 2, 1, 2, 3, 2, 1]

    # CHECK: 2
    print(output[0])
    # CHECK: 3
    print(output[1])
    # CHECK: 2
    print(output[2])
    # CHECK: 1
    print(output[3])
    # CHECK: 2
    print(output[4])
    # CHECK: 3
    print(output[5])
    # CHECK: 2
    print(output[6])
    # CHECK: 1
    print(output[7])


# CHECK-LABEL: test_pad_repeat_1d
fn test_pad_repeat_1d():
    print("== test_pad_repeat_1d")

    alias in_shape = DimList(3)
    alias out_shape = DimList(8)

    # Create an input matrix of the form
    # [1, 2, 3]
    var input = NDBuffer[DType.index, 1, in_shape].stack_allocation()
    input[StaticIntTuple[1](0)] = 1
    input[StaticIntTuple[1](1)] = 2
    input[StaticIntTuple[1](2)] = 3

    # Create an output matrix of the form
    # [0, 0, 0, 0, 0, 0, 0, 0]
    var output = NDBuffer[DType.index, 1, out_shape].stack_allocation()
    output.fill(0)

    # Create a padding array of the form
    # [3, 2]
    var paddings = Buffer[DType.index, 2].stack_allocation()
    paddings[0] = 3
    paddings[1] = 2

    # pad
    pad_repeat(output, input, paddings.data)

    # output should have form
    # [1, 1, 1, 1, 2, 3, 3, 3]

    # CHECK: 1
    print(output[0])
    # CHECK: 1
    print(output[1])
    # CHECK: 1
    print(output[2])
    # CHECK: 1
    print(output[3])
    # CHECK: 2
    print(output[4])
    # CHECK: 3
    print(output[5])
    # CHECK: 3
    print(output[6])
    # CHECK: 3
    print(output[7])


# CHECK-LABEL: test_pad_2d
fn test_pad_2d():
    print("== test_pad_2d")

    alias in_shape = DimList(2, 2)
    alias out_shape = DimList(3, 4)

    # Create an input matrix of the form
    # [[1, 2],
    #  [3, 4]]
    var input = NDBuffer[DType.index, 2, in_shape].stack_allocation()
    input[StaticIntTuple[2](0, 0)] = 1
    input[StaticIntTuple[2](0, 1)] = 2
    input[StaticIntTuple[2](1, 0)] = 3
    input[StaticIntTuple[2](1, 1)] = 4

    # Create a padding array of the form
    # [1, 0, 1, 1]
    var paddings = Buffer[DType.index, 4].stack_allocation()
    paddings[0] = 1
    paddings[1] = 0
    paddings[2] = 1
    paddings[3] = 1

    # Create an output matrix of the form
    # [[0, 0, 0, 0]
    #  [0, 0, 0, 0]
    #  [0, 0, 0, 0]]
    var output = NDBuffer[DType.index, 2, out_shape].stack_allocation()
    output.fill(0)

    var constant = Scalar[DType.index](6)

    # pad
    pad_constant(output, input, paddings.data, constant)

    # output should have form
    # [[6, 6, 6, 6]
    #  [6, 1, 2, 6]
    #  [6, 3, 4, 6]]

    # CHECK: 6
    print(output[0, 0])
    # CHECK: 6
    print(output[0, 1])
    # CHECK: 6
    print(output[0, 2])
    # CHECK: 6
    print(output[0, 3])
    # CHECK: 6
    print(output[1, 0])
    # CHECK: 1
    print(output[1, 1])
    # CHECK: 2
    print(output[1, 2])
    # CHECK: 6
    print(output[1, 3])
    # CHECK: 6
    print(output[2, 0])
    # CHECK: 3
    print(output[2, 1])
    # CHECK: 4
    print(output[2, 2])
    # CHECK: 6
    print(output[2, 3])


# CHECK-LABEL: test_pad_reflect_2d
fn test_pad_reflect_2d():
    print("== test_pad_reflect_2d")

    alias in_shape = DimList(2, 2)
    alias out_shape = DimList(6, 3)

    # Create an input matrix of the form
    # [[1, 2],
    #  [3, 4]]
    var input = NDBuffer[DType.index, 2, in_shape].stack_allocation()
    input[StaticIntTuple[2](0, 0)] = 1
    input[StaticIntTuple[2](0, 1)] = 2
    input[StaticIntTuple[2](1, 0)] = 3
    input[StaticIntTuple[2](1, 1)] = 4

    # Create a padding array of the form
    # [2, 2, 1, 0]
    var paddings = Buffer[DType.index, 4].stack_allocation()
    paddings[0] = 2
    paddings[1] = 2
    paddings[2] = 1
    paddings[3] = 0

    # Create an output matrix of the form
    # [[0 0 0]
    #  [0 0 0]
    #  [0 0 0]
    #  [0 0 0]
    #  [0 0 0]
    #  [0 0 0]]
    var output = NDBuffer[DType.index, 2, out_shape].stack_allocation()
    output.fill(0)

    # pad
    pad_reflect(output, input, paddings.data)

    # output should have form
    # [[2 1 2]
    #  [4 3 4]
    #  [2 1 2]
    #  [4 3 4]
    #  [2 1 2]
    #  [4 3 4]]

    # CHECK: 2
    print(output[0, 0])
    # CHECK: 1
    print(output[0, 1])
    # CHECK: 2
    print(output[0, 2])
    # CHECK: 4
    print(output[1, 0])
    # CHECK: 3
    print(output[1, 1])
    # CHECK: 4
    print(output[1, 2])
    # CHECK: 2
    print(output[2, 0])
    # CHECK: 1
    print(output[2, 1])
    # CHECK: 2
    print(output[2, 2])
    # CHECK: 4
    print(output[3, 0])
    # CHECK: 3
    print(output[3, 1])
    # CHECK: 4
    print(output[3, 2])
    # CHECK: 2
    print(output[4, 0])
    # CHECK: 1
    print(output[4, 1])
    # CHECK: 2
    print(output[4, 2])
    # CHECK: 4
    print(output[5, 0])
    # CHECK: 3
    print(output[5, 1])
    # CHECK: 4
    print(output[5, 2])


# CHECK-LABEL: test_pad_repeat_2d
fn test_pad_repeat_2d():
    print("== test_pad_repeat_2d")

    alias in_shape = DimList(2, 2)
    alias out_shape = DimList(6, 3)

    # Create an input matrix of the form
    # [[1, 2],
    #  [3, 4]]
    var input = NDBuffer[DType.index, 2, in_shape].stack_allocation()
    input[StaticIntTuple[2](0, 0)] = 1
    input[StaticIntTuple[2](0, 1)] = 2
    input[StaticIntTuple[2](1, 0)] = 3
    input[StaticIntTuple[2](1, 1)] = 4

    # Create a padding array of the form
    # [2, 2, 1, 0]
    var paddings = Buffer[DType.index, 4].stack_allocation()
    paddings[0] = 2
    paddings[1] = 2
    paddings[2] = 1
    paddings[3] = 0

    # Create an output matrix of the form
    # [[0 0 0]
    #  [0 0 0]
    #  [0 0 0]
    #  [0 0 0]
    #  [0 0 0]
    #  [0 0 0]]
    var output = NDBuffer[DType.index, 2, out_shape].stack_allocation()
    output.fill(0)

    # pad
    pad_repeat(output, input, paddings.data)

    # output should have form
    # [[1, 1, 2],
    #  [1, 1, 2],
    #  [1, 1, 2],
    #  [3, 3, 4],
    #  [3, 3, 4],
    #  [3, 3, 4]]

    # CHECK: 1
    print(output[0, 0])
    # CHECK: 1
    print(output[0, 1])
    # CHECK: 2
    print(output[0, 2])
    # CHECK: 1
    print(output[1, 0])
    # CHECK: 1
    print(output[1, 1])
    # CHECK: 2
    print(output[1, 2])
    # CHECK: 1
    print(output[2, 0])
    # CHECK: 1
    print(output[2, 1])
    # CHECK: 2
    print(output[2, 2])
    # CHECK: 3
    print(output[3, 0])
    # CHECK: 3
    print(output[3, 1])
    # CHECK: 4
    print(output[3, 2])
    # CHECK: 3
    print(output[4, 0])
    # CHECK: 3
    print(output[4, 1])
    # CHECK: 4
    print(output[4, 2])
    # CHECK: 3
    print(output[5, 0])
    # CHECK: 3
    print(output[5, 1])
    # CHECK: 4
    print(output[5, 2])


# CHECK-LABEL: test_pad_3d
fn test_pad_3d():
    print("== test_pad_3d")

    alias in_shape = DimList(1, 2, 2)
    alias out_shape = DimList(2, 3, 3)

    # Create an input matrix of the form
    # [[[1, 2],
    #   [3, 4]]]
    var input = NDBuffer[DType.index, 3, in_shape].stack_allocation()
    input[StaticIntTuple[3](0, 0, 0)] = 1
    input[StaticIntTuple[3](0, 0, 1)] = 2
    input[StaticIntTuple[3](0, 1, 0)] = 3
    input[StaticIntTuple[3](0, 1, 1)] = 4

    # Create a padding array of the form
    # [1, 0, 0, 1, 1, 0]
    var paddings = Buffer[DType.index, 6].stack_allocation()
    paddings[0] = 1
    paddings[1] = 0
    paddings[2] = 0
    paddings[3] = 1
    paddings[4] = 1
    paddings[5] = 0

    # Create an output matrix of the form
    # [[[0, 0, 0]
    #   [0, 0, 0]
    #   [0, 0, 0]]
    #  [[0, 0, 0]
    #   [0, 0, 0]
    #   [0, 0, 0]]]
    var output = NDBuffer[DType.index, 3, out_shape].stack_allocation()
    output.fill(0)

    var constant = Scalar[DType.index](7)

    # pad
    pad_constant(output, input, paddings.data, constant)

    # output should have form
    # [[[7, 7, 7]
    #   [7, 7, 7]
    #   [7, 7, 7]]
    #  [[7, 1, 2]
    #   [7, 3, 4]
    #   [7, 7, 7]]]

    # CHECK: 7
    print(output[0, 0, 0])
    # CHECK: 7
    print(output[0, 0, 1])
    # CHECK: 7
    print(output[0, 0, 2])
    # CHECK: 7
    print(output[0, 1, 0])
    # CHECK: 7
    print(output[0, 1, 1])
    # CHECK: 7
    print(output[0, 1, 2])
    # CHECK: 7
    print(output[0, 2, 0])
    # CHECK: 7
    print(output[0, 2, 1])
    # CHECK: 7
    print(output[0, 2, 2])
    # CHECK: 7
    print(output[1, 0, 0])
    # CHECK: 1
    print(output[1, 0, 1])
    # CHECK: 2
    print(output[1, 0, 2])
    # CHECK: 7
    print(output[1, 1, 0])
    # CHECK: 3
    print(output[1, 1, 1])
    # CHECK: 4
    print(output[1, 1, 2])
    # CHECK: 7
    print(output[1, 2, 0])
    # CHECK: 7
    print(output[1, 2, 1])
    # CHECK: 7
    print(output[1, 2, 2])


# CHECK-LABEL: test_pad_reflect_3d
fn test_pad_reflect_3d():
    print("== test_pad_reflect_3d")
    alias in_shape = DimList(2, 2, 2)
    alias out_shape = DimList(4, 3, 3)

    # Create an input matrix of the form
    # [[[1, 2],
    #   [3, 4]],
    #  [[1, 2],
    #   [3 ,4]]]
    var input = NDBuffer[DType.index, 3, in_shape].stack_allocation()
    input[StaticIntTuple[3](0, 0, 0)] = 1
    input[StaticIntTuple[3](0, 0, 1)] = 2
    input[StaticIntTuple[3](0, 1, 0)] = 3
    input[StaticIntTuple[3](0, 1, 1)] = 4
    input[StaticIntTuple[3](1, 0, 0)] = 1
    input[StaticIntTuple[3](1, 0, 1)] = 2
    input[StaticIntTuple[3](1, 1, 0)] = 3
    input[StaticIntTuple[3](1, 1, 1)] = 4

    # Create a padding array of the form
    # [1, 1, 0, 1, 1, 0]
    var paddings = Buffer[DType.index, 6].stack_allocation()
    paddings[0] = 1
    paddings[1] = 1
    paddings[2] = 0
    paddings[3] = 1
    paddings[4] = 1
    paddings[5] = 0

    # Create an output matrix of the form
    # [[[0 0 0]
    #   [0 0 0]
    #   [0 0 0]]
    #  [[0 0 0]
    #   [0 0 0]
    #   [0 0 0]]
    #  [[0 0 0]
    #   [0 0 0]
    #   [0 0 0]]
    #  [[0 0 0]
    #   [0 0 0]
    #   [0 0 0]]]
    var output = NDBuffer[DType.index, 3, out_shape].stack_allocation()
    output.fill(0)

    # pad
    pad_reflect(output, input, paddings.data)

    # output should have form
    # [[[2 1 2]
    #   [4 3 4]
    #   [2 1 2]]
    #  [[2 1 2]
    #   [4 3 4]
    #   [2 1 2]]
    #  [[2 1 2]
    #   [4 3 4]
    #   [2 1 2]]
    #  [[2 1 2]
    #   [4 3 4]
    #   [2 1 2]]]

    # CHECK: 2
    print(output[0, 0, 0])
    # CHECK: 1
    print(output[0, 0, 1])
    # CHECK: 2
    print(output[0, 0, 2])
    # CHECK: 4
    print(output[0, 1, 0])
    # CHECK: 3
    print(output[0, 1, 1])
    # CHECK: 4
    print(output[0, 1, 2])
    # CHECK: 2
    print(output[0, 2, 0])
    # CHECK: 1
    print(output[0, 2, 1])
    # CHECK: 2
    print(output[0, 2, 2])
    # CHECK: 2
    print(output[1, 0, 0])
    # CHECK: 1
    print(output[1, 0, 1])
    # CHECK: 2
    print(output[1, 0, 2])
    # CHECK: 4
    print(output[1, 1, 0])
    # CHECK: 3
    print(output[1, 1, 1])
    # CHECK: 4
    print(output[1, 1, 2])
    # CHECK: 2
    print(output[1, 2, 0])
    # CHECK: 1
    print(output[1, 2, 1])
    # CHECK: 2
    print(output[1, 2, 2])
    # CHECK: 2
    print(output[2, 0, 0])
    # CHECK: 1
    print(output[2, 0, 1])
    # CHECK: 2
    print(output[2, 0, 2])
    # CHECK: 4
    print(output[2, 1, 0])
    # CHECK: 3
    print(output[2, 1, 1])
    # CHECK: 4
    print(output[2, 1, 2])
    # CHECK: 2
    print(output[2, 2, 0])
    # CHECK: 1
    print(output[2, 2, 1])
    # CHECK: 2
    print(output[2, 2, 2])
    # CHECK: 2
    print(output[3, 0, 0])
    # CHECK: 1
    print(output[3, 0, 1])
    # CHECK: 2
    print(output[3, 0, 2])
    # CHECK: 4
    print(output[3, 1, 0])
    # CHECK: 3
    print(output[3, 1, 1])
    # CHECK: 4
    print(output[3, 1, 2])
    # CHECK: 2
    print(output[3, 2, 0])
    # CHECK: 1
    print(output[3, 2, 1])
    # CHECK: 2
    print(output[3, 2, 2])


# CHECK-LABEL: test_pad_reflect_3d_singleton
fn test_pad_reflect_3d_singleton():
    print("== test_pad_reflect_3d_singleton")
    alias in_shape = DimList(1, 1, 1)
    alias out_shape = DimList(2, 2, 5)

    # Create an input matrix of the form
    # [[[1]]]
    var input = NDBuffer[DType.index, 3, in_shape].stack_allocation()
    input[StaticIntTuple[3](0, 0, 0)] = 1

    # Create a padding array of the form
    # [1, 0, 0, 1, 2, 2]
    var paddings = Buffer[DType.index, 6].stack_allocation()
    paddings[0] = 1
    paddings[1] = 0
    paddings[2] = 0
    paddings[3] = 1
    paddings[4] = 2
    paddings[5] = 2

    # Create an output matrix of the form
    # [[[0 0 0 0 0]
    #   [0 0 0 0 0]]
    #  [[0 0 0 0 0]
    #   [0 0 0 0 0]]]
    var output = NDBuffer[DType.index, 3, out_shape].stack_allocation()
    output.fill(0)

    # pad
    pad_reflect(output, input, paddings.data)

    # output should have the form
    # [[[1 1 1 1 1]
    #   [1 1 1 1 1]]
    #  [[1 1 1 1 1]
    #   [1 1 1 1 1]]]

    # CHECK: 1
    print(output[0, 0, 0])
    # CHECK: 1
    print(output[0, 0, 1])
    # CHECK: 1
    print(output[0, 0, 2])
    # CHECK: 1
    print(output[0, 0, 3])
    # CHECK: 1
    print(output[0, 0, 4])
    # CHECK: 1
    print(output[0, 1, 0])
    # CHECK: 1
    print(output[0, 1, 1])
    # CHECK: 1
    print(output[0, 1, 2])
    # CHECK: 1
    print(output[0, 1, 3])
    # CHECK: 1
    print(output[0, 1, 4])
    # CHECK: 1
    print(output[1, 0, 0])
    # CHECK: 1
    print(output[1, 0, 1])
    # CHECK: 1
    print(output[1, 0, 2])
    # CHECK: 1
    print(output[1, 0, 3])
    # CHECK: 1
    print(output[1, 0, 4])
    # CHECK: 1
    print(output[1, 1, 0])
    # CHECK: 1
    print(output[1, 1, 1])
    # CHECK: 1
    print(output[1, 1, 2])
    # CHECK: 1
    print(output[1, 1, 3])
    # CHECK: 1
    print(output[1, 1, 4])


# CHECK-LABEL: test_pad_reflect_4d_big_input
fn test_pad_reflect_4d_big_input():
    print("== test_pad_reflect_4d_big_input")

    alias in_shape = DimList(1, 1, 512, 512)
    alias in_size = 1 * 1 * 512 * 512
    alias out_shape = DimList(2, 3, 1024, 1024)
    alias out_size = 2 * 3 * 1024 * 1024

    # create a big input matrix and fill it with ones
    var input_ptr = DTypePointer[DType.index].alloc(in_size)
    var input = NDBuffer[DType.index, 4, in_shape](input_ptr, in_shape)
    input.fill(1)

    # create a padding array of the form
    # [1, 0, 1, 1, 256, 256, 256, 256]
    var paddings = Buffer[DType.index, 8].stack_allocation()
    paddings[0] = 1
    paddings[1] = 0
    paddings[2] = 1
    paddings[3] = 1
    paddings[4] = 256
    paddings[5] = 256
    paddings[6] = 256
    paddings[7] = 256

    # create an even bigger output matrix and fill it with zeros
    var output_ptr = DTypePointer[DType.index].alloc(out_size)
    var output = NDBuffer[DType.index, 4, out_shape](output_ptr, out_shape)
    output.fill(0)

    # pad
    pad_reflect(output, input, paddings.data)

    # CHECK: 1
    print(output[0, 0, 0, 0])

    input_ptr.free()
    output_ptr.free()


# CHECK-LABEL: test_pad_repeat_3d
fn test_pad_repeat_3d():
    print("== test_pad_repeat_3d")
    alias in_shape = DimList(2, 2, 2)
    alias out_shape = DimList(5, 4, 3)

    # Create an input matrix of the form
    # [[[1, 2],
    #   [3, 4]],
    #  [[1, 2],
    #   [3 ,4]]]
    var input = NDBuffer[DType.index, 3, in_shape].stack_allocation()
    input[StaticIntTuple[3](0, 0, 0)] = 1
    input[StaticIntTuple[3](0, 0, 1)] = 2
    input[StaticIntTuple[3](0, 1, 0)] = 3
    input[StaticIntTuple[3](0, 1, 1)] = 4
    input[StaticIntTuple[3](1, 0, 0)] = 1
    input[StaticIntTuple[3](1, 0, 1)] = 2
    input[StaticIntTuple[3](1, 1, 0)] = 3
    input[StaticIntTuple[3](1, 1, 1)] = 4

    # Create a padding array of the form
    # [1, 1, 0, 1, 1, 0]
    var paddings = Buffer[DType.index, 6].stack_allocation()
    paddings[0] = 1
    paddings[1] = 2
    paddings[2] = 0
    paddings[3] = 2
    paddings[4] = 0
    paddings[5] = 1

    # Create an output array equivalent to np.zeros((5, 4, 3))
    var output = NDBuffer[DType.index, 3, out_shape].stack_allocation()
    output.fill(0)

    # pad
    pad_repeat(output, input, paddings.data)

    # output should have form
    # [[[1, 2, 2],
    #   [3, 4, 4],
    #   [3, 4, 4],
    #   [3, 4, 4]],
    #
    #  [[1, 2, 2],
    #   [3, 4, 4],
    #   [3, 4, 4],
    #   [3, 4, 4]],
    #
    #  [[1, 2, 2],
    #   [3, 4, 4],
    #   [3, 4, 4],
    #   [3, 4, 4]],
    #
    #  [[1, 2, 2],
    #   [3, 4, 4],
    #   [3, 4, 4],
    #   [3, 4, 4]],
    #
    #  [[1, 2, 2],
    #   [3, 4, 4],
    #   [3, 4, 4],
    #   [3, 4, 4]]]

    # CHECK: 1
    print(output[0, 0, 0])
    # CHECK: 2
    print(output[0, 0, 1])
    # CHECK: 2
    print(output[0, 0, 2])
    # CHECK: 3
    print(output[0, 1, 0])
    # CHECK: 4
    print(output[0, 1, 1])
    # CHECK: 4
    print(output[0, 1, 2])
    # CHECK: 3
    print(output[0, 2, 0])
    # CHECK: 4
    print(output[0, 2, 1])
    # CHECK: 4
    print(output[0, 2, 2])
    # CHECK: 3
    print(output[0, 3, 0])
    # CHECK: 4
    print(output[0, 3, 1])
    # CHECK: 4
    print(output[0, 3, 2])
    # CHECK: 1
    print(output[1, 0, 0])
    # CHECK: 2
    print(output[1, 0, 1])
    # CHECK: 2
    print(output[1, 0, 2])
    # CHECK: 3
    print(output[1, 1, 0])
    # CHECK: 4
    print(output[1, 1, 1])
    # CHECK: 4
    print(output[1, 1, 2])
    # CHECK: 3
    print(output[1, 2, 0])
    # CHECK: 4
    print(output[1, 2, 1])
    # CHECK: 4
    print(output[1, 2, 2])
    # CHECK: 3
    print(output[1, 3, 0])
    # CHECK: 4
    print(output[1, 3, 1])
    # CHECK: 4
    print(output[1, 3, 2])
    # CHECK: 1
    print(output[2, 0, 0])
    # CHECK: 2
    print(output[2, 0, 1])
    # CHECK: 2
    print(output[2, 0, 2])
    # CHECK: 3
    print(output[2, 1, 0])
    # CHECK: 4
    print(output[2, 1, 1])
    # CHECK: 4
    print(output[2, 1, 2])
    # CHECK: 3
    print(output[2, 2, 0])
    # CHECK: 4
    print(output[2, 2, 1])
    # CHECK: 4
    print(output[2, 2, 2])
    # CHECK: 3
    print(output[2, 3, 0])
    # CHECK: 4
    print(output[2, 3, 1])
    # CHECK: 4
    print(output[2, 3, 2])
    # CHECK: 1
    print(output[3, 0, 0])
    # CHECK: 2
    print(output[3, 0, 1])
    # CHECK: 2
    print(output[3, 0, 2])
    # CHECK: 3
    print(output[3, 1, 0])
    # CHECK: 4
    print(output[3, 1, 1])
    # CHECK: 4
    print(output[3, 1, 2])
    # CHECK: 3
    print(output[3, 2, 0])
    # CHECK: 4
    print(output[3, 2, 1])
    # CHECK: 4
    print(output[3, 2, 2])
    # CHECK: 3
    print(output[3, 3, 0])
    # CHECK: 4
    print(output[3, 3, 1])
    # CHECK: 4
    print(output[3, 3, 2])
    # CHECK: 1
    print(output[4, 0, 0])
    # CHECK: 2
    print(output[4, 0, 1])
    # CHECK: 2
    print(output[4, 0, 2])
    # CHECK: 3
    print(output[4, 1, 0])
    # CHECK: 4
    print(output[4, 1, 1])
    # CHECK: 4
    print(output[4, 1, 2])
    # CHECK: 3
    print(output[4, 2, 0])
    # CHECK: 4
    print(output[4, 2, 1])
    # CHECK: 4
    print(output[4, 2, 2])
    # CHECK: 3
    print(output[4, 3, 0])
    # CHECK: 4
    print(output[4, 3, 1])
    # CHECK: 4
    print(output[4, 3, 2])


fn main():
    test_pad_1d()
    test_pad_reflect_1d()
    test_pad_repeat_1d()
    test_pad_2d()
    test_pad_reflect_2d()
    test_pad_repeat_2d()
    test_pad_3d()
    test_pad_reflect_3d()
    test_pad_reflect_3d_singleton()
    test_pad_reflect_4d_big_input()
    test_pad_repeat_3d()
