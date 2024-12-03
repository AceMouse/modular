# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Implements the Complex type.

You can import these APIs from the `complex` package. For example:

```mojo
from complex import ComplexSIMD
```
"""

from sys import llvm_intrinsic

alias ComplexFloat32 = ComplexSIMD[DType.float32, 1]
alias ComplexFloat64 = ComplexSIMD[DType.float64, 1]


# ===-----------------------------------------------------------------------===#
# ComplexSIMD
# ===-----------------------------------------------------------------------===#


@value
@register_passable("trivial")
struct ComplexSIMD[type: DType, size: Int](Stringable, Writable):
    """Represents a complex SIMD value.

    The class provides basic methods for manipulating complex values.

    Parameters:
        type: DType of the value.
        size: SIMD width of the value.
    """

    # ===-------------------------------------------------------------------===#
    # Fields
    # ===-------------------------------------------------------------------===#

    var re: SIMD[type, size]
    """The real part of the complex SIMD value."""
    var im: SIMD[type, size]
    """The imaginary part of the complex SIMD value."""

    # ===-------------------------------------------------------------------===#
    # Trait implementations
    # ===-------------------------------------------------------------------===#

    @no_inline
    fn __str__(self) -> String:
        """Get the complex as a string.

        Returns:
            A string representation.
        """
        return String.write(self)

    fn write_to[W: Writer](self, mut writer: W):
        """
        Formats this complex value to the provided Writer.

        Parameters:
            W: A type conforming to the Writable trait.

        Args:
            writer: The object to write to.
        """

        # TODO(MSTDL-700):
        #   Add a Writer.reserve() method, to afford writer implementions
        #   to request reservation of additional space from `Writer`
        #   implementations that support that. Then use the logic below to
        #   call that method here.

        # Reserve space for opening and closing brackets, plus each element and
        # its trailing commas.
        # var initial_buffer_size = 2
        # for i in range(size):
        #     initial_buffer_size += (
        #         _calc_initial_buffer_size(self.re[i])
        #         + _calc_initial_buffer_size(self.im[i])
        #         + 4  # for the ' + i' suffix on the imaginary
        #         + 2
        #     )
        # buf.reserve(initial_buffer_size)

        # Print an opening `[`.
        @parameter
        if size > 1:
            writer.write("[")

        # Print each element.
        for i in range(size):
            var re = self.re[i]
            var im = self.im[i]
            # Print separators between each element.
            if i != 0:
                writer.write(", ")

            writer.write(re)

            if im != 0:
                writer.write(" + ", im, "i")

        # Print a closing `]`.
        @parameter
        if size > 1:
            writer.write("]")

    @always_inline
    fn __abs__(self) -> SIMD[type, size]:
        """Returns the magnitude of the complex value.

        Returns:
            Value of `sqrt(re*re + im*im)`.
        """
        return self.norm()

    # ===-------------------------------------------------------------------===#
    # Operator dunders
    # ===-------------------------------------------------------------------===#

    @always_inline
    fn __add__(self, rhs: Self) -> Self:
        """Adds two complex values.

        Args:
            rhs: Complex value to add.

        Returns:
            A sum of this and RHS complex values.
        """
        return Self {re: self.re + rhs.re, im: self.im + rhs.im}

    @always_inline
    fn __mul__(self, rhs: Self) -> Self:
        """Multiplies two complex values.

        Args:
            rhs: Complex value to multiply with.

        Returns:
            A product of this and RHS complex values.
        """
        return Self(
            self.re.fma(rhs.re, -self.im * rhs.im),
            self.re.fma(rhs.im, self.im * rhs.re),
        )

    @always_inline
    fn __neg__(self) -> Self:
        """Negates the complex value.

        Returns:
            The negative of the complex value.
        """
        return ComplexSIMD(-self.re, -self.im)

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    @always_inline
    fn norm(self) -> SIMD[type, size]:
        """Returns the magnitude of the complex value.

        Returns:
            Value of `sqrt(re*re + im*im)`.
        """
        return llvm_intrinsic["llvm.sqrt", SIMD[type, size]](
            self.squared_norm()
        )

    @always_inline
    fn squared_norm(self) -> SIMD[type, size]:
        """Returns the squared magnitude of the complex value.

        Returns:
            Value of `re*re + im*im`.
        """
        return self.re.fma(self.re, self.im * self.im)

    # fma(self, b, c)
    @always_inline
    fn fma(self, b: Self, c: Self) -> Self:
        """Computes FMA operation.

        Compute fused multiple-add with two other complex values:
        `result = self * b + c`

        Args:
            b: Multiplier complex value.
            c: Complex value to add.

        Returns:
            Computed `Self * B + C` complex value.
        """
        return Self(
            self.re.fma(b.re, -(self.im.fma(b.im, -c.re))),
            self.re.fma(b.im, self.im.fma(b.re, c.im)),
        )

    # fma(self, self, c)
    @always_inline
    fn squared_add(self, c: Self) -> Self:
        """Computes Square-Add operation.

        Compute `Self * Self + C`.

        Args:
            c: Complex value to add.

        Returns:
            Computed `Self * Self + C` complex value.
        """
        return Self(
            self.re.fma(self.re, self.im.fma(-self.im, c.re)),
            self.re.fma(self.im + self.im, c.im),
        )


# TODO: we need this overload, because the Absable trait requires returning Self
# type. We could maybe get rid of this if we had associated types?
@always_inline
fn abs(x: ComplexSIMD[*_]) -> SIMD[x.type, x.size]:
    """Performs elementwise abs (norm) on each element of the complex value.

    Args:
        x: The complex vector to perform absolute value on.

    Returns:
        The elementwise abs of x.
    """
    return x.__abs__()
