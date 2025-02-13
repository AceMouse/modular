# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: H100-GPU
# RUN: %mojo-no-debug-no-assert %s

from sys import sizeof

from gpu import barrier
from gpu.host import DeviceContext
from gpu.host._compile import _get_gpu_target
from gpu.host._nvidia_cuda import TensorMapSwizzle
from gpu.id import block_idx, thread_idx
from layout import Layout, LayoutTensor
from layout._utils import ManagedLayoutTensor
from layout.fillers import arange
from layout.swizzle import make_swizzle
from layout.tma_async import TMABarrier, TMATensorTile, create_tma_tile
from memory.pointer import _GPUAddressSpace
from testing import assert_equal

from utils.index import Index, IndexList
from utils.static_tuple import StaticTuple


# Test loading a single 2d tile.
@__llvm_metadata(`nvvm.grid_constant`=StaticTuple[Int, 1](1))
fn tma_swizzle_load_kernel[
    dtype: DType,
    layout: Layout,
    tile_layout: Layout,
    desc_layout: Layout,
](
    dst: LayoutTensor[dtype, layout],
    tma_tile: TMATensorTile[dtype, tile_layout, desc_layout],
):
    alias tileM = tile_layout.shape[0].value()
    alias tileN = tile_layout.shape[1].value()
    alias expected_bytes = tile_layout.size() * sizeof[dtype]()

    tile = LayoutTensor[
        dtype,
        tile_layout,
        address_space = _GPUAddressSpace.SHARED,
        alignment=128,
    ].stack_allocation()

    mbar = TMABarrier()

    if thread_idx.x == 0:
        mbar.init()
        mbar.expect_bytes(expected_bytes)
        tma_tile.async_copy(
            tile, mbar, (block_idx.x * tileN, block_idx.y * tileM)
        )
    # Ensure all threads sees initialized mbarrier
    barrier()
    mbar.wait()

    dst_tile = dst.tile[tileM, tileN](block_idx.y, block_idx.x)

    if thread_idx.x == 0:
        dst_tile.copy_from(tile)


def test_tma_swizzle[
    type: DType,
    shape: IndexList[2],
    tile_shape: IndexList[2],
    swizzle_mode: TensorMapSwizzle = TensorMapSwizzle.SWIZZLE_NONE,
    is_k_major: Bool = True,
](ctx: DeviceContext):
    constrained[
        shape == tile_shape, "Only support same shape and tile shape."
    ]()

    alias layout = Layout.row_major(shape[0], shape[1])
    var src = ManagedLayoutTensor[type, layout](ctx)
    var dst = ManagedLayoutTensor[type, layout](ctx)

    arange(src.tensor[update=False](), 0)
    arange(dst.tensor[update=False](), 0)
    var tma_tensor = create_tma_tile[
        type,
        2,
        tile_shape,
        swizzle_mode=swizzle_mode,
        is_k_major=is_k_major,
    ](ctx, src.device_tensor())

    # print test info
    alias use_multiple_loads = (
        tma_tensor.layout.size() > tma_tensor.desc_layout.size()
    )
    alias test_name = "test " + String(type) + (
        " multiple " if use_multiple_loads else " single "
    ) + "tma w/ " + String(swizzle_mode) + " k-major " + String(is_k_major)
    print(test_name)

    # Descriptor tile is the copy per tma instruction. One load could have multiple tma copies.
    alias descM = __type_of(tma_tensor).desc_layout.shape[0].value()
    alias descN = __type_of(tma_tensor).desc_layout.shape[1].value()
    alias desc_tile_size = descM * descN
    desc_tile = LayoutTensor[
        type, __type_of(tma_tensor).desc_layout
    ].stack_allocation()

    alias kernel = tma_swizzle_load_kernel[
        __type_of(tma_tensor).dtype,
        layout,
        __type_of(tma_tensor).layout,
        __type_of(tma_tensor).desc_layout,
    ]
    ctx.enqueue_function[kernel](
        dst.device_tensor(),
        tma_tensor,
        grid_dim=(shape[1] // tile_shape[1], shape[0] // tile_shape[0]),
        block_dim=(1),
    )

    src_host = src.tensor()
    dst_host = dst.tensor()

    alias swizzle = make_swizzle[type, swizzle_mode]()

    dst_tile_ptr = dst_host.ptr
    for desc_tile_m in range(shape[0] // descM):
        for desc_tile_n in range(shape[1] // descN):
            desc_tile.copy_from(
                src_host.tile[descM, descN](desc_tile_m, desc_tile_n)
            )
            for i in range(desc_tile_size):
                desc_idx = swizzle(i)
                if desc_tile.ptr[desc_idx] != dst_tile_ptr[i]:
                    print(
                        desc_tile_m,
                        desc_tile_n,
                        desc_tile.ptr[desc_idx],
                        dst_tile_ptr[i],
                    )
                    break
            dst_tile_ptr += desc_tile_size

    _ = src^
    _ = dst^


def main():
    with DeviceContext() as ctx:
        test_tma_swizzle[
            DType.bfloat16,
            shape = Index(8, 64),
            tile_shape = Index(8, 64),
            swizzle_mode = TensorMapSwizzle.SWIZZLE_128B,
        ](ctx)

        test_tma_swizzle[
            DType.bfloat16,
            shape = Index(8, 128),
            tile_shape = Index(8, 128),
            swizzle_mode = TensorMapSwizzle.SWIZZLE_128B,
        ](ctx)

        test_tma_swizzle[
            DType.bfloat16,
            shape = Index(8, 32),
            tile_shape = Index(8, 32),
            swizzle_mode = TensorMapSwizzle.SWIZZLE_64B,
        ](ctx)

        test_tma_swizzle[
            DType.bfloat16,
            shape = Index(8, 64),
            tile_shape = Index(8, 64),
            swizzle_mode = TensorMapSwizzle.SWIZZLE_64B,
        ](ctx)

        test_tma_swizzle[
            DType.bfloat16,
            shape = Index(8, 16),
            tile_shape = Index(8, 16),
            swizzle_mode = TensorMapSwizzle.SWIZZLE_32B,
        ](ctx)

        test_tma_swizzle[
            DType.bfloat16,
            shape = Index(8, 32),
            tile_shape = Index(8, 32),
            swizzle_mode = TensorMapSwizzle.SWIZZLE_32B,
        ](ctx)

        test_tma_swizzle[
            DType.bfloat16,
            shape = Index(8, 16),
            tile_shape = Index(8, 16),
            swizzle_mode = TensorMapSwizzle.SWIZZLE_NONE,
        ](ctx)

        test_tma_swizzle[
            DType.bfloat16,
            shape = Index(8, 32),
            tile_shape = Index(8, 32),
            swizzle_mode = TensorMapSwizzle.SWIZZLE_NONE,
        ](ctx)

        test_tma_swizzle[
            DType.bfloat16,
            shape = Index(16, 64),
            tile_shape = Index(16, 64),
            swizzle_mode = TensorMapSwizzle.SWIZZLE_128B,
            is_k_major=False,
        ](ctx)

        test_tma_swizzle[
            DType.bfloat16,
            shape = Index(16, 128),
            tile_shape = Index(16, 128),
            swizzle_mode = TensorMapSwizzle.SWIZZLE_128B,
            is_k_major=False,
        ](ctx)
