# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Test the max.graph Python bindings."""

import itertools
from typing import Optional

from conftest import broadcast_shapes, broadcastable_tensor_types
from hypothesis import assume, event, given
from max.graph import DType, Graph
from max.graph.ops import sub
from max.graph.type import Dim, StaticDim, TensorType


@given(tensor_type=...)
def test_sub__same_type(tensor_type: TensorType):
    with Graph("sub", input_types=[tensor_type, tensor_type]) as graph:
        op = sub(graph.inputs[0], graph.inputs[1])
        assert op.tensor_type == tensor_type


@given(tensor_type=...)
def test_sub__same_type__operator(tensor_type: TensorType):
    with Graph("sub", input_types=[tensor_type, tensor_type]) as graph:
        op = graph.inputs[0] - graph.inputs[1]
        assert op.tensor_type == tensor_type


@given(d1=..., d2=..., shape=...)
def test_sub__promoted_dtype__operator(d1: DType, d2: DType, shape: list[Dim]):
    assume(d1 != d2)
    t1 = TensorType(d1, shape)
    t2 = TensorType(d2, shape)
    with Graph("sub", input_types=[t1, t2]) as graph:
        i0, i1 = graph.inputs
        try:
            assert (i0 - i1).tensor_type.dtype in (d1, d2)
            assert (i1 - i0).tensor_type.dtype in (d1, d2)
            assert (i0 - i1).tensor_type == (i1 - i0).tensor_type
            event("types promote")
        except ValueError as e:
            assert "Unsafe cast" in str(e)
            event("types don't promote")


@given(types=broadcastable_tensor_types(2))
def test_sub__broadcast__operator(types: list[TensorType]):
    t1, t2 = types
    broadcast_shape = broadcast_shapes(t1.shape, t2.shape)
    with Graph("sub", input_types=[t1, t2]) as graph:
        i0, i1 = graph.inputs
        assert (i0 - i1).tensor_type.shape == broadcast_shape
        assert (i1 - i0).tensor_type.shape == broadcast_shape
