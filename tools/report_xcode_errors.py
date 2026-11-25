"""Print bounded GitHub annotations from Xcode logs, without credential URLs."""
import argparse
from pathlib import Path
import re


def annotations(logs, workspace, limit=12):
    workspace = Path(workspace).resolve()
    diagnostics = re.compile(r"^(.+?\.swift):(\d+)(?::\d+)?:\s+(?:fatal )?error:\s+(.*)$")
    summary = re.compile(r"^(?:(?:xcodebuild|clang(?:\+\+)?): )?(?:fatal )?error:|^Undefined symbols for architecture|^ld: ")
    credentials = re.compile(r"https?://[^/\s@]+@|\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]+")
    seen = set()
    for log in logs:
        if not Path(log).is_file():
            continue
        with Path(log).open(encoding="utf-8", errors="replace") as lines:
            for raw in lines:
                line = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", raw).strip()
                match = diagnostics.match(line)
                if match:
                    file, number, message = match.groups()
                    path = (workspace / file).resolve()
                    relative = path.relative_to(workspace).as_posix() if path.is_relative_to(workspace) else ""
                    location = f" file={relative},line={number}" if re.fullmatch(r"[\w./+-]+", relative) else ""
                elif summary.search(line):
                    message, location = line, ""
                else:
                    continue
                message = credentials.sub("[skjult]", message)[:500]
                message = message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
                key = (location, message)
                if key not in seen:
                    seen.add(key)
                    yield f"::error{location}::{message}"
                if len(seen) >= limit:
                    return


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("logs", type=Path, nargs="+")
    args = parser.parse_args()
    for annotation in annotations(args.logs, args.workspace):
        print(annotation)
