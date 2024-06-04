# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
from buffer import DimList, NDBuffer
from gpu.cublas.cublas import (
    ComputeType,
    _convert_to_cublas_datatype,
    _convert_to_cublas_transpose,
    cublasContext,
    cublasGemmAlgo_t,
    cublasGemmEx,
)
from gpu.cublas.dtype import DataType
from gpu.cublas.result import Result


fn cublas_matmul(
    handle: Pointer[cublasContext],
    c: NDBuffer[_, 2, _],
    a: NDBuffer[_, 2, _],
    b: NDBuffer[_, 2, _],
    c_row_major: Bool = False,
    transpose_a: Bool = False,
    transpose_b: Bool = False,
) -> Result:
    constrained[
        a.type == b.type
        and (a.type == DType.float32 or a.type.is_half_float()),
        (
            "Only support FP32, FP16 and BF16 for cublas wrapper. Please extend"
            " it if more types are needed."
        ),
    ]()

    var M = c.dim[0]()
    var N = c.dim[1]()
    var K = a.dim[1]() if not transpose_a else a.dim[0]()

    var alpha = Scalar[DType.float32](1.0)
    var beta = Scalar[DType.float32](0.0)

    # Cublas is by default column-major but we like to have the output in row-major
    # to compare with our results. To do this without an explicit transpose, we
    # can swap A, B and output a NxM column-major matrix, which is same as
    # MxN row-major i.e.
    #
    #      C: MxN_row_major = A: MxK_row_major @ B: KxN_row_major
    #   => C: NxM_col_major = B: NxK_col_major @ A: KxM_col_major
    #
    # I haven't seen any significant performance difference before and after this
    # transformation. To be rigorous though, we should set `c_is_row_major = True`
    # for accuracy validations and uses default column-major in benchmark.

    if c_row_major:
        return cublasGemmEx(
            handle,
            _convert_to_cublas_transpose(transpose_b),
            _convert_to_cublas_transpose(transpose_a),
            N,
            M,
            K,
            Pointer.address_of(alpha).bitcast[NoneType](),
            b.data.address.bitcast[NoneType](),
            _convert_to_cublas_datatype[b.type](),
            N,
            a.data.address.bitcast[NoneType](),
            _convert_to_cublas_datatype[a.type](),
            K,
            Pointer.address_of(beta).bitcast[NoneType](),
            c.data.address.bitcast[NoneType](),
            _convert_to_cublas_datatype[c.type](),
            N,
            ComputeType.COMPUTE_32F,
            cublasGemmAlgo_t.CUBLAS_GEMM_DEFAULT,
        )
    # Default column-major.
    else:
        return cublasGemmEx(
            handle,
            _convert_to_cublas_transpose(transpose_a),
            _convert_to_cublas_transpose(transpose_b),
            M,
            N,
            K,
            Pointer.address_of(alpha).bitcast[NoneType](),
            a.data.address.bitcast[NoneType](),
            _convert_to_cublas_datatype[a.type](),
            M,
            b.data.address.bitcast[NoneType](),
            _convert_to_cublas_datatype[b.type](),
            K,
            Pointer.address_of(beta).bitcast[NoneType](),
            c.data.address.bitcast[NoneType](),
            _convert_to_cublas_datatype[c.type](),
            M,
            ComputeType.COMPUTE_32F,
            cublasGemmAlgo_t.CUBLAS_GEMM_DEFAULT,
        )
