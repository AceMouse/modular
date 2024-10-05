# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

# RUN: %mojo-no-debug %s -t | FileCheck %s
# CHECK: Benchmark results

from memory import UnsafePointer
from random import rand
from os import abort

from benchmark import *
from benchmark import keep
from buffer import NDBuffer
from buffer.dimlist import DimList
from linalg.matmul import matmul
from linalg.packing import pack_b_ndbuffer, pack_matmul_b_shape_func
from testing import assert_almost_equal

from utils import IndexList
from utils.index import Index


fn gemm_naive(a: NDBuffer, b: NDBuffer, c: NDBuffer):
    var m = c.get_shape()[0]
    var n = c.get_shape()[1]
    var k = a.get_shape()[1]
    c.zero()

    for i in range(m):
        for p in range(k):
            for j in range(n):
                var a_val = a[i, p].cast[c.type]()
                var b_val = b[p, j].cast[c.type]()
                c[(i, j)] += a_val * b_val


fn verify(a: NDBuffer, b: NDBuffer, c: NDBuffer):
    var m = c.get_shape()[0]
    var n = c.get_shape()[1]

    var c_ref_ptr = UnsafePointer[Scalar[c.type]].alloc(m * n)
    var c_ref = NDBuffer[c.type, c.rank](c_ref_ptr, c.get_shape())
    gemm_naive(a, b, c_ref)

    for i in range(m):
        for j in range(n):
            try:
                assert_almost_equal(c[(i, j)], c_ref[(i, j)])
            except e:
                abort(e)  # this function should raise, blocked by #31795
    c_ref_ptr.free()


fn bench_matmul_spec(inout m: Bench, spec: MatmulSpec) raises:
    # disatch to bench_matmul with concrete spec type
    m.bench_with_input[
        MatmulSpec[spec.static_info], bench_matmul[spec.static_info]
    ](
        BenchId("matmul", str(spec)),
        spec,
        # TODO: Pick relevant benchmetric
        ThroughputMeasure(BenchMetric.elements, spec.flops()),
    )


fn bench_matmul[
    static: MatmulSpecStatic
](inout bencher: Bencher, spec: MatmulSpec[static]) capturing:
    alias a_type = spec.static_info.a_type
    alias b_type = spec.static_info.b_type
    alias c_type = spec.static_info.c_type
    alias b_packed = spec.static_info.b_packed
    alias alignment = 64
    var a_ptr = UnsafePointer[Scalar[a_type], alignment=alignment].alloc(
        spec.m * spec.k
    )
    var b_ptr = UnsafePointer[Scalar[b_type], alignment=alignment].alloc(
        spec.k * spec.n
    )
    var c_ptr = UnsafePointer[Scalar[c_type], alignment=alignment].alloc(
        spec.m * spec.n
    )
    var a = NDBuffer[a_type, 2](a_ptr, Index(spec.m, spec.k))
    var b = NDBuffer[b_type, 2](b_ptr, Index(spec.k, spec.n))
    var c = NDBuffer[c_type, 2](c_ptr, Index(spec.m, spec.n))
    rand[a_type](a_ptr, len(a))
    rand[b_type](b_ptr, len(b))
    c.zero()

    var padded_n_k = IndexList[2]()
    padded_n_k = pack_matmul_b_shape_func[
        a_type,
        DimList.create_unknown[2](),
        b_type,
        DimList.create_unknown[2](),
        c_type,
        DimList.create_unknown[2](),
        transpose_in_0=False,
        single_thread_blocking_override=False,
    ](b)

    var padded_n = padded_n_k[1] if b_packed else spec.n
    var padded_k = padded_n_k[0] if b_packed else spec.k

    var bp_ptr = UnsafePointer[Scalar[b_type], alignment=alignment].alloc(
        padded_k * padded_n
    )
    var bp = NDBuffer[b_type, 2](bp_ptr, Index(padded_k, padded_n))

    if b_packed:
        pack_b_ndbuffer[
            a_type,
            DimList.create_unknown[2](),
            b_type,
            DimList.create_unknown[2](),
            c_type,
            DimList.create_unknown[2](),
        ](b, bp)

    @always_inline
    @parameter
    fn bench_fn():
        matmul[
            transpose_b=False,
            b_packed=b_packed,
            saturated_vnni=False,
        ](c, a, bp if b_packed else b)
        keep(c.data)

    bencher.iter[bench_fn]()
    verify(a, b, c)

    a_ptr.free()
    b_ptr.free()
    bp_ptr.free()
    c_ptr.free()


@value
struct MatmulSpecStatic:
    var b_packed: Bool
    var a_type: DType
    var b_type: DType
    var c_type: DType


@value
struct MatmulSpec[static_info: MatmulSpecStatic](Stringable):
    var m: Int
    var n: Int
    var k: Int

    @no_inline
    fn __str__(self) -> String:
        return (
            "m="
            + str(self.m)
            + ";n="
            + str(self.n)
            + ";k="
            + str(self.k)
            + ";b_packed="
            + str(Self.static_info.b_packed)
            + ";a_type="
            + str(Self.static_info.a_type)
            + ";b_type="
            + str(Self.static_info.b_type)
            + ";c_type="
            + str(Self.static_info.c_type)
        )

    fn flops(self) -> Int:
        return 2 * self.m * self.n * self.k


def main():
    var m = Bench(BenchConfig(num_repetitions=2))

    alias packed_float32 = MatmulSpecStatic(
        b_packed=True,
        a_type=DType.float32,
        b_type=DType.float32,
        c_type=DType.float32,
    )
    alias unpacked_float32 = MatmulSpecStatic(
        b_packed=False,
        a_type=DType.float32,
        b_type=DType.float32,
        c_type=DType.float32,
    )

    bench_matmul_spec(m, MatmulSpec[packed_float32](m=256, n=256, k=256))
    bench_matmul_spec(m, MatmulSpec[packed_float32](m=512, n=512, k=512))
    bench_matmul_spec(m, MatmulSpec[packed_float32](m=1024, n=1024, k=1024))
    bench_matmul_spec(m, MatmulSpec[unpacked_float32](m=256, n=256, k=256))

    m.dump_report()
