# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo %s | FileCheck %s

from algorithm import parallelize, sync_parallelize, vectorize
from kernel_utils._utils import ManagedLayoutTensor
from kernel_utils.layout import Layout, LayoutList, composition
from kernel_utils.layout_tensor import IntTuple, LayoutTensor


@value
@register_passable
struct Dim(Stringable):
    var m: Int
    var n: Int
    var k: Int

    fn subrange(self, sub_dim: Self) -> Self:
        return Self(
            self.m // sub_dim.m, self.n // sub_dim.n, self.k // sub_dim.k
        )

    fn __str__(self) -> String:
        return (
            "m: " + str(self.m) + ", n: " + str(self.n) + ", k: " + str(self.k)
        )


trait TiledOp:
    @staticmethod
    fn op[
        layout_m_n: Layout,
        layout_m_k: Layout,
        layout_n_k: Layout,
        dtype: DType,
    ](
        inout dst: LayoutTensor[layout_m_n, dtype],
        lhs: LayoutTensor[layout_m_k, dtype],
        rhs: LayoutTensor[layout_n_k, dtype],
    ):
        pass


# matrix multiply and accumlate
struct MMA(TiledOp):
    @staticmethod
    fn op[
        layout_m_n: Layout,
        layout_m_k: Layout,
        layout_n_k: Layout,
        dtype: DType,
    ](
        inout dst: LayoutTensor[layout_m_n, dtype],
        lhs: LayoutTensor[layout_m_k, dtype],
        rhs: LayoutTensor[layout_n_k, dtype],
    ):
        alias M = dst.dim[0]()
        alias N = dst.dim[1]()
        alias K = lhs.dim[1]()

        for m in range(M):
            for n in range(N):
                for k in range(K):
                    dst[m, n] += lhs[m, k] * rhs[n, k]


# matrix multiply and accumlate, vectorized and parallelized
struct MMA_Vec(TiledOp):
    @staticmethod
    fn op[
        layout_m_n: Layout,
        layout_m_k: Layout,
        layout_n_k: Layout,
        dtype: DType,
    ](
        inout dst: LayoutTensor[layout_m_n, dtype],
        lhs: LayoutTensor[layout_m_k, dtype],
        rhs: LayoutTensor[layout_n_k, dtype],
    ):
        alias M = dst.dim[0]()
        alias N = dst.dim[1]()
        alias K = lhs.dim[1]()

        alias width = simdwidthof[dtype]() * 2

        for m in range(M):
            for n in range(N):

                @parameter
                fn dot[width: Int](k: Int):
                    dst.store[width](
                        m,
                        n,
                        dst.load[width](m, n)
                        + lhs[m, k] * rhs.load[width](n, k),
                    )

                vectorize[dot, width, size=K]()


fn gemm_l2_cache[
    mma: TiledOp,
    L1: Dim,
    L2: Dim,
    layout_m_n: Layout,
    layout_m_k: Layout,
    layout_k_n: Layout,
    dtype: DType,
](
    dst: LayoutTensor[layout_m_n, dtype],
    lhs: LayoutTensor[layout_m_k, dtype],
    rhs: LayoutTensor[layout_k_n, dtype],
):
    alias M = dst.dim[0]()
    alias N = dst.dim[1]()
    alias K = lhs.dim[1]()

    # Dimensions of the Operation
    alias op_dim = Dim(M, N, K)

    # L1 and L2 Tiile ranges
    alias l1_size = op_dim.subrange(L1)
    alias l2_size = L1.subrange(L2)

    # Cache matrix to materialize L2 transposed tiles
    var l2_rhs_cache = ManagedLayoutTensor[
        Layout(IntTuple(L2.n, L2.k)), dtype
    ]()

    # First level of tiling (grid_blocks, L1 cache ..etc).
    for m_1 in range(l1_size.m):
        for n_1 in range(l1_size.n):
            var dst_l1_tile = dst.tile[L1.m, L1.n](m_1, n_1)

            for k_1 in range(l1_size.k):
                var lhs_l1_tile = lhs.tile[L1.m, L1.k](m_1, k_1)
                var rhs_l1_tile = rhs.tile[L1.k, L1.n](k_1, n_1)

                # Second level of tiling (instruction, vectorization..etc)
                for m_2 in range(l2_size.m):
                    for n_2 in range(l2_size.n):
                        var dst_l2_tile = dst_l1_tile.tile[L2.m, L2.n](m_2, n_2)

                        for k_2 in range(l2_size.k):
                            var lhs_l2_tile = lhs_l1_tile.tile[L2.m, L2.k](
                                m_2, k_2
                            )
                            var rhs_l2_tile = rhs_l1_tile.tile[L2.k, L2.n](
                                k_2, n_2
                            )

                            # Materialize L2 rhs transposed tile
                            l2_rhs_cache.tensor.copy_from(
                                rhs_l2_tile.transpose()
                            )

                            # Execute mma.op - rhs_l2_tile is already transposed
                            mma.op(
                                dst_l2_tile, lhs_l2_tile, l2_rhs_cache.tensor
                            )


fn gemm_l1_cache[
    mma: TiledOp,
    L1: Dim,
    L2: Dim,
    layout_m_n: Layout,
    layout_m_k: Layout,
    layout_k_n: Layout,
    dtype: DType,
](
    dst: LayoutTensor[layout_m_n, dtype],
    lhs: LayoutTensor[layout_m_k, dtype],
    rhs: LayoutTensor[layout_k_n, dtype],
):
    alias M = dst.dim[0]()
    alias N = dst.dim[1]()
    alias K = lhs.dim[1]()

    # Dimensions of the Operation
    alias op_dim = Dim(M, N, K)

    # L1 and L2 Tiile ranges
    alias l1_size = op_dim.subrange(L1)
    alias l2_size = L1.subrange(L2)

    # Cache the L1 RHS and LHS tiles to reuse across the k_1 loop
    # The RHS tile is also cached to minimize the transpose operatipons.

    # var l1_lhs_cache = List[LayoutTensor[dtype, L1.m, L1.k]](
    #     capacity=l1_size.m
    # )
    # var l1_rhs_cache = List[LayoutTensor[dtype, L1.n, L1.k]](
    #     capacity=l1_size.m
    # )
    # for m in range(l1_size.m):
    #     l1_lhs_cache.append(LayoutTensor[dtype, L1.m, L1.k]())
    #     l1_rhs_cache.append(LayoutTensor[dtype, L1.n, L1.k]())

    @parameter
    fn process_raw(m_1: Int) capturing:
        # Cache the current lhs tile and reuse it for all rhs tiles in the column
        var l1_lhs_cache = LayoutTensor[
            Layout(IntTuple(L1.m, L1.k)), dtype
        ].stack_allocation()
        var l1_rhs_cache = LayoutTensor[
            Layout(IntTuple(L1.n, L1.k)), dtype
        ].stack_allocation()

        for k_1 in range(l1_size.k):
            l1_lhs_cache.copy_from(lhs.tile[L1.m, L1.k](m_1, k_1))

            for n_1 in range(l1_size.n):
                var dst_l1_tile = dst.tile[L1.m, L1.n](m_1, n_1)

                # Materialize L1 rhs transposed tile
                l1_rhs_cache.copy_from(
                    rhs.tile[L1.k, L1.n](k_1, n_1).transpose()
                )

                # Second level of tiling (instruction, vectorization..etc)
                for m_2 in range(l2_size.m):
                    for n_2 in range(l2_size.n):
                        var dst_l2_tile = dst_l1_tile.tile[L2.m, L2.n](m_2, n_2)

                        for k_2 in range(l2_size.k):
                            var lhs_l2_tile = l1_lhs_cache.tile[L2.m, L2.k](
                                m_2, k_2
                            )
                            # Transposed tile -> transposed indices
                            var rhs_l2_tile = l1_rhs_cache.tile[L2.n, L2.k](
                                n_2, k_2
                            )

                            # Execute mma.op - rhs_l2_tile is already transposed
                            mma.op(dst_l2_tile, lhs_l2_tile, rhs_l2_tile)

    sync_parallelize[process_raw](l1_size.m)

    # Make sure Mojo won't throw away our caches
    # _ = len(l1_lhs_cache)
    # _ = len(l1_rhs_cache)


fn test_tiled_matmul[use_l1_cache: Bool]():
    if use_l1_cache:
        print("=== test_tiled_matmul_l1_cache")
    else:
        print("=== test_tiled_matmul_l2_cache")

    var dst = ManagedLayoutTensor[Layout(IntTuple(8, 8)), DType.float32]()
    var rhs = ManagedLayoutTensor[Layout(IntTuple(8, 8)), DType.float32]()
    var lhs = ManagedLayoutTensor[Layout(IntTuple(8, 8)), DType.float32]()

    dst.tensor.fill(0)
    rhs.tensor.linspace()
    lhs.tensor.linspace()

    if use_l1_cache:
        gemm_l1_cache[
            MMA_Vec,
            Dim(4, 4, 2),
            Dim(2, 2, 1),
        ](dst.tensor, lhs.tensor, rhs.tensor)
    else:
        gemm_l2_cache[
            MMA_Vec,
            Dim(4, 4, 2),
            Dim(2, 2, 1),
        ](dst.tensor, lhs.tensor, rhs.tensor)
    dst.tensor.print()


fn main():
    # CHECK: === test_tiled_matmul_l1_cache
    # CHECK: 1120.0   1148.0   1176.0   1204.0   1232.0   1260.0   1288.0   1316.0
    # CHECK: 2912.0   3004.0   3096.0   3188.0   3280.0   3372.0   3464.0   3556.0
    # CHECK: 4704.0   4860.0   5016.0   5172.0   5328.0   5484.0   5640.0   5796.0
    # CHECK: 6496.0   6716.0   6936.0   7156.0   7376.0   7596.0   7816.0   8036.0
    # CHECK: 8288.0   8572.0   8856.0   9140.0   9424.0   9708.0   9992.0   10276.0
    # CHECK: 10080.0   10428.0   10776.0   11124.0   11472.0   11820.0   12168.0   12516.0
    # CHECK: 11872.0   12284.0   12696.0   13108.0   13520.0   13932.0   14344.0   14756.0
    # CHECK: 13664.0   14140.0   14616.0   15092.0   15568.0   16044.0   16520.0   16996.0
    test_tiled_matmul[use_l1_cache=True]()

    # CHECK: === test_tiled_matmul_l2_cache
    # CHECK: 1120.0   1148.0   1176.0   1204.0   1232.0   1260.0   1288.0   1316.0
    # CHECK: 2912.0   3004.0   3096.0   3188.0   3280.0   3372.0   3464.0   3556.0
    # CHECK: 4704.0   4860.0   5016.0   5172.0   5328.0   5484.0   5640.0   5796.0
    # CHECK: 6496.0   6716.0   6936.0   7156.0   7376.0   7596.0   7816.0   8036.0
    # CHECK: 8288.0   8572.0   8856.0   9140.0   9424.0   9708.0   9992.0   10276.0
    # CHECK: 10080.0   10428.0   10776.0   11124.0   11472.0   11820.0   12168.0   12516.0
    # CHECK: 11872.0   12284.0   12696.0   13108.0   13520.0   13932.0   14344.0   14756.0
    # CHECK: 13664.0   14140.0   14616.0   15092.0   15568.0   16044.0   16520.0   16996.0
    test_tiled_matmul[use_l1_cache=False]()
