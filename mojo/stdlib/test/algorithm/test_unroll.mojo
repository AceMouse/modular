# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo -debug-level full %s | FileCheck %s

from algorithm import unroll

from utils.index import StaticIntTuple

# CHECK-LABEL: test_unroll
fn test_unroll():
    print("test_unroll")

    # CHECK: 0
    # CHECK: 1
    # CHECK: 2
    # CHECK: 3
    @parameter
    fn func[idx: Int]():
        print(idx)

    unroll[4, func]()


# CHECK-LABEL: test_unroll
fn test_unroll2():
    print("test_unroll")

    # CHECK: (0, 0)
    # CHECK: (0, 1)
    # CHECK: (1, 0)
    # CHECK: (1, 1)
    @parameter
    fn func[idx0: Int, idx1: Int]():
        print(StaticIntTuple[2](idx0, idx1))

    unroll[2, 2, func]()


# CHECK-LABEL: test_unroll
fn test_unroll3():
    print("test_unroll")

    # CHECK: (0, 0, 0)
    # CHECK: (0, 0, 1)
    # CHECK: (0, 0, 2)
    # CHECK: (0, 1, 0)
    # CHECK: (0, 1, 1)
    # CHECK: (0, 1, 2)
    # CHECK: (1, 0, 0)
    # CHECK: (1, 0, 1)
    # CHECK: (1, 0, 2)
    # CHECK: (1, 1, 0)
    # CHECK: (1, 1, 1)
    # CHECK: (1, 1, 2)
    # CHECK: (2, 0, 0)
    # CHECK: (2, 0, 1)
    # CHECK: (2, 0, 2)
    # CHECK: (2, 1, 0)
    # CHECK: (2, 1, 1)
    # CHECK: (2, 1, 2)
    # CHECK: (3, 0, 0)
    # CHECK: (3, 0, 1)
    # CHECK: (3, 0, 2)
    # CHECK: (3, 1, 0)
    # CHECK: (3, 1, 1)
    # CHECK: (3, 1, 2)
    @parameter
    fn func[idx0: Int, idx1: Int, idx2: Int]():
        print(StaticIntTuple[3](idx0, idx1, idx2))

    unroll[4, 2, 3, func]()


fn main():
    test_unroll()
    test_unroll2()
    test_unroll3()
