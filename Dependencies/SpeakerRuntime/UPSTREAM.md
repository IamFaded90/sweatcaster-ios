# SpeakerRuntime

FluidAudio (MIT) is pinned to e2ea498dafd6db9b3f18f0f644bc35312b3a7679. Swift 6.2 traits
include Diarizer and omit TTS/NemoTextProcessing. No new ASR or TTS model is
selected. FadedAI keeps its existing Danish whisper.cpp checkpoints.

An explicit install loads the offline VBx model set and records file sizes.
Inference sets ModelHub.offlineMode, validates the complete local manifest,
loads models, initializes the manager directly and uses its disk-backed file
API. Corrupt/missing files fail without silently downloading a replacement.
Models are released after each run. Speaker labels are estimates and do not
identify people. Apple compilation, RAM and actual diarization quality remain
device checks; Linux package resolution alone is not those checks.
