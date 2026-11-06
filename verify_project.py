"""Static Windows-friendly check of the delivered Xcode project wiring."""
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent
project = root / "SweatCaster.xcodeproj"
pbx = (project / "project.pbxproj").read_text(encoding="utf-8")
rows = dict(re.findall(r"^\s*([0-9A-F]{24}) = \{ (isa = .*?) \};$", pbx, re.M))
assert len(rows) >= 35
for ref in re.findall(r"\b[0-9A-F]{24}\b", pbx):
    assert ref in rows, ref
for folder in ("App", "Tests"):
    for source in (root / folder).glob("*.swift"):
        ref, = [key for key, row in rows.items() if f"path = {source.name};" in row]
        build, = [key for key, row in rows.items() if f"fileRef = {ref};" in row]
        phase, = [row for row in rows.values() if "PBXSourcesBuildPhase" in row and build in row]
        assert phase
scheme = ET.parse(project / "xcshareddata/xcschemes/SweatCaster.xcscheme")
for ref in scheme.findall(".//BuildableReference"):
    assert "PBXNativeTarget" in rows[ref.attrib["BlueprintIdentifier"]]
    assert ref.attrib["ReferencedContainer"] == "container:SweatCaster.xcodeproj"
assert len(scheme.findall(".//TestableReference")) == 1

with (root / "App/Info.plist").open("rb") as file:
    info = plistlib.load(file)
assert info["NSLocalNetworkUsageDescription"]
ats = info["NSAppTransportSecurity"]
assert ats["NSAllowsLocalNetworking"] is True
assert "NSAllowsArbitraryLoads" not in ats
assert set(ats["NSExceptionDomains"]) == {"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"}
assert all(v == {"NSExceptionAllowsInsecureHTTPLoads": True} for v in ats["NSExceptionDomains"].values())
print(f"OK: {len(rows)} Xcode objects, source references, shared test scheme and LAN Info.plist.")
