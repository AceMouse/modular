# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: nvptx_backend
# REQUIRES: has_cuda_device
# RUN: %mojo %s | FileCheck %s

from math import div_ceil
from pathlib import Path
from sys.info import triple_is_nvidia_cuda
from sys.param_env import env_get_string

from gpu import *
from gpu.host import Context, Dim, Function, Stream, synchronize
from gpu.host.memory import (
    _copy_device_to_host,
    _copy_host_to_device,
    _free,
    _malloc,
)
from memory import memset_zero
from memory.buffer import NDBuffer
from tensor import Tensor

from utils.index import Index
from utils.list import DimList

alias TILE_SZ_A = 128
alias TILE_SZ_B = 16
alias TILE_SZ_RATIO = TILE_SZ_A // TILE_SZ_B


@export("matmul")
fn matmul(
    a_ptr: DTypePointer[DType.float32],
    b_ptr: DTypePointer[DType.float32],
    c_ptr: DTypePointer[DType.float32],
    m: Int,
    n: Int,
    k: Int,
):
    @parameter
    if not triple_is_nvidia_cuda():
        return

    let a = NDBuffer[2, DimList.create_unknown[2](), DType.float32](
        a_ptr, Index(m, k)
    )
    let b = NDBuffer[2, DimList.create_unknown[2](), DType.float32](
        b_ptr, Index(k, n)
    )
    let c = NDBuffer[2, DimList.create_unknown[2](), DType.float32](
        c_ptr, Index(m, n)
    )

    # Compute C = A x B
    #   where A is a (m x k) matrix
    #   where B is a (k x n) matrix
    #   where C is a (m x n) matrix
    #
    # Use register and shared memory tiling and thread coarsening
    #
    # NOTE: A and C are column major, B is row major.

    # Allocate B array into shared memory for tiling.
    let b_shared = stack_allocation[
        TILE_SZ_RATIO * TILE_SZ_B, DType.float32, AddressSpace.SHARED
    ]()

    # Thread indexing offsets.
    let row = BlockIdx.x() * BlockDim.x() + ThreadIdx.x()
    let col = BlockIdx.y() * TILE_SZ_B

    # Privatization of the C matrix.
    let c_reg = stack_allocation[TILE_SZ_B, DType.float32]()

    memset_zero(c_reg, TILE_SZ_B)

    # Loop over each input tile.
    for tile_idx in range((k - 1) // TILE_SZ_RATIO + 1):
        let i = ThreadIdx.x() // TILE_SZ_B
        let j = ThreadIdx.x() % TILE_SZ_B

        # Load the B matrix into shared memory.
        let b_val: Float32
        if tile_idx * TILE_SZ_RATIO + i < k and col + j < n:
            b_val = b[tile_idx * TILE_SZ_RATIO + i, col + j]
        else:
            b_val = 0
        b_shared.store(i * TILE_SZ_B + j, b_val)

        barrier()

        # Loop within the tile.
        for idx in range(TILE_SZ_RATIO):
            # Load the A tile into the register.
            let a_reg: Float32
            if row < m and tile_idx * TILE_SZ_RATIO + idx < k:
                a_reg = a[row, tile_idx * TILE_SZ_RATIO + idx]
            else:
                a_reg = 0

            # Compute the output element for each thread.
            for out_idx in range(TILE_SZ_B):
                c_reg.store(
                    out_idx,
                    c_reg.load(out_idx)
                    + a_reg * b_shared.load(idx * TILE_SZ_RATIO + out_idx),
                )
        barrier()

    # Store the values into the output matrix.
    for out_idx in range(TILE_SZ_B):
        if row < m and col + out_idx < n:
            c[Index(row, col + out_idx)] = c_reg.load(out_idx)


# CHECK-LABEL: run_matmul
fn run_matmul() raises:
    print("== run_matmul")

    alias m = 512
    alias n = 512
    alias k = 512

    let stream = Stream[False]()

    var a_host = Tensor[DType.float32](m, k)
    var b_host = Tensor[DType.float32](k, n)
    var c_host = Tensor[DType.float32](m, n)

    for i in range(m):
        for j in range(k):
            a_host[Index(i, j)] = 1

    for i in range(k):
        for j in range(n):
            b_host[Index(i, j)] = 1

    for i in range(m):
        for j in range(n):
            c_host[Index(i, j)] = 0

    let a_device = _malloc[Float32](m * k)
    let b_device = _malloc[Float32](k * n)
    let c_device = _malloc[Float32](m * n)

    _copy_host_to_device(a_device, a_host.data(), m * k)
    _copy_host_to_device(b_device, b_host.data(), k * n)

    let func = Function[
        # fmt: off
      fn (DTypePointer[DType.float32],
          DTypePointer[DType.float32],
          DTypePointer[DType.float32],
          Int, Int, Int) -> None,
        # fmt: on
        matmul
    ]()

    func(
        (div_ceil(m, TILE_SZ_A), div_ceil(n, TILE_SZ_B)),
        (TILE_SZ_A, 1),
        a_device,
        b_device,
        c_device,
        m,
        n,
        k,
        stream=stream,
    )
    synchronize()

    _copy_device_to_host(c_host.data(), c_device, m * n)

    for i in range(10):
        for j in range(10):
            print("at index = [", i, ",", j, "] the value is", c_host[i, j])

    _free(a_device)
    _free(b_device)
    _free(c_device)

    _ = a_host
    _ = b_host
    _ = c_host

    _ = func ^
    _ = stream ^


# CHECK-NOT: CUDA_ERROR
def main():
    try:
        with Context() as ctx:
            run_matmul()
    except e:
        print("CUDA_ERROR:", e)
