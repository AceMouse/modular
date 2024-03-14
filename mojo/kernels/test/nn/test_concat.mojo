# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo -debug-level full %s | FileCheck %s

from closed_source_memory.buffer import Buffer, DynamicRankBuffer, NDBuffer
from memory.unsafe import DTypePointer
from nn.concat import (
    _concat_parallel,
    _concat_serial,
    concat,
    variadic_list_to_vector,
)

from utils.index import StaticIntTuple
from utils.list import Dim, DimList


fn test_concat() raises:
    print("== test_concat")

    alias type = DType.float32
    alias rank = 4
    alias concat_axis = 2

    alias s1 = DimList(2, 2, 1, 2, 0)
    alias s2 = DimList(2, 2, 2, 2, 0)
    alias s3 = DimList(2, 2, 3, 2, 0)

    var x1 = NDBuffer[type, rank, s1].stack_allocation()
    var x2 = NDBuffer[type, rank, s2].stack_allocation()
    var x3 = NDBuffer[type, rank, s3].stack_allocation()
    x1.fill(0)
    x2.fill(1)
    x3.fill(2)
    var x1_dyn = NDBuffer[type, rank](x1.data, s1)
    var x2_dyn = NDBuffer[type, rank](x2.data, s2)
    var x3_dyn = NDBuffer[type, rank](x3.data, s3)

    alias out_shape = DimList(2, 2, 6, 2, 0)
    var output = NDBuffer[type, rank, out_shape].stack_allocation()
    output.fill(-1)
    var output_dyn = NDBuffer[type, rank](output.data, out_shape)

    var input_list = VariadicList[NDBuffer[type, rank]](x1_dyn, x2_dyn, x3_dyn)

    var input_vec = variadic_list_to_vector(input_list)
    concat[rank, type, False](output_dyn, concat_axis, input_vec)
    input_vec._del_old()

    # CHECK: == test_concat
    # CHECK-COUNT-2: 0.0
    # CHECK-COUNT-4: 1.0
    # CHECK-COUNT-6: 2.0
    # CHECK-COUNT-2: 0.0
    # CHECK-COUNT-4: 1.0
    # CHECK-COUNT-6: 2.0
    # CHECK-COUNT-2: 0.0
    # CHECK-COUNT-4: 1.0
    # CHECK-COUNT-6: 2.0
    for i in range(out_shape.product[rank]().get()):
        print(output.flatten()[i])


fn test_concat_parallel():
    print("== test_concat_parallel")

    alias type = DType.float32
    alias rank = 4
    alias concat_axis = 2

    alias s1 = DimList(2, 2, 1, 2, 0)
    alias s2 = DimList(2, 2, 2, 2, 0)
    alias s3 = DimList(2, 2, 3, 2, 0)

    var x1 = NDBuffer[type, rank, s1].stack_allocation()
    var x2 = NDBuffer[type, rank, s2].stack_allocation()
    var x3 = NDBuffer[type, rank, s3].stack_allocation()
    x1.fill(0)
    x2.fill(1)
    x3.fill(2)
    var x1_dyn = NDBuffer[type, rank](x1.data, s1)
    var x2_dyn = NDBuffer[type, rank](x2.data, s2)
    var x3_dyn = NDBuffer[type, rank](x3.data, s3)

    alias out_shape = DimList(2, 2, 6, 2, 0)
    var output = NDBuffer[type, rank, out_shape]().stack_allocation()
    output.fill(-1)
    var output_dyn = NDBuffer[type, rank](output.data, out_shape)

    var input_list = VariadicList[NDBuffer[type, rank]](x1_dyn, x2_dyn, x3_dyn)

    var input_vec = variadic_list_to_vector(input_list)
    _concat_parallel[rank, type](output_dyn, concat_axis, input_vec)
    input_vec._del_old()

    # CHECK: == test_concat_parallel
    # CHECK-COUNT-2: 0.0
    # CHECK-COUNT-4: 1.0
    # CHECK-COUNT-6: 2.0
    # CHECK-COUNT-2: 0.0
    # CHECK-COUNT-4: 1.0
    # CHECK-COUNT-6: 2.0
    # CHECK-COUNT-2: 0.0
    # CHECK-COUNT-4: 1.0
    # CHECK-COUNT-6: 2.0
    for i in range(out_shape.product[rank]().get()):
        print(output.flatten()[i])


# CHECK-LABEL: test_concat_inner
fn test_concat_inner():
    print("== test_concat_inner")

    alias type = DType.float32
    alias rank = 5
    alias concat_axis = 2

    alias s1 = DimList(1, 1, 1, 2, 2)
    alias s2 = DimList(1, 1, 2, 2, 2)
    alias s3 = DimList(1, 1, 3, 2, 2)

    var x1 = NDBuffer[type, rank, s1].stack_allocation()
    var x2 = NDBuffer[type, rank, s2].stack_allocation()
    var x3 = NDBuffer[type, rank, s3].stack_allocation()
    x1.fill(0)
    x2.fill(1)
    x3.fill(2)
    var x1_dyn = NDBuffer[type, rank](x1.data, s1)
    var x2_dyn = NDBuffer[type, rank](x2.data, s2)
    var x3_dyn = NDBuffer[type, rank](x3.data, s3)

    alias out_shape = DimList(1, 1, 6, 2, 2)
    var output = NDBuffer[type, rank, out_shape]().stack_allocation()
    output.fill(-1)
    var output_dyn = NDBuffer[type, rank](output.data, out_shape)

    var input_list = VariadicList[NDBuffer[type, rank]](x1_dyn, x2_dyn, x3_dyn)

    var input_vec = variadic_list_to_vector(input_list)
    _concat_serial[rank, type](output_dyn, concat_axis, input_vec)
    input_vec._del_old()

    # CHECK-COUNT-4: 0.0
    # CHECK-COUNT-8: 1.0
    # CHECK-COUNT-12: 2.0
    for i in range(out_shape.product[rank]().get()):
        print(output.flatten()[i])


fn main() raises:
    test_concat()
    test_concat_parallel()
    test_concat_inner()
