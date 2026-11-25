"""Generate synthetic fixtures with the installed official ACE-Step code.

Uses its actual target-padding, chunk-mask, tokenizer patching and context
routing implementations, while replacing expensive learned layers with small
deterministic fakes. Output is research only; no model inference is claimed.
"""
import argparse
from contextlib import nullcontext
import json
from pathlib import Path
import sys
from types import SimpleNamespace

import torch
import transformers.utils


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError("Refusing to overwrite an existing fixture")
    sys.path.insert(0, str(args.engine))
    # Some transformers versions' optional auto-docstrings cannot inspect
    # this locally installed model; this does not alter the tested methods.
    old = transformers.utils.auto_docstring
    transformers.utils.auto_docstring = lambda obj=None, **kw: (lambda value: value) if obj is None else obj
    try:
        from acestep.core.generation.handler.conditioning_target import ConditioningTargetMixin
        from acestep.core.generation.handler.conditioning_masks import ConditioningMaskMixin
        from acestep.core.generation.handler.task_utils import TaskUtilsMixin
        from acestep.models.turbo.modeling_acestep_v15_turbo import AceStepConditionGenerationModel
    finally:
        transformers.utils.auto_docstring = old

    class Target(ConditioningTargetMixin):
        device = torch.device("cpu")
        dtype = torch.float32
        sample_rate = 48000
        def __init__(self, src, silence):
            self.src = src
            self.silence_latent = silence.unsqueeze(0)
        def _ensure_silence_latent_on_device(self): pass
        def _load_model_context(self, name): return nullcontext()
        def is_silence(self, wave): return False
        def _encode_audio_to_latents(self, wave): return self.src.clone()

    class Masks(ConditioningMaskMixin, TaskUtilsMixin):
        device = torch.device("cpu")
        sample_rate = 48000

    class CapturingTokenizer:
        config = SimpleNamespace(pool_window_size=5)
        def tokenizer(self, x): return x, torch.zeros(x.shape[:2], dtype=torch.long)

    class Context:
        def encoder(self, **kwargs): return torch.zeros(1, 1, 1), torch.ones(1, 1)

    class Sampler:
        def __init__(self): self.route = []
        def prepare_condition(self, **kwargs):
            cover = bool(kwargs["is_covers"][0])
            length = kwargs["src_latents"].shape[1]
            marker = torch.full((1, length, 4), float(cover))
            return torch.zeros(1, 1, 1), torch.ones(1, 1), marker
        def prepare_noise(self, context, seed): return torch.zeros(context.shape[0], context.shape[1], 2)
        def decoder(self, **kwargs):
            self.route.append(int(kwargs["context_latents"][0, 0, 0]))
            return torch.zeros_like(kwargs["hidden_states"]), kwargs["past_key_values"]
        def get_x0_from_noise(self, x, velocity, timestep):
            return x - velocity * timestep.reshape(-1, 1, 1)

    # Run the real pinned sampler with a fake decoder/conditioner; this
    # records exactly which steps use cover vs non-cover conditioning.
    traces = {}
    for strength in (0.0, 0.2, 0.5, 0.999, 1.0):
        sampler = Sampler()
        latent = torch.zeros(1, 5, 2)
        AceStepConditionGenerationModel.generate_audio(
            sampler, text_hidden_states=torch.zeros(1, 1, 1), text_attention_mask=torch.ones(1, 1),
            lyric_hidden_states=torch.zeros(1, 1, 1), lyric_attention_mask=torch.ones(1, 1),
            refer_audio_acoustic_hidden_states_packed=torch.zeros(1, 1, 1), refer_audio_order_mask=torch.zeros(1, dtype=torch.long),
            src_latents=latent, chunk_masks=torch.ones_like(latent), is_covers=torch.ones(1, dtype=torch.bool),
            silence_latent=latent, non_cover_text_hidden_states=torch.zeros(1, 1, 1),
            non_cover_text_attention_mask=torch.ones(1, 1), audio_cover_strength=strength,
            dcw_enabled=False, seed=42, infer_steps=8)
        traces[strength] = sampler.route
        assert len(sampler.route) == 8

    fixtures = []
    for frames in (1, 4, 5, 127, 128, 129, 251, 300):
        channels = 2
        src = torch.arange(frames * channels, dtype=torch.float32).reshape(frames, channels) / 10
        silence = torch.arange(256 * channels, dtype=torch.float32).reshape(256, channels) / 1000 + 5
        wave = torch.ones(1, 2, frames * 1920, dtype=torch.float32)
        _, target, latent_mask, target_frames, tiled = Target(src, silence)._prepare_target_latents_and_wavs(
            1, wave, [None])
        token_patches, _, token_mask = AceStepConditionGenerationModel.tokenize(
            CapturingTokenizer(), target, silence.unsqueeze(0), latent_mask)
        token_values = token_patches.reshape(-1).tolist()
        # tokenizer returns the pooled attention mask. The expected unpooled
        # padding is the target mask followed by zeros, used to compute it.
        padded_mask = latent_mask[0].tolist() + [0] * ((5 - target_frames % 5) % 5)
        for mode in ("text2music", "cover", "cover-nofsq"):
            masks, spans, is_cover, source_latents, _ = Masks()._build_chunk_masks_and_src_latents(
                1, target_frames, ["unused"], [None], wave, target, None, None,
                tiled, chunk_mask_modes=["auto"], task_type=mode)
            chunk = masks.unsqueeze(-1).repeat(1, 1, channels)
            hints = torch.arange(target_frames * channels, dtype=torch.float32).reshape(1, target_frames, channels) / 50 + 9
            _, _, ctx = AceStepConditionGenerationModel.prepare_condition(
                Context(), torch.zeros(1, 1, 1), torch.ones(1, 1), torch.zeros(1, 1, 1), torch.ones(1, 1),
                torch.zeros(1, 1, 1), torch.zeros(1, dtype=torch.long), target,
                latent_mask, silence.unsqueeze(0), source_latents, chunk, is_cover,
                precomputed_lm_hints_25Hz=hints)
            instruction = Masks().generate_instruction(mode)
            for strength in (0.0, 0.2, 0.5, 0.999, 1.0):
                route = traces[strength]
                release_after = route.index(0) if 0 in route else None
                fixtures.append({
                    "mode": mode, "sourceFrames": frames, "channels": channels, "steps": 8,
                    "strength": strength, "source": src.reshape(-1).tolist(), "silence": silence.reshape(-1).tolist(),
                    "target": target.reshape(-1).tolist(), "tokenValues": token_values,
                    "tokenMask": padded_mask, "pooledMask": token_mask[0].tolist(),
                    "hints": hints.reshape(-1).tolist(), "context": ctx.reshape(-1).tolist(),
                    "instruction": instruction, "isCover": bool(is_cover[0]),
                    "releaseAfter": release_after,
                })
    args.output.write_text(json.dumps(fixtures, separators=(",", ":")), encoding="utf-8")
    print(f"Generated {len(fixtures)} fixtures from installed ACE-Step handlers")


if __name__ == "__main__":
    main()
