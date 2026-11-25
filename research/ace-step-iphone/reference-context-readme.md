# Experimental reference-context routing

This is research, outside every app target. It does not generate audio or
establish that a phone can run a cover. `ReferenceContextPlan.swift` describes
the route for one text-to-music, FSQ cover or cover-nofsq item. It implements
the current PC handler's 128-frame minimum, start-of-silence padding, five-frame
tokenizer patches and attention mask, source/hint selection, full-span chunk
mask, task instruction and eight-step guide-release boundary. Its limits are
stricter than the upstream API: 1–4,500 source frames, 1–64 channels and
1–20 steps, with finite cover strength in [0, 1].

`reference_context_oracle.py` uses the locally installed, pinned ACE-Step
target-padding, chunk-mask, tokenizer-shaping, instruction and
`prepare_condition` methods to produce deterministic synthetic fixtures. It
also executes the actual eight-step PC sampler with a fake conditioner and
decoder to record guide-release timing. Learned VAE/tokenizer/detokenizer
layers are faked, so the tests do not measure numerical model quality. The
single-item, full-span `auto` chunk mask is `1` in the installed handler: it
assigns `2.0` into a Boolean tensor, which stores `true`. This observation is
specific to the pinned PC code, not a claim about other ACE-Step versions.

`ReferenceContextPlanChecks.swift` matched 120 cases in Swift 5 on a Linux
container: eight source lengths, three routes and five guide strengths. It
also rejects invalid lengths, malformed arrays, missing cover hints and
non-finite inputs. No MLX, Apple build, iPhone inference, memory measurement,
audio rendering, network or production code is exercised.

Reproduce with an isolated output path that does not already exist:

```powershell
& 'F:/FadedAI/song-studio/venv/Scripts/python.exe' research/ace-step-iphone/reference_context_oracle.py `
  --engine 'F:/FadedAI/song-studio/engine' --output build/reference-context-fixtures-new.json
```

Compile `ReferenceContextPlan.swift` and `ReferenceContextPlanChecks.swift`
together in Swift 5 mode, then invoke the executable with the JSON path. The
fixture file contains only synthetic numbers. ACE-Step 1.5 is MIT-licensed;
the code was compared with the installed ACE-Step v0.1.8 implementation.

**Integration requirement:** the iPhone text-to-song generator currently
renders beyond the requested duration before cropping. The PC cover path uses
the actual source length. Do not blindly apply text-to-song's extended render
window to source-guided remix: reconcile source duration, latent padding,
masking, conditioner, model compilation and output crop, then test on device.
