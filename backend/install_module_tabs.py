"""Install the additive module hooks into a compatible FadedAI PC checkpoint."""

import argparse
from pathlib import Path


def install(root: Path) -> None:
    package = root / "sweatcaster"
    source = Path(__file__).resolve().parent / "sweatcaster" / "module_tabs.py"
    changes = {
        "api.py": (
            "    register_v2(app, settings)\n",
            "    register_v2(app, settings)\n"
            "    from sweatcaster.module_tabs import register_modules\n"
            "    register_modules(app, settings, _bearer)\n",
        ),
        "v2_api.py": (
            '        tag, lease = _admit_chat(settings, coord, body)\n',
            '        from sweatcaster.module_tabs import collection_answer\n'
            '        message = str(body.get("message") or "")\n'
            '        answer = collection_answer(settings, message)\n'
            '        if answer is not None:\n'
            '            if settings.token:\n'
            '                answer = answer.replace(settings.token, "[token]")\n'
            '            tag = _resolve_tag(settings, body.get("model_id"))\n'
            '            try:\n'
            '                lease = coord.admit(identity_hash(settings.token), str(body["request_id"]), tag)\n'
            '            except RequestReused as exc:\n'
            '                raise ApiError(409, "REQUEST_REUSED", "That request id was already used.") from exc\n'
            '            except QueueFull as exc:\n'
            '                raise ApiError(503, "NOT_READY", "The model queue is full.") from exc\n'
            '            coord.release(lease)\n'
            '            def stream_collection():\n'
            '                yield sse("tool_status", "Læser Kortsamling på PC’en.")\n'
            '                for offset in range(0, len(answer), 2000):\n'
            '                    yield sse("text", answer[offset:offset + 2000])\n'
            '                yield sse_json({"type": "done", "content": "", "message_id": str(uuid.uuid4()),\n'
            '                                "model_id": id_for(tag) or "qwen25-7b"})\n'
            '            return StreamingResponse(stream_collection(), media_type="text/event-stream")\n'
            '        tag, lease = _admit_chat(settings, coord, body)\n',
        ),
        "output_cleanup.py": (
            "def delete_rendered_video(settings: Settings, store: Store, job_id: str) -> dict:\n",
            "def discard_failed_video(settings: Settings, job_id: str) -> None:\n"
            "    if not re.fullmatch(r\"[a-f0-9]{32}\", job_id):\n"
            "        raise ApiError(404, \"NOT_FOUND\", \"Jobbet findes ikke.\")\n"
            "    folder = settings.output_root.resolve() / \"jobs\" / job_id\n"
            "    if folder.resolve() != folder:\n"
            "        raise ApiError(409, \"NOT_READY\", \"Jobmappen er et link.\")\n"
            "    with _HELD_LOCK:\n"
            "        if _HELD.get(job_id):\n"
            "            raise ApiError(409, \"NOT_READY\", \"Luk videoen, og prøv igen.\")\n"
            "        for name in _FILES:\n"
            "            _remove_allowlisted(folder, folder / name, unlink=Path.unlink, sleep=time.sleep)\n"
            "\n\n"
            "def delete_rendered_video(settings: Settings, store: Store, job_id: str) -> dict:\n"
        ),
        "store.py": (
            "    def next_queued(self) -> str | None:\n",
            "    def delete_completed_job(self, job_id: str) -> bool:\n"
            "        with self._lock:\n"
            "            conn = self._connect()\n"
            "            try:\n"
            "                result = conn.execute(\"DELETE FROM jobs WHERE id = ? AND state = 'completed'\", (job_id,))\n"
            "                conn.commit()\n"
            "                return result.rowcount == 1\n"
            "            finally:\n"
            "                conn.close()\n"
            "\n"
            "    def next_queued(self) -> str | None:\n"
        ),
    }
    staged = {}
    for name, (anchor, replacement) in changes.items():
        path = package / name
        original = path.read_text(encoding="utf-8")
        if replacement in original:
            continue
        base = original
        if name == "v2_api.py":
            old_start = '        from sweatcaster.module_tabs import collection_answer\n'
            old_end = '        yield sse("tool_status", "Preparing the selected model.")\n'
            if old_start in base:
                start = base.index(old_start)
                end = base.index(old_end, start)
                base = base[:start] + base[end:]
        if base.count(anchor) != 1:
            raise ValueError(f"Checkpoint has an unexpected {name}; no files were written.")
        updated = base.replace(anchor, replacement)
        compile(updated, str(path), "exec")
        staged[path] = (original, updated)
    api = package / "api.py"
    original = api.read_text(encoding="utf-8")
    current = staged.get(api, (original, original))[1]
    failed_delete = "        if not store.delete_failed_job(job_id):\n"
    failed_cleanup = (
        "        from sweatcaster.output_cleanup import discard_failed_video\n"
        "        discard_failed_video(settings, job_id)\n"
        + failed_delete
    )
    if failed_cleanup not in current:
        if current.count(failed_delete) != 1:
            raise ValueError("Checkpoint has an unexpected failed video handler; no files were written.")
        updated = current.replace(failed_delete, failed_cleanup)
        compile(updated, str(api), "exec")
        staged[api] = (original, updated)
    cleanup = package / "output_cleanup.py"
    original = cleanup.read_text(encoding="utf-8")
    current = staged.get(cleanup, (original, original))[1]
    unavailable_job = (
        "def discard_unavailable_video_job(settings: Settings, store: Store, job_id: str) -> None:\n"
        "    if not re.fullmatch(r\"[a-f0-9]{32}\", job_id):\n"
        "        raise ApiError(404, \"NOT_FOUND\", \"Jobbet findes ikke.\")\n"
        "    with _HELD_LOCK:\n"
        "        job = store.get_job(job_id)\n"
        "        if job is None:\n"
        "            return\n"
        "        if job[\"status\"] != \"completed\" or _HELD.get(job_id):\n"
        "            raise ApiError(409, \"NOT_READY\", \"Kun afsluttede jobkort uden video kan fjernes.\")\n"
        "        folder = settings.output_root.resolve() / \"jobs\" / job_id\n"
        "        if folder.resolve() != folder:\n"
        "            raise ApiError(409, \"NOT_READY\", \"Jobmappen er et link.\")\n"
        "        try:\n"
        "            (folder / \"output.mp4\").lstat()\n"
        "        except FileNotFoundError:\n"
        "            pass\n"
        "        except OSError as exc:\n"
        "            raise ApiError(409, \"NOT_READY\", \"PC’en kunne ikke kontrollere den redigerede video.\") from exc\n"
        "        else:\n"
        "            raise ApiError(409, \"NOT_READY\", \"Den redigerede video ligger stadig på PC’en.\")\n"
        "        if not store.delete_completed_job(job_id):\n"
        "            raise ApiError(409, \"NOT_READY\", \"Jobbet ændrede sig. Opdatér joblisten.\")\n"
        "\n\n"
    )
    if unavailable_job not in current:
        anchor = "def discard_failed_video(settings: Settings, job_id: str) -> None:\n"
        if current.count(anchor) != 1:
            raise ValueError("Checkpoint has unexpected video cleanup; no files were written.")
        updated = current.replace(anchor, unavailable_job + anchor)
        compile(updated, str(cleanup), "exec")
        staged[cleanup] = (original, updated)
    modules = {}
    for name in (source.name, "code_batch.py", "repository_library.py", "agent_workflows.py",
                 "aio_runtime.py", "bot_computers.py", "bot_computer_routes.py",
                 "emby_library.py", "emby_settings.py", "searxng_search.py", "google_desktop.py", "youtube_connection.py"):
        path = source.parent / name
        module = path.read_text(encoding="utf-8")
        compile(module, str(path), "exec")
        modules[name] = module
    for path, (original, _) in staged.items():
        backup = path.with_suffix(".py.before-module-tabs")
        if not backup.exists():
            backup.write_text(original, encoding="utf-8")
    for name, module in modules.items():
        (package / name).write_text(module, encoding="utf-8")
    for path, (_, updated) in staged.items():
        path.write_text(updated, encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkpoint", type=Path)
    install(parser.parse_args().checkpoint.resolve())
