# FadedAI image fallback (PC)

The active PC installation adds `POST /api/v2/images/generate` on the existing authenticated FastAPI server. It accepts `{"prompt":"..."}` (1–1000 characters) and returns `image/png`. Errors use the existing JSON envelope: 401 for a bad token, 422 for invalid input, and 503 when ComfyUI or the checkpoint is unavailable. The route calls only PC-local ComfyUI at `127.0.0.1:8188` and uses the installed Stable Diffusion 1.5 checkpoint. It does not transfer a phone LoRA.

The iOS app first tries MediaGenerationKit on the phone. If that call throws an error, it tries this PC route once. There is no automatic retry of the POST. The app saves the returned PNG in its local image history and labels the source as PC.

The active PC source is under `%LOCALAPPDATA%\SweatCaster\app\fadedai-checkpoint-20261107`. The generated wire schema is [openapi-v1-v2.json](openapi-v1-v2.json). The GitHub repository remains the iOS source repository; this document records the new PC contract for the app build.

Video highlights now use a short window around an observed kill: up to 3 seconds before and 7 seconds after, bounded by the available clip. The original source is never trimmed or overwritten. The existing v1 `commentary: false` compatibility extension remains documented in the PC schema.
