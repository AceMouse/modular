# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo-no-debug %s

from math import ceildiv, isclose
from random import rand

from buffer import NDBuffer
from buffer.dimlist import DimList
from gpu import BlockDim, BlockIdx, GridDim, ThreadIdx
from gpu.host import DeviceBuffer, DeviceContext
from gpu.semaphore import Semaphore
from memory import UnsafePointer, memset_zero
from testing import assert_equal

from utils.index import Index


fn semaphore_vector_reduce[
    type: DType,
    N: Int,
    num_parts: Int,
](
    c_ptr: UnsafePointer[Scalar[type]],
    a_ptr: UnsafePointer[Scalar[type]],
    locks: UnsafePointer[Int32],
):
    var tid = ThreadIdx.x
    var block_idx = BlockIdx.x
    var sema = Semaphore(locks.offset(0), tid)

    sema.fetch()
    # for each block the partition id is the same as blockIdx

    sema.wait(block_idx)

    c_ptr[tid] += a_ptr[block_idx * N + tid]
    var lx = 0
    if num_parts == (block_idx + 1):
        lx = 0
    else:
        lx = block_idx + 1
    sema.release(lx)


fn run_vector_reduction[
    type: DType,
    N: Int,
    num_parts: Int,
](ctx: DeviceContext,) raises:
    print(
        "== run_semaphore vector reduction kernel => ", str(type), N, num_parts
    )

    alias PN = N * num_parts
    var a_host = UnsafePointer[Scalar[type]].alloc(PN)
    var c_host = UnsafePointer[Scalar[type]].alloc(N)
    var c_host_ref = UnsafePointer[Scalar[type]].alloc(N)

    rand[type](a_host, PN)
    memset_zero(c_host, N)
    memset_zero(c_host_ref, N)

    var a_device = ctx.enqueue_create_buffer[type](PN)
    var c_device = ctx.enqueue_create_buffer[type](N)
    var lock_dev = ctx.enqueue_create_buffer[type](1)
    var a_buf = NDBuffer[type, 1](a_device.ptr, Index(PN))
    var c_buf = NDBuffer[type, 1](c_device.ptr, Index(N))

    ctx.enqueue_memset(lock_dev, 0)
    ctx.enqueue_copy_to_device(a_device, a_host)
    ctx.enqueue_copy_to_device(c_device, c_host)

    var func_red_vec = ctx.compile_function[
        semaphore_vector_reduce[type, N, num_parts],
        dump_asm=False,
    ]()

    ctx.enqueue_function(
        func_red_vec,
        c_buf.data,
        a_buf.data,
        lock_dev.ptr,
        grid_dim=num_parts,
        block_dim=N,
    )

    ctx.enqueue_copy_from_device(c_host, c_device)
    ctx.synchronize()

    for i in range(N):
        for j in range(num_parts):
            c_host_ref[i] += a_host[j * N + i]

    for i in range(N):
        assert_equal(c_host[i], c_host_ref[i])

    _ = a_device
    _ = c_device
    _ = lock_dev

    a_host.free()
    c_host.free()
    c_host_ref.free()
    _ = func_red_vec^


fn semaphore_matrix_reduce[
    type: DType, M: Int, N: Int, num_parts: Int
](
    c_ptr: UnsafePointer[Scalar[type]],
    a_ptr: UnsafePointer[Scalar[type]],
    locks: UnsafePointer[Int32],
):
    var tid = ThreadIdx.x
    var block_idx = BlockIdx.x
    var sema = Semaphore(locks.offset(0), tid)

    sema.fetch()

    sema.wait(block_idx)
    for x in range(tid, M * N, BlockDim.x):
        var row = x // N
        var col = x % N
        c_ptr[row * N + col] += a_ptr[
            row * (N * num_parts) + (block_idx * num_parts + col)
        ]

    var lx = 0
    if num_parts == (block_idx + 1):
        lx = 0
    else:
        lx = block_idx + 1
    sema.release(lx)


fn run_matrix_reduction[
    type: DType,
    M: Int,
    N: Int,
    num_parts: Int,
](ctx: DeviceContext,) raises:
    print(
        "== run_semaphore matrix reduction kernel => ",
        str(type),
        M,
        N,
        num_parts,
    )

    alias PX = M * N * num_parts
    var a_host = UnsafePointer[Scalar[type]].alloc(PX)
    var c_host = UnsafePointer[Scalar[type]].alloc(M * N)
    var c_host_ref = UnsafePointer[Scalar[type]].alloc(M * N)

    rand[type](a_host, PX)
    memset_zero(c_host, M * N)
    memset_zero(c_host_ref, M * N)

    var a_device = ctx.enqueue_create_buffer[type](PX)
    var c_device = ctx.enqueue_create_buffer[type](M * N)
    var lock_dev = ctx.enqueue_create_buffer[type](1)
    var a_buf = NDBuffer[type, 1](a_device.ptr, Index(PX))
    var c_buf = NDBuffer[type, 1](c_device.ptr, Index(M * N))

    ctx.enqueue_memset(lock_dev, 0)
    ctx.enqueue_copy_to_device(a_device, a_host)
    ctx.enqueue_copy_to_device(c_device, c_host)

    var func_red = ctx.compile_function[
        semaphore_matrix_reduce[type, M, N, num_parts],
    ]()

    var block_size = 1024

    ctx.enqueue_function(
        func_red,
        c_buf.data,
        a_buf.data,
        lock_dev.ptr,
        grid_dim=num_parts,
        block_dim=block_size,
    )

    ctx.enqueue_copy_from_device(c_host, c_device)
    ctx.synchronize()

    for r in range(M):
        for c in range(N):
            for i in range(num_parts):
                c_host_ref[r * N + c] += a_host[
                    r * (N * num_parts) + (i * num_parts + c)
                ]

    for i in range(M * N):
        assert_equal(c_host[i], c_host_ref[i])

    _ = a_device
    _ = c_device
    _ = lock_dev

    a_host.free()
    c_host.free()
    c_host_ref.free()
    _ = func_red^


def main():
    with DeviceContext() as ctx:
        run_vector_reduction[DType.float32, 128, 4](ctx)
        run_matrix_reduction[DType.float32, 128, 128, 4](ctx)
