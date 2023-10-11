# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
#
# This uses mandelbrot as an example to test how the entire stdlib works
# together.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo %s | FileCheck %s


from builtin.io import _printf
from utils.index import Index
from utils.vector import DynamicVector
from memory.buffer import Buffer
from tensor import Tensor
from utils.list import Dim, DimList
from runtime.llcl import num_cores
from algorithm import (
    parallelize,
    vectorize,
    sync_parallelize,
    async_parallelize,
)
from math import iota
from complex import ComplexSIMD
from benchmark import Benchmark, keep
from memory.unsafe import Pointer, DTypePointer
from sys.info import simdwidthof
from math import abs

alias float_type = DType.float64
alias int_type = DType.index


alias width = 4096
alias height = 4096
alias MAX_ITERS = 1000

alias min_x = -2.0
alias max_x = 0.47
alias min_y = -1.12
alias max_y = 1.12


fn draw_mandelbrot(inout out: Tensor[int_type]):
    let charset = String(".,c8M@jawrpogOQEPGJ")
    for row in range(out.dim(0)):
        for col in range(out.dim(1)):
            let v: Int = out[row, col].value
            if v > 0:
                let p = charset[v % charset.__len__()]
                _printf("%c", p)
            else:
                print_no_newline("0")
        print("")


# ===----------------------------------------------------------------------===#
# Blog post 1
# ===----------------------------------------------------------------------===#


@always_inline
def mandelbrot_kernel_part0(c: ComplexSIMD[float_type, 1]) -> Int:
    z = ComplexSIMD[float_type, 1](0, 0)
    nv = 0

    for i in range(1, MAX_ITERS):
        if abs(z) > 2:
            break
        z = z * z + c
        nv += 1
    return nv


@always_inline
fn mandelbrot_kernel_part1(c: ComplexSIMD[float_type, 1]) -> Int:
    var z = ComplexSIMD[float_type, 1](0, 0)
    var nv = 0

    for i in range(1, MAX_ITERS):
        if abs(z) > 2:
            break
        z = z * z + c
        nv += 1
    return nv


@always_inline
fn mandelbrot_kernel_part2(c: ComplexSIMD[float_type, 1]) -> Int:
    var z = ComplexSIMD[float_type, 1](0, 0)
    var nv = 0

    for i in range(MAX_ITERS):
        if z.squared_norm() > 4:
            break
        z = z.squared_add(c)
        nv += 1
    return nv


@always_inline
fn mandelbrot_blog_1[
    h: Int, w: Int, part: Int
](
    inout out: Tensor[int_type],
    min_x: SIMD[float_type, 1],
    max_x: SIMD[float_type, 1],
    min_y: SIMD[float_type, 1],
    max_y: SIMD[float_type, 1],
):
    let scalex = (max_x - min_x) / w
    let scaley = (max_y - min_y) / h

    for row in range(h):
        for col in range(w):
            let cx = min_x + col * scalex
            let cy = min_y + row * scaley
            let c = ComplexSIMD[float_type, 1](cx, cy)

            let res: SIMD[int_type, 1]

            @parameter
            if part == 0:
                try:
                    res = mandelbrot_kernel_part0(c)
                except:
                    res = 0
            elif part == 1:
                res = mandelbrot_kernel_part1(c)
            elif part == 2:
                res = mandelbrot_kernel_part2(c)
            else:
                res = 0

            out[Index(row, col)] = res


fn main_blog_part1():
    constrained[width % 16 == 0, "must be a multiple of 16"]()
    let m = Tensor[int_type](height, width)

    @always_inline
    @parameter
    fn bench_fn[part: Int]():
        let min_x = -2.0
        let max_x = 0.47
        let min_y = -1.12
        let max_y = 1.12

        mandelbrot_blog_1[height, width, part](m, min_x, max_x, min_y, max_y)

    var time: Float64
    let ns_per_second: Int = 1_000_000_000

    bench_fn[2]()
    var pixel_sum: Int = 0
    for i in range(height):
        for j in range(width):
            pixel_sum += m[i, j].to_int()
    print("pixel sum: ", pixel_sum)

    var num_warmup: Int = 1
    time = Benchmark(num_warmup).run[bench_fn[0]]() / ns_per_second
    print("blog post 1 with part=0 ", time)

    time = Benchmark(num_warmup).run[bench_fn[1]]() / ns_per_second
    print("blog post 1 with part=1 ", time)

    time = Benchmark(num_warmup).run[bench_fn[2]]() / ns_per_second
    print("blog post 1 with part=2 ", time)

    print(m[Index(0, 0)])


# ===----------------------------------------------------------------------===#
# Blog post 2
# ===----------------------------------------------------------------------===#


@value
@register_passable("trivial")
struct BlogPost2Step:
    var value: Int
    alias VECTORIZE = BlogPost2Step(0)
    """Vectorizes the code."""
    alias VECTORIZE_WIDE = BlogPost2Step(1)
    """Uses wider vector width."""
    alias PARALLELIZE = BlogPost2Step(6)
    """Implements coarse-grained parallelism."""
    alias PARALLELIZE_FINE_2 = BlogPost2Step(7)
    """Implements fine-grained parallelism (twice num_cores)."""
    alias PARALLELIZE_FINE_4 = BlogPost2Step(8)
    """Implements fine-grained parallelism (four times num_cores)."""
    alias PARALLELIZE_FINE_8 = BlogPost2Step(9)
    """Implements fine-grained parallelism (eight times num_cores)."""
    alias PARALLELIZE_FINE_16 = BlogPost2Step(10)
    """Implements fine-grained parallelism (sixteen times num_cores)."""
    alias PARALLELIZE_FINE_32 = BlogPost2Step(11)
    """Implements fine-grained parallelism (thirty-two times num_cores)."""

    fn __init__(value: Int) -> Self:
        return Self {value: value}

    @always_inline("nodebug")
    fn __eq__(self, rhs: BlogPost2Step) -> Bool:
        return self.value == rhs.value

    @always_inline("nodebug")
    fn __ne__(self, rhs: BlogPost2Step) -> Bool:
        return self.value != rhs.value


@always_inline
fn mandelbrot_kernel[
    simd_width: Int
](c: ComplexSIMD[float_type, simd_width]) -> SIMD[int_type, simd_width]:
    """A vectorized implementation of the inner mandelbrot computation."""
    var z = ComplexSIMD[float_type, simd_width](0, 0)
    var iters = SIMD[int_type, simd_width](0)

    var in_set_mask: SIMD[DType.bool, simd_width] = True
    for i in range(MAX_ITERS):
        if not in_set_mask.reduce_or():
            break
        in_set_mask = z.squared_norm() <= 4
        iters = in_set_mask.select(iters + 1, iters)
        z = z.squared_add(c)

    return iters


@always_inline
fn mandelbrot[
    simd_width: Int, h: Int, w: Int, step: BlogPost2Step
](inout out: Tensor[int_type]):
    # Each task gets a row.
    @always_inline
    @parameter
    fn worker(row: Int):
        let scale_x = (max_x - min_x) / w
        let scale_y = (max_y - min_y) / h

        @always_inline
        @parameter
        fn compute_vector[simd_width: Int](col: Int):
            """Each time we operate on a `simd_width` vector of pixels."""
            let cx = min_x + (col + iota[float_type, simd_width]()) * scale_x
            let cy = min_y + row * scale_y
            let c = ComplexSIMD[float_type, simd_width](cx, cy)
            out.simd_store[simd_width](
                Index(row, col), mandelbrot_kernel[simd_width](c)
            )

        # We vectorize the call to compute_vector where call gets a chunk of
        # pixels.
        vectorize[simd_width, compute_vector](w)

    @parameter
    if step == BlogPost2Step.PARALLELIZE:
        # If we just want to parallelize, then we launch the code above to
        # run in parallel with each thread getting a chunk of h.
        parallelize[worker](h)
    elif step.value >= BlogPost2Step.PARALLELIZE_FINE_2.value:
        # A parallel launch where we overpartition the work. Each thread is
        # now resposnible for multiple chunks and executes these chunks in a
        # round-robin manner.
        parallelize[worker](
            h,
            # Get the number of workers multiple.
            (step.value - BlogPost2Step.PARALLELIZE_FINE_2.value + 2)
            * num_cores(),
        )
    else:
        # The sequential non-parallel version.
        for row in range(h):
            worker(row)


fn main_blog_part2():
    constrained[width % 16 == 0, "must be a multiple of 16"]()

    var m = Tensor[int_type](height, width)

    alias ns_per_second: Int = 1_000_000_000

    mandelbrot[
        simdwidthof[DType.float64](), height, width, BlogPost2Step.PARALLELIZE
    ](m)

    var pixel_sum: Int = 0
    for i in range(height):
        for j in range(width):
            pixel_sum += m[i, j].to_int()
    print("pixel sum: ", pixel_sum)

    alias num_warmup = 1
    alias experiment_iter_count = 2
    var time: Float64

    # PART 1. Just vectorize
    @always_inline
    @parameter
    fn bench_vector[simd_width: Int]():
        mandelbrot[simd_width, height, width, BlogPost2Step.VECTORIZE](m)

    for i in range(experiment_iter_count):
        alias simd_width = simdwidthof[DType.float64]()
        time = (
            Benchmark(num_warmup).run[bench_vector[simd_width]]()
            / ns_per_second
        )
        print("Vectorize with simd_width=", simd_width, "::", time)

    # PART 2. Vectorize, fine grained
    @always_inline
    @parameter
    fn bench_vector_2[simd_width: Int]():
        mandelbrot[simd_width, height, width, BlogPost2Step.VECTORIZE_WIDE](m)

    for i in range(experiment_iter_count):
        alias simd_width = 2 * simdwidthof[DType.float64]()
        time = (
            Benchmark(num_warmup).run[bench_vector_2[simd_width]]()
            / ns_per_second
        )
        print("Vectorize with simd_width=", simd_width, "::", time)

    for i in range(experiment_iter_count):
        alias simd_width = 4 * simdwidthof[DType.float64]()
        time = (
            Benchmark(num_warmup).run[bench_vector_2[simd_width]]()
            / ns_per_second
        )
        print("Vectorize with simd_width=", simd_width, "::", time)

    for i in range(experiment_iter_count):
        alias simd_width = 8 * simdwidthof[DType.float64]()
        time = (
            Benchmark(num_warmup).run[bench_vector_2[simd_width]]()
            / ns_per_second
        )
        print("Vectorize with simd_width=", simd_width, "::", time)

    for i in range(experiment_iter_count):
        alias simd_width = 16 * simdwidthof[DType.float64]()
        time = (
            Benchmark(num_warmup).run[bench_vector_2[simd_width]]()
            / ns_per_second
        )
        print("Vectorize with simd_width=", simd_width, "::", time)

    # Parallelize the code.
    alias simd_width = 4 * simdwidthof[DType.float64]()

    @always_inline
    @parameter
    fn bench_parallel[simd_width: Int]():
        mandelbrot[simd_width, height, width, BlogPost2Step.PARALLELIZE](m)

    for i in range(experiment_iter_count):
        time = (
            Benchmark(num_warmup).run[bench_parallel[simd_width]]()
            / ns_per_second
        )
        print("Parallel with simd_width=", simd_width, "::", time)

    # Fine grained parallelism.

    @always_inline
    @parameter
    fn bench_parallel_2[simd_width: Int]():
        mandelbrot[simd_width, height, width, BlogPost2Step.PARALLELIZE_FINE_2](
            m
        )

    for i in range(experiment_iter_count):
        alias simd_width = 2 * simdwidthof[DType.float64]()
        time = (
            Benchmark(num_warmup).run[bench_parallel_2[simd_width]]()
            / ns_per_second
        )
        print("Parallel(2) with simd_width=", simd_width, "::", time)

    @always_inline
    @parameter
    fn bench_parallel_4[simd_width: Int]():
        mandelbrot[simd_width, height, width, BlogPost2Step.PARALLELIZE_FINE_4](
            m
        )

    for i in range(experiment_iter_count):
        alias simd_width = 4 * simdwidthof[DType.float64]()
        time = (
            Benchmark(num_warmup).run[bench_parallel_4[simd_width]]()
            / ns_per_second
        )
        print("Parallel(4) with simd_width=", simd_width, "::", time)

    @always_inline
    @parameter
    fn bench_parallel_8[simd_width: Int]():
        mandelbrot[simd_width, height, width, BlogPost2Step.PARALLELIZE_FINE_8](
            m
        )

    for i in range(experiment_iter_count):
        alias simd_width = 8 * simdwidthof[DType.float64]()
        time = (
            Benchmark(num_warmup).run[bench_parallel_8[simd_width]]()
            / ns_per_second
        )
        print("Parallel(8) with simd_width=", simd_width, "::", time)

    @always_inline
    @parameter
    fn bench_parallel_16[simd_width: Int]():
        mandelbrot[
            simd_width, height, width, BlogPost2Step.PARALLELIZE_FINE_16
        ](m)

    for i in range(experiment_iter_count):
        alias simd_width = 16 * simdwidthof[DType.float64]()
        time = (
            Benchmark(num_warmup).run[bench_parallel_16[simd_width]]()
            / ns_per_second
        )
        print("Parallel(16) with simd_width=", simd_width, "::", time)

    @always_inline
    @parameter
    fn bench_parallel_32[simd_width: Int]():
        mandelbrot[
            simd_width, height, width, BlogPost2Step.PARALLELIZE_FINE_32
        ](m)

    for i in range(experiment_iter_count):
        alias simd_width = 32 * simdwidthof[DType.float64]()
        time = (
            Benchmark(num_warmup).run[bench_parallel_32[simd_width]]()
            / ns_per_second
        )
        print("Parallel(32) with simd_width=", simd_width, "::", time)

    keep(m[Index(0, 0)])


fn main():
    # main_blog_part1()
    main_blog_part2()
