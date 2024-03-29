# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo -debug-level full %s | FileCheck %s

from collections import List
from math import ceildiv, erf, exp, tanh
from sys.info import num_physical_cores, simdwidthof

from algorithm import elementwise
from buffer import Buffer
from buffer.list import Dim, DimList

from utils.index import StaticIntTuple


# CHECK-LABEL: test_elementwise_1d
fn test_elementwise_1d():
    print("== test_elementwise_1d")

    var num_work_items = num_physical_cores()

    alias num_elements = 64
    var ptr = DTypePointer[DType.float32].alloc(num_elements)

    var vector = Buffer[DType.float32, num_elements](ptr)

    for i in range(len(vector)):
        vector[i] = i

    var chunk_size = ceildiv(len(vector), num_work_items)

    @always_inline
    @__copy_capture(vector)
    @parameter
    fn func[simd_width: Int, rank: Int](idx: StaticIntTuple[rank]):
        var elem = vector.load[width=simd_width](idx[0])
        var val = exp(erf(tanh(elem + 1)))
        vector.store[width=simd_width](idx[0], val)

    elementwise[func, simdwidthof[DType.float32](), 1](
        StaticIntTuple[1](num_elements)
    )

    # CHECK: 2.051446{{[0-9]+}}
    print(vector[0])

    ptr.free()


fn main():
    test_elementwise_1d()
