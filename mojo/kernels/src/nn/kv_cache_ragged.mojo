# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

from collections import Optional, OptionalReg

from buffer import Dim, DimList, NDBuffer
from gpu.host import DeviceContext
from gpu.host.info import is_cpu, is_gpu
from kv_cache.types import (
    ContinuousBatchingKVCache,
    ContinuousBatchingKVCacheCollection,
    KVCacheStaticParams,
    KVCacheT,
    KVCollectionT,
    PagedKVCache,
    PagedKVCacheCollection,
)
from linalg.matmul import elementwise_epilogue_type, matmul
from quantization.qmatmul_gpu import matmul_gpu_qint4_impl
from memory import UnsafePointer
from nn._ragged_utils import get_batch_from_row_offsets
from nn.flash_attention import (
    flash_attention_kv_cache as flash_attention_kv_cache_cpu,
)
from nn.fused_qk_rope import fused_qk_rope_ragged
from nn.mha import flash_attention as gpu_flash_attention
from nn.mha_mask import CausalMask, MHAMask, NullMask
from nn.mha_score_mod import AlibiScoreMod, IdentityScoreMod
from register import register_internal
from runtime.asyncrt import MojoCallContextPtr
from runtime.tracing import Trace, TraceLevel, trace_arg

from utils.index import Index, IndexList

# ===-----------------------------------------------------------------------===#
# Fused QKV matmul (ragged)
# ===-----------------------------------------------------------------------===#


@always_inline
fn generic_fused_qkv_matmul_kv_cache_cont_batch_ragged[
    type: DType, //,
    target: StringLiteral = "cpu",
](
    hidden_state: NDBuffer[type, 2, _],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    weight: NDBuffer[type, 2, _],
    kv_collection: ContinuousBatchingKVCacheCollection,
    layer_idx: UInt32,
    output: NDBuffer[type, 2, _],
    ctx: MojoCallContextPtr,
) raises:
    """Performs a fused QKV matmul. Q outputs are written to the output argument
    while K and V outputs are written in-place into k_cache and v_cache.

    Args:
        hidden_state: Tensor with shape (sum(seq_lens), num_heads * head_size).
        input_row_offsets: Tensor with shape (batch_size + 1,).
            The value at each index is the start_idx of the corresponding batch in hidden_state.
        weight: Tensor with shape (num_heads * head_size, num_kv_heads * head_size).
        kv_collection: The object storing the KVCache for this layer.
        layer_idx: The current layer, used to retrieve the KVCache object from kv_collection.
        output: The pre-allocated output buffer for Q projections. K and V
            projections are written in-place to k_cache and v_cache.
            Shape: (sum(seq_lens), num_heads * head_size).
        ctx: The call context pointer, passed by the graph compiler.
    """

    @always_inline
    @parameter
    fn description_fn() -> String:
        return String(
            trace_arg("output", output),
            trace_arg("hidden_state", hidden_state),
            trace_arg("weight", weight),
            trace_arg("layer_idx", layer_idx),
            trace_arg("num_heads", kv_collection.kv_params.num_heads),
            trace_arg("head_size", kv_collection.kv_params.head_size),
            sep=";",
        )

    with Trace[TraceLevel.OP, target=target](
        String(
            "mo.fused_qkv_matmul.ragged.continuous_batching.nhead_",
            kv_collection.kv_params.num_heads,
            ".hdim_",
            kv_collection.kv_params.head_size,
            Trace[TraceLevel.OP]._get_detail_str[description_fn](),
        )
    ):
        return _fused_qkv_matmul_kv_cache_ragged[
            kv_collection.CacheType, target=target
        ](
            hidden_state,
            input_row_offsets,
            weight,
            kv_collection,
            layer_idx,
            output,
            ctx,
        )


@always_inline
fn generic_fused_qkv_matmul_kv_cache_paged_ragged[
    type: DType,
    weight_type: DType,
    target: StringLiteral = "cpu",
    group_size: OptionalReg[Int] = None,
    has_zp: OptionalReg[Bool] = None,
](
    hidden_state: NDBuffer[type, 2, _],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    weight: NDBuffer[weight_type, 2, _],
    kv_collection: PagedKVCacheCollection,
    layer_idx: UInt32,
    output: NDBuffer[type, 2, _],
    ctx: MojoCallContextPtr,
) raises:
    """Performs a fused QKV matmul. Q outputs are written to the output argument
    while K and V outputs are written in-place into k_cache and v_cache.

    Args:
        hidden_state: Tensor with shape (sum(seq_lens), num_heads * head_size).
        input_row_offsets: Tensor with shape (batch_size + 1,).
            The value at each index is the start_idx of the corresponding batch in hidden_state.
        weight: Tensor with shape (num_heads * head_size, num_kv_heads * head_size).
        kv_collection: The object storing the KVCache for this layer.
        layer_idx: The current layer, used to retrieve the KVCache object from kv_collection.
        output: The pre-allocated output buffer for Q projections. K and V
            projections are written in-place to k_cache and v_cache.
            Shape: (sum(seq_lens), num_heads * head_size).
        ctx: The call context pointer, passed by the graph compiler.
    """

    @always_inline
    @parameter
    fn description_fn() -> String:
        return String(
            trace_arg("output", output),
            trace_arg("hidden_state", hidden_state),
            trace_arg("weight", weight),
            trace_arg("layer_idx", layer_idx),
            trace_arg("num_heads", kv_collection.kv_params.num_heads),
            trace_arg("head_size", kv_collection.kv_params.head_size),
            sep=";",
        )

    alias name = String(
        "mo.fused_qkv_matmul.ragged.paged.nhead_",
        kv_collection.kv_params.num_heads,
        ".hdim_",
        kv_collection.kv_params.head_size,
    )
    with Trace[TraceLevel.OP, target=target](
        name,
        Trace[TraceLevel.OP]._get_detail_str[description_fn](),
    ):
        return _fused_qkv_matmul_kv_cache_ragged[
            kv_collection.CacheType,
            target=target,
            group_size=group_size,
            has_zp=has_zp,
        ](
            hidden_state,
            input_row_offsets,
            weight,
            kv_collection,
            layer_idx,
            output,
            ctx,
        )


@always_inline
fn generic_fused_qkv_matmul_kv_cache_paged_ragged_bias[
    type: DType,
    weight_type: DType,
    target: StringLiteral = "cpu",
    group_size: OptionalReg[Int] = None,
    has_zp: OptionalReg[Bool] = None,
](
    hidden_state: NDBuffer[type, 2, _],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    weight: NDBuffer[weight_type, 2, _],
    kv_collection: PagedKVCacheCollection,
    layer_idx: UInt32,
    output: NDBuffer[type, 2, _],
    bias: NDBuffer[type, 1],
    ctx: MojoCallContextPtr,
) raises:
    """Performs a fused QKV matmul. Q outputs are written to the output argument
    while K and V outputs are written in-place into k_cache and v_cache.

    Args:
        hidden_state: Tensor with shape (sum(seq_lens), num_heads * head_size).
        input_row_offsets: Tensor with shape (batch_size + 1,).
            The value at each index is the start_idx of the corresponding batch in hidden_state.
        weight: Tensor with shape (num_heads * head_size, num_kv_heads * head_size).
        kv_collection: The object storing the KVCache for this layer.
        layer_idx: The current layer, used to retrieve the KVCache object from kv_collection.
        output: The pre-allocated output buffer for Q projections. K and V
            projections are written in-place to k_cache and v_cache.
            Shape: (sum(seq_lens), num_heads * head_size).
        bias: Bias to be added to the QKV Tensor. Tensor is concatenated q + k + v. Rank 1.
        ctx: The call context pointer, passed by the graph compiler.
    """

    @always_inline
    @parameter
    fn description_fn() -> String:
        return String(";").join(
            trace_arg("output", output),
            trace_arg("hidden_state", hidden_state),
            trace_arg("weight", weight),
            "layer_idx=" + String(layer_idx),
            "num_heads=" + String(kv_collection.kv_params.num_heads),
            "head_size=" + String(kv_collection.kv_params.head_size),
        )

    alias name = "mo.fused_qkv_matmul.ragged.paged.bias.nhead_" + String(
        kv_collection.kv_params.num_heads
    ) + ".hdim_" + String(kv_collection.kv_params.head_size)
    with Trace[TraceLevel.OP, target=target](
        name,
        Trace[TraceLevel.OP]._get_detail_str[description_fn](),
    ):
        return _fused_qkv_matmul_kv_cache_ragged_bias[
            kv_collection.CacheType,
            target=target,
            group_size=group_size,
            has_zp=has_zp,
        ](
            hidden_state,
            input_row_offsets,
            weight,
            kv_collection,
            layer_idx,
            output,
            bias,
            ctx,
        )


@always_inline
fn _fused_qkv_matmul_kv_cache_ragged[
    type: DType,
    weight_type: DType,
    collection_t: KVCollectionT, //,
    cache_t: KVCacheT,
    *,
    target: StringLiteral,
    group_size: OptionalReg[Int] = None,
    has_zp: OptionalReg[Bool] = None,
](
    hidden_state: NDBuffer[type, 2, _],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    weight: NDBuffer[weight_type, 2, _],
    kv_collection: collection_t,
    layer_idx: UInt32,
    output: NDBuffer[type, 2, _],
    context: MojoCallContextPtr,
) raises:
    """Performs a fused QKV matmul. Q outputs are written to the output argument
    while K and V outputs are written in-place into k_cache and v_cache.

    Args:
        hidden_state: Tensor with shape (batch_size, seq_len, num_heads * head_size).
        input_row_offsets: Tensor with shape (batch_size + 1,).
            The value at each index is the start_idx of the corresponding batch in hidden_state.
        weight: Tensor with shape (num_heads * head_size, num_kv_heads * head_size).
        kv_collection: The object storing the KVCache for this layer.
        layer_idx: The current layer, used to retrieve the KVCache object from kv_collection.
        output: The pre-allocated output buffer for Q projections. K and V
            projections are written in-place to k_cache and v_cache.
        context: The call context pointer, passed by the graph compiler.
    """
    var cuda_ctx: Optional[DeviceContext] = None
    var layer_idx_cast = Int(layer_idx)
    var k_cache = kv_collection.get_key_cache(layer_idx_cast)
    var v_cache = kv_collection.get_value_cache(layer_idx_cast)

    @parameter
    if is_gpu[target]():
        cuda_ctx = context.get_device_context()

    return _fused_qkv_matmul_kv_cache_ragged_impl[
        target=target,
        group_size=group_size,
        has_zp=has_zp,
    ](
        hidden_state,
        input_row_offsets,
        weight,
        k_cache,
        v_cache,
        output,
        cuda_ctx,
    )


@always_inline
fn _fused_qkv_matmul_kv_cache_ragged_bias[
    type: DType,
    weight_type: DType,
    collection_t: KVCollectionT, //,
    cache_t: KVCacheT,
    *,
    target: StringLiteral,
    group_size: OptionalReg[Int] = None,
    has_zp: OptionalReg[Bool] = None,
](
    hidden_state: NDBuffer[type, 2, _],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    weight: NDBuffer[weight_type, 2, _],
    kv_collection: collection_t,
    layer_idx: UInt32,
    output: NDBuffer[type, 2, _],
    bias: NDBuffer[type, 1],
    context: MojoCallContextPtr,
) raises:
    """Performs a fused QKV matmul. Q outputs are written to the output argument
    while K and V outputs are written in-place into k_cache and v_cache.

    Args:
        hidden_state: Tensor with shape (batch_size, seq_len, num_heads * head_size).
        input_row_offsets: Tensor with shape (batch_size + 1,).
            The value at each index is the start_idx of the corresponding batch in hidden_state.
        weight: Tensor with shape (num_heads * head_size, num_kv_heads * head_size).
        kv_collection: The object storing the KVCache for this layer.
        layer_idx: The current layer, used to retrieve the KVCache object from kv_collection.
        output: The pre-allocated output buffer for Q projections. K and V
            projections are written in-place to k_cache and v_cache.
        bias: Bias to be added to the QKV Tensor. Tensor is concatenated q + k + v. Rank 1.
        context: The call context pointer, passed by the graph compiler.
    """
    var cuda_ctx: Optional[DeviceContext] = None
    var layer_idx_cast = Int(layer_idx)
    var k_cache = kv_collection.get_key_cache(layer_idx_cast)
    var v_cache = kv_collection.get_value_cache(layer_idx_cast)

    @parameter
    if is_gpu[target]():
        cuda_ctx = context.get_device_context()

    return _fused_qkv_matmul_kv_cache_ragged_impl_bias[
        target=target,
        group_size=group_size,
        has_zp=has_zp,
    ](
        hidden_state,
        input_row_offsets,
        weight,
        k_cache,
        v_cache,
        output,
        bias,
        cuda_ctx,
    )


@always_inline
fn _fused_qkv_matmul_kv_cache_ragged_impl[
    type: DType,
    weight_type: DType,
    cache_t: KVCacheT, //,
    *,
    target: StringLiteral,
    group_size: OptionalReg[Int] = None,
    has_zp: OptionalReg[Bool] = None,
](
    hidden_state: NDBuffer[type, 2, _],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    weight: NDBuffer[weight_type, 2, _],
    k_cache: cache_t,
    v_cache: cache_t,
    output: NDBuffer[type, 2, *_],
    context: Optional[DeviceContext],
) raises:
    """Performs a fused QKV matmul on ragged tensors. Q outputs are written to the output argument
    while K and V outputs are written in-place into k_cache and v_cache.

    Args:
        hidden_state: Tensor with shape (sum(seq_lens), num_heads * head_size).
        input_row_offsets: Tensor with shape (batch_size + 1,)
            denoting the start of each sequence along the seq_len dimension.
        weight: Tensor with shape (num_heads * head_size, (num_heads + 2 * num_kv_heads) * head_size).
        k_cache: The historical KVCacheT for keys, with logical shape:
            (batch_size, max_seq_len, num_kv_heads, head_size).
        v_cache: The historical KVCacheT for values, with logical shape:
            (batch_size, max_seq_len, num_kv_heads, head_size).
        output: The pre-allocated output buffer for Q projections. K and V
            projections are written in-place to k_cache and v_cache.
            Shape is (sum(seq_lens), num_heads * head_size)
        context: The DeviceContext. This is unused if is_cpu[target]().
    """
    alias kv_type = cache_t.type
    alias kv_params = cache_t.kv_params
    alias N = weight.shape.get[0]()
    alias K = weight.shape.get[1]()

    constrained[kv_type == type, "Mismatch in type between Q and KV tensors"]()

    var q_dim = output.dim[1]()
    var k_dim = kv_params.head_size * kv_params.num_heads
    var qk_offset = q_dim + k_dim
    var batch_size = input_row_offsets.dim[0]() - 1

    @parameter
    @__copy_capture(q_dim, qk_offset, batch_size)
    fn write_to_cache[
        type_: DType, width: Int, *, alignment: Int = 1
    ](idx: IndexList[2], val: SIMD[type_, width]):
        if idx[1] < q_dim:
            output.store[width=width, alignment=alignment](
                idx,
                rebind[SIMD[type, width]](val),
            )
            return

        global_token_idx = idx[0]

        var batch_idx: Int = get_batch_from_row_offsets(
            input_row_offsets, global_token_idx
        )

        token_idx = Int(global_token_idx - input_row_offsets[batch_idx])

        var h_idx: UInt
        var hd_idx: UInt
        var cache: cache_t
        var output_val = val
        if idx[1] < qk_offset:
            cache = k_cache
            h_idx, hd_idx = divmod(UInt(idx[1]) - q_dim, kv_params.head_size)
        else:
            cache = v_cache
            h_idx, hd_idx = divmod(
                UInt(idx[1]) - qk_offset, kv_params.head_size
            )

        var cache_length = cache.cache_length(batch_idx)
        var cache_token_idx = token_idx + cache_length
        cache.store(
            batch_idx,
            h_idx,
            cache_token_idx,
            hd_idx,
            rebind[SIMD[kv_type, width]](output_val),
        )

    @parameter
    if group_size:
        constrained[
            not has_zp.value(), "Zero point is not supported for quantization."
        ]()
        constrained[
            weight_type == DType.uint8,
            "Expect GPTQ weights in an uint8 tensor.",
        ]()
        var new_weight = rebind[
            NDBuffer[DType.uint8, weight.rank, weight.shape, weight.strides]
        ](weight)

        _qmatmul_common[
            group_size = group_size.value(),
            target=target,
            elementwise_lambda_fn=write_to_cache,
        ](hidden_state, new_weight, context)

    else:
        constrained[
            weight_type == type,
            "Mismatch in type between weight and QKV tensors",
        ]()
        var new_weight = rebind[
            NDBuffer[type, weight.rank, weight.shape, weight.strides]
        ](weight)

        _matmul_common[target=target, elementwise_lambda_fn=write_to_cache](
            hidden_state, new_weight, context
        )


@always_inline
fn _fused_qkv_matmul_kv_cache_ragged_impl_bias[
    type: DType,
    weight_type: DType,
    cache_t: KVCacheT, //,
    *,
    target: StringLiteral,
    group_size: OptionalReg[Int] = None,
    has_zp: OptionalReg[Bool] = None,
](
    hidden_state: NDBuffer[type, 2, _],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    weight: NDBuffer[weight_type, 2, _],
    k_cache: cache_t,
    v_cache: cache_t,
    output: NDBuffer[type, 2, *_],
    bias: NDBuffer[type, 1],
    context: Optional[DeviceContext],
) raises:
    """Performs a fused QKV matmul on ragged tensors. Q outputs are written to the output argument
    while K and V outputs are written in-place into k_cache and v_cache.

    Args:
        hidden_state: Tensor with shape (sum(seq_lens), num_heads * head_size).
        input_row_offsets: Tensor with shape (batch_size + 1,)
            denoting the start of each sequence along the seq_len dimension.
        weight: Tensor with shape (num_heads * head_size, (num_heads + 2 * num_kv_heads) * head_size).
        k_cache: The historical KVCacheT for keys, with logical shape:
            (batch_size, max_seq_len, num_kv_heads, head_size).
        v_cache: The historical KVCacheT for values, with logical shape:
            (batch_size, max_seq_len, num_kv_heads, head_size).
        output: The pre-allocated output buffer for Q projections. K and V
            projections are written in-place to k_cache and v_cache.
            Shape is (sum(seq_lens), num_heads * head_size)
        bias: Bias to be added to the QKV Tensor. Tensor is concatenated q + k + v. Rank 1.
        context: The DeviceContext. This is unused if is_cpu[target]().
    """
    alias kv_type = cache_t.type
    alias kv_params = cache_t.kv_params
    alias N = weight.shape.get[0]()
    alias K = weight.shape.get[1]()

    constrained[kv_type == type, "Mismatch in type between Q and KV tensors"]()

    var q_dim = output.dim[1]()
    var k_dim = kv_params.head_size * kv_params.num_heads
    var qk_offset = q_dim + k_dim
    var batch_size = input_row_offsets.dim[0]() - 1

    @parameter
    @__copy_capture(q_dim, qk_offset, batch_size)
    fn write_to_cache[
        type_: DType, width: Int, *, alignment: Int = 1
    ](idx: IndexList[2], val: SIMD[type_, width]):
        var output_val = val + rebind[SIMD[type_, width]](
            bias.load[width=width, alignment=alignment](idx[1])
        )
        if idx[1] < q_dim:
            output.store[width=width, alignment=alignment](
                idx,
                rebind[SIMD[type, width]](output_val),
            )
            return

        global_token_idx = idx[0]

        var batch_idx: Int = get_batch_from_row_offsets(
            input_row_offsets, global_token_idx
        )

        token_idx = Int(global_token_idx - input_row_offsets[batch_idx])

        var h_idx: UInt
        var hd_idx: UInt
        var cache: cache_t
        if idx[1] < qk_offset:
            cache = k_cache
            h_idx, hd_idx = divmod(UInt(idx[1]) - q_dim, kv_params.head_size)
        else:
            cache = v_cache
            h_idx, hd_idx = divmod(
                UInt(idx[1]) - qk_offset, kv_params.head_size
            )

        var cache_length = cache.cache_length(batch_idx)
        var cache_token_idx = token_idx + cache_length
        cache.store(
            batch_idx,
            h_idx,
            cache_token_idx,
            hd_idx,
            rebind[SIMD[kv_type, width]](output_val),
        )

    @parameter
    if group_size:
        constrained[
            not has_zp.value(), "Zero point is not supported for quantization."
        ]()
        constrained[
            weight_type == DType.uint8,
            "Expect GPTQ weights to be a 'uint8' tensor.",
        ]()
        var new_weight = rebind[
            NDBuffer[DType.uint8, weight.rank, weight.shape, weight.strides]
        ](weight)

        _qmatmul_common[
            group_size = group_size.value(),
            target=target,
            elementwise_lambda_fn=write_to_cache,
        ](hidden_state, new_weight, context)

    else:
        constrained[
            weight_type == type,
            "Mismatch in type between weight and QKV tensors",
        ]()
        var new_weight = rebind[
            NDBuffer[type, weight.rank, weight.shape, weight.strides]
        ](weight)

        _matmul_common[target=target, elementwise_lambda_fn=write_to_cache](
            hidden_state, new_weight, context
        )


@always_inline
fn _matmul_common[
    type: DType, //,
    *,
    target: StringLiteral,
    elementwise_lambda_fn: OptionalReg[elementwise_epilogue_type] = None,
](
    hidden_state: NDBuffer[type, 2, _],
    weight: NDBuffer[type, 2, _],
    context: Optional[DeviceContext],
) raises:
    var TOTAL_SEQ_LEN = hidden_state.dim[0]()
    alias N = weight.shape.get[0]()
    alias K = weight.shape.get[1]()
    var c_nd: NDBuffer[type, 2, DimList(Dim(), N)]

    @parameter
    if is_cpu[target]():
        # The CPU matmul codepath uses the C buffer as a workspace
        # even if an epilogue is provided, here we just allocate
        # something to ensure we don't segfault.
        var c_ptr = UnsafePointer[Scalar[type]].alloc(TOTAL_SEQ_LEN * N)

        c_nd = __type_of(c_nd)(
            c_ptr,
            IndexList[2](TOTAL_SEQ_LEN, N),
        )
    else:
        c_nd = __type_of(c_nd)(
            UnsafePointer[Scalar[type]](),
            IndexList[2](TOTAL_SEQ_LEN, N),
        )

    matmul[
        target=target,
        transpose_b=True,
        elementwise_lambda_fn=elementwise_lambda_fn,
    ](c_nd, hidden_state, weight, context)

    @parameter
    if is_cpu[target]():
        c_nd.data.free()


@always_inline
fn _qmatmul_common[
    type: DType, //,
    *,
    group_size: Int,
    target: StringLiteral,
    elementwise_lambda_fn: OptionalReg[elementwise_epilogue_type] = None,
](
    hidden_state: NDBuffer[type, 2, _],
    weight: NDBuffer[DType.uint8, 2, _],
    context: Optional[DeviceContext],
) raises:
    constrained[is_gpu[target](), "GPTQ quantization only works on GPU."]()

    var TOTAL_SEQ_LEN = hidden_state.dim[0]()
    alias N = weight.shape.get[0]()
    var c_nd: NDBuffer[type, 2, DimList(Dim(), N)]

    c_nd = __type_of(c_nd)(
        UnsafePointer[Scalar[type]](),
        IndexList[2](TOTAL_SEQ_LEN, N),
    )

    matmul_gpu_qint4_impl[
        target=target,
        group_size=group_size,
        elementwise_lambda_fn=elementwise_lambda_fn,
    ](c_nd, hidden_state, weight, context)


# ===-----------------------------------------------------------------------===#
# Unfused KV cache matmul (ragged)
# ===-----------------------------------------------------------------------===#


fn kv_matmul_ragged_continuous_batching[
    type: DType, num_heads: Int, head_dim: Int, //, target: StringLiteral
](
    hidden_state: NDBuffer[type, 2, _],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    weight: NDBuffer[type, 2, _],
    kv_collection: ContinuousBatchingKVCacheCollection[
        type,
        KVCacheStaticParams(num_heads=num_heads, head_size=head_dim),
    ],
    layer_idx: UInt32,
    ctx: MojoCallContextPtr,
) raises:
    """Performs a matmul, writing the output into a mutable ContinuousBatchingKVCacheCollection object.

    Args:
        hidden_state: Tensor with shape (sum(seq_lens), num_heads * head_size).
        input_row_offsets: Tensor with shape (batch_size + 1,)
            denoting the start of each sequence along the seq_len dimension.
        weight: Tensor with shape (num_heads * head_size, num_kv_heads * head_size).
        kv_collection: The historical KVCache for keys and values. The KVCache for
            this layer is retrieved via layer_idx.
        layer_idx: The index of the layer being executed. Used to retrieve the KVCache
            for the given layer from kv_collection.
        ctx: The call context pointer, passed by the graph compiler.
    """

    @always_inline
    @parameter
    fn description_fn() -> String:
        return String(
            trace_arg("weight", weight),
            trace_arg("layer_idx", layer_idx),
            trace_arg("num_heads", kv_collection.kv_params.num_heads),
            trace_arg("head_size", kv_collection.kv_params.head_size),
            sep=";",
        )

    with Trace[TraceLevel.OP, target=target](
        String(
            "mo.kv_matmul.ragged.continuous_batching.nhead_",
            kv_collection.kv_params.num_heads,
            ".hdim_",
            kv_collection.kv_params.head_size,
        ),
        Trace[TraceLevel.OP]._get_detail_str[description_fn](),
    ):
        return _matmul_kv_cache_ragged[target=target](
            hidden_state,
            input_row_offsets,
            weight,
            kv_collection,
            layer_idx,
            ctx,
        )


@always_inline
fn _matmul_kv_cache_ragged[
    type: DType, //,
    *,
    target: StringLiteral,
](
    hidden_state: NDBuffer[type, 2, _],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    weight: NDBuffer[type, 2, _],
    kv_collection: ContinuousBatchingKVCacheCollection,
    layer_idx: UInt32,
    context: MojoCallContextPtr,
) raises:
    """Helper for performing matmul with custom ContinuousBatchingKVCacheCollection types.

    Args:
        hidden_state: Tensor with shape (sum(seq_lens), num_heads * head_size).
        input_row_offsets: Tensor with shape (batch_size + 1,)
            denoting the start of each sequence along the seq_len dimension.
        weight: Tensor with shape (num_heads * head_size, 2 * num_kv_heads * head_size)
        kv_collection: The historical KVCache for keys and values. The KVCache for
            this layer is retrieved via layer_idx.
        layer_idx: The index of the layer being executed. Used to retrieve the KVCache
            for the given layer from kv_collection.
        context: Pointer containing the runtime context for the target device.
    """
    var cuda_ctx: Optional[DeviceContext] = None
    layer_idx_cast = Int(layer_idx)
    k_cache = kv_collection.get_key_cache(layer_idx_cast)
    v_cache = kv_collection.get_value_cache(layer_idx_cast)

    @parameter
    if is_gpu[target]():
        cuda_ctx = context.get_device_context()

    _matmul_kv_cache_ragged_impl[target=target](
        hidden_state,
        input_row_offsets,
        weight,
        k_cache,
        v_cache,
        cuda_ctx,
    )


@always_inline
fn _matmul_kv_cache_ragged_impl[
    type: DType,
    cache_t: KVCacheT, //,
    *,
    target: StringLiteral,
](
    hidden_state: NDBuffer[type, 2, _],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    weight: NDBuffer[type, 2, _],
    k_cache: cache_t,
    v_cache: cache_t,
    ctx: Optional[DeviceContext],
) raises:
    """Helper for performing matmul with custom KVCacheT types.

    Args:
        hidden_state: Tensor with shape (sum(seq_lens), num_heads * head_size).
        input_row_offsets: Tensor with shape (batch_size + 1,)
            denoting the start of each sequence along the seq_len dimension.
        weight: Tensor with shape (num_heads * head_size, 2 * num_kv_heads * head_size)
        k_cache: The historical KVCacheT for keys, with logical shape:
            (batch_size, max_seq_len, num_kv_heads, head_size).
        v_cache: The historical KVCacheT for values, with logical shape:
            (batch_size, max_seq_len, num_kv_heads, head_size).
        ctx: Pointer containing the runtime context for the target device.
    """
    if hidden_state.num_elements() == 0:
        # Nothing to do.
        return

    alias kv_params = cache_t.kv_params
    alias N: UInt = weight.shape.get[0]()
    alias K: UInt = weight.shape.get[1]()

    batch_size = input_row_offsets.dim[0]() - 1

    # Set the matmul_common output lambda to write to K cache for the first N
    # elements and V cache for the next N.
    k_offset = kv_params.head_size * kv_params.num_heads

    @parameter
    @__copy_capture(input_row_offsets, k_offset, batch_size)
    @always_inline
    fn write_to_cache_common[
        type_: DType, cache_t: KVCacheT, width: Int
    ](
        k_cache: cache_t,
        v_cache: cache_t,
        idx: IndexList[2],
        val: SIMD[type_, width],
    ):
        alias kv_type = cache_t.type

        constrained[
            kv_type == type_,
            "Mismatch in type between hidden state and KV tensors",
        ]()

        # Token index in the "ragged" combined sequence dimension.
        global_token_idx = idx[0]

        batch_idx = get_batch_from_row_offsets(
            input_row_offsets, global_token_idx
        )
        token_idx = Int(global_token_idx - input_row_offsets[batch_idx])

        if idx[1] < k_offset:
            # Write this element to the K cache.
            cache = k_cache
            h_idx, hd_idx = divmod(UInt(idx[1]), kv_params.head_size)
        else:
            # Otherwise, write this element to the V cache.
            cache = v_cache
            h_idx, hd_idx = divmod(UInt(idx[1]) - k_offset, kv_params.head_size)

        cache_length = cache.cache_length(batch_idx)
        cache_token_idx = token_idx + cache_length
        cache.store(
            batch_idx,
            h_idx,
            cache_token_idx,
            hd_idx,
            rebind[SIMD[kv_type, width]](val),
        )

    # Cast to a register passable type so the function closure works on GPU.
    k_cache_reg = rebind[ContinuousBatchingKVCache[type, kv_params]](k_cache)
    v_cache_reg = rebind[ContinuousBatchingKVCache[type, kv_params]](v_cache)

    @parameter
    @__copy_capture(k_cache_reg, v_cache_reg)
    fn write_to_cache_continuous[
        type_: DType, width: Int, *, alignment: Int = 1
    ](idx: IndexList[2], val: SIMD[type_, width]):
        write_to_cache_common(k_cache_reg, v_cache_reg, idx, val)

    _matmul_common[
        target=target, elementwise_lambda_fn=write_to_cache_continuous
    ](hidden_state, weight, ctx)


# ===-----------------------------------------------------------------------===#
# Fused QK RoPE (ragged)
# ===-----------------------------------------------------------------------===#


@always_inline
fn generic_fused_qk_rope_bshd_continous_batch_ragged[
    type: DType, //,
    *,
    interleaved: Bool,
    target: StringLiteral,
](
    q_proj: NDBuffer[type, 3, *_],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    kv_collection: ContinuousBatchingKVCacheCollection,
    freqs_cis: NDBuffer[type, 2, *_],
    layer_idx: UInt32,
    output: NDBuffer[type, 3, *_],
    context: MojoCallContextPtr,
):
    @always_inline
    @parameter
    fn description_fn() -> String:
        return String(
            trace_arg("output", output),
            trace_arg("q_proj", q_proj),
            trace_arg("freqs_cis", freqs_cis),
            trace_arg("layer_idx", layer_idx),
            trace_arg("num_heads", kv_collection.kv_params.num_heads),
            trace_arg("head_size", kv_collection.kv_params.head_size),
            trace_arg("interleaved", interleaved),
            sep=";",
        )

    # Pass device context only on GPU.
    var dev_ctx = Optional[DeviceContext]() if is_cpu[
        target
    ]() else context.get_device_context()

    with Trace[TraceLevel.OP, target=target](
        String(
            "mo.fused_qk_rope.ragged.continuous_batching.nhead_",
            kv_collection.kv_params.num_heads,
            ".hdim_",
            kv_collection.kv_params.head_size,
        ),
        Trace[TraceLevel.OP]._get_detail_str[description_fn](),
    ):
        fused_qk_rope_ragged[
            kv_collection.CacheType, interleaved=interleaved, target=target
        ](
            q_proj,
            input_row_offsets,
            kv_collection,
            freqs_cis,
            layer_idx,
            output,
            dev_ctx,
        )


@always_inline
fn generic_fused_qk_rope_bshd_paged_ragged[
    type: DType, //,
    *,
    interleaved: Bool,
    target: StringLiteral,
](
    q_proj: NDBuffer[type, 3, *_],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    kv_collection: PagedKVCacheCollection,
    freqs_cis: NDBuffer[type, 2, *_],
    layer_idx: UInt32,
    output: NDBuffer[type, 3, *_],
    context: MojoCallContextPtr = MojoCallContextPtr(),
):
    """Performs a fused RoPE projection for Q and K projections.

    We have a manually fused QKV projection with mo.opaque types in our Llama model.
    Due to a limitation in custom op definitions, we can't declare both a tensor
    and opaque type as output from a custom kernel. This requires us to only note
    Q_proj as an output from the QKV projection. If we immediately follow the
    QKV proj kernel with a RoPE kernel applied to K, we'll get a race condition
    because the graph compiler doesn't know about the dependency between these
    kernels in the graph definition. Here we fuse the RoPE kernel applied to
    Q_proj with K_proj, so K_proj RoPE is only executed after QKV completes.
    """

    @always_inline
    @parameter
    fn description_fn() -> String:
        return String(
            trace_arg("output", output),
            trace_arg("q_proj", q_proj),
            trace_arg("freqs_cis", freqs_cis),
            trace_arg("layer_idx", layer_idx),
            trace_arg("num_heads", kv_collection.kv_params.num_heads),
            trace_arg("head_size", kv_collection.kv_params.head_size),
            trace_arg("interleaved", interleaved),
            sep=";",
        )

    # Pass device context only on GPU.
    var dev_ctx = Optional[DeviceContext]() if is_cpu[
        target
    ]() else context.get_device_context()

    alias name = String(
        "mo.fused_qk_rope.ragged.paged.nhead_",
        kv_collection.kv_params.num_heads,
        ".hdim_",
        kv_collection.kv_params.head_size,
    )
    with Trace[TraceLevel.OP, target=target](
        name,
        Trace[TraceLevel.OP]._get_detail_str[description_fn](),
    ):
        fused_qk_rope_ragged[
            kv_collection.CacheType, interleaved=interleaved, target=target
        ](
            q_proj,
            input_row_offsets,
            kv_collection,
            freqs_cis,
            layer_idx,
            output,
            dev_ctx,
        )


# ===-----------------------------------------------------------------------===#
# MHA (ragged)
# ===-----------------------------------------------------------------------===#


@always_inline
fn generic_flash_attention_kv_cache_causal_mask_paged_ragged[
    target: StringLiteral, type: DType
](
    q: NDBuffer[type, 3, *_],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    kv_collection: PagedKVCacheCollection,
    layer_idx: UInt32,
    scale: Float32,
    output: NDBuffer[type, 3, *_],
    context: MojoCallContextPtr,
) raises:
    @always_inline
    @parameter
    fn description_fn() -> String:
        return String(
            trace_arg("q", q),
            trace_arg("scale", scale),
            trace_arg("layer_idx", layer_idx),
            trace_arg("num_heads", kv_collection.kv_params.num_heads),
            trace_arg("head_size", kv_collection.kv_params.head_size),
            sep=";",
        )

    alias name = String(
        "mo.mha.ragged.paged.causal_mask.no_pos.nhead_",
        kv_collection.kv_params.num_heads,
        ".hdim_",
        kv_collection.kv_params.head_size,
    )

    with Trace[TraceLevel.OP, target=target](
        name,
        Trace[TraceLevel.OP]._get_detail_str[description_fn](),
    ):
        return _flash_attention_kv_cache_ragged[
            kv_collection.CacheType, target=target
        ](
            q,
            input_row_offsets,
            kv_collection,
            layer_idx,
            CausalMask(),
            scale,
            output,
            context,
        )


@always_inline
fn generic_flash_attention_kv_cache_causal_mask_cont_batch_ragged[
    type: DType, //,
    target: StringLiteral,
](
    q: NDBuffer[type, 3, *_],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    kv_collection: ContinuousBatchingKVCacheCollection,
    layer_idx: UInt32,
    scale: Float32,
    output: NDBuffer[type, 3, *_],
    context: MojoCallContextPtr,
) raises:
    @always_inline
    @parameter
    fn description_fn() -> String:
        return String(
            trace_arg("output", output),
            trace_arg("q", q),
            trace_arg("input_row_offsets", input_row_offsets),
            trace_arg("layer_idx", layer_idx),
            trace_arg("num_heads", kv_collection.kv_params.num_heads),
            trace_arg("head_size", kv_collection.kv_params.head_size),
            sep=";",
        )

    with Trace[TraceLevel.OP, target=target](
        String(
            "mo.mha.ragged.continuous_batching.causal_mask.no_pos.nhead_",
            kv_collection.kv_params.num_heads,
            ".hdim_",
            kv_collection.kv_params.head_size,
        ),
        Trace[TraceLevel.OP]._get_detail_str[description_fn](),
    ):
        return _flash_attention_kv_cache_ragged[
            kv_collection.CacheType, target=target
        ](
            q,
            input_row_offsets,
            kv_collection,
            layer_idx,
            CausalMask(),
            scale,
            output,
            context,
        )


@always_inline
fn generic_flash_attention_kv_cache_alibi_mask_cont_batch_ragged[
    type: DType, //,
    target: StringLiteral,
](
    q: NDBuffer[type, 3, *_],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    kv_collection: ContinuousBatchingKVCacheCollection,
    layer_idx: UInt32,
    scale: Float32,
    output: NDBuffer[type, 3, *_],
    context: MojoCallContextPtr,
) raises:
    @always_inline
    @parameter
    fn description_fn() -> String:
        return String(
            trace_arg("output", output),
            trace_arg("q", q),
            trace_arg("input_row_offsets", input_row_offsets),
            trace_arg("layer_idx", layer_idx),
            trace_arg("num_heads", kv_collection.kv_params.num_heads),
            trace_arg("head_size", kv_collection.kv_params.head_size),
            sep=";",
        )

    with Trace[TraceLevel.OP, target=target](
        String(
            "mo.mha.ragged.continuous_batching.causal_mask.alibi_pos.nhead_",
            kv_collection.kv_params.num_heads,
            ".hdim_",
            kv_collection.kv_params.head_size,
        ),
        Trace[TraceLevel.OP]._get_detail_str[description_fn](),
    ):
        return _flash_attention_kv_cache_alibi_mask_ragged[
            kv_collection.CacheType, target=target
        ](
            q,
            input_row_offsets,
            kv_collection,
            layer_idx,
            scale,
            output,
            context,
        )


@always_inline
fn generic_flash_attention_kv_cache_null_mask_cont_batch_ragged[
    type: DType, //, target: StringLiteral
](
    q: NDBuffer[type, 3, *_],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    kv_collection: ContinuousBatchingKVCacheCollection,
    layer_idx: UInt32,
    scale: Float32,
    output: NDBuffer[type, 3, *_],
    context: MojoCallContextPtr,
) raises:
    @always_inline
    @parameter
    fn description_fn() -> String:
        return String(
            trace_arg("output", output),
            trace_arg("q", q),
            trace_arg("input_row_offsets", input_row_offsets),
            trace_arg("layer_idx", layer_idx),
            trace_arg("num_heads", kv_collection.kv_params.num_heads),
            trace_arg("head_size", kv_collection.kv_params.head_size),
            sep=";",
        )

    with Trace[TraceLevel.OP, target=target](
        String(
            "mo.mha.ragged.continuous_batching.null_mask.no_pos.nhead_",
            kv_collection.kv_params.num_heads,
            ".hdim_",
            kv_collection.kv_params.head_size,
        ),
        Trace[TraceLevel.OP]._get_detail_str[description_fn](),
    ):
        return _flash_attention_kv_cache_ragged[
            kv_collection.CacheType, target=target
        ](
            q,
            input_row_offsets,
            kv_collection,
            layer_idx,
            NullMask(),
            scale,
            output,
            context,
        )


@always_inline
fn _flash_attention_kv_cache_ragged[
    type: DType,
    collection_t: KVCollectionT,
    mask_t: MHAMask, //,
    cache_t: KVCacheT,
    target: StringLiteral,
](
    q: NDBuffer[type, 3, *_],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    kv_collection: collection_t,
    layer_idx: UInt32,
    mask: mask_t,
    scale: Float32,
    output: NDBuffer[type, 3, *_],
    context: MojoCallContextPtr,
) raises:
    """Performs flash attention using k and v caches from KVCacheT custom types.

    Args:
        q: NDBuffer with shape (batch_size, num_heads, seq_len, head_size).
        input_row_offsets: The start and end position of each Q entry in the batch.
        kv_collection: The Collection object storing out KVCache entries for this layer
        layer_idx: The current layer, used to retrieve kv_cache objects from kv_colleciton
        mask: Mask functor that computes a masked score vector and tile status from coords.
        scale: The scaled factor in scaled-dot product attention. Usually isqrt(head_size).
        output: The Pre-allocated output buffer to write results to. Has shape:
            (batch_size, num_heads, seq_len, head_size).
        context: Pointer containing the runtime context for the target device.
    """
    var cuda_ctx: Optional[DeviceContext] = None

    @parameter
    if is_gpu[target]():
        cuda_ctx = context.get_device_context()

    _flash_attention_kv_cache_ragged_impl[cache_t, target=target](
        q,
        input_row_offsets,
        kv_collection,
        layer_idx,
        mask,
        scale,
        output,
        cuda_ctx,
    )


@always_inline
fn _flash_attention_kv_cache_alibi_mask_ragged[
    type: DType,
    collection_t: KVCollectionT, //,
    cache_t: KVCacheT,
    target: StringLiteral,
](
    q: NDBuffer[type, 3, *_],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    kv_collection: collection_t,
    layer_idx: UInt32,
    scale: Float32,
    output: NDBuffer[type, 3, *_],
    context: MojoCallContextPtr,
) raises:
    """Performs flash attention using k and v caches from KVCacheT custom types.

    Args:
        q: NDBuffer with shape (batch_size, num_heads, seq_len, head_size).
        input_row_offsets: The start and end position of each entry in the batch.
        kv_collection: The Collection object storing out KVCache entries for this layer
        layer_idx: The current layer, used to retrieve kv_cache objects from kv_colleciton
        scale: The scaled factor in scaled-dot product attention. Usually isqrt(head_size).
        output: The Pre-allocated output buffer to write results to. Has shape:
            (batch_size, num_heads, seq_len, head_size).
        context: Pointer containing the runtime context for the target device.
    """
    var cuda_ctx: Optional[DeviceContext] = None

    @parameter
    if is_gpu[target]():
        cuda_ctx = context.get_device_context()

    _flash_attention_kv_cache_alibi_mask_ragged_impl[cache_t, target=target](
        q,
        input_row_offsets,
        kv_collection,
        layer_idx,
        scale,
        output,
        cuda_ctx,
    )


@always_inline
fn _flash_attention_kv_cache_ragged_impl[
    type: DType,
    collection_t: KVCollectionT,
    mask_t: MHAMask, //,
    cache_t: KVCacheT,
    target: StringLiteral,
](
    q: NDBuffer[type, 3, *_],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    kv_collection: collection_t,
    layer_idx: UInt32,
    mask: mask_t,
    scale: Float32,
    output: NDBuffer[type, 3, *_],
    context: Optional[DeviceContext],
) raises:
    """Performs flash attention using k and v caches from KVCacheT custom types.

    Args:
        q: NDBuffer with shape (sum(seq_lens in batch), num_heads, head_size).
        input_row_offsets: The start and end position of each Q entry in the batch.
        kv_collection: The Collection object storing out KVCache entries for this layer
        layer_idx: The current layer, used to retrieve kv_cache objects from kv_colleciton
        mask: Mask functor that computes a masked score vector and tile status from coords.
        scale: The scaled factor in scaled-dot product attention. Usually isqrt(head_size).
        output: The Pre-allocated output buffer to write results to. Has shape:
            (sum(seq_lens in batch), num_heads, head_size).
        context: CUDA DeviceContext. This is not used if is_cpu[target]()
    """

    var layer_idx_cast = Int(layer_idx)
    var k = kv_collection.get_key_cache(layer_idx_cast)
    var v = kv_collection.get_value_cache(layer_idx_cast)

    @parameter
    if is_cpu[target]():
        return flash_attention_kv_cache_cpu(
            q, input_row_offsets, input_row_offsets, k, v, mask, scale, output
        )
    else:
        return _flash_attention_kv_cache_ragged_gpu[target=target](
            q, input_row_offsets, k, v, mask, scale, output, context.value()
        )


@always_inline
fn _flash_attention_kv_cache_alibi_mask_ragged_impl[
    type: DType,
    collection_t: KVCollectionT, //,
    cache_t: KVCacheT,
    target: StringLiteral,
](
    q: NDBuffer[type, 3, *_],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    kv_collection: collection_t,
    layer_idx: UInt32,
    scale: Float32,
    output: NDBuffer[type, 3, *_],
    context: Optional[DeviceContext],
) raises:
    """Performs flash attention using k and v caches from KVCacheT custom types.

    Args:
        q: NDBuffer with shape (sum(seq_lens in batch), num_heads, head_size).
        input_row_offsets: The start and end position of each entry in the batch.
        kv_collection: The Collection object storing out KVCache entries for this layer
        layer_idx: The current layer, used to retrieve kv_cache objects from kv_colleciton
        scale: The scaled factor in scaled-dot product attention. Usually isqrt(head_size).
        output: The Pre-allocated output buffer to write results to. Has shape:
            (sum(seq_lens in batch), num_heads, head_size).
        context: CUDA DeviceContext. This is not used if is_cpu[target]()
    """

    var layer_idx_cast = Int(layer_idx)
    var k = kv_collection.get_key_cache(layer_idx_cast)
    var v = kv_collection.get_value_cache(layer_idx_cast)

    @parameter
    if is_cpu[target]():
        # TODO: I dont think this is set up yet.
        return flash_attention_kv_cache_cpu(
            q,
            input_row_offsets,
            # Assume self attention: Q and KV sequence lengths are equal.
            input_row_offsets,
            k,
            v,
            CausalMask(),
            scale,
            output,
        )
    else:
        return _flash_attention_kv_cache_alibi_mask_ragged_gpu[target=target](
            q, input_row_offsets, k, v, scale, output, context.value()
        )


@always_inline
fn _flash_attention_kv_cache_ragged_gpu[
    type: DType,
    cache_t: KVCacheT,
    mask_t: MHAMask, //,
    *,
    target: StringLiteral,
](
    q: NDBuffer[type, 3, *_],
    input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    k: cache_t,
    v: cache_t,
    mask: mask_t,
    scale: Float32,
    output: NDBuffer[type, 3, *_],
    context: DeviceContext,
) raises:
    var dummy_mask = NDBuffer[
        type,
        4,
        DimList.create_unknown[4](),
    ]()

    gpu_flash_attention[add_attn_mask=False, ragged=True](
        output,
        q,
        k,
        v,
        dummy_mask,
        mask,
        IdentityScoreMod(),
        input_row_offsets,
        scale,
        context,
    )


@always_inline
fn _flash_attention_kv_cache_alibi_mask_ragged_gpu[
    type: DType, cache_t: KVCacheT, //, *, target: StringLiteral
](
    q: NDBuffer[type, 3, *_],
    input_row_offsets: NDBuffer[DType.uint32, 1],
    k: cache_t,
    v: cache_t,
    scale: Float32,
    output: NDBuffer[type, 3, *_],
    context: DeviceContext,
) raises:
    var dummy_mask = NDBuffer[
        type,
        4,
        DimList.create_unknown[4](),
    ]()

    # This assumes that, the q tensor is static in the 1 dim.
    alias num_q_heads = Int(q.shape.at[1]())

    gpu_flash_attention[add_attn_mask=False, use_score_mod=True, ragged=True](
        output,
        q,
        k,
        v,
        dummy_mask,
        CausalMask(),
        AlibiScoreMod[num_q_heads](),
        input_row_offsets,
        scale,
        context,
    )


# ===-----------------------------------------------------------------------===#
# Cross attention (ragged)
# ===-----------------------------------------------------------------------===#


@always_inline
fn _cross_attention_kv_cache_ragged[
    type: DType,
    collection_t: KVCollectionT,
    mask_t: MHAMask, //,
    cache_t: KVCacheT,
    target: StringLiteral,
](
    q: NDBuffer[type, 3, *_],
    q_input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    q_max_seq_len: UInt32,
    kv_input_row_offsets: NDBuffer[DType.uint32, 1],
    kv_collection: collection_t,
    layer_idx: UInt32,
    mask: mask_t,
    scale: Float32,
    output: NDBuffer[type, 3, *_],
    context: MojoCallContextPtr,
) raises:
    """Performs cross attention using k and v caches from KVCacheT custom types.

    Args:
        q: NDBuffer with shape (batch_size, num_heads, seq_len, head_size).
        q_input_row_offsets: The start and end position of each Q entry in the batch.
        q_max_seq_len: Maximum query sequence length.
        kv_input_row_offsets: The start and end position of each KV entry in the batch.
        kv_collection: The Collection object storing out KVCache entries for this layer
        layer_idx: The current layer, used to retrieve kv_cache objects from kv_colleciton
        mask: Mask functor that computes a masked score vector and tile status from coords.
        scale: The scaled factor in scaled-dot product attention. Usually isqrt(head_size).
        output: The Pre-allocated output buffer to write results to. Has shape:
            (batch_size, num_heads, seq_len, head_size).
        context: Pointer containing the runtime context for the target device.
    """
    var layer_idx_cast = Int(layer_idx)
    var k = kv_collection.get_key_cache(layer_idx_cast)
    var v = kv_collection.get_value_cache(layer_idx_cast)

    @parameter
    if is_cpu[target]():
        return flash_attention_kv_cache_cpu(
            q,
            q_input_row_offsets,
            # Use KV offsets for cross attention.
            kv_input_row_offsets,
            k,
            v,
            mask,
            scale,
            output,
        )
    else:
        var dummy_mask = NDBuffer[type, 4, DimList.create_unknown[4]()](
            UnsafePointer[Scalar[type]](), Index(0, 0, 0, 0)
        )
        gpu_flash_attention[add_attn_mask=False, ragged=True](
            output,
            q,
            k,
            v,
            dummy_mask,
            mask,
            IdentityScoreMod(),
            q_input_row_offsets,
            scale,
            context.get_device_context(),
            Int(q_max_seq_len),
            kv_input_row_offsets,
            None,
        )


@always_inline
fn generic_cross_attention_kv_cache_null_mask_cont_batch_ragged[
    type: DType, //, target: StringLiteral
](
    q: NDBuffer[type, 3, *_],
    q_input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    q_max_seq_len: NDBuffer[DType.uint32, 1, *_],
    kv_input_row_offsets: NDBuffer[DType.uint32, 1, *_],
    kv_collection: ContinuousBatchingKVCacheCollection,
    layer_idx: UInt32,
    scale: Float32,
    output: NDBuffer[type, 3, *_],
    context: MojoCallContextPtr,
) raises:
    @always_inline
    @parameter
    fn description_fn() -> String:
        return String(
            trace_arg("output", output),
            trace_arg("q", q),
            trace_arg("q_input_row_offsets", q_input_row_offsets),
            trace_arg("kv_input_row_offsets", kv_input_row_offsets),
            trace_arg("layer_idx", layer_idx),
            trace_arg("num_heads", kv_collection.kv_params.num_heads),
            trace_arg("head_size", kv_collection.kv_params.head_size),
            sep=";",
        )

    with Trace[TraceLevel.OP, target=target](
        String(
            "mo.cross_attention.ragged.continuous_batching.null_mask.no_pos.nhead_",
            kv_collection.kv_params.num_heads,
            ".hdim_",
            kv_collection.kv_params.head_size,
        ),
        Trace[TraceLevel.OP]._get_detail_str[description_fn](),
    ):
        return _cross_attention_kv_cache_ragged[
            kv_collection.CacheType, target=target
        ](
            q,
            q_input_row_offsets,
            q_max_seq_len[0],
            kv_input_row_offsets,
            kv_collection,
            layer_idx,
            NullMask(),
            scale,
            output,
            context,
        )
