# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo-no-debug %s -t

from algorithm._gpu.reduction import reduce_launch
from buffer import NDBuffer
from gpu.host.device_context import DeviceContext
from gpu.host._compile import _get_nvptx_target
from testing import assert_equal
from benchmark import Bench, Bencher, BenchId, BenchMetric, ThroughputMeasure

from utils import StaticIntTuple, StaticTuple
from utils.index import product
from internal_utils import DeviceNDBuffer
from buffer.dimlist import DimList, _make_tuple


fn alignof_simd[type: DType, simd_target: __mlir_type.`!kgen.target`]() -> Int:
    # TODO: move this utility function to a module.
    alias pack_size = simdwidthof[type, target=simd_target]()
    return alignof[SIMD[type, pack_size]]()


fn run_reduce[
    reduce_fn: fn[type: DType, width: Int] (
        SIMD[type, width], SIMD[type, width]
    ) capturing -> SIMD[type, width],
    type: DType,
    rank: Int,
    num_reductions: Int = 1,
](inout m: Bench, shape: StaticIntTuple[rank], ctx: DeviceContext,) raises:
    print("run_reduce", shape)
    var axis = rank - 1
    var out_shape = shape
    out_shape[axis] = 1
    alias init: Scalar[type] = Scalar[type](0.0)

    var in_size = shape.flattened_length()
    var out_size = product(shape, rank - 1)

    alias align = alignof_simd[type, simd_target = _get_nvptx_target()]()
    var expected_vals = DTypePointer[type].alloc(out_size, alignment=align)

    var in_host = DTypePointer[type].alloc(in_size)
    var res_host = DTypePointer[type].alloc(out_size)

    for i in range(in_size):
        in_host[i] = (i // shape[axis]) + 1

    # TODO: use reduce_fn to make this generic.
    for i in range(out_size):
        expected_vals[i] = shape[axis] * Scalar[type](i + 1)

    var vec_device = DeviceNDBuffer[type, rank](shape, ctx=ctx)
    var res_device = DeviceNDBuffer[type, rank](out_shape, ctx=ctx)
    var input_buf_device = vec_device.tensor
    var output_buf_device = res_device.tensor

    ctx.enqueue_copy_to_device(vec_device.buffer, in_host)

    @always_inline
    @parameter
    fn reduce_wrapper[
        type: DType, width: Int, reduction_idx: Int
    ](lhs: SIMD[type, width], rhs: SIMD[type, width]) -> SIMD[type, width]:
        constrained[reduction_idx < num_reductions, "invalid reduction idx"]()

        return reduce_fn[type, width](lhs, rhs)

    @__copy_capture(input_buf_device)
    @parameter
    fn input_fn[
        type: DType,
        width: Int,
        _rank: Int,
    ](coords: StaticIntTuple[_rank]) -> SIMD[type, width]:
        return rebind[SIMD[type, width]](
            input_buf_device.load[width=width](
                rebind[StaticIntTuple[rank]](coords)
            )
        )

    @__copy_capture(output_buf_device)
    @parameter
    fn output_fn[
        _type: DType, width: Int, _rank: Int
    ](
        coords: StaticIntTuple[_rank],
        val: StaticTuple[SIMD[_type, width], num_reductions],
    ):
        output_buf_device[rebind[StaticIntTuple[rank]](coords)] = rebind[
            Scalar[type]
        ](val[0])

    @__copy_capture(axis)
    @parameter
    @always_inline
    fn bench_func(inout b: Bencher):
        @parameter
        @always_inline
        fn kernel_launch(ctx: DeviceContext) raises:
            reduce_launch[
                num_reductions, input_fn, output_fn, reduce_wrapper, rank, type
            ](shape, axis, init, ctx)

        b.iter_custom[kernel_launch](ctx)

    m.bench_function[bench_func](
        BenchId("reduce", input_id=str(type) + "/shape=" + str(shape)),
        ThroughputMeasure(BenchMetric.elements, in_size),
    )

    ctx.synchronize()
    ctx.enqueue_copy_from_device(res_host, res_device.buffer)

    for i in range(out_size):
        assert_equal(res_host[i], expected_vals[i])

    _ = vec_device
    _ = res_device

    in_host.free()
    res_host.free()


def main():
    @parameter
    fn reduce_add[
        type: DType,
        width: Int,
    ](x: SIMD[type, width], y: SIMD[type, width]) -> SIMD[type, width]:
        return x + y

    alias types = VariadicList[DType](
        DType.bfloat16, DType.float32, DType.float16
    )
    alias shape_list = VariadicList[DimList](
        DimList(1, 1024, 3072),  # baby-replit-CE/TG-kernels;
        DimList(1, 1, 4096),  # baby-llama-LPTG-kernels
        DimList(1, 256, 4096),  # baby-llama-CE-kernels
    )

    var m = Bench()
    try:
        with DeviceContext() as ctx:

            @parameter
            for j in range(len(shape_list)):
                alias dims = _make_tuple[len(shape_list[j])](shape_list[j])

                @parameter
                for i in range(len(types)):
                    run_reduce[reduce_add, types[i]](
                        m,
                        dims,
                        ctx,
                    )
    except e:
        print("CUDA_ERROR:", e)

    m.dump_report()
