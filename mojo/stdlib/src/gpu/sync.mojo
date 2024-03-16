# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""This module includes intrinsics for NVIDIA GPUs sync instructions."""

from sys import llvm_intrinsic

from memory.unsafe import AddressSpace, DTypePointer, Pointer

from .memory import AddressSpace as GPUAddressSpace

# ===----------------------------------------------------------------------===#
# barrier
# ===----------------------------------------------------------------------===#


@always_inline("nodebug")
fn barrier():
    """Performs a synchronization barrier on block (equivelent to `__syncthreads`
    in CUDA).
    """
    __mlir_op.`nvvm.barrier0`()


# ===----------------------------------------------------------------------===#
# syncwarp
# ===----------------------------------------------------------------------===#


@always_inline("nodebug")
fn syncwarp(mask: Int = -1):
    """Causes all threads to wait until all lanes specified by the warp mask
    reach the sync warp.

    Args:
      mask: The mask of the warp lanes.
    """
    __mlir_op.`nvvm.bar.warp.sync`(
        __mlir_op.`index.casts`[_type = __mlir_type.i32](mask.value)
    )


# ===----------------------------------------------------------------------===#
# mbarrier
# ===----------------------------------------------------------------------===#


@always_inline("nodebug")
fn _mbarrier_impl[
    type: AnyRegType, address_space: AddressSpace
](address: Pointer[type, address_space]):
    """Makes the mbarrier object track all prior copy async operations initiated
    by the executing thread.

    Args:
      address: The mbarrier object is at the location.
    """

    @parameter
    if address_space == GPUAddressSpace.SHARED:
        llvm_intrinsic["llvm.nvvm.cp.async.mbarrier.arrive.shared", NoneType](
            address
        )
    elif (
        address_space == GPUAddressSpace.GLOBAL
        or address_space == GPUAddressSpace.GENERIC
    ):
        llvm_intrinsic["llvm.nvvm.cp.async.mbarrier.arrive", NoneType](
            address.address_space_cast[GPUAddressSpace.GENERIC]().address
        )
    else:
        constrained[False, "invalid address space"]()


@always_inline("nodebug")
fn mbarrier[
    type: AnyRegType, address_space: AddressSpace
](address: Pointer[type, address_space]):
    """Makes the mbarrier object track all prior copy async operations initiated
    by the executing thread.

    Args:
      address: The mbarrier object is at the location.
    """

    _mbarrier_impl(address)


@always_inline("nodebug")
fn mbarrier[
    type: DType, address_space: AddressSpace
](address: DTypePointer[type, address_space]):
    """Makes the mbarrier object track all prior copy async operations initiated
    by the executing thread.

    Args:
      address: The mbarrier object is at the location.
    """

    _mbarrier_impl(address.address)


@always_inline("nodebug")
fn mbarrier_init[
    type: DType
](shared_mem: DTypePointer[type, GPUAddressSpace.SHARED], num_threads: Int32):
    """Initialize shared memory barrier for N number of threads.

    Args:
        shared_mem: Shared memory barrier to initialize.
        num_threads: Number of threads participating.
    """
    llvm_intrinsic["llvm.nvvm.mbarrier.init.shared", NoneType](
        shared_mem, num_threads
    )


@always_inline("nodebug")
fn mbarrier_init[
    type: AnyRegType
](shared_mem: Pointer[type, GPUAddressSpace.SHARED], num_threads: Int32):
    """Initialize shared memory barrier for N number of threads.

    Args:
        shared_mem: Shared memory barrier to initialize.
        num_threads: Number of threads participating.
    """
    llvm_intrinsic["llvm.nvvm.mbarrier.init.shared", NoneType](
        shared_mem, num_threads
    )


@always_inline("nodebug")
fn mbarrier_arrive[
    type: DType
](shared_mem: DTypePointer[type, GPUAddressSpace.SHARED]) -> Int:
    """Commits the arrival of thead to a shared memory barrier.

    Args:
        shared_mem: Shared memory barrier.

    Returns:
        An Int64 value representing the state of the memory barrier.
    """
    return llvm_intrinsic["llvm.nvvm.mbarrier.arrive.shared", Int](shared_mem)


@always_inline("nodebug")
fn mbarrier_test_wait[
    type: AnyRegType
](shared_mem: Pointer[type, GPUAddressSpace.SHARED], state: Int) -> Bool:
    """Test waiting for the memory barrier.

    Args:
        shared_mem: Shared memory barrier.
        state: Memory barrier arrival state.

    Returns:
        True if all particpating thread arrived to the barrier.
    """
    return llvm_intrinsic["llvm.nvvm.mbarrier.test.wait.shared", Bool](
        shared_mem, state
    )


@always_inline("nodebug")
fn mbarrier_test_wait[
    type: DType
](shared_mem: DTypePointer[type, GPUAddressSpace.SHARED], state: Int) -> Bool:
    """Test waiting for the memory barrier.

    Args:
        shared_mem: Shared memory barrier.
        state: Memory barrier arrival state.

    Returns:
        True if all particpating thread arrived to the barrier.
    """
    return llvm_intrinsic["llvm.nvvm.mbarrier.test.wait.shared", Bool](
        shared_mem, state
    )
