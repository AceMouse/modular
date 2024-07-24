# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo %s | FileCheck %s

from buffer import Buffer
from memory import UnsafePointer

alias simd_width = 8


fn strsv[
    size: Int
](L: Buffer[DType.float32, size * size], x: Buffer[DType.float32, size]):
    # assuming size is a multiple of simd_width
    var x_ptr = UnsafePointer[Float32](x.data)
    var L_ptr = UnsafePointer[Float32](L.data)
    var n: Int = size
    var x_solved = Buffer[
        DType.float32, simd_width * simd_width
    ].stack_allocation[alignment=64]()

    while True:
        for j in range(simd_width):
            var x_j = x_ptr[j]
            for i in range(j + 1, simd_width):
                x_ptr[i] = x_j.fma(-L_ptr[i + j * size], x_ptr[i])

        n -= simd_width
        if n <= 0:
            return

        # Save the solution of the triangular tile in stack, while
        # packing them as simd vectors.
        var x_vec: SIMD[DType.float32, simd_width] = 0.0
        for i in range(simd_width):
            # Broadcast one solution value to a simd vector.
            x_vec = x_ptr[i]
            x_solved.store(i * simd_width, x_vec)

        x_ptr += simd_width
        L_ptr += simd_width

        # Update the columns under the triangular tile
        # Move down tile by tile.
        var x_solved_vec: SIMD[DType.float32, simd_width] = 0
        var L_col_vec: SIMD[DType.float32, simd_width] = 0

        for i in range(0, n, simd_width):
            x_vec = SIMD[size=simd_width].load(x_ptr, i)
            # Move to right column by column within in a tile.
            for j in range(simd_width):
                x_solved_vec = x_solved.load[width=simd_width](j * simd_width)
                L_col_vec = SIMD[size=simd_width].load(L_ptr, i + j * size)
                x_vec = x_solved_vec.fma(-L_col_vec, x_vec)
            SIMD[size=simd_width].store(x_ptr, i, x_vec)

        L_ptr += size * simd_width


# Fill the lower triangle matrix.
fn fill_L[size: Int](L: Buffer[DType.float32, size * size]):
    for j in range(size):
        for i in range(size):
            if i == j:
                L[i + j * size] = 1.0
            else:
                L[i + j * size] = -2.5 / Float32(size * (size - 1))


# Fill the rhs, which is also used to save the solution vector.
fn fill_x[size: Int](x: Buffer[DType.float32, size]):
    for i in range(size):
        x[i] = 1.0


fn naive_strsv[
    size: Int
](L: Buffer[DType.float32, size * size], x: Buffer[DType.float32, size]):
    for j in range(size):
        var x_j = x[j]
        for i in range(j + 1, size):
            x[i] = x[i] - x_j * L[i + j * size]


# CHECK-LABEL: test_strsv
fn test_strsv():
    print("== test_strsv")

    alias size: Int = 64
    var L = Buffer[DType.float32, size * size].stack_allocation()
    var x0 = Buffer[DType.float32, size].stack_allocation()
    var x1 = Buffer[DType.float32, size].stack_allocation()

    fill_L[size](L)
    fill_x[size](x0)
    fill_x[size](x1)
    naive_strsv[size](L, x0)
    strsv[size](L, x1)

    var err: Float32 = 0.0
    for i in range(x0.__len__()):
        err += abs(x0[i] - x1[i])

    # CHECK: 0.0
    print(err)


fn main():
    test_strsv()
