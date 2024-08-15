# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: has_cuda_device
# RUN: %mojo-no-debug %s

from collections.optional import Optional
from math import ceildiv
from sys import simdwidthof

from algorithm.functional import _elementwise_impl_gpu
from buffer import NDBuffer
from buffer.dimlist import DimList, _make_tuple
from gpu import BlockDim, BlockIdx, ThreadIdx, barrier
from gpu.cublas.cublas import (
    check_cublas_error,
    cublasContext,
    cublasCreate,
    cublasDestroy,
)
from gpu.host._compile import _get_nvptx_target
from gpu.host.device_context import DeviceBuffer, DeviceContext
from gpu.host.memory import _memset
from internal_utils import (
    DeviceNDBuffer,
    HostNDBuffer,
    assert_almost_equal,
    assert_equal,
    fill,
    linspace,
    random,
    zero,
)
from linalg.cublas import cublas_matmul
from linalg.matmul_gpu import _matmul_gpu, matmul_kernel_naive
from memory import memset_zero, stack_allocation
from memory.reference import _GPUAddressSpace as GPUAddressSpace
from testing import assert_equal as assert_equal_val

from utils import StaticIntTuple
from utils.index import Index

alias init_fn_type = fn (buff: NDBuffer) -> None


struct test_matmul[
    type: DType,
    static_b_shape: DimList = DimList.create_unknown[2](),
    transpose_b: Bool = False,
    init_a: Optional[init_fn_type] = None,
    init_b: Optional[init_fn_type] = None,
]:
    var ctx: DeviceContext

    var M: Int
    var N: Int
    var K: Int

    var a_host: HostNDBuffer[type, 2]
    var b_host: HostNDBuffer[type, 2, static_b_shape]
    var c_host: HostNDBuffer[type, 2]
    var c_host_ref: HostNDBuffer[type, 2]

    var a_device: DeviceNDBuffer[type, 2]
    var b_device: DeviceNDBuffer[type, 2, static_b_shape]
    var c_device: DeviceNDBuffer[type, 2]
    var c_device_ref: DeviceNDBuffer[type, 2]

    fn __init__(
        inout self,
        ctx: DeviceContext,
        shape: Tuple[Int, Int, Int],
    ) raises:
        self.ctx = ctx

        self.M = shape[0]
        self.N = shape[1]
        self.K = shape[2]

        @parameter
        if static_b_shape.all_known[2]():
            alias b_k_dim = 1 if transpose_b else 0
            alias b_n_dim = 0 if transpose_b else 1
            assert_equal_val(self.K, static_b_shape.get[b_k_dim]())
            assert_equal_val(self.N, static_b_shape.get[b_n_dim]())

        var a_shape = DimList(self.M, self.K)
        var b_shape = DimList(self.K, self.N)
        var c_shape = DimList(self.M, self.N)

        self.a_host = HostNDBuffer[type, 2](a_shape)
        self.b_host = HostNDBuffer[type, 2, static_b_shape](b_shape)
        self.c_host = HostNDBuffer[type, 2](c_shape)
        self.c_host_ref = HostNDBuffer[type, 2](c_shape)

        self.a_device = DeviceNDBuffer[type, 2](a_shape, ctx=ctx)
        self.b_device = DeviceNDBuffer[type, 2, static_b_shape](
            b_shape, ctx=ctx
        )
        self.c_device = DeviceNDBuffer[type, 2](c_shape, ctx=ctx)
        self.c_device_ref = DeviceNDBuffer[type, 2](c_shape, ctx=ctx)

        @parameter
        if init_a:
            alias init_a_fn = init_a.value()
            init_a_fn(self.a_host.tensor)
        else:
            random(self.a_host.tensor)

        @parameter
        if init_b:
            alias init_b_fn = init_b.value()
            init_b_fn(self.b_host.tensor)
        else:
            random(self.b_host.tensor)

        zero(self.c_host.tensor)
        zero(self.c_host_ref.tensor)

    fn run_test[test_function: fn (Self) raises capturing -> None](self) raises:
        print("=== test_matmul")

        var ctx = self.ctx

        ctx.enqueue_copy_to_device(
            self.a_device.buffer, self.a_host.tensor.data
        )
        ctx.enqueue_copy_to_device(
            self.b_device.buffer, self.b_host.tensor.data
        )
        _memset(self.c_device.buffer.ptr, 0, self.M * self.N)
        _memset(self.c_device_ref.buffer.ptr, 0, self.M * self.N)

        test_function(self)

        ctx.enqueue_copy_from_device(
            self.c_host.tensor.data, self.c_device.buffer
        )
        ctx.enqueue_copy_from_device(
            self.c_host_ref.tensor.data, self.c_device_ref.buffer
        )
        ctx.synchronize()

        assert_almost_equal(
            self.c_host_ref.tensor,
            self.c_host.tensor,
            atol=0.0001,
            rtol=0.01,
        )


def main():
    with DeviceContext() as ctx:

        @parameter
        fn basic_test[
            type: DType,
            /,
            *,
            shape: DimList = DimList.create_unknown[2](),
            transpose_b: Bool = False,
            use_tensor_core: Bool = True,
            init_a: Optional[init_fn_type] = None,
            init_b: Optional[init_fn_type] = None,
        ](
            test_ctx: test_matmul[
                type,
                shape,
                transpose_b,
                init_a,
                init_b,
            ]
        ) raises:
            _matmul_gpu[use_tensor_core=use_tensor_core](
                test_ctx.c_device.tensor,
                test_ctx.a_device.tensor,
                test_ctx.b_device.tensor,
                ctx,
            )

            var handle = UnsafePointer[cublasContext]()
            check_cublas_error(cublasCreate(UnsafePointer.address_of(handle)))
            check_cublas_error(
                cublas_matmul(
                    handle,
                    test_ctx.c_device_ref.tensor,
                    test_ctx.a_device.tensor,
                    test_ctx.b_device.tensor,
                    c_row_major=True,
                    transpose_b=transpose_b,
                )
            )
            check_cublas_error(cublasDestroy(handle))

        test_matmul[DType.float32, DimList(128, 384)](
            ctx, (256, 384, 128)
        ).run_test[
            basic_test[
                DType.float32,
                shape = DimList(128, 384),
                use_tensor_core=True,
            ]
        ]()

        print("===> test float32 with shapes in llama2 with padding rows")

        test_matmul[DType.float32, DimList(128, 384)](
            ctx, (256, 384, 128)
        ).run_test[
            basic_test[
                DType.float32,
                shape = DimList(128, 384),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.float32, DimList(4096, 4096)](
            ctx, (256, 4096, 4096)
        ).run_test[
            basic_test[
                DType.float32,
                shape = DimList(4096, 4096),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.float32, DimList(4096, 12288)](
            ctx, (256, 12288, 4096)
        ).run_test[
            basic_test[
                DType.float32,
                shape = DimList(4096, 12288),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.float32, DimList(11008, 4096)](
            ctx, (256, 4096, 11008)
        ).run_test[
            basic_test[
                DType.float32,
                shape = DimList(11008, 4096),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.float32, DimList(12288, 4096)](
            ctx, (256, 4096, 12288)
        ).run_test[
            basic_test[
                DType.float32,
                shape = DimList(12288, 4096),
                use_tensor_core=True,
            ]
        ]()

        print("===> test float32 with shapes in llama2")

        test_matmul[DType.float32, DimList(4096, 4096)](
            ctx, (100, 4096, 4096)
        ).run_test[
            basic_test[
                DType.float32,
                shape = DimList(4096, 4096),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.float32, DimList(4096, 12288)](
            ctx, (100, 12288, 4096)
        ).run_test[
            basic_test[
                DType.float32,
                shape = DimList(4096, 12288),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.float32, DimList(11008, 4096)](
            ctx, (100, 4096, 11008)
        ).run_test[
            basic_test[
                DType.float32,
                shape = DimList(11008, 4096),
                use_tensor_core=True,
            ]
        ]()

        print("===> test bfloat16 using shape in context encoding in replit 3B")

        test_matmul[DType.bfloat16, DimList(12288, 3072)](
            ctx, (1024, 3072, 12288)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(12288, 3072),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 12288)](
            ctx, (1024, 12288, 3072)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(3072, 12288),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 5120)](
            ctx, (1024, 5120, 3072)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(3072, 5120),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(32768, 3072)](
            ctx, (1024, 3072, 32768)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(32768, 3072),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 3072)](
            ctx, (1024, 3072, 3072)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(3072, 3072),
                use_tensor_core=True,
            ]
        ]()

        @parameter
        fn epilogue_test[
            type: DType,
            /,
            *,
            shape: DimList = DimList.create_unknown[2](),
            transpose_b: Bool = False,
            use_tensor_core: Bool = False,
        ](test_ctx: test_matmul[type, shape]) raises:
            var M = test_ctx.M
            var N = test_ctx.N

            var c_tensor = test_ctx.c_device.tensor
            var ctx = test_ctx.ctx
            var epilogue_shape = Index(M, N)
            var epilogue_host = HostNDBuffer[type, 2](epilogue_shape)
            var epilogue_device = DeviceNDBuffer[type, 2](
                epilogue_shape, ctx=ctx
            )
            random(epilogue_host.tensor, 0.5, 1.5)
            ctx.enqueue_copy_to_device(
                epilogue_device.buffer, epilogue_host.tensor.data
            )
            var epilogue_buff = epilogue_device.tensor

            @parameter
            @always_inline
            @__copy_capture(c_tensor, epilogue_buff)
            fn epilogue_fn[
                _type: DType, width: Int
            ](
                idx: StaticIntTuple[2], val: SIMD[_type, width]
            ) capturing -> None:
                var another_val = rebind[SIMD[_type, width]](
                    epilogue_buff.load[width=width](idx)
                )
                c_tensor.store(
                    idx, rebind[SIMD[type, width]](val * another_val)
                )

            alias pack_size = simdwidthof[type, target = _get_nvptx_target()]()

            _matmul_gpu[
                use_tensor_core=use_tensor_core,
                transpose_b=False,
                elementwise_lambda_fn=epilogue_fn,
            ](
                test_ctx.c_device.tensor,
                test_ctx.a_device.tensor,
                test_ctx.b_device.tensor,
                ctx,
            )

            var handle = UnsafePointer[cublasContext]()
            check_cublas_error(cublasCreate(UnsafePointer.address_of(handle)))
            check_cublas_error(
                cublas_matmul(
                    handle,
                    test_ctx.c_device_ref.tensor,
                    test_ctx.a_device.tensor,
                    test_ctx.b_device.tensor,
                    c_row_major=True,
                    transpose_b=transpose_b,
                )
            )
            check_cublas_error(cublasDestroy(handle))
            var c_ref_tensor = test_ctx.c_device_ref.tensor

            @always_inline
            @__copy_capture(c_ref_tensor, epilogue_buff)
            @parameter
            fn func[simd_width: Int, rank: Int](idx0: StaticIntTuple[rank]):
                var idx = rebind[StaticIntTuple[2]](idx0)
                var another_val = epilogue_buff.load[width=simd_width](idx)

                c_ref_tensor.store(
                    idx,
                    c_ref_tensor.load[width=simd_width](idx) * another_val,
                )

            _elementwise_impl_gpu[func, pack_size](
                StaticIntTuple[2](M, N),
                ctx,
            )
            _ = epilogue_host^
            _ = epilogue_device^

        print("===> test non trivial epilogue")
        print("===> float32 with shapes in llama2 with padding rows")

        test_matmul[DType.float32, DimList(128, 384)](
            ctx, (256, 384, 128)
        ).run_test[
            epilogue_test[
                DType.float32,
                shape = DimList(128, 384),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.float32, DimList(4096, 4096)](
            ctx, (256, 4096, 4096)
        ).run_test[
            epilogue_test[
                DType.float32,
                shape = DimList(4096, 4096),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.float32, DimList(4096, 12288)](
            ctx, (256, 12288, 4096)
        ).run_test[
            epilogue_test[
                DType.float32,
                shape = DimList(4096, 12288),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.float32, DimList(11008, 4096)](
            ctx, (256, 4096, 11008)
        ).run_test[
            epilogue_test[
                DType.float32,
                shape = DimList(11008, 4096),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.float32, DimList(12288, 4096)](
            ctx, (256, 4096, 12288)
        ).run_test[
            epilogue_test[
                DType.float32,
                shape = DimList(12288, 4096),
                use_tensor_core=True,
            ]
        ]()

        print("===> float32 with shapes in llama2")

        test_matmul[DType.float32, DimList(4096, 4096)](
            ctx, (100, 4096, 4096)
        ).run_test[
            epilogue_test[
                DType.float32,
                shape = DimList(4096, 4096),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.float32, DimList(4096, 12288)](
            ctx, (100, 12288, 4096)
        ).run_test[
            epilogue_test[
                DType.float32,
                shape = DimList(4096, 12288),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.float32, DimList(11008, 4096)](
            ctx, (100, 4096, 11008)
        ).run_test[
            epilogue_test[
                DType.float32,
                shape = DimList(11008, 4096),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.float32, DimList(12288, 4096)](
            ctx, (100, 4096, 12288)
        ).run_test[
            epilogue_test[
                DType.float32,
                shape = DimList(12288, 4096),
                use_tensor_core=True,
            ]
        ]()

        print("===> test bfloat16 using shapes with arbitrary M")

        test_matmul[DType.bfloat16, DimList(12288, 3072)](
            ctx, (100, 3072, 12288)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(12288, 3072),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 12288)](
            ctx, (100, 12288, 3072)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(3072, 12288),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 5120)](
            ctx, (1000, 5120, 3072)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(3072, 5120),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(32768, 3072)](
            ctx, (1000, 3072, 32768)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(32768, 3072),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 3072)](
            ctx, (1000, 3072, 3072)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(3072, 3072),
                use_tensor_core=True,
            ]
        ]()

        print(
            "===> non-trivial epilogue bfloat16 using shape in context"
            " encoding in replit 3B"
        )

        test_matmul[DType.bfloat16, DimList(12288, 3072)](
            ctx, (1024, 3072, 12288)
        ).run_test[
            epilogue_test[
                DType.bfloat16,
                shape = DimList(12288, 3072),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 12288)](
            ctx, (1024, 12288, 3072)
        ).run_test[
            epilogue_test[
                DType.bfloat16,
                shape = DimList(3072, 12288),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 5120)](
            ctx, (1024, 5120, 3072)
        ).run_test[
            epilogue_test[
                DType.bfloat16,
                shape = DimList(3072, 5120),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 3072)](
            ctx, (1024, 3072, 3072)
        ).run_test[
            epilogue_test[
                DType.bfloat16,
                shape = DimList(3072, 3072),
                use_tensor_core=True,
            ]
        ]()

        print("=== test fp16 with generic M and epilogue")

        test_matmul[DType.bfloat16, DimList(12288, 3072)](
            ctx, (1024, 3072, 12288)
        ).run_test[
            epilogue_test[
                DType.bfloat16,
                shape = DimList(12288, 3072),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 12288)](
            ctx, (1024, 12288, 3072)
        ).run_test[
            epilogue_test[
                DType.bfloat16,
                shape = DimList(3072, 12288),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 5120)](
            ctx, (100, 5120, 3072)
        ).run_test[
            epilogue_test[
                DType.bfloat16,
                shape = DimList(3072, 5120),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(32768, 3072)](
            ctx, (1000, 3072, 32768)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(32768, 3072),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 3072)](
            ctx, (1000, 3072, 3072)
        ).run_test[
            epilogue_test[
                DType.bfloat16,
                shape = DimList(3072, 3072),
                use_tensor_core=True,
            ]
        ]()

        print("=== test shapes from pipeline tests")
        test_matmul[DType.bfloat16, DimList(12288, 3072)](
            ctx, (10, 3072, 12288)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(12288, 3072),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 12288)](
            ctx, (10, 12288, 3072)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(3072, 12288),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 5120)](
            ctx, (10, 5120, 3072)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(3072, 5120),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(32768, 3072)](
            ctx, (10, 3072, 32768)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(32768, 3072),
                use_tensor_core=True,
            ]
        ]()

        test_matmul[DType.bfloat16, DimList(3072, 3072)](
            ctx, (10, 3072, 3072)
        ).run_test[
            basic_test[
                DType.bfloat16,
                shape = DimList(3072, 3072),
                use_tensor_core=True,
            ]
        ]()
