# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo %s | FileCheck %s
# XFAIL: *

from algorithm.functional import _elementwise_impl
from buffer import DimList, NDBuffer
from gpu import *
from gpu.host.device_context import DeviceContext
from gpu.host._compile import _get_nvptx_target
from testing import assert_almost_equal

alias type = DType.float32


def run_elementwise(exponent: BFloat16, ctx: DeviceContext):
    alias length = 256

    alias pack_size = simdwidthof[type, target = _get_nvptx_target()]()

    var in_host = NDBuffer[type, 1, DimList(length)].stack_allocation()
    var out_host = NDBuffer[type, 1, DimList(length)].stack_allocation()

    var flattened_length = in_host.num_elements()

    # Add a small constant to avoid 0^-pow.
    alias epsilon = 0.001
    for i in range(length):
        in_host[i] = (Scalar[type](i) - length // 2) + epsilon

    var in_device = ctx.create_buffer[type](flattened_length)
    var out_device = ctx.create_buffer[type](flattened_length)

    ctx.enqueue_copy_to_device(in_device, in_host.data)

    var in_buffer = NDBuffer[type, 1](in_device.ptr, (length))
    var out_buffer = NDBuffer[type, 1](out_device.ptr, (length))

    @always_inline
    @__copy_capture(out_buffer, in_buffer, exponent)
    @parameter
    fn func[simd_width: Int, rank: Int](idx0: StaticIntTuple[rank]):
        var idx = rebind[StaticIntTuple[1]](idx0)

        var val = in_buffer.load[width=simd_width](idx).cast[DType.bfloat16]()
        var result = val ** SIMD[DType.bfloat16, simd_width](exponent)
        out_buffer.store[width=simd_width](idx, result.cast[DType.float32]())

    _elementwise_impl[
        func, pack_size, 1, use_blocking_impl=True, target="cuda"
    ](StaticIntTuple[1](length), ctx)
    ctx.synchronize()

    ctx.enqueue_copy_from_device(out_host.data, out_device)

    for i in range(length):
        var expected_value = in_host[i] ** exponent.cast[DType.float32]()
        assert_almost_equal[type, 1](
            out_host[i],
            expected_value,
            msg="values did not match at position " + str(i),
            atol=1e-04,
            rtol=2e-02,
        )

    _ = in_device
    _ = out_device


# CHECK-NOT: CUDA_ERROR
def main():
    # NOTE: This is expected to fail. Keeping this around as a negative test
    # so we know when its fixed.
    var ctx = DeviceContext()
    run_elementwise(0.375, ctx)
    _ = ctx
