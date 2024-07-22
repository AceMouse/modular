# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo %s | FileCheck %s

from gpu.host import DeviceContext, FuncAttribute
from gpu.id import ThreadIdx
from gpu.memory import dynamic_shared_memory
from gpu.sync import barrier


# CHECK-LABEL: test_dynamic_shared_mem
fn test_dynamic_shared_mem(ctx: DeviceContext) raises:
    print("== test_dynamic_shared_mem")

    fn dynamc_smem_kernel(data: UnsafePointer[Float32]):
        var dynamic_sram = dynamic_shared_memory[Float32, alignment=4]()
        dynamic_sram[ThreadIdx.x()] = ThreadIdx.x()
        barrier()
        data[ThreadIdx.x()] = dynamic_sram[ThreadIdx.x()]

    # The default limitation is < 48KB for sm_80, 86, 89.
    var func = ctx.compile_function[dynamc_smem_kernel](
        func_attribute=FuncAttribute.MAX_DYNAMIC_SHARED_SIZE_BYTES(64 * 1024),
    )

    var res_host_ptr = UnsafePointer[Float32].alloc(16)
    var res_device = ctx.create_buffer[DType.float32](16)

    for i in range(16):
        res_host_ptr[i] = 0

    ctx.enqueue_copy_to_device(res_device, res_host_ptr)

    ctx.enqueue_function(
        func,
        res_device,
        grid_dim=(1),
        block_dim=(16),
        shared_mem_bytes=64 * 1024,
    )

    ctx.enqueue_copy_from_device(res_host_ptr, res_device)

    # CHECK: 0.0
    # CHECK: 1.0
    # CHECK: 2.0
    # CHECK: 3.0
    # CHECK: 4.0
    # CHECK: 5.0
    # CHECK: 6.0
    # CHECK: 7.0
    # CHECK: 8.0
    # CHECK: 9.0
    # CHECK: 10.0
    # CHECK: 11.0
    # CHECK: 12.0
    # CHECK: 13.0
    # CHECK: 14.0
    # CHECK: 15.0
    for i in range(16):
        print(res_host_ptr[i])

    _ = res_device
    res_host_ptr.free()


fn main() raises:
    try:
        with DeviceContext() as ctx:
            test_dynamic_shared_mem(ctx)
    except e:
        print("CUDA_ERROR:", e)
