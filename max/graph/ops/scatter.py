# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Op implementation for scatter."""

from functools import reduce
from operator import mul

from max.dtype import DType
from max.mlir.dialects import rmo

from .. import dtype_promotion
from ..graph import Graph
from ..type import TensorType
from ..value import TensorValue, TensorValueLike
from .nonzero import nonzero


def masked_scatter(
    input: TensorValueLike, mask: TensorValueLike, updates: TensorValueLike
) -> TensorValue:
    """
    Creates a new symbolic tensor where the updates are written to input where mask is true.

    Args:
        input: The input symbolic tensor to write elements to.
        mask: A symbolic tensor of boolean values to update.
        updates: A symbolic tensor of elements to write to input.

    Returns:
        A new symbolic tensor representing the result of the masked_scatter operation.
    """
    input, updates = TensorValue(input), TensorValue(updates)
    mask = dtype_promotion._promote_to_strong(mask, DType.bool)

    if input.dtype != updates.dtype:
        raise ValueError(
            f"The input dtype ({input.dtype}) and updates dtype"
            f" ({updates.dtype}) must match"
        )

    input_size = reduce(mul, input.shape, 1)
    updates_size = reduce(mul, updates.shape, 1)
    # TODO: This is a bug. They don't have to match.
    # Assuming it will throw a run-time error if updates_size != non-zeros in mask
    # if input_size != updates_size and updates_size != 1:
    #    raise ValueError(
    #        f"The number of elements in the input ({input_size}) and the number"
    #        f" of elements in updates ({updates_size}) must match"
    #    )

    mask = mask.broadcast_to(input.shape)
    indices = nonzero(
        mask, Graph.current.unique_symbolic_dim("nonzero_indices")
    )

    updates = updates.flatten()

    return Graph.current._add_op(
        rmo.mo_scatter_nd,
        TensorType(input.dtype, input.shape, input.device).to_mlir(),
        input,
        updates,
        indices,
    )[0].tensor
