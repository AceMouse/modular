# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""This module includes NVIDIA GPUs id operations."""

from sys import llvm_intrinsic

# ===----------------------------------------------------------------------===#
# ThreadIdx
# ===----------------------------------------------------------------------===#


struct ThreadIdx:
    """ThreadIdx provides static methods for getting the x/y/z coordinates of
    a thread within a block."""

    @staticmethod
    @always_inline("nodebug")
    fn x() -> Int:
        """Gets the `x` coordinate of the thread within the block.

        Returns:
            The `x` coordinate within the block.
        """
        return int(llvm_intrinsic["llvm.nvvm.read.ptx.sreg.tid.x", Int32]())

    @staticmethod
    @always_inline("nodebug")
    fn y() -> Int:
        """Gets the `y` coordinate of the thread within the block.

        Returns:
            The `y` coordinate within the block.
        """
        return int(llvm_intrinsic["llvm.nvvm.read.ptx.sreg.tid.y", Int32]())

    @staticmethod
    @always_inline("nodebug")
    fn z() -> Int:
        """Gets the `z` coordinate of the thread within the block.

        Returns:
            The `z` coordinate within the block.
        """
        return int(llvm_intrinsic["llvm.nvvm.read.ptx.sreg.tid.z", Int32]())


# ===----------------------------------------------------------------------===#
# BlockIdx
# ===----------------------------------------------------------------------===#


struct BlockIdx:
    """BlockIdx provides static methods for getting the x/y/z coordinates of
    a block within a grid."""

    @staticmethod
    @always_inline("nodebug")
    fn x() -> Int:
        """Gets the `x` coordinate of the block within a grid.

        Returns:
            The `x` coordinate within the grid.
        """
        return int(llvm_intrinsic["llvm.nvvm.read.ptx.sreg.ctaid.x", Int32]())

    @staticmethod
    @always_inline("nodebug")
    fn y() -> Int:
        """Gets the `y` coordinate of the block within a grid.

        Returns:
            The `y` coordinate within the grid.
        """
        return int(llvm_intrinsic["llvm.nvvm.read.ptx.sreg.ctaid.y", Int32]())

    @staticmethod
    @always_inline("nodebug")
    fn z() -> Int:
        """Gets the `z` coordinate of the block within a grid.

        Returns:
            The `z` coordinate within the grid.
        """
        return int(llvm_intrinsic["llvm.nvvm.read.ptx.sreg.ctaid.z", Int32]())


# ===----------------------------------------------------------------------===#
# BlockDim
# ===----------------------------------------------------------------------===#


struct BlockDim:
    """BlockDim provides static methods for getting the x/y/z dimension of a
    block."""

    @staticmethod
    @always_inline("nodebug")
    fn x() -> Int:
        """Gets the `x` dimension of the block.

        Returns:
            The `x` dimension of the block.
        """
        return int(llvm_intrinsic["llvm.nvvm.read.ptx.sreg.ntid.x", Int32]())

    @staticmethod
    @always_inline("nodebug")
    fn y() -> Int:
        """Gets the `y` dimension of the block.

        Returns:
            The `y` dimension of the block.
        """
        return int(llvm_intrinsic["llvm.nvvm.read.ptx.sreg.ntid.y", Int32]())

    @staticmethod
    @always_inline("nodebug")
    fn z() -> Int:
        """Gets the `z` dimension of the block.

        Returns:
            The `z` dimension of the block.
        """
        return int(llvm_intrinsic["llvm.nvvm.read.ptx.sreg.ntid.z", Int32]())


# ===----------------------------------------------------------------------===#
# GridDim
# ===----------------------------------------------------------------------===#


struct GridDim:
    """GridDim provides static methods for getting the x/y/z dimension of a
    grid."""

    @staticmethod
    @always_inline("nodebug")
    fn x() -> Int:
        """Gets the `x` dimension of the grid.

        Returns:
            The `x` dimension of the grid.
        """
        return int(llvm_intrinsic["llvm.nvvm.read.ptx.sreg.nctaid.x", Int32]())

    @staticmethod
    @always_inline("nodebug")
    fn y() -> Int:
        """Gets the `y` dimension of the grid.

        Returns:
            The `y` dimension of the grid.
        """
        return int(llvm_intrinsic["llvm.nvvm.read.ptx.sreg.nctaid.y", Int32]())

    @staticmethod
    @always_inline("nodebug")
    fn z() -> Int:
        """Gets the `z` dimension of the grid.

        Returns:
            The `z` dimension of the grid.
        """
        return int(llvm_intrinsic["llvm.nvvm.read.ptx.sreg.nctaid.z", Int32]())


# ===----------------------------------------------------------------------===#
# lane_id
# ===----------------------------------------------------------------------===#


@always_inline("nodebug")
fn lane_id() -> UInt32:
    """Returns the lane ID of the current thread.

    Returns:
        The lane ID of the the current thread.
    """
    return llvm_intrinsic["llvm.nvvm.read.ptx.sreg.laneid", Int32]().cast[
        DType.uint32
    ]()


# ===----------------------------------------------------------------------===#
# sm_id
# ===----------------------------------------------------------------------===#


@always_inline("nodebug")
fn sm_id() -> UInt32:
    """Returns the SM ID of the current thread.

    Returns:
        The SM ID of the the current thread.
    """
    return llvm_intrinsic["llvm.nvvm.read.ptx.sreg.smid", Int32]().cast[
        DType.uint32
    ]()
