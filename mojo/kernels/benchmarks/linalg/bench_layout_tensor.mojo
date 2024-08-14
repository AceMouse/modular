# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo-no-debug %s -t | FileCheck %s
# CHECK: CPU Results

import math
from sys import alignof, simdwidthof
from random import rand

import benchmark
from algorithm import Static2DTileUnitFunc as Tile2DFunc
from algorithm import sync_parallelize, vectorize
from layout import *
from layout.layout_tensor import LayoutTensor
from memory import memset_zero
from python import Python

alias M = 512  # rows of A and C
alias N = 4096  # cols of B and C
alias K = 512  # cols of A and rows of B

alias dtype = DType.float32


struct Matrix[rows: Int, cols: Int]:
    var data: UnsafePointer[Scalar[dtype]]

    # Initialize zeroeing all values
    fn __init__(inout self):
        self.data = UnsafePointer[Scalar[dtype]].alloc(rows * cols)
        memset_zero(self.data, rows * cols)

    # Initialize taking a pointer, don't set any elements
    fn __init__(inout self, data: UnsafePointer[Scalar[dtype]]):
        self.data = data

    ## Initialize with random values
    @staticmethod
    fn rand() -> Self:
        var data = UnsafePointer[Scalar[dtype]].alloc(rows * cols)
        rand(data, rows * cols)
        return Self(data)

    fn __getitem__(self, y: Int, x: Int) -> SIMD[dtype, 1]:
        return self.load[1](y, x)

    fn __setitem__(inout self, y: Int, x: Int, val: SIMD[dtype, 1]):
        self.store[1](y, x, val)

    fn load[nelts: Int](self, y: Int, x: Int) -> SIMD[dtype, nelts]:
        return self.data.load[width=nelts](y * self.cols + x)

    fn store[nelts: Int](self, y: Int, x: Int, val: SIMD[dtype, nelts]):
        return self.data.store[width=nelts](y * self.cols + x, val)


fn matmul_naive(inout C: Matrix, A: Matrix, B: Matrix):
    for m in range(C.rows):
        for k in range(A.cols):
            for n in range(C.cols):
                C[m, n] += A[m, k] * B[k, n]


# Perform 2D tiling on the iteration space defined by end_x and end_y
fn tile[tiled_fn: Tile2DFunc, tile_x: Int, tile_y: Int](end_x: Int, end_y: Int):
    for y in range(0, end_y, tile_y):
        for x in range(0, end_x, tile_x):
            tiled_fn[tile_x, tile_y](x, y)


# Unroll the vectorized loop by a constant factor
fn matmul_unrolled(inout C: Matrix, A: Matrix, B: Matrix):
    # simdwidth of = amount of `dtype` elements that fit into a single SIMD register
    # 2x multiplier will use multiple SIMD registers in parallel where possible
    alias nelts = simdwidthof[dtype]() * 2
    alias tile_m = 8  # M must be a multiple of this
    alias tile_n = 64  # N must be a multiple of this
    alias tile_k = 4  # K must be a multiple of this

    constrained[M % tile_m == 0, "M must be a multiple of tile_m"]()
    constrained[N % tile_n == 0, "N must be a multiple of tile_n"]()
    constrained[K % tile_k == 0, "K must be a multiple of tile_k"]()

    @parameter
    fn calc_row(m0: Int):
        for m in range(tile_m * m0, tile_m * m0 + tile_m):

            @parameter
            fn calc_tile[tile_x: Int, tile_y: Int](x: Int, y: Int):
                @parameter
                for _k in range(tile_y):
                    var k = _k + y
                    var A_val = A[m, k]

                    @parameter
                    fn dot[simd_size: Int](n: Int):
                        var idx = n + x
                        C.store(
                            m,
                            idx,
                            C.load[simd_size](m, idx)
                            + A_val * B.load[simd_size](k, idx),
                        )

                    alias unroll_factor = tile_x // nelts
                    vectorize[
                        dot, nelts, size=tile_x, unroll_factor=unroll_factor
                    ]()
                    _ = k
                    _ = A_val

            tile[calc_tile, tile_n, tile_k](C.cols, B.rows)
            _ = m

    sync_parallelize[calc_row](C.rows // tile_m)


fn matmul_tiled_layout(inout C: Matrix, A: Matrix, B: Matrix):
    var dst = LayoutTensor[dtype, Layout.row_major(M, N)](C.data)
    var lhs = LayoutTensor[dtype, Layout.row_major(M, K)](A.data)
    var rhs = LayoutTensor[dtype, Layout.row_major(K, N)](B.data)

    alias vec_size = simdwidthof[dtype]() * 2

    alias tile_m = 2
    alias tile_n = 64
    alias tile_k = 4

    constrained[M % tile_m == 0, "N must be a multiple of tile_m"]()
    constrained[N % tile_n == 0, "N must be a multiple of tile_n"]()
    constrained[K % tile_k == 0, "K must be a multiple of tile_k"]()

    @parameter
    fn calc_row(m_1: Int):
        for k_1 in range(K // tile_k):
            for n_1 in range(N // tile_n):
                var lhs_view = lhs.tile[tile_m, tile_k](m_1, k_1)
                var dst_view = dst.tile[tile_m, tile_n](m_1, n_1)
                var rhs_view = rhs.tile[tile_k, tile_n](k_1, n_1)

                @parameter
                for m in range(tile_m):

                    @parameter
                    for k in range(tile_k):
                        var lhs_val = rebind[Scalar[dtype]](lhs_view[m, k])

                        @parameter
                        fn dot[simd_size: Int](n: Int):
                            constrained[
                                dst_view.layout.stride[1] == 1,
                                "elements of dst should be contiguous",
                            ]()
                            constrained[
                                rhs_view.layout.stride[1] == 1,
                                "elements of rhs should be contiguous",
                            ]()

                            dst_view.store[simd_size](
                                m,
                                n,
                                dst_view.load[simd_size](m, n)
                                + lhs_val * rhs_view.load[simd_size](k, n),
                            )

                        alias unroll_factor = tile_n // vec_size
                        vectorize[
                            dot,
                            vec_size,
                            size=tile_n,
                            unroll_factor=unroll_factor,
                        ]()
                _ = lhs_view^
                _ = dst_view^
                _ = rhs_view^

    sync_parallelize[calc_row](M // tile_m)
    _ = dst^
    _ = lhs^
    _ = rhs^


fn alloc_aligned_tile[
    M: Int, N: Int, dtype: DType
]() -> UnsafePointer[Scalar[dtype]]:
    alias alignment = alignof[SIMD[dtype, simdwidthof[dtype]()]]()
    alias cache_width = ((N + alignment - 1) // alignment) * alignment
    return UnsafePointer[Scalar[dtype]].alloc(
        M * cache_width, alignment=alignment
    )


fn matmul_tiled_layout_cache(inout C: Matrix, A: Matrix, B: Matrix):
    var dst = LayoutTensor[dtype, Layout.row_major(M, N)](C.data)
    var lhs = LayoutTensor[dtype, Layout.row_major(M, K)](A.data)
    var rhs = LayoutTensor[dtype, Layout.row_major(K, N)](B.data)

    alias vec_size = simdwidthof[dtype]() * 2

    alias tile_m = 8
    alias tile_n = 64
    alias tile_k = 4

    constrained[M % tile_m == 0, "N must be a multiple of tile_m"]()
    constrained[N % tile_n == 0, "N must be a multiple of tile_n"]()
    constrained[K % tile_k == 0, "K must be a multiple of tile_k"]()

    @parameter
    fn calc_row(m_1: Int):
        var rhs_cache = LayoutTensor[
            dtype, Layout.row_major(tile_k, tile_n)
        ].stack_allocation()

        for k_1 in range(K // tile_k):
            for n_1 in range(N // tile_n):
                var lhs_view = lhs.tile[tile_m, tile_k](m_1, k_1)
                var dst_view = dst.tile[tile_m, tile_n](m_1, n_1)
                var rhs_view = rhs.tile[tile_k, tile_n](k_1, n_1)

                rhs_cache.copy_from(rhs_view)

                @parameter
                for m in range(tile_m):

                    @parameter
                    for k in range(tile_k):
                        var lhs_val = rebind[Scalar[dtype]](lhs_view[m, k])

                        @parameter
                        fn dot[simd_size: Int](n: Int):
                            constrained[
                                dst_view.layout.stride[1] == 1,
                                "elements of dst should be contiguous",
                            ]()

                            dst_view.store[simd_size](
                                m,
                                n,
                                dst_view.load[simd_size](m, n)
                                + lhs_val
                                * rhs_cache.aligned_load[simd_size](k, n),
                            )

                        alias unroll_factor = tile_n // vec_size
                        vectorize[
                            dot,
                            vec_size,
                            size=tile_n,
                            unroll_factor=unroll_factor,
                        ]()
                _ = lhs_view^
                _ = dst_view^
                _ = rhs_view^

    sync_parallelize[calc_row](M // tile_m)
    _ = dst^
    _ = lhs^
    _ = rhs^


fn matmul_layout_transposed(inout C: Matrix, A: Matrix, B: Matrix):
    var dst = LayoutTensor[dtype, Layout.row_major(M, N)](C.data)
    var lhs = LayoutTensor[dtype, Layout.row_major(M, K)](A.data)
    var rhs = LayoutTensor[dtype, Layout.row_major(K, N)](B.data)

    alias vec_size = 4 * simdwidthof[dtype]()

    alias tile_m = 16
    alias tile_n = 16
    alias tile_k = 128

    constrained[M % tile_m == 0, "N must be a multiple of tile_m"]()
    constrained[N % tile_n == 0, "N must be a multiple of tile_n"]()
    constrained[K % tile_k == 0, "K must be a multiple of tile_k"]()

    constrained[
        tile_k % vec_size == 0, "tile_k must be a multiple of vec_size"
    ]()

    @parameter
    fn calc_row(m_1: Int):
        var rhs_cache = LayoutTensor[
            dtype, Layout.row_major(tile_n, tile_k)
        ].stack_allocation()
        var lhs_cache = LayoutTensor[
            dtype, Layout.row_major(tile_m, tile_k)
        ].stack_allocation()

        for k_1 in range(K // tile_k):
            var lhs_view = lhs.tile[tile_m, tile_k](m_1, k_1)
            lhs_cache.copy_from(lhs_view)

            for n_1 in range(N // tile_n):
                var dst_view = dst.tile[tile_m, tile_n](m_1, n_1)
                var rhs_view = rhs.tile[tile_k, tile_n](k_1, n_1).transpose()
                rhs_cache.copy_from(rhs_view)

                for m in range(tile_m):
                    for n in range(tile_n):
                        var sum = SIMD[dtype, vec_size](0)

                        @parameter
                        fn dot[simd_size: Int](k: Int):
                            sum = math.fma(
                                lhs_cache.load[vec_size](m, k),
                                rhs_cache.aligned_load[vec_size](n, k),
                                sum,
                            )

                        alias unroll_factor = tile_k // vec_size
                        vectorize[
                            dot,
                            vec_size,
                            size=tile_k,
                            unroll_factor=unroll_factor,
                        ]()

                        dst_view[m, n] += sum.reduce_add()
                _ = dst_view
                _ = rhs_view
            _ = lhs_view^

    sync_parallelize[calc_row](M // tile_m)
    _ = dst^
    _ = lhs^
    _ = rhs^


@always_inline
fn bench[
    func: fn (inout Matrix, Matrix, Matrix) -> None, name: StringLiteral
]() raises:
    var A = Matrix[M, K].rand()
    var B = Matrix[K, N].rand()
    var C = Matrix[M, N]()

    @always_inline
    @parameter
    fn test_fn():
        _ = func(C, A, B)

    var secs = benchmark.run[test_fn](max_runtime_secs=0.5).mean()

    A.data.free()
    B.data.free()
    C.data.free()

    var gflops = ((2 * M * N * K) / secs) / 1e9

    var py = Python.import_module("builtins")
    _ = py.print(py.str("{:<13}{:>8.3f} GFLOPS").format(name, gflops))


@always_inline
fn test_matrix_equal[
    func: fn (inout Matrix, Matrix, Matrix) -> None
](inout C: Matrix, A: Matrix, B: Matrix) raises -> Bool:
    """Runs a matmul function on A and B and tests the result for equality with
    C on every element.
    """
    var result = Matrix[M, N]()
    _ = func(result, A, B)
    for i in range(C.rows):
        for j in range(C.cols):
            # if C[i, j] != result[i, j]:
            if abs(C[i, j] - result[i, j]) > 1e-3:
                return False
    return True


fn test_all() raises:
    var A = Matrix[M, K].rand()
    var B = Matrix[K, N].rand()
    var C = Matrix[M, N]()

    matmul_naive(C, A, B)

    if not test_matrix_equal[matmul_unrolled](C, A, B):
        raise Error("Unroll output does not match naive implementation")
    if not test_matrix_equal[matmul_tiled_layout](C, A, B):
        raise Error(
            "Layout Tiled Parallel Vectorized output does not match naive"
            " implementation"
        )
    if not test_matrix_equal[matmul_tiled_layout_cache](C, A, B):
        raise Error(
            "Layout Tiled Parallel Vectorized output does not match naive"
            " implementation"
        )
    if not test_matrix_equal[matmul_layout_transposed](C, A, B):
        raise Error(
            "Layout Transposed output does not match naive implementation"
        )

    A.data.free()
    B.data.free()
    C.data.free()


fn main() raises:
    test_all()
    print("CPU Results\n")

    bench[matmul_naive, "Naive:"]()
    bench[matmul_unrolled, "Unrolled:"]()
    bench[matmul_tiled_layout, "LayoutTensor:"]()
    bench[matmul_tiled_layout_cache, "LayoutTensor Cached:"]()
    bench[matmul_layout_transposed, "LayoutTensor Transposed:"]()
