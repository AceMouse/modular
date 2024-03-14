# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo %s

from math import exp
from sys.info import triple_is_nvidia_cuda

from algorithm.functional import _elementwise_impl
from gpu import *
from gpu.host import Context, Dim, Function, Stream
from gpu.host._compile import _get_nvptx_target
from benchmark.cuda import run
from gpu.host.memory import (
    _copy_device_to_host,
    _copy_host_to_device,
    _free,
    _malloc,
    _memset,
)
from gpu.host.sync import synchronize
from closed_source_memory.buffer import NDBuffer
from tensor import Tensor
from testing import assert_equal

from utils.index import Index


# CHECK-LABEL: run_elementwise
fn run_elementwise[type: DType]() raises:
    alias pack_size = simdwidthof[type, target = _get_nvptx_target()]()

    var in_host = Tensor[type](2, 8)
    var out_host = Tensor[type](2, 8)

    var flattened_length = in_host.num_elements()
    for i in range(2):
        for j in range(8):
            in_host[Index(i, j)] = i + j

    var in_device = _malloc[type](flattened_length)
    var out_device = _malloc[type](flattened_length)

    _copy_host_to_device(in_device, in_host.data(), flattened_length)

    var in_buffer = NDBuffer[type, 2](in_device, Index(2, 8))
    var out_buffer = NDBuffer[type, 2](out_device, Index(2, 8))

    @always_inline
    @__copy_capture(in_buffer, out_buffer)
    @parameter
    fn func[simd_width: Int, rank: Int](idx0: StaticIntTuple[rank]):
        var idx = rebind[StaticIntTuple[2]](idx0)

        @parameter
        if simd_width == 1:
            alias alignment = alignof[SIMD[type, pack_size]]()
            out_buffer.aligned_simd_store[simd_width, alignment](
                idx,
                in_buffer.aligned_simd_load[simd_width, alignment](idx) + 42,
            )
        else:
            out_buffer.simd_store[simd_width](
                idx,
                in_buffer.load[simd_width](idx) + 42,
            )

    _elementwise_impl[func, pack_size, 2, True, target="cuda"](
        StaticIntTuple[2](2, 8),
    )
    synchronize()

    _copy_device_to_host(out_host.data(), out_device, flattened_length)

    var expected_vals = List[Scalar[type]](
        42.0,
        43.0,
        44.0,
        45.0,
        46.0,
        47.0,
        48.0,
        49.0,
        43.0,
        44.0,
        45.0,
        46.0,
        47.0,
        48.0,
        49.0,
        50.0,
    )
    for i in range(2):
        for j in range(8):
            assert_equal(
                out_host[Index(i, j)],
                expected_vals[i * 8 + j],
            )

    _ = in_host ^
    _ = out_host ^

    _free(in_device)
    _free(out_device)


# CHECK-LABEL: run_elementwise_uneven_simd
fn run_elementwise_uneven_simd[type: DType]() raises:
    alias pack_size = simdwidthof[type, target = _get_nvptx_target()]()
    var in_host = Tensor[type](3, 3)
    var out_host = Tensor[type](3, 3)

    var flattened_length = in_host.num_elements()
    for i in range(3):
        for j in range(3):
            in_host[Index(i, j)] = i + j

    var in_device = _malloc[type](flattened_length)
    var out_device = _malloc[type](flattened_length)

    _copy_host_to_device(in_device, in_host.data(), flattened_length)

    var in_buffer = NDBuffer[type, 2](in_device, Index(3, 3))
    var out_buffer = NDBuffer[type, 2](out_device, Index(3, 3))

    @always_inline
    @__copy_capture(in_buffer, out_buffer)
    @parameter
    fn func[simd_width: Int, rank: Int](idx0: StaticIntTuple[rank]):
        var idx = rebind[StaticIntTuple[2]](idx0)

        @parameter
        if simd_width == 1:
            alias alignment = alignof[SIMD[type, pack_size]]()
            out_buffer.aligned_simd_store[simd_width, alignment](
                idx,
                in_buffer.aligned_simd_load[simd_width, alignment](idx) + 42,
            )
        else:
            out_buffer.simd_store[simd_width](
                idx,
                in_buffer.load[simd_width](idx) + 42,
            )

    _elementwise_impl[func, pack_size, 2, True, target="cuda"](
        StaticIntTuple[2](3, 3),
    )
    synchronize()
    _copy_device_to_host(out_host.data(), out_device, flattened_length)

    var expected_vals = List[Scalar[type]](
        42.0, 43.0, 44.0, 43.0, 44.0, 45.0, 44.0, 45.0, 46.0
    )
    for i in range(3):
        for j in range(3):
            assert_equal(
                out_host[Index(i, j)],
                expected_vals[i * 3 + j],
            )

    _ = in_host ^
    _ = out_host ^

    _free(in_device)
    _free(out_device)


fn run_elementwise_transpose_copy[type: DType]() raises:
    alias pack_size = simdwidthof[type, target = _get_nvptx_target()]()
    var in_host = Tensor[type](2, 4, 5)
    var out_host = Tensor[type](4, 2, 5)

    var flattened_length = in_host.num_elements()
    for i in range(2):
        for j in range(4):
            for k in range(5):
                in_host[Index(i, j, k)] = i * 4 * 5 + j * 5 + k

    var in_device = _malloc[type](flattened_length)
    var out_device = _malloc[type](flattened_length)

    _copy_host_to_device(in_device, in_host.data(), flattened_length)

    var in_buffer_transposed = NDBuffer[type, 3](
        in_device, Index(4, 2, 5), Index(5, 20, 1)
    )
    var out_buffer = NDBuffer[type, 3](out_device, Index(4, 2, 5))

    @always_inline
    @__copy_capture(in_buffer_transposed, out_buffer)
    @parameter
    fn func[simd_width: Int, rank: Int](idx0: StaticIntTuple[rank]):
        var idx = rebind[StaticIntTuple[3]](idx0)

        out_buffer.simd_store[simd_width](
            idx, in_buffer_transposed.load[width=simd_width](idx)
        )

    _elementwise_impl[func, 4, 3, True, target="cuda"](
        StaticIntTuple[3](4, 2, 5),
    )
    synchronize()
    _copy_device_to_host(out_host.data(), out_device, flattened_length)

    var expected_vals = List[Scalar[type]](
        0.0,
        1.0,
        2.0,
        3.0,
        4.0,
        20.0,
        21.0,
        22.0,
        23.0,
        24.0,
        5.0,
        6.0,
        7.0,
        8.0,
        9.0,
        25.0,
        26.0,
        27.0,
        28.0,
        29.0,
        10.0,
        11.0,
        12.0,
        13.0,
        14.0,
        30.0,
        31.0,
        32.0,
        33.0,
        34.0,
        15.0,
        16.0,
        17.0,
        18.0,
        19.0,
        35.0,
        36.0,
        37.0,
        38.0,
        39.0,
    )
    for i in range(4):
        for j in range(2):
            for k in range(5):
                assert_equal(
                    out_host[Index(i, j, k)],
                    expected_vals[i * 2 * 5 + j * 5 + k],
                )

    _ = in_host ^
    _ = out_host ^

    _free(in_device)
    _free(out_device)


fn main() raises:
    with Context() as ctx:
        run_elementwise[DType.float32]()
        run_elementwise_uneven_simd[DType.float32]()
        run_elementwise_transpose_copy[DType.float32]()
        run_elementwise[DType.bfloat16]()
        run_elementwise_uneven_simd[DType.bfloat16]()
        run_elementwise_transpose_copy[DType.bfloat16]()
