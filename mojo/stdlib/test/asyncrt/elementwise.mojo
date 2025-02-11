# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

# COM: Note: CPU function compilation not supported
# COM: %mojo-no-debug -D MODULAR_ASYNCRT_DEVICE_CONTEXT_V2=cpu %s
# RUN: %mojo-no-debug -D MODULAR_ASYNCRT_DEVICE_CONTEXT_V2=gpu %s


from sys import simdwidthof

from algorithm.functional import elementwise
from asyncrt_test_utils import create_test_device_context, expect_eq
from buffer import NDBuffer
from gpu import *
from gpu.host import DeviceContext
from gpu.host._compile import _get_gpu_target

from utils import IndexList
from utils.index import Index


fn run_elementwise[type: DType](ctx: DeviceContext) raises:
    print("-")
    print("run_elementwise[", type, "]:")

    alias pack_size = simdwidthof[type, target = _get_gpu_target()]()

    alias rank = 2
    alias dim_x = 2
    alias dim_y = 8
    alias length = dim_x * dim_y

    var in_host = ctx.enqueue_create_host_buffer[type](length)
    var out_host = ctx.enqueue_create_host_buffer[type](length)
    var in_dev = ctx.enqueue_create_buffer[type](length)
    var out_dev = ctx.enqueue_create_buffer[type](length)

    # Initialize the input and outputs with known values.
    for i in range(length):
        in_host[i] = i
        out_host[i] = length + i

    # Copy to device buffers.
    in_host.enqueue_copy_to(in_dev)
    # Write known bad values to out_dev.
    out_host.enqueue_copy_to(out_dev)

    var in_buffer = NDBuffer[type, 2](
        in_dev.unsafe_pointer(), Index(dim_x, dim_y)
    )
    var out_buffer = NDBuffer[type, 2](
        out_dev.unsafe_pointer(), Index(dim_x, dim_y)
    )

    @always_inline
    @__copy_capture(in_buffer, out_buffer)
    @parameter
    fn func[simd_width: Int, rank: Int](idx0: IndexList[rank]):
        var idx = rebind[IndexList[2]](idx0)
        out_buffer.store(
            idx,
            in_buffer.load[width=simd_width](idx) + 42,
        )

    elementwise[func, pack_size, target="gpu"](
        IndexList[2](2, 8),
        ctx,
    )

    out_dev.enqueue_copy_to(out_host)

    # Wait for the copies to be completed.
    ctx.synchronize()

    for i in range(length):
        if i < 10:
            print("at index", i, "the value is", out_host[i])
        expect_eq(
            out_host[i], i + 42, "at index ", i, " the value is ", out_host[i]
        )


fn main() raises:
    var ctx = create_test_device_context()
    print("-------")
    # TODO(iposva): Reenable printing of name.
    # print("Running test_elementwise(" + ctx.name() + "):")
    print("Running test_elementwise(DeviceContext):")

    run_elementwise[DType.float32](ctx)
    run_elementwise[DType.bfloat16](ctx)
    run_elementwise[DType.float16](ctx)
    run_elementwise[DType.int8](ctx)

    print("Done.")
