# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from . import Layout, RuntimeLayout
from .layout import to_int
from .int_tuple import UNKNOWN_VALUE
from memory import AddressSpace
from sys import alignof
from utils import StaticIntTuple


@always_inline
fn __get_offset[
    i: Int, layout: Layout
](runtime_layout: RuntimeLayout[layout]) -> Int:
    @parameter
    if layout.all_dims_known():
        alias offset = layout(i)
        return offset
    else:
        return runtime_layout(i)


@always_inline
fn __get_offset[
    i: Int, j: Int, layout: Layout
](runtime_layout: RuntimeLayout[layout]) -> Int:
    @parameter
    if layout.all_dims_known():
        alias offset = layout(IntTuple(i, j))
        return offset
    else:
        return runtime_layout(
            RuntimeTuple[IntTuple(UNKNOWN_VALUE, UNKNOWN_VALUE)](i, j)
        )


# Element is a wrapper around SIMD type, it extends the SIMD type to define
# a vectorized load / store that is driven by the layout of the element.
#
struct Element[dtype: DType, layout: Layout](Stringable, Formattable):
    alias element_data_type = SIMD[dtype, size = layout.size()]

    var element_data: Self.element_data_type

    var runtime_layout: RuntimeLayout[layout]

    fn __init__(inout self, element_data: Self.element_data_type):
        self.element_data = element_data
        self.runtime_layout = RuntimeLayout[layout]()

    fn __init__(
        inout self,
        element_data: Self.element_data_type,
        runtime_layout: RuntimeLayout[layout],
    ):
        self.element_data = element_data
        self.runtime_layout = runtime_layout

    @staticmethod
    fn load[
        address_space: AddressSpace
    ](
        ptr: UnsafePointer[Scalar[dtype], address_space],
        runtime_layout: RuntimeLayout[layout] = RuntimeLayout[layout](),
    ) -> Self:
        constrained[layout.rank() <= 2, "Only supports rank <= 2"]()

        var element_data = Self.element_data_type()

        @parameter
        if layout.rank() == 1:
            alias size = layout.size()

            @parameter
            if layout.stride[0] == 1:
                alias alignment = alignof[Self.element_data_type]()
                return ptr.load[
                    width = Self.element_data_type.size, alignment=alignment
                ]()

            @parameter
            for i in range(size):
                element_data[i] = ptr[__get_offset[i](runtime_layout)]
            return Element(element_data, runtime_layout)

        @parameter
        if layout.stride[0] == 1:
            alias size = to_int(layout.shape[0])
            alias elements = to_int(layout.shape[1])
            alias vec_type = SIMD[dtype, size]
            alias alignment = alignof[vec_type]

            @parameter
            for i in range(elements):
                var vec_i = ptr.load[width=size](
                    __get_offset[0, i](runtime_layout)
                )
                element_data = element_data.insert[offset = i * size](vec_i)
            return Element(element_data, runtime_layout)

        elif layout.stride[1] == 1:
            alias size = to_int(layout.shape[1])
            alias elements = to_int(layout.shape[0])
            alias vec_type = SIMD[dtype, size]
            alias alignment = alignof[vec_type]

            @parameter
            for i in range(elements):
                var vec_i = ptr.load[width=size](
                    __get_offset[i, 0](runtime_layout)
                )
                element_data = element_data.insert[offset = i * size](vec_i)
            return Element(element_data, runtime_layout)

        alias dim_0 = to_int(layout.shape[0])
        alias dim_1 = to_int(layout.shape[1])

        @parameter
        for i in range(dim_0):

            @parameter
            for j in range(dim_1):
                element_data[i + j * dim_0] = ptr[
                    __get_offset[i, j](runtime_layout)
                ]
        return Element(element_data, runtime_layout)

    @staticmethod
    fn masked_load[
        address_space: AddressSpace, rank: Int
    ](
        ptr: UnsafePointer[Scalar[dtype], address_space],
        element_bounds: StaticIntTuple[rank],
        runtime_layout: RuntimeLayout[layout] = RuntimeLayout[layout](),
    ) -> Self:
        # TODO: Use partial_simd_load after closing KERN-729.
        constrained[layout.rank() <= 2, "Only supports rank <= 2"]()
        constrained[
            rank == layout.rank(), "bounds rank must match layout rank"
        ]()
        var element_data = Self.element_data_type()

        @parameter
        if layout.rank() == 1:
            alias size = layout.size()

            @parameter
            if layout.stride[0] == 1:
                alias alignment = alignof[Self.element_data_type]()
                if element_bounds[0] < size:

                    @parameter
                    for i in range(size):
                        if i >= element_bounds[0]:
                            break
                        element_data[i] = ptr[__get_offset[i](runtime_layout)]
                    return Element(element_data, runtime_layout)

                return ptr.load[
                    width = Self.element_data_type.size, alignment=alignment
                ](0)

            @parameter
            for i in range(size):
                if i >= element_bounds[0]:
                    break
                element_data[i] = ptr[__get_offset[i](runtime_layout)]
            return Element(element_data, runtime_layout)

        # rank-2 element.
        @parameter
        if layout.stride[0] == 1:
            alias size = to_int(layout.shape[0])
            alias elements = to_int(layout.shape[1])
            alias vec_type = SIMD[dtype, size]
            alias alignment = alignof[vec_type]
            var element_data = Self.element_data_type()
            if element_bounds[0] < size:
                alias dim_0 = to_int(layout.shape[0])
                alias dim_1 = to_int(layout.shape[1])

                @parameter
                for i in range(dim_0):
                    if i >= element_bounds[0]:
                        break

                    @parameter
                    for j in range(dim_1):
                        if j >= element_bounds[1]:
                            break
                        element_data[i + j * dim_0] = ptr[
                            __get_offset[i, j](runtime_layout)
                        ]
                return Element(element_data, runtime_layout)

            @parameter
            for i in range(elements):
                if i >= element_bounds[1]:
                    break
                var vec_i = ptr.load[width=size](
                    __get_offset[0, i](runtime_layout)
                )
                element_data = element_data.insert[offset = i * size](vec_i)
            return Element(element_data, runtime_layout)

        elif layout.stride[1] == 1:
            alias size = to_int(layout.shape[1])
            alias elements = to_int(layout.shape[0])
            alias vec_type = SIMD[dtype, size]
            alias alignment = alignof[vec_type]
            var element_data = Self.element_data_type()
            if element_bounds[1] < size:
                alias dim_0 = to_int(layout.shape[0])
                alias dim_1 = to_int(layout.shape[1])

                @parameter
                for i in range(dim_0):
                    if i >= element_bounds[0]:
                        break

                    @parameter
                    for j in range(dim_1):
                        if j >= element_bounds[1]:
                            break
                        element_data[i + j * dim_0] = ptr[
                            __get_offset[i, j](runtime_layout)
                        ]
                return Element(element_data, runtime_layout)

            @parameter
            for i in range(elements):
                if i >= element_bounds[0]:
                    break
                var vec_i = ptr.load[width=size](
                    __get_offset[i, 0](runtime_layout)
                )
                element_data = element_data.insert[offset = i * size](vec_i)
            return Element(element_data, runtime_layout)

        alias dim_0 = to_int(layout.shape[0])
        alias dim_1 = to_int(layout.shape[1])

        @parameter
        for i in range(dim_0):
            if i >= element_bounds[0]:
                break

            @parameter
            for j in range(dim_1):
                if j >= element_bounds[1]:
                    break
                element_data[i + j * dim_0] = ptr[
                    __get_offset[i, j](runtime_layout)
                ]
        return Element(element_data, runtime_layout)

    fn store[
        address_space: AddressSpace
    ](self, ptr: UnsafePointer[Scalar[dtype], address_space]):
        constrained[layout.rank() <= 2, "Only supports rank <= 2"]()

        @parameter
        if layout.rank() == 1:
            alias size = layout.size()

            @parameter
            if layout.stride[0] == 1:
                alias alignment = alignof[Self.element_data_type]()
                ptr.store[alignment=alignment](self.element_data)
            else:

                @parameter
                for i in range(size):
                    ptr[
                        __get_offset[i](self.runtime_layout)
                    ] = self.element_data[i]
        else:

            @parameter
            if layout.stride[0] == 1:
                alias size = to_int(layout.shape[0])
                alias elements = to_int(layout.shape[1])

                alias vec_type = SIMD[dtype, size]
                alias alignment = alignof[vec_type]()

                @parameter
                for i in range(elements):
                    (ptr + __get_offset[i, 0](self.runtime_layout)).store[
                        width=size, alignment=alignment
                    ](
                        self.element_data.slice[size, offset = i * size](),
                    )

            elif layout.stride[1] == 1:
                alias size = to_int(layout.shape[1])
                alias elements = to_int(layout.shape[0])

                alias vec_type = SIMD[dtype, size]
                alias alignment = alignof[vec_type]()

                @parameter
                for i in range(elements):
                    (ptr + __get_offset[i, 0](self.runtime_layout)).store[
                        width=size, alignment=alignment
                    ](
                        self.element_data.slice[size, offset = i * size](),
                    )
            else:
                alias dim_0 = to_int(layout.shape[0])
                alias dim_1 = to_int(layout.shape[1])

                @parameter
                for i in range(dim_0):

                    @parameter
                    for j in range(dim_1):
                        (ptr + __get_offset[i, j](self.runtime_layout)).store(
                            self.element_data[i + j * dim_0]
                        )

    fn masked_store[
        address_space: AddressSpace, rank: Int
    ](
        self,
        ptr: UnsafePointer[Scalar[dtype], address_space],
        element_bounds: StaticIntTuple[rank],
    ):
        constrained[layout.rank() <= 2, "Only supports rank <= 2"]()
        constrained[
            rank == layout.rank(), "bounds rank must match layout rank"
        ]()

        @parameter
        if layout.rank() == 1:
            alias size = layout.size()

            @parameter
            if layout.stride[0] == 1:
                if element_bounds[0] < size:

                    @parameter
                    for i in range(size):
                        if i >= element_bounds[0]:
                            break
                        ptr[
                            __get_offset[i](self.runtime_layout)
                        ] = self.element_data[i]
                else:
                    alias alignment = alignof[Self.element_data_type]()
                    ptr.store(self.element_data)
            else:

                @parameter
                for i in range(size):
                    if i >= element_bounds[0]:
                        break
                    ptr[
                        __get_offset[i](self.runtime_layout)
                    ] = self.element_data[i]
        else:

            @parameter
            if layout.stride[0] == 1:
                alias size = to_int(layout.shape[0])
                alias elements = to_int(layout.shape[1])

                alias vec_type = SIMD[dtype, size]
                alias alignment = alignof[vec_type]()
                if element_bounds[1] < size:
                    alias dim_0 = to_int(layout.shape[0])
                    alias dim_1 = to_int(layout.shape[1])

                    @parameter
                    for i in range(dim_0):
                        if i >= element_bounds[0]:
                            break

                        @parameter
                        for j in range(dim_1):
                            if j >= element_bounds[1]:
                                break
                            ptr.store[width=1](
                                __get_offset[i, j](self.runtime_layout)
                            )

                else:

                    @parameter
                    for i in range(elements):
                        if i >= element_bounds[0]:
                            break
                        (ptr + __get_offset[i, 0](self.runtime_layout)).store[
                            alignment=alignment
                        ](
                            self.element_data.slice[size, offset = i * size](),
                        )

            elif layout.stride[1] == 1:
                alias size = to_int(layout.shape[1])
                alias elements = to_int(layout.shape[0])

                alias vec_type = SIMD[dtype, size]
                alias alignment = alignof[vec_type]()

                if element_bounds[1] < size:
                    alias dim_0 = to_int(layout.shape[0])
                    alias dim_1 = to_int(layout.shape[1])

                    @parameter
                    for i in range(dim_0):
                        if i >= element_bounds[0]:
                            break

                        @parameter
                        for j in range(dim_1):
                            if j >= element_bounds[1]:
                                break
                            ptr.store(
                                __get_offset[i, j](self.runtime_layout),
                                self.element_data[i + j * dim_0],
                            )
                else:

                    @parameter
                    for i in range(elements):
                        if i >= element_bounds[1]:
                            break
                        (ptr + __get_offset[i, 0](self.runtime_layout)).store[
                            alignment=alignment
                        ](
                            self.element_data.slice[size, offset = i * size](),
                        )
            else:
                alias dim_0 = to_int(layout.shape[0])
                alias dim_1 = to_int(layout.shape[1])

                @parameter
                for i in range(dim_0):
                    if i >= element_bounds[0]:
                        break

                    @parameter
                    for j in range(dim_1):
                        if j >= element_bounds[1]:
                            break
                        (ptr + __get_offset[i, j](self.runtime_layout)).store(
                            self.element_data[i + j * dim_0]
                        )

    @no_inline
    fn __str__(self) -> String:
        return String.format_sequence(self)

    @no_inline
    fn format_to(self, inout writer: Formatter):
        writer.write(self.element_data)
