# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from layout.int_tuple import IntTuple, flatten

from layout.int_tuple import prefix_product as prefix_product_int_tuple
from layout.int_tuple import idx2crd as idx2crd_int_tuple, UNKNOWN_VALUE

from utils.static_tuple import InlineArray


fn concat(owned lhs: IntTuple, rhs: IntTuple) -> IntTuple:
    for i in range(len(rhs)):
        lhs.append(rhs[i])
    return lhs


@register_passable("trivial")
struct RuntimeTuple[S: IntTuple = UNKNOWN_VALUE](Stringable, Sized):
    alias scalar_length = len(flatten(S))
    var value: StaticIntTuple[Self.scalar_length]

    @always_inline
    fn __init__(inout self):
        self.value = StaticIntTuple[Self.scalar_length]()

        alias f = flatten(S)

        @parameter
        for i in range(Self.scalar_length):
            alias v = f[i].value()

            @parameter
            if v != UNKNOWN_VALUE:
                self.value[i] = v

    @always_inline
    fn __init__(inout self, *values: Int):
        self.value = values

    @always_inline
    fn __init__[l: Int](inout self, values: StaticIntTuple[l]):
        constrained[Self.scalar_length == l, "Must use same tuple length"]()
        self.value = rebind[StaticIntTuple[Self.scalar_length]](values)

    @staticmethod
    @always_inline
    fn offset_until[i: Int]() -> Int:
        var result = 0

        @parameter
        for j in range(i):
            result += len(flatten(S[j]))
        return result

    @always_inline
    fn get_int(self) -> Int:
        alias comptime_value: Int = S.value()

        @parameter
        if comptime_value != UNKNOWN_VALUE:
            return comptime_value
        else:
            return self.value[0]

    @always_inline
    fn __getitem__[i: Int](self) -> RuntimeTuple[S[i]]:
        var res = RuntimeTuple[S[i]]()
        alias offset = Self.offset_until[i]()

        @parameter
        for i in range(Self.scalar_length - offset):
            res.value[i] = self.value[i + offset]
        return res

    @always_inline
    fn __setitem__[i: Int](inout self, val: Int):
        alias offset = Self.offset_until[i]()
        self.value[offset] = val

    @always_inline
    fn __str__(self) -> String:
        return String.format_sequence(self)

    @always_inline
    fn concat[
        R: IntTuple
    ](self, rhs: RuntimeTuple[R]) -> RuntimeTuple[concat(S, R)]:
        var out = RuntimeTuple[concat(S, R)]()

        alias S_flat = flatten(S)

        @parameter
        for i in range(Self.scalar_length):

            @parameter
            if S_flat[i] == UNKNOWN_VALUE:
                out.value[i] = self.value[i]

        alias R_flat = flatten(R)

        @parameter
        for i in range(rhs.scalar_length):

            @parameter
            if R_flat[i] == UNKNOWN_VALUE:
                out.value[Self.scalar_length + i] = rhs.value[i]

        return out

    @always_inline
    fn flatten(self) -> RuntimeTuple[flatten(S)]:
        return RuntimeTuple[flatten(S)](self.value)

    fn format_to(self, inout f: Formatter):
        @parameter
        if S.is_value():
            self.get_int().format_to(f)
        else:
            f.write_str["("]()

            alias size = len(S)

            @parameter
            for i in range(size):
                self[i].format_to(f)

                @parameter
                if i != size - 1:
                    f.write_str[", "]()
            f.write_str[")"]()

    @always_inline
    fn __len__(self) -> Int:
        return len(S)


fn is_tuple[t: IntTuple](tuple: RuntimeTuple[t]) -> Bool:
    return t.is_tuple()


fn is_int[t: IntTuple](tuple: RuntimeTuple[t]) -> Bool:
    return t.is_value()


@always_inline
fn to_int[t: IntTuple](tuple: RuntimeTuple[t]) -> Int:
    constrained[t.is_value(), "tuple must be a single int value"]()
    return tuple.value[0]


@always_inline
fn prefix_product[
    t: IntTuple
](tuple: RuntimeTuple[t]) -> RuntimeTuple[prefix_product_int_tuple(t)]:
    var res = RuntimeTuple[prefix_product_int_tuple(t)]()
    var prefix_res = 1
    for i in range(tuple.scalar_length):
        res.value[i] = prefix_res
        prefix_res *= tuple.value[i]
    return res


@always_inline
fn product[t: IntTuple](tuple: RuntimeTuple[t]) -> Int:
    var res: Int = 1

    @parameter
    for i in range(tuple.scalar_length):
        res *= tuple.value[i]
    return res


@always_inline
fn idx2crd[
    idx_t: IntTuple, shape_t: IntTuple, stride_t: IntTuple
](
    idx: RuntimeTuple[idx_t],
    shape: RuntimeTuple[shape_t],
    stride: RuntimeTuple[stride_t],
) -> RuntimeTuple[idx2crd_int_tuple(idx_t, shape_t, stride_t)]:
    var res = RuntimeTuple[idx2crd_int_tuple(idx_t, shape_t, stride_t)]()
    constrained[idx_t.is_value(), "Only scalar index is supported"]()
    for i in range(res.scalar_length):
        res.value[i] = (to_int(idx) // stride.value[i]) % shape.value[i]
    return res


@always_inline
fn idx2crd[
    idx_t: IntTuple, shape_t: IntTuple
](idx: RuntimeTuple[idx_t], shape: RuntimeTuple[shape_t]) -> RuntimeTuple[
    idx2crd_int_tuple(idx_t, shape_t, prefix_product_int_tuple(shape_t))
]:
    return idx2crd(idx, shape, prefix_product(shape))


fn crd2idx[
    crd_t: IntTuple, shape_t: IntTuple, stride_t: IntTuple
](
    crd: RuntimeTuple[crd_t],
    shape: RuntimeTuple[shape_t],
    stride: RuntimeTuple[stride_t],
) -> Int:
    @parameter
    if crd_t.is_tuple():
        constrained[
            shape_t.is_tuple()
            and (len(crd_t) == len(shape_t) == len(stride_t)),
            "Inputs should have same rank",
        ]()
        var r: Int = 0
        alias size = min(min(len(crd_t), len(shape_t)), len(stride_t))

        @parameter
        for i in range(size):
            r += crd2idx(crd[i], shape[i], stride[i])
        return r
    else:
        var int_crd: Int = 0 if len(crd) == 0 else to_int(crd)

        @parameter
        if shape_t.is_tuple():  # "int" tuple tuple
            constrained[
                len(shape_t) == len(stride_t),
                "shape and stride should have same rank",
            ]()
            var result: Int = 0

            alias last_elem_idx = len(shape_t) - 1

            @parameter
            for i in range(last_elem_idx):
                var divisor_quotient = divmod(int_crd, product(shape[i]))
                result += crd2idx(divisor_quotient[1], shape[i], stride[i])
                int_crd = divisor_quotient[0]
            # FIXME(KERN-640): Replace with [-1], currently not giving correct result.
            return result + crd2idx(
                int_crd, shape[last_elem_idx], stride[last_elem_idx]
            )
        else:  # "int" "int" "int"
            return int_crd * to_int(stride)
