# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from sys import external_call

from gpu.host import DeviceContext, DeviceStream
from gpu.host.device_context import (
    _CharPtr,
    _checked,
    _DeviceBufferPtr,
    _DeviceContextPtr,
    _DeviceStreamPtr,
)
from memory import UnsafePointer, stack_allocation
from memory.unsafe import bitcast


struct _CUctx_st:
    pass


struct _CUstream_st:
    pass


alias CUcontext = UnsafePointer[_CUctx_st]
alias CUstream = UnsafePointer[_CUstream_st]


# Accessor function to get access to the underlying CUcontext from a abstract DeviceContext.
# Use `var cuda_ctx: CUcontext = CUDA(ctx)` where ctx is a `DeviceContext` to get access to the underlying CUcontext.
@always_inline
fn CUDA(ctx: DeviceContext) raises -> CUcontext:
    var result = CUcontext()
    # const char *AsyncRT_DeviceContext_cuda_context(CUcontext *result, const DeviceContext *ctx)
    _checked(
        external_call[
            "AsyncRT_DeviceContext_cuda_context",
            _CharPtr,
            UnsafePointer[CUcontext],
            _DeviceContextPtr,
        ](
            UnsafePointer.address_of(result),
            ctx._handle,
        )
    )
    return result


# Accessor function to get access to the underlying CUstream from a abstract DeviceStream.
# Use `var cuda_stream: CUstream = CUDA(ctx.stream())` where ctx is a `DeviceContext` to get access to the underlying CUstream.
@always_inline
fn CUDA(stream: DeviceStream) raises -> CUstream:
    var result = CUstream()
    # const char *AsyncRT_DeviceStream_cuda_stream(CUstream *result, const DeviceStream *stream)
    _checked(
        external_call[
            "AsyncRT_DeviceStream_cuda_stream",
            _CharPtr,
            UnsafePointer[CUstream],
            _DeviceStreamPtr,
        ](
            UnsafePointer.address_of(result),
            stream._handle,
        )
    )
    return result


# ===----------------------------------------------------------------------=== #
# TMA
# ===----------------------------------------------------------------------=== #


@value
@register_passable("trivial")
struct TensorMapDataType:
    var _value: Int32

    alias UINT8 = Self(0)
    alias UINT16 = Self(1)
    alias UINT32 = Self(2)
    alias INT32 = Self(3)
    alias UINT64 = Self(4)
    alias INT64 = Self(5)
    alias FLOAT16 = Self(6)
    alias FLOAT32 = Self(7)
    alias FLOAT64 = Self(8)
    alias BFLOAT16 = Self(9)
    alias FLOAT32_FTZ = Self(10)
    alias TFLOAT32 = Self(11)
    alias TFLOAT32_FTZ = Self(12)

    @implicit
    fn __init__(out self, value: Int32):
        self._value = value

    @staticmethod
    fn from_dtype[dtype: DType]() -> Self:
        constrained[
            dtype in (DType.float32, DType.bfloat16), "Unsupported dtype"
        ]()

        @parameter
        if dtype is DType.float32:
            return Self.FLOAT32
        else:
            return Self.BFLOAT16


@value
@register_passable("trivial")
struct TensornsorMapInterleave:
    var _value: Int32

    alias INTERLEAVE_NONE = Self(0)
    alias INTERLEAVE_16B = Self(1)
    alias INTERLEAVE_32B = Self(2)

    @implicit
    fn __init__(out self, value: Int32):
        self._value = value


@value
@register_passable("trivial")
struct TensorMapSwizzle:
    var _value: Int32

    alias SWIZZLE_NONE = Self(0)
    alias SWIZZLE_32B = Self(1)
    alias SWIZZLE_64B = Self(2)
    alias SWIZZLE_128B = Self(3)

    @implicit
    fn __init__(out self, value: Int32):
        self._value = value


@value
@register_passable("trivial")
struct TensorMapL2Promotion:
    var _value: Int32

    alias NONE = Self(0)
    alias L2_64B = Self(1)
    alias L2_128B = Self(2)
    alias L2_256B = Self(3)

    @implicit
    fn __init__(out self, value: Int32):
        self._value = value


@value
@register_passable
struct TensorMapFloatOOBFill:
    var _value: Int32

    alias NONE = Self(0)
    alias NAN_REQUEST_ZERO_FMA = Self(1)

    @implicit
    fn __init__(out self, value: Int32):
        self._value = value


# The TMA descriptor is a 128-byte opaque object filled by the driver API.
# It should be 64-byte aligned both on the host and the device (if passed to constant memory).
struct TMADescriptor:
    var data: StaticTuple[UInt8, 128]

    @always_inline
    fn __copyinit__(out self, other: Self):
        self.data = other.data


@always_inline
fn create_tma_descriptor[
    dtype: DType, rank: Int
](
    global_buf: DeviceBuffer[dtype],
    global_shape: IndexList[rank],
    global_strides: IndexList[rank],
    shared_mem_shape: IndexList[rank],
    element_stride: IndexList[rank] = IndexList[rank](1),
) raises -> TMADescriptor:
    """Create a tensor map descriptor object representing tiled memory region.
    """
    # Enforces host-side aligment
    var tma_descriptor = stack_allocation[1, TMADescriptor, alignment=64]()[0]
    var tensor_map_ptr = UnsafePointer.address_of(tma_descriptor).bitcast[
        NoneType
    ]()

    var global_dim_arg = stack_allocation[rank, Int64]()
    var global_strides_arg = stack_allocation[rank - 1, Int64]()
    var box_dim_arg = stack_allocation[rank, Int32]()
    var element_stride_arg = stack_allocation[rank, Int32]()

    @parameter
    for i in range(rank):
        global_dim_arg[i] = global_shape[rank - i - 1]
        box_dim_arg[i] = shared_mem_shape[rank - i - 1]
        element_stride_arg[i] = element_stride[rank - i - 1]

    @parameter
    for i in range(rank - 1):
        global_strides_arg[i] = global_strides[rank - i - 2] * sizeof[dtype]()

    # const char *AsyncRT_cuda_tensorMapEncodeTiled(
    #     void *tensorMap, int32_t tensorDataType, uint32_t tensorRank,
    #     const DeviceBuffer *globalAddress, const uint64_t *globalDim,
    #     const uint64_t *globalStrides, const uint32_t *boxDim,
    #     const uint32_t *elementStrides, int32_t interleave, int32_t swizzle,
    #     int32_t l2Promotion, int32_t oobFill) {
    _checked(
        external_call[
            "AsyncRT_cuda_tensorMapEncodeTiled",
            _CharPtr,
            UnsafePointer[NoneType],  # tensorMap
            Int32,  # tensorDataType
            Int32,  # tensorRank
            _DeviceBufferPtr,  #  globalAddress
            UnsafePointer[Int64],  # globalDim
            UnsafePointer[Int64],  # globalStrides
            UnsafePointer[Int32],  # boxDim
            UnsafePointer[Int32],  # elementStrides
            Int32,  # interleave
            Int32,  # swizzle
            Int32,  # l2Promotion
            Int32,  # oobFill
        ](
            tensor_map_ptr,
            TensorMapDataType.from_dtype[dtype]()._value,
            rank,
            global_buf._handle,
            global_dim_arg,
            global_strides_arg,
            box_dim_arg,
            element_stride_arg,
            TensornsorMapInterleave.INTERLEAVE_NONE._value,
            TensorMapSwizzle.SWIZZLE_NONE._value,
            TensorMapL2Promotion.NONE._value,
            TensorMapFloatOOBFill.NONE._value,
        )
    )
    return tma_descriptor
