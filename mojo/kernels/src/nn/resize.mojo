# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from math import ceil, floor, max, min, round_half_down, round_half_up

from algorithm.functional import elementwise
from algorithm.reduction import _get_nd_indices_from_flat_index
from memory.buffer import NDBuffer
from collections.vector import InlinedFixedVector


@value
struct CoordinateTransformationMode:
    var value: Int
    alias HalfPixel = CoordinateTransformationMode(0)
    alias AlignCorners = CoordinateTransformationMode(1)
    alias Asymmetric = CoordinateTransformationMode(2)

    @always_inline
    fn __eq__(self, other: CoordinateTransformationMode) -> Bool:
        return self.value == other.value


@parameter
@always_inline
fn coord_transform[
    mode: CoordinateTransformationMode
](out_coord: Int, in_dim: Int, out_dim: Int, scale: Float32) -> Float32:
    @parameter
    if mode == CoordinateTransformationMode.HalfPixel:
        # note: coordinates are for the CENTER of the pixel
        # - 0.5 term at the end is so that when we round to the nearest integer
        # coordinate, we get the coordinate whose center is closest
        return (out_coord + 0.5) / scale - 0.5
    elif mode == CoordinateTransformationMode.AlignCorners:
        # aligning "corners" when output is 1D isn't well defined
        # this matches pytorch
        if out_dim == 1:
            return 0
        # note: resized image will have same corners as original image
        return out_coord * ((in_dim - 1) / (out_dim - 1)).cast[DType.float32]()
    elif mode == CoordinateTransformationMode.Asymmetric:
        return out_coord / scale
    else:
        constrained[True, "coordinate_transformation_mode not implemented"]()
        return 0


@value
struct RoundMode:
    var value: Int
    alias HalfDown = RoundMode(0)
    alias HalfUp = RoundMode(1)
    alias Floor = RoundMode(2)
    alias Ceil = RoundMode(3)

    @always_inline
    fn __eq__(self, other: RoundMode) -> Bool:
        return self.value == other.value


@value
struct InterpolationMode:
    var value: Int
    alias Linear = InterpolationMode(0)

    @always_inline
    fn __eq__(self, other: InterpolationMode) -> Bool:
        return self.value == other.value


@value
@register_passable("trivial")
struct Interpolator[mode: InterpolationMode]:
    var cubic_coeff: Float32

    @always_inline
    fn __init__(cubic_coeff: Float32) -> Self:
        return Self {cubic_coeff: cubic_coeff}

    @always_inline
    fn __init__() -> Self:
        return Self {cubic_coeff: 0}

    @staticmethod
    @always_inline
    fn filter_length() -> Int:
        @parameter
        if mode == InterpolationMode.Linear:
            return 1
        else:
            constrained[False, "InterpolationMode not supported"]()
            return -1

    @always_inline
    fn filter(self, x: Float32) -> Float32:
        @parameter
        if mode == InterpolationMode.Linear:
            return linear_filter(x)
        else:
            constrained[False, "InterpolationMode not supported"]()
            return -1


fn resize_nearest_neighbor[
    coordinate_transformation_mode: CoordinateTransformationMode,
    round_mode: RoundMode,
    rank: Int,
    type: DType,
](
    input: NDBuffer[rank, DimList.create_unknown[rank](), type],
    output: NDBuffer[rank, DimList.create_unknown[rank](), type],
):
    var scales = StaticTuple[rank, Float32]()
    for i in range(rank):
        scales[i] = (output.dim(i) / input.dim(i)).cast[DType.float32]()

    @parameter
    @always_inline
    fn round[type: DType](val: SIMD[type, 1]) -> SIMD[type, 1]:
        @parameter
        if round_mode == RoundMode.HalfDown:
            return round_half_down(val)
        elif round_mode == RoundMode.HalfUp:
            return round_half_up(val)
        elif round_mode == RoundMode.Floor:
            return floor(val)
        elif round_mode == RoundMode.Ceil:
            return ceil(val)
        else:
            constrained[True, "round_mode not implemented"]()
            return val

    # need a copy because `let` variables are captured by copy but `var` variables are not
    let scales_copy = scales

    @parameter
    fn nn_interpolate[
        simd_width: Int, _rank: Int
    ](out_coords: StaticIntTuple[_rank]):
        var in_coords = StaticIntTuple[rank](0)

        @unroll
        for i in range(rank):
            in_coords[i] = min(
                int(
                    round(
                        coord_transform[coordinate_transformation_mode](
                            out_coords[i],
                            input.dim(i),
                            output.dim(i),
                            scales_copy[i],
                        )
                    )
                ),
                input.dim(i) - 1,
            )

        output[rebind[StaticIntTuple[rank]](out_coords)] = input[in_coords]

    # TODO (#21439): can use memcpy when scale on inner dimension is 1
    elementwise[rank, 1, nn_interpolate](output.get_shape())


@always_inline
fn linear_filter(x: Float32) -> Float32:
    """This is a tent filter.

    f(x) = 1 + x, x < 0
    f(x) = 1 - x, 0 <= x < 1
    f(x) = 0, x >= 1

    """
    var coeff = x
    if x < 0:
        coeff = -x
    if x < 1:
        return 1 - coeff
    return 0


@parameter
@always_inline
fn interpolate_point_1d[
    coordinate_transformation_mode: CoordinateTransformationMode,
    antialias: Bool,
    rank: Int,
    type: DType,
    interpolation_mode: InterpolationMode,
](
    interpolator: Interpolator[interpolation_mode],
    dim: Int,
    out_coords: StaticIntTuple[rank],
    scale: Float32,
    input: NDBuffer[rank, DimList.create_unknown[rank](), type],
    output: NDBuffer[rank, DimList.create_unknown[rank](), type],
):
    let center = coord_transform[coordinate_transformation_mode](
        out_coords[dim], input.dim(dim), output.dim(dim), scale
    ) + 0.5
    let filter_scale = 1 / scale if antialias and scale < 1 else 1
    let support = interpolator.filter_length() * filter_scale
    let xmin = max(0, int(center - support + 0.5))
    let xmax = min(input.dim(dim), int(center + support + 0.5))
    var in_coords = out_coords
    var sum = SIMD[type, 1](0)
    var acc = SIMD[type, 1](0)
    let ss = 1 / filter_scale
    for k in range(xmax - xmin):
        in_coords[dim] = k + xmin
        let dist_from_center = ((k + xmin + 0.5) - center) * ss
        let filter_coeff = interpolator.filter(dist_from_center).cast[type]()
        acc += input[in_coords] * filter_coeff
        sum += filter_coeff

    # normalize to handle cases near image boundary where only 1 point is used
    # for interpolation
    output[out_coords] = acc / sum


fn resize_linear[
    coordinate_transformation_mode: CoordinateTransformationMode,
    antialias: Bool,
    rank: Int,
    type: DType,
](
    input: NDBuffer[rank, DimList.create_unknown[rank](), type],
    output: NDBuffer[rank, DimList.create_unknown[rank](), type],
):
    """Resizes input to output shape using linear interpolation.

    Does not use anti-aliasing filter for downsampling (coming soon).

    Parameters:
        coordinate_transformation_mode: How to map a coordinate in output to a coordinate in input.
        antialias: Whether or not to use an antialiasing linear/cubic filter, which when downsampling, uses
            more points to avoid aliasing artifacts. Effectively stretches the filter by a factor of 1 / scale.
        rank: Rank of the input and output.
        type: Type of input and output.

    Args:
        input: The input to be resized.
        output: The output containing the resized input.


    """
    _resize[
        InterpolationMode.Linear, coordinate_transformation_mode, antialias
    ](input, output)


fn _resize[
    interpolation_mode: InterpolationMode,
    coordinate_transformation_mode: CoordinateTransformationMode,
    antialias: Bool,
    rank: Int,
    type: DType,
](
    input: NDBuffer[rank, DimList.create_unknown[rank](), type],
    output: NDBuffer[rank, DimList.create_unknown[rank](), type],
):
    var scales = StaticTuple[rank, Float32]()

    var resize_dims = InlinedFixedVector[Int, size=rank](rank)
    var tmp_dims = StaticIntTuple[rank](0)
    for i in range(rank):
        # need to consider output dims when upsampling and input dims when downsampling
        tmp_dims[i] = max(input.dim(i), output.dim(i))
        scales[i] = (output.dim(i) / input.dim(i)).cast[DType.float32]()
        if input.dim(i) != output.dim(i):
            resize_dims.append(i)
    let interpolator = Interpolator[interpolation_mode]()

    var in_ptr = input.data
    var out_ptr = DTypePointer[type]()
    var using_tmp1 = False
    var tmp_buffer1 = DTypePointer[type]()
    var tmp_buffer2 = DTypePointer[type]()
    # ping pong between using tmp_buffer1 and tmp_buffer2 to store outputs
    # of 1d interpolation pass accross one of the dimensions
    if len(resize_dims) == 1:  # avoid allocating tmp_buffer
        out_ptr = output.data
    if len(resize_dims) > 1:  # avoid allocating second tmp_buffer
        tmp_buffer1 = DTypePointer[type].alloc(tmp_dims.flattened_length())
        out_ptr = tmp_buffer1
        using_tmp1 = True
    if len(resize_dims) > 2:  # need a second tmp_buffer
        # TODO: if you are upsampling all dims, you can use the output in place of tmp_buffer2
        # as long as you make sure that the last iteration uses tmp1_buffer as the input
        # and tmp_buffer2 (output) as the output
        tmp_buffer2 = DTypePointer[type].alloc(tmp_dims.flattened_length())
    var in_shape = input.get_shape()
    var out_shape = input.get_shape()
    # interpolation is separable, so perform 1d interpolation across each
    # interpolated dimension
    for dim_idx in range(len(resize_dims)):
        if dim_idx == len(resize_dims) - 1:
            out_ptr = output.data
        let resize_dim = resize_dims[dim_idx]
        out_shape[resize_dim] = output.dim(resize_dim)

        let in_buf = NDBuffer[rank, DimList.create_unknown[rank](), type](
            in_ptr, in_shape
        )
        let out_buf = NDBuffer[rank, DimList.create_unknown[rank](), type](
            out_ptr, out_shape
        )

        let num_rows = out_buf.num_elements() // out_shape[resize_dim]
        for row_idx in range(num_rows):
            var coords = _get_nd_indices_from_flat_index(
                row_idx, out_shape, resize_dim
            )
            for i in range(out_shape[resize_dim]):
                coords[resize_dim] = i
                interpolate_point_1d[coordinate_transformation_mode, antialias](
                    interpolator,
                    resize_dim,
                    coords,
                    scales[resize_dim],
                    in_buf,
                    out_buf,
                )

        in_shape = out_shape
        in_ptr = out_ptr

        out_ptr = tmp_buffer2 if using_tmp1 else tmp_buffer1
        using_tmp1 = not using_tmp1

    tmp_buffer1.free()
    tmp_buffer2.free()
    resize_dims._del_old()
