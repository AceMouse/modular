# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""ops.concat tests."""

from random import Random

import pytest
from conftest import axes, shapes, tensor_types
from hypothesis import assume, given, settings
from hypothesis import strategies as st
from max.dtype import DType
from max.graph import Graph, TensorType, ops
from max.graph.type import Dim, Shape, StaticDim


shared_dtypes = st.shared(st.from_type(DType))
shared_shapes = st.shared(shapes())
shared_tensor_types = st.shared(
    tensor_types(dtypes=shared_dtypes, shapes=shared_shapes)
)

# For test speed, don't do huge concats.
MAX_CONCAT_SIZE = 100


def with_dim(shape: Shape, axis: int, dim: StaticDim):
    shape = Shape(shape)
    shape[axis] = dim
    return shape


@given(
    base_type=shared_tensor_types,
    axis_sizes=st.lists(st.from_type(StaticDim), max_size=MAX_CONCAT_SIZE),
    axis=axes(shared_tensor_types),
)
@settings(deadline=None)
def test_concat__static_dim(
    base_type: TensorType, axis_sizes: list[StaticDim], axis: int
):
    assume(axis_sizes)
    merged_size = sum(dim.dim for dim in axis_sizes)
    # TODO: test the error for this case
    assume(merged_size < 2**63)

    input_types = [
        TensorType(base_type.dtype, with_dim(base_type.shape, axis, dim))
        for dim in axis_sizes
    ]

    with Graph("concat", input_types=input_types) as graph:
        out = ops.concat(graph.inputs, axis)
        assert out.shape == with_dim(base_type.shape, axis, merged_size)
        graph.output(out)


@given(
    base_type=shared_tensor_types,
    axis=st.integers(),
)
# TODO(MSDK-847): fix the perf here and re-enable the deadline.
@settings(deadline=None)
def test_concat__axis_out_of_bounds(base_type: TensorType, axis: int):
    assume(axis < -base_type.rank or axis >= base_type.rank)

    with Graph("concat", input_types=[base_type]) as graph:
        with pytest.raises(IndexError):
            out = ops.concat(graph.inputs, axis)


@given(
    type_a=shared_tensor_types,
    type_b=tensor_types(shapes=shared_shapes),
    axis=axes(shared_tensor_types),
)
# TODO(MSDK-847): fix the perf here and re-enable the deadline.
@settings(deadline=None)
def test_concat__bad_dtype(type_a: TensorType, type_b: TensorType, axis: int):
    assume(type_a.dtype != type_b.dtype)
    assert type_a.shape == type_b.shape
    assume(
        not type_a.shape[axis].is_static()
        or 2 * type_a.shape[axis].dim < 2**63
    )

    with Graph("concat", input_types=[type_a, type_b]) as graph:
        with pytest.raises(ValueError):
            out = ops.concat(graph.inputs, axis)


@given(axis=...)
# TODO(MSDK-847): fix the perf here and re-enable the deadline.
@settings(deadline=None)
def test_concat__no_inputs(axis: int):
    with Graph("concat", input_types=[]) as graph:
        with pytest.raises(ValueError):
            out = ops.concat([], axis)


@given(
    type_a=shared_tensor_types,
    type_b=tensor_types(dtypes=shared_dtypes),
    axis=axes(shared_tensor_types),
)
# TODO(MSDK-847): fix the perf here and re-enable the deadline.
@settings(deadline=None)
def test_concat__different_ranks(
    type_a: TensorType, type_b: TensorType, axis: int
):
    assert type_a.dtype == type_b.dtype
    assume(type_a.rank != type_b.rank)

    with Graph("concat", input_types=[type_a, type_b]) as graph:
        with pytest.raises(ValueError):
            out = ops.concat(graph.inputs, axis)


@given(
    type_a=shared_tensor_types,
    type_b=shared_tensor_types.flatmap(
        lambda t: tensor_types(
            dtypes=shared_dtypes,
            shapes=shapes(min_size=t.rank, max_size=t.rank),
        )
    ),
    axis=axes(shared_tensor_types),
)
# TODO(MSDK-847): fix the perf here and re-enable the deadline.
@settings(deadline=None)
def test_concat__mismatched_dims(
    type_a: TensorType, type_b: TensorType, axis: int
):
    assert type_a.dtype == type_b.dtype
    assert type_a.rank == type_b.rank
    assume(
        not all(
            d1 == d2
            for i, (d1, d2) in enumerate(zip(type_a.shape, type_b.shape))
            if i != (axis if axis >= 0 else axis + type_a.rank)
        )
    )

    with Graph("concat", input_types=[type_a, type_b]) as graph:
        with pytest.raises(ValueError):
            out = ops.concat(graph.inputs, axis)


@given(
    base_type=shared_tensor_types,
    axis=axes(shared_tensor_types),
    axis_dims=st.lists(st.from_type(Dim), min_size=1, max_size=MAX_CONCAT_SIZE),
)
# TODO(MSDK-847): fix the perf here and re-enable the deadline.
@settings(deadline=None)
def test_concat__symbolic__size_gt_1__no_new_dim(
    base_type: TensorType, axis: int, axis_dims: list[Dim]
):
    assume(len(axis_dims) > 1)
    assume(not all(dim.is_static() for dim in axis_dims))
    merged_static_size = sum(dim.dim for dim in axis_dims if dim.is_static())
    assume(merged_static_size < 2**63)

    input_types = [
        TensorType(base_type.dtype, with_dim(base_type.shape, axis, dim))
        for dim in axis_dims
    ]

    with Graph("concat", input_types=input_types) as graph:
        with pytest.raises(ValueError):
            out = ops.concat(graph.inputs, axis)


@given(base_type=shared_tensor_types, axis=axes(shared_tensor_types))
# TODO(MSDK-847): fix the perf here and re-enable the deadline.
@settings(deadline=None)
def test_concat__symbolic__size_1(base_type: TensorType, axis: int):
    assume(not base_type.shape[axis].is_static())

    with Graph("concat", input_types=[base_type]) as graph:
        out = ops.concat(graph.inputs, axis)
        assert out.shape == base_type.shape
        graph.output(out)


@given(
    base_type=shared_tensor_types,
    axis=axes(shared_tensor_types),
    axis_dims=st.lists(st.from_type(Dim), min_size=1, max_size=MAX_CONCAT_SIZE),
    new_dim=...,
)
# TODO(MSDK-847): fix the perf here and re-enable the deadline.
@settings(deadline=None)
def test_concat__symbolic__new_dim(
    base_type: TensorType,
    axis: int,
    axis_dims: list[Dim],
    new_dim: Dim,
):
    assume(axis_dims)
    assume(not all(dim.is_static() for dim in axis_dims))
    merged_static_size = sum(dim.dim for dim in axis_dims if dim.is_static())
    assume(merged_static_size < 2**63)

    input_types = [
        TensorType(base_type.dtype, with_dim(base_type.shape, axis, dim))
        for dim in axis_dims
    ]

    with Graph("concat", input_types=input_types) as graph:
        out = ops.concat(graph.inputs, axis, new_dim=new_dim)
        assert out.shape == with_dim(base_type.shape, axis, new_dim)
        graph.output(out)
