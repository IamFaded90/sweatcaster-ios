"""Install the already downloaded Windows CPU runtime. Run with the whisper-pc-test source directory."""
from hashlib import file_digest
import os
from pathlib import Path
import shutil
import sys
from tempfile import TemporaryDirectory

FILES = {
    "Release/whisper-cli.exe": "b7c6dc2e999a80bc2d23cd4c76701211f392ae55d5cabdf0d45eb2ca4faf09af",
    "Release/ggml.dll": "f91ef57cfd6d2f07a5fc33e5dca114b3dc3abe8495f47b46dfbe178d6d775c37",
    "Release/ggml-base.dll": "e912e19071c32d673a81de4aab058d36328cc6b0c59c75889a0ba4c65fd6a4e6",
    "Release/ggml-cpu.dll": "341ed96e2520ef9b44509f18b5ac4f60d171e47a6c55ab390d704ea7b06ae617",
    "Release/whisper.dll": "bbeceed370799687a363244edc583bac3dc5d472f5bd14691a26f22c7e710bb8",
    "ggml-small-q5_1.bin": "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
}


def install(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    with TemporaryDirectory(prefix=".film-setup-", dir=target.parent) as staging:
        staged = Path(staging) / "film-whisper"
        (staged / "Release").mkdir(parents=True)
        for name, checksum in FILES.items():
            shutil.copyfile(source / name, staged / name)
            with (staged / name).open("rb") as file:
                if file_digest(file, "sha256").hexdigest() != checksum:
                    raise ValueError("Uventet fil i Whisper-pakken: " + name)
        if target.exists():
            for name, checksum in FILES.items():
                with (target / name).open("rb") as file:
                    if file_digest(file, "sha256").hexdigest() != checksum:
                        raise ValueError("En anden Whisper-installation bruger målmappen.")
            return
        staged.rename(target)


if __name__ == "__main__":
    base = Path(os.environ["LOCALAPPDATA"]) / "SweatCaster" / "models" / "film-whisper"
    install(Path(sys.argv[1]), base)
    print("Whisper til filmvennen er klar:", base)
