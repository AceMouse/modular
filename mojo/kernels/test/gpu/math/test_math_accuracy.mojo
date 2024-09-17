# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo-no-debug %s

from math import exp, exp2, log
from sys import simdwidthof

from algorithm.functional import elementwise
from buffer import DimList, NDBuffer
from gpu import *
from gpu.host._compile import _get_nvptx_target
from gpu.host.device_context import DeviceContext
from testing import assert_almost_equal

alias length = 8192


def run_elementwise[
    type: DType, math_fn: fn (x: SIMD) -> __type_of(x)
](ctx: DeviceContext, in_host: NDBuffer[type, 1, DimList(length)]):
    alias pack_size = simdwidthof[type, target = _get_nvptx_target()]()

    var out_host = NDBuffer[type, 1, DimList(length)].stack_allocation()

    var flattened_length = in_host.num_elements()

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
        var result = math_fn(val)
        out_buffer.store[width=simd_width](idx, result)

    elementwise[func, pack_size, target="cuda"](StaticIntTuple[1](length), ctx)
    ctx.synchronize()

    ctx.enqueue_copy_from_device(out_host.data, out_device)

    for i in range(length):
        var expected_value = math_fn(in_host[i])

        alias atol = 1e-05 if type == DType.float32 else 1e-4
        alias rtol = 2e-05 if type == DType.float32 else 2e-2
        assert_almost_equal[type, 1](
            out_host[i],
            expected_value,
            msg="values did not match at position " + str(i),
            atol=atol,
            rtol=rtol,
        )

    _ = in_device
    _ = out_device


def test_exp[type: DType](ctx: DeviceContext):
    var input = NDBuffer[type, 1, DimList(length)].stack_allocation()
    alias epsilon = 0.001
    for i in range(length):
        input[i] = log(Scalar[type](i) + epsilon)
    run_elementwise[type, exp](ctx, input)


def test_exp2[type: DType](ctx: DeviceContext):
    var input = NDBuffer[type, 1, DimList(length)].stack_allocation()
    alias epsilon = 0.001
    for i in range(length):
        input[i] = log(Scalar[type](i) + epsilon)
    run_elementwise[type, exp2](ctx, input)


def main():
    with DeviceContext() as ctx:
        test_exp[DType.float32](ctx)
        test_exp[DType.float16](ctx)
        test_exp[DType.bfloat16](ctx)
        test_exp2[DType.float32](ctx)
        test_exp2[DType.float16](ctx)
        test_exp2[DType.bfloat16](ctx)
