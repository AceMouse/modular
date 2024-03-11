# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo -debug-level full %s | FileCheck %s

from math import iota

from memory.buffer import Buffer, NDBuffer
from memory.unsafe import DTypePointer, Pointer

from utils.index import Index, StaticIntTuple
from utils.list import DimList


fn test(m: NDBuffer[DType.int32, 2, DimList(4, 4)]):
    # CHECK: [0, 1, 2, 3]
    print(m.load[width=4](0, 0))
    # CHECK: [4, 5, 6, 7]
    print(m.load[width=4](1, 0))
    # CHECK: [8, 9, 10, 11]
    print(m.load[width=4](2, 0))
    # CHECK: [12, 13, 14, 15]
    print(m.load[width=4](3, 0))

    var v = iota[DType.int32, 4]()
    m.simd_store[4](StaticIntTuple[2](3, 0), v)
    # CHECK: [0, 1, 2, 3]
    print(m.load[width=4](3, 0))


fn test_dynamic_shape(m: NDBuffer[DType.int32, 2, DimList.create_unknown[2]()]):
    # CHECK: [0, 1, 2, 3]
    print(m.load[width=4](0, 0))
    # CHECK: [4, 5, 6, 7]
    print(m.load[width=4](1, 0))
    # CHECK: [8, 9, 10, 11]
    print(m.load[width=4](2, 0))
    # CHECK: [12, 13, 14, 15]
    print(m.load[width=4](3, 0))

    var v = iota[DType.int32, 4]()
    m.simd_store[4](StaticIntTuple[2](3, 0), v)
    # CHECK: [0, 1, 2, 3]
    print(m.load[width=4](3, 0))


fn test_matrix_static():
    print("== test_matrix_static")
    var a = Buffer[DType.int32, 16].stack_allocation()
    var m = NDBuffer[DType.int32, 2, DimList(4, 4)](a.data)
    for i in range(16):
        a[i] = i
    test(m)


fn test_matrix_dynamic():
    print("== test_matrix_dynamic")
    var a = Buffer[DType.int32, 16].stack_allocation()
    var m = NDBuffer[DType.int32, 2, DimList(4, 4)](a.data)
    for i in range(16):
        a[i] = i
    test(m)


fn test_matrix_dynamic_shape():
    print("== test_matrix_dynamic_shape")
    var a = Buffer[DType.int32, 16].stack_allocation()
    # var m = Matrix[DimList(4, 4), DType.int32, False](a.data, Index(4,4), DType.int32)
    var m = NDBuffer[DType.int32, 2, DimList.create_unknown[2]()](
        a.data, Index(4, 4)
    )
    for i in range(16):
        a[i] = i
    test_dynamic_shape(m)


fn main():
    test_matrix_static()
    test_matrix_dynamic()
    test_matrix_dynamic_shape()
