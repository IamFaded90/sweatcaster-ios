# Experimental ACE-Step iPhone audio reference

The separate `PhoneSongReferenceModels` preparer now lives in
`Dependencies/OfflineSongRuntime/Sources/OfflineSongRuntime`. It downloads and
verifies optional weights in its own directory; it does not change the existing
text-song model's installation state. Linux Swift tests cover individual stages,
API path guards and orphan recovery. The streamed runtime encoder converter
was tested on the full local encoder: all 146 output keys/shapes matched the
Python export, with 109,542/84,264,832 differing FP16 values and maximum
absolute difference 0.0001220703125. Cancellation after actual reconstruction
and conversion began removed incomplete staging outputs in local tests.
On 2026-11-25, both official complete header ranges (40,536 and 80,568 bytes)
also returned correct 206, ETag, Content-Range and locally pinned SHA-256 in a
Python PC preflight. A full Linux Swift fixture test served the verified local
encoder and tokenizer ranges through an injected test-only URL protocol: cancel
and resume, full preparation, integrity/status, reuse without downloading and
separate removal passed while a sentinel existing text-song model was preserved.
The protocol injection is behind `FADEDAI_RANGE_TESTS` and absent from normal
builds. The full chain has **not been tested against the real server or built /
tested on iPhone**, and its public API has no general lease to prevent deletion
while another direct caller is using a prepared directory.

To repeat the full PC fixture test, run `prepare_song_reference_e2e_fixture.py`
with `--vae`, `--tokenizer` and a **new** `--output` directory. Compile the
five `SongReference*` / `PhoneSongReferenceModels.swift` runtime files with
`PhoneSongReferenceEndToEndChecks.swift`, Swift 5 and `-D FADEDAI_RANGE_TESTS`;
on the Linux fixture container link OpenSSL 3 with
`-Xlinker -l:libcrypto.so.3`. Mount the fixture directory at `/work`, set
`HOME=/work/home`, and run the test without network. Only the fixture directory
and test executable should be removed afterwards. This reproduces the offline
fixture, not a real-server, iOS or audio-generation test.

`ACEAudioEncoder.swift` is a research port, outside the package's source
directory. It is **not built, installed, or connected to song creation**. A
successful Python check does not validate Swift/MLX, iPhone memory use, or
generated-audio quality.

The existing ACE-Step 1.5 PC VAE checkpoint can be converted without changing
it using `tools/export_ace_vae_encoder.py`. The resulting encoder weights are
approximately 169 MB (FP16); deployment, provenance and integrity checks must
be designed before adding a model-download URL to the app. A reference clip
also requires 48 kHz stereo conversion, hop-aligned padding, conditioning,
explicit memory lifecycle management, error handling and an iPhone UI.

`RangeFileDownload.swift` is an isolated optional-asset download prototype; it
is not in the app. It requests bounded chunks with Range/If-Range and a strong
ETag, checks every response and saves a sidecar identifying the partial file.
The caller must serialise access to each partial path and supply a strong final
digest verifier (preferably streaming SHA-256 from a trusted manifest). It
rejects servers lacking supported ranges or the expected strong ETag; no
production hosting, background transfer or integrity manifest is configured.
`RangeFileDownloadChecks.swift` passed with Swift 5 mode on Linux against
`range_fixture_server.py` on loopback: interrupted/resumed ranges, incorrect
status, Content-Range, ETag and length, plus failed final verification. Header
validation uses a data-task delegate and explicitly cancels on rejection; with
a paced 64 MiB invalid HTTP 200 response the server sent 32,768 bytes before
disconnect. Calling only the delegate completion handler with `.cancel` did not
stop this Linux test early, so the explicit task cancellation is necessary.
This fixture does not prove a fixed limit on bytes in flight. It does not test
real iOS URLSession, network interruptions during a chunk, disk full/power loss,
multi-process races, a real hosting provider or large valid files.
Absolute source offsets are also covered: a subrange beginning at byte 22,000
was interrupted and resumed from byte 38,384 without repeating the first block;
wrong source total and wrong starting offset in Content-Range were rejected.
On 2026-11-25, a separate 65,536-byte absolute range from each pinned official
VAE and tokenizer URL was also fetched using Linux Swift URLSession. Each
followed one redirect, returned the expected ETag and Content-Range, and
matched bytes from the independently whole-file-verified local checkpoint.
The VAE probe used bytes 168,868,700–168,934,235 of 337,431,388; the tokenizer
probe used bytes 4,577,761,208–4,577,826,743 of 4,787,825,604. Across Python
preflights and Swift probes, 448 KiB of model data were read in total. CDN
ETags are transport validators and may change; they are not the pinned hashes.
These small real-server probes do not test the entire model, long-running
resumption, changing CDN ETags or iOS. Task cancellation is now propagated to
the URLSession task. A paced local fixture cancelled a second chunk after the
server sent 512 of 16,384 bytes; the prior complete chunk was preserved and a
subsequent request resumed and verified the full output. Immediate cancellation
also passed. Real-server/iOS cancellation, process termination, disk failures
and exhaustive cancellation-race testing remain outstanding.

`tools/check_song_encoder_reference.py` checks tiled vs. untiled encoding using
the PC's PyTorch VAE with deterministic synthetic audio. It does not run Swift.
On the local original model, it passed with maximum absolute difference
0.00000763 across 30 latent frames. The converter's weight-norm verification
also passed; a separate short PC forward pass using exported FP16 weights
showed mean absolute difference 0.000466 and maximum 0.002623 vs. the original.

`rebuild_safetensors_range.py` reconstructs a separate original-layout BF16
file from a pinned complete header and the corresponding contiguous data range
in `official-range-manifest.json`. `locally-derived-header-digests.json` records
header hashes calculated locally after the original complete files matched the
manifest's official whole-file hashes; neither those header hashes nor the
range hashes are independently published official digests. Eight synthetic
tests passed, including corruption, malformed headers and no-overwrite cases.
Using temporary local extracts from both original ACE-Step checkpoints, all
183 encoder and 32 tokenizer tensors matched their original tensors when read
with safetensors. Temporary extracts were removed. Reconstruction does not
fold weight normalization or convert to the MLX layout, and Python code here
is not an iPhone implementation or production downloader.

`RebuildSafeTensors.swift` is a separate streaming Swift 5 reconstruction
prototype. In a network-isolated Linux container, its output matched Python's
BF16 bit patterns for both synthetic tensors, all 183 real encoder tensors and
all 32 real tokenizer tensors; corrupt
headers, corrupt data and an existing destination were rejected. The Linux
test used the installed OpenSSL 3 runtime for streaming SHA-256. Its CryptoKit
branch has not been compiled or tested on Apple hardware. Header/manifest
digests must come from a trusted source, and JSON duplicate-key handling,
concurrent writers, device file protection and atomic move behaviour require
additional validation before production use. No model or app is installed.

`EncoderWeightsConvert.swift` is a separate Swift 5 research converter from a
previously verified encoder-only BF16 safetensors file to FP16 MLX Conv1d
layout. On a small synthetic fixture, all six resulting tensors were bit-exact
against `tools/export_ace_vae_encoder.py`, including a hand-checked norm axis,
transpose and unchanged Snake log parameters. Separate executable checks
rejected a missing pair, zero norm, non-finite values, FP16 overflow, wrong
shape and overwriting an existing output. A full 169 MB real encoder conversion
in a two-CPU, no-GPU Linux container took 28.3 seconds; container cgroup memory
peaked at 676,061,184 bytes (~645 MiB, including other container memory/cache).
All 146 output names, shapes and types matched the existing Python export;
109,542 of 84,264,832 values across 30 tensors differed, maximum absolute
difference 0.0001220703125. The remaining values matched exactly. These results
do not determine audible differences, MLX runtime behaviour or iPhone RAM use.
The implementation assumes trusted reconstructed input and lacks production-
grade atomic staging, cancellation and resumability. Keep it outside the app.

`reference_audio_plan.py` is a platform-independent frame-selection design for
a 30-second timbre reference. `check_reference_audio_plan.py` compares it
directly to the installed ACE-Step handler across 15 input-length and random
offset edge cases; all selected samples matched. The separate
`ReferenceAudioPlan.swift` port and `ReferenceAudioPlanChecks.swift` passed
those 15 fixtures, invalid-input checks and an Int.max overflow check using
Swift 6.2.1 in an offline Linux container. They remain outside the app's build;
the test does not exercise iOS audio decoding, resampling, MLX or song creation.

Normal cover/remix is more than reference timbre. `ACEAudioTokenizer.swift` is
an experimental FSQ path using the existing `ACEEncoderStack`; it is outside
the build and needs compilation, numerical comparison and device testing.
`tools/export_ace_audio_tokenizer.py` exports the 32 tokenizer tensors from the
PC checkpoint without overwriting it. `tools/test_ace_audio_tokenizer_export.py`
compared original and exported weights through the actual CPU tokenizer, using
silence, seeded random and smooth input: all six token IDs matched and the
largest quantized-vector difference was 5.96e-8. `tools/check_ace_fsq_math.py`
compared an independent translation of the Swift scalar FSQ arithmetic against
the installed Python quantizer for 2,048 vectors; all codes matched exactly.
Neither test runs the Swift implementation.

Full cover still needs the existing detokenizer, correct source masks and
sampling. ACE-Step also has a raw/no-FSQ cover variant; it is not equivalent to
the default FSQ path and has not been ported or quality-tested.

Next validation: Apple-platform compilation against MLX Swift 0.31.4, numerical
comparison on-device against a PC-generated oracle, peak-memory profiling on a
real iPhone, then end-to-end listening tests. Do not present this as finished.

Encoder architecture is based on [mlx-ace-step-swift](https://github.com/xocialize/mlx-ace-step-swift)
and the ACE-Step 1.5 MLX implementation (MIT licenses).
