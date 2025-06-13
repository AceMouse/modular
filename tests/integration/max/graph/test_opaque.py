# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

import os
from pathlib import Path

import pytest
from max.driver import Tensor
from max.dtype import DType
from max.engine.api import InferenceSession, Model
from max.graph import DeviceRef, Graph, TensorType, _OpaqueType, ops


@pytest.fixture
def counter_ops_path() -> Path:
    return Path(os.environ["MODULAR_COUNTER_OPS_PATH"])


@pytest.fixture
def maker_model(session: InferenceSession, counter_ops_path: Path) -> Model:
    counter_type = _OpaqueType("Counter")
    maker_graph = Graph(
        "maker",
        input_types=[],
        output_types=[counter_type],
        custom_extensions=[counter_ops_path],
    )
    with maker_graph:
        maker_graph.output(
            ops.custom(
                "make_counter",
                device=DeviceRef.CPU(),
                values=[],
                out_types=[counter_type],
                parameters={"stride": 1},
            )[0]
        )
    maker_compiled = session.load(maker_graph)
    return maker_compiled


@pytest.fixture
def bumper_model(session: InferenceSession, counter_ops_path: Path) -> Model:
    counter_type = _OpaqueType("Counter")
    bumper_graph = Graph(
        "bumper",
        input_types=[counter_type],
        output_types=[],
        custom_extensions=[counter_ops_path],
    )
    with bumper_graph:
        ops.inplace_custom(
            "bump_counter",
            device=DeviceRef.CPU(),
            values=[bumper_graph.inputs[0]],
            out_types=[],
            parameters={"stride": 1},
        )
        bumper_graph.output()
    bumper_compiled = session.load(bumper_graph)
    return bumper_compiled


@pytest.fixture
def reader_model(session: InferenceSession, counter_ops_path: Path) -> Model:
    counter_type = _OpaqueType("Counter")
    reader_graph = Graph(
        "reader",
        input_types=[counter_type],
        output_types=[],
        custom_extensions=[counter_ops_path],
    )
    with reader_graph:
        c = ops.inplace_custom(
            "read_counter",
            device=DeviceRef.CPU(),
            values=[reader_graph.inputs[0]],
            out_types=[TensorType(DType.int32, [2], device=DeviceRef.CPU())],
            parameters={"stride": 1},
        )
        reader_graph.output(c[0])
    reader_compiled = session.load(reader_graph)
    return reader_compiled


def test_opaque_simple(
    maker_model: Model, bumper_model: Model, reader_model: Model
) -> None:
    counter = maker_model.execute()[0]
    for _ in range(5):
        bumper_model.execute(counter)
    x = reader_model.execute(counter)[0]
    assert isinstance(x, Tensor)
    result = x.to_numpy()

    assert (result == [5, 15]).all()


class PythonCounter:
    def __init__(self, a=0, b=0):
        self.a = a
        self.b = b

    def bump(self):
        self.a += 1
        self.b += self.a

    def copy(self):
        return PythonCounter(self.a, self.b)


def test_pyobject_opaque(
    session: InferenceSession, counter_ops_path: Path
) -> None:
    python_type = _OpaqueType("PythonObject")

    bumper_graph = Graph(
        "bumper",
        input_types=[python_type],
        output_types=[python_type],
        custom_extensions=[counter_ops_path],
    )
    with bumper_graph:
        x = ops.inplace_custom(
            "bump_python_counter",
            device=DeviceRef.CPU(),
            values=[bumper_graph.inputs[0]],
            out_types=[python_type],
        )[0]
        y = ops.inplace_custom(
            "bump_python_counter",
            device=DeviceRef.CPU(),
            values=[x],
            out_types=[python_type],
        )[0]
        bumper_graph.output(y)
    bumper_compiled = session.load(bumper_graph)

    counter = PythonCounter()
    for _ in range(5):
        counter = bumper_compiled.execute(counter)[0]  # type: ignore
    assert counter.a == 10 and counter.b == 55
