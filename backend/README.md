# FadedAI PC backend extensions

`repository_library.py` is an additive PC module. Copy it into the existing Python installation's `sweatcaster` package. The current HTTP contracts stay as shipped. Use the PC's existing Git credential helper for private GitHub access, configured under the same Windows account that runs this command. The module never accepts a token or an arbitrary clone URL.

From the PC backend directory, replace the two example paths with the configured Agent Workspace and the existing local ONNX embedding directory:

```powershell
$repoArgs = @('--workspace', 'D:\AgentWorkspace', '--database', 'D:\FadedAIData\code-index.sqlite', '--embedding-dir', 'F:\FadedAIModels\embedding')
.\.venv\Scripts\python.exe -m sweatcaster.repository_library @repoArgs clone owner/project
.\.venv\Scripts\python.exe -m sweatcaster.repository_library @repoArgs index owner/project
```

The optional `mcp` subcommand requires the official Python `mcp` SDK. Configure it as a local stdio server in the agent host, passing the same paths. It exposes `read_repository_file` and `search_repository`. It reads regular tracked source blobs from a local Git snapshot. Keep the workspace and index private, especially for private projects. Existing PDF ingest and scheduling remain available through the installed backend.

## Dynamic tabs and Kortscanner

Run `python backend/install_module_tabs.py <checkpoint-directory>` and restart the PC server. The installer validates the existing hook locations and keeps copies of the two original files. The separate `/api/modules/v1` endpoints use the existing pairing authentication. The first compatible iOS build is required once.

Export JSON from Kortscanner, open Kortsamling on the phone and choose the file. Import replaces the previous collection on this PC. In v2 chat, type `Kortsamling: Hvilke kort har jeg dubletter af?` or `Kortsamling: Hvilke kort mangler en pris?`. These answers use a local lookup.

Add more native information tabs by placing `module-tabs.json` in the configured output directory, for example `[{"id":"status","title":"Status","text":"Alle rutiner er klar."}]`. The phone refreshes the manifest on foreground and pull-to-refresh. Other renderers and actions require a new app build.

## Local Code Bot batch queue

Copy `sweatcaster/code_batch.py` into the same installed Python package as `repository_library.py`. Run from the checkpoint directory:

```powershell
.\.venv\Scripts\python.exe -m sweatcaster.code_batch enqueue owner/project 'Describe a usable change' path/first.py path/second.py
.\.venv\Scripts\python.exe -m sweatcaster.code_batch worker
.\.venv\Scripts\python.exe -m sweatcaster.code_batch show <job-id>
```

The queue persists under the PC output directory. The worker serializes jobs and acquires the existing Ollama model lease shared with chat and rendering. It uses the configured local model. A job produces a review-only unified diff for up to five selected tracked files, plus a test plan. The worker does not apply proposals. Start the worker separately from the HTTP server. `worker --once` handles at most one queued job.
