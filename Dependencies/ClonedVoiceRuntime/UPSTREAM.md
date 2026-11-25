# ChatterboxCoreML adapter

Native adapter around iliasaz/chatterbox-coreml at
`b8288834e783f3a6210757fbaf62f9014220bff9` (MIT). The package is resolved via
SwiftPM; upstream code and license remain in the dependency checkout.
Multilingual is selected for Danish. Turbo/Nano are English and are not used.
PerthCoreML follows the same branch requirement as upstream and is locked by
Package.resolved after dependency resolution. No voice clips or model weights
belong in this directory or Git.

Install fetches multilingual synthesis, voice-conditioning encoders, and the
Perth encoder together, then checks every selected manifest file's size.
A cancelled or partial download does not become ready. Synthesis loads only
local paths and never invokes Hub discovery or Russian model downloads.

Danish speech quality, cloning similarity, first-load compilation time and RAM
need an Apple/iPhone acceptance test. Upstream validates multilingual primarily
in Russian; its benchmark numbers are not FadedAI measurements.
