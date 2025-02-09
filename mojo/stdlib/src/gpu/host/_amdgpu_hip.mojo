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
    _DeviceContextPtr,
    _DeviceStreamPtr,
)
from memory import UnsafePointer


struct _ihipCtx_t:
    pass


struct _ihipStream_t:
    pass


alias hipCtx_t = UnsafePointer[_ihipCtx_t]
alias hipStream_t = UnsafePointer[_ihipStream_t]


# Accessor function to get access to the underlying hipCtx_t from an abstract DeviceContext.
# Use `var hip_ctx: hipCtx_t = HIP(ctx)` where ctx is a `DeviceContext` to get access to the underlying hipCtx_t.
@always_inline
fn HIP(ctx: DeviceContext) raises -> hipCtx_t:
    var result = hipCtx_t()
    # const char *AsyncRT_DeviceContext_hip_context(hipCtx_t *result, const DeviceContext *ctx)
    _checked(
        external_call[
            "AsyncRT_DeviceContext_hip_context",
            _CharPtr,
            UnsafePointer[hipCtx_t],
            _DeviceContextPtr,
        ](
            UnsafePointer.address_of(result),
            ctx._handle,
        )
    )
    return result


# Accessor function to get access to the underlying hipStream_t from an abstract DeviceStream.
# Use `var hip_stream: hipStream_t = HIP(ctx.stream())` where ctx is a `DeviceContext` to get access to the underlying hipStream_t.
@always_inline
fn HIP(stream: DeviceStream) raises -> hipStream_t:
    var result = hipStream_t()
    # const char *AsyncRT_DeviceStream_hip_stream(hipStream_t *result, const DeviceStream *stream)
    _checked(
        external_call[
            "AsyncRT_DeviceStream_hip_stream",
            _CharPtr,
            UnsafePointer[hipStream_t],
            _DeviceStreamPtr,
        ](
            UnsafePointer.address_of(result),
            stream._handle,
        )
    )
    return result
