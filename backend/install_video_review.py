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
    for path, text in [(render, renderer), (pipeline, engine)]:
        compile(text, str(path), "exec")
    for path, text in [(render, renderer), (pipeline, engine)]:
        path.write_text(text, encoding="utf-8")
