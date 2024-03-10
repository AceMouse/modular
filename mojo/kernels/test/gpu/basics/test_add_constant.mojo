# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo %s

from gpu import *
from gpu.host import Context, Dim, Function, Stream, synchronize
from gpu.host.memory import (
    _copy_device_to_host,
    _copy_host_to_device,
    _free,
    _malloc,
)
from testing import *


fn add_constant_fn(
    out: DTypePointer[DType.float32],
    input: DTypePointer[DType.float32],
    constant: Float32,
    len: Int,
):
    var tid = ThreadIdx.x() + BlockDim.x() * BlockIdx.x()
    if tid >= len:
        return
    out[tid] = input[tid] + constant


def run_add_constant():
    alias length = 1024
    var stream = Stream()

    var in_host = Pointer[Float32].alloc(length)
    var out_host = Pointer[Float32].alloc(length)

    for i in range(length):
        in_host[i] = i

    var in_device = _malloc[Float32](length)
    var out_device = _malloc[Float32](length)

    _copy_host_to_device(in_device, in_host, length)

    var func = Function[
        fn (
            DTypePointer[DType.float32],
            DTypePointer[DType.float32],
            Float32,
            Int,
        ) -> None, add_constant_fn
    ]()

    var block_dim = 32
    alias constant = FloatLiteral(33)

    func(
        out_device,
        in_device,
        constant,
        length,
        grid_dim=(length // block_dim),
        block_dim=(block_dim),
        stream=stream,
    )

    _copy_device_to_host(out_host, out_device, length)

    for i in range(10):
        assert_equal(out_host[i], i + constant)

    _free(in_device)
    _free(out_device)

    in_host.free()
    out_host.free()

    _ = func ^
    _ = stream ^


# CHECK-NOT: CUDA_ERROR
def main():
    try:
        with Context() as ctx:
            run_add_constant()
    except e:
        print("CUDA_ERROR:", e)
