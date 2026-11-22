"""Isolated Røst inference process; model and dependencies are installed separately."""

import json
import os
from pathlib import Path
import re
import sys

if len(sys.argv) > 1:
    os.environ.setdefault("HF_HOME", str(Path(sys.argv[1]).resolve().parent / "roest-cache"))
os.environ.setdefault("HF_HUB_OFFLINE", "1")

import torch
import torchaudio
from chatterbox.mtl_tts import ChatterboxMultilingualTTS
from chatterbox.models.tokenizers.tokenizer import ChineseCangjieConverter


def main():
    model_dir, output, speaker = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
    if speaker not in {"mic", "nic", "lumi", "synthetic"}:
        raise ValueError("Unknown speaker")
    text = json.load(sys.stdin)["text"]
    sample_dir = model_dir / "audio_samples"
    if speaker == "synthetic":
        reference = Path(sys.argv[4])
    elif speaker == "lumi":
        reference = sample_dir / "00_lumi_00_reference.wav"
        if not reference.is_file():
            raise FileNotFoundError("Missing Lumi voice example")
    else:
        examples = list(sample_dir.glob(f"00_{speaker}_00_*.wav"))
        if len(examples) != 1:
            raise FileNotFoundError("Missing voice example")
        reference = examples[0]
    # This worker only generates Danish. Chatterbox otherwise initializes a Chinese
    # segmenter and downloads its model even when Chinese is never used.
    ChineseCangjieConverter._load_cangjie_mapping = lambda self, model_dir=None: None
    ChineseCangjieConverter._init_segmenter = lambda self: None
    device = "cuda" if torch.cuda.is_available() else "cpu"
    model = ChatterboxMultilingualTTS.from_local(model_dir, device=device)
    chunks = []
    for sentence in re.split(r"(?<=[.!?])\s+", text):
        remaining = sentence.strip()
        while len(remaining) > 180:
            split = remaining.rfind(" ", 0, 181)
            split = split if split > 0 else 180
            chunks.append(remaining[:split])
            remaining = remaining[split:].strip()
        if remaining:
            chunks.append(remaining)
    parts = []
    for chunk in chunks:
        parts.append(model.generate(chunk, language_id="da", audio_prompt_path=str(reference)).cpu())
    if not parts:
        raise ValueError("Empty text")
    torchaudio.save(str(output), torch.cat(parts, dim=-1).clamp(-1, 1), model.sr,
                    encoding="PCM_S", bits_per_sample=16)


if __name__ == "__main__":
    main()
