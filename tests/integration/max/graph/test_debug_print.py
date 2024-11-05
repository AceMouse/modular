# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Test value printing and debug print options."""


import platform
import pytest
import numpy as np
import pytest
from max.driver import Tensor
from max.driver.tensor import load_max_tensor
from max.dtype import DType
from max.graph import BufferType, Graph, TensorType


@pytest.fixture(scope="module")
def compiled_model(session):
    def print_input(x):
        x.print("test_x_value")
        return x

    g = Graph("test_print", print_input, [TensorType(DType.float32, ["dim1"])])
    return session.load(g)


@pytest.fixture(scope="module")
def compiled_buffer_model(session):
    def print_input(x):
        x.print("test_x_value")
        return x

    g = Graph("test_print", print_input, [BufferType(DType.float32, ["dim1"])])
    return session.load(g)


def test_debug_print_options(session, tmp_path):
    with pytest.raises(TypeError, match="Invalid debug print style"):
        session.set_debug_print_options("NOTVALID")

    session.set_debug_print_options("COMPACT")
    session.set_debug_print_options("NONE")

    session.set_debug_print_options("FULL")
    session.set_debug_print_options("FULL", precision=5)
    with pytest.raises(TypeError, match="precision must be an int"):
        session.set_debug_print_options("FULL", precision=5.0)

    session.set_debug_print_options("BINARY", output_directory=tmp_path)
    session.set_debug_print_options("BINARY", output_directory=str(tmp_path))
    with pytest.raises(ValueError, match="output directory cannot be empty"):
        session.set_debug_print_options("BINARY")


def test_debug_print_compact(compiled_model, session, capfd):
    session.set_debug_print_options("COMPACT")
    _ = compiled_model.execute(
        Tensor.from_numpy(np.full([20], 1.1234567, np.float32))
    )
    captured = capfd.readouterr()
    assert (
        "test_x_value = tensor([[1.1235, 1.1235, 1.1235, ..., 1.1235,"
        " 1.1235, 1.1235]], dtype=f32, shape=[20])"
        in captured.out
    )


def test_debug_print_buffer(compiled_buffer_model, session, capfd):
    session.set_debug_print_options("COMPACT")
    _ = compiled_buffer_model.execute(
        Tensor.from_numpy(np.full([20], 1.1234567, np.float32))
    )
    captured = capfd.readouterr()
    assert (
        "test_x_value = tensor([[1.1235, 1.1235, 1.1235, ..., 1.1235,"
        " 1.1235, 1.1235]], dtype=f32, shape=[20])"
        in captured.out
    )


def test_debug_print_full(compiled_model, session, capfd):
    session.set_debug_print_options("FULL", 2)
    _ = compiled_model.execute(
        Tensor.from_numpy(np.full([20], 1.1234567, np.float32))
    )
    captured = capfd.readouterr()
    assert (
        "test_x_value = tensor<20xf32> [1.12e+00, 1.12e+00, 1.12e+00,"
        " 1.12e+00, 1.12e+00, 1.12e+00, 1.12e+00, 1.12e+00, 1.12e+00, 1.12e+00,"
        " 1.12e+00, 1.12e+00, 1.12e+00, 1.12e+00, 1.12e+00, 1.12e+00, 1.12e+00,"
        " 1.12e+00, 1.12e+00, 1.12e+00]"
        in captured.out
    )

    session.set_debug_print_options("FULL", 6)
    _ = compiled_model.execute(
        Tensor.from_numpy(np.full([20], 1.1234567, np.float32))
    )
    captured = capfd.readouterr()
    assert (
        "test_x_value = tensor<20xf32> [1.123457e+00, 1.123457e+00,"
        " 1.123457e+00, 1.123457e+00, 1.123457e+00, 1.123457e+00, 1.123457e+00,"
        " 1.123457e+00, 1.123457e+00, 1.123457e+00, 1.123457e+00, 1.123457e+00,"
        " 1.123457e+00, 1.123457e+00, 1.123457e+00, 1.123457e+00, 1.123457e+00,"
        " 1.123457e+00, 1.123457e+00, 1.123457e+00]"
        in captured.out
    )


def test_debug_print_none(compiled_model, session, capfd):
    session.set_debug_print_options("NONE")
    _ = compiled_model.execute(
        Tensor.from_numpy(np.full([20], 1.1234567, np.float32))
    )
    captured = capfd.readouterr()
    assert "test_x_value" not in captured.out


def test_debug_print_binary(compiled_model, session, capfd, tmp_path):
    session.set_debug_print_options("BINARY", output_directory=tmp_path)
    input = np.full([20], 1.1234567, np.float32)
    _ = compiled_model.execute(Tensor.from_numpy(input))
    captured = capfd.readouterr()
    assert "test_x_value" not in captured.out
    assert (tmp_path / "test_x_value").exists()
    from_file = np.fromfile(tmp_path / "test_x_value", np.float32)
    assert (input == from_file).all()


def test_debug_print_binary_max(compiled_model, session, capfd, tmp_path):
    session.set_debug_print_options(
        "BINARY_MAX_CHECKPOINT", output_directory=tmp_path
    )
    input = np.random.uniform(size=[15]).astype(np.float32)
    _ = compiled_model.execute(Tensor.from_numpy(input))
    captured = capfd.readouterr()
    assert "test_x_value" not in captured.out

    max_path = tmp_path / "test_x_value.max"
    assert max_path.exists()
    from_file = load_max_tensor(max_path).to_numpy()
    assert (input == from_file).all()


@pytest.mark.skipif(
    platform.machine() in ["arm64", "aarch64"],
    reason="BF16 is not supported on ARM CPU architecture",
)
def test_debug_print_binary_max_bf16(session, capfd, tmp_path):
    def print_input(x):
        x.print("test_x_value")
        return x

    g = Graph("test_print", print_input, [TensorType(DType.bfloat16, ["dim1"])])
    compiled_model = session.load(g)

    session.set_debug_print_options(
        "BINARY_MAX_CHECKPOINT", output_directory=tmp_path
    )
    dim = 15
    input = Tensor([dim], DType.bfloat16)
    for i in range(dim):
        input[i] = np.random.uniform()

    _ = compiled_model.execute(input)
    captured = capfd.readouterr()
    assert "test_x_value" not in captured.out

    max_path = tmp_path / "test_x_value.max"
    assert max_path.exists()
    from_file = load_max_tensor(max_path)

    for i in range(dim):
        assert from_file[i].item() == input[i].item()
