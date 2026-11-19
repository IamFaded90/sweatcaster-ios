"""Executable building blocks for generated, tested FadedAI file tools."""

import csv
import io
import json
from pathlib import PurePosixPath
import re
import zipfile

MAX_BYTES = 24_000_000
TYPES = {"image_resize", "rename", "csv_columns", "text_replace", "zip"}


def basename(value):
    if not isinstance(value, str) or not 1 <= len(value) <= 140:
        raise ValueError("Filnavnet er ugyldigt.")
    if value != PurePosixPath(value).name or re.search(r'[\\/:*?"<>|\x00-\x1f]', value) or value in {".", ".."}:
        raise ValueError("Brug et almindeligt filnavn.")
    return value


def validate_spec(body):
    if not isinstance(body, dict) or set(body) != {"title", "description", "steps"}:
        raise ValueError("Værktøjet mangler titel, beskrivelse eller trin.")
    title, description = body["title"], body["description"]
    if not isinstance(title, str) or not 1 <= len(title.strip()) <= 60:
        raise ValueError("Giv værktøjet en kort titel.")
    if not isinstance(description, str) or not 1 <= len(description.strip()) <= 600:
        raise ValueError("Beskriv, hvad værktøjet gør.")
    if not isinstance(body["steps"], list) or not 1 <= len(body["steps"]) <= 5:
        raise ValueError("Et værktøj skal have ét til fem trin.")
    result = {"title": title.strip(), "description": description.strip(), "steps": []}
    for index, item in enumerate(body["steps"]):
        if not isinstance(item, dict):
            raise ValueError("Et trin er ugyldigt.")
        kind = item.get("type")
        if kind == "image_resize" and set(item) == {"type", "maxEdge", "format", "quality"}:
            if type(item["maxEdge"]) is not int or not 128 <= item["maxEdge"] <= 4096:
                raise ValueError("Billedstørrelsen skal være mellem 128 og 4096 pixels.")
            if (not isinstance(item["format"], str) or item["format"] not in {"jpeg", "png"}
                    or type(item["quality"]) is not int or not 50 <= item["quality"] <= 95):
                raise ValueError("Vælg JPEG eller PNG med kvalitet 50–95.")
        elif kind == "rename" and set(item) == {"type", "prefix", "start"}:
            if not isinstance(item["prefix"], str) or not re.fullmatch(r"[\w -]{1,60}", item["prefix"]):
                raise ValueError("Brug et kort navnepræfiks.")
            if type(item["start"]) is not int or not 0 <= item["start"] <= 999_999:
                raise ValueError("Startnummeret er ugyldigt.")
        elif kind == "csv_columns" and set(item) == {"type", "columns"}:
            columns = item["columns"]
            if (not isinstance(columns, list) or not 1 <= len(columns) <= 30
                    or any(not isinstance(col, str) or not 1 <= len(col) <= 100 for col in columns)
                    or len(set(columns)) != len(columns)):
                raise ValueError("Vælg de kolonner, du vil beholde.")
        elif kind == "text_replace" and set(item) == {"type", "find", "replace"}:
            if (not isinstance(item["find"], str) or not 1 <= len(item["find"]) <= 500
                    or not isinstance(item["replace"], str) or len(item["replace"]) > 500):
                raise ValueError("Søg efter og erstat med korte tekster.")
        elif kind == "zip" and set(item) == {"type", "name"}:
            if index != len(body["steps"]) - 1 or not basename(item["name"]).lower().endswith(".zip"):
                raise ValueError("En ZIP-pakke skal være sidste trin.")
        else:
            raise ValueError("Værktøjet indeholder et ukendt trin.")
        result["steps"].append(dict(item))
    return result


def _images(files, step):
    from PIL import Image

    result, matched = {}, False
    for name, data in files.items():
        if PurePosixPath(name).suffix.lower() not in {".jpg", ".jpeg", ".png", ".webp", ".bmp"}:
            result[name] = data
            continue
        matched = True
        with Image.open(io.BytesIO(data)) as image:
            if image.width * image.height > 16_000_000:
                raise ValueError("Billedet er for stort. Vælg et billede på højst 16 megapixels.")
            image.thumbnail((step["maxEdge"], step["maxEdge"]))
            output = io.BytesIO()
            converted = image.convert("RGB") if step["format"] == "jpeg" else image.convert("RGBA")
            converted.save(output, format=step["format"].upper(), quality=step["quality"])
            suffix = ".jpg" if step["format"] == "jpeg" else ".png"
            target = str(PurePosixPath(name).with_suffix(suffix))
            if target in result:
                raise ValueError("To billeder ville få samme filnavn.")
            result[target] = output.getvalue()
        if sum(map(len, result.values())) > MAX_BYTES * 2:
            raise ValueError("Billedresultatet er for stort.")
    if not matched:
        raise ValueError("Vælg mindst ét billede til dette værktøj.")
    return result


def _columns(files, step):
    result, matched = {}, False
    for name, data in files.items():
        if PurePosixPath(name).suffix.lower() != ".csv":
            result[name] = data
            continue
        matched = True
        reader = csv.DictReader(io.StringIO(data.decode("utf-8-sig")))
        header = reader.fieldnames or []
        if len(set(header)) != len(header):
            raise ValueError("CSV-filen har ens kolonnenavne. Giv kolonnerne hvert sit navn først.")
        if not set(step["columns"]).issubset(header):
            raise ValueError("CSV-filen mangler en af de valgte kolonner.")
        output = io.StringIO(newline="")
        writer = csv.DictWriter(output, fieldnames=step["columns"], extrasaction="ignore")
        writer.writeheader()
        for row in reader:
            writer.writerow(row)
            if output.tell() > MAX_BYTES:
                raise ValueError("CSV-resultatet er for stort.")
        result[name] = output.getvalue().encode("utf-8")
    if not matched:
        raise ValueError("Vælg en CSV-fil til dette værktøj.")
    return result


def execute(spec, files):
    spec = validate_spec(spec)
    if not isinstance(files, dict) or not 1 <= len(files) <= 20:
        raise ValueError("Vælg én til 20 filer.")
    if any(basename(name) != name or not isinstance(data, bytes) for name, data in files.items()):
        raise ValueError("En fil er ugyldig.")
    if sum(map(len, files.values())) > MAX_BYTES:
        raise ValueError("Vælg filer på tilsammen højst 24 MB.")
    files = dict(files)
    for step in spec["steps"]:
        kind = step["type"]
        if kind == "image_resize":
            files = _images(files, step)
        elif kind == "rename":
            files = {f'{step["prefix"]}-{step["start"] + i:03d}{PurePosixPath(name).suffix}': data
                     for i, (name, data) in enumerate(files.items())}
        elif kind == "csv_columns":
            files = _columns(files, step)
        elif kind == "text_replace":
            updated = {}
            matched = False
            for name, data in files.items():
                if PurePosixPath(name).suffix.lower() in {".txt", ".md", ".csv", ".json"}:
                    matched = True
                    value = data.decode("utf-8-sig")
                    projected = len(value) + value.count(step["find"]) * (len(step["replace"]) - len(step["find"]))
                    if projected > MAX_BYTES * 2:
                        raise ValueError("Tekstresultatet er for stort.")
                    data = value.replace(step["find"], step["replace"]).encode("utf-8")
                updated[name] = data
            if not matched:
                raise ValueError("Vælg en tekstfil til dette værktøj.")
            files = updated
        elif kind == "zip":
            output = io.BytesIO()
            with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for name, data in files.items():
                    archive.writestr(basename(name), data)
            files = {step["name"]: output.getvalue()}
        if sum(map(len, files.values())) > MAX_BYTES * 2:
            raise ValueError("Resultatet er for stort.")
    return files


def program(spec):
    encoded = json.dumps(validate_spec(spec), ensure_ascii=False)
    return ("import json\nfrom sweatcaster.agent_tool_runtime import execute\n"
            f"SPEC = json.loads({encoded!r})\n\n"
            "def run(files):\n    return execute(SPEC, files)\n")


def self_test(spec):
    """Run the actual generated program on throw-away files and inspect its output."""
    from PIL import Image

    source = program(spec)
    namespace = {}
    exec(compile(source, "<FadedAI generated tool>", "exec"), namespace)
    image = io.BytesIO()
    Image.new("RGB", (800, 600), (40, 180, 150)).save(image, "PNG")
    columns = list(dict.fromkeys(col for step in spec["steps"] if step["type"] == "csv_columns" for col in step["columns"]))
    table = io.StringIO()
    writer = csv.writer(table)
    writer.writerow(columns + ["fadedai_extra"])
    writer.writerow(["prøve" for _ in columns] + ["udelades"])
    find = next((step["find"] for step in spec["steps"] if step["type"] == "text_replace"), "FadedAI")
    files = {"billede.png": image.getvalue(), "tabel.csv": table.getvalue().encode(), "note.txt": (find + "\n").encode()}
    original = dict(files)
    output = namespace["run"](files)
    assert files == original, "Originalerne blev ændret."
    assert output and all(data for data in output.values()), "Resultatet mangler."
    if spec["steps"][-1]["type"] == "zip":
        with zipfile.ZipFile(io.BytesIO(next(iter(output.values())))) as archive:
            assert archive.testzip() is None
            checked = {name: archive.read(name) for name in archive.namelist()}
    else:
        checked = output
    assert len(checked) == len(files), "Der mangler filer."
    last_resize = next((step for step in reversed(spec["steps"]) if step["type"] == "image_resize"), None)
    if last_resize:
        images = [data for name, data in checked.items() if PurePosixPath(name).suffix.lower() in {".png", ".jpg"}]
        assert images
        for data in images:
            with Image.open(io.BytesIO(data)) as result:
                assert max(result.size) <= last_resize["maxEdge"]
                result.verify()
    return ["Det genererede program er kørt på prøvefiler.", "Alle prøvefiler kom med i resultatet.",
            "Originalerne er bevaret.", "Resultatfilerne kan åbnes."] + (
                ["Billedstørrelsen er kontrolleret."] if last_resize else [])
