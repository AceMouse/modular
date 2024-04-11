# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
#
# This file is only run on targets with Intel AMX and Linux.
#
# ===----------------------------------------------------------------------=== #
# REQUIRES: linux, intel_amx
# RUN: %mojo %s | FileCheck %s


from sys.info import has_intel_amx, os_is_linux

from buffer import Buffer, NDBuffer
from buffer.list import Dim, DimList
from LinAlg.intel_amx_intrinsics import (
    _tile_dpbssd,
    _tile_dpbssd_emulated,
    _tile_loadconfig,
    _tile_loadd,
    _tile_release,
    _tile_storeconfig,
    _tile_stored,
    _tile_zero,
    init_intel_amx,
    tileconfig,
)
from LinAlg.Matmul import Matrix, naive_matmul
from memory import memcmp, memset_zero
from memory.unsafe import DTypePointer, Pointer
from LinAlg.transpose import transpose, transpose_inplace

from utils.loop import unroll

alias void = DType.invalid.value
alias int32_pop = __mlir_type.`!pop.scalar<si32>`
alias int8_pop = __mlir_type.`!pop.scalar<si8>`


fn print_buffer[n: Int, type: DType](a_ptr: DTypePointer[void]):
    var a = Buffer[type](a_ptr.bitcast[type](), n)
    for i in range(n):
        var v = __mlir_op.`pop.cast`[_type=int32_pop](a[i].value)
        print(v)


fn print_matrix[m: Int, n: Int, type: DType](a_ptr: DTypePointer[void]):
    var a = Buffer[type](a_ptr.bitcast[type](), m * n)
    for i in range(m):
        print("row")
        for j in range(n):
            var ai = __mlir_op.`pop.cast`[_type=int32_pop](a[n * i + j].value)
            print(ai)


@always_inline
fn identity_epilogue_rowise_func[
    accum_type: DType
](row_idx: Int, row: Buffer[accum_type]):
    pass


@always_inline
fn identity_epilogue_elemwise_func[
    accum_type: DType
](row: Int, col: Int, val: SIMD[accum_type, 1]) -> SIMD[accum_type, 1]:
    return val


fn init_matrices(
    a_ptr: DTypePointer[DType.int8],
    b_ptr: DTypePointer[DType.int8],
    c_ptr: DTypePointer[DType.int32],
    c2_ptr: DTypePointer[DType.int32],
):
    var a = Buffer[DType.int8](a_ptr.address, 1024)
    var b = Buffer[DType.int8](b_ptr.address, 1024)
    var c = Buffer[DType.int32](c_ptr.address, 256)
    var c2 = Buffer[DType.int32](c2_ptr.address, 256)
    var b2 = Buffer[DType.int8, 1024].stack_allocation()

    for i in range(1024):
        a[i] = Int8(i & 127)
        b2[i] = Int8(i & 127)

    memset_zero[DType.int32](c.data, 1024)
    memset_zero[DType.int32](c2.data, 1024)

    var b2m = NDBuffer[DType.int8, 2, DimList(64, 16)](b2.data.address)
    var bm = NDBuffer[DType.int8, 2, DimList(16, 64)](b_ptr.address)
    # transpose from 64x16 to 16x64
    transpose[2, DimList(16, 64), DimList(64, 16), DType.int8](bm, b2m)

    var b32_ptr = b.data.bitcast[DType.int32]()
    var b32m = NDBuffer[DType.int32, 2, DimList(16, 16)](b32_ptr.address)
    transpose_inplace[16, 16, DType.int32](b32m)
    var am = NDBuffer[DType.int8, 2, DimList(16, 64)](a.data.address)
    var c2m = NDBuffer[DType.int32, 2, DimList(16, 16)](c2.data.address)
    naive_matmul[
        DimList(16, 64),
        DimList(64, 16),
        DimList(16, 16),
        DType.int32,
        DType.int8,
        False,
        False,
        identity_epilogue_elemwise_func,
        identity_epilogue_rowise_func,
    ](c2m, am, b2m)


fn setup_tile_config() -> tileconfig:
    var tc: tileconfig
    var ptr = Pointer.address_of(tc)
    var tc_ptr = DTypePointer[DType.int8](ptr.bitcast[int8_pop]().address)
    memset_zero(tc_ptr, 64)

    var nrows: UInt8 = 16
    var colb: UInt16 = 64

    tc.palette_id = 1

    @always_inline
    fn tc_fill[idx: Int]():
        tc.rows[idx] = nrows.value
        tc.colb[idx] = colb.value

    unroll[tc_fill, 8]()
    return tc


fn main():
    var a = Buffer[DType.int8, 1024].stack_allocation()
    var b = Buffer[DType.int8, 1024].stack_allocation()
    var c = Buffer[DType.int32, 256].stack_allocation()
    var c2 = Buffer[DType.int32, 256].stack_allocation()

    init_matrices(a.data, b.data, c.data, c2.data)
    # print_matrix[16, 64, DType.int8](b.data.bitcast[void]())

    _tile_dpbssd_emulated(c.data, a.data, b.data)
    # print_matrix[16, 16, DType.int32](c.data.bitcast[void]())
    var errors: Int = 0
    errors = memcmp(c.data, c2.data, len(c))
    print("Emulated AMX-int8 matmul test.")
    # CHECK: 0
    print(errors)
    if errors != 0:
        print("Matrices don't agree!")
    memset_zero[DType.int32](c.data, 1024)
    if os_is_linux() and has_intel_amx() and init_intel_amx():
        print("Hardware AMX-int8 matmul test.")
        var tc = setup_tile_config()
        var ptr = Pointer[tileconfig].address_of(tc)
        var tc_ptr = DTypePointer[void](
            ptr.bitcast[__mlir_type.`!pop.scalar<invalid>`]().address
        )

        _tile_loadconfig(tc_ptr)
        # _tile_storeconfig(tc_ptr)
        _tile_zero[0]()
        _tile_loadd[1](a.data.bitcast[void](), 64)
        _tile_loadd[2](b.data.bitcast[void](), 64)
        _tile_dpbssd[0, 1, 2]()
        _tile_stored[0](c.data.bitcast[void](), 64)
        _tile_release()

        errors = memcmp(c.data.bitcast[void](), c2.data.bitcast[void](), len(c))
    # CHECK: 0
    print(errors)
    if errors != 0:
        print("\nMatrices don't agree!")
