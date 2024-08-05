# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Test the Python weight loading interface."""
from tempfile import NamedTemporaryFile

import max.engine as me
import numpy as np
import pytest
import torch
from max.graph import DType, Graph
from max.graph.utils import load_gguf, load_pytorch


def test_weight() -> None:
    """Tests adding an external weight to a graph."""
    session = me.InferenceSession()
    with Graph("graph_with_weights") as graph:
        weight_shape = [5, 10]
        weight = np.random.uniform(1, 100, size=weight_shape).astype(np.int64)
        with NamedTemporaryFile() as f:
            weight.tofile(f.name)
            w = graph.add_weight(
                "random_weight",
                dtype=DType.int64,
                shape=weight_shape,
                filepath=f.name,
            )
            graph.output(w.value)
            compiled = session.load(graph)
            output = compiled.execute()

            np.testing.assert_array_equal(weight, output["output0"])


def test_weight_offset() -> None:
    """Tests adding an external weight to a graph."""
    session = me.InferenceSession()
    with Graph("graph_with_offset_weights") as graph:
        weight_shape = [5, 10]
        weight = np.random.uniform(1, 100, size=weight_shape).astype(np.int64)
        with NamedTemporaryFile("wb") as f:
            f.write(b"abcde")  # Add fake offset.
            f.write(weight.tobytes())
            f.flush()

            w = graph.add_weight(
                "random_weight",
                dtype=DType.int64,
                shape=weight_shape,
                filepath=f.name,
                offset=5,
            )
            graph.output(w.value)
            compiled = session.load(graph)
            output = compiled.execute()

            np.testing.assert_array_equal(weight, output["output0"])


def _test_data():
    return {
        "a": np.arange(10, dtype=np.int32).reshape(5, 2),
        "b": np.full((1, 2, 3), 3.5, dtype=np.float64),
        "c": np.array(5432.1, dtype=np.float32),
        "fancy/name": np.array([1, 2, 3], dtype=np.int64),
        # This is actually saved as bf16 in gen_external_checkpoints.
        "bf16": np.array([123, 45], dtype=np.float16),
    }


def test_load_pytorch(graph_testdata) -> None:
    """Tests adding an external weight to a graph."""
    session = me.InferenceSession()
    expected_dict = _test_data()
    flat_keys = list(expected_dict.keys())
    expected = [expected_dict[k] for k in flat_keys]

    with Graph("graph_with_pt_weights") as graph:
        loaded = load_pytorch(graph_testdata / "example_data.pt")
        graph.output(*[loaded[k].value for k in flat_keys])
        compiled = session.load(graph)
        output = compiled.execute()

        assert len(expected) == len(output)
        for n, expected in enumerate(expected):
            # TODO(MSDK-732): Skip bfloat16 weight for now, since np doesn't
            # support it.
            if flat_keys[n] == "bf16":
                continue
            np.testing.assert_array_equal(expected, output[f"output{n}"])


def test_load_gguf(graph_testdata) -> None:
    """Tests adding an external weight to a graph."""
    session = me.InferenceSession()
    expected_dict = _test_data()
    flat_keys = list(expected_dict.keys())
    expected = [expected_dict[k] for k in flat_keys]

    with Graph("graph_with_gguf_weights") as graph:
        loaded = load_gguf(graph_testdata / "example_data.gguf")
        graph.output(*[loaded[k].value for k in flat_keys])
        compiled = session.load(graph)
        output = compiled.execute()

        assert len(expected) == len(output)
        for n, expected in enumerate(expected):
            # TODO(MSDK-732): Skip bfloat16 weight for now, since np doesn't
            # support it.
            if flat_keys[n] == "bf16":
                continue
            np.testing.assert_array_equal(expected, output[f"output{n}"])
