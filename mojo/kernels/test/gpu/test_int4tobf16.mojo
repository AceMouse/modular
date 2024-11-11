# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo-no-debug %s

# https://github.com/PaddlePaddle/Paddle/blob/3862f8303d2723c03ffb42ce332d4c570906669f/paddle/phi/kernels/funcs/weight_only_gemv.cu#L795

# logic and shift instruciton: lop3
# https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#logic-and-shift-instructions-lop3

from memory.unsafe import bitcast
from sys import has_neon
from testing import assert_equal
from gpu.host import DeviceContext
from buffer import Buffer
from memory import UnsafePointer
from gpu.intrinsics import lop
from utils import StaticTuple
from gpu.memory import AddressSpace


# 8xint4 -> 8xbfloat16 interleaved conversion
fn int4tobf16[no_lop: Bool = False](i4: Int32) -> SIMD[DType.bfloat16, 8]:
    alias MASK: Int32 = 0x000F000F
    alias I4s_TO_BF16s_MAGIC_NUM: Int32 = 0x43004300

    # 0xc308 = -136.0, 0xc300 = -128.0
    alias BF16_BIAS = SIMD[DType.bfloat16, 2](-128, -128)
    # 0x3f80 = 1.0
    alias BF16_ONE = SIMD[DType.bfloat16, 2](1, 1)

    var i4s: Int32 = i4
    var v: SIMD[DType.int32, 4] = 0
    alias lut: Int32 = (0xF0 & 0xCC) | 0xAA
    # This lut is operation: (A & B) | C

    @parameter
    for i in range(0, 4):
        var t = (i4s & MASK) | I4s_TO_BF16s_MAGIC_NUM if no_lop else lop[lut](
            i4s, MASK, I4s_TO_BF16s_MAGIC_NUM
        )
        v[i] = bitcast[DType.int32, 1](
            bitcast[DType.bfloat16, 2](t).fma(BF16_ONE, BF16_BIAS)
        )
        i4s >>= 4
    return bitcast[DType.bfloat16, 8](v)


fn call_int4tobf16[
    no_lop: Bool
](i4: Int32, out_ptr: UnsafePointer[BFloat16, AddressSpace.GLOBAL]):
    var v = int4tobf16[no_lop](i4)
    out_ptr.bitcast[Int32]().store[alignment=16](0, bitcast[DType.int32, 4](v))


def test_int4tobfloat16[no_lop: Bool](ctx: DeviceContext):
    var out_host = Buffer[DType.bfloat16, 8].stack_allocation()
    var out_device = ctx.enqueue_create_buffer[DType.bfloat16](8)

    var func = ctx.compile_function[call_int4tobf16[no_lop]]()
    ctx.enqueue_function(
        func, UInt32(0x76543210), out_device, grid_dim=1, block_dim=1
    )

    ctx.enqueue_copy_from_device(out_host.data, out_device)
    for i in range(4):
        assert_equal(out_host[2 * i + 0], i + 0)
        assert_equal(out_host[2 * i + 1], i + 4)


def main():
    # TODO(KERN-228): support BF16 on neon systems.
    @parameter
    if not has_neon():
        with DeviceContext() as ctx:
            test_int4tobfloat16[no_lop=False](ctx)
            test_int4tobfloat16[no_lop=True](ctx)
