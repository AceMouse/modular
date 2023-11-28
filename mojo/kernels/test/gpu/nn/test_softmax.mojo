# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo %s | FileCheck %s

from sys.info import simdwidthof

from memory.buffer import Buffer, NDBuffer
from runtime.llcl import OwningOutputChainPtr, Runtime
from Softmax import softmax_2_pass, softmax
from random import rand

from utils.list import Dim, DimList

from math import iota, isclose
from gpu.host import Context, Stream, synchronize
from gpu.host.memory import (
    _copy_device_to_host,
    _copy_host_to_device,
    _free,
    _malloc,
    _memset,
)


# CHECK-LABEL: test_gpu_softmax
fn test_gpu_softmax() raises:
    print("== test_gpu_softmax")

    alias type = DType.float32
    alias rank = 3
    let shape = StaticIntTuple[rank](3, 5, 515)
    let in_host_ptr = DTypePointer[type].alloc(shape.flattened_length())
    let in_device_ptr = _malloc[type](shape.flattened_length())
    let in_host = NDBuffer[rank, DimList.create_unknown[rank](), type](
        in_host_ptr, shape
    )
    let in_device = NDBuffer[rank, DimList.create_unknown[rank](), type](
        in_device_ptr, shape
    )
    let out_host_ptr = DTypePointer[type].alloc(shape.flattened_length())
    let out_ref_ptr = DTypePointer[type].alloc(shape.flattened_length())
    let out_device_ptr = _malloc[type](shape.flattened_length())
    let out_host = NDBuffer[rank, DimList.create_unknown[rank](), type](
        out_host_ptr, shape
    )
    let out_ref = NDBuffer[rank, DimList.create_unknown[rank](), type](
        out_ref_ptr, shape
    )
    let out_device = NDBuffer[rank, DimList.create_unknown[rank](), type](
        out_device_ptr, shape
    )

    rand[type](in_host_ptr, shape.flattened_length())
    _copy_host_to_device(in_device_ptr, in_host_ptr, shape.flattened_length())

    @parameter
    fn input_fn_device[
        _simd_width: Int, _rank: Int
    ](coords: StaticIntTuple[_rank]) -> SIMD[type, _simd_width]:
        return in_device[rebind[StaticIntTuple[rank]](coords)]

    @parameter
    fn input_fn_host[
        _simd_width: Int, _rank: Int
    ](coords: StaticIntTuple[_rank]) -> SIMD[type, _simd_width]:
        return in_host[rebind[StaticIntTuple[rank]](coords)]

    softmax[
        type, 1, rank, DimList.create_unknown[rank](), input_fn_device, "cuda"
    ](shape, out_device, rank - 1, OutputChainPtr())

    with Runtime() as rt:
        let out_chain = OwningOutputChainPtr(rt)
        softmax[
            type,
            1,
            rank,
            DimList.create_unknown[rank](),
            input_fn_host,
            "cpu",
        ](shape, out_ref, rank - 1, out_chain.borrow())
        out_chain.wait()

    synchronize()
    _copy_device_to_host(out_host_ptr, out_device_ptr, shape.flattened_length())

    # CHECK-NOT: ERROR
    for i in range(shape.flattened_length()):
        if not isclose(
            out_ref.flatten()[i],
            out_host.flatten()[i],
            1e-4,  # atol
            1e-5,  # rtol
        ):
            print("ERROR. Mismatch at flattened idx:", i)

    in_host_ptr.free()
    out_host_ptr.free()
    out_ref_ptr.free()

    _free(in_device_ptr)
    _free(out_device_ptr)


fn main():
    try:
        with Context() as ctx:
            test_gpu_softmax()
    except e:
        print(e)
