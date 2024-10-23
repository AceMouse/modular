# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
from typing import Tuple

import numpy as np
import pytest
import torch
import torch.nn.functional as F
from max.dtype import DType
from max.graph import Graph, TensorType, TensorValue
from max.graph.ops import constant, conv2d
from modular_graph_test import modular_graph_test


def torch_conv2d(
    x: TensorValue,
    filter: TensorValue,
    stride: Tuple[int, int] = (1, 1),
    dilation: Tuple[int, int] = (1, 1),
    padding: Tuple[int, int] = (0, 0),
    groups: int = 1,
):
    x = torch.permute(x, (0, 3, 1, 2))
    filter = torch.permute(filter, (3, 2, 0, 1))
    out = F.conv2d(
        x,
        filter,
        stride=stride,
        padding=padding,
        dilation=dilation,
        groups=groups,
    )
    return torch.permute(out, (0, 2, 3, 1))


# TODO(KERN-1066): Fix and enable test
@pytest.mark.skip(reason="Errors are larger than usual (10^-2)")
@pytest.mark.parametrize(
    "input_type, filter_type",
    [
        (
            TensorType(DType.float32, [1, 16, 16, 4]),
            TensorType(DType.float32, [16, 16, 4, 5]),
        ),
    ],
)
def test_conv2d(session, input_type: TensorType, filter_type: TensorType):
    with Graph("conv2d", input_types=[input_type, filter_type]) as graph:
        x, filter = graph.inputs
        stride = (16, 16)
        padding = (0, 0)
        dilation = (1, 1)

        conv = conv2d(x, filter, stride, dilation, (0, 0, 0, 0))
        graph.output(conv)

        @modular_graph_test(session, graph)
        def test_correctness(execute, inputs, torch_inputs):
            result = execute(inputs)
            x, w = torch_inputs
            expected = (
                torch_conv2d(x, w, stride, dilation, padding).detach().numpy()
            )
            ACCURACY_RTOL = 1e-4
            ACCURACY_ATOL = 1e-6
            np.testing.assert_allclose(
                result,
                expected,
                equal_nan=True,
                rtol=ACCURACY_RTOL,
                atol=ACCURACY_ATOL,
            )
