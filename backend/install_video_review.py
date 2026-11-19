"""Add an optional 360×640 render to the existing PC video pipeline."""

from pathlib import Path

def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError("The installed video renderer does not match the preview update.")
    return source.replace(old, new, 1)


def install(root: Path):
    package = root / "sweatcaster"
    render = package / "render.py"
    pipeline = package / "pipeline.py"
    renderer = render.read_text(encoding="utf-8")
    engine = pipeline.read_text(encoding="utf-8")
    if 'preview: bool = False,' not in renderer:
        renderer = replace_once(renderer, '    crop_mode_used: str,\n) -> list[str]:',
                                '    crop_mode_used: str,\n    preview: bool = False,\n) -> list[str]:')
        renderer = replace_once(renderer, '    filtergraph = ";".join([video, *chains])',
                                '''    if preview:
        video = video.replace("1080:1920", "360:640").replace("boxblur=20:1", "boxblur=7:1")
    filtergraph = ";".join([video, *chains])''')
        renderer = replace_once(renderer, '        "veryfast",\n        "-crf",\n        "20",',
                                '        "ultrafast" if preview else "veryfast",\n        "-crf",\n        "30" if preview else "20",')
        renderer = replace_once(renderer, '    cancel: threading.Event | None,\n) -> list[str]:',
                                '    cancel: threading.Event | None,\n    preview: bool = False,\n) -> list[str]:')
        renderer = replace_once(renderer, '        crop_mode_used=crop_mode_used,\n    )',
                                '        crop_mode_used=crop_mode_used,\n        preview=preview,\n    )')
        renderer = replace_once(renderer, '''    if info.width != 1080 or info.height != 1920:
        raise UserFacingError(
            f"The video came out {info.width}x{info.height} instead of 1080x1920."
        )''', '''    width, height = (360, 640) if preview else (1080, 1920)
    if (info.width, info.height) != (width, height):
        raise UserFacingError(
            f"The video came out {info.width}x{info.height} instead of {width}x{height}."
        )''')
    if 'preview=bool(job.get("faded_preview")),' not in engine:
        engine = replace_once(engine, '            crop_mode_used=analysis.crop_mode_used,\n            cancel=cancel,',
                              '            crop_mode_used=analysis.crop_mode_used,\n            cancel=cancel,\n            preview=bool(job.get("faded_preview")),')
    worker = package / "jobs.py"
    jobs = worker.read_text(encoding="utf-8")
    if 'job["export_quality"] = check_export' not in engine:
        engine = replace_once(engine, "        return warnings, timed",
                              "        from sweatcaster.video_quality import check_export\n"
                              '        job["export_quality"] = check_export(output, analysis.probe, bundle, cancel)\n'
                              "        return warnings, timed")
    if "    checks_export = True" not in engine:
        engine = replace_once(engine, "class Pipeline:\n", "class Pipeline:\n    checks_export = True\n\n")
    if 'current["export_quality"] = job.get("export_quality")' not in jobs:
        jobs = replace_once(jobs, '                current["warnings"] = warnings[:12]',
                            '                current["export_quality"] = job.get("export_quality")\n'
                            '                current["warnings"] = warnings[:12]')
        jobs = replace_once(jobs, '            code, message = phone_error(exc, self.settings.token)',
                            '            from sweatcaster.video_quality import ExportQualityError\n'
                            '            if isinstance(exc, ExportQualityError):\n'
                            '                current["export_quality"] = exc.quality\n'
                            '            code, message = phone_error(exc, self.settings.token)')
    files = [(render, renderer), (pipeline, engine), (worker, jobs)]
    for path, text in files:
        compile(text, str(path), "exec")
    for path, text in files:
        path.write_text(text, encoding="utf-8")
