# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from collections.vector import InlinedFixedVector
from sys import external_call

from algorithm import sync_parallelize
from memory import memcpy
from memory.buffer import Buffer, DynamicRankBuffer, NDBuffer

from utils.index import product
from utils.list import Dim, DimList


struct _NDBufferVector[type: DType, rank: Int](Sized):
    """Utility to store a VariadicList of NDBuffers. Required because there is not
    a clean way to convert a VariadicList of DynamicRankBuffers to a VariadicList
    of NDBuffers."""

    alias stack_capacity = 20
    alias BufferType = NDBuffer[type, rank]
    alias StorageType = InlinedFixedVector[
        Self.BufferType, size = Self.stack_capacity
    ]
    var storage: Self.StorageType

    @always_inline
    fn __init__(inout self, num_inputs: Int):
        self.storage = Self.StorageType(num_inputs)

    @always_inline
    fn __init__(inout self, *inputs: DynamicRankBuffer):
        self.__init__(inputs)

    fn __init__(inout self, input_list: VariadicList[DynamicRankBuffer]):
        self.storage = Self.StorageType(len(input_list))
        for i in range(len(input_list)):
            self.storage.append(input_list[i].to_ndbuffer[type, rank]())

    @always_inline
    fn __init__(inout self, *inputs: Self.BufferType):
        self.__init__(inputs)

    fn __init__(inout self, input_list: VariadicList[Self.BufferType]):
        self.storage = Self.StorageType(len(input_list))
        for i in range(len(input_list)):
            self.storage.append(input_list[i])

    @always_inline
    fn __getitem__(self, idx: Int) -> NDBuffer[type, rank]:
        return self.storage[idx]

    @always_inline
    fn __len__(self) -> Int:
        return len(self.storage)

    @always_inline
    fn __del__(owned self):
        return self.storage._del_old()


# ===----------------------------------------------------------------------===#
# split
# ===----------------------------------------------------------------------===#


fn _split[
    type: DType,
    rank: Int,
](
    input: NDBuffer[type, rank],
    axis: Int,
    outputs: _NDBufferVector[type, rank],
):
    """splits input along axis and store in outputs.

    This simplifies the implementation by reshaping the output and inputs into 3D
    buffers. output i has dims [h, wi, c]. The input has dims [h, sum(wi), c] where
    i ranges from [0, num_outputs).

    Reshaping the buffer does not change the memory layout. After reshaping to 3D
    it is easy to visualize that the inputs can be copied in w x c sized
    contiguous slices along the h dimension.

    """

    var shape = outputs[0].get_shape()
    var h = product(shape, 0, axis)
    var c = product(shape, axis + 1, rank)

    var w_in: Int = 0
    for i in range(len(outputs)):
        w_in += outputs[i].dim(axis)

    var stride_h_in = w_in * c
    var stride_w_in = c

    var w_offset: Int = 0
    for i in range(len(outputs)):
        # copy one w x c slice along h at a time
        var w = outputs[i].dim(axis)
        var out_buf = outputs[i].flatten()
        for j in range(h):
            var output_offset = j * w * c
            var input_offset = j * stride_h_in + w_offset * stride_w_in
            var out_slice = Buffer[type](out_buf.data + output_offset, w * c)
            var in_slice = Buffer[type](input.data + input_offset, w * c)
            # these slices are contiguous
            memcpy(out_slice, in_slice)
        w_offset += w


fn _split_inner[
    type: DType, rank: Int, axis: Int
](input: NDBuffer[type, rank], outputs: _NDBufferVector[type, rank],):
    constrained[axis == 0, "_split_inner only supports axis 0"]()
    var num_elems_copied: Int = 0
    for i in range(len(outputs)):
        var output_buf = outputs[i].flatten()
        var buffer_len = len(output_buf)
        var input_buffer_offset = Buffer[type](
            input.data.offset(num_elems_copied), buffer_len
        )
        memcpy[type](output_buf, input_buffer_offset)
        num_elems_copied += buffer_len


fn split[
    type: DType,
    rank: Int,
](
    input: NDBuffer[type, rank],
    axis: Int,
    outputs: _NDBufferVector[type, rank],
) raises:
    # check inputs have same rank and same dims except for axis dim
    for i in range(len(outputs)):
        if outputs[0].get_rank() != outputs[i].get_rank():
            raise Error("all split inputs must have the same rank")
        for j in range(outputs[i].get_rank()):
            if j != axis and outputs[0].dim(j) != outputs[i].dim(j):
                raise Error(
                    "all split outputs must have the same dimensions in the"
                    " non-split axes"
                )

    @parameter
    @always_inline
    fn task_func(task_id: Int):
        if axis == 0:
            _split_inner[type, rank, 0](input, outputs)
            return

        _split[type](input, axis, outputs)

    # The task_func closure captures the stack allocated _NDBufferVector,
    # so this kernel must run synchronously.
    sync_parallelize[task_func](1)
