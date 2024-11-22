# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo-no-debug %s

from math import ceildiv, sqrt
from sys import simdwidthof

from buffer import Buffer, NDBuffer
from buffer.dimlist import DimList
from gpu.host._compile import _get_gpu_target
from gpu.host import DeviceBuffer, DeviceContext
from memory import UnsafePointer
from nn.normalization import *
from testing import assert_almost_equal

from utils.index import Index, IndexList


fn compute_rms[
    type: DType
](data: Buffer[type], size: Int, eps: Scalar[type]) -> Scalar[type]:
    var sum_of_squares = Scalar[type]()
    for i in range(size):
        sum_of_squares += data[i] * data[i]
    return sqrt((sum_of_squares / len(data)) + eps).cast[type]()


fn run_rms_norm_gpu[
    type: DType, rank: Int
](ctx: DeviceContext, shape: IndexList[rank], rtol: Scalar[type] = 0.01) raises:
    print("== run_rms_norm_gpu")

    var cols = shape[rank - 1]
    var rows = shape.flattened_length() // cols

    var data_h = UnsafePointer[Scalar[type]].alloc(rows * cols)
    var res = UnsafePointer[Scalar[type]].alloc(rows * cols)
    var gamma_h = UnsafePointer[Scalar[type]].alloc(cols)

    for i in range(rows * cols):
        var val = Scalar[type](i)
        data_h[i] = val

    for i in range(cols):
        gamma_h[i] = ((i + cols) / cols).cast[type]()

    var data_d = ctx.enqueue_create_buffer[type](rows * cols)
    var gamma_d = ctx.enqueue_create_buffer[type](cols)
    var beta_d = ctx.enqueue_create_buffer[type](cols)

    var param_shape = Index(cols)

    var data_buf = NDBuffer[type, rank](data_d.ptr, shape)
    var gamma = NDBuffer[type, 1](gamma_d.ptr, param_shape)
    var epsilon = Scalar[type](0.001)

    ctx.enqueue_copy_to_device(data_d, data_h)
    ctx.enqueue_copy_to_device(gamma_d, gamma_h)

    @__copy_capture(data_buf)
    @always_inline
    @parameter
    fn input_fn[
        width: Int, _rank: Int
    ](idx: IndexList[_rank]) -> SIMD[type, width]:
        return data_buf.load[width=width](rebind[IndexList[rank]](idx))

    rms_norm_gpu[input_fn](shape, gamma, epsilon, data_buf, ctx)
    ctx.enqueue_copy_from_device(res, data_d)
    ctx.synchronize()

    for r in range(rows):
        var vec = Buffer[type](data_h + r * cols, cols)
        var rms_ref = compute_rms(vec, cols, epsilon)
        for c in range(cols):
            var idx = r * cols + c
            var val = (data_h[idx] / rms_ref) * gamma_h[c]
            assert_almost_equal(val, res[idx], rtol=rtol)

    _ = data_d
    _ = gamma_d

    data_h.free()
    res.free()
    gamma_h.free()


def main():
    with DeviceContext() as ctx:
        run_rms_norm_gpu[DType.float32](ctx, Index(5))
        run_rms_norm_gpu[DType.float32](ctx, Index(3, 4, 10, 20, 8))
        run_rms_norm_gpu[DType.float32](ctx, Index(1, 5, 6, 10, 128))
        run_rms_norm_gpu[DType.float32](ctx, Index(2, 5))
        run_rms_norm_gpu[DType.float32](ctx, Index(2, 55))
        run_rms_norm_gpu[DType.float32](ctx, Index(7, 557))
        run_rms_norm_gpu[DType.float32](ctx, Index(2, 8191))
        run_rms_norm_gpu[DType.float32](ctx, Index(2, 8192))
        run_rms_norm_gpu[DType.float32](ctx, Index(2, 16384))
        run_rms_norm_gpu[DType.float32](ctx, Index(2, 16385))
