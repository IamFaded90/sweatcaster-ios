"""Move a single indexed original out of the Video Studio catalog."""

import re
import stat
from pathlib import PurePosixPath
from threading import Lock

from sweatcaster.dto import ApiError, TERMINAL
from sweatcaster.media import VIDEO_EXTENSIONS
from sweatcaster.security import UnsafePath, resolve_inside

clip_operations = Lock()
REMOVED_FOLDER = ".FadedAI-slettede-klip"


def _plain(path, *, directory=False):
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode) or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT:
        raise ApiError(409, "NOT_READY", "Klip eller mappe er et link eller en særlig fil.")
    return info


def _clip_location(settings, store, clip_id):
    if not re.fullmatch(r"[a-f0-9]{32}", clip_id):
        raise ApiError(404, "NOT_FOUND", "Klip-id'et findes ikke.")
    row = store.get_clip(clip_id)
    if row is None:
        raise ApiError(404, "NOT_FOUND", "Klippet findes ikke i PC’ens klipliste.")
    index = int(row["root_index"])
    if not 0 <= index < len(settings.input_roots):
        raise ApiError(404, "NOT_FOUND", "Klippets spilmappe findes ikke.")
    root = settings.input_roots[index].resolve()
    relative = row["relative_path"]
    try:
        source = resolve_inside(root, relative)
    except UnsafePath as exc:
        raise ApiError(409, "NOT_READY", "Klippet ligger ikke i en gyldig spilmappe.") from exc
    parts = PurePosixPath(relative).parts
    if source != root.joinpath(*parts) or source.suffix.lower() not in VIDEO_EXTENSIONS or any(part.startswith(".") for part in parts):
        raise ApiError(409, "NOT_READY", "Klippet ligger ikke i en gyldig spilmappe.")
    return root, source, row


def check_clip_for_job(settings, store, clip_id):
    # A recently moved clip can remain in the PC catalog until the next scan.
    _, source, _ = _clip_location(settings, store, clip_id)
    try:
        _plain(source)
    except FileNotFoundError as exc:
        raise ApiError(404, "NOT_FOUND", "Klippet findes ikke længere i spilmappen.") from exc


def move_original_clip(settings, store, clip_id):
    with clip_operations:
        root, source, row = _clip_location(settings, store, clip_id)
        if any(job["clip_id"] == clip_id and job["status"] not in TERMINAL for job in store.list_jobs()):
            raise ApiError(409, "NOT_READY", "Afslut eller stop klippets videojob først.")
        try:
            info = _plain(source)
        except FileNotFoundError:
            raise ApiError(404, "NOT_FOUND", "Klippet findes ikke længere i spilmappen.") from None
        if info.st_size != int(row["size_bytes"]) or info.st_mtime_ns != int(row["mtime_ns"]):
            raise ApiError(409, "CLIP_CHANGED", "Klippet er ændret. Opdatér spilmappen og prøv igen.")
        try:
            archive = root / REMOVED_FOLDER
            archive.mkdir(exist_ok=True)
            _plain(archive, directory=True)
            target_folder = archive / clip_id
            target_folder.mkdir(exist_ok=True)
            _plain(target_folder, directory=True)
            target = target_folder / source.name
            if target.exists() or target.is_symlink():
                raise ApiError(409, "NOT_READY", "Der findes allerede en gendannelseskopi med det navn.")
            if _plain(source) != info:
                raise ApiError(409, "CLIP_CHANGED", "Klippet er ændret. Opdatér spilmappen og prøv igen.")
            source.rename(target)
        except OSError as exc:
            raise ApiError(409, "NOT_READY", "PC’en kunne ikke flytte klippet. Luk klippet på PC’en og prøv igen.") from exc
        return {"removed": True}
