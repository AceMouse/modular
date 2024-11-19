# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo-no-debug %s

from math import exp
from sys import has_neon, simdwidthof

from algorithm.functional import elementwise
from buffer import DimList, NDBuffer
from gpu import *
from gpu.host import DeviceContext
from gpu.host._compile import _get_gpu_target
from testing import *

from utils import Index


def run_elementwise[type: DType](ctx: DeviceContext):
    alias length = 256

    alias pack_size = simdwidthof[type, target = _get_gpu_target()]()

    var in_host = NDBuffer[type, 1, DimList(length)].stack_allocation()
    var out_host = NDBuffer[type, 1, DimList(length)].stack_allocation()

    var flattened_length = in_host.num_elements()
    for i in range(length):
        in_host[i] = 0.001 * (Scalar[type](i) - length // 2)

    var in_device = ctx.enqueue_create_buffer[type](flattened_length)
    var out_device = ctx.enqueue_create_buffer[type](flattened_length)

    ctx.enqueue_copy_to_device(in_device, in_host.data)

    var in_buffer = NDBuffer[type, 1](in_device.ptr, Index(length))
    var out_buffer = NDBuffer[type, 1](out_device.ptr, Index(length))

    @always_inline
    @__copy_capture(out_buffer, in_buffer)
    @parameter
    fn func[simd_width: Int, rank: Int](idx0: IndexList[rank]):
        var idx = rebind[IndexList[1]](idx0)

        out_buffer.store[width=simd_width](
            idx, exp(in_buffer.load[width=simd_width](idx))
        )

    elementwise[func, pack_size, target="gpu"](IndexList[1](length), ctx)

    ctx.enqueue_copy_from_device(out_host.data, out_device)

    ctx.synchronize()

    for i in range(length):
        var msg = (
            "values did not match at position "
            + str(i)
            + " for dtype="
            + str(type)
            + " and value="
            + str(in_host[i])
        )

        @parameter
        if type is DType.float32:
            assert_almost_equal(
                out_host[i],
                exp(in_host[i]),
                msg=msg,
                atol=1e-08,
                rtol=1e-05,
            )
        else:
            assert_almost_equal(
                out_host[i],
                exp(in_host[i]),
                msg=msg,
                atol=1e-04,
                rtol=1e-03,
            )

    _ = in_device
    _ = out_device


def main():
    with DeviceContext() as ctx:
        run_elementwise[DType.float16](ctx)
        run_elementwise[DType.bfloat16](ctx)
        run_elementwise[DType.float32](ctx)
