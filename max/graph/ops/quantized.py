# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Optimized quantized operations."""

from typing import Callable, Dict

from max.dtype import DType

from ..graph import Graph
from ..graph_value import GraphValue
from ..quantization import QuantizationEncoding
from ..type import Dim, StaticDim, TensorType

from .custom import custom


def _repack_quantized_weights(op_name: str, rhs: GraphValue) -> GraphValue:
    rhs_type = rhs.tensor_type
    return custom(
        op_name,
        [rhs],
        out_types=[
            TensorType(
                DType.uint8, (rhs_type.shape[0], rhs_type.shape[1])
            ).to_mlir()
        ],
    )[0]


def _packed_qmatmul(
    op_name: str, lhs_matrix: GraphValue, rhs_repack: GraphValue
) -> GraphValue:
    return custom(
        op_name,
        [lhs_matrix, rhs_repack],
        out_types=[
            TensorType(
                DType.float32, (lhs_matrix.shape[0], rhs_repack.shape[0])
            ).to_mlir(),
        ],
    )[0]


def _repack_then_matmul(
    repack_op_name: str, matmul_op_name: str
) -> Callable[[GraphValue, GraphValue], GraphValue]:
    def impl(lhs: GraphValue, rhs: GraphValue) -> GraphValue:
        # Quantized matmul for supported quantized encoding types.
        # rhs is uint8 and in a packed format such as Q4_0, Q4_K, or Q6_K.
        if rhs.dtype is not DType.uint8:
            raise TypeError(f"Right-hand side must be uint8, but got {rhs=}")
        if lhs.dtype is not DType.float32:
            raise TypeError(f"Left-hand side must be float32, but got {lhs=}")

        if len(rhs.shape) != 2:
            raise TypeError(f"Right-hand side must be a matrix, but got {rhs=}")

        # Reshape LHS to a matrix, which is expected by the q4_0 matmul op.
        lhs_matrix = lhs.reshape((-1, lhs.shape[-1]))
        # Rebinding here breaks the reshape later, see GRA-881.
        # Fortunately things work without the rebind.
        # prod_dim = Graph.current.unique_symbolic_dim("qmatmul")
        # lhs_matrix = lhs_matrix.rebind((prod_dim, lhs.shape[-1]))

        # Prepack weights.
        rhs_repack = _repack_quantized_weights(repack_op_name, rhs)

        # Perform quantized matmul.
        qmatmul_out = _packed_qmatmul(matmul_op_name, lhs_matrix, rhs_repack)

        # Reshape matmul output to restore the original rank(lhs) - 1 dimensions.
        return qmatmul_out.reshape((*lhs.shape[:-1], rhs.shape[0]))

    return impl


# We do not know for sure that all future quantization encodings will best be
# served by the "repack and then matmul" scheme, so this design lets us better
# support future alternative schemes while continuing to support the current
# scheme.
_QMATMUL_STRATEGIES: Dict[
    QuantizationEncoding, Callable[[GraphValue, GraphValue], GraphValue]
] = {
    QuantizationEncoding.Q4_0: _repack_then_matmul(
        "vroom_q4_0_repack_weights", "vroom_q4_0_matmul"
    ),
    QuantizationEncoding.Q4_K: _repack_then_matmul(
        "vroom_q4_k_repack_weights", "vroom_q4_k_matmul"
    ),
    QuantizationEncoding.Q6_K: _repack_then_matmul(
        "vroom_q6_k_repack_weights", "vroom_q6_k_matmul"
    ),
}


def qmatmul(
    encoding: QuantizationEncoding, lhs: GraphValue, rhs: GraphValue
) -> GraphValue:
    """Performs matrix multiplication between floating point and quantized
    tensors.

    This quantizes the `lhs` floating point value to match the encoding of the
    `rhs` quantized value, performs matmul, and then dequantizes the result.
    Beware that, compared to a regular matmul op, this one expects the `rhs`
    value to be transposed. For example, if the `lhs` shape is `[32, 64]`, and
    the quantized `rhs` shape is also `[32, 64]`, then the output shape is
    `[32, 32]`

    That is, this function returns the result from:

        dequantize(quantize(lhs) @ transpose(rhs))

    The last two dimensions in `lhs` are treated as matrices and multiplied
    by `rhs` (which must be a 2D tensor). Any remaining dimensions in `lhs`
    are broadcast dimensions.

    NOTE: Currently this supports Q4_0, Q4_K, and Q6_K encodings only.

    Args:
        encoding: The quantization encoding to use.
        lhs: The non-quantized, left-hand-side of the matmul.
        rhs: The transposed and quantized right-hand-side of the matmul.
             Must be rank 2 (a 2D tensor/matrix) and in a supported
             [quantization encoding](/max/api/mojo/graph/quantization/).

    Returns:
        The dequantized result (a floating point tensor).
    """
    strategy = _QMATMUL_STRATEGIES.get(encoding)
    if strategy is None:
        raise ValueError(f"unsupported quantization encoding {encoding}")
    return strategy(lhs, rhs)


_DEQUANTIZE_OP_NAMES: Dict[QuantizationEncoding, str] = {
    QuantizationEncoding.Q4_0: "ggml_q4_0_dequantize",
    QuantizationEncoding.Q4_K: "ggml_q4_k_dequantize",
    QuantizationEncoding.Q6_K: "ggml_q6_k_dequantize",
}


def dequantize(
    encoding: QuantizationEncoding, quantized: GraphValue
) -> GraphValue:
    """Dequantizes a quantized tensor to floating point.

    NOTE: Currently this supports Q4_0, Q4_K, and Q6_K encodings only.

    Args:
        encoding: The quantization encoding to use.
        quantized: The quantized tensor to dequantize.

    Returns:
        The dequantized result (a floating point tensor).
    """
    op_name = _DEQUANTIZE_OP_NAMES.get(encoding)
    if op_name is None:
        raise ValueError(f"unsupported quantization encoding {encoding}")
    *dims, qdim = quantized.shape
    if not isinstance(qdim, StaticDim):
        raise TypeError("dequantize only supported with static last dimension")
    if qdim.dim % encoding.block_size != 0:
        raise ValueError(
            f"last dimension ({qdim}) not divisible by block size "
            f"({encoding.block_size})"
        )
    odim = StaticDim(
        (qdim.dim // encoding.block_size) * encoding.elements_per_block
    )
    flat_quantized = quantized.reshape([-1, qdim])
    flat_dequantized = custom(
        name=op_name,
        values=[flat_quantized],
        out_types=[
            TensorType(DType.float32, [flat_quantized.shape[0], odim]).to_mlir()
        ],
    )[0]
    return flat_dequantized.reshape([*dims, odim])
