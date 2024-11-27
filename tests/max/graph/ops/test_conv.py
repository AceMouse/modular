# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""ops.conv2d tests."""

from math import sqrt

import pytest
import numpy as np

from conftest import (
    MAX_INT32,
    static_dims,
    tensor_types,
)
from hypothesis import assume, given
from hypothesis import strategies as st
from max.dtype import DType
from max.graph import Graph, TensorType, Weight, ops

shared_dtypes = st.shared(st.from_type(DType))
static_tensor_type = tensor_types(
    dtypes=shared_dtypes,
    shapes=(
        st.lists(
            static_dims(min=1, max=int(sqrt(sqrt(MAX_INT32)))),
            min_size=4,
            max_size=4,
        )
    ),
)

sized_int = st.integers(min_value=0, max_value=10)
pos_int = st.integers(min_value=1, max_value=10)

padding_type = st.tuples(sized_int, sized_int, sized_int, sized_int)
stride_type = st.tuples(pos_int, pos_int)


@given(
    x_type=static_tensor_type,
    filter_type=static_tensor_type,
    stride=stride_type,
    padding=padding_type,
)
def test_conv_valid(
    x_type: TensorType, filter_type: TensorType, stride, padding
):
    assume(filter_type.shape[0] <= x_type.shape[1])
    assume(filter_type.shape[1] <= x_type.shape[2])
    with Graph("conv", input_types=[x_type, filter_type]) as graph:
        out = ops.conv2d(
            graph.inputs[0],
            graph.inputs[1],
            stride=stride,
            padding=padding,
        )
        output_height = (
            x_type.shape[1]
            - filter_type.shape[0]
            + padding[0]
            + padding[1]
            + stride[0]
        ) // stride[0]
        output_width = (
            x_type.shape[2]
            - filter_type.shape[1]
            + padding[2]
            + padding[3]
            + stride[1]
        ) // stride[1]
        assert out.shape == [
            x_type.shape[0],
            output_height,
            output_width,
            filter_type.shape[3],
        ]
        graph.output(out)


def test_conv_dtype_promote_np():
    x_type = TensorType(DType.bfloat16, [1, 128, 128, 4])
    filter_shape = [3, 3, 4, 5]
    filter = np.ones(filter_shape, dtype=np.float32)
    with Graph("conv", input_types=[x_type]) as graph:
        out = ops.conv2d(
            graph.inputs[0],
            filter,
        )
        # The numpy filter has a weak dtype. This all resolves happily.
        assert out.dtype == DType.bfloat16
        graph.output(out)


def test_conv_dtype_promote_weight():
    x_type = TensorType(DType.bfloat16, [1, 128, 128, 4])
    filter_shape = [3, 3, 4, 5]
    filter = Weight(
        "filter",
        dtype=DType.bfloat16,
        shape=filter_shape,
    )
    with Graph("conv", input_types=[x_type]) as graph:
        out = ops.conv2d(
            graph.inputs[0],
            filter,
        )
        # Both input and filter dtype exactly match.
        assert out.dtype == DType.bfloat16
        graph.output(out)


def test_conv_dtype_promote_weight_failed():
    x_type = TensorType(DType.bfloat16, [1, 128, 128, 4])
    filter_shape = [3, 3, 4, 5]
    filter = Weight(
        "filter",
        dtype=DType.float32,
        shape=filter_shape,
    )
    with Graph("conv", input_types=[x_type]) as graph:
        # Both the input and weight have strong dtypes. Conv requires them to match.
        with pytest.raises(
            ValueError,
            match="input and filter must resolve to the same strong dtype",
        ):
            out = ops.conv2d(
                graph.inputs[0],
                filter,
            )
