# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# FIXME: KERN-1377
# UNSUPPORTED: AMD-GPU
# RUN: %mojo-no-debug %s

from gpu.host._compile import _compile_code_asm, _get_gpu_target
from nn.mha_mask import CausalMask, TileMaskStatus
from testing import assert_equal, assert_true

from utils.index import Index, IndexList
from utils.numerics import min_or_neg_inf


def test_causal_mask():
    alias type = DType.int32

    print("test_causal_mask")
    var mask = CausalMask()

    # Check mask value.
    # TODO(KERN-782): should be -inf but softmax saturates with NaNs.
    var mask_val = -10000
    var masked_vec = mask.mask(Index(0, 0, 4, 3), SIMD[type, 4](0, 1, 2, 3))
    assert_equal(masked_vec, SIMD[type, 4](0, 1, mask_val, mask_val))

    masked_vec = mask.mask(Index(0, 0, 4, 0), SIMD[type, 4](0, 1, 2, 3))
    assert_equal(masked_vec, SIMD[type, 4](0, 1, 2, 3))

    masked_vec = mask.mask(Index(0, 0, 1, 6), SIMD[type, 4](0, 1, 2, 3))
    assert_equal(masked_vec, SIMD[type, 4](mask_val))

    # Check tile status.
    assert_true(
        mask.status(Index(4, 4), Index(4, 4)) == TileMaskStatus.PARTIAL_MASK
    )
    assert_true(
        mask.status(Index(0, 2), Index(2, 2)) == TileMaskStatus.FULL_MASK
    )
    assert_true(mask.status(Index(2, 0), Index(2, 2)) == TileMaskStatus.NO_MASK)
    assert_true(
        mask.status(Index(1, 5), Index(2, 2)) == TileMaskStatus.FULL_MASK
    )
    assert_true(
        mask.status(Index(64, 0), Index(64, 128)) == TileMaskStatus.PARTIAL_MASK
    )
    assert_true(
        mask.status(Index(64, 128), Index(64, 128)) == TileMaskStatus.FULL_MASK
    )
    assert_true(
        mask.status(Index(64, 256), Index(64, 128)) == TileMaskStatus.FULL_MASK
    )
    assert_true(
        mask.status(Index(64, 384), Index(64, 128)) == TileMaskStatus.FULL_MASK
    )


def test_causal_mask_asm():
    """Verify mask comparison is not in 64 bits."""

    print("== test_causal_mask_asm")

    fn kernel(q_idx: UInt32, k_idx: UInt32) -> Scalar[DType.float32]:
        var mask = CausalMask()
        var vec = mask.mask(
            IndexList[4, element_bitwidth=32, unsigned=True](
                0, 0, int(q_idx), int(k_idx)
            ),
            SIMD[DType.float32, 4](0),
        )
        if (
            mask.status(
                Index[element_bitwidth=32, unsigned=True](q_idx, k_idx),
                Index[element_bitwidth=32, unsigned=True](4, 5),
            )
            == TileMaskStatus.PARTIAL_MASK
        ):
            return vec[3]

        return vec[2]

    alias asm = _compile_code_asm[kernel, target = _get_gpu_target()]()
    assert_true("setp.lt.u64" not in asm)
    assert_true("setp.lt.s64" not in asm)


def main():
    test_causal_mask()
    test_causal_mask_asm()
