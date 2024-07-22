# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo-no-debug %s | FileCheck %s

from math import cos, sin
from pathlib import Path

from gpu.host import DeviceContext
from testing import assert_almost_equal


fn run_func[
    type: DType, kernel_fn: fn (SIMD[type, 1]) capturing -> SIMD[type, 1]
](
    out_prefix: String,
    val: SIMD[type, 1],
    ref_: SIMD[type, 1],
    ctx: DeviceContext,
) raises:
    print("test trignometric functions on gpu")

    var out = ctx.create_buffer[type](1)

    @parameter
    fn kernel(out_dev: UnsafePointer[Scalar[type]], lhs: SIMD[type, 1]):
        var result = kernel_fn(lhs)
        out_dev[0] = result

    var func = ctx.compile_function[kernel]()

    ctx.enqueue_function(func, out, val, grid_dim=1, block_dim=1)
    ctx.synchronize()
    var out_h = UnsafePointer[Scalar[type]].alloc(1)
    ctx.enqueue_copy_from_device(out_h, out)
    assert_almost_equal(out_h[0], ref_)
    _ = out
    _ = func^


# CHECK-NOT: CUDA_ERROR
def main():
    @parameter
    fn cos_fn(val: SIMD[DType.float16, 1]) -> SIMD[DType.float16, 1]:
        return cos(val)

    @parameter
    fn cos_fn(val: SIMD[DType.float32, 1]) -> SIMD[DType.float32, 1]:
        return cos(val)

    @parameter
    fn sin_fn(val: SIMD[DType.float16, 1]) -> SIMD[DType.float16, 1]:
        return sin(val)

    @parameter
    fn sin_fn(val: SIMD[DType.float32, 1]) -> SIMD[DType.float32, 1]:
        return sin(val)

    try:
        with DeviceContext() as ctx:
            run_func[DType.float32, cos_fn](
                "./cos", 10, -0.83907192945480347, ctx
            )
            run_func[DType.float16, cos_fn]("./cos", 10, -0.8388671875, ctx)
            run_func[DType.float32, sin_fn](
                "./sin", 10, -0.54402029514312744, ctx
            )
            run_func[DType.float16, sin_fn]("./sin", 10, -0.5439453125, ctx)
    except e:
        print("CUDA_ERROR:", e)
