# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""test the max.graph python bindings."""

import pytest
from conftest import broadcast_shapes, broadcastable_shapes, tensor_types
from hypothesis import assume, given, reject
from hypothesis import strategies as st
from max.dtype import DType
from max.graph import Graph, Shape, TensorType
from max.graph.ops import logical_and


@given(tensor_type=tensor_types(dtypes=st.just(DType.bool)))
def test_logical_and__same_type(tensor_type: TensorType):
    with Graph("logical_and", input_types=[tensor_type, tensor_type]) as graph:
        x, y = graph.inputs
        op = logical_and(x, y)
        assert op.type == tensor_type


@given(tensor_type=...)
def test_logical_and__invalid_dtype(tensor_type: TensorType):
    assume(tensor_type.dtype != DType.bool)
    with Graph("logical_and", input_types=[tensor_type, tensor_type]) as graph:
        x, y = graph.inputs
        with pytest.raises(ValueError):
            logical_and(x, y)


@given(shapes=broadcastable_shapes(2))
def test_logical_and__broadcast(shapes: list[Shape]):
    s1, s2 = shapes
    broadcast_shape = broadcast_shapes(s1, s2)
    with Graph(
        "logical_and",
        input_types=[TensorType(DType.bool, s1), TensorType(DType.bool, s2)],
    ) as graph:
        x, y = graph.inputs
        assert logical_and(x, y).shape == broadcast_shape
        assert logical_and(y, x).shape == broadcast_shape


@pytest.mark.skip("MSDK-1158")
@given(s1=..., s2=...)
def test_logical_and__invalid_broadcast(s1: Shape, s2: Shape):
    try:
        broadcast_shapes(s1, s2)
    except ValueError:
        pass
    else:
        reject()  # valid broadcast

    with Graph(
        "logical_and",
        input_types=[TensorType(DType.bool, s1), TensorType(DType.bool, s2)],
    ) as graph:
        x, y = graph.inputs
        with pytest.raises(Exception):
            logical_and(x, y)
        with pytest.raises(Exception):
            logical_and(y, x)


@given(tensor_type=tensor_types(dtypes=st.just(DType.bool)), b=...)
def test_logical_and__python_bool(tensor_type: TensorType, b: bool):
    with Graph("logical_and", input_types=[tensor_type]) as graph:
        (x,) = graph.inputs
        assert logical_and(x, b).type == tensor_type
        assert logical_and(b, x).type == tensor_type
