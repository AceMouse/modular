# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Implements CUDA stream operations."""

from os import abort


from ._utils import _check_error, _StreamHandle


# ===----------------------------------------------------------------------===#
# Stream
# ===----------------------------------------------------------------------===#


struct Stream(CollectionElement):
    var stream: _StreamHandle
    var owning: Bool
    var cuda_dll: CudaDLL

    fn __init__(inout self, stream: _StreamHandle, cuda_dll: CudaDLL):
        self.stream = stream
        self.owning = False
        self.cuda_dll = cuda_dll

    fn __init__(inout self, ctx: Context, stream: _StreamHandle):
        self.__init__(stream, ctx.cuda_dll)

    fn __init__(
        inout self,
        cuda_dll: CudaDLL,
        flags: Int = 0,
    ) raises:
        self.stream = _StreamHandle()
        self.cuda_dll = cuda_dll
        self.owning = True

        var cuStreamCreate = self.cuda_dll.cuStreamCreate
        _check_error(
            cuStreamCreate(UnsafePointer.address_of(self.stream), Int32(flags))
        )

    fn __init__(inout self, *, other: Self):
        """Explicitly construct a deep copy of the provided value.

        Args:
            other: The value to copy.
        """
        self = other

    fn __init__(inout self, ctx: Context, flags: Int = 0) raises:
        self.__init__(ctx.cuda_dll, flags)

    fn __del__(owned self):
        try:
            var cuStreamDestroy = self.cuda_dll.cuStreamDestroy
            if self.owning and self.stream:
                _check_error(cuStreamDestroy(self.stream))
        except e:
            abort(e.__str__())

    fn __copyinit__(inout self, existing: Self):
        self.stream = existing.stream
        self.owning = False
        self.cuda_dll = existing.cuda_dll

    fn __moveinit__(inout self, owned existing: Self):
        self.stream = existing.stream
        self.owning = existing.owning
        self.cuda_dll = existing.cuda_dll
        existing.stream = _StreamHandle()
        existing.owning = False
        existing.cuda_dll = CudaDLL()

    fn synchronize(self) raises:
        """Wait until a CUDA stream's tasks are completed."""
        if self.stream:
            var cuStreamSynchronize = self.cuda_dll.cuStreamSynchronize
            _check_error(cuStreamSynchronize(self.stream))
