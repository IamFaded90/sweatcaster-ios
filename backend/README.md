# FadedAI PC backend extensions

`repository_library.py` is an additive PC module. Copy it into the existing Python installation's `sweatcaster` package. The current HTTP contracts stay as shipped. Use the PC's existing Git credential helper for private GitHub access, configured under the same Windows account that runs this command. The module never accepts a token or an arbitrary clone URL.

From the PC backend directory, replace the two example paths with the configured Agent Workspace and the existing local ONNX embedding directory:

```powershell
$repoArgs = @('--workspace', 'D:\AgentWorkspace', '--database', 'D:\FadedAIData\code-index.sqlite', '--embedding-dir', 'F:\FadedAIModels\embedding')
.\.venv\Scripts\python.exe -m sweatcaster.repository_library @repoArgs clone owner/project
.\.venv\Scripts\python.exe -m sweatcaster.repository_library @repoArgs index owner/project
```

The optional `mcp` subcommand requires the official Python `mcp` SDK. Configure it as a local stdio server in the agent host, passing the same paths. It exposes `read_repository_file` and `search_repository`. It reads regular tracked source blobs from a local Git snapshot. Keep the workspace and index private, especially for private projects. Existing PDF ingest and scheduling remain available through the installed backend.
