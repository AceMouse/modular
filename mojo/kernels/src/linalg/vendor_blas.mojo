# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
from sys import sizeof, has_amd_gpu_accelerator, has_nvidia_gpu_accelerator

from buffer import DimList, NDBuffer
from gpu.cublas.cublas import (
    Algorithm,
    ComputeType,
    _convert_to_cublas_datatype,
    _convert_to_cublas_transpose,
    check_cublas_error,
    cublasContext,
    cublasGemmEx,
    cublasOperation_t,
    cublasCreate,
    cublasDestroy,
)
from gpu.cublas.cublaslt import (
    Context,
    MatmulAlgorithm,
    Preference,
    cublasLtCreate,
    cublasLtDestroy,
    cublasLtGetVersion,
    cublasLtMatmul,
    cublasLtMatmulAlgoGetHeuristic,
    cublasLtMatmulAlgoInit,
    cublasLtMatmulDesc_t,
    cublasLtMatmulDescAttributes_t,
    cublasLtMatmulDescCreate,
    cublasLtMatmulDescDestroy,
    cublasLtMatmulDescSetAttribute,
    cublasLtMatmulHeuristicResult_t,
    cublasLtMatmulPreference_t,
    cublasLtMatmulPreferenceCreate,
    cublasLtMatmulPreferenceDestroy,
    cublasLtMatmulPreferenceSetAttribute,
    cublasLtMatrixLayout_t,
    cublasLtMatrixLayoutCreate,
    cublasLtMatrixLayoutDestroy,
)
from gpu.cublas.dtype import DataType
from gpu.cublas.result import Result
from gpu.host import DeviceContext
from gpu.host.nvidia_cuda import CUDA
from layout import Layout
from memory import UnsafePointer
from utils.variant import Variant
import gpu.rocblas
from os import abort

# ===----------------------------------------------------------------------===#
# Backend
# ===----------------------------------------------------------------------===#


@value
@register_passable("trivial")
struct Backend:
    var _value: Int32

    alias AUTOMATIC = Self(0)
    alias CUBLAS = Self(1)
    alias CUBLASLT = Self(2)
    alias ROCBLAS = Self(3)

    @implicit
    fn __init__(out self, value: Int):
        self._value = value

    fn __is__(self, other: Self) -> Bool:
        return self == other

    fn __isnot__(self, other: Self) -> Bool:
        return self != other

    fn __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    fn __ne__(self, other: Self) -> Bool:
        return not (self == other)

    fn __int__(self) -> Int:
        return Int(self._value)

    fn __str__(self) -> String:
        return String.write(self)

    fn write_to[W: Writer](self, mut writer: W):
        if self is Self.AUTOMATIC:
            return writer.write("AUTOMATIC")
        if self is Self.CUBLAS:
            return writer.write("CUBLAS")
        if self is Self.CUBLASLT:
            return writer.write("CUBLASLT")
        writer.write("ROCBLAS")


fn _resolve_backend[backend: Backend, type: DType = DType.invalid]() -> Backend:
    @parameter
    if backend is not Backend.AUTOMATIC:
        return backend
    elif has_amd_gpu_accelerator():
        return Backend.ROCBLAS
    elif type.is_float8():
        return Backend.CUBLASLT
    return Backend.CUBLAS


# ===----------------------------------------------------------------------===#
# Handle
# ===----------------------------------------------------------------------===#


@value
struct Handle[backend: Backend = _resolve_backend[Backend.AUTOMATIC]()]:
    alias resolved_backend = _resolve_backend[backend]()
    alias _cublas_type = UnsafePointer[cublasContext]
    alias _cublaslt_type = UnsafePointer[Context]
    alias _rocblas_type = rocblas.Handle
    alias type = Variant[
        Self._cublas_type, Self._cublaslt_type, Self._rocblas_type
    ]
    var _handle: Self.type

    fn __init__(out self) raises:
        @parameter
        if Self.resolved_backend is Backend.CUBLAS:
            var handle = Self._cublas_type()
            check_cublas_error(cublasCreate(UnsafePointer.address_of(handle)))
            self._handle = handle
        elif Self.resolved_backend is Backend.CUBLASLT:
            var handle = Self._cublaslt_type()
            check_cublas_error(cublasLtCreate(UnsafePointer.address_of(handle)))
            self._handle = handle
        elif Self.resolved_backend is Backend.ROCBLAS:
            var handle = Self._rocblas_type()
            rocblas.check_error(
                rocblas.rocblas.rocblas_create_handle(
                    UnsafePointer.address_of(handle)
                )
            )
            self._handle = handle
        else:
            raise Error(
                "the backend '",
                backend,
                "' is not currently supported",
            )

    @always_inline
    fn __enter__(self) -> Self:
        return self

    @always_inline
    fn __exit__(mut self) raises:
        @parameter
        if Self.resolved_backend is Backend.CUBLAS:
            check_cublas_error(cublasDestroy(self._get_cublas()))
            self._handle = Self._cublas_type()
            return
        elif Self.resolved_backend is Backend.CUBLASLT:
            check_cublas_error(cublasLtDestroy(self._get_cublaslt()))
            self._handle = Self._cublaslt_type()
            return
        elif Self.resolved_backend is Backend.ROCBLAS:
            rocblas.check_error(
                rocblas.rocblas.rocblas_destroy_handle(self._get_rocblas())
            )
            self._handle = Self._rocblas_type()
            return

        raise Error("the backend is not currently supported")

    fn _is_null(self) -> Bool:
        @parameter
        if Self.resolved_backend is Backend.CUBLAS:
            return self._get_cublas() == Self._cublas_type()
        elif Self.resolved_backend is Backend.CUBLASLT:
            return self._get_cublaslt() == Self._cublaslt_type()
        elif Self.resolved_backend is Backend.ROCBLAS:
            return self._get_rocblas() == Self._rocblas_type()

        return False

    fn _get_cublas(self) -> Self._cublas_type:
        constrained[
            Self.resolved_backend is Backend.CUBLAS, "backend must be CUBLAS"
        ]()
        return self._handle[Self._cublas_type]

    fn _get_cublaslt(self) -> Self._cublas_type:
        constrained[
            Self.resolved_backend is Backend.CUBLASLT,
            "backend must be CUBLASLT",
        ]()
        return self._handle[Self._cublaslt_type]

    fn _get_rocblas(self) -> Self._rocblas_type:
        constrained[
            Self.resolved_backend is Backend.ROCBLAS, "backend must be ROCBLAS"
        ]()
        return self._handle[Self._rocblas_type]

    fn __is__(self, other: Backend) -> Bool:
        return Self.resolved_backend is other

    fn __isnot__(self, other: Backend) -> Bool:
        return Self.resolved_backend is not other


# ===----------------------------------------------------------------------===#
# Matmul
# ===----------------------------------------------------------------------===#


fn matmul[
    use_tf32: Bool = False
](
    ctx: DeviceContext,
    handle: Handle,
    c: NDBuffer[_, 2, _],
    a: NDBuffer[_, 2, _],
    b: NDBuffer[_, 2, _],
    *,
    c_row_major: Bool = False,
    transpose_a: Bool = False,
    transpose_b: Bool = False,
) raises:
    @parameter
    if handle.resolved_backend is Backend.CUBLAS:
        _cublas_matmul[use_tf32=use_tf32](
            ctx,
            handle._get_cublas(),
            c,
            a,
            b,
            c_row_major=c_row_major,
            transpose_a=transpose_a,
            transpose_b=transpose_b,
        )
    elif handle.resolved_backend is Backend.ROCBLAS:
        _rocblas_matmul[use_tf32=use_tf32](
            ctx,
            handle._get_rocblas(),
            c,
            a,
            b,
            c_row_major=c_row_major,
            transpose_a=transpose_a,
            transpose_b=transpose_b,
        )
    elif handle.resolved_backend is Backend.CUBLASLT:
        _cublasLt_matmul(
            ctx,
            handle._get_cublaslt(),
            c,
            a,
            b,
            c_row_major=c_row_major,
            transpose_a=transpose_a,
            transpose_b=transpose_b,
        )
    else:
        raise String(
            "the backend '",
            handle.backend,
            "' is not currently supported",
        )


# ===----------------------------------------------------------------------===#
# CUBLAS
# ===----------------------------------------------------------------------===#


fn _cublas_matmul[
    use_tf32: Bool = False,
](
    ctx: DeviceContext,
    handle: UnsafePointer[cublasContext],
    c: NDBuffer[_, 2, _],
    a: NDBuffer[_, 2, _],
    b: NDBuffer[_, 2, _],
    *,
    c_row_major: Bool = False,
    transpose_a: Bool = False,
    transpose_b: Bool = False,
) raises:
    constrained[
        a.type == b.type
        and (a.type is DType.float32 or a.type.is_half_float()),
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

    var compute_type: ComputeType

    @parameter
    if a.type == DType.float16:
        compute_type = ComputeType.COMPUTE_32F
    elif a.type == DType.bfloat16:
        compute_type = ComputeType.COMPUTE_32F
    else:
        compute_type = (
            ComputeType.COMPUTE_32F_FAST_TF32 if use_tf32 else ComputeType.COMPUTE_32F
        )

    # Rocblas is by default column-major but we like to have the output in row-major
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
        return check_cublas_error(
            cublasGemmEx(
                handle,
                _convert_to_cublas_transpose(transpose_b),
                _convert_to_cublas_transpose(transpose_a),
                N,
                M,
                K,
                UnsafePointer.address_of(alpha).bitcast[NoneType](),
                UnsafePointer(b.data.bitcast[NoneType]()),
                _convert_to_cublas_datatype[b.type](),
                K if transpose_b else N,
                UnsafePointer(a.data.bitcast[NoneType]()),
                _convert_to_cublas_datatype[a.type](),
                K,
                UnsafePointer.address_of(beta).bitcast[NoneType](),
                UnsafePointer(c.data.bitcast[NoneType]()),
                _convert_to_cublas_datatype[c.type](),
                N,
                compute_type,
                Algorithm.DEFAULT,
            )
        )
    # Default column-major.
    check_cublas_error(
        cublasGemmEx(
            handle,
            _convert_to_cublas_transpose(transpose_a),
            _convert_to_cublas_transpose(transpose_b),
            M,
            N,
            K,
            UnsafePointer.address_of(alpha).bitcast[NoneType](),
            UnsafePointer(a.data.bitcast[NoneType]()),
            _convert_to_cublas_datatype[a.type](),
            M,
            UnsafePointer(b.data.bitcast[NoneType]()),
            _convert_to_cublas_datatype[b.type](),
            N if transpose_b else K,
            UnsafePointer.address_of(beta).bitcast[NoneType](),
            UnsafePointer(c.data.bitcast[NoneType]()),
            _convert_to_cublas_datatype[c.type](),
            M,
            compute_type,
            Algorithm.DEFAULT,
        )
    )


# ===----------------------------------------------------------------------===#
# ROCBLAS
# ===----------------------------------------------------------------------===#


fn _rocblas_matmul[
    use_tf32: Bool = False,
](
    ctx: DeviceContext,
    handle: rocblas.Handle,
    c: NDBuffer[_, 2, _],
    a: NDBuffer[_, 2, _],
    b: NDBuffer[_, 2, _],
    *,
    c_row_major: Bool = False,
    transpose_a: Bool = False,
    transpose_b: Bool = False,
) raises:
    constrained[
        a.type == b.type
        and (a.type is DType.float32 or a.type.is_half_float()),
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

    var compute_type = rocblas.types.DataType(DType.float32)

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

    fn _convert_to_rocblas_transpose(tr: Bool) -> rocblas.types.Operation:
        if tr:
            return rocblas.types.Operation.TRANSPOSE
        return rocblas.types.Operation.NONE

    if c_row_major:
        return rocblas.check_error(
            rocblas.rocblas.rocblas_gemm_ex(
                handle,
                _convert_to_rocblas_transpose(transpose_b),
                _convert_to_rocblas_transpose(transpose_a),
                N,
                M,
                K,
                UnsafePointer.address_of(alpha).bitcast[NoneType](),
                UnsafePointer(b.data.bitcast[NoneType]()),
                rocblas.types.DataType(b.type),
                K if transpose_b else N,
                UnsafePointer(a.data.bitcast[NoneType]()),
                rocblas.types.DataType(a.type),
                K,
                UnsafePointer.address_of(beta).bitcast[NoneType](),
                UnsafePointer(c.data.bitcast[NoneType]()),
                rocblas.types.DataType(c.type),
                N,
                UnsafePointer(c.data.bitcast[NoneType]()),
                rocblas.types.DataType(c.type),
                N,
                compute_type,
                rocblas.rocblas.types.Algorithm.STANDARD,
                0,
                0,
            )
        )
    # Default column-major.
    rocblas.check_error(
        rocblas.rocblas.rocblas_gemm_ex(
            handle,
            _convert_to_rocblas_transpose(transpose_a),
            _convert_to_rocblas_transpose(transpose_b),
            M,
            N,
            K,
            UnsafePointer.address_of(alpha).bitcast[NoneType](),
            UnsafePointer(a.data.bitcast[NoneType]()),
            rocblas.types.DataType(a.type),
            M,
            UnsafePointer(b.data.bitcast[NoneType]()),
            rocblas.types.DataType(b.type),
            N if transpose_b else K,
            UnsafePointer.address_of(beta).bitcast[NoneType](),
            UnsafePointer(c.data.bitcast[NoneType]()),
            rocblas.types.DataType(c.type),
            M,
            UnsafePointer(c.data.bitcast[NoneType]()),
            rocblas.types.DataType(c.type),
            M,
            compute_type,
            rocblas.rocblas.types.Algorithm.STANDARD,
            0,
            0,
        )
    )


# ===----------------------------------------------------------------------===#
# CUBLASLT
# ===----------------------------------------------------------------------===#


fn _cublasLt_matmul(
    ctx: DeviceContext,
    handle: UnsafePointer[Context],
    d: NDBuffer[_, 2, _],
    a: NDBuffer[_, 2, _],
    b: NDBuffer[_, 2, _],
    *,
    c_row_major: Bool = True,
    transpose_a: Bool = False,
    transpose_b: Bool = False,
) raises:
    alias a_type = a.type
    alias b_type = b.type
    alias d_type = d.type
    var M = d.dim[0]()
    var N = d.dim[1]()
    var K = a.dim[1]()

    constrained[
        (
            a_type in [DType.float8e4m3, DType.float8e5m2]
            and b_type in [DType.float8e4m3, DType.float8e5m2]
        ),
        (
            "Only E4M3 and E5M2 input data types are supported. Please extend"
            " it if you need more data types."
        ),
    ]()

    constrained[
        not (a_type == b_type == DType.float8e5m2),
        (
            "E5M2xE5m2 is not supported! Please refer to"
            " `https://docs.nvidia.com/cuda/cublas/#id105`"
        ),
    ]()

    if transpose_a or transpose_b:
        raise Error(
            "the cuBLASLT backend currently only is implemented for"
            " transpose_a=False and transpose_a=False"
        )

    # CublasLt is by default column-major but we like to have the output in row-major
    # to compare with our results. Use `c_row_major` to determine the output layout.

    # To use FP8 kernels, the following set of requirements must be satisfied:
    # 1) All matrix dimensions must meet the optimal requirements listed in Tensor Core Usage (See Below)
    # 2) A must be transposed and B non-transposed (The “TN” format).
    # 3) The compute type must be CUBLAS_COMPUTE_32F.
    # 4) The scale type must be CUDA_R_32F.

    # A verity of A, B, and D data types are supported by this API. For more
    # information please refer to `https://docs.nvidia.com/cuda/cublas/#id105`

    # The best performance when using Tensor Cores can be achieved when the matrix dimensions and
    # pointers meet certain memory alignment requirements.
    # Specifically, all of the following conditions must be satisfied to get the most performance out of Tensor Cores:
    # 1) ((op_A == CUBLAS_OP_N ? m : k) * AtypeSize) % 16 == 0
    # 2) ((op_B == CUBLAS_OP_N ? k : n) * BtypeSize) % 16 == 0
    # 3) (m * CtypeSize) % 16 == 0
    # 4) (lda * AtypeSize) % 16 == 0
    # 5) (ldb * BtypeSize) % 16 == 0
    # 6) (ldc * CtypeSize) % 16 == 0
    # 7) intptr_t(A) % 16 == 0
    # 8) intptr_t(B) % 16 == 0
    # 9) intptr_t(C) % 16 == 0

    # set the transforms for A and B
    var transa = cublasOperation_t.CUBLAS_OP_T
    var transb = cublasOperation_t.CUBLAS_OP_N

    var alpha = Scalar[DType.float32](1.0)
    var beta = Scalar[DType.float32](0.0)

    # create operation desciriptor; see cublasLtMatmulDescAttributes_t for details about defaults;
    var operationDesc = cublasLtMatmulDesc_t()
    check_cublas_error(
        cublasLtMatmulDescCreate(
            UnsafePointer.address_of(operationDesc),
            ComputeType.COMPUTE_32F,
            DataType.R_32F,
        )
    )

    check_cublas_error(
        cublasLtMatmulDescSetAttribute(
            operationDesc,
            cublasLtMatmulDescAttributes_t.CUBLASLT_MATMUL_DESC_TRANSA,
            UnsafePointer.address_of(transa).bitcast[NoneType](),
            sizeof[cublasOperation_t](),
        )
    )
    check_cublas_error(
        cublasLtMatmulDescSetAttribute(
            operationDesc,
            cublasLtMatmulDescAttributes_t.CUBLASLT_MATMUL_DESC_TRANSB,
            UnsafePointer.address_of(transb).bitcast[NoneType](),
            sizeof[cublasOperation_t](),
        )
    )

    # create matrix descriptors, we are good with the details here so no need to set any extra attributes
    # table of supported type combinations can be found in the documentation: https://docs.nvidia.com/cuda/cublas/index.html#cublasltmatmul
    var _adesc = cublasLtMatrixLayout_t()
    check_cublas_error(
        cublasLtMatrixLayoutCreate(
            UnsafePointer.address_of(_adesc),
            _convert_to_cublas_datatype[a_type](),
            K,
            N if c_row_major else M,
            K,
        )
    )

    var _bdesc = cublasLtMatrixLayout_t()
    check_cublas_error(
        cublasLtMatrixLayoutCreate(
            UnsafePointer.address_of(_bdesc),
            _convert_to_cublas_datatype[b_type](),
            K,
            M if c_row_major else N,
            K,
        )
    )

    var _ddesc = cublasLtMatrixLayout_t()
    check_cublas_error(
        cublasLtMatrixLayoutCreate(
            UnsafePointer.address_of(_ddesc),
            _convert_to_cublas_datatype[d_type](),
            N if c_row_major else M,
            M if c_row_major else N,
            N if c_row_major else M,
        )
    )

    var _cdesc = cublasLtMatrixLayout_t()
    check_cublas_error(
        cublasLtMatrixLayoutCreate(
            UnsafePointer.address_of(_cdesc),
            _convert_to_cublas_datatype[d_type](),
            N if c_row_major else M,
            M if c_row_major else N,
            N if c_row_major else M,
        )
    )

    var preference = cublasLtMatmulPreference_t()
    check_cublas_error(
        cublasLtMatmulPreferenceCreate(UnsafePointer.address_of(preference))
    )

    var workspaceSize = 0
    # var workspaceSize = 32 * 1024 * 1024
    # check_cublas_error(
    #     cublasLtMatmulPreferenceSetAttribute(
    #         preference,
    #         Preference.MAX_WORKSPACE_BYTES,
    #         UnsafePointer.address_of(workspaceSize).bitcast[NoneType](),
    #         sizeof[Int]()
    #     )
    # )

    var heuristicResult = cublasLtMatmulHeuristicResult_t()
    var returnedResults = 0
    check_cublas_error(
        cublasLtMatmulAlgoGetHeuristic(
            handle,
            operationDesc,
            _adesc,
            _bdesc,
            _cdesc,
            _ddesc,
            preference,
            1,
            UnsafePointer.address_of(heuristicResult),
            UnsafePointer.address_of(returnedResults),
        )
    )

    if returnedResults == 0:
        raise Error("No algorithm was found!")

    var cuda_stream = CUDA(ctx.stream())

    if c_row_major:
        check_cublas_error(
            cublasLtMatmul(
                handle,  # light_handle
                operationDesc,  # compute_desc
                UnsafePointer.address_of(alpha).bitcast[NoneType](),  # alpha
                UnsafePointer(b.data.bitcast[NoneType]()),  # _a
                _adesc,  # _adesc
                UnsafePointer(a.data.bitcast[NoneType]()),  # _b
                _bdesc,  # _bdesc
                UnsafePointer.address_of(beta).bitcast[NoneType](),  # beta
                UnsafePointer[NoneType](),  # _c
                _cdesc,  # _cdesc
                UnsafePointer(d.data.bitcast[NoneType]()),  # _d
                _ddesc,  # _ddesc
                UnsafePointer.address_of(heuristicResult.algo),  # algo
                UnsafePointer[NoneType](),  # workspace
                workspaceSize,  # workspace_size_in_bytes
                cuda_stream[],  # stream
            )
        )
    else:
        check_cublas_error(
            cublasLtMatmul(
                handle,  # light_handle
                operationDesc,  # compute_desc
                UnsafePointer.address_of(alpha).bitcast[NoneType](),  # alpha
                UnsafePointer(a.data.bitcast[NoneType]()),  # _a
                _adesc,  # _adesc
                UnsafePointer(b.data.bitcast[NoneType]()),  # _b
                _bdesc,  # _bdesc
                UnsafePointer.address_of(beta).bitcast[NoneType](),  # beta
                UnsafePointer[NoneType](),  # _c
                _cdesc,  # _cdesc
                UnsafePointer(d.data.bitcast[NoneType]()),  # _d
                _ddesc,  # _ddesc
                UnsafePointer.address_of(heuristicResult.algo),  # algo
                UnsafePointer[NoneType](),  # workspace
                workspaceSize,  # workspace_size_in_bytes
                cuda_stream[],  # stream
            )
        )

    ctx.synchronize()

    check_cublas_error(cublasLtMatmulDescDestroy(operationDesc))
    check_cublas_error(cublasLtMatrixLayoutDestroy(_adesc))
    check_cublas_error(cublasLtMatrixLayoutDestroy(_bdesc))
    check_cublas_error(cublasLtMatrixLayoutDestroy(_cdesc))
    check_cublas_error(cublasLtMatrixLayoutDestroy(_ddesc))
    check_cublas_error(cublasLtMatmulPreferenceDestroy(preference))
