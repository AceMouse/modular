# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo-no-debug %s

import time
from math import floor
from sys import sizeof

from buffer import Buffer, NDBuffer
from buffer.dimlist import DimList
from gpu.all_reduce import MAX_GPUS, Signal, all_reduce
from gpu.host import DeviceBuffer, DeviceContext
from internal_utils import DeviceNDBuffer, HostNDBuffer, TestTensor
from memory import UnsafePointer
from testing import assert_almost_equal

from utils.index import IndexList, StaticTuple


fn _pretty_print_float(val: Float64) -> String:
    """This converts the float value to a string, but omits the fractional part
    if not needed (e.g. prints 2 instead of 2.0).
    """
    if Float64(floor(val)) == val:
        return str(int(val))
    return str(val)


fn _human_memory(size: Int) -> String:
    alias KB = 1024
    alias MB = KB * KB
    alias GB = MB * KB

    if size >= GB:
        return _pretty_print_float(Float64(size) / GB) + "GB"

    if size >= MB:
        return _pretty_print_float(Float64(size) / MB) + "MB"

    if size >= KB:
        return _pretty_print_float(Float64(size) / KB) + "KB"

    return str(size) + "B"


fn all_reduce_test[
    type: DType, rank: Int, ngpus: Int
](list_of_ctx: List[DeviceContext], length: Int) raises:
    constrained[ngpus in (1, 2, 4, 8), "ngpus must be 1, 2, 4, or 8"]()

    # Create device buffers for all GPUs
    var in_bufs_list = List[DeviceBuffer[type]](capacity=ngpus)
    var out_bufs_list = List[DeviceBuffer[type]](capacity=ngpus)
    var host_buffers = List[UnsafePointer[Scalar[type]]](capacity=ngpus)

    # Create signal buffers for synchronization
    var sig_bufs = List[DeviceBuffer[DType.uint8]](capacity=ngpus)
    var rank_sigs = StaticTuple[UnsafePointer[Signal], MAX_GPUS]()

    # Initialize buffers for each GPU
    @parameter
    for i in range(ngpus):
        # Create and store device buffers
        in_bufs_list.append(list_of_ctx[i].create_buffer_sync[type](length))
        out_bufs_list.append(list_of_ctx[i].create_buffer_sync[type](length))

        # Create and initialize host buffers
        var host_buffer = UnsafePointer[Scalar[type]].alloc(length)
        host_buffers.append(host_buffer)

        # Initialize host buffer with values (i + 1).0
        var host_nd_buf = NDBuffer[type, rank](host_buffer, DimList(length))
        host_nd_buf.fill(Scalar[type](i + 1))

        # Create and initialize signal buffers
        sig_bufs.append(
            list_of_ctx[i].create_buffer_sync[DType.uint8](sizeof[Signal]())
        )
        list_of_ctx[i].memset_sync[DType.uint8](sig_bufs[i], 0)
        rank_sigs[i] = sig_bufs[i].ptr.bitcast[Signal]()

        # Copy data to device
        list_of_ctx[i].enqueue_copy_to_device(in_bufs_list[i], host_buffers[i])

    # Create StaticTuples for input and output buffers
    var in_bufs = StaticTuple[NDBuffer[type, rank], ngpus]()
    var out_bufs = StaticTuple[NDBuffer[type, rank], ngpus]()

    for i in range(ngpus):
        in_bufs[i] = NDBuffer[type, rank](in_bufs_list[i].ptr, DimList(length))
        out_bufs[i] = NDBuffer[type, rank](
            out_bufs_list[i].ptr, DimList(length)
        )

    # Perform all_reduce
    start_t = time.perf_counter_ns()
    all_reduce(list_of_ctx, in_bufs, out_bufs, rank_sigs)

    # Synchronize all devices
    @parameter
    for i in range(ngpus):
        list_of_ctx[i].synchronize()
    end_t = time.perf_counter_ns()
    # Quick and dirty benchmark since benchmark module doesn't support multi-device contexts
    print("Time taken (ms):", (end_t - start_t) / 1_000_000)

    # Copy results back and verify
    var expected_sum = Scalar[type](0)

    @parameter
    for i in range(ngpus):
        expected_sum += i + 1
        list_of_ctx[i].enqueue_copy_from_device(
            host_buffers[i], out_bufs_list[i]
        )

    # Verify results
    @parameter
    for i in range(ngpus):
        for j in range(length):
            try:
                assert_almost_equal(host_buffers[i][j], expected_sum)
            except e:
                print("Verification failed at GPU", i, "index", j)
                print("Value:", host_buffers[i][j])
                print("Expected:", expected_sum)
                raise e

    # Cleanup
    for i in range(ngpus):
        host_buffers[i].free()
    _ = sig_bufs^


fn _get_test_str(type: DType, ngpus: Int, length: Int) -> String:
    return (
        "====allreduce-"
        + str(type)
        + "-"
        + str(ngpus)
        + "-"
        + _human_memory(length)
    )


def main():
    # Test configurations
    alias length = 256 * 1024
    alias rank = 1

    # Test with 2 GPUs
    var device_count = DeviceContext.number_of_devices()
    if device_count >= 2:
        var ctx2 = List[DeviceContext](
            DeviceContext(device_id=0), DeviceContext(device_id=1)
        )
        print(_get_test_str(DType.bfloat16, 2, length))
        all_reduce_test[DType.bfloat16, rank, 2](ctx2, length)
        print(_get_test_str(DType.float32, 2, length))
        all_reduce_test[DType.float32, rank, 2](ctx2, length)

    # Test with 4 GPUs if available
    if device_count >= 4:
        var ctx4 = List[DeviceContext]()
        for i in range(4):
            ctx4.append(DeviceContext(device_id=i))

        print(_get_test_str(DType.bfloat16, 4, length))
        all_reduce_test[DType.bfloat16, rank, 4](ctx4, length)
        print(_get_test_str(DType.float32, 4, length))
        all_reduce_test[DType.float32, rank, 4](ctx4, length)

    # Test with 8 GPUs if available
    if device_count >= 8:
        var ctx8 = List[DeviceContext]()
        for i in range(8):
            ctx8.append(DeviceContext(device_id=i))
        print(_get_test_str(DType.bfloat16, 8, length))
        all_reduce_test[DType.bfloat16, rank, 8](ctx8, length)
        print(_get_test_str(DType.float32, 8, length))
        all_reduce_test[DType.float32, rank, 8](ctx8, length)
