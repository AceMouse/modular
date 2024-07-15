# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: linux
# RUN: %mojo %s

from math import tanh
from random import randn, seed

from buffer import Buffer
from internal_utils import compare
from test_utils import libm_call
from testing import assert_almost_equal


fn tanh_libm[
    type: DType, simd_width: Int
](arg: SIMD[type, simd_width]) -> SIMD[type, simd_width]:
    return libm_call[type, simd_width, "tanhf", "tanh"](arg)


def test_tanh_tfvals_fp32():
    alias dtype = DType.float32

    # The following input values for x are taken from
    # https://github.com/modularml/modular/issues/28981#issuecomment-1890182667
    var x = Buffer[dtype, 4].stack_allocation()
    x.store[width=4](
        0,
        SIMD[dtype, 4](
            -1.2583316564559937,
            -8.081921577453613,
            -8.626264572143555,
            -0.7127348184585571,
        ),
    )

    var y = Buffer[dtype, 4].stack_allocation()
    for i in range(4):
        y[i] = tanh(x[i])

    #################################################
    # TF results
    # use `tf.print(tf.math.tanh(numpy.float32(x)))`
    var tfvals_fp32 = Buffer[dtype, 4].stack_allocation()
    tfvals_fp32.store[width=4](
        0, SIMD[dtype, 4](-0.850603521, -1, -1, -0.612388909)
    )

    # abs_rel_err = (abs_min, abs_max, rel_min, rel_max)
    var abs_rel_err = SIMD[dtype, 4](
        0.0, 1.1920928955078125e-07, 0.0, 1.1920928955078125e-07
    )
    var err = compare[dtype](
        y.data, tfvals_fp32.data, 4, msg="Compare Mojo vs. Tensorflow FP32"
    )
    assert_almost_equal(err, abs_rel_err)


def test_tanh_tfvals_fp64():
    alias dtype = DType.float64

    # The following input values for x are taken from
    # https://github.com/modularml/modular/issues/28981#issuecomment-1890182667
    var x = Buffer[dtype, 4].stack_allocation()
    x.store[width=4](
        0,
        SIMD[dtype, 4](
            -1.2583316564559937,
            -8.081921577453613,
            -8.626264572143555,
            -0.7127348184585571,
        ),
    )

    var y = Buffer[dtype, 4].stack_allocation()
    for i in range(4):
        y[i] = tanh(x[i])

    #################################################
    # TF results
    # use `tf.print(tf.math.tanh(numpy.float64(x)))`
    var tfvals_fp64 = Buffer[dtype, 4].stack_allocation()
    tfvals_fp64.store[width=4](
        0,
        SIMD[dtype, 4](
            -0.85060351067231821,
            -0.99999980894339091,
            -0.99999993567914991,
            -0.61238890225714893,
        ),
    )

    # abs_rel_err = (abs_min, abs_max, rel_min, rel_max)
    var abs_rel_err = SIMD[dtype, 4](
        7.2062200651146213e-09,
        1.2149700800989649e-08,
        8.3577847290501252e-09,
        1.4283624095774667e-08,
    )

    var err = compare[dtype](
        y.data, tfvals_fp64.data, 4, msg="Compare Mojo vs. Tensorflow FP64"
    )
    assert_almost_equal(err, abs_rel_err)


def test_tanh_libm[N: Int = 8192]():
    seed(0)
    alias test_dtype = DType.float32
    var x32 = DTypePointer[test_dtype].alloc(N)
    randn[test_dtype](x32.address, N, 0, 9.0)
    print("For N=" + str(N) + " randomly generated vals; mean=0.0, var=9.0")

    ####################
    # mojo tanh result
    ####################
    var y32 = DTypePointer[test_dtype].alloc(N)
    for i in range(N):
        y32[i] = tanh(x32[i])

    ####################
    ## libm tanh result
    ####################
    var libm_out = DTypePointer[test_dtype].alloc(N)
    for i in range(N):
        libm_out[i] = tanh_libm(x32[i])

    # abs_rel_err = (abs_min, abs_max, rel_min, rel_max)
    var abs_rel_err = SIMD[test_dtype, 4](
        0.0, 2.384185791015625e-07, 0.0, 2.5438197326366208e-07
    )

    var err = compare[test_dtype](y32, libm_out, N, msg="Compare Mojo vs. LibM")
    assert_almost_equal(err, abs_rel_err)

    x32.free()
    y32.free()
    libm_out.free()


def test_direct():
    alias F32x4 = SIMD[DType.float32, 4]
    var f32x4 = 0.5 * F32x4(0.0, 1.0, 2.0, 3.0)
    assert_almost_equal(
        tanh(f32x4), F32x4(0.0, 0.462117165, 0.761594176, 0.905148208)
    )
    assert_almost_equal(
        tanh(0.5 * f32x4), F32x4(0.0, 0.244918659, 0.462117165, 0.635149002)
    )

    alias F64x4 = SIMD[DType.float64, 4]
    var f64x4 = 0.5 * F64x4(0.0, 1.0, 2.0, 3.0)
    assert_almost_equal(
        tanh(f64x4), F64x4(0.0, 0.462117165, 0.761594176, 0.905148208)
    )
    assert_almost_equal(
        tanh(0.5 * f64x4), F64x4(0.0, 0.244918659, 0.462117165, 0.635149002)
    )


def main():
    test_direct()
    test_tanh_tfvals_fp32()
    test_tanh_tfvals_fp64()
    test_tanh_libm()
