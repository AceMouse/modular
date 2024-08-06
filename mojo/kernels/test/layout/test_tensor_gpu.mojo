# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo %s | FileCheck %s

from layout.layout_tensor import LayoutTensor, Layout
from layout._utils import ManagedLayoutGPUTensor

from gpu.host.device_context import DeviceContext
from gpu.memory import (
    _GPUAddressSpace,
    async_copy_commit_group,
    async_copy_wait_group,
)
from gpu import BlockIdx, GridDim, ThreadIdx, barrier
from testing import assert_true
from builtin.io import _printf


# CHECK-LABEL: test_copy_dram_to_sram_async
def test_copy_dram_to_sram_async(ctx: DeviceContext):
    print("== test_copy_dram_to_sram_async")
    alias tensor_layout = Layout.row_major(4, 16)
    var tensor = ManagedLayoutGPUTensor[DType.float32, tensor_layout]()
    tensor.tensor.linspace()

    var check_state = True

    fn copy_to_sram_test_kernel[
        layout: Layout,
    ](
        dram_tensor: LayoutTensor[DType.float32, layout],
        flag: UnsafePointer[Bool],
    ):
        var dram_tile = dram_tensor.tile[4, 4](0, BlockIdx.x())
        var sram_tensor = LayoutTensor[
            DType.float32,
            Layout.row_major(4, 4),
            address_space = _GPUAddressSpace.SHARED,
        ].stack_allocation()
        sram_tensor.copy_from_async(dram_tile)

        async_copy_commit_group()
        async_copy_wait_group(0)

        var col_offset = BlockIdx.x() * 4

        for r in range(4):
            for c in range(4):
                if sram_tensor[r, c] != r * 16 + col_offset + c:
                    flag[] = False

    var copy_to_sram_test_launch = ctx.compile_function[
        copy_to_sram_test_kernel[tensor_layout]
    ]()

    ctx.enqueue_function(
        copy_to_sram_test_launch,
        tensor.tensor,
        UnsafePointer.address_of(check_state),
        grid_dim=(4),
        block_dim=(1),
    )
    assert_true(check_state, "Inconsistent values in shared memory")


# CHECK-LABEL: test_copy_from_async_masked_src
def test_copy_from_async_masked_src(ctx: DeviceContext):
    print("== test_copy_from_async_masked_src")
    alias tensor_layout = Layout.row_major(31, 32)
    var tensor = ManagedLayoutGPUTensor[DType.int32, tensor_layout]()
    tensor.tensor.linspace()

    var check_state = True

    fn copy_to_sram_masked_src_test_kernel[
        layout: Layout,
    ](
        dram_tensor: LayoutTensor[DType.int32, layout],
        flag: UnsafePointer[Bool],
    ):
        var dram_tile = dram_tensor.tile[16, 16](BlockIdx.y(), BlockIdx.x())
        var smem_tensor = LayoutTensor[
            DType.int32,
            Layout.row_major(16, 16),
            address_space = _GPUAddressSpace.SHARED,
        ].stack_allocation()

        alias thrd_layout = Layout.row_major(8, 8)
        var smem_frag = smem_tensor.distribute[thrd_layout](ThreadIdx.x())

        # Zero Init
        smem_frag.fill(0)
        barrier()

        var dram_frag = dram_tile.distribute[thrd_layout](ThreadIdx.x())
        var offset = dram_frag.distance(dram_tensor.ptr)
        smem_frag.copy_from_async_masked_src(dram_frag, offset, 31, 32)

        async_copy_commit_group()
        async_copy_wait_group(0)

        var row_offset = BlockIdx.y() * 16
        var col_offset = BlockIdx.x() * 16

        if ThreadIdx.x() == 0:
            for sub_r in range(16):
                for sub_c in range(16):
                    var row_id = row_offset + sub_r
                    var col_id = col_offset + sub_c
                    if (
                        row_id < 31
                        and smem_tensor[sub_r, sub_c] != row_id * 32 + col_id
                    ):
                        flag[] = False

        barrier()

    var copy_to_sram_test_launch = ctx.compile_function[
        copy_to_sram_masked_src_test_kernel[tensor_layout]
    ]()

    ctx.enqueue_function(
        copy_to_sram_test_launch,
        tensor.tensor,
        UnsafePointer.address_of(check_state),
        grid_dim=(2, 2, 1),
        block_dim=(64, 1, 1),
    )
    assert_true(check_state, "Shared memory value mismatches")


def main():
    with DeviceContext() as ctx:
        test_copy_dram_to_sram_async(ctx)
        test_copy_from_async_masked_src(ctx)
