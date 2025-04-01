# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Integration tests for mutable ops."""

import os
from pathlib import Path

import numpy as np
import pytest
import torch
from max.driver import Tensor
from max.dtype import DType
from max.engine import InferenceSession
from max.graph import BufferType, BufferValue, Graph, TensorType, ops
from max.graph.ops import buffer_load, buffer_store


@pytest.fixture
def custom_ops_path() -> Path:
    return Path(os.environ["CUSTOM_OPS_PATH"])


def torch_add_n(x, n):
    return torch.add(x, n)


def torch_multiply(x):
    return torch.mul(x, x)


def torch_add_relu(x):
    relu = torch.nn.ReLU()
    return relu(torch.add(x, 100))


def zeros(shape, dtype):
    return np.zeros([int(d) for d in shape]).astype(dtype.to_numpy())


def ones(shape, dtype):
    return np.ones([int(d) for d in shape]).astype(dtype.to_numpy())


@pytest.fixture(
    params=[
        BufferType(DType.float32, [100, 100]),
        BufferType(DType.float32, [10, 10]),
        BufferType(DType.float32, [100, 40]),
    ]
)
def buffer_type(request):
    return request.param


@pytest.fixture(
    params=[
        TensorType(DType.float32, [10, 10]),
        TensorType(DType.float32, [1, 1]),
        TensorType(DType.float32, [10, 2]),
        TensorType(DType.float32, [5, 5]),
    ]
)
def tensor_type(request):
    return request.param


@pytest.fixture
def buffer_graph(buffer_type) -> Graph:
    graph = Graph("buffer", input_types=[buffer_type])
    return graph


@pytest.fixture
def buffer_tensor_graph(tensor_type, buffer_type) -> Graph:
    graph = Graph(
        "buffer_tensor",
        input_types=[
            tensor_type,
            buffer_type,
        ],
    )
    return graph


@pytest.mark.parametrize("n", [-9, 9, 100])
def test_load_mutate_store(n, buffer_graph: Graph, session: InferenceSession):
    with buffer_graph as graph:
        input_buffer = graph.inputs[0]
        x = buffer_load(input_buffer)
        x = x + n
        buffer_store(input_buffer, x)
        graph.output()
        graph._mlir_op.verify()
        compiled = session.load(graph)
    input = zeros(input_buffer.shape, input_buffer.dtype)
    expected = torch_add_n(torch.from_numpy(input), n)
    compiled.execute(input)
    assert np.allclose(input, expected)


@pytest.mark.parametrize("n", [-9, 9, 100])
def test_load_mutate_store_ellipsis(
    n, buffer_graph: Graph, session: InferenceSession
):
    with buffer_graph as graph:
        input_buffer = graph.inputs[0]
        input_buffer[...] = input_buffer[...] + n
        graph.output()
        graph._mlir_op.verify()
        compiled = session.load(graph)
    input = zeros(input_buffer.shape, input_buffer.dtype)
    expected = torch_add_n(torch.from_numpy(input), n)
    compiled.execute(input)
    assert np.allclose(input, expected)


@pytest.mark.parametrize("n", [-9, 9, 100])
def test_store_slice_load_slice(
    n, buffer_tensor_graph: Graph, session: InferenceSession
):
    with buffer_tensor_graph as graph:
        tensor = graph.inputs[0]
        buffer = graph.inputs[1]

        buf_idx = [(slice(0, int(d)), d) for d in tensor.shape]
        y = tensor * tensor
        # Store slice.
        buffer[*buf_idx] = y + buffer[*buf_idx]

        graph.output()

        compiled_model = session.load(graph)
    input_tensor = ones(tensor.shape, tensor.dtype) + n
    input_buffer = zeros(buffer.shape, buffer.dtype) + n
    compiled_model.execute(input_tensor, input_buffer)

    expected = zeros(buffer.shape, buffer.dtype) + n
    expected[: input_tensor.shape[0], : input_tensor.shape[1]] = (
        torch_multiply(torch.from_numpy(input_tensor))
        + expected[: input_tensor.shape[0], : input_tensor.shape[1]]
    )
    assert np.allclose(input_buffer, expected)


def test_inplace_user_supplied(custom_ops_path, session: InferenceSession):
    bt = BufferType(DType.float32, [2, 2])

    with Graph(
        "basic", input_types=[bt], custom_extensions=[custom_ops_path]
    ) as graph:
        buffer: BufferValue = graph.inputs[0]

        # this custom op is equivalent to buffer[0,0] += 1
        ops.inplace_custom("mutable_test_op", values=[buffer])
        ops.inplace_custom("mutable_test_op", values=[buffer])
        buffer[...] = ops.negate(buffer[...])

        graph.output()

    rawbuffer = np.ones((2, 2), dtype=np.float32)

    model = session.load(graph, custom_ops_path=custom_ops_path)
    model.execute(Tensor.from_dlpack(rawbuffer))

    actual = np.array([[3, 1], [1, 1]], dtype=np.float32) * -1

    np.testing.assert_equal(rawbuffer, actual)


def test_variadic_buffer_handling(
    custom_ops_path: Path, session: InferenceSession
) -> None:
    """Test custom op with variadic buffer inputs."""

    # Build, compile, and execute.
    output = session.load(
        Graph(
            "variadic_buffer_test",
            forward=lambda x, y: ops.inplace_custom(
                "reduce_buffers",
                values=[x, y],
                out_types=[TensorType(DType.float32, [1])],
            ),
            input_types=[
                BufferType(DType.float32, [2]),
                BufferType(DType.float32, [2]),
            ],
            custom_extensions=[custom_ops_path],
        ),
        custom_extensions=[custom_ops_path],
    ).execute(np.arange(2, dtype=np.float32), np.arange(2, dtype=np.float32))[0]
    assert isinstance(output, Tensor)
