# Offline agents

The agent chat exposes **Klar uden PC** in its model card and voice menu. This
screen uses the existing model downloads and per-agent model/voice preferences.
It does not replace an existing model or voice automatically.

## Chat

- Optional Qwen3-4B-Instruct-2507 Q4_K_M download (2,497,281,120 bytes).
- Original model: https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507 (Apache-2.0).
- Quantization: https://huggingface.co/unsloth/Qwen3-4B-Instruct-2507-GGUF,
  revision `a06e946bb6b655725eafa393f4a9745d460374c9`.
- Existing download path checks file length and SHA-256 before installation.
- This model uses a 4,096-token context and Qwen non-thinking sampling settings.
  Other GGUF models retain their existing context and sampler settings.
- The agent supplies up to eight recent exchanges for the curated model. The
  runtime removes complete oldest exchanges if tokenization exceeds its budget;
  it preserves the instructions and latest question.
- The existing benchmark and model deletion screens also handle this model.

## Photos and voice

- Photo chat respects a selected, installed vision model if its RAM preflight
  passes; otherwise it uses a fitting model in catalog order. Text-only models
  are never treated as vision models. The response identifies its actual source.
- Without an installed vision model, existing on-device OCR remains available.
- Failed photo analysis preserves the attachment and question for retry.
- Hands-free preflight checks chat, dictation and the selected voice before
  recording. A PC voice does not silently become another voice.
- Downloadable speech retains the existing ten-voice Supertonic 3 pack and the
  existing Danish Whisper model. Voice selection stays per agent.
- Cached speech sessions are released before chat, vision, dictation and
  benchmarks. This does not increase the operating system's RAM allowance.
- Hands-free questions use the same send path as typed questions, including a
  photo attachment, and the agent reads the photo answer aloud.

## Validation and remaining device checks

Local validation covers the curated model with the existing llama.cpp b8668
runtime, model-choice/voice-readiness tests, native runtime type checking and
Swift syntax. It also checks synthesis from all ten voices and Danish recognition
of synthetic female and male samples. These are smoke tests, not a claim of
human-level Danish or iPhone performance.

Before release, on an iPhone with the appropriate signing permissions:

1. Download the chat model, choose it for one agent and run its speed test.
2. Hold a Danish conversation for at least ten turns, including a correction.
3. Attach a screenshot with PC disconnected; check the model label and answer.
4. Test a selected larger vision model under reduced memory and retry afterward.
5. Choose different downloaded voices for two agents; restart and verify choices.
6. Talk hands-free for several turns, including a photo question. Interrupt speech,
   lock/unlock the phone and verify that the microphone does not restart unnoticed.
7. Alternate voice, image generation and chat, checking memory and cancellation.

Full Xcode/ContractTests, iPhone vision inference, thermal behaviour and peak RAM
require Apple hardware. No release build or push is part of this local change.

## PC disconnected versus no internet

These are separate modes. A local language model can use an internet tool over
Wi-Fi or cellular without sending its model inference through the PC.

Implemented locally in the phone-tool follow-up:

- Agent chat recognises explicit Danish web-search requests and retains the
  existing web button. Team-chat searches and shared public links use the same
  reader. The PC route remains preferred for research, with a short health check;
  connection failures can fall back to the phone's existing Composio credential.
- Direct phone research uses discovered `TAVILY_SEARCH` / `TAVILY_EXTRACT`
  schemas. Search snippets remain labelled as snippets, not full-page reads.
  Empty or invalid results never become evidence for an invented answer.
- Instant-account search that consumes Composio balance is off by default. The
  user can enable it in Composio on iPhone or connect their own search account.
  This is not a promise of unlimited free web search.
- Latest/unread Gmail requests can list up to twelve messages and read a selected
  message directly through Composio. A stored phone credential takes precedence
  for these reads; the existing PC reader remains available otherwise. Message
  IDs are validated and message contents must match the selected ID. HTML is
  converted to inert text; no tracking images are loaded. No mail is sent,
  deleted, archived or marked as read by this path.
- A PC chat connection failure can continue the same text turn with the agent's
  selected installed phone model, preserving instructions and history. The
  answer and chat source change visibly to iPhone. Authentication errors and
  cancellations do not trigger a fallback. No model is downloaded automatically.

Still requiring separate implementation or a running PC:

- Mail cleanup, appointment scanning, and the remaining Drive/Sheets/Notion/GitHub
  action flows still use their existing PC pathways. Reviewed Gmail replies now
  also have a direct phone route, described below.
- The native phone workspace implements files, text tasks, research and queues;
  it does not emulate a Linux or Windows desktop.
- AIO Linux desktops, Windows programs, PC-only files and heavyweight PC models
  cannot run on a powered-off PC. Equivalent remote execution needs an available
  computer/server; cellular access alone does not provide one.

Local checks: parser/routing unit tests and driver tests with platform stubs;
Swift syntax and project wiring. The current Composio discovery schemas were
inspected. Real cellular transport, the phone's account login, service quotas,
full Xcode ContractTests and end-to-end tool execution remain device/account
checks. No private mail was read and no paid search was executed during these
checks. A release build is not started automatically.


## Combined two-five-item follow-up (local implementation)

The two lists overlap on conversation quality. The shared implementation is used
once, rather than adding a second memory or retry system. These changes are local;
no new IPA, push, service deployment or real email send was performed.

| Requested improvement | Implemented path | Release check still required |
| --- | --- | --- |
| User-selected Apple Shortcuts | Agent chat menu → Arbejdsrum → Mine Apple-genveje; registered names only, reviewed input, single-use callback correlation | Run an installed Shortcut on iPhone, including cancel/error callbacks |
| Gmail → reply → follow-up | Direct Composio on phone, reviewed recipient/body, persistent send receipt, exact sent-message verification; Calendar/Reminders review below receipt | Real account permissions, device cellular and one separately authorised email |
| Each agent's offline workspace | Agent-isolated files, notes, revisions, imports, local document tasks and selected-file context; use file in chat | iOS import/share UI and model performance |
| Durable jobs and PC handoff | Atomic per-agent journal; interrupted reads pause; explicit PC jobs wait and poll while workspace is open; server requestID identifies an uncertain submission | Suspend/relaunch, PC reconnect and real server status |
| Personal conversation and corrections | Per-agent language corrections replace contradictory preferences; explicit conversation corrections remain available beyond the short model history | Long natural conversations with installed model |
| Images in chat | Normal agent chat image workbench, local one/two references, serial four-image batch, image results in history, edit previous result, share/delete | Real iPhone two-reference and four-image generation; thermal/battery interruption |
| Fewer repetitive replies | Detect substantial repeated answers; one bounded repair pass, then honest failure if still repeating | Real local/PC model conversations |
| Same conversation after PC disconnect | Selected installed phone model receives history/profile, visible source switch; no auto download | Switch off PC during a real text reply |
| Hands-free interruption | Listen/think/speak status; Min tur cancels speech or generation, waits for cancellation, then resumes listening without replaying old draft | Real microphone/TTS timing and headphones; this is tap-to-interrupt, not acoustic barge-in |
| Photo/document → action | OCR deadline evidence and existing review/save flow; calendar/reminder actions under document/photo replies | iOS OCR and EventKit review/save/read-back |

Workspace examples: `lav et dokument: en pakkeliste`, `undersøg og gem: ...`,
`arbejd på pc: ...`, `kør genvej: Navn | input`. Files are supplied only when
selected; web search never automatically uploads workspace documents. Context
excerpts are labelled and bounded to the PC contract's byte limits. Unsupported
or old PC APIs fail explicitly instead of silently omitting the selected file.

The ordinary image workbench uses the existing general PC text-to-image endpoint.
Reference editing in this workbench uses a downloaded phone model; two references
require FLUX.2 Klein. Existing Studio/PC image flows remain unchanged. Four images
run sequentially, preserving each completed image if a later generation stops.

Mail sends are never automatically retried. A persisted `sending` or `uncertain`
state blocks a second send; if a message ID was returned it can be rechecked.
Without a returned ID, the user must inspect Sent in Gmail. Shortcuts callbacks
report what Shortcuts said, not independent verification of third-party effects.
PC job IDs follow the existing server requestID contract; a missing receipt is
queried rather than resubmitted. iOS can suspend the app: this is foreground work
with durable continuation, not a promise of always-running background agents.

Validation: 39 executable local Swift tests passed, including existing preference
and tool-loop regressions, workspace isolation/atomicity/revisions, UTF-8 context
budgets, callback replay/forgery checks, language preferences, correction context,
PC fallback, and real mail-client control flow against simulated service replies.
No real mail was read/sent for these tests. The workspace runner and reply driver
were compiled with platform stubs. All App/Tests Swift files passed syntax parsing,
project registration and whitespace checks. This is not a full SwiftUI/Xcode
build or a completed ContractTests/device run. Those remain release checks.

Apple Shortcuts URL/callback behavior was checked against the
[official Apple guide](https://support.apple.com/en-ca/guide/shortcuts/apdcd7f20a6f/ios).
Gmail request schemas were inspected through Composio discovery; no credentials
or personal account contents are included in these notes.
