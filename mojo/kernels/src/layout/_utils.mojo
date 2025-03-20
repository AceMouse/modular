# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from collections import Optional
from sys import bitwidthof

from buffer import NDBuffer
from gpu.host import DeviceBuffer, DeviceContext
from layout import *
from layout.layout_tensor import LayoutTensor
from memory import UnsafePointer

from utils.index import Index

from .int_tuple import product, _get_index_type
from gpu.intrinsics import make_buffer_resource, _buffer_resource


struct ManagedLayoutTensor[
    dtype: DType,
    layout: Layout,
    *,
]:
    alias layout_bitwidth = bitwidthof[_get_index_type(AddressSpace.GENERIC)]()
    var device_data: Optional[DeviceBuffer[dtype]]
    var host_data: DeviceBuffer[dtype]
    var runtime_layout: RuntimeLayout[layout, bitwidth = Self.layout_bitwidth]
    var ctx: DeviceContext

    @always_inline
    fn __init__(out self) raises:
        self.ctx = DeviceContext(api="cpu")
        self.runtime_layout = __type_of(self.runtime_layout)()
        self.device_data = None
        self.host_data = self.ctx.enqueue_create_host_buffer[dtype](
            self.runtime_layout.size()
        )
        self.ctx.synchronize()

    @always_inline
    fn __init__(out self, runtime_layout: RuntimeLayout[layout, **_]) raises:
        self.ctx = DeviceContext(api="cpu")
        self.runtime_layout = rebind[__type_of(self.runtime_layout)](
            runtime_layout
        )
        self.device_data = None
        self.host_data = self.ctx.enqueue_create_host_buffer[dtype](
            self.runtime_layout.size()
        )
        self.ctx.synchronize()

    @always_inline
    fn __init__(out self, ctx: DeviceContext) raises:
        self.ctx = ctx
        self.runtime_layout = __type_of(self.runtime_layout)()
        self.device_data = ctx.enqueue_create_buffer[dtype](
            self.runtime_layout.size()
        )
        self.host_data = self.ctx.enqueue_create_host_buffer[dtype](
            self.runtime_layout.size()
        )
        self.ctx.synchronize()

    @always_inline
    fn __init__(
        out self, runtime_layout: RuntimeLayout[layout, **_], ctx: DeviceContext
    ) raises:
        self.ctx = ctx
        self.runtime_layout = rebind[__type_of(self.runtime_layout)](
            runtime_layout
        )
        self.device_data = ctx.enqueue_create_buffer[dtype](
            self.runtime_layout.size()
        )
        self.host_data = self.ctx.enqueue_create_host_buffer[dtype](
            self.runtime_layout.size()
        )
        self.ctx.synchronize()

    fn device_tensor[
        update: Bool = True
    ](self) raises -> LayoutTensor[dtype, layout, MutableAnyOrigin]:
        debug_assert(
            Bool(self.ctx.api() != "cpu"),
            "device_tensor cannot be constructed for host only tensor.",
        )

        @parameter
        if update:
            self._update_device()

        @parameter
        if layout.all_dims_known():
            return LayoutTensor[dtype, layout](
                self.device_data.value(),
            )
        else:
            return LayoutTensor[dtype, layout](
                self.device_data.value().unsafe_ptr(),
                self.runtime_layout,
            )

    fn device_buffer[update: Bool = True](self) raises -> NDBuffer[dtype, 2]:
        @parameter
        if update:
            self._update_device()

        constrained[layout.rank() == 2, "Only support exporting 2D NDBuffer."]()

        M = self.runtime_layout.dim(0)
        N = self.runtime_layout.dim(1)

        return NDBuffer[dtype, 2](self.device_data.value().unsafe_ptr(), (M, N))

    fn tensor[
        update: Bool = True
    ](self) raises -> LayoutTensor[dtype, layout, MutableAnyOrigin]:
        @parameter
        if update:
            self._update_host()

        @parameter
        if layout.all_dims_known():
            return LayoutTensor[dtype, layout](
                self.host_data,
            )
        else:
            return LayoutTensor[dtype, layout](
                self.host_data,
                self.runtime_layout,
            )

    fn buffer[update: Bool = True](self) raises -> NDBuffer[dtype, 2]:
        @parameter
        if update:
            self._update_host()

        constrained[layout.rank() == 2, "Only support exporting 2D NDBuffer."]()

        M = self.runtime_layout.dim(0)
        N = self.runtime_layout.dim(1)

        return NDBuffer[dtype, 2](self.host_data.unsafe_ptr(), (M, N))

    fn _update_device(self) raises:
        if self.ctx.api() != "cpu":
            self.ctx.enqueue_copy(self.device_data.value(), self.host_data)
            self.ctx.synchronize()

    fn _update_host(self) raises:
        if self.ctx.api() != "cpu":
            self.ctx.enqueue_copy(self.host_data, self.device_data.value())
            self.ctx.synchronize()

    @always_inline
    fn __del__(owned self):
        pass


fn load_to_simd(
    tensor: LayoutTensor,
    out res: SIMD[tensor.dtype, product(tensor.layout.shape)],
):
    constrained[
        tensor.layout.all_dims_known(),
        "load_to_simd is supported only for tensors with known layout",
    ]()
    alias size = __type_of(res).size
    return rebind[__type_of(res)](
        tensor.reshape[Layout(size)]().vectorize[size]()[0]
    )


@always_inline
fn _get_bounds(tensor: LayoutTensor) -> Int:
    constrained[
        tensor.element_layout.all_dims_known(),
        "Element layout must be known for _get_bounds",
    ]()
    alias element_layout = tensor.element_layout
    alias element_offset = element_layout(element_layout.size() - 1)
    return (
        tensor._offset(tensor.dim(0) - 1, tensor.dim(1) - 1)
        + element_offset
        + 1
    )


@always_inline
fn get_amd_buffer_descriptor(tensor: LayoutTensor) -> _buffer_resource:
    var ptr = tensor.ptr
    var size = _get_bounds(tensor)
    return make_buffer_resource(ptr, size)
