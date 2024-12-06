# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""mutable ops tests."""

import pytest
from conftest import buffer_types, shapes, tensor_types
from hypothesis import assume, given, settings
from hypothesis import strategies as st
from max import _graph, mlir
from max.dtype import DType
from max.graph import (
    BufferType,
    BufferValue,
    Graph,
    TensorType,
    TensorValue,
    Value,
    _ChainType,
    _ChainValue,
    ops,
)

shared_dtypes = st.shared(st.from_type(DType))
shared_shapes = st.shared(shapes().filter(lambda shape: 0 not in shape))
tensor_type = tensor_types(shapes=shared_shapes, dtypes=shared_dtypes)
buffer_type = buffer_types(shapes=shared_shapes, dtypes=shared_dtypes)


@given(buffer_type=...)
def test_mlir_type_checking(buffer_type: BufferType):
    with Graph(
        "buffer",
        input_types=[
            buffer_type,
        ],
    ) as graph:
        buffer = graph.inputs[0]
        type = buffer.type
        assert isinstance(buffer, BufferValue)
        assert type == buffer_type
        assert not isinstance(buffer, mlir.Value)
        assert _graph.type_is_buffer(buffer._mlir_value.type)
        assert not _graph.type_is_tensor(buffer._mlir_value.type)
        assert not _graph.type_is_opaque(buffer._mlir_value.type)


@given(tensor_type=tensor_type, buffer_type=buffer_type)
def test_value_constructor(tensor_type: TensorType, buffer_type: BufferType):
    with Graph(
        "buffer_store",
        input_types=[
            tensor_type,
            buffer_type,
        ],
    ) as graph:
        buffer = Value(graph.inputs[1]._mlir_value)
        assert isinstance(buffer, BufferValue)
        assert buffer._mlir_value is not None
        tensor = Value(graph.inputs[0]._mlir_value)
        assert isinstance(tensor, TensorValue)
        assert tensor._mlir_value is not None

        buffer = BufferValue(graph.inputs[1]._mlir_value)
        assert isinstance(buffer, BufferValue)
        assert buffer._mlir_value is not None
        tensor = TensorValue(graph.inputs[0]._mlir_value)
        assert isinstance(tensor, TensorValue)
        assert tensor._mlir_value is not None

        with pytest.raises(TypeError):
            BufferValue(graph.inputs[0]._mlir_value)
        with pytest.raises(TypeError):
            TensorValue(graph.inputs[1]._mlir_value)

        buffer = Value(graph.inputs[1])
        assert isinstance(buffer, BufferValue)
        assert buffer._mlir_value is not None
        tensor = Value(graph.inputs[0])
        assert isinstance(tensor, TensorValue)
        assert tensor._mlir_value is not None

        buffer = BufferValue(graph.inputs[1])
        assert isinstance(buffer, BufferValue)
        assert buffer._mlir_value is not None
        tensor = TensorValue(graph.inputs[0])
        assert isinstance(tensor, TensorValue)
        assert tensor._mlir_value is not None

        with pytest.raises(TypeError):
            BufferValue(graph.inputs[0])
        with pytest.raises(TypeError):
            TensorValue(graph.inputs[1])

        with pytest.raises(TypeError):
            TensorValue(0)

        with pytest.raises(TypeError):
            BufferValue(0)


# buffer and tensor inputs share dtype and shape
@given(buffer_type=...)
def test_load(buffer_type: BufferType):
    with Graph(
        "buffer_load",
        input_types=[
            buffer_type,
        ],
    ) as graph:
        buffer = graph.inputs[0]
        chain_0 = graph._current_chain
        assert isinstance(chain_0, _ChainValue)
        assert isinstance(chain_0.type, _ChainType)

        y = ops.buffer_load(buffer)
        chain_1 = graph._current_chain

        assert isinstance(chain_1, _ChainValue)
        assert isinstance(chain_1.type, _ChainType)

        assert y.shape == buffer.shape
        assert y.dtype == buffer.dtype
        assert isinstance(y, TensorValue)
        # Check the chain is updated.
        assert chain_0 != chain_1

        graph.output()
        graph._mlir_op.verify()
        assert "rmo.mo.mutable.load" in str(graph)
        assert "mo.chain.create" in str(graph)


# buffer and tensor inputs share dtype and shape
@given(tensor_type=tensor_type, buffer_type=buffer_type)
def test_store(tensor_type: TensorType, buffer_type: BufferType):
    with Graph(
        "buffer_store",
        input_types=[
            tensor_type,
            buffer_type,
        ],
    ) as graph:
        tensor = graph.inputs[0]
        buffer = graph.inputs[1]
        chain_0 = graph._current_chain
        ops.buffer_store(buffer, tensor)
        chain_1 = graph._current_chain

        assert buffer.shape == tensor.shape
        assert buffer.dtype == tensor.dtype

        # Check the chain is updated.
        assert chain_0 != chain_1

        graph.output()
        graph._mlir_op.verify()
        assert "rmo.mo.mutable.store" in str(graph)
        assert "mo.chain.create" in str(graph)


@given(buffer_type=...)
def test_load_store(buffer_type: BufferType):
    with Graph(
        "buffer_load_store",
        input_types=[
            buffer_type,
        ],
    ) as graph:
        buffer = graph.inputs[0]
        chain_0 = graph._current_chain
        tensor = ops.buffer_load(buffer)
        chain_1 = graph._current_chain

        assert tensor.shape == buffer.shape
        assert tensor.dtype == buffer.dtype
        assert isinstance(tensor, TensorValue)
        assert chain_0 != chain_1

        ops.buffer_store(buffer, tensor)
        chain_2 = graph._current_chain

        assert buffer.shape == tensor.shape
        assert buffer.dtype == tensor.dtype
        assert chain_0 != chain_2
        assert chain_1 != chain_2

        graph.output()
        graph._mlir_op.verify()
        assert "mo.chain.create" in str(graph)
        assert "rmo.mo.mutable.load" in str(graph)
        assert "rmo.mo.mutable.store" in str(graph)


@given(tensor_type=tensor_type, buffer_type=buffer_type)
def test_load_store_ellipsis_slice(
    tensor_type: TensorType, buffer_type: BufferType
):
    assume(tensor_type.rank > 1 and buffer_type.rank > 1)

    with Graph(
        "buffer_load",
        input_types=[
            tensor_type,
            buffer_type,
        ],
    ) as graph:
        tensor = graph.inputs[0]
        buffer = graph.inputs[1]
        chain_0 = graph._current_chain
        buffer[...] = tensor + buffer[...]
        chain_1 = graph._current_chain

        assert buffer.shape == tensor.shape
        assert buffer.dtype == tensor.dtype
        # Check the chain is updated.
        assert chain_0 != chain_1

        graph.output()
        graph._mlir_op.verify()
        assert "rmo.mo.mutable.load" in str(graph)
        assert "rmo.mo.mutable.store" in str(graph)
        assert "rmo.mo.mutable.store.slice" not in str(graph)
        assert "mo.chain.create" in str(graph)


@given(tensor_type=tensor_type, buffer_type=buffer_type)
# TODO(MSDK-847): fix the perf here and re-enable the deadline.
@settings(deadline=None)
def test_load_store_slice(tensor_type: TensorType, buffer_type: BufferType):
    assume(tensor_type.rank > 1 and buffer_type.rank > 1)

    with Graph(
        "buffer_load",
        input_types=[
            tensor_type,
            buffer_type,
        ],
    ) as graph:
        tensor = graph.inputs[0]
        buffer = graph.inputs[1]
        chain_0 = graph._current_chain
        buffer[0] = tensor[0] + buffer[0]
        chain_1 = graph._current_chain

        assert buffer.shape == tensor.shape
        assert buffer.dtype == tensor.dtype
        # Check the chain is updated.
        assert chain_0 != chain_1

        graph.output()
        graph._mlir_op.verify()
        assert "rmo.mo.mutable.load" in str(graph)
        assert "rmo.mo.mutable.store" in str(graph)
        assert "rmo.mo.mutable.store.slice" in str(graph)
        assert "mo.chain.create" in str(graph)


@given(tensor_type=tensor_type, buffer_type=buffer_type)
def test_no_implicit_load(tensor_type: TensorType, buffer_type: BufferType):
    assume(tensor_type.rank > 1 and buffer_type.rank > 1)

    with Graph(
        "buffer_load",
        input_types=[
            tensor_type,
            buffer_type,
        ],
    ) as graph:
        tensor = graph.inputs[0]
        buffer = graph.inputs[1]

        with pytest.raises(TypeError):  # binary ops
            y = tensor + buffer

        with pytest.raises(TypeError):  # unary ops
            y = abs(buffer)

        assert "rmo.mo.mutable.load" not in str(graph)
        assert "rmo.mo.slice" not in str(graph)


@given(tensor_type=tensor_type, buffer_type=buffer_type)
def test_inplace_custom(tensor_type: TensorType, buffer_type: BufferType):
    with Graph(
        "buffer_load",
        input_types=[buffer_type, tensor_type],
    ) as graph:
        buffer: BufferValue = graph.inputs[0]
        tensor: TensorValue = graph.inputs[1]

        chain_0 = graph._current_chain

        ops.inplace_custom("foo", values=[buffer])
        chain_1 = graph._current_chain

        ops.buffer_store(buffer, tensor)
        chain_2 = graph._current_chain

        ops.inplace_custom("bar", values=[buffer])
        chain_3 = graph._current_chain

        with pytest.raises(TypeError):
            ops.inplace_custom("baz", values=[tensor])

        graph.output()

        assert chain_0 != chain_1
        assert chain_1 != chain_2
        assert chain_2 != chain_3

        assert 'mo.custom {symbol = "foo"}' in str(graph)
        assert 'mo.custom {symbol = "bar"}' in str(graph)


@given(tensor_type=tensor_type, buffer_type=buffer_type)
def test_prints_with_buffer_ops(
    tensor_type: TensorType, buffer_type: BufferType
):
    with Graph(
        "debug_prints_and_mutable_ops",
        input_types=[buffer_type, tensor_type],
    ) as graph:
        buffer: BufferValue = graph.inputs[0]
        tensor: TensorValue = graph.inputs[1]

        chain_0 = graph._current_chain

        tensor.print()
        chain_1 = graph._current_chain

        x = buffer[...]
        chain_2 = graph._current_chain

        x.print()
        chain_3 = graph._current_chain

        ops.buffer_store(buffer, tensor)
        chain_3 = graph._current_chain

        graph.output()

        assert chain_0 != chain_1
        assert chain_1 != chain_2
        assert chain_2 != chain_3


# TODO(MSDK-960): test that the chain is working correctly.
# TODO(MSDK-960): test load -> element-wise ops -> store.


def test_custom_buffer_error() -> None:
    """Test that we get an error for passing unchained buffers to custom ops."""
    with Graph(
        "custom_buffer_error",
        input_types=[BufferType(DType.float32, shape=[42])],
    ) as graph:
        buffer = graph.inputs[0]

        with pytest.raises(
            TypeError,
            match=(
                "custom ops that take buffers or opaque values to do in-place "
                "updates should use ops.inplace_custom instead"
            ),
        ):
            _ = ops.custom(
                "bar",
                values=[buffer],
                out_types=[TensorType(DType.uint32, shape=[])],
            )[0]

        graph.output()
