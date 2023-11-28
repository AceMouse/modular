# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo -debug-level full %s | FileCheck %s


from math import iota
from utils.vector import DynamicVector

from algorithm.reduction import _get_nd_indices_from_flat_index
from memory.buffer import NDBuffer
from runtime.llcl import OwningOutputChainPtr, Runtime
from TopK import _top_k


struct TestTensor[rank: Int, type: DType]:
    var storage: DynamicVector[SIMD[type, 1]]
    var shape: StaticIntTuple[rank]

    fn __init__(inout self, shape: StaticIntTuple[rank]):
        self.storage = DynamicVector[SIMD[type, 1]](shape.flattened_length())
        self.storage.resize(shape.flattened_length(), 0)
        self.shape = shape

    fn __moveinit__(inout self, owned existing: Self):
        self.storage = existing.storage
        self.shape = existing.shape

    fn to_ndbuffer(
        self,
    ) -> NDBuffer[rank, DimList.create_unknown[rank](), type]:
        return NDBuffer[rank, DimList.create_unknown[rank](), type](
            rebind[DTypePointer[type]](self.storage.data), self.shape
        )


fn test_case[
    rank: Int,
    type: DType,
    fill_fn: fn[rank: Int, type: DType] (
        inout NDBuffer[rank, DimList.create_unknown[rank](), type]
    ) capturing -> None,
](
    K: Int,
    axis: Int,
    input_shape: StaticIntTuple[rank],
    largest: Bool = True,
    sorted: Bool = True,
):
    let input = TestTensor[rank, type](input_shape)

    var output_shape = input_shape
    output_shape[axis] = K
    let out_vals = TestTensor[rank, type](output_shape)
    let out_idxs = TestTensor[rank, DType.int64](output_shape)

    var input_buf = input.to_ndbuffer()
    fill_fn[rank, type](input_buf)

    with Runtime() as rt:
        let out_chain = OwningOutputChainPtr(rt)
        _top_k(
            input.to_ndbuffer(),
            K,
            axis,
            largest,
            out_vals.to_ndbuffer(),
            out_idxs.to_ndbuffer(),
            out_chain.borrow(),
            1,  # force multithreading for small test cases,
            sorted,
        )
        out_chain.wait()

    let xxx_no_lifetimes = input ^  # intentionally bad name

    for i in range(out_vals.storage.size):
        print_no_newline(out_vals.storage[i])
        print_no_newline(",")
    print("")
    for i in range(out_idxs.storage.size):
        print_no_newline(out_idxs.storage[i])
        print_no_newline(",")
    print("")


fn main():
    @parameter
    fn fill_iota[
        rank: Int, type: DType
    ](inout buf: NDBuffer[rank, DimList.create_unknown[rank](), type]):
        iota[type](buf.data, buf.get_shape().flattened_length())

    fn test_1d_sorted():
        print("== test_1d_sorted")
        test_case[1, DType.float32, fill_iota](
            5, 0, StaticIntTuple[1](10), sorted=True
        )

    # CHECK-LABEL: test_1d_sorted
    # CHECK: 9.0,8.0,7.0,6.0,5.0,
    # CHECK: 9,8,7,6,5,
    test_1d_sorted()

    fn test_1d_notsorted():
        print("== test_1d_notsorted")
        test_case[1, DType.float32, fill_iota](
            5, 0, StaticIntTuple[1](10), sorted=False
        )

    # CHECK-LABEL: test_1d_notsorted
    # CHECK: 8.0,7.0,6.0,9.0,5.0,
    # CHECK: 8,7,6,9,5,
    test_1d_notsorted()

    fn test_axis_1():
        print("== test_axis_1")
        test_case[2, DType.float32, fill_iota](
            2, 1, StaticIntTuple[2](4, 4), sorted=True
        )

    # CHECK-LABEL: test_axis_1
    # CHECK: 3.0,2.0,7.0,6.0,11.0,10.0,15.0,14.0,
    # CHECK-NEXT: 3,2,3,2,3,2,3,2,
    test_axis_1()

    fn test_axis_1_notsorted():
        print("== test_axis_1_notsorted")
        test_case[2, DType.float32, fill_iota](
            2, 1, StaticIntTuple[2](4, 4), sorted=False
        )

    # CHECK-LABEL: test_axis_1_notsorted
    # CHECK: 3.0,2.0,7.0,6.0,11.0,10.0,15.0,14.0,
    # CHECK-NEXT: 3,2,3,2,3,2,3,2,
    test_axis_1_notsorted()

    fn test_smallest():
        print("== test_smallest")
        test_case[2, DType.float32, fill_iota](
            2, 1, StaticIntTuple[2](4, 4), False
        )

    # CHECK-LABEL: test_smallest
    # CHECK: 0.0,1.0,4.0,5.0,8.0,9.0,12.0,13.0,
    # CHECK-NEXT: 0,1,0,1,0,1,0,1,
    test_smallest()

    fn test_axis_0():
        print("== test_axis_0")
        test_case[2, DType.float32, fill_iota](2, 0, StaticIntTuple[2](4, 4))

    # CHECK-LABEL: test_axis_0
    # CHECK: 12.0,13.0,14.0,15.0,8.0,9.0,10.0,11.0,
    # CHECK-NEXT: 3,3,3,3,2,2,2,2,
    test_axis_0()

    @parameter
    fn fill_identical[
        rank: Int, type: DType
    ](inout buf: NDBuffer[rank, DimList.create_unknown[rank](), type]):
        buf.fill(1)

    fn test_identical():
        print("== test_identical")
        test_case[2, DType.float32, fill_identical](
            3, 0, StaticIntTuple[2](4, 4)
        )

    # CHECK-LABEL: test_identical
    # CHECK: 1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,
    # CHECK-NEXT: 0,0,0,0,1,1,1,1,2,2,2,2,
    test_identical()

    fn test_identical_large():
        print("== test_identical_large")
        test_case[2, DType.float32, fill_identical](
            3, 0, StaticIntTuple[2](33, 33)
        )

    # CHECK-LABEL: test_identical_large
    # CHECK: 1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,1.0,
    # CHECK: 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
    test_identical_large()

    fn test_max_k():
        print("== test_max_k")
        test_case[2, DType.float32, fill_iota](3, 0, StaticIntTuple[2](3, 4))

    # CHECK-LABEL: test_max_k
    # CHECK: 8.0,9.0,10.0,11.0,4.0,5.0,6.0,7.0,0.0,1.0,2.0,3.0,
    # CHECK-NEXT: 2,2,2,2,1,1,1,1,0,0,0,0,
    test_max_k()

    @parameter
    fn fill_custom[
        rank: Int, type: DType
    ](inout buf: NDBuffer[rank, DimList.create_unknown[rank](), type]):
        let flat_buf = buf.flatten()
        for i in range(len(flat_buf)):
            flat_buf[i] = len(flat_buf) - i - 1
        flat_buf[0] = -1

    fn test_5d():
        print("== test_5d")
        test_case[5, DType.float32, fill_custom](
            1, 1, StaticIntTuple[5](1, 4, 3, 2, 1)
        )

    # CHECK-LABEL: == test_5d
    # CHECK: 17.0,22.0,21.0,20.0,19.0,18.0,
    # CHECK-NEXT: 1,0,0,0,0,0,
    test_5d()
