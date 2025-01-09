# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: disabled

from os import abort
from sys import bitwidthof
from layout import *
from layout.layout_tensor import _get_index_type
from memory import UnsafePointer
from collections import Optional
from gpu.host import DeviceBuffer, DeviceContext
from .int_tuple import product


struct ManagedLayoutTensor[
    dtype: DType,
    layout: Layout,
    *,
]:
    alias layout_bitwidth = bitwidthof[_get_index_type(AddressSpace.GENERIC)]()
    var device_data: Optional[DeviceBuffer[dtype]]
    var host_data: UnsafePointer[Scalar[dtype]]
    var runtime_layout: RuntimeLayout[layout, bitwidth = Self.layout_bitwidth]
    var ctx: Optional[DeviceContext]

    @always_inline
    fn __init__(out self):
        self.ctx = None
        self.device_data = None
        self.host_data = __type_of(self.host_data).alloc(layout.size())
        self.runtime_layout = __type_of(self.runtime_layout)()

    @always_inline
    fn __init__(mut self, runtime_layout: RuntimeLayout[layout, **_]):
        self.ctx = None
        self.device_data = None
        self.host_data = __type_of(self.host_data).alloc(runtime_layout.size())
        self.runtime_layout = rebind[__type_of(self.runtime_layout)](
            runtime_layout
        )

    @always_inline
    fn __init__(out self, ctx: DeviceContext) raises:
        self.ctx = ctx
        self.device_data = ctx.create_buffer_sync[dtype](layout.size())
        self.host_data = __type_of(self.host_data).alloc(layout.size())
        self.runtime_layout = __type_of(self.runtime_layout)()

    @always_inline
    fn __init__(
        mut self, runtime_layout: RuntimeLayout[layout, **_], ctx: DeviceContext
    ) raises:
        self.ctx = ctx
        self.device_data = ctx.create_buffer_sync[dtype](runtime_layout.size())
        self.host_data = __type_of(self.host_data).alloc(runtime_layout.size())
        self.runtime_layout = rebind[__type_of(self.runtime_layout)](
            runtime_layout
        )

    fn device_tensor[
        update: Bool = True
    ](self) raises -> LayoutTensor[dtype, layout]:
        debug_assert(
            bool(self.ctx),
            "device_tensor cannot be constructed for host only tensor.",
        )

        @parameter
        if update:
            self._update_device()

        @parameter
        if layout.all_dims_known():
            return LayoutTensor[dtype, layout](
                self.device_data.value().ptr,
            )
        else:
            return LayoutTensor[dtype, layout](
                self.device_data.value().ptr,
                self.runtime_layout,
            )

    fn tensor[update: Bool = True](self) raises -> LayoutTensor[dtype, layout]:
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

    fn _update_device(self) raises:
        if self.ctx:
            self.ctx.value().copy_to_device_sync(
                self.device_data.value(), self.host_data
            )

    fn _update_host(self) raises:
        if self.ctx:
            self.ctx.value().copy_from_device_sync(
                self.host_data, self.device_data.value()
            )

    @always_inline
    fn __del__(owned self):
        self.host_data.free()


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
