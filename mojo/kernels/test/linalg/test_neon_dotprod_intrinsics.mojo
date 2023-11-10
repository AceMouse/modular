# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
#
# This file tests the Neon dotprod intrinsics
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: neon_dotprod
# RUN: %mojo -debug-level full %s | FileCheck %s

from Neon import _neon_dotprod, _neon_dotprod_lane
from sys.info import has_neon_int8_dotprod


# CHECK-LABEL: test_has_neon_int8_dotprod
fn test_has_neon_int8_dotprod():
    print("== test_has_neon_int8_dotprod")

    # CHECK: True
    print(has_neon_int8_dotprod())


# CHECK-LABEL: test_int8_dotprod
fn test_int8_dotprod():
    print("== test_int8_dotprod")

    let a = SIMD[DType.int8, 16](
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    )
    let b = SIMD[DType.int8, 16](
        -8, -7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 7
    )
    let c = SIMD[DType.int32, 4](10000, 20000, 30000, 40000)

    # CHECK: [9966, 19950, 30062, 40302]
    print(_neon_dotprod(c, a, b))

    # CHECK: [10014, 20038, 30062, 40086]
    print(_neon_dotprod_lane[2](c, a, b))


# CHECK-LABEL: test_uint8_dotprod
fn test_uint8_dotprod():
    print("== test_uint8_dotprod")

    let a = SIMD[DType.uint8, 16](
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
    )
    let b = SIMD[DType.uint8, 16](
        0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224, 240
    )
    let c = SIMD[DType.int32, 4](10000, 20000, 30000, 40000)

    # CHECK: [10224, 22016, 35856, 51744]
    print(_neon_dotprod(c, a, b))

    # CHECK: [10608, 22016, 33424, 44832]
    print(_neon_dotprod_lane[1](c, a, b))


fn main():
    test_has_neon_int8_dotprod()
    test_int8_dotprod()
    test_uint8_dotprod()
