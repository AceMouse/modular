# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

# RUN: %mojo-no-debug %s -t

from algorithm import max
from buffer import Buffer, NDBuffer, Dim, DimList
from gpu.host import DeviceContext
from kv_cache.types import ContinuousBatchingKVCache, KVCacheStaticParams
from math import isqrt, isclose
from memory import UnsafePointer
from nn.mha import mha_gpu_naive, flash_attention
from nn.mha_mask import NullMask, CausalMask
from nn.mha_score_mod import IdentityScoreMod
from internal_utils import (
    HostNDBuffer,
    DeviceNDBuffer,
    random,
)
from memory import memcpy
from runtime.asyncrt import (
    MojoCallContextPtr,
)
from testing import assert_almost_equal
from utils import IndexList
from utils.index import Index
from utils.numerics import min_or_neg_inf
from collections import Set
from random import random_ui64, seed

alias kv_params_replit = KVCacheStaticParams(num_heads=8, head_size=128)
alias replit_num_q_heads = 24

alias kv_params_llama3 = KVCacheStaticParams(num_heads=8, head_size=128)
alias llama_num_q_heads = 32


def execute_ragged_flash_attention[
    num_q_heads: Int, type: DType, kv_params: KVCacheStaticParams
](
    valid_lengths: List[Int],
    max_seq_len_cache: Int,
    cache_lengths: List[Int],
    num_layers: Int,
    layer_idx: Int,
    ctx: DeviceContext,
):
    alias num_blocks = 32
    alias CacheType = ContinuousBatchingKVCache[
        type,
        kv_params,
    ]

    var batch_size = len(valid_lengths)
    debug_assert(
        batch_size < num_blocks,
        "batch_size passed to unit test ("
        + str(batch_size)
        + ") is larger than configured num_blocks ("
        + str(num_blocks)
        + ")",
    )
    debug_assert(
        len(valid_lengths) == len(cache_lengths),
        "expected valid_lengths and cache_lengths size to be equal",
    )

    var input_row_offset_host = HostNDBuffer[DType.uint32, 1](
        IndexList[1](batch_size + 1)
    )
    var cache_lengths_host = HostNDBuffer[DType.uint32, 1](
        IndexList[1](batch_size)
    )
    var valid_lengths_host = HostNDBuffer[DType.uint32, 1](
        IndexList[1](batch_size)
    )

    var total_length = 0
    var max_context_length = -1
    var max_prompt_length = -1
    var is_context_encoding = True
    for i in range(batch_size):
        input_row_offset_host.tensor[i] = total_length
        cache_lengths_host.tensor[i] = cache_lengths[i]
        valid_lengths_host.tensor[i] = valid_lengths[i]
        full_context_length = cache_lengths[i] + valid_lengths[i]
        if full_context_length > max_context_length:
            max_context_length = full_context_length

        if valid_lengths[i] > max_prompt_length:
            max_prompt_length = valid_lengths[i]

        if cache_lengths[i] > 0:
            is_context_encoding = False

        total_length += valid_lengths[i]
    input_row_offset_host.tensor[batch_size] = total_length

    input_row_offset_device = input_row_offset_host.copy_to_device(ctx)
    valid_lengths_device = valid_lengths_host.copy_to_device(ctx)
    cache_lengths_device = cache_lengths_host.copy_to_device(ctx)

    q_ragged_host = HostNDBuffer[
        type, 3, DimList(Dim(), num_q_heads, kv_params.head_size)
    ](IndexList[3](total_length, num_q_heads, kv_params.head_size))
    random(q_ragged_host.tensor)
    q_padded_host = HostNDBuffer[
        type, 4, DimList(Dim(), Dim(), num_q_heads, kv_params.head_size)
    ](
        IndexList[4](
            batch_size, max_prompt_length, num_q_heads, kv_params.head_size
        )
    )

    # copy over the ragged values to the padded tensor.
    # Don't worry about padded values, we won't read them.
    for bs in range(batch_size):
        unpadded_seq_len = valid_lengths[bs]
        ragged_start_idx = int(input_row_offset_host.tensor[bs])
        padded_ptr = q_padded_host.tensor._offset((bs, 0, 0, 0))
        ragged_ptr = q_ragged_host.tensor._offset((ragged_start_idx, 0, 0))
        memcpy(
            padded_ptr,
            ragged_ptr,
            unpadded_seq_len * num_q_heads * kv_params.head_size,
        )

    q_ragged_device = q_ragged_host.copy_to_device(ctx)
    q_padded_device = q_padded_host.copy_to_device(ctx)

    # initialize mask tensor
    # dummy mask to satisfy the argument.
    dummy_mask = NDBuffer[type, 4](
        UnsafePointer[Scalar[type]](), IndexList[4]()
    )

    # initialize scale tensor
    scale_host = HostNDBuffer[DType.float32, 1, DimList(1)](IndexList[1](1))

    scale_host.tensor[0] = isqrt(Float32(kv_params.head_size))
    scale_device = scale_host.copy_to_device(ctx)

    # initialize reference output
    ref_output_host = HostNDBuffer[
        type, 4, DimList(Dim(), Dim(), num_q_heads, kv_params.head_size)
    ](
        IndexList[4](
            batch_size, max_prompt_length, num_q_heads, kv_params.head_size
        ),
    )
    ref_output_device = ref_output_host.copy_to_device(ctx)

    test_output_host = HostNDBuffer[
        type, 3, DimList(Dim(), num_q_heads, kv_params.head_size)
    ](IndexList[3](total_length, num_q_heads, kv_params.head_size))
    test_output_device = test_output_host.copy_to_device(ctx)

    # initialize our KVCache
    kv_block_host = HostNDBuffer[type, 6,](
        IndexList[6](
            num_blocks,
            2,
            num_layers,
            max_seq_len_cache,
            kv_params.num_heads,
            kv_params.head_size,
        ),
    )
    random(kv_block_host.tensor)
    kv_block_device = kv_block_host.copy_to_device(ctx)
    var lookup_table_host = HostNDBuffer[DType.uint32, 1,](
        IndexList[1](
            batch_size,
        ),
    )

    # hacky way to select random blocks.
    var block_idx_set = Set[Int]()
    var idx = 0
    while idx < batch_size:
        var randval = int(random_ui64(0, num_blocks - 1))
        if randval in block_idx_set:
            continue

        block_idx_set.add(randval)
        lookup_table_host.tensor[idx] = UInt32(randval)
        idx += 1

    var lookup_table_device = lookup_table_host.copy_to_device(ctx)
    var k_cache_device = CacheType(
        kv_block_device.tensor,
        cache_lengths_device.tensor,
        lookup_table_device.tensor,
        is_context_encoding,
        layer_idx,
        CacheType.KeyIdx,
    )
    var k_cache_host = CacheType(
        kv_block_host.tensor,
        cache_lengths_host.tensor,
        lookup_table_host.tensor,
        is_context_encoding,
        layer_idx,
        CacheType.KeyIdx,
    )
    var v_cache_device = CacheType(
        kv_block_device.tensor,
        cache_lengths_device.tensor,
        lookup_table_device.tensor,
        is_context_encoding,
        layer_idx,
        CacheType.ValueIdx,
    )
    var v_cache_host = CacheType(
        kv_block_host.tensor,
        cache_lengths_host.tensor,
        lookup_table_host.tensor,
        is_context_encoding,
        layer_idx,
        CacheType.ValueIdx,
    )

    # ragged execution
    flash_attention[add_attn_mask=False, ragged=True](
        test_output_device.tensor,
        q_ragged_device.tensor,
        k_cache_device,
        v_cache_device,
        dummy_mask,
        CausalMask(),
        IdentityScoreMod(),
        input_row_offset_device.tensor,
        # TODO take scale from argument GRA-750
        isqrt(Float32(kv_params.head_size)),
        ctx,
    )
    # padded execution
    flash_attention[add_attn_mask=False](
        ref_output_device.tensor,
        q_padded_device.tensor,
        k_cache_device,
        v_cache_device,
        dummy_mask,
        CausalMask(),
        IdentityScoreMod(),
        valid_lengths_device.tensor,
        # TODO take scale from argument GRA-750
        isqrt(Float32(kv_params.head_size)),
        ctx,
    )

    ctx.enqueue_copy_from_device(
        test_output_host.tensor.data, test_output_device.buffer
    )
    ctx.enqueue_copy_from_device(
        ref_output_host.tensor.data, ref_output_device.buffer
    )
    ctx.synchronize()

    ref_out = ref_output_host.tensor
    test_out = test_output_host.tensor
    for bs in range(batch_size):
        prompt_len = valid_lengths[bs]
        ragged_offset = int(input_row_offset_host.tensor[bs])
        for s in range(prompt_len):
            for h in range(num_q_heads):
                for hd in range(kv_params.head_size):
                    try:
                        assert_almost_equal(
                            ref_out[bs, s, h, hd],
                            test_out[ragged_offset + s, h, hd],
                        )
                    except e:
                        print(
                            "MISMATCH:",
                            bs,
                            s,
                            h,
                            hd,
                            ref_out[bs, s, h, hd],
                            test_out[ragged_offset + s, h, hd],
                        )
                        raise e

    _ = q_ragged_host^
    _ = q_ragged_device^
    _ = q_padded_host^
    _ = q_padded_device^
    _ = scale_host^
    _ = scale_device^
    _ = kv_block_host^
    _ = kv_block_device^
    _ = lookup_table_host^
    _ = lookup_table_device^
    _ = ref_output_device^
    _ = ref_output_host^
    _ = test_output_device^
    _ = test_output_host^
    _ = valid_lengths_device^
    _ = valid_lengths_host^
    _ = cache_lengths_host^
    _ = cache_lengths_device^


def execute_flash_attention_suite(ctx: DeviceContext):
    alias types = Tuple[DType, DType](DType.float32, DType.bfloat16)

    for bs_ref in List[Int](1, 16):

        @parameter
        for type_idx in range(2):
            alias type = types.get[type_idx, DType]()

            bs = bs_ref[]
            ce_cache_sizes = List[Int]()
            ce_seq_lens = List[Int]()
            tg_cache_sizes = List[Int]()
            tg_seq_lens = List[Int]()
            for _ in range(bs):
                tg_seq_lens.append(1)
                tg_cache_sizes.append(int(random_ui64(1, 100)))
                ce_seq_lens.append(int(random_ui64(1, 100)))
                ce_cache_sizes.append(0)
            print("CE", bs, type)
            execute_ragged_flash_attention[
                llama_num_q_heads, type, kv_params_llama3
            ](ce_seq_lens, 110, ce_cache_sizes, 2, 1, ctx)

            print("TG", bs, type)
            execute_ragged_flash_attention[
                llama_num_q_heads, type, kv_params_llama3
            ](tg_seq_lens, 110, tg_cache_sizes, 2, 0, ctx)

    # edge cases
    var short_ce_seq_len = List[Int](2)
    var short_ce_cache_size = List[Int](0)
    execute_ragged_flash_attention[
        llama_num_q_heads, DType.bfloat16, kv_params_llama3
    ](short_ce_seq_len, 110, short_ce_cache_size, 2, 1, ctx)


def main():
    seed(42)
    with DeviceContext() as ctx:
        execute_flash_attention_suite(ctx)
