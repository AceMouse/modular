# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #
# RUN: %mojo -debug-level full %s | FileCheck %s

from math import abs, ceil, div_ceil, max
from sys.info import alignof, sizeof

from memory.buffer import NDBuffer
from quantization import Q4sym


fn _run_test_quant[group_size: Int, tolerance: FloatLiteralOld]() -> Bool:
    var uniform = SIMD[DType.float32, group_size]()
    for i in range(group_size):
        uniform[i] = i
    uniform -= group_size // 2

    var skew_pos = uniform + 30
    var skew_neg = uniform - 30
    var skew_slightly_pos = uniform + 1.842
    var skew_slightly_neg = uniform - 1.842
    var big_range = uniform * 1000
    var unitary = SIMD[DType.float32, group_size].splat(1.0)

    fn run_fake_quant(input_vec: SIMD[DType.float32, group_size]) -> Bool:
        var packed_result = Q4sym[group_size, DType.float32](input_vec)
        var decoded_result = packed_result.decode_fully()
        print("input_vec        :", input_vec)
        print("fakeq_result     :", decoded_result)
        print("abs-err          :", input_vec - decoded_result)
        print(
            "max abs-err      :", abs(input_vec - decoded_result).reduce_max()
        )

        var l2_norm_err = (
            (input_vec - decoded_result) * (input_vec - decoded_result)
        ).reduce_add()
        l2_norm_err = l2_norm_err**0.5
        var l2_norm_input = (input_vec * input_vec).reduce_add() ** 0.5
        var rel_l2_norm = l2_norm_err / l2_norm_input
        print("rel-l2-norm      :", rel_l2_norm)

        return rel_l2_norm < tolerance

    var allPass: Bool = True
    allPass = allPass and run_fake_quant(uniform)
    allPass = allPass and run_fake_quant(skew_pos)
    allPass = allPass and run_fake_quant(skew_neg)
    allPass = allPass and run_fake_quant(skew_slightly_pos)
    allPass = allPass and run_fake_quant(skew_slightly_neg)
    allPass = allPass and run_fake_quant(big_range)
    allPass = allPass and run_fake_quant(unitary)
    return allPass


fn test_fake_quant_error[l2_tolerance: FloatLiteralOld]():
    # Tests round-trippability of encoding/decoding groups of numbers
    print("------------test_fake_quant_error------------")
    print("********** GROUP SIZE 08 **********")
    var g8_result = _run_test_quant[8, l2_tolerance]()
    print("G08 PASS" if g8_result else "FAIL")
    print()

    print("********** GROUP SIZE 16 **********")
    var g16_result = _run_test_quant[16, l2_tolerance]()
    print("G16 PASS" if g16_result else "FAIL")
    print()

    print("********** GROUP SIZE 32 **********")
    var g32_result = _run_test_quant[32, l2_tolerance]()
    print("------------test_fake_quant_error------------")
    print("G32 PASS" if g32_result else "FAIL")
    print()


fn test_alignment_and_size():
    # Tests the total size and alignment of structs is as expected
    print("-------test_alignment_and_size-------")
    print("StructType, Sizeof, Alignment")
    print(
        "Q5sym[32, DType.float32]",
        sizeof[Q4sym[32, DType.float32]](),
        alignof[Q4sym[32, DType.float32]](),
    )
    print(
        "Q5sym[16, DType.float32]",
        sizeof[Q4sym[16, DType.float32]](),
        alignof[Q4sym[16, DType.float32]](),
    )
    print(
        "Q5sym[8, DType.float32]",
        sizeof[Q4sym[8, DType.float32]](),
        alignof[Q4sym[8, DType.float32]](),
    )
    # Calculation for group size 8:
    # - 2 bytes for fp16 scale
    # - 8 // 2 = 4 bytes for the low bits
    # 2 + 4 = 6
    # Bits per weight: (8 * 6) / 8 = 6bpw
    constrained[sizeof[Q4sym[8]]() == 6]()

    # Calculation for group size 16:
    # - 2 bytes for fp16 scale
    # - 16 // 2 = 8 bytes for the low bits
    # 2 + 8 = 10
    # Bits per weight: (8 * 10) / 16 = 5bpw
    constrained[sizeof[Q4sym[16]]() == 10]()

    # Calculation for group size 32:
    # - 2 bytes for fp16 scale
    # - 32 // 2 = 16 bytes for the low bits
    # 2 + 16 = 18
    # Bits per weight: (8 * 18) / 32 = 4.5bpw
    constrained[sizeof[Q4sym[32]]() == 18]()
    print("-------test_alignment_and_size-------")
    print()


fn _read_write_to_tensors[
    group_size: Int,
    rtol: FloatLiteralOld,
    atol: FloatLiteralOld,
    num_elements: Int = 64,
    rank: Int = 1,
]() -> Bool:
    # Write a quantized tensor, and then immediately decode, making sure results
    # are close.

    # Allocate and populate tensor to encode
    # Buffer with the original data
    var data_matrix = NDBuffer[
        DType.float32,
        rank,
        DimList(num_elements),
    ].stack_allocation()
    for i in range(num_elements):
        data_matrix[i] = i

    # Tensor to store the packed data
    constrained[num_elements % group_size == 0]()
    alias num_blocks = div_ceil(num_elements, group_size)
    alias block_size = sizeof[Q4sym[group_size]]()
    var packed_blob = NDBuffer[
        DType.uint8, rank, DimList(num_blocks * block_size)
    ].stack_allocation()

    # Tensor to store the dequantized data
    var out_data_matrix = NDBuffer[
        DType.float32,
        1,
        DimList(num_elements),
    ].stack_allocation()
    for i in range(num_elements):
        out_data_matrix[i] = 0

    var rebound_data_matrix = rebind[NDBuffer[DType.float32, rank]](data_matrix)
    var rebound_packed_block = rebind[NDBuffer[DType.uint8, rank]](packed_blob)
    var rebound_out_data_matrix = rebind[NDBuffer[DType.float32, rank]](
        out_data_matrix
    )

    Q4sym[group_size, DType.float32].quantize_and_write_to_tensor[rank](
        rebound_data_matrix,
        rebound_packed_block,
        StaticIntTuple[rank](num_elements),
    )

    Q4sym[group_size, DType.float32].dequantize_and_write_to_tensor[rank](
        rebound_packed_block,
        rebound_out_data_matrix,
        StaticIntTuple[rank](num_elements),
    )

    var allClose: Bool = True
    # See if it prints the correct results!
    for i in range(num_elements):
        var localRDiff = abs(
            (data_matrix[i] - out_data_matrix[i]) / (data_matrix[i] + 1e-10)
        )
        var acceptableErr = abs(data_matrix[i] * rtol) + atol
        print(
            "fake-quantized:",
            out_data_matrix[i],
            " vs original:",
            data_matrix[i],
            " -- rel-diff: ",
            localRDiff,
        )
        allClose = allClose and (localRDiff <= acceptableErr)
    return allClose


fn test_read_write_to_tensors[rtol: FloatLiteralOld, atol: FloatLiteralOld]():
    print("------------test_fake_quant_error------------")

    print("********** GROUP SIZE 08 **********")
    var g8_result = _read_write_to_tensors[8, rtol, atol]()
    print("G08 PASS" if g8_result else "FAIL")
    print()

    print("********** GROUP SIZE 16 **********")
    var g16_result = _read_write_to_tensors[16, rtol, atol]()
    print("G16 PASS" if g8_result else "FAIL")
    print()

    print("********** GROUP SIZE 32 **********")
    var g32_result = _read_write_to_tensors[32, rtol, atol]()
    print("G32 PASS" if g8_result else "FAIL")
    print()

    print("------------test_fake_quant_error------------")
    print()


fn main():
    alias l2_tolerance: FloatLiteralOld = 0.1

    # CHECK-LABEL: G08 PASS
    # CHECK-LABEL: G16 PASS
    # CHECK-LABEL: G32 PASS
    test_fake_quant_error[l2_tolerance]()

    # CHECK-LABEL: G08 PASS
    # CHECK-LABEL: G16 PASS
    # CHECK-LABEL: G32 PASS
    alias rtol: FloatLiteralOld = 0.1
    alias atol: FloatLiteralOld = 1.0
    test_read_write_to_tensors[rtol, atol]()

    # Tests via compile-time constraints on sizeof(Q4Sym)
    test_alignment_and_size()
