# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo %s | FileCheck %s

from math import abs, div_ceil, isclose, min
from random import rand, seed
from sys import external_call
from sys.info import simdwidthof

from algorithm.functional import vectorize
from memory.buffer import NDBuffer
from memory.unsafe import DTypePointer
from NN.Conv import (
    ConvDirectNHWC,
    ConvInfoStatic,
    Naive2dConvolution,
    pack_conv_filter_shape,
    pack_filter,
)
from NN.ConvUtils import (
    ConvShape,
    get_conv_tile_shape,
    get_direct_conv_micro_kernel_height,
    get_direct_conv_micro_kernel_width,
    extend_shape,
    append_shape,
)
from NN.Image import Image2DLayout, ImageData, ImageShape

from utils.index import Index, StaticIntTuple
from utils.list import DimList

alias simd_size: Int = simdwidthof[DType.float32]()
alias type = DType.float32


# CHECK-LABEL: test_conv_epilogue
fn test[
    rank: Int, type: DType, filter_packed: Bool
](
    N: Int,
    input_dims: StaticIntTuple[rank],
    C: Int,
    filter_dims: StaticIntTuple[rank],
    F: Int,
    stride: StaticIntTuple[rank],
    dilation: StaticIntTuple[rank],
    pad: StaticIntTuple[2 * rank],  # pad in d, h, w
    num_groups: Int,
) raises:
    print("== test_conv_epilogue")

    var output_dims = StaticIntTuple[rank](1)

    @unroll
    for i in range(rank):
        output_dims[i] = (
            input_dims[i]
            + pad[2 * i]
            + pad[2 * i + 1]
            - dilation[i] * (filter_dims[i] - 1)
            - 1
        ) // stride[i] + 1

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

    let conv_shape = ConvShape[rank] {
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

    let C_per_group = C // num_groups

    let input_size = N * conv_shape.input_image_flat_size() * C
    let input_ptr = DTypePointer[type].alloc(input_size)
    rand(input_ptr, input_size)

    let filter_size = conv_shape.filter_window_flat_size() * C_per_group * F
    let filter_ptr = DTypePointer[type].alloc(filter_size)
    rand(filter_ptr, filter_size)

    let output_size = N * conv_shape.output_image_flat_size() * F
    let output_ptr = DTypePointer[type].alloc(output_size)
    let output_ref_ptr = DTypePointer[type].alloc(output_size)

    let bias_ptr = DTypePointer[type].alloc(F)
    rand(bias_ptr, F)

    # Find the tile size used in packing.
    alias micro_kernel_height = get_direct_conv_micro_kernel_height()
    alias micro_kernel_width = get_direct_conv_micro_kernel_width()

    # Rounded C and F size for pre-packed filter.
    let micro_kernel_f_size = micro_kernel_width * simd_size
    let rounded_F = div_ceil(F, micro_kernel_f_size) * micro_kernel_f_size

    # Input buffer.
    var input_shape = extend_shape(input_dims, N, C)
    let input = NDBuffer[type, rank + 2](input_ptr, input_shape)

    # Filter buffer.
    var filter_shape = append_shape(filter_dims, C_per_group, F)
    let filter = NDBuffer[type, rank + 2](filter_ptr, filter_shape)

    let packed_filter_shape = pack_conv_filter_shape[False](filter, num_groups)
    let packed_filter_ptr = DTypePointer[type].alloc(
        packed_filter_shape.flattened_length()
    )
    let packed_filter = NDBuffer[type, rank + 3](
        packed_filter_ptr, rebind[StaticIntTuple[rank + 3]](packed_filter_shape)
    )

    let output_shape = extend_shape(output_dims, N, F)
    let output = NDBuffer[type, rank + 2](output_ptr, output_shape)
    let output_ref = NDBuffer[type, rank + 2](output_ref_ptr, output_shape)

    @parameter
    if filter_packed:
        pack_filter(filter, packed_filter, num_groups)

    alias conv_attr = ConvInfoStatic.create_unknown[rank]()

    @always_inline
    @parameter
    fn null_epilogue[rank: Int](coords: StaticIntTuple[rank], f_size: Int):
        pass

    @parameter
    if filter_packed:
        ConvDirectNHWC[
            rank + 2,
            rank + 3,
            rank + 2,
            DimList.create_unknown[rank + 2](),
            DimList.create_unknown[rank + 3](),
            DimList.create_unknown[rank + 2](),
            type,
            type,
            type,
            True,
            conv_attr,
            elementwise_epilogue_enabled=False,
        ].run(
            output_ref,
            input,
            packed_filter,
            # 30770
            rebind[ConvShape[rank + 2 - 2]](conv_shape),
        )
    else:
        ConvDirectNHWC[
            rank + 2,
            rank + 2,
            rank + 2,
            DimList.create_unknown[rank + 2](),
            DimList.create_unknown[rank + 2](),
            DimList.create_unknown[rank + 2](),
            type,
            type,
            type,
            False,
            conv_attr,
            elementwise_epilogue_enabled=False,
        ].run(
            output_ref,
            input,
            filter,
            # 30770
            rebind[ConvShape[rank + 2 - 2]](conv_shape),
        )

    # Add bias and activatiion separately.
    let output_image_size = output_dims.flattened_length()
    for n in range(N):
        for i in range(output_image_size):
            let output_ref_ptr = output_ref.data + F * (
                i + output_image_size * n
            )

            @always_inline
            @__copy_capture(output_ref_ptr, bias_ptr)
            @parameter
            fn body0[width: Int](offset: Int):
                output_ref_ptr.simd_store(
                    offset,
                    10.0
                    * (
                        output_ref_ptr.simd_load[width](offset)
                        + bias_ptr.simd_load[width](offset)
                    ),
                )

            vectorize[body0, simd_size](F)

    # Test epilogue
    @always_inline
    @__copy_capture(output, bias_ptr)
    fn epilogue(coords: StaticIntTuple[rank + 2], f_size: Int):
        @always_inline
        @parameter
        fn body1[width: Int](idx: Int):
            var curr_coords = coords
            curr_coords[rank + 1] += idx

            let vec = output.simd_load[width](curr_coords)

            output.simd_store(
                curr_coords,
                10.0 * (vec + bias_ptr.simd_load[width](curr_coords[rank + 1])),
            )

        vectorize[body1, simd_size](f_size)

    @parameter
    if filter_packed:
        ConvDirectNHWC[
            rank + 2,
            rank + 3,
            rank + 2,
            DimList.create_unknown[rank + 2](),
            DimList.create_unknown[rank + 3](),
            DimList.create_unknown[rank + 2](),
            type,
            type,
            type,
            True,
            conv_attr,
            elementwise_epilogue_enabled=True,
        ].run(
            output,
            input,
            packed_filter,
            # 30770
            rebind[ConvShape[rank + 2 - 2]](conv_shape),
            epilogue,
        )
    else:
        ConvDirectNHWC[
            rank + 2,
            rank + 2,
            rank + 2,
            DimList.create_unknown[rank + 2](),
            DimList.create_unknown[rank + 2](),
            DimList.create_unknown[rank + 2](),
            type,
            type,
            type,
            False,
            conv_attr,
            elementwise_epilogue_enabled=True,
        ].run(
            output,
            input,
            filter,
            # 30770
            rebind[ConvShape[rank + 2 - 2]](conv_shape),
            epilogue,
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
            1e-4,  # absolute error tolerance
            1e-4,  # relative error tolerance
        ):
            print("Input shape: ", input_shape)
            print("filter shape: ", filter_shape)
            print("filter packed", filter_packed)
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
    # No packing or padding.
    test[2, DType.float32, False](
        1,  # N
        Index(6, 5),  # H, W
        1,  # C
        Index(3, 4),  # R, S
        4,  # F
        Index(2, 2),  # stride
        Index(1, 1),  # dilation
        Index(0, 0, 0, 0),  # pad_h, pad_w
        1,  # num_groups
    )

    test[3, DType.float32, False](
        1,  # N
        Index(4, 8, 13),
        16,  # C
        Index(1, 2, 5),
        64,  # F
        Index(1, 1, 2),  # stride
        Index(1, 1, 1),  # dilation
        StaticIntTuple[6](0),  # pad_d, pad_h, pad_w
        1,  # num_groups
    )

    test[1, DType.float32, False](
        1,  # N
        Index(14),
        7,  # C
        Index(3),
        256,  # F
        Index(3),  # stride
        Index(1),  # dilation
        Index(0, 0),  # pad_w
        1,  # num_groups
    )

    # Pre-packed test w/o padding.

    test[2, DType.float32, True](
        1,  # N
        Index(12, 12),
        12,  # C
        Index(3, 3),
        64,  # F
        Index(1, 1),  # stride
        Index(1, 1),  # dilation
        Index(0, 0, 0, 0),  # pad_h, pad_w
        1,  # num_groups
    )

    test[3, DType.float32, True](
        5,  # N
        Index(9, 12, 11),
        8,  # C
        Index(3, 3, 4),
        64,  # F
        Index(2, 2, 2),  # stride
        Index(1, 1, 1),  # dilation
        StaticIntTuple[6](0),  # pad_h, pad_w
        1,  # num_groups
    )

    test[1, DType.float32, True](
        1,  # N
        Index(17),
        11,  # C
        Index(3),
        192,  # F
        Index(3),  # stride
        Index(1),  # dilation
        Index(0, 0),  # pad_h, pad_w
        1,  # num_groups
    )

    # No packing, w/ padding, and F not multiple of simd_size.

    test[2, DType.float32, False](
        1,  # N
        Index(5, 5),
        3,  # C
        Index(3, 3),
        1,  # F
        Index(1, 1),  # stride
        Index(1, 1),  # dilation
        Index(1, 1, 1, 1),  # pad_h, pad_w
        1,  # num_groups
    )

    test[3, DType.float32, False](
        1,  # N
        Index(9, 10, 5),
        2,  # C
        Index(2, 4, 3),
        6,  # F
        Index(3, 2, 3),  # stride
        Index(1, 1, 1),  # dilation
        StaticIntTuple[6](1, 0, 2, 1, 1, 1),
        1,  # num_groups
    )

    # Pre-packed, F not multiple of simd_size
    test[2, DType.float32, True](
        1,  # N
        Index(7, 7),
        2,  # C
        Index(3, 3),
        42,  # F
        Index(2, 2),  # stride
        Index(1, 1),  # dilation
        Index(0, 0, 0, 0),  # pad_h, pad_w
        1,  # num_groups
    )

    test[1, DType.float32, True](
        1,  # N
        Index(11),
        2,  # C
        Index(5),
        7,  # F
        Index(1),  # stride
        Index(1),  # dilation
        Index(2, 2),  # pad_h, pad_w
        1,  # num_groups
    )

    test[3, DType.float32, True](
        1,  # N
        Index(7, 7, 9),
        2,  # C
        Index(4, 3, 3),
        42,  # F
        Index(2, 2, 2),  # stride
        Index(1, 1, 1),  # dilation
        StaticIntTuple[6](2, 1, 1, 1, 1, 1),
        1,  # num_groups
    )

    test[2, DType.float32, True](
        1,  # N
        Index(14, 14),
        3,  # C
        Index(3, 3),
        16,  # F
        Index(2, 2),  # stride
        Index(1, 1),  # dilation
        Index(1, 1, 1, 1),
        1,  # num_groups
    )

    # grouped conv tests
    test[2, DType.float32, True](
        1,  # N
        Index(3, 3),
        18,  # C
        Index(3, 3),
        18,  # F
        Index(1, 1),  # stride
        Index(1, 1),  # dilation
        Index(0, 0, 0, 0),
        3,  # num_groups
    )

    test[2, DType.float32, True](
        3,  # N
        Index(11, 17),
        36,  # C
        Index(3, 3),
        93,  # F
        Index(2, 2),  # stride
        Index(1, 1),  # dilation
        Index(1, 1, 2, 2),
        3,  # num_groups
    )

    test[2, DType.float32, True](
        1,  # N
        Index(11, 17),
        36,  # C
        Index(2, 6),
        198,  # F
        Index(2, 3),  # stride
        Index(1, 1),  # dilation
        Index(1, 0, 3, 2),  # pad_h
        2,  # num_groups
    )

    # depthwise conv
    test[2, DType.float32, True](
        1,  # N
        Index(11, 7),
        33,  # C
        Index(3, 5),
        66,  # F
        Index(2, 2),  # stride
        Index(1, 1),  # dilation
        Index(1, 1, 2, 2),
        33,  # num_groups
    )

    # 1D edge case
    test[1, DType.float32, True](
        2,  # N
        Index(49),  # W
        1024,  # C
        Index(128),  # S
        1024,  # F
        Index(1),  # stride
        Index(1),  # dilation
        Index(64, 64),  # pad_w
        64,  # num_groups
    )
