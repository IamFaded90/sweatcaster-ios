# Lumi private studio

Lumi is an optional 18+ village bot with stable ID `ecba4ff7-69b2-5a9c-a028-d93ef6ec7983`.
Her own iPhone screen has chat, image, and video tabs. No general model picker entry points
at her text, image, or video model. All three PC routes require the existing pairing token
and reject every other bot ID. The PC owner can still reach local Ollama and ComfyUI
directly; this boundary is within FadedAI, not an operating-system access control.

PC models:

* Chat: `hf.co/bartowski/Lumimaid-v0.2-12B-GGUF:Q4_K_M` in Ollama.
* Image: `RealVisXL_V5.0_fp16.safetensors` in ComfyUI checkpoints. Big Love's
  publisher download required login during setup, so this free SDXL checkpoint is
  the tested default. The installer verifies the publisher SHA-256.
* Video: Comfy-Org Wan 2.1 T2V 1.3B with its UMT5 encoder and Wan VAE. The
  proposed Wan 2.2 1.3B name is not an available model; Wan 2.1 1.3B is a
  smaller, working fit for the RTX 3070. The installer verifies all three hashes.

All routes proxy through the paired FadedAI PC server. Ollama and ComfyUI stay on
localhost. Images are returned as PNG; short WebM renders are converted to MP4
with the locally installed FFmpeg before the phone fetches them. Video jobs run
on the PC after the phone starts them, so rendering does not depend on a long
open phone request. Render results live in PC memory until the next video job or
PC restart; durable gallery storage is a separate feature.

Installation and verification:

1. Install the three models with `ollama pull` and the two `backend/install_lumi_*.py`
   downloaders, pointed at the existing ComfyUI models folders.
2. Run `python backend/install_lumi_pc.py <PC checkpoint> --apply`, then restart
   the FadedAI PC server so it imports the new route.
3. Run `backend/test_lumi_companion.py` with the PC checkpoint and its virtual
   environment on `PYTHONPATH`.
4. Build the iOS branch on a Mac and test all three tabs on the paired iPhone.

Local PC smoke tests on 15 November 2026: malformed English chat answered in
English; RealVisXL returned a valid 993,144-byte PNG; Wan returned a valid MP4
after a short 512×288 render. These do not replace the iPhone build and UI test.
