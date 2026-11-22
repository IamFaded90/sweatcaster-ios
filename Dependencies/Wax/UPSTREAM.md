# Wax iOS compatibility

Source is from [Wax](https://github.com/christopherkarani/Wax) revision
`17b211996af3774c2fbc4c676e2e750b04aa3027`, under the included MIT license.

This snapshot contains the six library targets used by FadedAI's private
text search. The package manifest keeps the same dependencies and resources
for those targets. Embedding providers remain disabled, matching the previous
dependency's empty trait selection.

Two source files have platform guards added for iOS compilation.

- `AgentBrokerClient.swift` compiles process termination helpers on macOS and
  Linux only. Process ownership lookup uses `proc_pidpath` on macOS only.
- `MemorySemantics+Git.swift` runs Git ancestry queries on macOS and Linux only.
  On iOS, unverified ancestry returns false.

The memory store, text search and private lookup API are from the pinned
upstream revision. Any update should retain these platform guards until the
equivalent upstream fixes are included.
