# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

import numpy as np
import pytest
import torch
from max.dtype import DType
from max.graph import Graph, TensorType, ops


@pytest.mark.parametrize(
    "input,repeats", [([1, 2, 3], 2), ([[1, 2], [3, 4]], 3)]
)
def test_repeat_interleave(
    session,
    input: TensorType,
    repeats: int,
):
    with Graph(
        "repeat_interleave",
        input_types=[],
    ) as graph:
        x = ops.constant(np.array(input), DType.int64)

        output = ops.repeat_interleave(x, repeats)
        graph.output(output)

    expected = (
        torch.repeat_interleave(torch.tensor(input), repeats).detach().numpy()
    )

    model = session.load(graph)
    result = model.execute()[0]

    np.testing.assert_equal(result.to_numpy(), expected)
