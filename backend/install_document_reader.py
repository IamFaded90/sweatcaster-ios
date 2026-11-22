"""Install the three local Office converters without changing the PC server's packages."""

import subprocess
import sys
from pathlib import Path


def install_document_reader(checkpoint: Path) -> None:
    if not (checkpoint / "sweatcaster" / "api.py").is_file():
        raise ValueError("Expected a FadedAI checkpoint.")
    environment = checkpoint / "document-tools-venv"
    python = environment / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")
    options = dict(check=True, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if not python.is_file():
        subprocess.run([sys.executable, "-m", "venv", str(environment)], **options)
    subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check",
                    "markitdown[docx,pptx,xlsx]==0.1.9"], timeout=600, **options)


if __name__ == "__main__":
    install_document_reader(Path(sys.argv[1]).resolve(strict=True))
