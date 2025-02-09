# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo-no-debug-no-assert %s


from gpu.host import DeviceContext, FuncAttribute
from layout import Layout
from linalg._multistage_gemm_gpu import multistage_gemm_kernel
from linalg.utils_gpu import MatmulKernels

alias a_type = DType.bfloat16
alias b_type = DType.bfloat16
alias c_type = DType.bfloat16
alias transpose_b = False


fn multistage_gemm_simple[
    M: Int,
    N: Int,
    K: Int,
](ctx: DeviceContext,) raises:
    alias kernels = MatmulKernels[a_type, b_type, c_type, transpose_b]()
    alias config = kernels.ampere_128x128_4

    alias a_layout = Layout.row_major(M, K)
    alias b_layout = Layout.row_major(
        N, K
    ) if transpose_b else Layout.row_major(K, N)
    alias c_layout = Layout.row_major(M, N)

    # Dispatch w/o split K
    alias gemm_kernel_type = multistage_gemm_kernel[
        c_type,
        c_layout,
        a_type,
        a_layout,
        b_type,
        b_layout,
        transpose_b,
        config,
    ]

    var gemm_kernel = ctx.compile_function[gemm_kernel_type, dump_asm=True](
        func_attribute=FuncAttribute.MAX_DYNAMIC_SHARED_SIZE_BYTES(
            config.shared_mem_usage()
        ),
    )


fn main() raises:
    with DeviceContext() as ctx:
        multistage_gemm_simple[1024, 1024, 1024](ctx)
