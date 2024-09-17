# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo-no-debug %s

from math import log, log2, log10
from sys import simdwidthof

from algorithm.functional import elementwise
from buffer import DimList, NDBuffer
from gpu import *
from gpu.host._compile import _get_nvptx_target
from gpu.host.device_context import DeviceContext
from testing import assert_almost_equal


def run_elementwise[
    type: DType, log_fn: fn (x: SIMD) -> __type_of(x)
](ctx: DeviceContext):
    alias length = 8192

    alias pack_size = simdwidthof[type, target = _get_nvptx_target()]()

    var in_host = NDBuffer[type, 1, DimList(length)].stack_allocation()
    var out_host = NDBuffer[type, 1, DimList(length)].stack_allocation()

    var flattened_length = in_host.num_elements()

    alias epsilon = 0.001
    for i in range(length):
        in_host[i] = Scalar[type](i) + epsilon

    var in_device = ctx.create_buffer[type](flattened_length)
    var out_device = ctx.create_buffer[type](flattened_length)

    ctx.enqueue_copy_to_device(in_device, in_host.data)

    var in_buffer = NDBuffer[type, 1](in_device.ptr, (length))
    var out_buffer = NDBuffer[type, 1](out_device.ptr, (length))

    @always_inline
    @__copy_capture(out_buffer, in_buffer)
    @parameter
    fn func[simd_width: Int, rank: Int](idx0: StaticIntTuple[rank]):
        var idx = rebind[StaticIntTuple[1]](idx0)
        var val = in_buffer.load[width=simd_width](idx)
        var result = log_fn(val)
        out_buffer.store[width=simd_width](idx, result)

    elementwise[func, pack_size, target="cuda"](StaticIntTuple[1](length), ctx)
    ctx.synchronize()

    ctx.enqueue_copy_from_device(out_host.data, out_device)

    for i in range(length):
        var expected_value = log_fn(in_host[i])

        alias atol = 1e-07 if type == DType.float32 else 1e-4
        alias rtol = 2e-07 if type == DType.float32 else 2e-2
        assert_almost_equal[type, 1](
            out_host[i],
            expected_value,
            msg="values did not match at position " + str(i),
            atol=atol,
            rtol=rtol,
        )

    _ = in_device
    _ = out_device


def main():
    with DeviceContext() as ctx:
        run_elementwise[DType.float32, log](ctx)
        run_elementwise[DType.float32, log10](ctx)
        run_elementwise[DType.float32, log2](ctx)
        run_elementwise[DType.float16, log](ctx)
        run_elementwise[DType.float16, log10](ctx)
        run_elementwise[DType.float16, log2](ctx)
        run_elementwise[DType.bfloat16, log](ctx)
        run_elementwise[DType.bfloat16, log10](ctx)
        run_elementwise[DType.bfloat16, log2](ctx)
