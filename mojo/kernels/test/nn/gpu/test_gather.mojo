# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo %s | FileCheck %s

from sys.info import simdwidthof

from gpu.host import Context
from gpu.host.memory import (
    _copy_device_to_host,
    _copy_host_to_device,
    _free,
    _malloc,
    _memset,
)
from gpu.host.sync import synchronize
from memory.buffer import NDBuffer
from nn.gather_scatter import gather

from utils.index import Index, StaticIntTuple
from utils.list import DimList


# CHECK-LABEL: test_gather
fn test_gather() raises:
    print("== test_gather")

    @always_inline
    @parameter
    fn _test_gather[indices_type: DType]() raises:
        alias num_rows = 16
        alias row_size = 4

        var input_host = NDBuffer[
            DType.float32,
            2,
            DimList(num_rows, row_size),
        ].stack_allocation()
        for i in range(num_rows):
            for j in range(row_size):
                input_host[Index(i, j)] = Float32(i).value
        var input_device_ptr = _malloc[DType.float32](
            input_host.size() * sizeof[DType.float32]()
        )
        _copy_host_to_device(
            input_device_ptr, input_host.data, input_host.size()
        )
        var input_device = NDBuffer[
            DType.float32,
            2,
            DimList(num_rows, row_size),
        ](input_device_ptr)

        alias num_indices = 16
        var indices_host = NDBuffer[
            indices_type,
            1,
            DimList(num_indices),
        ].stack_allocation()
        var indices_device_ptr = _malloc[indices_type](
            indices_host.size() * sizeof[indices_type]()
        )
        var indices_device = NDBuffer[
            indices_type,
            1,
            DimList(num_indices),
        ](indices_device_ptr)

        for i in range(num_indices):
            indices_host[Index(i)] = i // 2
        indices_host[0] = -1
        indices_host[1] = -num_rows

        _copy_host_to_device(
            indices_device_ptr, indices_host.data, indices_host.size()
        )

        # create output
        var output_host = NDBuffer[
            DType.float32,
            2,
            DimList(num_indices, row_size),
        ].stack_allocation()
        var output_device_ptr = _malloc[DType.float32](
            output_host.size() * sizeof[DType.float32]()
        )
        var output_device = NDBuffer[
            DType.float32,
            2,
            DimList(num_indices, row_size),
        ](output_device_ptr)

        gather[axis=0, target="cuda"](
            output_device.make_dims_unknown(),
            input_device.make_dims_unknown(),
            indices_device.make_dims_unknown(),
        )
        synchronize()

        _copy_device_to_host(
            output_host.data, output_device_ptr, output_host.size()
        )

        _free(input_device_ptr)
        _free(indices_device_ptr)
        _free(output_device_ptr)

        print(output_host[Index(0, 0)])
        print(output_host[Index(1, 0)])
        print(output_host[Index(2, 0)])
        print(output_host[Index(6, 0)])
        print(output_host[Index(15, 0)])

    # CHECK: 15.0
    # CHECK: 0.0
    # CHECK-NEXT: 1.0
    # CHECK-NEXT: 3.0
    # CHECK-NEXT: 7.0
    _test_gather[DType.int32]()
    # CHECK: 0.0
    # CHECK-NEXT: 1.0
    # CHECK-NEXT: 3.0
    # CHECK-NEXT: 7.0
    _test_gather[DType.int64]()


fn main() raises:
    with Context() as ctx:
        test_gather()
