# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo -debug-level full %s | FileCheck %s

from collections.vector import DynamicVector

from NN.NonMaxSuppression import (
    non_max_suppression,
    non_max_suppression_shape_func,
)
from tensor import Tensor, TensorShape

from utils.index import Index


@register_passable("trivial")
struct BoxCoords[type: DType]:
    var y1: SIMD[type, 1]
    var x1: SIMD[type, 1]
    var y2: SIMD[type, 1]
    var x2: SIMD[type, 1]

    fn __init__(
        y1: SIMD[type, 1],
        x1: SIMD[type, 1],
        y2: SIMD[type, 1],
        x2: SIMD[type, 1],
    ) -> Self:
        return Self {y1: y1, x1: x1, y2: y2, x2: x2}


fn fill_boxes[
    type: DType
](batch_size: Int, box_list: VariadicList[BoxCoords[type]]) -> Tensor[type]:
    var num_boxes = len(box_list) // batch_size
    var boxes = Tensor[type](batch_size, num_boxes, 4)
    for i in range(len(box_list)):
        var coords = linear_offset_to_coords[2](
            i, TensorShape(batch_size, num_boxes)
        )
        boxes[Index(coords[0], coords[1], 0)] = box_list[i].y1
        boxes[Index(coords[0], coords[1], 1)] = box_list[i].x1
        boxes[Index(coords[0], coords[1], 2)] = box_list[i].y2
        boxes[Index(coords[0], coords[1], 3)] = box_list[i].x2

    return boxes


fn linear_offset_to_coords[
    rank: Int
](idx: Int, shape: TensorShape) -> StaticIntTuple[rank]:
    var output = StaticIntTuple[rank](0)
    var curr_idx = idx
    for i in range(rank - 1, -1, -1):
        output[i] = curr_idx % shape[i]
        curr_idx //= shape[i]

    return output


fn fill_scores[
    type: DType
](
    batch_size: Int, num_classes: Int, scores_list: VariadicList[SIMD[type, 1]]
) -> Tensor[type]:
    var num_boxes = len(scores_list) // batch_size // num_classes

    var shape = TensorShape(batch_size, num_classes, num_boxes)
    var scores = Tensor[type](shape)
    for i in range(len(scores_list)):
        var coords = linear_offset_to_coords[3](i, shape)
        scores[coords] = scores_list[i]

    return scores


fn test_case[
    type: DType
](
    batch_size: Int,
    num_classes: Int,
    num_boxes: Int,
    iou_threshold: Float32,
    score_threshold: Float32,
    max_output_boxes_per_class: Int,
    box_list: VariadicList[BoxCoords[type]],
    scores_list: VariadicList[SIMD[type, 1]],
):
    var boxes = fill_boxes[type](batch_size, box_list)
    var scores = fill_scores[type](batch_size, num_classes, scores_list)

    var shape = non_max_suppression_shape_func(
        boxes._to_ndbuffer[3](),
        scores._to_ndbuffer[3](),
        max_output_boxes_per_class,
        iou_threshold,
        score_threshold,
    )
    var selected_idxs = Tensor[DType.int64](shape[0], shape[1])
    non_max_suppression(
        boxes._to_ndbuffer[3](),
        scores._to_ndbuffer[3](),
        selected_idxs._to_ndbuffer[2](),
        max_output_boxes_per_class,
        iou_threshold,
        score_threshold,
    )

    # FIXME: missing lifetimes support, needed so that these tensors don't get destroyed
    _ = boxes
    _ = scores

    for i in range(selected_idxs.dim(0)):
        print_no_newline(selected_idxs[i, 0])
        print_no_newline(",")
        print_no_newline(selected_idxs[i, 1])
        print_no_newline(",")
        print_no_newline(selected_idxs[i, 2])
        print_no_newline(",")
        print("")


fn main():
    fn test_no_score_threshold():
        print("== test_no_score_threshold")
        var box_list = VariadicList[BoxCoords[DType.float32]](
            BoxCoords[DType.float32](0.0, 0.0, 1.0, 1.0),
            BoxCoords[DType.float32](0.0, 0.1, 1.0, 1.1),
            BoxCoords[DType.float32](0.0, -0.1, 1.0, 0.9),
            BoxCoords[DType.float32](0.0, 10.0, 1.0, 11.0),
            BoxCoords[DType.float32](0.0, 10.1, 1.0, 11.1),
            BoxCoords[DType.float32](0.0, 100.0, 1.0, 101.0),
        )
        var scores_list = VariadicList[Float32](0.9, 0.75, 0.6, 0.95, 0.5, 0.3)

        test_case[DType.float32](
            1, 1, 6, Float32(0.5), Float32(0.0), 3, box_list, scores_list
        )

    fn test_flipped_coords():
        print("== test_flipped_coords")
        var box_list = VariadicList[BoxCoords[DType.float32]](
            BoxCoords[DType.float32](1.0, 1.0, 0.0, 0.0),
            BoxCoords[DType.float32](1.0, 1.1, 0.0, 0.1),
            BoxCoords[DType.float32](1.0, 0.9, 0.0, -0.1),
            BoxCoords[DType.float32](1.0, 11.0, 0.0, 10.0),
            BoxCoords[DType.float32](1.0, 11.1, 0.0, 10.1),
            BoxCoords[DType.float32](1.0, 101.0, 0.0, 100.0),
        )
        var scores_list = VariadicList[Float32](0.9, 0.75, 0.6, 0.95, 0.5, 0.3)

        test_case[DType.float32](
            1, 1, 6, Float32(0.5), Float32(0.0), 3, box_list, scores_list
        )

    fn test_reflect_over_yx():
        print("== test_reflect_over_yx")
        var box_list = VariadicList[BoxCoords[DType.float32]](
            BoxCoords[DType.float32](-1.0, -1.0, 0.0, 0.0),
            BoxCoords[DType.float32](-1.0, -1.1, 0.0, -0.1),
            BoxCoords[DType.float32](-1.0, -0.9, 0.0, 0.1),
            BoxCoords[DType.float32](-1.0, -11.0, 0.0, -10.0),
            BoxCoords[DType.float32](-1.0, -11.1, 0.0, -10.1),
            BoxCoords[DType.float32](-1.0, -101.0, 0.0, -100.0),
        )
        var scores_list = VariadicList[Float32](0.9, 0.75, 0.6, 0.95, 0.5, 0.3)

        test_case[DType.float32](
            1, 1, 6, Float32(0.5), Float32(0.0), 3, box_list, scores_list
        )

    fn test_score_threshold():
        print("== test_score_threshold")
        var box_list = VariadicList[BoxCoords[DType.float32]](
            BoxCoords[DType.float32](0.0, 0.0, 1.0, 1.0),
            BoxCoords[DType.float32](0.0, 0.1, 1.0, 1.1),
            BoxCoords[DType.float32](0.0, -0.1, 1.0, 0.9),
            BoxCoords[DType.float32](0.0, 10.0, 1.0, 11.0),
            BoxCoords[DType.float32](0.0, 10.1, 1.0, 11.1),
            BoxCoords[DType.float32](0.0, 100.0, 1.0, 101.0),
        )
        var scores_list = VariadicList[Float32](0.9, 0.75, 0.6, 0.95, 0.5, 0.3)

        test_case[DType.float32](
            1, 1, 6, Float32(0.5), Float32(0.4), 3, box_list, scores_list
        )

    fn test_limit_outputs():
        print("== test_limit_outputs")
        var box_list = VariadicList[BoxCoords[DType.float32]](
            BoxCoords[DType.float32](0.0, 0.0, 1.0, 1.0),
            BoxCoords[DType.float32](0.0, 0.1, 1.0, 1.1),
            BoxCoords[DType.float32](0.0, -0.1, 1.0, 0.9),
            BoxCoords[DType.float32](0.0, 10.0, 1.0, 11.0),
            BoxCoords[DType.float32](0.0, 10.1, 1.0, 11.1),
            BoxCoords[DType.float32](0.0, 100.0, 1.0, 101.0),
        )
        var scores_list = VariadicList[Float32](0.9, 0.75, 0.6, 0.95, 0.5, 0.3)

        test_case[DType.float32](
            1, 1, 6, Float32(0.5), Float32(0.0), 2, box_list, scores_list
        )

    fn test_single_box():
        print("== test_single_box")
        var box_list = VariadicList[BoxCoords[DType.float32]](
            BoxCoords[DType.float32](0.0, 0.0, 1.0, 1.0),
        )
        var scores_list = VariadicList[Float32](0.9)

        test_case[DType.float32](
            1, 1, 1, Float32(0.5), Float32(0.0), 2, box_list, scores_list
        )

    fn test_two_classes():
        print("== test_two_classes")
        var box_list = VariadicList[BoxCoords[DType.float32]](
            BoxCoords[DType.float32](0.0, 0.0, 1.0, 1.0),
            BoxCoords[DType.float32](0.0, 0.1, 1.0, 1.1),
            BoxCoords[DType.float32](0.0, -0.1, 1.0, 0.9),
            BoxCoords[DType.float32](0.0, 10.0, 1.0, 11.0),
            BoxCoords[DType.float32](0.0, 10.1, 1.0, 11.1),
            BoxCoords[DType.float32](0.0, 100.0, 1.0, 101.0),
        )
        var scores_list = VariadicList[Float32](
            0.9,
            0.75,
            0.6,
            0.95,
            0.5,
            0.3,
            0.9,
            0.75,
            0.6,
            0.95,
            0.5,
            0.3,
        )

        test_case[DType.float32](
            1, 2, 6, Float32(0.5), Float32(0.0), 2, box_list, scores_list
        )

    fn test_two_batches():
        print("== test_two_batches")
        var box_list = VariadicList[BoxCoords[DType.float32]](
            BoxCoords[DType.float32](0.0, 0.0, 1.0, 1.0),
            BoxCoords[DType.float32](0.0, 0.1, 1.0, 1.1),
            BoxCoords[DType.float32](0.0, -0.1, 1.0, 0.9),
            BoxCoords[DType.float32](0.0, 10.0, 1.0, 11.0),
            BoxCoords[DType.float32](0.0, 10.1, 1.0, 11.1),
            BoxCoords[DType.float32](0.0, 100.0, 1.0, 101.0),
            BoxCoords[DType.float32](0.0, 0.0, 1.0, 1.0),
            BoxCoords[DType.float32](0.0, 0.1, 1.0, 1.1),
            BoxCoords[DType.float32](0.0, -0.1, 1.0, 0.9),
            BoxCoords[DType.float32](0.0, 10.0, 1.0, 11.0),
            BoxCoords[DType.float32](0.0, 10.1, 1.0, 11.1),
            BoxCoords[DType.float32](0.0, 100.0, 1.0, 101.0),
        )
        var scores_list = VariadicList[Float32](
            0.9,
            0.75,
            0.6,
            0.95,
            0.5,
            0.3,
            0.9,
            0.75,
            0.6,
            0.95,
            0.5,
            0.3,
        )

        test_case[DType.float32](
            2, 1, 6, Float32(0.5), Float32(0.0), 2, box_list, scores_list
        )

    # CHECK-LABEL: == test_no_score_threshold
    # CHECK: 0,0,3,
    # CHECK-NEXT: 0,0,0,
    # CHECK-NEXT: 0,0,5,
    test_no_score_threshold()

    # CHECK-LABEL: == test_flipped_coords
    # CHECK: 0,0,3,
    # CHECK-NEXT: 0,0,0,
    # CHECK-NEXT: 0,0,5,
    test_flipped_coords()

    # CHECK-LABEL: == test_reflect_over_yx
    # CHECK: 0,0,3,
    # CHECK-NEXT: 0,0,0,
    # CHECK-NEXT: 0,0,5,
    test_reflect_over_yx()

    # CHECK-LABEL: == test_score_threshold
    # CHECK: 0,0,3,
    # CHECK-NEXT: 0,0,0,
    test_score_threshold()

    # CHECK-LABEL: == test_limit_outputs
    # CHECK: 0,0,3,
    # CHECK-NEXT: 0,0,0,
    test_limit_outputs()

    # CHECK-LABEL: == test_single_box
    # CHECK: 0,0,0,
    test_single_box()

    # CHECK-LABEL: == test_two_classes
    # CHECK: 0,0,3,
    # CHECK-NEXT: 0,0,0,
    # CHECK-NEXT: 0,1,3,
    # CHECK-NEXT: 0,1,0,
    test_two_classes()

    # CHECK-LABEL: == test_two_batches
    # CHECK: 0,0,3,
    # CHECK-NEXT: 0,0,0,
    # CHECK-NEXT: 1,0,3,
    # CHECK-NEXT: 1,0,0,
    test_two_batches()
