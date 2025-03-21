# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# FIXME: KERN-1377
# UNSUPPORTED: AMD-GPU
# RUN: %mojo-no-debug %s
from gpu.host._compile import _compile_code_asm, _get_gpu_target
from testing import assert_true


def test_operation[
    dtype: DType,
    target_arch: StringLiteral,
    op_fn: fn[width: Int] (x: SIMD[dtype, width], y: __type_of(x)) -> __type_of(
        x
    ),
    op_name: StringLiteral,
]():
    var scalar: String
    var pairwise: String

    @parameter
    if dtype is DType.float16:
        scalar = op_name + ".rn.f16 "
        pairwise = op_name + ".rn.f16x2 "
    elif target_arch == "sm_80":
        # sm_80 does not support trivial add/sub/mul bfloat16 operations, but
        # these can be implemented using the FMA instruction. Verify that the
        # backend is using FMA and not falling back to widening the inputs to
        # float32.
        scalar = "fma.rn.bf16 "
        pairwise = "fma.rn.bf16x2 "
    else:
        # sm_90 and later has wider support for bfloat16 operations.
        scalar = op_name + ".rn.bf16 "
        pairwise = op_name + ".rn.bf16x2 "

    alias target = _get_gpu_target[target_arch]()

    assert_true(scalar in _compile_code_asm[op_fn[width=1], target=target]())
    assert_true(pairwise in _compile_code_asm[op_fn[width=2], target=target]())
    assert_true(pairwise in _compile_code_asm[op_fn[width=8], target=target]())


def test_add[dtype: DType, target_arch: StringLiteral]():
    fn add[width: Int](x: SIMD[dtype, width], y: __type_of(x)) -> __type_of(x):
        return x + y

    test_operation[dtype, target_arch, add, "add"]()


def test_sub[dtype: DType, target_arch: StringLiteral]():
    fn sub[width: Int](x: SIMD[dtype, width], y: __type_of(x)) -> __type_of(x):
        return x - y

    test_operation[dtype, target_arch, sub, "sub"]()


def test_mul[dtype: DType, target_arch: StringLiteral]():
    fn mul[width: Int](x: SIMD[dtype, width], y: __type_of(x)) -> __type_of(x):
        return x * y

    test_operation[dtype, target_arch, mul, "mul"]()


def test_half_float_instruction_selection():
    def test_operations[dtype: DType, target_arch: StringLiteral]():
        test_add[dtype, target_arch]()
        test_sub[dtype, target_arch]()
        test_mul[dtype, target_arch]()

    def test_types[dtype: DType]():
        test_operations[dtype, "sm_80"]()
        test_operations[dtype, "sm_90"]()

    test_types[DType.bfloat16]()
    test_types[DType.float16]()


def test_fma[dtype: DType]():
    fn fma[
        width: Int
    ](x: SIMD[dtype, width], y: __type_of(x), z: __type_of(x)) -> __type_of(x):
        return x * y + z

    @parameter
    if dtype is DType.bfloat16:
        assert_true("fma.rn.bf16 " in _compile_code_asm[fma[width=1]]())
        assert_true("fma.rn.bf16x2 " in _compile_code_asm[fma[width=2]]())
        assert_true("fma.rn.bf16x2 " in _compile_code_asm[fma[width=8]]())
    else:
        assert_true("fma.rn.f16 " in _compile_code_asm[fma[width=1]]())
        assert_true("fma.rn.f16x2 " in _compile_code_asm[fma[width=2]]())
        assert_true("fma.rn.f16x2 " in _compile_code_asm[fma[width=8]]())


def test_cast():
    fn cast[
        src_type: DType, dst_type: DType, width: Int
    ](src: SIMD[src_type, width]) -> SIMD[dst_type, width]:
        return src.cast[dst_type]()

    assert_true(
        "cvt.rn.f16x2.f32"
        in _compile_code_asm[
            cast[src_type = DType.float32, dst_type = DType.float16, width=4]
        ]()
    )
    assert_true(
        "cvt.rn.bf16x2.f32"
        in _compile_code_asm[
            cast[src_type = DType.float32, dst_type = DType.bfloat16, width=4]
        ]()
    )
    assert_true(
        "cvt.f32.bf16"
        in _compile_code_asm[
            cast[src_type = DType.bfloat16, dst_type = DType.float32, width=1]
        ]()
    )
    assert_true(
        "cvt.f32.bf16"
        in _compile_code_asm[
            cast[src_type = DType.bfloat16, dst_type = DType.float32, width=4]
        ]()
    )


def main():
    test_half_float_instruction_selection()

    test_fma[DType.bfloat16]()
    test_fma[DType.float16]()

    test_cast()
