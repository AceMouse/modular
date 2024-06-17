# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo %s | FileCheck %s

from sys.info import simdwidthof

from buffer import NDBuffer
from buffer.list import DimList
from linalg.packing import PackMatrixCols

from utils.index import Index

alias type = DType.float32
alias simd_size: Int = simdwidthof[DType.float32]()
alias simd_cols: Int = 4
alias kernel_cols: Int = simd_cols * simd_size
alias width = 2 * kernel_cols

alias N: Int = 128
alias K: Int = 128
alias kc = 128


@export(ABI="C")
fn pack_b(
    packed_b: NDBuffer[type, 3, DimList(width // kernel_cols, K, kernel_cols)],
    b: NDBuffer[type, 2, DimList(K, N)],
):
    PackMatrixCols[
        DimList(K, N),
        DimList(width // kernel_cols, K, kernel_cols),
        type,
        simd_size,
        kernel_cols,
        False,  # use_vnni
        False,  # use_i8mm
    ].run(
        packed_b,
        b,
        Index(0, 0),
        Index(kc, width),
        Index(K, N),
    )


fn test_pack_b():
    var packed_b = NDBuffer[
        type, 3, DimList(width // kernel_cols, K, kernel_cols)
    ].aligned_stack_allocation[64]()
    packed_b.fill(1)
    var b = NDBuffer[type, 2, DimList(K, N)].aligned_stack_allocation[64]()
    b.fill(1)
    pack_b(packed_b, b)

    # CHECK: 1.0
    print(packed_b[0, 0, 0])


fn main():
    test_pack_b()
