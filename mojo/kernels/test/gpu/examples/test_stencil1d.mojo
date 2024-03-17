# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# TODO(#31429): Restore `--debug-level full` here
# RUN: %mojo %s | FileCheck %s

from math import div_ceil

from buffer import NDBuffer
from gpu import AddressSpace, BlockDim, BlockIdx, ThreadIdx, barrier
from gpu.host import Context, Dim, Function, Stream, synchronize
from gpu.host.memory import (
    _copy_device_to_host,
    _copy_host_to_device,
    _free,
    _malloc,
)
from memory import memset_zero, stack_allocation
from memory.unsafe import DTypePointer
from tensor import Tensor

from utils.index import Index
from utils.list import DimList

alias BLOCK_DIM = 8


fn stencil1d(
    a_ptr: DTypePointer[DType.float32],
    b_ptr: DTypePointer[DType.float32],
    arr_size: Int,
    coeff0: Int,
    coeff1: Int,
    coeff2: Int,
):
    var tid = BlockIdx.x() * BlockDim.x() + ThreadIdx.x()

    var a = NDBuffer[DType.float32, 1](a_ptr, Index(arr_size))
    var b = NDBuffer[DType.float32, 1](b_ptr, Index(arr_size))

    if 0 < tid < arr_size - 1:
        b[tid] = coeff0 * a[tid - 1] + coeff1 * a[tid] + coeff2 * a[tid + 1]


fn stencil1d_smem(
    a_ptr: DTypePointer[DType.float32],
    b_ptr: DTypePointer[DType.float32],
    arr_size: Int,
    coeff0: Int,
    coeff1: Int,
    coeff2: Int,
):
    var tid = BlockIdx.x() * BlockDim.x() + ThreadIdx.x()
    var lindex = ThreadIdx.x() + 1

    var a = NDBuffer[DType.float32, 1](a_ptr, Index(arr_size))
    var b = NDBuffer[DType.float32, 1](b_ptr, Index(arr_size))

    var a_shared = stack_allocation[
        BLOCK_DIM + 2, DType.float32, address_space = AddressSpace.SHARED
    ]()

    a_shared[lindex] = a[tid]
    if ThreadIdx.x() == 0:
        a_shared[lindex - 1] = a[tid - 1]
        a_shared[lindex + BLOCK_DIM] = a[tid + BLOCK_DIM]

    barrier()

    if 0 < tid < arr_size - 1:
        b[tid] = (
            coeff0 * a_shared[lindex - 1]
            + coeff1 * a_shared[lindex]
            + coeff2 * a_shared[lindex + 1]
        )


# CHECK-LABEL: run_stencil1d
fn run_stencil1d[smem: Bool]() raises:
    print("== run_stencil1d")

    alias m = 64
    alias coeff0 = 3
    alias coeff1 = 2
    alias coeff2 = 4
    alias iterations = 4

    var a_host = Tensor[DType.float32](m)
    var b_host = Tensor[DType.float32](m)

    var stream = Stream()

    for i in range(m):
        a_host[Index(i)] = i
        b_host[Index(i)] = 0

    var a_device = _malloc[Float32](m)
    var b_device = _malloc[Float32](m)

    _copy_host_to_device(a_device, a_host.data(), m)

    alias func_select = stencil1d_smem if smem == True else stencil1d

    var func = Function[__type_of(func_select), func_select](debug=True)

    for i in range(iterations):
        func(
            a_device,
            b_device,
            m,
            coeff0,
            coeff1,
            coeff2,
            grid_dim=(div_ceil(m, BLOCK_DIM)),
            block_dim=(BLOCK_DIM),
            stream=stream,
        )
        synchronize()

        var tmp_ptr = b_device
        b_device = a_device
        a_device = tmp_ptr

    _copy_device_to_host(b_host.data(), b_device, m)

    # CHECK: == run_stencil1d
    # CHECK: 912.0 ,1692.0 ,2430.0 ,3159.0 ,3888.0 ,4617.0 ,5346.0 ,6075.0 ,
    # CHECK: 6804.0 ,7533.0 ,8262.0 ,8991.0 ,9720.0 ,10449.0 ,11178.0 ,11907.0 ,
    # CHECK: 12636.0 ,13365.0 ,14094.0 ,14823.0 ,15552.0 ,16281.0 ,17010.0 ,
    # CHECK: 17739.0 ,18468.0 ,19197.0 ,19926.0 ,20655.0 ,21384.0 ,22113.0 ,
    # CHECK: 22842.0 ,23571.0 ,24300.0 ,25029.0 ,25758.0 ,26487.0 ,27216.0 ,
    # CHECK: 27945.0 ,28674.0 ,29403.0 ,30132.0 ,30861.0 ,31590.0 ,32319.0 ,
    # CHECK: 33048.0 ,33777.0 ,34506.0 ,35235.0 ,35964.0 ,36693.0 ,37422.0 ,
    # CHECK: 38151.0 ,38880.0 ,39609.0 ,40338.0 ,41067.0 ,41796.0 ,42525.0 ,
    # CHECK: 43254.0 ,43983.0 ,35624.0 ,20665.0 ,
    for i in range(1, m - 1):
        print_no_newline(b_host[i], ",")
    print()

    _free(a_device)
    _free(b_device)

    _ = a_host
    _ = b_host

    _ = func ^
    _ = stream ^


# CHECK-NOT: CUDA_ERROR
def main():
    try:
        with Context() as ctx:
            run_stencil1d[False]()
            run_stencil1d[True]()
    except e:
        print("CUDA_ERROR:", e)
