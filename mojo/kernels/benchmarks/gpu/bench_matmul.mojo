# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %bare-mojo build %s


from benchmark import Bench, Bencher, BenchId, BenchMetric, ThroughputMeasure
from buffer import Dim, DimList, NDBuffer
from buffer.dimlist import _make_tuple
from gpu.host.device_context import DeviceBuffer, DeviceContext
from linalg.matmul_gpu import _matmul_gpu
from internal_utils import DeviceNDBuffer, bench_compile_time
from utils import StaticIntTuple


fn _get_run_name[
    type: DType, shape_c: DimList, shape_a: DimList, shape_b: DimList
](
    shape_c_dim: StaticIntTuple[2],
    shape_a_dim: StaticIntTuple[2],
    shape_b_dim: StaticIntTuple[2],
) -> String:
    var str = String("matmul(")
    str += type.__str__()
    str += ") : "
    str += shape_c_dim[0].__str__()
    str += (
        "_dynamic"
        + " x "
        + shape_b_dim[1].__str__() if shape_c.at[0]().is_dynamic() else " x "
        + shape_b_dim[1].__str__()
    )
    str += (
        "_dynamic"
        + " x "
        + shape_a_dim[1].__str__() if shape_b.at[1]().is_dynamic() else " x "
        + shape_a_dim[1].__str__()
    )
    str += "_dynamic" if shape_a.at[1]().is_dynamic() else ""
    str += "\t"
    return str


fn bench_matmul[
    dtype: DType,
    shape_c: DimList,
    shape_a: DimList,
    shape_b: DimList,
](
    ctx: DeviceContext,
    inout b: Bench,
    shape_c_dim: StaticIntTuple[2],
    shape_a_dim: StaticIntTuple[2],
    shape_b_dim: StaticIntTuple[2],
) raises:
    var mat_c = DeviceNDBuffer[dtype, 2, shape_c](shape_c_dim, ctx=ctx)
    var mat_a = DeviceNDBuffer[dtype, 2, shape_a](shape_a_dim, ctx=ctx)
    var mat_b = DeviceNDBuffer[dtype, 2, shape_b](shape_b_dim, ctx=ctx)

    @parameter
    @always_inline
    fn bench_func(inout b: Bencher):
        @parameter
        @always_inline
        fn kernel_launch(ctx: DeviceContext) raises:
            _matmul_gpu(mat_c.tensor, mat_a.tensor, mat_b.tensor, ctx)

        b.iter_custom[kernel_launch](ctx)

    b.bench_function[bench_func](
        BenchId(
            _get_run_name[dtype, shape_c, shape_a, shape_b](
                shape_c_dim, shape_a_dim, shape_b_dim
            )
        ),
        # TODO: Pick relevant benchmetric
        ThroughputMeasure(
            BenchMetric.elements,
            2 * shape_c_dim[0] * shape_c_dim[1] * shape_b_dim[0],
        ),
    )

    # Retain our buffers till the end.
    _ = mat_c^
    _ = mat_a^
    _ = mat_b^


struct ValOrDim[dim: Dim = Dim()]:
    var value: Int

    fn __init__(inout self):
        constrained[
            not dim.is_dynamic(),
            "Can't construct a dynamic dim with no runtime value",
        ]()
        self.value = dim.get()

    fn __init__(inout self, v: Int):
        self.value = v


fn static[d: Int]() -> ValOrDim[d]:
    return ValOrDim[d]()


fn dynamic(d: Int) -> ValOrDim:
    return ValOrDim(d)


fn create_matmul_bench[
    dtype: DType
](
    ctx: DeviceContext, inout b: Bench, m: ValOrDim, n: ValOrDim, k: ValOrDim
) raises:
    bench_matmul[
        dtype,
        DimList(m.dim, n.dim),
        DimList(m.dim, k.dim),
        DimList(k.dim, n.dim),
    ](ctx, b, (m.value, n.value), (m.value, k.value), (k.value, n.value))


fn compile_matmul_bench[
    dtype: DType
](
    ctx: DeviceContext, inout b: Bench, m: ValOrDim, n: ValOrDim, k: ValOrDim
) raises:
    var s: String = "type=" + str(dtype) + "/m=" + str(m.value) + ", n=" + str(
        n.value
    ) + ", k=" + str(k.value)
    # Note: important to pass list of BenchMetric's used by the computational benchmark (in this case, BenchMetric.elements)
    bench_compile_time[
        bench_matmul[
            dtype,
            DimList(m.dim, n.dim),
            DimList(m.dim, k.dim),
            DimList(k.dim, n.dim),
        ]
    ](b, "matmul/" + s, List[BenchMetric](BenchMetric.elements))


fn main() raises:
    alias types = List[DType](DType.bfloat16)
    alias shape_list = VariadicList[DimList](
        # baby-llama-ce-kernels (llama2-ce)
        DimList(256, 22016, 4096),
        DimList(256, 12288, 4096),
        DimList(256, 4096, 11008),
        DimList(1, 32000, 4096),
        DimList(256, 4096, 4096),
        # llama2 shapes LPTG
        DimList(1, 12288, 3072),
        DimList(1, 3072, 12288),
        DimList(1, 5120, 3072),
        DimList(1, 3072, 3072),
        # replit-V1.5-3b (baby-replit-CE-kernels)
        DimList(1024, 3072, 12288),
        DimList(1024, 12288, 3072),
        DimList(1024, 5120, 3072),
        DimList(1024, 3072, 3072),
        DimList(1024, 32768, 3072),
        # misc.
        DimList(1, 3072, 12288),
        DimList(1, 12288, 3072),
        DimList(1, 5120, 3072),
        DimList(1, 3072, 3072),
        DimList(1, 32768, 3072),
        # misc reverse
        DimList(3072, 1, 12288),
        DimList(12288, 1, 3072),
        DimList(5120, 1, 3072),
        DimList(3072, 1, 3072),
        DimList(32768, 1, 3072),
        DimList(32000, 1, 4096),
        # misc.
        DimList(32, 3072, 12288),
        DimList(32, 12288, 3072),
        DimList(32, 5120, 3072),
        DimList(32, 3072, 3072),
        DimList(32, 32768, 3072),
        # misc.
        DimList(64, 3072, 12288),
        DimList(64, 12288, 3072),
        DimList(64, 5120, 3072),
        DimList(64, 3072, 3072),
        DimList(64, 32768, 3072),
        # misc.
        DimList(128, 3072, 12288),
        DimList(128, 12288, 3072),
        DimList(128, 5120, 3072),
        DimList(128, 3072, 3072),
        DimList(128, 32768, 3072),
        # misc.
        DimList(600, 3072, 12288),
        DimList(600, 12288, 3072),
        DimList(600, 5120, 3072),
        DimList(600, 3072, 3072),
        DimList(600, 32768, 3072),
        # misc list from here:
        # https://linear.app/modularml/issue/KERN-679/significant-regression-in-replit-pipeline-in-bf16#comment-163b69e7
        DimList(857, 12288, 3072),
        DimList(857, 3072, 12288),
        DimList(857, 5120, 3072),
        DimList(857, 3072, 3072),
    )

    var m = Bench()
    try:
        with DeviceContext() as ctx:
            # benchmarking matmul
            @parameter
            for i in range(len(types)):

                @parameter
                for j in range(len(shape_list)):
                    alias dims = _make_tuple[len(shape_list[j])](shape_list[j])

                    @parameter
                    if dims[0] % 128 == 0:
                        create_matmul_bench[types[i]](
                            ctx,
                            m,
                            dynamic(dims[0]),
                            static[dims[1]](),
                            static[dims[2]](),
                        )
                    else:
                        create_matmul_bench[types[i]](
                            ctx,
                            m,
                            dynamic(dims[0]),
                            dynamic(dims[1]),
                            dynamic(dims[2]),
                        )

            # benchmarking compilation time of matmul
            @parameter
            for i in range(len(types)):

                @parameter
                for j in range(len(shape_list)):
                    alias dims = _make_tuple[len(shape_list[j])](shape_list[j])

                    @parameter
                    if dims[0] % 128 == 0:
                        compile_matmul_bench[types[i]](
                            ctx,
                            m,
                            dynamic(dims[0]),
                            static[dims[1]](),
                            static[dims[2]](),
                        )
                    else:
                        compile_matmul_bench[types[i]](
                            ctx,
                            m,
                            dynamic(dims[0]),
                            dynamic(dims[1]),
                            dynamic(dims[2]),
                        )

    except e:
        print("CUDA_ERROR:", e)

    m.dump_report()
