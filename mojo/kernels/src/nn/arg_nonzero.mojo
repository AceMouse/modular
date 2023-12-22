# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from algorithm import sync_parallelize, vectorize_unroll
from algorithm.functional import _get_start_indices_of_nth_subvolume
from memory.buffer import NDBuffer
from runtime.llcl import OutputChainPtr
from runtime.tracing import Trace, TraceLevel

from utils.index import StaticIntTuple
from utils.list import Dim, DimList

# ===----------------------------------------------------------------------===#
# arg_nonzero
# ===----------------------------------------------------------------------===#


@always_inline
fn arg_nonzero[
    type: DType,
    output_type: DType,
    rank: Int,
](
    input_buffer: NDBuffer[rank, DimList.create_unknown[rank](), type],
    output_buffer: NDBuffer[2, DimList.create_unknown[2](), output_type],
    out_chain: OutputChainPtr,
):
    """Gather the indices of all non-zero elements in input buffer storing
    the indices in the output_buffer.

    Parameters:
        type: The element type.
        output_type: The integer type to store the indices in.
        rank: The rank of the tensor.

    Args:
        input_buffer: The tensor to count the non-zeros in.
        output_buffer: The indices of all non-zero elements.
        out_chain: The our chain to attach results to.
    """

    with Trace[TraceLevel.OP]("mojo.arg_nonzero") as t:
        let numel = input_buffer.dynamic_shape.flattened_length()
        if numel == 0:
            return

        var j: Int = 0
        for i in range(numel):
            let indices = _get_start_indices_of_nth_subvolume[rank, 0](
                i, input_buffer.dynamic_shape
            )
            if input_buffer[indices] != 0:
                var out_indices = StaticIntTuple[2]()
                out_indices[0] = j
                j += 1

                # Write each of the output values to the output buffer.
                @unroll
                for k in range(rank):
                    out_indices[1] = k
                    output_buffer[out_indices] = indices[k]


# Where has the shape 2D shape [NumNonZeros, InputRank]
@always_inline
fn arg_nonzero_shape[
    type: DType,
    rank: Int,
    single_thread_blocking_override: Bool,
](
    input_buffer: NDBuffer[rank, DimList.create_unknown[rank](), type],
) -> StaticIntTuple[2]:
    """Return [NumNonZeros, InputRank] where NumNonZeros are the number of
    non-zero elements in the input.

    Parameters:
        type: The element type.
        rank: The rank.
        single_thread_blocking_override: This op can block.

    Args:
        input_buffer: The tensor to count the non-zeros in.

    Returns:
        Shape of the arg_nonzero kernel for this input [NumNonZeros, InputRank].
    """

    var shape = StaticIntTuple[2]()
    shape[1] = rank

    let numel = input_buffer.dynamic_shape.flattened_length()

    var j: Int = 0
    for i in range(numel):
        let indices = _get_start_indices_of_nth_subvolume[rank, 0](
            i, input_buffer.dynamic_shape
        )
        if input_buffer[indices] != 0:
            j += 1

    shape[0] = j
    return shape
