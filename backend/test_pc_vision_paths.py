"""Opt-in image regression across the deployed v2, window and screen-share PC interfaces."""

import asyncio
from base64 import b64encode
from io import BytesIO
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from types import SimpleNamespace
import uuid

import pytest


@pytest.mark.skipif(os.environ.get("FADEDAI_TEST_QWEN_VISION") != "1", reason="Requires local Ollama with Qwen3-VL 4B")
def test_installed_vision_reads_fixture_and_reports_correct_model(tmp_path):
    subprocess.run([sys.executable, "-B", __file__, str(tmp_path)], check=True, timeout=175)


def run_fixture(tmp_path):
    from PIL import Image, ImageDraw, ImageFont
    import sweatcaster
    from install_fadedai_pc import install

    source = Path(sweatcaster.__file__).parent
    package = tmp_path / "sweatcaster"
    package.mkdir()
    for module in source.glob("*.py"):
        shutil.copyfile(module, package / module.name)
    install(tmp_path)
    sweatcaster.__path__.insert(0, str(package))
    from sweatcaster import v2_api
    from sweatcaster.coord import ModelCoord
    from sweatcaster.phone_screen import PhoneScreens
    from sweatcaster.window_capture import Window
    from sweatcaster.window_help import WindowHelp

    settings = SimpleNamespace(ollama_origin="http://127.0.0.1:11434", output_root=tmp_path,
                               ollama_model="qwen3.5:4b", token="synthetic-test")
    image = Image.new("RGB", (680, 280), "white")
    draw = ImageDraw.Draw(image)
    draw.rectangle((12, 12, 668, 268), outline="navy", width=6)
    font = ImageFont.truetype("C:/Windows/Fonts/arialbd.ttf", 85)
    draw.text((42, 85), "TEST 7392", font=font, fill="black")
    output = BytesIO()
    image.save(output, format="JPEG", quality=93)
    pixels = output.getvalue()
    model = next(item for item in v2_api.catalog(settings)["models"] if item["id"] == "qwen3-vl-4b")
    assert model["available"] and model["label"] == "Qwen3-VL 4B"
    body = {"model_id": model["id"], "message": "Read the text from this image exactly.",
            "request_id": str(uuid.uuid4()), "image": {"media_type": "image/jpeg", "data_base64": b64encode(pixels).decode()}}
    coord = ModelCoord(tmp_path / "state.sqlite3")
    stream = v2_api._image_chat(settings, coord, body)

    async def collect():
        return [part.decode() if isinstance(part, bytes) else part async for part in stream.body_iterator]

    events = [json.loads(line.removeprefix("data:").strip()) for line in "".join(asyncio.run(collect())).splitlines()
              if line.startswith("data:")]
    answer = "".join(record["content"] for record in events if record["type"] == "text")
    assert "7392" in answer and events[-1].get("model_id") == model["id"]

    class SelectedWindow:
        def list_windows(self):
            return [Window(123, 42, "Synthetic OCR test", "Test")]

        def labels(self, window):
            return []

        def state(self, window):
            return "visible"

        def capture(self, window):
            return pixels

    window = WindowHelp(settings, SelectedWindow())
    observation = window.inspect(window.windows()["windows"][0]["id"], "Hvilket nummer kan du se?")
    assert "7392" in (observation.get("reading") or "") and coord.resident() == "qwen3-vl:4b"
    phone = PhoneScreens(settings)
    session = phone.create(str(uuid.uuid4()))
    phone.frame(session["id"], session["uploadToken"], pixels)
    observation = phone.ask(session["id"], "Hvilket tal står der?")
    assert "7392" in observation["reading"] and coord.resident() == "qwen3-vl:4b"


if __name__ == "__main__":
    run_fixture(Path(sys.argv[1]))
