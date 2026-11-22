# Agent workflows on the PC

Install with `install_module_tabs.py` and restart the PC server. Existing Code Bot batch submissions run through local research, code generation and static checks. The checks parse Python and JSON without executing proposed code. The existing Manager, Researcher and File Explorer histories show the work. Approval stays in the existing batch review screen.

For the paired Windows runtime, install `requirements-agent-tools.txt` with the checkpoint Python. Run `install_document_reader.py` for the separate Office conversion runtime. Playwright uses the installed Edge browser on Windows. The public price reader accepts a single advertised product price in the selected currency. Scheduled repository refreshes can resume indexing after process interruption with LangGraph's SQLite checkpoints.

The documentation fallback uses a dedicated Docker MCP profile. To reproduce the profile on a new PC, run `docker mcp profile create --id fadedai-docs --name "FadedAI dokumentation" --server catalog://mcp/docker-mcp-catalog/context7`. The client invokes only the two documentation tools. To run the local Ollama model browser, use `docker compose -f backend/compose.agent-lab.yaml up -d` from the repository, then open `http://127.0.0.1:3077` on the PC.

Manage explicit memories with authenticated `GET/PUT /api/modules/v1/agent-memory` and `DELETE /api/modules/v1/agent-memory/{id}`. A PUT body can be `{"scope":"global","kind":"preference","text":"Use Danish labels"}`. For architecture notes, set `scope` to `owner/repo` and `kind` to `architecture`. Batch research searches matching notes locally.

For daily local snapshot reindexing, create `agent-workflows/routines.json` under the configured output directory. Example: `[{"action":"reindex_repository","repo":"owner/project","hour":2}]`. The worker attempts a routine once per Copenhagen calendar day at or after the given hour while the PC service runs. This indexes local Git snapshots without fetching or pushing remote changes.

`GET /api/modules/v1/routines` returns the configuration and today's status. To replace the configuration, `PUT` an object with a `routines` array and the fields in the example. Choose `refresh_repository` to fetch the source branch from GitHub using the PC's Git credentials before indexing. Refresh accepts fast-forward updates only. It leaves review branches in place.

Code Bot's GitHub clone button calls authenticated `PUT /api/modules/v1/code-repositories` with `{"repo":"owner/project"}`. It uses existing PC Git credentials, including for private repositories. The HTTP MCP endpoint is `/api/modules/v1/mcp` with the official SDK `mcp>=1.29.1,<2`. It caps request bodies at 32 KiB, uses the pairing bearer token, allows local hosts, rejects browser Origin headers, and exposes the two read-only repository tools. The existing stdio transport is also available.
