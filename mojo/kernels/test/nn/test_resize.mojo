# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo -debug-level full -I %S/.. %s | FileCheck %s

from Resize import (
    CoordinateTransformationMode,
    RoundMode,
    resize_linear,
    resize_nearest_neighbor,
)
from runtime.llcl import OwningOutputChainPtr, Runtime
from tensor import Tensor, TensorShape
from test_utils import linear_fill
from testing import assert_almost_equal


fn test_case_nearest[
    rank: Int,
    coord_transform: CoordinateTransformationMode,
    round_mode: RoundMode,
    type: DType,
](input: Tensor[type], output: Tensor[type]):
    with Runtime() as rt:
        let out_chain = OwningOutputChainPtr(rt)
        resize_nearest_neighbor[coord_transform, round_mode,](
            input._to_ndbuffer[rank](),
            output._to_ndbuffer[rank](),
            out_chain.borrow(),
        )
        out_chain.wait()

    for i in range(output.num_elements()):
        print_no_newline(output._to_buffer()[i])
        print_no_newline(",")
    print("")


fn test_case_linear[
    rank: Int,
    coord_transform: CoordinateTransformationMode,
    antialias: Bool,
    type: DType,
](input: Tensor[type], output: Tensor[type], reference: Tensor[type]):
    with Runtime() as rt:
        let out_chain = OwningOutputChainPtr(rt)
        resize_linear[coord_transform, antialias](
            input._to_ndbuffer[rank](),
            output._to_ndbuffer[rank](),
            out_chain.borrow(),
        )
        out_chain.wait()

    var passed = True
    for i in range(output.num_elements()):
        passed = passed & assert_almost_equal(
            output._to_buffer()[i],
            reference._to_buffer()[i],
            1e-5,
            1e-4,
        )
    if passed:
        print("PASSED")


fn main():
    fn test_upsample_sizes_nearest_1():
        print("== test_upsample_sizes_nearest_1")
        alias type = DType.float32
        var input = Tensor[type](1, 1, 2, 2)
        linear_fill[type](input, VariadicList[SIMD[type, 1]](1, 2, 3, 4))
        let output = Tensor[type](1, 1, 4, 6)
        test_case_nearest[
            4, CoordinateTransformationMode.HalfPixel, RoundMode.HalfDown
        ](input, output)

    # CHECK-LABEL: test_upsample_sizes_nearest_1
    # CHECK: 1.0,1.0,1.0,2.0,2.0,2.0,1.0,1.0,1.0,2.0,2.0,2.0,3.0,3.0,3.0,4.0,4.0,4.0,3.0,3.0,3.0,4.0,4.0,4.0,
    test_upsample_sizes_nearest_1()

    fn test_downsample_sizes_nearest():
        print("== test_downsample_sizes_nearest")
        alias type = DType.float32
        var input = Tensor[type](1, 1, 2, 4)
        linear_fill[type](
            input, VariadicList[SIMD[type, 1]](1, 2, 3, 4, 5, 6, 7, 8)
        )
        let output = Tensor[type](1, 1, 1, 2)

        test_case_nearest[
            4, CoordinateTransformationMode.HalfPixel, RoundMode.HalfDown
        ](input, output)

    # CHECK-LABEL: test_downsample_sizes_nearest
    # CHECK: 1.0,3.0,
    test_downsample_sizes_nearest()

    fn test_upsample_sizes_nearest_2():
        print("== test_upsample_sizes_nearest_2")
        alias type = DType.float32
        var input = Tensor[type](1, 1, 2, 2)
        linear_fill[type](input, VariadicList[SIMD[type, 1]](1, 2, 3, 4))
        let output = Tensor[type](1, 1, 7, 8)

        test_case_nearest[
            4, CoordinateTransformationMode.HalfPixel, RoundMode.HalfDown
        ](input, output)

    # CHECK-LABEL: test_upsample_sizes_nearest_2
    # CHECK: 1.0,1.0,1.0,1.0,2.0,2.0,2.0,2.0,1.0,1.0,1.0,1.0,2.0,2.0,2.0,2.0,1.0,1.0,1.0,1.0,2.0,2.0,2.0,2.0,1.0,1.0,1.0,1.0,2.0,2.0,2.0,2.0,3.0,3.0,3.0,3.0,4.0,4.0,4.0,4.0,3.0,3.0,3.0,3.0,4.0,4.0,4.0,4.0,3.0,3.0,3.0,3.0,4.0,4.0,4.0,4.0,
    test_upsample_sizes_nearest_2()

    fn test_upsample_sizes_nearest_floor_align_corners():
        print("== test_upsample_sizes_nearest_floor_align_corners")
        alias type = DType.float32
        var input = Tensor[type](1, 1, 4, 4)
        linear_fill[type](
            input,
            VariadicList[SIMD[type, 1]](
                1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
            ),
        )
        let output = Tensor[type](1, 1, 8, 8)

        test_case_nearest[
            4, CoordinateTransformationMode.AlignCorners, RoundMode.Floor
        ](input, output)

    # CHECK-LABEL: test_upsample_sizes_nearest_floor_align_corners
    # CHECK: 1.0,1.0,1.0,2.0,2.0,3.0,3.0,4.0,1.0,1.0,1.0,2.0,2.0,3.0,3.0,4.0,1.0,1.0,1.0,2.0,2.0,3.0,3.0,4.0,5.0,5.0,5.0,6.0,6.0,7.0,7.0,8.0,5.0,5.0,5.0,6.0,6.0,7.0,7.0,8.0,9.0,9.0,9.0,10.0,10.0,11.0,11.0,12.0,9.0,9.0,9.0,10.0,10.0,11.0,11.0,12.0,13.0,13.0,13.0,14.0,14.0,15.0,15.0,16.0,
    test_upsample_sizes_nearest_floor_align_corners()

    fn test_upsample_sizes_nearest_round_half_up_asymmetric():
        print("== test_upsample_sizes_nearest_round_half_up_asymmetric")
        alias type = DType.float32
        var input = Tensor[type](1, 1, 4, 4)
        linear_fill[type](
            input,
            VariadicList[SIMD[type, 1]](
                1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
            ),
        )
        let output = Tensor[type](1, 1, 8, 8)

        test_case_nearest[
            4, CoordinateTransformationMode.Asymmetric, RoundMode.HalfUp
        ](input, output)

    # CHECK-LABEL: test_upsample_sizes_nearest_round_half_up_asymmetric
    # CHECK: 1.0,2.0,2.0,3.0,3.0,4.0,4.0,4.0,5.0,6.0,6.0,7.0,7.0,8.0,8.0,8.0,5.0,6.0,6.0,7.0,7.0,8.0,8.0,8.0,9.0,10.0,10.0,11.0,11.0,12.0,12.0,12.0,9.0,10.0,10.0,11.0,11.0,12.0,12.0,12.0,13.0,14.0,14.0,15.0,15.0,16.0,16.0,16.0,13.0,14.0,14.0,15.0,15.0,16.0,16.0,16.0,13.0,14.0,14.0,15.0,15.0,16.0,16.0,16.0,
    test_upsample_sizes_nearest_round_half_up_asymmetric()

    fn test_upsample_sizes_nearest_ceil_half_pixel():
        print("== test_upsample_sizes_nearest_ceil_half_pixel")
        alias type = DType.float32
        var input = Tensor[type](1, 1, 4, 4)
        linear_fill[type](
            input,
            VariadicList[SIMD[type, 1]](
                1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16
            ),
        )
        let output = Tensor[type](1, 1, 8, 8)

        test_case_nearest[
            4, CoordinateTransformationMode.HalfPixel, RoundMode.Ceil
        ](input, output)

    # CHECK-LABEL: test_upsample_sizes_nearest_ceil_half_pixel
    # CHECK: 1.0,2.0,2.0,3.0,3.0,4.0,4.0,4.0,5.0,6.0,6.0,7.0,7.0,8.0,8.0,8.0,5.0,6.0,6.0,7.0,7.0,8.0,8.0,8.0,9.0,10.0,10.0,11.0,11.0,12.0,12.0,12.0,9.0,10.0,10.0,11.0,11.0,12.0,12.0,12.0,13.0,14.0,14.0,15.0,15.0,16.0,16.0,16.0,13.0,14.0,14.0,15.0,15.0,16.0,16.0,16.0,13.0,14.0,14.0,15.0,15.0,16.0,16.0,16.0,
    test_upsample_sizes_nearest_ceil_half_pixel()

    fn test_upsample_sizes_linear():
        print("== test_upsample_sizes_linear")
        alias type = DType.float32
        var input = Tensor[type](1, 1, 2, 2)
        linear_fill[type](
            input,
            VariadicList[SIMD[type, 1]](1, 2, 3, 4),
        )
        let output = Tensor[type](1, 1, 4, 4)
        var reference = Tensor[type](1, 1, 4, 4)

        # TORCH REFERENCE:
        # x = np.array([[[[1, 2], [3, 4]]]])
        # y = torch.nn.functional.interpolate(torch.Tensor(x), (4, 4), mode="bilinear")
        # print(y.flatten())

        linear_fill[type](
            reference,
            VariadicList[SIMD[type, 1]](
                1.0000,
                1.2500,
                1.7500,
                2.0000,
                1.5000,
                1.7500,
                2.2500,
                2.5000,
                2.5000,
                2.7500,
                3.2500,
                3.5000,
                3.0000,
                3.2500,
                3.7500,
                4.0000,
            ),
        )

        test_case_linear[4, CoordinateTransformationMode.HalfPixel, False](
            input, output, reference
        )

    # CHECK-LABEL: test_upsample_sizes_linear
    # CHECK: PASSED
    # CHECK-NOT: ASSERT ERROR
    test_upsample_sizes_linear()

    fn test_upsample_sizes_linear_align_corners():
        print("== test_upsample_sizes_linear_align_corners")
        alias type = DType.float32
        var input = Tensor[type](1, 1, 2, 2)
        linear_fill[type](
            input,
            VariadicList[SIMD[type, 1]](1, 2, 3, 4),
        )
        let output = Tensor[type](1, 1, 4, 4)
        var reference = Tensor[type](1, 1, 4, 4)

        # TORCH REFERENCE:
        # x = np.array([[[[1, 2], [3, 4]]]])
        # y = torch.nn.functional.interpolate(
        # torch.Tensor(x), (4, 4), mode="bilinear", align_corners=True)
        # print(y.flatten())
        linear_fill[type](
            reference,
            VariadicList[SIMD[type, 1]](
                1.0000,
                1.3333,
                1.6667,
                2.0000,
                1.6667,
                2.0000,
                2.3333,
                2.6667,
                2.3333,
                2.6667,
                3.0000,
                3.3333,
                3.0000,
                3.3333,
                3.6667,
                4.0000,
            ),
        )

        test_case_linear[4, CoordinateTransformationMode.AlignCorners, False](
            input, output, reference
        )

    # CHECK-LABEL: test_upsample_sizes_linear_align_corners
    # CHECK: PASSED
    # CHECK-NOT: ASSERT ERROR
    test_upsample_sizes_linear_align_corners()

    fn test_downsample_sizes_linear():
        print("== test_downsample_sizes_linear")
        alias type = DType.float32
        var input = Tensor[type](1, 1, 2, 4)
        linear_fill[type](
            input,
            VariadicList[SIMD[type, 1]](1, 2, 3, 4, 5, 6, 7, 8),
        )
        let output = Tensor[type](1, 1, 1, 2)
        var reference = Tensor[type](1, 1, 1, 2)
        # TORCH REFERENCE:
        # x = np.arange(1, 9).reshape((1, 1, 2, 4))
        # y = torch.nn.functional.interpolate(torch.Tensor(x), (1, 2), mode="bilinear")
        # print(y.flatten())
        linear_fill[type](
            reference, VariadicList[SIMD[type, 1]](3.50000, 5.50000)
        )

        test_case_linear[4, CoordinateTransformationMode.HalfPixel, False](
            input, output, reference
        )

    # CHECK-LABEL: test_downsample_sizes_linear
    # CHECK: PASSED
    # CHECK-NOT: ASSERT ERROR
    test_downsample_sizes_linear()

    fn test_downsample_sizes_linear_align_corners():
        print("== test_downsample_sizes_linear_align_corners")
        alias type = DType.float32
        var input = Tensor[type](1, 1, 2, 4)
        linear_fill[type](
            input,
            VariadicList[SIMD[type, 1]](1, 2, 3, 4, 5, 6, 7, 8),
        )
        let output = Tensor[type](1, 1, 1, 2)
        var reference = Tensor[type](1, 1, 1, 2)
        # TORCH REFERENCE:
        # x = np.arange(1, 9).reshape((1, 1, 2, 4))
        # y = torch.nn.functional.interpolate(
        #     torch.Tensor(x), (1, 2), mode="bilinear", align_corners=True
        # )
        # print(y.flatten())
        linear_fill[type](reference, VariadicList[SIMD[type, 1]](1, 4))

        test_case_linear[4, CoordinateTransformationMode.AlignCorners, False](
            input, output, reference
        )

    # CHECK-LABEL: test_downsample_sizes_linear_align_corners
    # CHECK: PASSED
    # CHECK-NOT: ASSERT ERROR
    test_downsample_sizes_linear_align_corners()

    fn test_upsample_sizes_trilinear():
        print("== test_upsample_sizes_trilinear")
        alias type = DType.float32
        var input = Tensor[type](1, 4, 2, 2)
        linear_fill[type](
            input,
            VariadicList[SIMD[type, 1]](
                0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
            ),
        )
        let output = Tensor[type](1, 6, 4, 4)
        var reference = Tensor[type](1, 6, 4, 4)
        # TORCH REFERENCE:
        # x = np.arange(16).reshape((1, 1, 4, 2, 2))
        # y = torch.nn.functional.interpolate(
        #     torch.Tensor(x), (6, 4, 4), mode="trilinear"
        # )
        # print(y.flatten())
        linear_fill[type](
            reference,
            # fmt: off
            VariadicList[SIMD[type, 1]](0.00000,  0.25000,  0.75000,  1.00000,  0.50000,  0.75000,  1.25000,
                1.50000,  1.50000,  1.75000,  2.25000,  2.50000,  2.00000,  2.25000,
                2.75000,  3.00000,  2.00000,  2.25000,  2.75000,  3.00000,  2.50000,
                2.75000,  3.25000,  3.50000,  3.50000,  3.75000,  4.25000,  4.50000,
                4.00000,  4.25000,  4.75000,  5.00000,  4.66667,  4.91667,  5.41667,
                5.66667,  5.16667,  5.41667,  5.91667,  6.16667,  6.16667,  6.41667,
                6.91667,  7.16667,  6.66667,  6.91667,  7.41667,  7.66667,  7.33333,
                7.58333,  8.08333,  8.33333,  7.83333,  8.08333,  8.58333,  8.83333,
                8.83333,  9.08333,  9.58333,  9.83333,  9.33333,  9.58333, 10.08333,
                10.33333, 10.00000, 10.25000, 10.75000, 11.00000, 10.50000, 10.75000,
                11.25000, 11.50000, 11.50000, 11.75000, 12.25000, 12.50000, 12.00000,
                12.25000, 12.75000, 13.00000, 12.00000, 12.25000, 12.75000, 13.00000,
                12.50000, 12.75000, 13.25000, 13.50000, 13.50000, 13.75000, 14.25000,
                14.50000, 14.00000, 14.25000, 14.75000, 15.00000)
            # fmt: on
        )

        test_case_linear[4, CoordinateTransformationMode.HalfPixel, False](
            input, output, reference
        )

    # CHECK-LABEL: test_upsample_sizes_trilinear
    # CHECK: PASSED
    # CHECK-NOT: ASSERT ERROR
    test_upsample_sizes_trilinear()

    fn test_downsample_sizes_linear_antialias():
        print("== test_downsample_sizes_linear_antialias")
        alias type = DType.float32
        var input = Tensor[type](1, 1, 4, 4)
        linear_fill[type](
            input,
            VariadicList[SIMD[type, 1]](
                0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
            ),
        )
        let output = Tensor[type](1, 1, 2, 2)
        var reference = Tensor[type](1, 1, 2, 2)
        # TORCH REFERENCE:
        # x = np.arange(16).reshape((1, 1, 4, 4))
        # y = torch.nn.functional.interpolate(
        #     torch.Tensor(x), (2, 2), mode="bilinear", antialias=True
        # )
        # print(y.flatten())
        linear_fill[type](
            reference,
            VariadicList[SIMD[type, 1]](3.57143, 5.14286, 9.85714, 11.42857),
        )

        test_case_linear[4, CoordinateTransformationMode.HalfPixel, True](
            input, output, reference
        )

    # CHECK-LABEL: test_downsample_sizes_linear_antialias
    # CHECK: PASSED
    # CHECK-NOT: ASSERT ERROR
    test_downsample_sizes_linear_antialias()
