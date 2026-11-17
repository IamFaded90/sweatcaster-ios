"""Static Windows-friendly check of the delivered Xcode project wiring."""
from pathlib import Path
import json
import plistlib
import re
import xml.etree.ElementTree as ET

from verify_ipa import VILLAGE_REQUIRED

root = Path(__file__).resolve().parent
project = root / "SweatCaster.xcodeproj"
pbx = (project / "project.pbxproj").read_text(encoding="utf-8")
rows = dict(re.findall(r"^\s*([0-9A-F]{24}) = \{ (isa = .*?) \};$", pbx, re.M))
assert len(rows) >= 35
for ref in re.findall(r"\b[0-9A-F]{24}\b", pbx):
    assert ref in rows, ref
for folder in ("App", "Tests"):
    for source in (root / folder).glob("*.swift"):
        ref, = [key for key, row in rows.items()
                if f"path = {source.name};" in row or f'path = "{source.name}";' in row]
        build, = [key for key, row in rows.items() if f"fileRef = {ref};" in row]
        phase, = [row for row in rows.values() if "PBXSourcesBuildPhase" in row and build in row]
        assert phase
app_configurations = [row for row in rows.values()
                      if "isa = XCBuildConfiguration;" in row and "PRODUCT_NAME = FadedAI;" in row]
assert len(app_configurations) == 2
for configuration in app_configurations:
    assert 'LD_RUNPATH_SEARCH_PATHS = ("$(inherited)", "@executable_path/Frameworks");' in configuration

scheme = ET.parse(project / "xcshareddata/xcschemes/SweatCaster.xcscheme")
for ref in scheme.findall(".//BuildableReference"):
    assert "PBXNativeTarget" in rows[ref.attrib["BlueprintIdentifier"]]
    assert ref.attrib["ReferencedContainer"] == "container:SweatCaster.xcodeproj"
assert len(scheme.findall(".//TestableReference")) == 1
extension_targets = [row for row in rows.values() if 'productType = "com.apple.product-type.app-extension"' in row]
assert len(extension_targets) == 2
assert {row.split("name = ", 1)[1].split(";", 1)[0] for row in extension_targets} == {"FadedAIWidgets", "FadedAIShare"}
extension_source = (root / "Widgets/FadedAIWidgets.swift").read_text(encoding="utf-8")
assert extension_source.count("ActivityConfiguration(") == 1
assert "StaticConfiguration(" not in extension_source and "AppIntentConfiguration(" not in extension_source
assert {path.name for path in (root / "App").rglob("*.appiconset")} == {"AppIcon.appiconset"}

app_target, = [row for row in rows.values() if 'productType = "com.apple.product-type.application"' in row]
app_phases = [rows[phase] for phase in re.findall(r"[0-9A-F]{24}", app_target.split("buildPhases = (", 1)[1].split(")", 1)[0])]
resource_phase, = [row for row in app_phases if "isa = PBXResourcesBuildPhase" in row]
village_ref, = [key for key, row in rows.items() if "lastKnownFileType = folder;" in row and "path = Assets/Village;" in row]
village_build, = [key for key, row in rows.items() if f"fileRef = {village_ref};" in row]
assert village_build in resource_phase
extension_phase, = [row for row in app_phases if 'name = "Embed App Extensions"' in row]
for product in ("FadedAIWidgets", "FadedAIShare"):
    product_ref, = [key for key, row in rows.items() if f"path = {product}.appex;" in row]
    product_build, = [key for key, row in rows.items() if f"fileRef = {product_ref};" in row]
    assert product_build in extension_phase

sharing_info = plistlib.loads((root / "ShareExtension/Info.plist").read_bytes())["NSExtension"]
assert sharing_info["NSExtensionPointIdentifier"] == "com.apple.share-services"
assert sharing_info["NSExtensionPrincipalClass"] == "$(PRODUCT_MODULE_NAME).FadedShareViewController"
rule = sharing_info["NSExtensionAttributes"]["NSExtensionActivationRule"]
assert all(kind in rule for kind in ("public.url", "public.image", "public.plain-text", "com.adobe.pdf"))
for path in ("App/FadedAI.entitlements", "ShareExtension/ShareExtension.entitlements"):
    entitlements = plistlib.loads((root / path).read_bytes())
    assert entitlements["com.apple.security.application-groups"] == ["group.dk.sweatcaster.ios.share"]
    assert sum(f"CODE_SIGN_ENTITLEMENTS = {path};" in row for row in rows.values()) == 2
share_source, = [key for key, row in rows.items() if "path = FadedShareViewController.swift;" in row]
share_source_build, = [key for key, row in rows.items() if f"fileRef = {share_source};" in row]
share_sources, = [row for row in rows.values() if "isa = PBXSourcesBuildPhase" in row and share_source_build in row]
assert share_sources not in app_phases
village = root / "App/Assets/Village"
for path in VILLAGE_REQUIRED:
    assert (village / path).stat().st_size > 0, path
cast = root / "Dependencies/CastBrowser"
assert '.copy("AdBlockingRules.json")' in (cast / "Package.swift").read_text(encoding="utf-8")
assert json.loads((cast / "Sources/CastBrowserFeature/AdBlockingRules.json").read_text(encoding="utf-8"))

with (root / "App/Info.plist").open("rb") as file:
    info = plistlib.load(file)
assert info["NSLocalNetworkUsageDescription"]
assert "CFBundleAlternateIcons" not in repr(info)
ats = info["NSAppTransportSecurity"]
assert ats["NSAllowsLocalNetworking"] is True
assert "NSAllowsArbitraryLoads" not in ats
assert set(ats["NSExceptionDomains"]) == {"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"}
assert all(v == {"NSExceptionAllowsInsecureHTTPLoads": True} for v in ats["NSExceptionDomains"].values())
print(f"OK: {len(rows)} Xcode objects, test scheme, Village, VRM and Cast resources, embedded extensions and LAN Info.plist.")
