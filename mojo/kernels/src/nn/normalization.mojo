# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from math import sqrt, min, div_ceil

from algorithm import map_reduce, mean, variance, vectorize
from algorithm.reduction import (
    _simd_sum,
    _simd_sum_elementwise,
    _get_nd_indices_from_flat_index,
)
from NN.Reshape import reshape
from algorithm.functional import sync_parallelize
from runtime.tracing import Trace, TraceLevel
from runtime.llcl import Runtime
from memory.buffer import Buffer, NDBuffer

from utils.index import StaticIntTuple
from utils.list import Dim, DimList
from utils.static_tuple import StaticTuple


fn layer_norm[
    simd_width: Int,
    type: DType,
    input_fn: fn[mytype: DType, width: Int] (Int, Int) capturing -> SIMD[
        mytype, width
    ],
    shape: DimList,
    inner_dim: DimList,
](
    out_buf: NDBuffer[type, 2, shape],
    gamma_buf: NDBuffer[type, 1, inner_dim],
    beta_buf: NDBuffer[type, 1, inner_dim],
    eps: SIMD[type, 1],
):
    """Computes layernorm(elementwise_fn(x)) across the last dimension of x, where layernorm is
    defined as $(x-mean(x))/(sqrt(var(x)+eps)*gamma + beta$.

    Currently performs 3 passes over the input data. This can be reduced to 2 by
    fusing the add, mean, and variance loops using Welford's algorithm.

    Parameters:
        simd_width: The vector width for the computation.
        type: The x and out buffers' elements dtype.
        input_fn: Function called to generate an input value.
        shape: The x and out buffers' shape.
        inner_dim: The shape of gamma_buf and beta_buf.

    Args:
        out_buf: The output buffer.
        gamma_buf: The gamma value to use in the layernorm calculation.
        beta_buf: The beta value to use in the layernorm calculation.
        eps: The eps value to use in the layernorm calculation.
    """

    let m = out_buf.dim[0]()
    let n = out_buf.dim[1]()  # contiguous

    for i in range(m):
        let start_coord = StaticIntTuple[2](i, 0)
        let out_slice = Buffer[type, shape.at[1]()](
            out_buf._offset(start_coord), n
        )

        @__copy_capture(sum_val, n)
        @parameter
        fn input_gen_wrapper[
            return_type: DType, simd_width: Int
        ](idx: Int) -> SIMD[return_type, simd_width]:
            return input_fn[return_type, simd_width](idx, i)

        let sum_val = map_reduce[
            simd_width,
            shape.at[1](),
            type,
            type,
            input_gen_wrapper,
            _simd_sum_elementwise,
            _simd_sum,
        ](out_slice, 0)

        @__copy_capture(sum_val, n)
        @parameter
        fn _sum_to_mean() -> SIMD[type, 1]:
            @parameter
            if type.is_integral():
                return sum_val // n
            return sum_val / n

        let mean_val = _sum_to_mean()

        let var_val = variance(out_slice, mean_val, 0)  # use biased estimator

        let norm_factor = 1 / sqrt(var_val + eps)

        @__copy_capture(out_slice, norm_factor, mean_val)
        @parameter
        fn _normalize[simd_width: Int](idx: Int):
            let out_val = out_slice.simd_load[simd_width](idx)
            let norm_val = (
                out_val - mean_val
            ) * norm_factor * gamma_buf.simd_load[simd_width](
                idx
            ) + beta_buf.simd_load[
                simd_width
            ](
                idx
            )
            out_slice.simd_store(idx, norm_val)

        vectorize[_normalize, simd_width](n)


fn layer_norm[
    type: DType,
    input_0_fn: fn[_width: Int, _rank: Int] (
        StaticIntTuple[_rank]
    ) capturing -> SIMD[type, _width],
    rank: Int,
](
    shape: StaticIntTuple[rank],
    gamma: NDBuffer[type, 1],
    beta: NDBuffer[type, 1],
    epsilon: NDBuffer[type, 1],
    output: NDBuffer[type, rank],
):
    @always_inline
    @parameter
    fn description_fn() -> String:
        return String(";").join(
            String("shape=") + String("x").join(shape),
        )

    with Trace[TraceLevel.OP](
        "mojo.layer_norm",
        Trace[TraceLevel.OP]._get_detail_str[description_fn](),
    ) as t:
        let eps = epsilon[0]

        alias simd_width = simdwidthof[type]()

        let last_dim = shape[rank - 1]
        let prod_all_but_last_dim = shape.flattened_length() // last_dim
        let flat_shape = StaticIntTuple[2](prod_all_but_last_dim, last_dim)

        let output_buf = reshape[rank, 2, type, True](output, flat_shape)

        let num_workers = min(
            Runtime().parallelism_level(), prod_all_but_last_dim
        )
        let chunk_size = div_ceil(prod_all_but_last_dim, num_workers)

        @__copy_capture(
            chunk_size, prod_all_but_last_dim, last_dim, output_buf, eps
        )
        @parameter
        fn task_func(thread_id: Int):
            let num_rows = min(
                chunk_size, prod_all_but_last_dim - thread_id * chunk_size
            )
            let row_idx = thread_id * chunk_size
            let thread_starting_coord = StaticIntTuple[2](row_idx, 0)
            let per_thread_dims = DimList(num_rows, last_dim)
            let output_buf_view = NDBuffer[type, 2](
                output_buf._offset(thread_starting_coord), per_thread_dims
            )

            @__copy_capture(row_idx, eps)
            @parameter
            @always_inline
            # Translate given 2d index back to original Nd tensor
            fn input_fn_2d[
                return_type: DType, simd_width: Int
            ](idx: Int, row: Int) -> SIMD[return_type, simd_width]:
                var indices = _get_nd_indices_from_flat_index[rank](
                    row_idx + row, shape, rank - 1
                )
                indices[rank - 1] = idx
                let input_val = input_0_fn[simd_width, rank](indices)
                return input_val.cast[return_type]()

            layer_norm[simd_width, type, input_fn_2d](
                output_buf_view, gamma, beta, eps
            )

        sync_parallelize[task_func](num_workers)
