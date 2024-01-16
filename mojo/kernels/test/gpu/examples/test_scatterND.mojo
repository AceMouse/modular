# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo %s | FileCheck %s

from tensor import Tensor, TensorShape
from memory.buffer import NDBuffer
from math import div_ceil
from gpu.host import Context, Dim, Function, Stream, synchronize
import gpu.host.benchmark
from gpu.host.event import time_function
from gpu.host.memory import (
    _copy_device_to_host,
    _copy_host_to_device,
    _free,
    _malloc,
)
from gpu import BlockIdx, BlockDim, ThreadIdx
from utils.index import Index
from utils.list import DimList

# This is DeviceAttribute.MAX_THREADS_PER_BLOCK (in ONNXRT it is a global
# with value of 256).
alias MAX_THREADS_PER_BLOCK = 256


# TODO: Follow-up: Eliminate offsets calculations and use NDBuffers directly.
fn scatter_nd_gpu[
    type: DType,
    indices_type: DType,
](
    output_data_ptr: DTypePointer[type],
    indices_data_ptr: DTypePointer[indices_type],
    element_counts_and_input_dims_ptr: DTypePointer[DType.int64],
    updates_data_ptr: DTypePointer[type],
    num_indices: Int,
    last_index_dimension: Int,
    num_updates_elements: Int,
):
    let id = BlockIdx.x() * BlockDim.x() + ThreadIdx.x()
    if id >= num_indices:
        return

    let element_counts_and_input_dims = NDBuffer[
        1, DimList.create_unknown[1](), DType.int64
    ](element_counts_and_input_dims_ptr, Index(last_index_dimension * 2))

    var data_offset = 0

    let indices_start = last_index_dimension * id
    let indices_end = indices_start + last_index_dimension

    for i in range(indices_start, indices_end):
        var index = int(indices_data_ptr.load(i))
        let element_count_dim = int(
            element_counts_and_input_dims[i - indices_start]
        )
        let dim_value = int(
            element_counts_and_input_dims[
                i - indices_start + last_index_dimension
            ]
        )

        # Clamp the index if out of range.
        # This would have been an error in the CPU kernel, but throwing in the CUDA EP
        # is hard. This is the approach taken by other frameworks for out of bound indices
        # in their corresponding GPU backends as well.
        # index >= -dim_value && index < dim_value
        if index >= 0:
            if index >= dim_value:
                index = dim_value - 1
        else:
            if index < -dim_value:
                index = 0
            else:
                index += dim_value

        data_offset += index * element_count_dim

    # Set updates_data_base to appropriate offset (from where to copy).
    let updates_data_base = updates_data_ptr.offset(num_updates_elements * id)
    # Set output_data_base to appropriate offset (where to copy).
    let output_data_base = output_data_ptr.offset(data_offset)

    # Start copying appropriate amount of elements.
    for i in range(num_updates_elements):
        output_data_base[i] = updates_data_base[i]


# TODO: Extend for using reduce function if needed.
fn scatter_nd[
    type: DType,
    indices_type: DType,
    data_rank: Int,
    indices_rank: Int,
    updates_rank: Int,
](
    data: NDBuffer[data_rank, DimList.create_unknown[data_rank](), type],
    indices: NDBuffer[
        indices_rank, DimList.create_unknown[indices_rank](), indices_type
    ],
    updates: NDBuffer[
        updates_rank, DimList.create_unknown[updates_rank](), type
    ],
    output: NDBuffer[data_rank, DimList.create_unknown[data_rank](), type],
) raises:
    """
    Implements ONNX ScatterND operation as defined in https://github.com/onnx/onnx/blob/main/docs/Operators.md#ScatterND.

    Parameters:
        type: Type of data, updates, and output tensors.
        indices_type: Type of the indices tensor.
        data_rank: Rank of input (data) tensor (data_rank >= 1).
        indices_rank: Rank of input (data) tensor (indices_rank >= 1).
        updates_rank: Rank of updates tensor (updates_rank = data_rank +
                      indices_rank - indices_shape[-1] - 1).

    Args:
        data: Tensor of rank data_rank >= 1.
        indices: Tensor of rank indices_rank containing indices for the scatter
                 operation.
        updates: Tensor containing values to update output tensor based on
                 indices tensor.
        output: Tensor of rank data_rank, shaped the same as data tensor.
    """
    if data.get_shape() != output.get_shape():
        print("Input and output shapes in scatter_nd must be the same.")

    if (
        len(updates.get_shape())
        != data_rank + indices_rank - indices.get_shape()[indices_rank - 1] - 1
    ):
        print(
            "updates rank must be: data_rank + indices_rank -"
            " indices_shape[-1] - 1"
        )

    let stream = Stream.get_current_stream()

    # Copy input data to output (appropriate elements will be updated as needed
    # by the end of scatternd kernel).
    let output_flat = output.flatten()
    let data_flat = data.flatten()
    memcpy(output_flat, data_flat)

    # Get shapes of buffers to be used in subsequent calculations.
    let data_shape = data.get_shape()
    let indices_shape = indices.get_shape()
    let last_shape_of_indices = indices_shape[indices_rank - 1]
    let updates_shape = updates.get_shape()

    # Depending on r_minus_m = data_rank - last_shape_of_indices,
    # we will be copying:
    #   element (r_minus_m = 0),
    #   row (r_minus_m = 1),
    #   sheet (r_minus_m = 2),
    #   cuboid (r_minus_m = 3), etc.
    let r_minus_m = data_rank - last_shape_of_indices
    # Calculate how many elements to copy/scatter (this is from the innermost
    # dimensions, and is contiguous memory locations).
    var count_copy = 1
    for i in range(r_minus_m):
        count_copy = count_copy * data_shape[data_rank - 1 - i]

    # Calculate number of (input) data elements to copy to GPU.
    var data_count_copy = 1
    for i in range(data_rank):
        data_count_copy = data_count_copy * data_shape[data_rank - 1 - i]

    # Calculate number of indices NDBuffer elements to copy to GPU.
    var indices_count_copy = 1
    for i in range(indices_rank):
        indices_count_copy = (
            indices_count_copy * indices_shape[indices_rank - 1 - i]
        )

    # Calculate number of updates NDBuffer elements to copy to GPU.
    var updates_count_copy = 1
    for i in range(updates_rank):
        updates_count_copy = (
            updates_count_copy * updates_shape[updates_rank - 1 - i]
        )

    # NDBuffer below will store both input_strides and data NDBuffer dimensions.
    # (combine both in one to reduce number of memcpy from H->D).
    let ptr = DTypePointer[DType.int64].alloc(last_shape_of_indices * 2)
    let element_counts_and_input_dims = NDBuffer[
        1, DimList.create_unknown[1](), DType.int64
    ](ptr, DimList(last_shape_of_indices * 2))

    # input_strides
    # e.g., for a shape of 2, 3, 4, 5
    #       input_strides --> [3*4*5, 4*5, 5, 1]
    let input_strides = NDBuffer[
        1, DimList(data_rank), DType.int64
    ]().stack_allocation()
    for i in range(data_rank):
        var total_stride = 1
        for j in range(i + 1, data_rank):
            total_stride *= data_shape[j]
        input_strides[i] = total_stride

    for i in range(last_shape_of_indices):
        element_counts_and_input_dims[i] = input_strides[i]
        element_counts_and_input_dims[i + last_shape_of_indices] = data_shape[i]

    # Allocate and copy output data, elements_counts_and_input_dims, updates,
    # indices to GPU.
    let output_device = _malloc[type](data_count_copy)
    let element_counts_and_input_dims_device = _malloc[DType.int64](
        last_shape_of_indices * 2
    )
    let updates_device = _malloc[type](updates_count_copy)
    let indices_device = _malloc[indices_type](indices_count_copy)
    _copy_host_to_device(output_device, output_flat.data, data_count_copy)
    _copy_host_to_device(
        element_counts_and_input_dims_device,
        element_counts_and_input_dims.data,
        last_shape_of_indices * 2,
    )
    _copy_host_to_device(updates_device, updates.data, updates_count_copy)
    _copy_host_to_device(indices_device, indices.data, indices_count_copy)

    # Number of indices (that is without last dimension).
    # Each thread will handle one index.
    # e.g., 3,2,3 ==> 6
    var num_indices = 1
    for i in range(len(indices.get_shape()) - 1):
        num_indices *= indices.get_shape()[i]

    let num_updates_elements = count_copy

    let func = Function[
        fn (
            DTypePointer[type],  # output data
            DTypePointer[indices_type],  # indices_data
            DTypePointer[DType.int64],  # elements_counts_and_input_dims
            DTypePointer[type],  # updates_data
            Int,  # num_indices
            Int,  # last_index_dimension
            Int,  # num_updates_elements
        ) -> None, scatter_nd_gpu[type=type, indices_type=indices_type]
    ]()

    func(
        stream,
        (div_ceil(num_indices, MAX_THREADS_PER_BLOCK)),
        (MAX_THREADS_PER_BLOCK),
        output_device,
        indices_device,
        element_counts_and_input_dims_device,
        updates_device,
        num_indices,
        last_shape_of_indices,
        num_updates_elements,
    )
    synchronize()

    # Copy back output data from GPU to CPU.
    _copy_device_to_host(output.data, output_device, data_count_copy)

    _free(output_device)
    _free(element_counts_and_input_dims_device)
    _free(updates_device)
    _free(indices_device)

    ptr.free()

    _ = func ^
    _ = stream ^


fn linear_fill[
    type: DType
](t: Tensor[type], elems: VariadicList[SIMD[type, 1]]):
    debug_assert(
        t.num_elements() == len(elems), "must fill all elements of tensor"
    )

    let buf = t._to_buffer()
    for i in range(t.num_elements()):
        buf[i] = elems[i]


fn test_case[
    type: DType,
](
    input_shape: TensorShape,
    indices_shape: TensorShape,
    updates_shape: TensorShape,
    data_vals: VariadicList[SIMD[type, 1]],
    indices_vals: VariadicList[SIMD[DType.int64, 1]],
    updates_vals: VariadicList[SIMD[type, 1]],
    output_ref_vals: VariadicList[SIMD[type, 1]],
):
    let data = Tensor[type](input_shape)
    linear_fill(data, data_vals)
    let indices = Tensor[DType.int64](indices_shape)
    linear_fill(indices, indices_vals)
    let updates = Tensor[type](updates_shape)
    linear_fill(updates, updates_vals)
    let output = Tensor[type](input_shape)

    # Note: This is for the specific set of examples
    #      (due to _to_ndbuffer[] parameters).
    try:
        with Context() as ctx:
            scatter_nd[type, DType.int64, 3, 2, 3](
                data._to_ndbuffer[3](),
                indices._to_ndbuffer[2](),
                updates._to_ndbuffer[3](),
                output._to_ndbuffer[3](),
            )
    except e:
        print("CUDA_ERROR:", e)

    _ = data
    _ = indices
    _ = updates

    let output_ref = Tensor[type](input_shape)
    linear_fill(output_ref, output_ref_vals)

    for i in range(output.num_elements()):
        if output_ref._to_buffer()[i] != output._to_buffer()[i]:
            print_no_newline("FAILURE: Mismatch at idx: ")
            print(i)


fn main():
    fn test_scatternd_gpu():
        print("== test_scatternd_gpu")
        let data = VariadicList[Float32](
            # fmt: off
            1, 2, 3, 4,
            5, 6, 7, 8,
            8, 7, 6, 5,
            4, 3, 2, 1,
            1, 2, 3, 4,
            5, 6, 7, 8,
            8, 7, 6, 5,
            4, 3, 2, 1,
            8, 7, 6, 5,
            4, 3, 2, 1,
            1, 2, 3, 4,
            5, 6, 7, 8,
            8, 7, 6, 5,
            4, 3, 2, 1,
            1, 2, 3, 4,
            5, 6, 7, 8,
            # fmt: on
        )

        let indices = VariadicList[Int64](0, 2)

        let updates = VariadicList[Float32](
            # fmt: off
            5, 5, 5, 5,
            6, 6, 6, 6,
            7, 7, 7, 7,
            8, 8, 8, 8,
            1, 1, 1, 1,
            2, 2, 2, 2,
            3, 3, 3, 3,
            4, 4, 4, 4,
            # fmt: on
        )

        let output_ref = VariadicList[Float32](
            # fmt: off
            5, 5, 5, 5,
            6, 6, 6, 6,
            7, 7, 7, 7,
            8, 8, 8, 8,
            1, 2, 3, 4,
            5, 6, 7, 8,
            8, 7, 6, 5,
            4, 3, 2, 1,
            1, 1, 1, 1,
            2, 2, 2, 2,
            3, 3, 3, 3,
            4, 4, 4, 4,
            8, 7, 6, 5,
            4, 3, 2, 1,
            1, 2, 3, 4,
            5, 6, 7, 8,
            # fmt: on
        )

        test_case[DType.float32](
            TensorShape(4, 4, 4),
            TensorShape(2, 1),
            TensorShape(2, 4, 4),
            data,
            indices,
            updates,
            output_ref,
        )

    # CHECK-LABEL: test_scatternd_gpu
    # CHECK-NOT: FAILURE
    test_scatternd_gpu()
