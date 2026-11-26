"""Check that directly linked local dynamic package products are embedded in the app."""
from pathlib import Path
import re


def verify_dynamic_packages(root, rows, app_target):
    def references(row, field):
        values = re.search(r"\b" + field + r" = \(([^)]*)\)", row)
        return re.findall(r"\b[0-9A-F]{24}\b", values[1]) if values else []

    phases = [rows[key] for key in references(app_target, "buildPhases")]
    linked = [rows[key] for phase in phases if "isa = PBXFrameworksBuildPhase;" in phase
              for key in references(phase, "files")]
    embedded = [rows[key] for phase in phases if "isa = PBXCopyFilesBuildPhase;" in phase
                and "dstSubfolderSpec = 10;" in phase for key in references(phase, "files")]
    checked = []
    for key in references(app_target, "packageProductDependencies"):
        product = rows[key]
        package = re.search(r"\bpackage = ([0-9A-F]{24});", product)
        name = re.search(r'\bproductName = "?([^";]+)"?;', product)
        if not package or not name:
            continue
        local = rows[package[1]]
        path = re.search(r'\brelativePath = "?([^";]+)"?;', local)
        if "isa = XCLocalSwiftPackageReference;" not in local or not path:
            continue
        manifest = (Path(root) / path[1] / "Package.swift").read_text(encoding="utf-8")
        dynamic = re.findall(r'\.library\(\s*name:\s*"([^"]+)"\s*,\s*type:\s*\.dynamic\b', manifest)
        if name[1] not in dynamic:
            continue
        reference = f"productRef = {key};"
        assert any(reference in row for row in linked), f"Dynamic package is not linked: {name[1]}"
        assert any(reference in row for row in embedded), f"Dynamic package is not embedded in app Frameworks: {name[1]}"
        checked.append(name[1])
    return checked
