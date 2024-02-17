# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo %s | FileCheck %s

from kernel_utils.dynamic_tuple import *
from testing import assert_equal, assert_not_equal

from utils.variant import Variant

alias General = Variant[Int, Float32, String]


# FIXME: This is a horrible hack around Mojo's lack or proper trait inheritance
struct GeneralDelegate(ElementDelegate):
    @always_inline
    @staticmethod
    fn is_equal[T: CollectionElement](va: Variant[T], vb: Variant[T]) -> Bool:
        if va.isa[General]() and vb.isa[General]():
            let a = va.get[General]()
            let b = vb.get[General]()
            if a.isa[Int]() and b.isa[Int]():
                return a.get[Int]() == b.get[Int]()
            elif a.isa[Float32]() and b.isa[Float32]():
                return a.get[Float32]() == b.get[Float32]()
            elif a.isa[String]() and b.isa[String]():
                return a.get[String]() == b.get[String]()
        trap("Unexpected data type.")
        return False

    @always_inline
    @staticmethod
    fn to_string[T: CollectionElement](a: Variant[T]) -> String:
        if a.isa[General]():
            let v = a.get[General]()
            if v.isa[Int]():
                return v.get[Int]()
            if v.isa[Float32]():
                return v.get[Float32]()
            if v.isa[String]():
                return v.get[String]()
        trap("Unexpected data type.")
        return "#"


alias GeneralTupleBase = DynamicTupleBase[General, GeneralDelegate]
alias GeneralElement = GeneralTupleBase.Element
alias GeneralTuple = DynamicTuple[General, GeneralDelegate]


# CHECK-LABEL: test_tuple_general
fn test_tuple_general() raises:
    print("== test_tuple_general")

    # Test General tuple operations

    var gt = GeneralTuple(
        General(1),
        GeneralTuple(
            General(Float32(3.5)),
            General(String("Mojo")),
        ),
    )

    # CHECK: 1
    # CHECK: 3.5
    # CHECK: Mojo
    # CHECK: (1, (3.5, Mojo))
    print(gt[0].value().get[Int]())
    print(gt[1][0].value().get[Float32]())
    print(gt[1][1].value().get[String]())
    print(gt)

    # CHECK: (7, (3.5, Mojo))
    gt[0] = General(7)
    print(gt)

    # Test General tuple comparison

    var gt2 = GeneralTuple(
        General(2),
        GeneralTuple(
            General(Float32(3.5)),
            General(String("Mojo")),
        ),
    )
    assert_not_equal(gt, gt2)

    gt2[0] = General(7)
    assert_equal(gt, gt2)


def main():
    test_tuple_general()
