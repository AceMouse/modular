# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo-no-debug %s
# CHECK-NOT: Failed

from math import isclose

from buffer import Dim, DimList, NDBuffer
from gpu.host.device_context import DeviceBuffer, DeviceContext
from linalg.matmul import matmul
from linalg.matmul_gpu import _matmul_gpu
from runtime.llcl import MojoCallContextPtr
from testing import assert_almost_equal


fn _size[rank: Int](dims: StaticIntTuple[rank]) -> Int:
    var size = 1

    @parameter
    for i in range(rank):
        size *= dims[i]
    return size


fn _create_device_buffer[
    dtype: DType, rank: Int, shape: DimList
](ctx: DeviceContext, dynamic_shape: StaticIntTuple[rank]) raises -> Tuple[
    DeviceBuffer[dtype], NDBuffer[dtype, rank, shape]
]:
    var storage = ctx.create_buffer[dtype](_size(dynamic_shape))
    return (
        storage,
        NDBuffer[dtype, rank, shape](storage.ptr, dynamic_shape=dynamic_shape),
    )


fn _create_host_buffer[
    dtype: DType, rank: Int, shape: DimList
](dynamic_shape: StaticIntTuple[rank]) raises -> NDBuffer[dtype, rank, shape]:
    var storage_ptr = DTypePointer[dtype].alloc(_size(dynamic_shape))
    return NDBuffer[dtype, rank, shape](
        storage_ptr, dynamic_shape=dynamic_shape
    )


fn _linspace_fill[
    dtype: DType, rank: Int, shape: DimList
](inout buff: NDBuffer[dtype, rank, shape]):
    for i in range(buff.size()):
        buff.data[i] = i


fn _create_host_buffer_like[
    dtype: DType, rank: Int, shape: DimList
](buff: NDBuffer[dtype, rank, shape]) raises -> NDBuffer[dtype, rank, shape]:
    return _create_host_buffer[dtype, rank, shape](buff.dynamic_shape)


fn _get_test_name[
    type: DType, shape_c: DimList, shape_a: DimList, shape_b: DimList
](
    shape_c_dim: StaticIntTuple[2],
    shape_a_dim: StaticIntTuple[2],
    shape_b_dim: StaticIntTuple[2],
) -> String:
    var str = String("test-case(")
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
    str += ", ... "
    return str


fn matmul_test_case[
    dtype: DType,
    shape_c: DimList,
    shape_a: DimList,
    shape_b: DimList,
](
    shape_c_dim: StaticIntTuple[2],
    shape_a_dim: StaticIntTuple[2],
    shape_b_dim: StaticIntTuple[2],
    ctx: DeviceContext,
) raises:
    print(
        _get_test_name[dtype, shape_c, shape_a, shape_b](
            shape_c_dim, shape_a_dim, shape_b_dim
        ),
        end=" ",
    )

    var mat_a_dev = _create_device_buffer[dtype, 2, shape_a](ctx, shape_a_dim)
    var mat_b_dev = _create_device_buffer[dtype, 2, shape_b](ctx, shape_b_dim)
    var mat_a_host = _create_host_buffer_like(mat_a_dev[1])
    var mat_b_host = _create_host_buffer_like(mat_b_dev[1])
    var mat_c_dev = _create_device_buffer[dtype, 2, shape_c](ctx, shape_c_dim)
    var mat_c_host = _create_host_buffer_like(mat_c_dev[1])
    var mat_c_ref_host = _create_host_buffer_like(mat_c_host)

    _linspace_fill(mat_a_host)
    _linspace_fill(mat_b_host)

    ctx.enqueue_copy_from_device(mat_a_host.data, mat_a_dev[0])
    ctx.enqueue_copy_from_device(mat_b_host.data, mat_b_dev[0])

    _matmul_gpu(mat_c_dev[1], mat_a_dev[1], mat_b_dev[1], ctx)

    ctx.enqueue_copy_from_device(mat_c_host.data, mat_c_dev[0])
    ctx.synchronize()

    # FIXME: We should run a reference gpu matmul, the reference should also
    # support applying the epilogue on the final result.
    matmul(
        mat_c_ref_host,
        mat_a_host,
        mat_b_host,
    )

    var success = True
    for m in range(shape_c_dim[0]):
        for n in range(shape_c_dim[1]):
            if not isclose(mat_c_ref_host[m, n], mat_c_host[m, n]):
                print(
                    "Failed at ",
                    m,
                    n,
                    mat_c_host[m, n],
                    ", ref=",
                    mat_c_ref_host[m, n],
                )
                success = False

    if success:
        print("Passed 🎉")

    mat_a_host.data.free()
    mat_b_host.data.free()
    _ = mat_a_dev^
    _ = mat_b_dev^
    _ = mat_c_dev^


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


fn create_matmul_test_case[
    dtype: DType
](ctx: DeviceContext, m: ValOrDim, n: ValOrDim, k: ValOrDim) raises:
    matmul_test_case[
        DType.float32,
        DimList(m.dim, n.dim),
        DimList(m.dim, k.dim),
        DimList(k.dim, n.dim),
    ]((m.value, n.value), (m.value, k.value), (k.value, n.value), ctx)


fn main():
    try:
        with DeviceContext() as ctx:
            create_matmul_test_case[DType.float32](
                ctx, dynamic(8), static[8](), static[4]()
            )
            create_matmul_test_case[DType.float32](
                ctx, dynamic(16), static[16](), static[8]()
            )

    except e:
        print("CUDA err:", e)
