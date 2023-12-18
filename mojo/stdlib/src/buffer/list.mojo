# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
"""Provides utilities for working with static and variadic lists.

You can import these APIs from the `utils` package. For example:

```mojo
from utils.list import Dim
```
"""

from memory.unsafe import Pointer
from utils._optional import Optional

# ===----------------------------------------------------------------------===#
# Dim
# ===----------------------------------------------------------------------===#


@value
@register_passable("trivial")
struct Dim(Intable):
    """A static or dynamic dimension modeled with an optional integer.

    This class is meant to represent an optional static dimension. When a value
    is present, the dimension has that static value. When a value is not
    present, the dimension is dynamic.
    """

    var value: Optional[Int]
    """An optional value for the dimension."""

    @always_inline("nodebug")
    fn __init__[type: Intable](value: type) -> Dim:
        """Creates a statically-known dimension.

        Parameters:
            type: The Intable type.

        Args:
            value: The static dimension value.

        Returns:
            A dimension with a static value.
        """
        return Self {value: int(value)}

    @always_inline("nodebug")
    fn __init__(value: __mlir_type.index) -> Dim:
        """Creates a statically-known dimension.

        Args:
            value: The static dimension value.

        Returns:
            A dimension with a static value.
        """
        return Self {value: Int(value)}

    @always_inline("nodebug")
    fn __init__() -> Dim:
        """Creates a dynamic dimension.

        Returns:
            A dimension value with no static value.
        """
        return Self {value: None}

    @always_inline("nodebug")
    fn __bool__(self) -> Bool:
        """Returns True if the dimension has a static value.

        Returns:
            Whether the dimension has a static value.
        """
        return self.value.__bool__()

    @always_inline("nodebug")
    fn has_value(self) -> Bool:
        """Returns True if the dimension has a static value.

        Returns:
            Whether the dimension has a static value.
        """
        return self.__bool__()

    @always_inline("nodebug")
    fn is_dynamic(self) -> Bool:
        """Returns True if the dimension has a dynamic value.

        Returns:
            Whether the dimension is dynamic.
        """
        return not self.has_value()

    @always_inline("nodebug")
    fn get(self) -> Int:
        """Gets the static dimension value.

        Returns:
            The static dimension value.
        """
        return self.value.value()

    @always_inline
    fn is_multiple[alignment: Int](self) -> Bool:
        """Checks if the dimension is aligned.

        Parameters:
            alignment: The alignment requirement.

        Returns:
            Whether the dimension is aligned.
        """
        if self.is_dynamic():
            return False
        return self.get() % alignment == 0

    @always_inline("nodebug")
    fn __mul__(self, rhs: Dim) -> Dim:
        """Multiplies two dimensions.

        If either are unknown, the result is unknown as well.

        Args:
            rhs: The other dimension.

        Returns:
            The product of the two dimensions.
        """
        if not self or not rhs:
            return Dim()
        return Dim(self.get() * rhs.get())

    @always_inline
    fn __floordiv__(self, rhs: Dim) -> Dim:
        """Divide two dimensions and round towards negative infinite.

        If either are unknown, the result is unknown as well.

        Args:
            rhs: The other dimension.

        Returns:
            The floor division of the two dimensions.
        """
        if not self or not rhs:
            return Dim()
        return Dim(self.get() // rhs.get())

    @always_inline("nodebug")
    fn __int__(self) -> Int:
        return self.value.value()

    @always_inline("nodebug")
    fn __eq__(self, rhs: Dim) -> Bool:
        """Compares two dimensions for equality.

        Args:
            rhs: The other dimension.

        Returns:
            True if the dimensions are the same.
        """
        if self and rhs:
            return self.get() == rhs.get()
        return (not self) == (not rhs)

    @always_inline("nodebug")
    fn __ne__(self, rhs: Dim) -> Bool:
        """Compare two dimensions for inequality.

        Args:
            rhs: The dimension to compare.

        Returns:
            True if they are not equal.
        """
        return not self == rhs


# ===----------------------------------------------------------------------===#
# DimList
# ===----------------------------------------------------------------------===#


@register_passable("trivial")
struct DimList(Sized):
    """This type represents a list of dimensions. Each dimension may have a
    static value or not have a value, which represents a dynamic dimension."""

    var value: VariadicList[Dim]
    """The underlying storage for the list of dimensions."""

    @always_inline("nodebug")
    fn __init__(values: VariadicList[Dim]) -> Self:
        """Creates a dimension list from the given list of values.

        Args:
            values: The initial dim values list.

        Returns:
            A dimension list.
        """
        return Self {value: values}

    @always_inline("nodebug")
    fn __init__(*values: Dim) -> Self:
        """Creates a dimension list from the given Dim values.

        Args:
            values: The initial dim values.

        Returns:
            A dimension list.
        """
        return values

    @always_inline("nodebug")
    fn __len__(self) -> Int:
        """Gets the size of the DimList.

        Returns:
            The number of elements in the DimList.
        """
        return len(self.value)

    @always_inline("nodebug")
    fn get[i: Int](self) -> Int:
        """Gets the static dimension value at a specified index.

        Parameters:
            i: The dimension index.

        Returns:
            The static dimension value at the specified index.
        """
        constrained[i >= 0, "index must be positive"]()
        return self.value[i].get()

    @always_inline("nodebug")
    fn at[i: Int](self) -> Dim:
        """Gets the dimension at a specified index.

        Parameters:
            i: The dimension index.

        Returns:
            The dimension at the specified index.
        """
        constrained[i >= 0, "index must be positive"]()
        return self.value[i]

    @always_inline
    fn _product_impl[i: Int, end: Int](self) -> Dim:
        @parameter
        if i >= end:
            return Dim(1)
        else:
            return self.at[i]() * self._product_impl[i + 1, end]()

    @always_inline
    fn product[length: Int](self) -> Dim:
        """Computes the product of all the dimensions in the list.

        If any are dynamic, the result is a dynamic dimension value.

        Parameters:
            length: The number of elements in the list.

        Returns:
            The product of all the dimensions.
        """
        return self._product_impl[0, length]()

    @always_inline
    fn product_range[start: Int, end: Int](self) -> Dim:
        """Computes the product of a range of the dimensions in the list.

        If any in the range are dynamic, the result is a dynamic dimension
        value.

        Parameters:
            start: The starting index.
            end: The end index.

        Returns:
            The product of all the dimensions.
        """
        return self._product_impl[start, end]()

    @always_inline
    fn _contains_impl[i: Int, length: Int](self, value: Dim) -> Bool:
        @parameter
        if i >= length:
            return False
        else:
            return self.at[i]() == value or self._contains_impl[i + 1, length](
                value
            )

    @always_inline
    fn contains[length: Int](self, value: Dim) -> Bool:
        """Determines whether the dimension list contains a specified dimension
        value.

        Parameters:
            length: The number of elements in the list.

        Args:
            value: The value to find.

        Returns:
            True if the list contains a dimension of the specified value.
        """
        return self._contains_impl[0, length](value)

    @always_inline
    fn all_known[length: Int](self) -> Bool:
        """Determines whether all dimensions are statically known.

        Parameters:
            length: The number of elements in the list.

        Returns:
            True if all dimensions have a static value.
        """
        return not self.contains[length](Dim())

    @always_inline
    @staticmethod
    fn create_unknown[length: Int]() -> Self:
        """Creates a dimension list of all dynamic dimension values.

        Parameters:
            length: The number of elements in the list.

        Returns:
            A list of all dynamic dimension values.
        """
        constrained[length > 0, "length must be positive"]()
        alias u = Dim()

        @parameter
        if length == 1:
            return rebind[Self](DimList(u))
        elif length == 2:
            return rebind[Self](DimList(u, u))
        elif length == 3:
            return rebind[Self](DimList(u, u, u))
        elif length == 4:
            return rebind[Self](DimList(u, u, u, u))
        elif length == 5:
            return rebind[Self](DimList(u, u, u, u, u))
        elif length == 6:
            return rebind[Self](DimList(u, u, u, u, u, u))
        elif length == 7:
            return rebind[Self](DimList(u, u, u, u, u, u, u))
        elif length == 8:
            return rebind[Self](DimList(u, u, u, u, u, u, u, u))
        elif length == 9:
            return rebind[Self](DimList(u, u, u, u, u, u, u, u, u))
        elif length == 10:
            return rebind[Self](DimList(u, u, u, u, u, u, u, u, u, u))
        elif length == 11:
            return rebind[Self](DimList(u, u, u, u, u, u, u, u, u, u, u))
        elif length == 12:
            return rebind[Self](DimList(u, u, u, u, u, u, u, u, u, u, u, u))
        elif length == 13:
            return rebind[Self](DimList(u, u, u, u, u, u, u, u, u, u, u, u, u))
        elif length == 14:
            return rebind[Self](
                DimList(u, u, u, u, u, u, u, u, u, u, u, u, u, u)
            )
        elif length == 15:
            return rebind[Self](
                DimList(u, u, u, u, u, u, u, u, u, u, u, u, u, u, u)
            )
        else:
            return rebind[Self](
                DimList(u, u, u, u, u, u, u, u, u, u, u, u, u, u, u, u)
            )
