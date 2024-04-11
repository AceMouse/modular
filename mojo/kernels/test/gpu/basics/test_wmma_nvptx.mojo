# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo-no-debug %s

from sys.param_env import is_defined

from gpu.host._compile import _compile_code
from gpu.mma import mma
from testing import *


# CHECK-LABEL: SM80_16x8x8_F16F16F16F16_TN
fn SM80_16x8x8_F16F16F16F16_TN(
    a: SIMD[DType.float16, 4],
    b: SIMD[DType.float16, 2],
    c: SIMD[DType.float16, 4],
) -> SIMD[DType.float16, 4]:
    var d = SIMD[DType.float16, 4]()
    mma(d, a, b, c)
    return d


def test_SM80_16x8x8_F16F16F16F16_TN():
    alias asm = str(
        _compile_code[
            __type_of(SM80_16x8x8_F16F16F16F16_TN), SM80_16x8x8_F16F16F16F16_TN
        ]().asm
    )
    assert_true("mma.sync.aligned.m16n8k8.row.col.f16.f16.f16.f16" in asm)
    assert_true("{%r10, %r11}," in asm)
    assert_true("{%r5, %r6}," in asm)
    assert_true("{%r9}," in asm)
    assert_true("{%r1, %r2};" in asm)


# CHECK-LABEL: SM80_m16n8k4_F32TF32TF32F32_TN
fn SM80_m16n8k4_F32TF32TF32F32_TN(
    a: SIMD[DType.float32, 2],
    b: Float32,
    c: SIMD[DType.float32, 4],
) -> SIMD[DType.float32, 4]:
    var d = SIMD[DType.float32, 4]()
    mma(d, a, b, c)
    return d


def test_SM80_m16n8k4_F32TF32TF32F32_TN():
    alias asm = str(
        _compile_code[
            __type_of(SM80_m16n8k4_F32TF32TF32F32_TN),
            SM80_m16n8k4_F32TF32TF32F32_TN,
        ]().asm
    )
    assert_true("mma.sync.aligned.m16n8k4.row.col.f32.tf32.tf32.f32" in asm)
    assert_true("{%f7, %f8, %f9, %f10}," in asm)
    assert_true("{%r2, %r1}," in asm)
    assert_true("{%r3}," in asm)
    assert_true("{%f3, %f4, %f5, %f6};" in asm)


fn SM80_m16n8k8_F32TF32TF32F32_TN(
    a: SIMD[DType.float32, 4],
    b: Float32,
    c: SIMD[DType.float32, 4],
) -> SIMD[DType.float32, 4]:
    var d = SIMD[DType.float32, 4]()
    mma(d, a, b.join(b), c)
    return d


def test_SM80_m16n8k8_F32TF32TF32F32_TN():
    alias asm = str(
        _compile_code[
            __type_of(SM80_m16n8k8_F32TF32TF32F32_TN),
            SM80_m16n8k8_F32TF32TF32F32_TN,
        ]().asm
    )
    assert_true("mma.sync.aligned.m16n8k8.row.col.f32.tf32.tf32.f32" in asm)
    assert_true("{%f5, %f6, %f7, %f8}," in asm)
    assert_true("{%r1, %r2, %r3, %r4}," in asm)
    assert_true("{%r5, %r5}," in asm)
    assert_true("{%f1, %f2, %f3, %f4};" in asm)


def main():
    @parameter
    if not is_defined["MODULAR_PRODUCTION"]():
        test_SM80_16x8x8_F16F16F16F16_TN()
        test_SM80_m16n8k4_F32TF32TF32F32_TN()
        test_SM80_m16n8k8_F32TF32TF32F32_TN()
