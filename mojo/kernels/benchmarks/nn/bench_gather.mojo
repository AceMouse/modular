# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

# RUN: %bare-mojo %s -t | FileCheck %s
# CHECK: Benchmark results

from collections.vector import InlinedFixedVector
from random import rand, randint

from benchmark import *
from buffer import NDBuffer
from buffer.dimlist import Dim, DimList
from nn.gather_scatter import gather_elements

from utils.index import Index


fn bench_gather(inout m: Bench, spec: GatherSpec) raises:
    @parameter
    @always_inline
    fn bench_gather_wrapper(inout b: Bencher, concrete_spec: GatherSpec):
        bench_gather(b, concrete_spec)

    m.bench_with_input[GatherSpec, bench_gather_wrapper](
        BenchId("gather", str(spec)), spec
    )


fn bench_gather(inout bencher: Bencher, spec: GatherSpec) capturing:
    var data = InlinedFixedVector[Float32](spec.m1 * spec.m2)
    var indices = InlinedFixedVector[Int32](spec.n1 * spec.n2)

    var index_rand_min = 0
    var index_rand_max = spec.n1 * spec.n2 - 1

    var input_shape = Index(spec.m1, spec.m2)
    var indices_shape = Index(spec.n1, spec.n2)

    var data_ptr = DTypePointer[DType.float32].alloc(
        input_shape.flattened_length()
    )
    rand(data_ptr.address, input_shape.flattened_length())
    var data_tensor = NDBuffer[DType.float32, 2](data_ptr, input_shape)

    var indices_ptr = DTypePointer[DType.int32].alloc(
        indices_shape.flattened_length()
    )
    randint(
        indices_ptr.address,
        indices_shape.flattened_length(),
        index_rand_min,
        index_rand_max,
    )
    var indices_tensor = NDBuffer[DType.int32, 2](indices_ptr, indices_shape)

    var output_ptr = DTypePointer[DType.float32].alloc(
        indices_shape.flattened_length()
    )
    var output_tensor = NDBuffer[DType.float32, 2](output_ptr, indices_shape)

    @always_inline
    @parameter
    fn bench_fn():
        try:
            gather_elements(
                data_tensor,
                indices_tensor,
                spec.axis,
                output_tensor,
            )
        except e:
            print("Err => ", e)

    bencher.iter[bench_fn]()

    _ = data_tensor
    _ = indices_tensor
    _ = output_tensor


@value
struct GatherSpec(Stringable):
    var axis: Int
    var m1: Int
    var m2: Int
    var n1: Int
    var n2: Int

    @no_inline
    fn __str__(self) -> String:
        return (
            "axis="
            + str(self.axis)
            + ";Dim=("
            + str(self.m1)
            + ","
            + str(self.m2)
            + ")("
            + str(self.n1)
            + ","
            + str(self.n2)
            + ")"
        )


def main():
    var m = Bench(BenchConfig(num_repetitions=2))
    bench_gather(m, GatherSpec(axis=1, m1=400, m2=400, n1=200, n2=200))
    bench_gather(m, GatherSpec(axis=1, m1=1000, m2=1000, n1=200, n2=200))
    m.dump_report()
