# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo -debug-level full %s | FileCheck %s

from math import abs, div_ceil, isclose, min
from random import rand, seed
from sys import external_call
from sys.info import simdwidthof

from algorithm.functional import vectorize
from buffer import NDBuffer
from buffer.list import DimList
from memory.unsafe import DTypePointer
from nn.conv_transpose import (
    ConvTransposedPacked,
    conv_transpose_naive,
    pack_filter,
    pack_filter_shape,
)
from nn.conv_utils import (
    ConvInfoStatic,
    ConvShape,
    append_shape,
    extend_shape,
    get_conv_num_partitions,
    get_conv_num_tasks,
    get_conv_tile_shape,
    get_direct_conv_micro_kernel_height,
    get_direct_conv_micro_kernel_width,
)

from utils.index import Index, StaticIntTuple

alias simd_size: Int = simdwidthof[DType.float32]()
alias type = DType.float32


@always_inline
fn extend_shape_5d[
    rank: Int
](in_shape: StaticIntTuple[rank], first: Int, last: Int) -> StaticIntTuple[5]:
    var out_shape = StaticIntTuple[5](1)
    out_shape[0] = first
    out_shape[4] = last

    @parameter
    if rank == 1:
        out_shape[3] = in_shape[0]
    elif rank == 2:
        out_shape[2] = in_shape[0]
        out_shape[3] = in_shape[1]
    elif rank == 3:
        out_shape[1] = in_shape[0]
        out_shape[2] = in_shape[1]
        out_shape[3] = in_shape[2]

    return out_shape


@always_inline
fn extend_shape_3d[
    rank: Int
](in_shape: StaticIntTuple[rank]) -> StaticIntTuple[3]:
    var out_shape = StaticIntTuple[3](1)

    @unroll
    for i in range(rank):
        out_shape[2 - i] = in_shape[rank - i - 1]

    return out_shape


@always_inline
fn append_shape_5d[
    rank: Int
](in_shape: StaticIntTuple[rank], last2nd: Int, last: Int) -> StaticIntTuple[5]:
    var out_shape = StaticIntTuple[5](1)
    out_shape[3] = last2nd
    out_shape[4] = last

    @parameter
    if rank == 1:
        out_shape[2] = in_shape[0]
    elif rank == 2:
        out_shape[1] = in_shape[0]
        out_shape[2] = in_shape[1]
    elif rank == 3:
        out_shape[0] = in_shape[0]
        out_shape[1] = in_shape[1]
        out_shape[2] = in_shape[2]

    return out_shape


fn test_conv_transposed[
    type: DType, rank: Int
](
    N: Int,
    input_dims: StaticIntTuple[rank],
    C: Int,
    filter_dims: StaticIntTuple[rank],
    F: Int,
    stride: StaticIntTuple[rank],
    dilation: StaticIntTuple[rank],
    pad: StaticIntTuple[2 * rank],
    num_groups: Int,
) raises:
    print("test_conv_transposed")

    var output_dims = StaticIntTuple[rank](1)

    @unroll
    for i in range(rank):
        output_dims[i] = (
            (input_dims[i] - 1) * stride[i]
            - pad[2 * i]
            - pad[2 * i + 1]
            + dilation[i] * (filter_dims[i] - 1)
            + 1
        )

    var pad_d = StaticIntTuple[2](0)
    var pad_h = StaticIntTuple[2](0)
    var pad_w = StaticIntTuple[2](0)

    @parameter
    if rank == 1:
        pad_w = Index(pad[0], pad[1])
    elif rank == 2:
        pad_h = Index(pad[0], pad[1])
        pad_w = Index(pad[2], pad[3])
    elif rank == 3:
        pad_d = Index(pad[0], pad[1])
        pad_h = Index(pad[2], pad[3])
        pad_w = Index(pad[4], pad[5])

    var conv_shape = ConvShape[rank] {
        n: N,
        input_dims: input_dims,
        output_dims: output_dims,
        filter_dims: filter_dims,
        c: C,
        f: F,
        stride: stride,
        dilation: dilation,
        pad_d: pad_d,
        pad_h: pad_h,
        pad_w: pad_w,
        num_groups: num_groups,
    }

    var C_per_group = C // num_groups

    var input_size = N * conv_shape.input_image_flat_size() * C
    var input_ptr = DTypePointer[type].alloc(input_size)
    rand(input_ptr, input_size)

    var filter_size = conv_shape.filter_window_flat_size() * C_per_group * F
    var filter_ptr = DTypePointer[type].alloc(filter_size)
    rand(filter_ptr, filter_size)

    var output_size = N * conv_shape.output_image_flat_size() * F
    var output_ptr = DTypePointer[type].alloc(output_size)
    var output_ref_ptr = DTypePointer[type].alloc(output_size)

    # Find the tile size used in packing.
    alias micro_kernel_height = get_direct_conv_micro_kernel_height()
    alias micro_kernel_width = get_direct_conv_micro_kernel_width()

    # Rounded C and F size for pre-packed filter.
    alias micro_kernel_f_size = get_direct_conv_micro_kernel_width() * simd_size
    var rounded_F = div_ceil(F, micro_kernel_f_size) * micro_kernel_f_size

    # Input buffer.
    var input_shape = extend_shape(input_dims, N, C)
    var input = NDBuffer[type, rank + 2](input_ptr, input_shape)
    var input_ref = NDBuffer[type, 5](
        input_ptr, extend_shape_5d(input_dims, N, C)
    )

    # Filter buffer.
    var filter_shape = append_shape(filter_dims, F, C_per_group)
    var filter = NDBuffer[type, rank + 2](filter_ptr, filter_shape)
    var filter_ref = NDBuffer[type, 5](
        filter_ptr, append_shape_5d(filter_dims, F, C_per_group)
    )

    var packed_filter_shape = pack_filter_shape(filter, num_groups)
    var packed_filter_ptr = DTypePointer[type].alloc(
        packed_filter_shape.flattened_length()
    )
    var packed_filter = NDBuffer[type, rank + 3](
        packed_filter_ptr, rebind[StaticIntTuple[rank + 3]](packed_filter_shape)
    )

    var output_shape = extend_shape(output_dims, N, F)
    var output = NDBuffer[type, rank + 2](output_ptr, output_shape)
    var output_ref = NDBuffer[type, 5](
        output_ref_ptr, extend_shape_5d(output_dims, N, F)
    )

    # Bias for epilogue
    var bias_ptr = DTypePointer[type].alloc(F)
    rand(bias_ptr, F)

    pack_filter(filter, packed_filter, num_groups)

    # Reference.
    conv_transpose_naive[type](
        output_ref,
        input_ref,
        filter_ref,
        extend_shape_3d[rank](stride),
        extend_shape_3d[rank](dilation),
        pad_d,
        pad_h,
        pad_w,
    )

    # Add bias and activatiion separately.
    var output_image_size = output_dims.flattened_length()
    for n in range(N):
        for i in range(output_image_size):
            var output_ref_ptr = output_ref.data + F * (
                i + output_image_size * n
            )

            @always_inline
            @__copy_capture(output_ref_ptr, bias_ptr)
            @parameter
            fn body0[width: Int](offset: Int):
                output_ref_ptr.store(
                    offset,
                    10.0
                    * (
                        output_ref_ptr.load[width=width](offset)
                        + bias_ptr.load[width=width](offset)
                    ),
                )

            vectorize[body0, simd_size](F)

    # Test.
    alias conv_attr = ConvInfoStatic[rank + 2 - 2]()

    # Test epilogue
    @always_inline
    @__copy_capture(output, bias_ptr)
    @parameter
    fn epilogue[_rank: Int](coords: StaticIntTuple[_rank], f_size: Int):
        @always_inline
        @parameter
        fn body1[width: Int](idx: Int):
            var curr_coords = rebind[StaticIntTuple[rank + 2]](coords)
            curr_coords[rank + 1] += idx

            var vec = output.load[width=width](curr_coords)

            output.store(
                curr_coords,
                10.0
                * (vec + bias_ptr.load[width=width](curr_coords[rank + 1])),
            )

        vectorize[body1, simd_size](f_size)

    ConvTransposedPacked[
        rank + 2,  # input rank
        rank + 3,  # filter rank
        rank + 2,  # output rank
        DimList.create_unknown[rank + 2](),  # input shape
        DimList.create_unknown[rank + 3](),  # filter shape
        DimList.create_unknown[rank + 2](),  # output shape
        type,  # input
        type,  # filter
        type,  # output
        conv_attr,
        epilogue,
    ].run(
        output,
        input,
        packed_filter,
        rebind[ConvShape[rank + 2 - 2]](conv_shape),
    )

    input_ptr.free()
    filter_ptr.free()
    packed_filter_ptr.free()
    bias_ptr.free()

    # Check results, return on the first failed comparison.
    for i in range(output_size):
        if not isclose(
            output_ref.data[i],
            output.data[i],
            atol=1e-4,  # absolute error tolerance
            rtol=1e-4,  # relative error tolerance
        ):
            print("Input shape: ", input_shape)
            print("filter shape: ", filter_shape)
            print("num groups", num_groups)
            print("flat output index:", i)
            print("Golden value: ", output_ref.data[i])
            print("Actual value: ", output.data[i])
            output_ptr.free()
            output_ref_ptr.free()
            return

    output_ptr.free()
    output_ref_ptr.free()

    # CHECK: Succeed
    print("Succeed")


fn main() raises:
    test_conv_transposed[DType.float32, 2](
        1,  # N
        Index(3, 3),
        1,  # C
        Index(3, 3),
        2,  # F
        Index(3, 2),  # stride
        Index(1, 1),  # dilation
        Index(1, 1, 2, 2),  # pad h, w
        1,  # num_groups
    )

    test_conv_transposed[DType.float32, 2](
        1,  # N
        Index(3, 3),
        1,  # C
        Index(3, 3),
        2,  # F
        Index(1, 1),  # stride
        Index(1, 1),  # dilation
        Index(0, 0, 0, 0),  # pad h, w
        1,  # num_groups
    )

    test_conv_transposed[DType.float32, 2](
        1,  # N
        Index(3, 3),
        1,  # C
        Index(3, 3),
        1,  # F
        Index(1, 1),  # stride
        Index(2, 2),  # dilation
        Index(0, 0, 0, 0),  # pad_h, pad_w
        1,  # num_groups
    )

    test_conv_transposed[DType.float32, 2](
        1,  # N
        Index(3, 3),
        1,  # C
        Index(2, 2),
        2,  # F
        Index(3, 2),  # stride
        Index(1, 1),  # dilation
        Index(0, 0, 0, 0),  # pad_h, pad_w
        1,  # num_groups
    )

    test_conv_transposed[DType.float32, 3](
        1,  # N
        Index(2, 3, 3),
        1,  # C
        Index(2, 2, 2),
        2,  # F
        Index(1, 3, 2),  # stride
        Index(1, 1, 1),  # dilation
        StaticIntTuple[6](0),  # pad
        1,  # num_groups
    )

    test_conv_transposed[DType.float32, 3](
        1,  # N
        Index(3, 4, 7),
        1,  # C
        Index(3, 2, 2),
        2,  # F
        Index(2, 1, 2),  # stride
        Index(1, 1, 2),  # dilation
        StaticIntTuple[6](0),  # pad
        1,  # num_groups
    )

    test_conv_transposed[DType.float32, 3](
        1,  # N
        Index(4, 3, 3),
        1,  # C
        Index(1, 4, 2),
        2,  # F
        Index(1, 3, 2),  # stride
        Index(1, 1, 1),  # dilation
        StaticIntTuple[6](1, 0, 2, 1, 0, 1),  # pad
        1,  # num_groups
    )

    test_conv_transposed[DType.float32, 3](
        1,  # N
        Index(4, 5, 7),
        1,  # C
        Index(3, 2, 1),
        2,  # F
        Index(1, 3, 2),  # stride
        Index(2, 3, 1),  # dilation
        StaticIntTuple[6](2, 2, 1, 1, 1, 1),  # pad
        1,  # num_groups
    )

    test_conv_transposed[DType.float32, 3](
        1,  # N
        Index(5, 5, 5),
        4,  # C
        Index(3, 3, 3),
        8,  # F
        Index(1, 1, 1),  # stride
        Index(1, 1, 1),  # dilation
        StaticIntTuple[6](0, 0, 0, 0, 0, 0),  # pad
        1,  # num_groups
    )

    # Large shapes commented out to save CI cost.

    # # StarGan shape
    # test_conv_transposed[DType.float32, 2](
    #     16,  # N
    #     Index(32, 32),
    #     256,  # C
    #     Index(4, 4),
    #     128,  # F
    #     Index(2, 2),  # stride
    #     Index(1, 1),  # dilation
    #     Index(1, 1, 1, 1),  # pad_h, w
    #     1,  # num_groups
    # )

    # test_conv_transposed[DType.float32, 2](
    #     16,  # N
    #     Index(64, 64),
    #     128,  # C
    #     Index(4, 4),
    #     64,  # F
    #     Index(2, 2),  # stride
    #     Index(1, 1),  # dilation
    #     Index(1, 1, 1, 1),  # pad_h, pad_w
    #     1,  # num_groups
    # )

    # # 3d Unet shapes
    # test_conv_transposed[DType.float32, 3](
    #     1,  # N
    #     Index(4, 4, 4),
    #     320,  # C
    #     Index(2, 2, 2),
    #     320,  # F
    #     Index(2, 2, 2),  # stride
    #     Index(1, 1, 1),  # dilation
    #     StaticIntTuple[6](0),  # pad
    #     1,  # num_groups
    # )

    # test_conv_transposed[DType.float32, 3](
    #     1,  # N
    #     Index(8, 8, 8),
    #     320,  # C
    #     Index(2, 2, 2),
    #     256,  # F
    #     Index(2, 2, 2),  # stride
    #     Index(1, 1, 1),  # dilation
    #     StaticIntTuple[6](0),  # pad
    #     1,  # num_groups
    # )

    # test_conv_transposed[DType.float32, 3](
    #     1,  # N
    #     Index(16, 16, 16),
    #     256,  # C
    #     Index(2, 2, 2),
    #     128,  # F
    #     Index(2, 2, 2),  # stride
    #     Index(1, 1, 1),  # dilation
    #     StaticIntTuple[6](0),  # pad
    #     1,  # num_groups
    # )

    # test_conv_transposed[DType.float32, 3](
    #     1,  # N
    #     Index(32, 32, 32),
    #     128,  # C
    #     Index(2, 2, 2),
    #     64,  # F
    #     Index(2, 2, 2),  # stride
    #     Index(1, 1, 1),  # dilation
    #     StaticIntTuple[6](0),  # pad
    #     1,  # num_groups
    # )

    # test_conv_transposed[DType.float32, 3](
    #     1,  # N
    #     Index(64, 64, 64),
    #     64,  # C
    #     Index(2, 2, 2),
    #     32,  # F
    #     Index(2, 2, 2),  # stride
    #     Index(1, 1, 1),  # dilation
    #     StaticIntTuple[6](0),  # pad
    #     1,  # num_groups
    # )
