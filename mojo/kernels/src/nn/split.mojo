# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from collections import List
from sys import external_call

from sys import simdwidthof
from collections.string import StaticString
from algorithm import elementwise
from buffer import NDBuffer
from buffer.dimlist import Dim, DimList
from memory import memcpy
from gpu.host.info import is_cpu
from gpu.host import DeviceContext
from sys.info import _current_target
from gpu.host._compile import _get_gpu_target

from utils import StaticTuple, IndexList
from utils.index import product

# ===-----------------------------------------------------------------------===#
# split
# ===-----------------------------------------------------------------------===#


fn split[
    type: DType,
    rank: Int,
    num_outputs: Int,
    target: StringLiteral,
    trace_description: StaticString,
](
    input: NDBuffer[type, rank],
    axis: Int,
    outputs: StaticTuple[NDBuffer[type, rank, MutableAnyOrigin], num_outputs],
    ctx: DeviceContext,
) raises:
    # check inputs have same rank and same dims except for axis dim
    @parameter
    for i in range(num_outputs):

        @parameter
        for j in range(rank):
            if j != axis and outputs[0].dim(j) != outputs[i].dim(j):
                raise Error(
                    "all split outputs must have the same dimensions in the"
                    " non-split axes"
                )

    var input_shape = input.get_shape()
    var output_sizes = IndexList[num_outputs]()

    @parameter
    for i in range(num_outputs):
        output_sizes[i] = outputs[i].get_shape()[axis]

    @__copy_capture(output_sizes)
    @parameter
    fn elementwise_fn_wrapper[
        width: Int, rank: Int
    ](input_coords: IndexList[rank]) capturing:
        # The associated index in the output tensor
        var output_coords = IndexList[rank]()

        # Which output index to write to
        var output_idx = 0

        # The current shape
        var axis_output_dim = input_coords[axis]

        # First determine which output we should write to
        @parameter
        for i in range(num_outputs):
            if axis_output_dim >= output_sizes[i]:
                axis_output_dim -= output_sizes[i]
                output_idx += 1
            else:
                break

        # Then derive the output coordinate
        @parameter
        for i in range(rank):
            if i == axis:
                output_coords[i] = axis_output_dim
            else:
                output_coords[i] = input_coords[i]

        var value = input.load[width=width](input_coords)

        # Hack to get around current shortcomings with origins.
        rebind[NDBuffer[type, rank, MutableAnyOrigin]](
            outputs[output_idx]
        ).store[width=width](output_coords, value)

    # Can vectorize only if not splitting over last dim.
    if axis != rank - 1:
        alias compile_target = _current_target() if is_cpu[
            target
        ]() else _get_gpu_target()
        alias target_simd_width = simdwidthof[type, target=compile_target]()

        elementwise[
            elementwise_fn_wrapper,
            target_simd_width,
            target=target,
            _trace_description=trace_description,
        ](input.get_shape(), ctx)
    else:
        elementwise[
            elementwise_fn_wrapper,
            1,
            target=target,
            _trace_description=trace_description,
        ](input.get_shape(), ctx)
