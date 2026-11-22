"""A single Office conversion, using stdin/stdout only in the isolated MarkItDown runtime."""

import io
import re
import sys
from zipfile import ZipFile

from defusedxml import ElementTree as XML
from markitdown import StreamInfo
from markitdown.converters import DocxConverter, PptxConverter, XlsxConverter

FORMATS = {
    "docx": ("word/document.xml", DocxConverter),
    "pptx": ("ppt/presentation.xml", PptxConverter),
    "xlsx": ("xl/workbook.xml", XlsxConverter),
}


def check_sheet(xml: bytes) -> None:
    # Sparse worksheets can otherwise expand to enormous rectangular Markdown tables.
    max_row = max_col = 0
    for _, cell in XML.iterparse(io.BytesIO(xml), events=("end",)):
        if cell.tag.endswith("}c"):
            address = re.fullmatch(r"([A-Z]{1,3})([1-9][0-9]{0,6})", cell.get("r", ""))
            if not address:
                raise ValueError("Invalid worksheet")
            column = 0
            for char in address[1]:
                column = column * 26 + ord(char) - ord("A") + 1
            max_row = max(max_row, int(address[2]))
            max_col = max(max_col, column)
            if max_row * max_col > 120_000:
                raise OverflowError
        cell.clear()


def convert(data: bytes, kind: str) -> str:
    main, converter = FORMATS[kind]
    stream = io.BytesIO(data)
    with ZipFile(stream) as package:
        members = package.infolist()
        names = set(package.namelist())
        if main not in names or "[Content_Types].xml" not in names or len(names) != len(members):
            raise ValueError("Invalid Office file")
        if len(members) > 1500 or sum(part.file_size for part in members) > 32_000_000:
            raise OverflowError
        for item in members:
            if item.filename.endswith(".rels"):
                for rel in XML.fromstring(package.read(item)):
                    if rel.get("TargetMode", "").lower() == "external" and not rel.get("Type", "").endswith("/hyperlink"):
                        raise ValueError("External embedded object")
            elif kind == "xlsx" and re.fullmatch(r"xl/worksheets/[^/]+\.xml", item.filename):
                check_sheet(package.read(item))
    stream.seek(0)
    text = converter().convert(stream, StreamInfo(extension="." + kind)).text_content.strip()
    if not text:
        raise ValueError("Empty document")
    if len(text) > 24_000:
        raise OverflowError
    return text


if __name__ == "__main__":
    try:
        payload = sys.stdin.buffer.read(8_000_001)
        if len(payload) > 8_000_000:
            raise OverflowError
        sys.stdout.buffer.write(convert(payload, sys.argv[1]).encode("utf-8"))
    except OverflowError:
        sys.exit(3)
    except Exception:
        sys.exit(2)
