# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from dataclasses import dataclass

import numpy as np
import pytest
import torch
from conftest import modular_graph_test
from hypothesis import assume
from max.dtype import DType
from max.graph import Dim, Graph, TensorType, TensorValue, TensorValueLike
from nn import RotaryEmbedding

MAX_SEQ_LEN = 2**16
ACCURACY_RTOL = 1e-2
ACCURACY_ATOL = 1e-7


def torch_freqs_cis(dim: int, theta: float, scaling: float):
    freqs = 1.0 / (
        theta ** (torch.arange(0, dim, 2)[: (dim // 2)].float() * scaling / dim)
    )
    t = torch.arange(
        MAX_SEQ_LEN * 2.0, device=freqs.device, dtype=torch.float32
    )
    freqs = torch.outer(t, freqs)
    freqs_cis = torch.polar(torch.ones_like(freqs), freqs)  # complex64
    return freqs_cis


@dataclass
class RopeParams:
    dim: int
    n_heads: int
    theta: float
    scaling: float

    @property
    def head_dim(self):
        return self.dim // self.n_heads


@pytest.mark.parametrize(
    "params",
    [
        RopeParams(dim=64, n_heads=4, theta=1e4, scaling=1.0),
        RopeParams(dim=512, n_heads=16, theta=5e5, scaling=0.1),
    ],
)
@pytest.mark.parametrize("dtype", [DType.float32])
def test_freqs_cis(session, dtype: DType, params: RopeParams):
    with Graph("freqs_cis", input_types=[]) as graph:
        rope = RotaryEmbedding(
            params.dim,
            params.n_heads,
            params.theta,
            MAX_SEQ_LEN,
            np.array([params.scaling], dtype=dtype.to_numpy()),
        )
        graph.output(rope.freqs_cis)
        model = session.load(graph)
    result = model.execute_legacy()["output0"]
    # freq_cis result is stacked along a new dimension - real goes first, then imaginary.
    # The result is a tensor with shape (..., 2) where the last dimension holds [real, imaginary]
    # We extract and convert into a complex tensor type before comparing them.
    result_cis_complex = result[:, :, 0] + 1j * result[:, :, 1]
    expected = torch_freqs_cis(params.head_dim, params.theta, params.scaling)
    # TODO(MSDK-1071): Consolidate and figure out how to call
    # assert_allclose(result, expected) to fire again on mismatched
    # tensor values.
    np.testing.assert_allclose(
        result_cis_complex,
        expected,
        atol=ACCURACY_ATOL,
        rtol=ACCURACY_RTOL,
        equal_nan=True,
    )


class CannedRotaryEmbedding(RotaryEmbedding):
    def __init__(self, freqs_cis: TensorValueLike):
        self._freqs_cis = freqs_cis


def torch_rope(x, freqs_cis, cache):
    start_pos = cache.shape[0]
    seq_len = x.shape[1]
    freqs_cis = freqs_cis[start_pos : start_pos + seq_len]
    freqs_cis = torch.view_as_complex(freqs_cis.reshape(seq_len, -1, 2))
    return apply_rotary_emb(x, freqs_cis)


def _reshape_for_broadcast(freqs_cis: torch.Tensor, x: torch.Tensor):
    ndim = x.ndim
    assert 1 < ndim
    assert freqs_cis.shape == (x.shape[1], x.shape[-1])
    shape = [d if i == 1 or i == ndim - 1 else 1 for i, d in enumerate(x.shape)]
    return freqs_cis.view(*shape)


def apply_rotary_emb(x: torch.Tensor, freqs_cis: torch.Tensor) -> torch.Tensor:
    x_ = torch.view_as_complex(x.float().reshape(*x.shape[:-1], -1, 2))
    freqs_cis = _reshape_for_broadcast(freqs_cis, x_)
    return torch.view_as_real(x_ * freqs_cis).flatten(3).type_as(x)


@pytest.mark.parametrize(
    "input_type",
    [TensorType(DType.float32, ["batch", "seqlen", "n_kv_heads", 32])],
)
@pytest.mark.parametrize("start_pos", [0, 15])
def test_rope(session, input_type: TensorType, start_pos: Dim):
    _, seqlen, _, head_dim = input_type.shape
    freqs_cis_type = TensorType(input_type.dtype, [MAX_SEQ_LEN, head_dim])
    cachelike = TensorType(DType.int64, [start_pos])
    with Graph(
        "rope", input_types=[input_type, freqs_cis_type, cachelike]
    ) as graph:
        x, freqs_cis, cache = graph.inputs
        freqs_cis = freqs_cis.reshape((MAX_SEQ_LEN, -1, 2))  # as complex
        start_pos = TensorValue(cache.shape[0])
        seq_len = x.shape[1]
        rope = CannedRotaryEmbedding(freqs_cis)
        graph.output(rope(x, start_pos, seq_len))

        @modular_graph_test(session, graph, max_magnitude=1.0)
        def test_correctness(execute, inputs, torch_inputs):
            x, freqs_cis, cache = inputs
            start_pos = cache.shape[0]
            seq_len = x.shape[1]
            assume(start_pos + seq_len < MAX_SEQ_LEN)
            result = execute(inputs)
            expected = torch_rope(*torch_inputs).detach().numpy()

            # TODO(MSDK-1071): Consolidate and figure out how to call
            # assert_allclose(result, expected) to fire again on mismatched
            # tensor values.
            np.testing.assert_allclose(
                result,
                expected,
                atol=ACCURACY_ATOL,
                rtol=ACCURACY_RTOL,
                equal_nan=True,
            )
