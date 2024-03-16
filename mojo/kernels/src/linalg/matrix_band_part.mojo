# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""The module implements matrix band part functions."""

from algorithm.functional import _elementwise_impl
from buffer import NDBuffer
from runtime.tracing import TraceLevel

from utils.index import Index, StaticIntTuple
from utils.list import DimList


@always_inline
fn matrix_band_part[
    type: DType,
    int_type: DType,
    cond_type: DType,
    rank: Int,
    input_0_fn: fn[width: Int, rank: Int] (
        StaticIntTuple[rank]
    ) capturing -> SIMD[type, width],
    simd_width: Int,
    single_thread_blocking_override: Bool,
](
    input_shape: StaticIntTuple[rank],
    num_lower: NDBuffer[int_type, 1],
    num_upper: NDBuffer[int_type, 1],
    exclude_buf: NDBuffer[cond_type, 1],
    output: NDBuffer[type, rank],
):
    var lower_diagonal_index = int(num_lower[0])
    var upper_diagonal_index = int(num_upper[0])
    var exclude = exclude_buf[0] != 0

    constrained[rank >= 2, "Matrix band only supports rank >=2"]()

    @__copy_capture(lower_diagonal_index, upper_diagonal_index, exclude)
    @parameter
    @always_inline
    fn func[
        simd_width: Int, inner_rank: Int
    ](index: StaticIntTuple[inner_rank]):
        var idx = rebind[StaticIntTuple[rank]](index)

        var row = idx[rank - 2]
        var col = idx[rank - 1]

        var in_band = (
            lower_diagonal_index < 0 or (row - col) <= lower_diagonal_index
        ) and (upper_diagonal_index < 0 or (col - row) <= upper_diagonal_index)
        if exclude:
            in_band = not in_band

        if in_band:
            output[idx] = rebind[Scalar[type]](
                input_0_fn[simd_width, rank](idx)
            )
        else:
            output[idx] = 0

    _elementwise_impl[func, 1, rank, single_thread_blocking_override](
        input_shape,
    )
