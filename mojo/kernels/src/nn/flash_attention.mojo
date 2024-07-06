# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from math import align_down, align_up, ceildiv, exp
from sys.info import has_avx512f, has_neon

from algorithm import sync_parallelize, tile, vectorize
from algorithm.reduction import (
    _simd_max,
    _simd_max_elementwise,
    _simd_sum,
    _simd_sum_elementwise,
    map_reduce,
)
from buffer import Buffer, NDBuffer
from buffer.dimlist import Dim, DimList
from linalg.accumulate import _Accumulator
from linalg.apple_accelerate import _cblas_f32, use_apple_accelerate_lib
from linalg.transpose import transpose_inplace
from linalg.utils import partition_work
from memory import memset_zero, stack_allocation
from memory.unsafe import DTypePointer
from runtime.llcl import parallelism_level

from utils import Index, InlineArray


struct _MatmulConfig:
    var col_sizes: VariadicList[Int]
    var row_sizes: VariadicList[Int]
    var gemv_sizes: VariadicList[Int]
    var pack_sizes: VariadicList[Int]

    fn __init__(
        inout self,
        *,
        col_sizes: VariadicList[Int],
        row_sizes: VariadicList[Int],
        gemv_sizes: VariadicList[Int],
        pack_sizes: VariadicList[Int],
    ):
        self.col_sizes = col_sizes
        self.row_sizes = row_sizes
        self.gemv_sizes = gemv_sizes
        self.pack_sizes = pack_sizes

    @staticmethod
    fn _get_config() -> _MatmulConfig:
        @parameter
        if has_neon():
            return _MatmulConfig(
                col_sizes=VariadicList[Int](4, 3, 2, 1),
                row_sizes=VariadicList[Int](6, 4, 1),
                gemv_sizes=VariadicList[Int](32, 4, 1),
                pack_sizes=VariadicList[Int](32, 8, 4, 1),
            )
        elif has_avx512f():
            return _MatmulConfig(
                col_sizes=VariadicList[Int](4, 3, 2, 1),
                row_sizes=VariadicList[Int](6, 4, 1),
                gemv_sizes=VariadicList[Int](64, 16, 4, 1),
                pack_sizes=VariadicList[Int](64, 16, 8, 4, 1),
            )
        else:
            return _MatmulConfig(
                col_sizes=VariadicList[Int](3, 2, 1),
                row_sizes=VariadicList[Int](4, 1),
                gemv_sizes=VariadicList[Int](64, 16, 4, 1),
                pack_sizes=VariadicList[Int](64, 16, 8, 4, 1),
            )


struct _Matmul[
    type: DType,
    simd_width: Int,
]:
    alias _matmul_config = _MatmulConfig._get_config()

    alias _input_fn_type = fn[simd_width: Int] (
        x: Int, y: Int
    ) capturing -> SIMD[type, simd_width]

    @staticmethod
    @always_inline
    fn _inner_loop_a_lane[
        tile_m: Int, tile_n: Int
    ](
        K: Int,
        a_ptr: DTypePointer[type],
        a_stride: Int,
        b_ptr: DTypePointer[type],
        b_stride: Int,
        inout c_tile: _Accumulator[type, tile_m, tile_n, simd_width],
    ):
        var ak_ptr = a_ptr
        var bk_ptr = b_ptr

        @parameter
        @always_inline
        fn loop_body[lane_count: Int](k: Int):
            var a_tile = InlineArray[SIMD[type, lane_count], tile_m](0)

            @parameter
            for m in range(tile_m):
                a_tile[m] = SIMD[size=lane_count].load(ak_ptr, m * a_stride)

            ak_ptr += lane_count

            @parameter
            for k in range(lane_count):

                @parameter
                for n in range(tile_n):
                    var b_data = SIMD[size=simd_width].load(
                        bk_ptr, n * simd_width
                    )

                    @parameter
                    for m in range(tile_m):
                        c_tile.fma(m, n, a_tile[m][k], b_data)

                bk_ptr += b_stride

        tile[loop_body, VariadicList[Int](simd_width, 1)](0, K)
        _ = ak_ptr
        _ = bk_ptr

    @staticmethod
    @always_inline
    fn _inner_loop_a_broadcast[
        tile_m: Int, tile_n: Int
    ](
        K: Int,
        a_ptr: DTypePointer[type],
        a_stride: Int,
        b_ptr: DTypePointer[type],
        b_stride: Int,
        inout c_tile: _Accumulator[type, tile_m, tile_n, simd_width],
    ):
        var ak_ptr = a_ptr
        var bk_ptr = b_ptr

        @parameter
        @always_inline
        fn loop_body[unroll_factor: Int](k: Int):
            var b_tile = InlineArray[SIMD[type, simd_width], tile_n](0)

            @parameter
            for k in range(unroll_factor):

                @parameter
                for n in range(tile_n):
                    b_tile[n] = SIMD[size=simd_width].load(
                        bk_ptr, n * simd_width
                    )

                @parameter
                for m in range(tile_m):
                    var a_data = Scalar.load(ak_ptr, m * a_stride)

                    @parameter
                    for n in range(tile_n):
                        c_tile.fma(m, n, a_data, b_tile[n])

                ak_ptr += 1
                bk_ptr += b_stride

        tile[loop_body, VariadicList[Int](2, 1)](0, K)
        _ = ak_ptr
        _ = bk_ptr

    @no_inline
    @staticmethod
    fn _matmul_packed(
        M: Int,
        N: Int,
        K: Int,
        a_ptr: DTypePointer[type],
        a_stride: Int,
        b_ptr: DTypePointer[type],
        c_ptr: DTypePointer[type],
        c_stride: Int,
        accumulate: Bool = False,
    ):
        var am_ptr = a_ptr
        var cm_ptr = c_ptr

        @parameter
        fn process_rows[tile_m: Int](m: Int):
            var bn_ptr = b_ptr
            var cn_ptr = cm_ptr

            @parameter
            fn process_cols[tile_n: Int](n_unscaled: Int):
                var c_tile = _Accumulator[type, tile_m, tile_n, simd_width]()

                if accumulate:
                    c_tile.load(cn_ptr, c_stride)
                else:
                    c_tile.init(0.0)

                @parameter
                if has_neon():
                    Self._inner_loop_a_lane(
                        K, am_ptr, a_stride, bn_ptr, N, c_tile
                    )
                else:
                    Self._inner_loop_a_broadcast(
                        K, am_ptr, a_stride, bn_ptr, N, c_tile
                    )

                c_tile.store(cn_ptr, c_stride)

                bn_ptr += tile_n * simd_width
                cn_ptr += tile_n * simd_width

            tile[process_cols, Self._matmul_config.col_sizes](
                0, ceildiv(N, simd_width)
            )
            _ = bn_ptr
            _ = cn_ptr

            am_ptr += tile_m * a_stride
            cm_ptr += tile_m * c_stride

        tile[process_rows, Self._matmul_config.row_sizes](0, M)
        _ = am_ptr
        _ = cm_ptr

    @no_inline
    @staticmethod
    fn _pack_buffer_transposed[
        input_b_fn: Self._input_fn_type, static_k: Dim
    ](packed_ptr: DTypePointer[type], N: Int, dynamic_k: Int):
        var K = int(static_k) if static_k else dynamic_k

        var aligned_n = align_up(N, simd_width)

        # Use a conservative SIMD width for transposing. Using a wider native
        # SIMD width has not been observed to improve performance and causes
        # code size to unnecessarily increase.
        alias transpose_width = 4
        alias tile_sizes = VariadicList[Int](transpose_width, 1)

        var transpose_buffer = NDBuffer[
            type, 2, DimList(transpose_width, transpose_width)
        ].stack_allocation()

        @parameter
        @always_inline
        fn process_tile[tile_n: Int, tile_k: Int](n: Int, k: Int):
            @parameter
            if transpose_width == tile_n == tile_k:
                # Use an optimized path to transpose a square tile of the
                # input tensor.
                @parameter
                for i in range(transpose_width):
                    var val = input_b_fn[simd_width=transpose_width](n + i, k)
                    transpose_buffer.store(Index(i, 0), val)

                transpose_inplace(transpose_buffer)

                @parameter
                for i in range(transpose_width):
                    var val = transpose_buffer.load[width=transpose_width](
                        Index(i, 0)
                    )
                    SIMD.store(packed_ptr, (k + i) * aligned_n + n, val)

            else:
                # Fallback to strided loads and stores of the tensors.
                #
                # Note that in the common case, `K` is statically known and is
                # a multiple of `transpose_width`, so the case to optimize for
                # `tile_n=1` and `tile_k=transpose_width`.
                @parameter
                for nn in range(tile_n):
                    var val = input_b_fn[simd_width=tile_k](n + nn, k)

                    @parameter
                    for kk in range(tile_k):
                        SIMD.store(
                            packed_ptr, (k + kk) * aligned_n + (n + nn), val[kk]
                        )

        tile[process_tile, tile_sizes, tile_sizes](0, 0, N, K)
        _ = transpose_buffer

        if aligned_n != N:
            for k in range(K):
                memset_zero(packed_ptr + k * aligned_n + N, aligned_n - N)

    @no_inline
    @staticmethod
    fn _pack_buffer[
        input_b_fn: Self._input_fn_type
    ](packed_ptr: DTypePointer[type], N: Int, K: Int):
        var output_ptr = packed_ptr
        var aligned_n = align_up(N, simd_width)

        for k in range(K):

            @parameter
            @always_inline
            fn packed_copy[_simd_width: Int](idx: Int):
                var val = input_b_fn[_simd_width](idx, k)
                SIMD.store(output_ptr, idx, val)

            tile[packed_copy, Self._matmul_config.pack_sizes](0, N)
            _ = k

            if aligned_n != N:
                memset_zero(output_ptr + N, aligned_n - N)

            output_ptr += aligned_n

    @no_inline
    @staticmethod
    fn _gemv_transposed[
        input_b_fn: Self._input_fn_type, static_k: Dim
    ](
        N: Int,
        dynamic_k: Int,
        a_ptr: DTypePointer[type],
        c_ptr: DTypePointer[type],
    ):
        var K = int(static_k) if static_k else dynamic_k

        var cn_ptr = c_ptr

        @parameter
        @always_inline
        fn process_cols[tile_n: Int](n: Int):
            @parameter
            @always_inline
            fn do_reduce[
                _simd_width: Int
            ](
                start: Int,
                end: Int,
                inout accum: InlineArray[SIMD[type, _simd_width], tile_n],
            ):
                for k in range(start, end, _simd_width):
                    var a_data = SIMD[size=_simd_width].load(a_ptr, k)

                    @parameter
                    for nn in range(tile_n):
                        var b_data = input_b_fn[_simd_width](n + nn, k)
                        accum[nn] = b_data.fma(a_data, accum[nn])

            @parameter
            @always_inline
            fn do_reduce_accum[
                target_width: Int, _simd_width: Int
            ](
                accum: InlineArray[SIMD[type, _simd_width], tile_n]
            ) -> InlineArray[SIMD[type, target_width], tile_n]:
                var accum_reduce = InlineArray[
                    SIMD[type, target_width], tile_n
                ](0)

                @parameter
                for nn in range(tile_n):
                    accum_reduce[nn] = accum[nn].reduce_add[target_width]()
                return accum_reduce

            alias unroll_factor = 2
            alias unroll_simd_width = simd_width * unroll_factor

            var unroll_loop_end = align_down(K, unroll_simd_width)
            var unroll_accum = InlineArray[
                SIMD[type, unroll_simd_width], tile_n
            ](0)
            do_reduce(0, unroll_loop_end, unroll_accum)

            var simd_loop_end = align_down(K, simd_width)
            var simd_accum = do_reduce_accum[simd_width](unroll_accum)
            do_reduce(unroll_loop_end, simd_loop_end, simd_accum)

            var scalar_accum = do_reduce_accum[1](simd_accum)
            do_reduce(simd_loop_end, K, scalar_accum)

            @parameter
            for nn in range(tile_n):
                Scalar.store(cn_ptr, nn, scalar_accum[nn])

            cn_ptr += tile_n

        tile[process_cols, VariadicList[Int](4, 1)](0, N)
        _ = cn_ptr
        _ = K

    @no_inline
    @staticmethod
    fn _gemv[
        input_b_fn: Self._input_fn_type
    ](
        N: Int,
        K: Int,
        a_ptr: DTypePointer[type],
        c_ptr: DTypePointer[type],
        accumulate: Bool = False,
    ):
        var cn_ptr = c_ptr

        @parameter
        @always_inline
        fn process_cols[_simd_width: Int](n: Int):
            var accum = SIMD[type, _simd_width]()

            for k in range(K):
                var b_data = input_b_fn[_simd_width](n, k)
                accum = b_data.fma(a_ptr[k], accum)

            if accumulate:
                accum += SIMD[size=_simd_width].load(cn_ptr)

            SIMD.store(cn_ptr, accum)
            cn_ptr += _simd_width

        tile[process_cols, Self._matmul_config.gemv_sizes](0, N)
        _ = cn_ptr

    @no_inline
    @staticmethod
    fn _matmul[
        input_b_fn: Self._input_fn_type,
        *,
        transpose_b: Bool = False,
        static_k: Dim = Dim(),
    ](
        M: Int,
        N: Int,
        K: Int,
        a_ptr: DTypePointer[type],
        a_stride: Int,
        packed_ptr: DTypePointer[type],
        c_ptr: DTypePointer[type],
        c_stride: Int,
        accumulate: Bool = False,
    ):
        if M == 1:

            @parameter
            if transpose_b:
                # Transpose is implemented for the K tensor and accumulation
                # is used with the V tensor, so simplify the implementation by
                # falling back to the general path.
                if not accumulate:
                    return Self._gemv_transposed[input_b_fn, static_k](
                        N, K, a_ptr, c_ptr
                    )
            else:
                return Self._gemv[input_b_fn](
                    N, K, a_ptr, c_ptr, accumulate=accumulate
                )

        @parameter
        if transpose_b:
            Self._pack_buffer_transposed[input_b_fn, static_k](packed_ptr, N, K)
        else:
            Self._pack_buffer[input_b_fn](packed_ptr, N, K)

        @parameter
        if use_apple_accelerate_lib[type, type, type]():
            return _cblas_f32(
                M,
                N,
                K,
                a_stride,
                align_up(N, simd_width),
                c_stride,
                Float32(1.0),
                Float32(1.0) if accumulate else Float32(0.0),
                rebind[DTypePointer[DType.float32]](c_ptr),
                rebind[DTypePointer[DType.float32]](a_ptr),
                rebind[DTypePointer[DType.float32]](packed_ptr),
            )

        Self._matmul_packed(
            M,
            align_up(N, simd_width),
            K,
            a_ptr,
            a_stride,
            packed_ptr,
            c_ptr,
            c_stride,
            accumulate=accumulate,
        )


struct _FlashAttentionConfig[
    type: DType,
    rank: Int,
    simd_width: Int,
    output_static_shape: DimList,
]:
    var block_m: Int
    var qk_block_n: Int
    var o_block_n: Int

    fn __init__(inout self):
        self.qk_block_n = 128
        self.o_block_n = 128

        # Set a target size for the output block array.
        alias output_target_size = 8192

        alias depth_static_dim = output_static_shape.at[rank - 1]()

        @parameter
        if depth_static_dim:
            # Extract the static depth dimension with a guard against zero.
            var depth_dim = max(int(depth_static_dim), 1)

            # Compute the number of columns for the output block array. If the
            # count is too large, then use the default size.
            self.o_block_n = align_up(
                depth_dim if depth_dim <= 256 else self.o_block_n, simd_width
            )

        # Compute the number of rows per iteration, but constrain this number
        # as other buffers are allocated to this size too.
        self.block_m = align_down(output_target_size // self.o_block_n, 4)
        self.block_m = min(max(self.block_m, 1), 64)


struct _FlashAttention[
    type: DType,
    rank: Int,
    simd_width: Int,
    input_k_fn: fn[simd_width: Int, rank: Int] (
        StaticIntTuple[rank]
    ) capturing -> SIMD[type, simd_width],
    input_v_fn: fn[simd_width: Int, rank: Int] (
        StaticIntTuple[rank]
    ) capturing -> SIMD[type, simd_width],
    input_mask_fn: fn[simd_width: Int, rank: Int] (
        StaticIntTuple[rank]
    ) capturing -> SIMD[type, simd_width],
    output_static_shape: DimList,
    *,
    transpose_k: Bool = False,
]:
    alias _matmul = _Matmul[type, simd_width]
    alias _config = _FlashAttentionConfig[
        type, rank, simd_width, output_static_shape
    ]()
    alias _depth_static_dim = output_static_shape.at[rank - 1]()

    @staticmethod
    fn _online_softmax[
        input_mask_fn: fn[simd_width: Int] (m: Int, n: Int) capturing -> SIMD[
            type, simd_width
        ],
    ](
        qk_block_ptr: DTypePointer[type],
        o_block_ptr: DTypePointer[type],
        max_vals: DTypePointer[type],
        sum_vals: DTypePointer[type],
        count_m: Int,
        count_n: Int,
        kv_seq_cnt: Int,
        scale: Float32,
    ):
        var qk_row_ptr = qk_block_ptr
        var o_row_ptr = o_block_ptr

        for m in range(count_m):
            var qk_row = Buffer[type](qk_row_ptr, kv_seq_cnt)

            @parameter
            @always_inline
            fn pass1_input_gen_fn[
                _type: DType, _simd_width: Int
            ](idx: Int) -> SIMD[_type, _simd_width]:
                var val = SIMD[size=_simd_width].load(qk_row_ptr, idx)
                var mask = input_mask_fn[_simd_width](m, idx)
                return rebind[SIMD[_type, _simd_width]](
                    val * scale.cast[type]() + mask
                )

            # Update the row with the scale and mask. Find the maximum value
            # of the row to bias the exponential function below for numeric
            # stability.
            var max_val = map_reduce[
                simd_width,
                Dim(),
                type,
                type,
                pass1_input_gen_fn,
                _simd_max_elementwise,
                _simd_max,
            ](qk_row, max_vals[m])

            @parameter
            @always_inline
            fn pass2_input_gen_fn[
                _type: DType, _simd_width: Int
            ](idx: Int) -> SIMD[_type, _simd_width]:
                var val = SIMD[size=_simd_width].load(qk_row_ptr, idx)
                return rebind[SIMD[_type, _simd_width]](exp(val - max_val))

            # Update the row with the exponential of each value and accumulate
            # the result.
            var accum_val = map_reduce[
                simd_width,
                Dim(),
                type,
                type,
                pass2_input_gen_fn,
                _simd_sum_elementwise,
                _simd_sum,
            ](qk_row, 0)

            var fixup_val = exp(max_vals[m] - max_val)

            # Update the running maximum and sum for the row.
            max_vals[m] = max_val
            sum_vals[m] = sum_vals[m] * fixup_val + accum_val

            @parameter
            @always_inline
            fn do_correction[_simd_width: Int](idx: Int):
                var val = SIMD[size=_simd_width].load(o_row_ptr, idx)
                SIMD.store(o_row_ptr, idx, val * fixup_val)

            vectorize[do_correction, simd_width, unroll_factor=2](count_n)
            _ = fixup_val

            qk_row_ptr += Self._config.qk_block_n
            o_row_ptr += Self._config.o_block_n

    @staticmethod
    fn run(
        q: NDBuffer[type, rank],
        k_shape: StaticIntTuple[rank],
        v_shape: StaticIntTuple[rank],
        output: NDBuffer[type, rank, output_static_shape],
        scale: Float32,
    ):
        var num_batches = output.dim[0]()
        var num_heads = output.dim[1]() if rank == 4 else 1
        var seq_len = output.dim[rank - 2]()
        var depth_dim = output.dim[rank - 1]()
        var kv_seq_len = v_shape[rank - 2]

        var num_kv_heads = k_shape[1] if rank == 4 else 1
        var kv_group_count = num_heads // num_kv_heads

        # Compute the maximum size in elements for the common packed buffer.
        var packed_qk_size = Self._config.qk_block_n * depth_dim
        var packed_o_size = Self._config.o_block_n * Self._config.qk_block_n
        var packed_size = max(packed_qk_size, packed_o_size)

        var num_blocks_m = ceildiv(seq_len, Self._config.block_m)
        var num_blocks_n = ceildiv(depth_dim, Self._config.o_block_n)
        var work_count = num_batches * num_heads * num_blocks_m * num_blocks_n

        var num_threads = min(work_count, parallelism_level())

        @__copy_capture(
            num_threads,
            work_count,
            num_blocks_n,
            num_blocks_m,
            packed_size,
            kv_group_count,
            kv_seq_len,
            depth_dim,
            seq_len,
            num_heads,
        )
        @parameter
        fn task_func(task_id: Int):
            var qk_block_ptr = stack_allocation[
                Self._config.block_m * Self._config.qk_block_n,
                type,
                alignment = alignof[SIMD[type, simd_width]](),
            ]()
            var o_block_ptr = stack_allocation[
                Self._config.block_m * Self._config.o_block_n,
                type,
                alignment = alignof[SIMD[type, simd_width]](),
            ]()
            var max_vals = Buffer[
                type, Dim(Self._config.block_m)
            ]().stack_allocation()
            var sum_vals = Buffer[
                type, Dim(Self._config.block_m)
            ]().stack_allocation()

            var packed_ptr = DTypePointer[
                type
            ]() if seq_len == 1 else DTypePointer[type].alloc(
                packed_size,
                alignment=alignof[SIMD[type, simd_width]](),
            )

            var block_range = partition_work(
                task_id, num_threads, work_count, 1
            )

            for i in range(block_range[0], block_range[0] + block_range[1]):
                var n = (i % num_blocks_n) * Self._config.o_block_n
                var j = i // num_blocks_n
                var m = (j % num_blocks_m) * Self._config.block_m
                var batch_head = j // num_blocks_m
                var head = batch_head % num_heads
                var batch = batch_head // num_heads
                var kv_head = head // kv_group_count

                @parameter
                @__copy_capture(batch, batch_head, kv_head, head)
                @always_inline
                fn get_nd_index[
                    is_kv: Bool = False
                ](x: Int, y: Int) -> StaticIntTuple[rank]:
                    @parameter
                    if rank == 4:
                        return StaticIntTuple[rank](
                            batch, kv_head if is_kv else head, x, y
                        )
                    else:
                        return StaticIntTuple[rank](batch_head, x, y)

                var count_m = min(Self._config.block_m, seq_len - m)
                var count_n = min(Self._config.o_block_n, depth_dim - n)

                var o_ptr = output._offset(get_nd_index(m, n))
                var q_ptr = q._offset(get_nd_index(m, 0))

                max_vals.fill(Scalar[type].MIN)
                sum_vals.fill(0)

                for kv_seq_idx in range(0, kv_seq_len, Self._config.qk_block_n):
                    var kv_seq_cnt = min(
                        kv_seq_len - kv_seq_idx, Self._config.qk_block_n
                    )

                    @parameter
                    @always_inline
                    fn input_k_2d_fn[
                        _simd_width: Int
                    ](_n: Int, _k: Int) -> SIMD[type, _simd_width]:
                        var x = _k
                        var y = _n + kv_seq_idx

                        @parameter
                        if transpose_k:
                            swap(x, y)
                        return input_k_fn[_simd_width, rank](
                            get_nd_index[is_kv=True](x, y)
                        )

                    Self._matmul._matmul[
                        input_k_2d_fn,
                        transpose_b=transpose_k,
                        static_k = Self._depth_static_dim,
                    ](
                        count_m,
                        kv_seq_cnt,
                        depth_dim,
                        q_ptr,
                        depth_dim,
                        packed_ptr,
                        qk_block_ptr,
                        Self._config.qk_block_n,
                    )

                    @parameter
                    @always_inline
                    fn input_mask_2d_fn[
                        _simd_width: Int
                    ](_m: Int, _n: Int) -> SIMD[type, _simd_width]:
                        return input_mask_fn[_simd_width, rank](
                            get_nd_index(_m + m, _n + kv_seq_idx)
                        )

                    Self._online_softmax[input_mask_2d_fn](
                        qk_block_ptr,
                        o_block_ptr,
                        max_vals.data,
                        sum_vals.data,
                        count_m,
                        count_n,
                        kv_seq_cnt,
                        scale,
                    )

                    @parameter
                    @always_inline
                    fn input_v_2d_fn[
                        _simd_width: Int
                    ](_n: Int, _k: Int) -> SIMD[type, _simd_width]:
                        return input_v_fn[_simd_width, rank](
                            get_nd_index[is_kv=True](_k + kv_seq_idx, n + _n)
                        )

                    Self._matmul._matmul[input_v_2d_fn](
                        count_m,
                        count_n,
                        kv_seq_cnt,
                        qk_block_ptr,
                        Self._config.qk_block_n,
                        packed_ptr,
                        o_block_ptr,
                        Self._config.o_block_n,
                        accumulate=(kv_seq_idx > 0),
                    )
                    _ = kv_seq_idx

                _ = m
                _ = n
                var oz_ptr = o_block_ptr

                for m in range(count_m):
                    var reciprocal = 1 / sum_vals[m]

                    @parameter
                    @always_inline
                    fn do_final[_simd_width: Int](idx: Int):
                        var v = SIMD[size=_simd_width].load(oz_ptr, idx)
                        SIMD.store(o_ptr, idx, v * reciprocal)

                    vectorize[do_final, simd_width, unroll_factor=4](count_n)

                    o_ptr += depth_dim
                    oz_ptr += Self._config.o_block_n

            if packed_ptr:
                packed_ptr.free()

        sync_parallelize[task_func](num_threads)


fn flash_attention[
    type: DType,
    rank: Int,
    input_k_fn: fn[simd_width: Int, rank: Int] (
        StaticIntTuple[rank]
    ) capturing -> SIMD[type, simd_width],
    input_v_fn: fn[simd_width: Int, rank: Int] (
        StaticIntTuple[rank]
    ) capturing -> SIMD[type, simd_width],
    input_mask_fn: fn[simd_width: Int, rank: Int] (
        StaticIntTuple[rank]
    ) capturing -> SIMD[type, simd_width],
    output_static_shape: DimList = DimList.create_unknown[rank](),
    *,
    transpose_k: Bool = False,
](
    q: NDBuffer[type, rank],
    k_shape: StaticIntTuple[rank],
    v_shape: StaticIntTuple[rank],
    output: NDBuffer[type, rank, output_static_shape],
    scale: Float32,
):
    _FlashAttention[
        type,
        rank,
        simdwidthof[type](),
        input_k_fn,
        input_v_fn,
        input_mask_fn,
        output_static_shape,
        transpose_k=transpose_k,
    ].run(q, k_shape, v_shape, output, scale)


fn flash_attention_split_kv[
    type: DType,
    rank: Int,
    input_k_fn: fn[simd_width: Int, rank: Int] (
        StaticIntTuple[rank]
    ) capturing -> SIMD[type, simd_width],
    input_v_fn: fn[simd_width: Int, rank: Int] (
        StaticIntTuple[rank]
    ) capturing -> SIMD[type, simd_width],
    input_k_cache_fn: fn[simd_width: Int, rank: Int] (
        StaticIntTuple[rank]
    ) capturing -> SIMD[type, simd_width],
    input_v_cache_fn: fn[simd_width: Int, rank: Int] (
        StaticIntTuple[rank]
    ) capturing -> SIMD[type, simd_width],
    input_mask_fn: fn[simd_width: Int, rank: Int] (
        StaticIntTuple[rank]
    ) capturing -> SIMD[type, simd_width],
    output_static_shape: DimList = DimList.create_unknown[rank](),
](
    q: NDBuffer[type, rank],
    k_shape: StaticIntTuple[rank],
    v_shape: StaticIntTuple[rank],
    # {k,v}_cache_shape are rank + 1 because reshape in MO IR prevents fusion.
    k_cache_shape: StaticIntTuple[rank + 1],
    v_cache_shape: StaticIntTuple[rank + 1],
    output: NDBuffer[type, rank, output_static_shape],
    scale: Float32,
):
    """Variant of flash attention that takes the previous KV cache
    `input_{k,v}_cache_fn` and the current KV tensors `input_k_fn` and
    `input_v_fn` as separate arguments.

    This works around the fact that fusion can't currently look through concat.
    So this kernel does an in-place concat fusion by changing the input lambdas
    `input_{k,v}_cache_fn_wrapper` to take previous sequence KV elements from
    the KV cache, and current KV elements from tensors `k` and `v`.
    """
    # This expects the following layouts:
    # q: BHSD
    # k (input_k_fn): BHSD
    # v (input_v_fn): BHSD
    # k_cache (input_k_cache_fn): 1BHS'D
    # v_cache (input_v_cache_fn): 1BHS'D
    constrained[rank == 4]()

    alias kv_rank = rank + 1
    alias simd_width = simdwidthof[type]()

    var num_batches = v_cache_shape[1]
    var num_heads = v_cache_shape[2]
    var prev_seq_len = v_cache_shape[3]
    var depth_dim = v_cache_shape[4]
    var seq_len = v_shape[rank - 2]

    # Wrap `input_{k,v}_cache_fn` with lambdas that operate on indices of
    # rank 4, as expected by `_FlashAttention.run()`.
    var k_shape_new = StaticIntTuple[rank](
        num_batches, num_heads, prev_seq_len + seq_len, depth_dim
    )
    var v_shape_new = StaticIntTuple[rank](
        num_batches, num_heads, prev_seq_len + seq_len, depth_dim
    )

    @always_inline
    @parameter
    fn kv_index[
        rank: Int
    ](idx: StaticIntTuple[rank]) -> StaticIntTuple[kv_rank]:
        # Index into the previous kv_cache by unsqueezing dim 0.
        return StaticIntTuple[kv_rank](0, idx[0], idx[1], idx[2], idx[3])

    @always_inline
    @__copy_capture(prev_seq_len)
    @parameter
    fn load_from_split_cache[
        curr_fn: fn[simd_width: Int, rank: Int] (
            StaticIntTuple[rank]
        ) capturing -> SIMD[type, simd_width],
        cache_fn: fn[simd_width: Int, rank: Int] (
            StaticIntTuple[rank]
        ) capturing -> SIMD[type, simd_width],
        rank: Int,
        simd_width: Int,
    ](idx: StaticIntTuple[rank]) -> SIMD[type, simd_width]:
        # Load directly from either `curr_fn` or `cache_fn` depending on the
        # sequence index.
        # Boundary condition handling is done by the caller since
        # the last dim `depth_dim` is contiguous.
        var seq_idx = idx[2]

        if seq_idx >= prev_seq_len:
            return curr_fn[simd_width, rank](
                StaticIntTuple[rank](
                    idx[0], idx[1], seq_idx - prev_seq_len, idx[3]
                )
            )

        return cache_fn[simd_width, kv_rank](kv_index(idx))

    @always_inline
    @parameter
    fn input_k_cache_fn_wrapper[
        simd_width: Int,
        rank: Int,
    ](idx: StaticIntTuple[rank]) -> SIMD[type, simd_width]:
        return load_from_split_cache[
            input_k_fn, input_k_cache_fn, rank, simd_width
        ](idx)

    @always_inline
    @parameter
    fn input_v_cache_fn_wrapper[
        simd_width: Int,
        rank: Int,
    ](idx: StaticIntTuple[rank]) -> SIMD[type, simd_width]:
        return load_from_split_cache[
            input_v_fn, input_v_cache_fn, rank, simd_width
        ](idx)

    _FlashAttention[
        type,
        rank,
        simdwidthof[type](),
        input_k_cache_fn_wrapper,
        input_v_cache_fn_wrapper,
        input_mask_fn,
        output_static_shape,
        transpose_k=True,
    ].run(q, k_shape_new, v_shape_new, output, scale)
