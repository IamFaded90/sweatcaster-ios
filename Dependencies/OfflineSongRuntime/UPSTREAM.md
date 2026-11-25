ACE-Step 1.5 iPhone kernel from https://github.com/yu314-coder/WhisperKit
Revision: aa7039a11ad98d918c4b7817947cc6237da82c4c
MIT, copyright Yu Yao-Hsing 2026; model port credits ACE-Step (MIT).
This consumer application is unrelated to the Argmax speech library of the same name.

Only ACE*, MappedWeights, PromptMetadata and the stage-memory/WAV support were
adopted. No upstream UI, app state, SwiftData, account handling or cleanup code.
The 2B transformer uses four Core ML chunks on CPU/Neural Engine, surrounded
by the MLX planner, conditioning and streaming audio decoder. Weights are
separate downloads from upstream releases acestep-v2, v3 and v4. Approximately
10 GB download / installed; model files are excluded from device backups.
The published flattened Core ML files are fetched directly into their pinned
model-folder paths, without archive extraction. Upstream publishes sizes, not
cryptographic asset hashes; every expected size is checked. Download completion
never loads a model.

FadedAI additions: bounded/resumable downloads to pinned paths; missing-space calculation;
foreground cancellation and serialized generation; prompt enhancement toggle;
Danish/English lyric control; output validation and safe deletion. Malformed
safetensors shapes/offsets and nonfinite WAV samples throw instead of trapping.
Blank lines removed in ACEPipeline.swift to keep every file below 600 lines.
Public PhoneSongEngine/PhoneSongInput names and Xcode package identity retained.

MLX 0.31.4 is pinned: it has the zero-copy rawPointer initializer required by
MappedWeights and its manifest supports the current Swift toolchain. Upstream
pins 0.31.6 (Swift 6.3), so full Apple compilation and numerical/device validation
remain required. Source parsing and dependency resolution are not those tests.
No native music model or native inference was tested on an iPhone here.
The prior unshipped YuE2 experiment was preserved only under ignored build/.
No model weights are bundled. No IPA/build/push has been started.
