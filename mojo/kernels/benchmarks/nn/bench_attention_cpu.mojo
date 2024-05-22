# ===----------------------------------------------------------------------=== #
#
# This file is Modular Inc proprietary.
#
# ===----------------------------------------------------------------------=== #

# RUN: %mojo-no-debug %s -t | FileCheck %s
# CHECK: Benchmark results

from benchmark import *
from buffer import NDBuffer
from buffer.list import Dim, DimList
from nn.flash_attention import flash_attention
from nn.mha import fused_attention
from random import rand
from utils.index import Index


@value
struct AttentionSpec(Stringable):
    var batch_size: Int
    var seq_len: Int
    var kv_seq_len: Int
    var depth_dim: Int

    fn __str__(self) -> String:
        return (
            "batch_size="
            + str(self.batch_size)
            + ",seq_len="
            + str(self.seq_len)
            + ",kv_seq_len="
            + str(self.kv_seq_len)
            + ",depth_dim="
            + str(self.depth_dim)
        )


def bench_attention[
    type: DType, transpose_k: Bool
](inout m: Bench, spec: AttentionSpec):
    var q_shape = Index(spec.batch_size, spec.seq_len, spec.depth_dim)
    var k_shape = Index(
        spec.batch_size, spec.kv_seq_len, spec.depth_dim
    ) if transpose_k else Index(
        spec.batch_size, spec.depth_dim, spec.kv_seq_len
    )
    var v_shape = Index(spec.batch_size, spec.kv_seq_len, spec.depth_dim)
    var mask_shape = Index(spec.batch_size, spec.seq_len, spec.kv_seq_len)
    var output_shape = Index(spec.batch_size, spec.seq_len, spec.depth_dim)

    var q_ptr = DTypePointer[type].alloc(q_shape.flattened_length())
    var k_ptr = DTypePointer[type].alloc(k_shape.flattened_length())
    var v_ptr = DTypePointer[type].alloc(v_shape.flattened_length())
    var mask_ptr = DTypePointer[type].alloc(mask_shape.flattened_length())
    var output_ptr = DTypePointer[type].alloc(output_shape.flattened_length())

    rand(q_ptr, q_shape.flattened_length())
    rand(k_ptr, k_shape.flattened_length())
    rand(v_ptr, v_shape.flattened_length())
    rand(mask_ptr, mask_shape.flattened_length())

    var q = NDBuffer[type, 3](q_ptr, q_shape)
    var k = NDBuffer[type, 3](k_ptr, k_shape)
    var v = NDBuffer[type, 3](v_ptr, v_shape)
    var mask = NDBuffer[type, 3](mask_ptr, mask_shape)
    var output = NDBuffer[type, 3](output_ptr, output_shape)

    @parameter
    @always_inline
    fn input_k_fn[
        simd_width: Int, _rank: Int
    ](idx: StaticIntTuple[_rank]) -> SIMD[type, simd_width]:
        return k.load[width=simd_width](rebind[StaticIntTuple[3]](idx))

    @parameter
    @always_inline
    fn input_v_fn[
        simd_width: Int, _rank: Int
    ](idx: StaticIntTuple[_rank]) -> SIMD[type, simd_width]:
        return v.load[width=simd_width](rebind[StaticIntTuple[3]](idx))

    @parameter
    @always_inline
    fn mask_fn[
        simd_width: Int, _rank: Int
    ](idx: StaticIntTuple[_rank]) -> SIMD[type, simd_width]:
        return mask.load[width=simd_width](rebind[StaticIntTuple[3]](idx))

    alias scale = 0.25

    @always_inline
    @parameter
    fn flash_bench_fn(inout b: Bencher):
        @always_inline
        @parameter
        fn iter_fn[depth_static_dim: Dim]():
            alias output_static_shape = DimList(Dim(), Dim(), depth_static_dim)
            flash_attention[
                type,
                3,
                input_k_fn,
                input_v_fn,
                mask_fn,
                output_static_shape,
                transpose_k=transpose_k,
            ](
                q.make_dims_unknown(),
                k.get_shape(),
                v.get_shape(),
                rebind[NDBuffer[type, 3, output_static_shape]](output),
                scale=scale,
            )

        alias depth_static_dims = VariadicList[Int](40, 64, 80, 128, 160)

        @parameter
        for idx in range(len(depth_static_dims)):
            if depth_static_dims[idx] == spec.depth_dim:
                b.iter[iter_fn[Dim(depth_static_dims[idx])]]()
                return

        # Fallback to dispatch with a dynamic shape.
        b.iter[iter_fn[Dim()]]()

    var input_id = "transpose_k=" + str(transpose_k) + "," + str(spec)

    m.bench_function[flash_bench_fn](BenchId(">flash", input_id))

    @always_inline
    @parameter
    fn fused_bench_fn(inout b: Bencher):
        @always_inline
        @parameter
        fn iter_fn():
            try:
                fused_attention[
                    3,
                    DimList.create_unknown[3](),
                    DimList.create_unknown[3](),
                    DimList.create_unknown[3](),
                    DimList.create_unknown[3](),
                    DimList.create_unknown[3](),
                    type,
                    type,
                    type,
                    type,
                    type,
                    add_attn_mask=True,
                    transpose_k=transpose_k,
                ](output, q, k, v, mask, scale, Float32())
            except e:
                abort(e)

        b.iter[iter_fn]()

    m.bench_function[fused_bench_fn](BenchId(" fused", input_id))


def main():
    alias specs = List[AttentionSpec](
        # bert-base-uncased-seqlen-16.yaml
        AttentionSpec(
            batch_size=12,
            seq_len=16,
            kv_seq_len=16,
            depth_dim=64,
        ),
        # BERT/bert-base-uncased-seqlen-128.yaml
        # GPT-2/gpt2-small-seqlen-128.yaml
        # RoBERTa/roberta-base-hf-onnx.yaml
        AttentionSpec(
            batch_size=12,
            seq_len=128,
            kv_seq_len=128,
            depth_dim=64,
        ),
        # CLIP-ViT/clip-vit-large-patch14-onnx.yaml
        AttentionSpec(
            batch_size=16,
            seq_len=257,
            kv_seq_len=257,
            depth_dim=64,
        ),
        # Llama2/llama2-7B-MS-context-encoding-onnx.yaml
        AttentionSpec(
            batch_size=32,
            seq_len=100,
            kv_seq_len=100,
            depth_dim=128,
        ),
        # Llama2/llama2-7B-MS-token-gen-onnx.yaml
        # Mistral/mistral-7b-hf-onnx-LPTG.yaml
        AttentionSpec(
            batch_size=32,
            seq_len=1,
            kv_seq_len=1025,
            depth_dim=128,
        ),
        # Mistral/mistral-7b-hf-onnx-context-encoding-onnx.yaml
        AttentionSpec(
            batch_size=32,
            seq_len=1024,
            kv_seq_len=1024,
            depth_dim=128,
        ),
        # OpenCLIP/clip-dynamic-per-tensor-weight-type-quint8-onnx-optimized.yaml
        AttentionSpec(
            batch_size=12,
            seq_len=50,
            kv_seq_len=50,
            depth_dim=64,
        ),
        AttentionSpec(
            batch_size=24,
            seq_len=77,
            kv_seq_len=77,
            depth_dim=64,
        ),
        # ReplitV1.5/replitv15-3B-hf-context-encoding-onnx.yaml
        AttentionSpec(
            batch_size=24,
            seq_len=1024,
            kv_seq_len=1024,
            depth_dim=128,
        ),
        # ReplitV1.5/replitv15-3B-hf-LPTG-onnx.yaml
        AttentionSpec(
            batch_size=24,
            seq_len=1,
            kv_seq_len=1025,
            depth_dim=128,
        ),
        # StableDiffusion-1.x/text_encoder/text_encoder-onnx.yaml
        AttentionSpec(
            batch_size=24,
            seq_len=16,
            kv_seq_len=16,
            depth_dim=64,
        ),
        # StableDiffusion-1.x/unet/unet-onnx.yaml
        AttentionSpec(
            batch_size=16,
            seq_len=64,
            kv_seq_len=16,
            depth_dim=160,
        ),
        AttentionSpec(
            batch_size=16,
            seq_len=64,
            kv_seq_len=64,
            depth_dim=160,
        ),
        AttentionSpec(
            batch_size=16,
            seq_len=256,
            kv_seq_len=16,
            depth_dim=160,
        ),
        AttentionSpec(
            batch_size=16,
            seq_len=256,
            kv_seq_len=256,
            depth_dim=160,
        ),
        AttentionSpec(
            batch_size=16,
            seq_len=1024,
            kv_seq_len=16,
            depth_dim=80,
        ),
        AttentionSpec(
            batch_size=16,
            seq_len=1024,
            kv_seq_len=1024,
            depth_dim=80,
        ),
        AttentionSpec(
            batch_size=16,
            seq_len=4096,
            kv_seq_len=16,
            depth_dim=40,
        ),
        AttentionSpec(
            batch_size=16,
            seq_len=4096,
            kv_seq_len=4096,
            depth_dim=40,
        ),
        # StableDiffusion-1.x/vae_decoder/vae_decoder-onnx.yaml
        # StableDiffusion-1.x/vae_encoder/vae_encoder-onnx.yaml
        AttentionSpec(
            batch_size=2,
            seq_len=4096,
            kv_seq_len=4096,
            depth_dim=512,
        ),
        # StarCoder/starcoder-7b-hf-context-encoding-onnx.yaml
        AttentionSpec(
            batch_size=1,
            seq_len=32768,
            kv_seq_len=1024,
            depth_dim=128,
        ),
        # StarCoder/starcoder-7b-hf-token-gen-onnx.yaml
        AttentionSpec(
            batch_size=12,
            seq_len=16,
            kv_seq_len=16,
            depth_dim=64,
        ),
        # WavLM/wavlm-large-onnx.yaml
        AttentionSpec(
            batch_size=32,
            seq_len=49,
            kv_seq_len=49,
            depth_dim=64,
        ),
        # Whisper/decoder_model_merged/decoder_model_merged-onnx.yaml
        AttentionSpec(
            batch_size=16,
            seq_len=1,
            kv_seq_len=16,
            depth_dim=64,
        ),
        # Whisper/encoder_model/encoder_model-onnx.yaml
        AttentionSpec(
            batch_size=8,
            seq_len=1500,
            kv_seq_len=1500,
            depth_dim=64,
        ),
    )

    var m = Bench()
    for i in range(len(specs)):
        bench_attention[DType.float32, transpose_k=False](m, specs[i])
        bench_attention[DType.float32, transpose_k=True](m, specs[i])
    m.dump_report()
