# Lumi private studio

## Video repair, 20 November 2026

The uploaded failing `Lumi.mp4` contained 17 frames at 12 fps (1.42 seconds).
Its first frame resembled the reference, then the result collapsed into coloured
noise. The revised pipeline emits 129 generated frames at 16 fps (8.06 seconds),
keeps the reference aspect ratio at a maximum 512-pixel side, and uses the
reference throughout Wan VACE conditioning. Unknown control frames are neutral
grey, generation masks are separate, and the VACE reference prefix is removed
before decoding. This follows the reference/trim connections in the
[official ComfyUI VACE workflow](https://github.com/Comfy-Org/workflow_templates/blob/main/templates/video_wan_vace_14B_ref2v.json).

A real, neutral workshop reference completed through `lumi_companion.video`,
including MP4 conversion, in 522.8 seconds on the RTX 3070. The exported clip is
512x384, 129 frames, 16 fps. Full FFmpeg decoding and start/middle/end playback
checks passed, and sampled images preserved the workshop. This does not prove
photorealistic human likeness or complex actions. No higher-capacity model was
installed. The active PC server has the revised pipeline and frame-rate-aware
export check. The focused backend suite passed 35 tests.

A second, 33-frame neutral motion test used the clothed first frame of the
uploaded video. It completed in 72.3 seconds, passed playback checks, and kept
the original subject and clothes visible in the start/middle/end samples.
Eight-second human motion and physical iPhone playback remain user checks.

The companion iOS change keeps the private foreground session active while its
video is rendering and explains the eight-second duration. That code requires
an updated IPA. The existing background expiry remains unchanged.

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
open phone request. The phone remembers an unfinished video job across app restarts
and offers a share sheet to save an image or video to Photos or Files. Render
results remain in PC memory until the next video job or PC restart; a PC restart
while a video is rendering means the job must be started again.

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
