# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from memory.unsafe import DTypePointer

from .int_tuple import flatten, int
from .layout import *
from sys.intrinsics import PrefetchOptions
from algorithm import vectorize
from memory import memcpy
from gpu.memory import async_copy, async_copy_wait_all
from gpu import AddressSpace


@register_passable
struct LayoutTensor[
    layout: Layout,
    dtype: DType,
    /,
    *,
    address_space: AddressSpace = AddressSpace.GENERIC,
](CollectionElement):
    var ptr: DTypePointer[dtype, address_space]
    var owning: Bool

    @always_inline
    fn __init__(
        inout self,
        ptr: DTypePointer[dtype, address_space],
        /,
        *,
        owning: Bool = False,
    ):
        self.ptr = ptr
        self.owning = owning

    @always_inline
    fn __copyinit__(inout self: Self, existing: Self):
        self.ptr = existing.ptr
        self.owning = False

    fn __del__(owned self):
        if self.owning:
            self.ptr.free()

    @always_inline
    fn _offset(self, m: Int, n: Int) -> Int:
        return Self.stride[0]() * m + Self.stride[1]() * n

    # FIXME: Without this __getitem__(m, n) gemm results are wrong
    @always_inline
    fn __getitem__(self, m: Int, n: Int) -> Scalar[dtype]:
        return self.ptr.load[width=1](self._offset(m, n))

    @always_inline
    fn __getitem__(self, *dims: Int) -> Scalar[dtype]:
        # TODO: Static assert ranks are the same!
        alias strides = Self._toStatic[flatten(layout.stride)]()
        return self.ptr.load[width=1](Self._getOffset(strides, dims))

    @always_inline
    fn __setitem__(self, d0: Int, val: Scalar[dtype]):
        alias strides = Self._toStatic[flatten(layout.stride)]()
        self.ptr.store[width=1](
            Self._getOffset(strides, VariadicList[Int](d0)), val
        )

    @always_inline
    fn __setitem__(self, d0: Int, d1: Int, val: Scalar[dtype]):
        alias strides = Self._toStatic[flatten(layout.stride)]()
        self.ptr.store[width=1](
            Self._getOffset(strides, VariadicList[Int](d0, d1)), val
        )

    @always_inline
    fn __setitem__(self, d0: Int, d1: Int, d2: Int, val: Scalar[dtype]):
        alias strides = Self._toStatic[flatten(layout.stride)]()
        self.ptr.store[width=1](
            Self._getOffset(strides, VariadicList[Int](d0, d1, d2)), val
        )

    @always_inline
    fn __setitem__(
        self, d0: Int, d1: Int, d2: Int, d3: Int, val: Scalar[dtype]
    ):
        alias strides = Self._toStatic[flatten(layout.stride)]()
        self.ptr.store[width=1](
            Self._getOffset(strides, VariadicList[Int](d0, d1, d2, d3)), val
        )

    @always_inline
    fn load[width: Int](self, m: Int, n: Int) -> SIMD[dtype, width]:
        return self.ptr.load[width=width](self._offset(m, n))

    @always_inline
    fn prefetch(self, m: Int, n: Int):
        self.ptr.offset(self._offset(m, n)).prefetch[
            PrefetchOptions().for_read().high_locality().to_data_cache()
        ]()

    @always_inline
    fn aligned_load[width: Int](self, m: Int, n: Int) -> SIMD[dtype, width]:
        alias alignment = alignof[SIMD[dtype, width]]()
        return self.ptr.aligned_simd_load[width, alignment](self._offset(m, n))

    @always_inline
    fn store[width: Int](self, m: Int, n: Int, val: SIMD[dtype, width]):
        return self.ptr.store[width=width](self._offset(m, n), val)

    @always_inline
    fn aligned_store[width: Int](self, m: Int, n: Int, val: SIMD[dtype, width]):
        alias alignment = alignof[SIMD[dtype, width]]()
        return self.ptr.aligned_simd_store[width, alignment](
            self._offset(m, n), val
        )

    @staticmethod
    @always_inline("nodebug")
    fn stack_allocation() -> Self:
        return stack_allocation[
            layout.size(), dtype, address_space=address_space
        ]()

    @staticmethod
    @always_inline("nodebug")
    fn aligned_stack_allocation[alignment: Int]() -> Self:
        return stack_allocation[
            layout.size(),
            dtype,
            alignment=alignment,
            address_space=address_space,
        ]()

    @staticmethod
    fn _toStatic[t: IntTuple]() -> StaticIntTuple[len(t)]:
        var st = StaticIntTuple[len(t)]()
        for i in range(len(t)):
            st[i] = int(t[i])
        return st

    @staticmethod
    fn _getOffset[
        rank: Int
    ](stride: StaticIntTuple[rank], vals: VariadicList[Int]) -> Int:
        var offset = 0
        for i in range(rank):
            offset += vals[i] * stride[i]
        return offset

    @staticmethod
    fn _getOffset[
        rank_1: Int, rank_2: Int
    ](stride: StaticIntTuple[rank_1], vals: StaticIntTuple[rank_2]) -> Int:
        # In theory we should be able to verify this at compile time but it not happening now!
        constrained[
            rank_1 == rank_2, "shape and stride should be the same rank!"
        ]()
        var offset = 0
        for i in range(rank_1):
            offset += vals[i] * stride[i]
        return offset

    @always_inline
    @staticmethod
    fn shape[idx: Int]() -> Int:
        alias shape = Self._toStatic[layout.shape]()
        return shape[idx]

    @always_inline
    @staticmethod
    fn stride[idx: Int]() -> Int:
        alias stride = Self._toStatic[layout.stride]()
        return stride[idx]

    @always_inline
    @staticmethod
    fn dim[idx: Int]() -> Int:
        return Self.shape[idx]()

    @staticmethod
    fn _compute_tile_layout[M: Int, N: Int]() -> Layout:
        alias tiler = MakeLayoutList(Layout(M, 1), Layout(N, 1))
        return zipped_divide(layout, tiler)

    @always_inline
    fn tile[
        M1: Int,
        N1: Int,
        *,
        __tiled_layout: Layout = Self._compute_tile_layout[M1, N1](),
    ](self, m: Int, n: Int) -> LayoutTensor[
        __tiled_layout[0], dtype, address_space
    ]:
        alias stride_m = int(__tiled_layout[1].stride[0])
        alias stride_n = int(__tiled_layout[1].stride[1])
        var offset = m * stride_m + n * stride_n
        return LayoutTensor[__tiled_layout[0], dtype, address_space](
            self.ptr.offset(offset)
        )

    @staticmethod
    fn _compute_distribute_layout[
        data_layout: Layout, threads_layout: Layout
    ]() -> Layout:
        var thread_tile = LayoutList()
        for dim in threads_layout.shape:
            thread_tile.append(Layout(dim))
        return zipped_divide(layout, thread_tile)

    @always_inline
    fn distribute[
        threads_layout: Layout,
        tiled_layout: Layout = Self._compute_distribute_layout[
            layout, threads_layout
        ](),
    ](self, thread_id: Int) -> LayoutTensor[
        tiled_layout[1], dtype, address_space
    ]:
        alias fragments_layout_stride = flatten(tiled_layout[0].stride)

        alias threads_layout_shape = flatten(threads_layout.shape)
        alias threads_layout_stride = flatten(threads_layout.stride)

        var offset = 0

        @parameter
        fn compute_offset[i: Int]():
            alias shape_i = int(threads_layout_shape[i])
            alias stride_i = int(threads_layout_stride[i])
            var coords_i = (thread_id // stride_i) % shape_i
            alias fragments_stride_i = int(fragments_layout_stride[i])
            offset += coords_i * fragments_stride_i

        unroll[compute_offset, len(fragments_layout_stride)]()

        return LayoutTensor[tiled_layout[1], dtype, address_space](
            self.ptr.offset(offset)
        )

    @always_inline
    fn transpose[
        M: Int = Self.dim[0](),
        N: Int = Self.dim[1](),
        transposed_layout: Layout = composition(
            layout,
            Layout(IntTuple(N, M), IntTuple(M, 1)),
        ),
    ](self) -> LayoutTensor[transposed_layout, dtype, address_space]:
        return LayoutTensor[transposed_layout, dtype, address_space](self.ptr)

    @always_inline
    fn reshape[
        dst_layout: Layout,
        reshaped_layout: Layout = composition(layout, dst_layout),
    ](self) -> LayoutTensor[reshaped_layout, dtype, address_space]:
        return LayoutTensor[reshaped_layout, dtype, address_space](self.ptr)

    @always_inline
    fn copy_from[
        other_layout: Layout
    ](self, other: LayoutTensor[other_layout, dtype, address_space]):
        for m in range(Self.dim[0]()):

            @parameter
            if (
                int(self.layout.stride[1]) <= 1
                and int(other.layout.stride[1]) <= 1
                and not triple_is_nvidia_cuda()
            ):
                # Optimize copy for row major layouts.
                memcpy(
                    self.ptr.offset(self._offset(m, 0)),
                    other.ptr.offset(other._offset(m, 0)),
                    Self.dim[1](),
                )
            else:
                for n in range(Self.dim[1]()):
                    self[m, n] = other[m, n]

    # When source and destination address spaces differ
    @always_inline
    fn copy_from_numa[
        other_layout: Layout, other_addr_space: AddressSpace
    ](
        self,
        other: LayoutTensor[
            other_layout, dtype, address_space=other_addr_space
        ],
    ):
        @parameter
        fn copy_element[i: Int]():
            alias src_idx = other_layout(i)
            alias dst_idx = self.layout(i)
            self.ptr[dst_idx] = other.ptr[src_idx]

        alias dst_size = layout.size()
        alias src_size = other_layout.size()

        constrained[
            dst_size == src_size, "copy_from should move data of the same size"
        ]()

        unroll[copy_element, dst_size]()

    @always_inline
    fn copy_from_async[
        src_layout: Layout, src_addr_space: AddressSpace
    ](
        self,
        src: LayoutTensor[src_layout, dtype, address_space=src_addr_space],
    ):
        constrained[
            self.address_space == AddressSpace.SHARED,
            "Async is only supported for destinations in shared memory",
        ]()

        @parameter
        fn copy_element[i: Int]():
            alias src_idx = src_layout(i)
            alias dst_idx = self.layout(i)

            var dst_ptr = self.ptr.address_space_cast[
                AddressSpace.SHARED
            ]() + dst_idx
            var src_ptr = src.ptr.address_space_cast[
                AddressSpace.GLOBAL
            ]() + src_idx
            async_copy[4](src_ptr, dst_ptr)

        alias dst_size = layout.size()
        alias src_size = src_layout.size()

        constrained[
            dst_size == src_size, "copy_from should move data of the same size"
        ]()

        unroll[copy_element, dst_size]()

    fn linspace(self):
        for m in range(Self.dim[0]()):
            for n in range(Self.dim[1]()):
                self[m, n] = m * Self.dim[1]() + n

    fn fill(self, val: Scalar[dtype]):
        for m in range(Self.dim[0]()):
            for n in range(Self.dim[1]()):
                self[m, n] = val

    fn print(self):
        for m in range(Self.dim[0]()):
            for n in range(Self.dim[1]()):
                print_no_newline(self[m, n], "  ")
            print("")


struct TensorBuilder[
    M: Int,
    N: Int,
    dtype: DType,
    layout: Layout = Layout(IntTuple(M, N), IntTuple(N, 1)),
]:
    alias Type = LayoutTensor[layout, dtype]
    alias AlignedType = LayoutTensor[Self._aligned_layout(), dtype]

    @staticmethod
    fn Wrap(ptr: DTypePointer[dtype]) -> Self.Type:
        return Self.Type(ptr)

    @staticmethod
    fn Build() -> Self.Type:
        return Self.Type(
            DTypePointer[dtype].alloc(M * N, alignment=alignof[SIMD[dtype]]()),
            owning=True,
        )

    @staticmethod
    fn OnStack() -> Self.Type:
        return Self.Type.stack_allocation()

    @staticmethod
    fn OnStackAligned[alignment: Int]() -> Self.Type:
        return Self.Type.aligned_stack_allocation[alignment]()

    @staticmethod
    fn _aligned_layout() -> Layout:
        alias alignment = alignof[SIMD[dtype]]()
        alias n_aligned = ((N + alignment - 1) // alignment) * alignment
        alias data_layout = Layout(
            IntTuple(M, n_aligned), IntTuple(n_aligned, 1)
        )
        return LayoutTensor[data_layout, dtype]._compute_tile_layout[M, N]()[0]

    @staticmethod
    fn BuildAligned[
        *, __target_layout: Layout = Self._aligned_layout()
    ]() -> LayoutTensor[__target_layout, dtype]:
        var ptr = DTypePointer[dtype].alloc(
            M * int(__target_layout.stride[0]), alignment=alignof[SIMD[dtype]]()
        )
        return LayoutTensor[__target_layout, dtype](ptr, owning=True)


fn stack_allocation_like[
    layout: Layout,
    dtype: DType,
    address_space: AddressSpace,
    target_address_space: AddressSpace = AddressSpace.GENERIC,
](in_tensor: LayoutTensor[layout, dtype, address_space]) -> LayoutTensor[
    layout, dtype, target_address_space
]:
    return LayoutTensor[layout, dtype, target_address_space].stack_allocation()
