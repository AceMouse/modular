# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: nvptx_backend
# REQUIRES: has_cuda_device
# RUN: %mojo %s | FileCheck %s

from gpu import *
from gpu.host import Function, Context, Dim, Stream
from gpu.host.memory import (
    _malloc,
    _free,
    _copy_host_to_device,
    _copy_device_to_host,
    _memset,
)
from pathlib import Path
from sys.info import triple_is_nvidia_cuda
from utils.index import Index
from tensor import Tensor
from math import div_ceil
from builtin.io import _printf


fn reduce(
    res: Pointer[Float32],
    vec: DTypePointer[DType.float32],
    len: Int,
):
    let tid = BlockIdx.x() * BlockDim.x() + ThreadIdx.x()

    if tid < len:
        _ = Atomic._fetch_add(res, vec.load(tid))


# CHECK-LABEL: run_reduce
fn run_reduce() raises:
    print("== run_reduce")

    alias BLOCK_SIZE = 32
    alias n = 1024

    let stream = Stream[False]()

    var vec_host = Tensor[DType.float32](n)

    for i in range(n):
        vec_host[i] = 1

    let vec_device = _malloc[Float32](n)
    let res_device = _malloc[Float32](1)

    _copy_host_to_device(vec_device, vec_host.data(), n)
    _memset(res_device, 0, 1)

    let func = Function[
        # fmt: off
      fn (Pointer[Float32],
          DTypePointer[DType.float32],
          Int
         ) -> None,
        # fmt: on
        reduce
    ](verbose=True)

    func(
        (div_ceil(n, BLOCK_SIZE),),
        (BLOCK_SIZE,),
        res_device,
        vec_device,
        n,
        stream=stream,
    )

    var res = SIMD[DType.float32, 1](0)
    _copy_device_to_host(Pointer.address_of(res), res_device, 1)

    # CHECK: res =  1024.0
    print("res = ", res)

    _free(vec_device)

    _ = vec_host

    _ = func ^
    _ = stream ^


# CHECK-NOT: CUDA_ERROR
def main():
    try:
        with Context() as ctx:
            run_reduce()
    except e:
        print("CUDA_ERROR:", e)
