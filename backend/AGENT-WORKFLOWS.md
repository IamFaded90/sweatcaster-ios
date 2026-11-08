# Agent workflows on the PC

Install with `install_module_tabs.py` and restart the PC server. Existing Code Bot batch submissions run through local research, code generation and static checks. The checks parse Python and JSON without executing proposed code. The existing Manager, Researcher and File Explorer histories show the work. Approval stays in the existing batch review screen.

Manage explicit memories with authenticated `GET/PUT /api/modules/v1/agent-memory` and `DELETE /api/modules/v1/agent-memory/{id}`. A PUT body can be `{"scope":"global","kind":"preference","text":"Use Danish labels"}`. For architecture notes, set `scope` to `owner/repo` and `kind` to `architecture`. Batch research searches matching notes locally.

For daily local snapshot reindexing, create `agent-workflows/routines.json` under the configured output directory. Example: `[{"action":"reindex_repository","repo":"owner/project","hour":2}]`. The worker attempts a routine once per Copenhagen calendar day at or after the given hour while the PC service runs. This indexes local Git snapshots without fetching or pushing remote changes.
