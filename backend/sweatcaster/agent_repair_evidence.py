"""Redacted iPhone/build evidence and an honest, exact-revision Mac handoff."""

from hashlib import sha256
import json
from pathlib import PurePosixPath
import re


def redact(text):
    text = re.sub(r"\b(?:sk-[A-Za-z0-9_-]{12,}|lim_[A-Za-z0-9]{20,}|nvapi-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{15,}|github_pat_[A-Za-z0-9_]{15,}|AIza[A-Za-z0-9_-]{20,})", "[nøgle fjernet]", text)
    text = re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._~+/-]{8,}=*", r"\1[fjernet]", text)
    return re.sub(r'''(?i)((?:["']?(?:api[_-]?key|access[_-]?token|password|secret|authorization)["']?)\s*[:=]\s*)(?:["'][^"'\r\n]{1,300}["']|[^\s,;}]{4,300})''', r"\1[fjernet]", text)


def evidence(raw):
    if not isinstance(raw, str) or not 1 <= len(raw.strip()) <= 48000:
        raise ValueError("Indsæt en fejlbeskrivelse eller den vigtigste del af loggen på højst 48.000 tegn.")
    report = redact(raw.strip())
    patterns = (
        ("missingFramework", "Appen mangler et indbygget bibliotek", r"Library not loaded:.*|@rpath[/\\][^\s\"']+[.]framework[/\\][^\s\"',]+", "Kontrollér biblioteket i den færdige app, dens Frameworks-mappe, signering og runpaths på Mac."),
        ("linker", "Bygningen fejler ved sammenkædning", r"Undefined symbols.*|ld: .*|linker command failed.*", "Byg den samme revision på Mac, og kontrollér det første linkerproblem."),
        ("swiftCompile", "Swift-koden kan ikke bygges", r"[^\r\n]{0,180}[.]swift:\d+:\d+: error:[^\r\n]*|SwiftCompile[^\r\n]*", "Kør den samme Xcode-bygning og ret den første dokumenterede compilerfejl."),
        ("memory", "iPhone har rapporteret hukommelsespres", r"JetsamEvent[^\r\n]*|per-process-limit[^\r\n]*|memory-pressure[^\r\n]*", "Gentag den samme handling på iPhone og mål hukommelsen; en simulator alene beviser ikke, at problemet er løst."),
        ("watchdog", "Appen blev stoppet under opstart eller arbejde", r"0x8badf00d[^\r\n]*|watchdog[^\r\n]*|FRONTBOARD[^\r\n]*", "Gentag opstart/handlingen på Mac og iPhone og undersøg, hvad der blokerer."),
    )
    for kind, title, pattern, next_check in patterns:
        matches = re.findall(pattern, report, re.I)
        if matches:
            break
    else:
        kind, title, matches, next_check = "reported", "Fejlbeskrivelsen er modtaget", [], "Fejlen skal først kunne gentages med en konkret kontrol."
    def field(pattern):
        match = re.search(pattern, report, re.I)
        return match.group(1)[:120] if match else None
    return {"kind": kind, "title": title, "report": report, "lines": [line[:500] for line in matches[:4]],
            "build": field(r'''["']?(?:build_version|CFBundleVersion)["']?\s*:\s*["']?([A-Za-z0-9._-]+)'''),
            "incident": field(r'''["']?incident(?:_id)?["']?\s*:\s*["']?([A-Fa-f0-9-]{36})'''),
            "nextCheck": next_check, "redacted": report != raw.strip(),
            "digest": sha256(report.encode()).hexdigest()}


def mac_handoff(repository, revision, paths, facts, *, approved=None, approved_branch=None, patch="", test_digest=None):
    projects = sorted({path.removesuffix("/project.pbxproj") for path in paths if path.endswith(".xcodeproj/project.pbxproj")})
    schemes = sorted({PurePosixPath(path).stem for path in paths if path.endswith(".xcscheme")})
    project = projects[0] if len(projects) == 1 else None
    scheme = schemes[0] if len(schemes) == 1 else PurePosixPath(project).stem if project else None
    steps = ["Hent projektets dokumenterede grundrevision: " + revision,
             "Arbejd i en ny kopi. Brug den vedlagte ændring, hvis den er godkendt.",
             "Gem den fulde byggelog, fejlkoder og navnet på den revision, der faktisk blev bygget."]
    commands = []
    if project and scheme and re.fullmatch(r"[A-Za-z0-9_./ -]+", project) and re.fullmatch(r"[A-Za-z0-9_. -]+", scheme):
        commands = [["xcodebuild", "-list", "-project", project],
                    ["xcodebuild", "-project", project, "-scheme", scheme, "-configuration", "Debug",
                     "-sdk", "iphonesimulator", "-derivedDataPath", "RepairDerivedData", "CODE_SIGNING_ALLOWED=NO", "build"]]
        steps.append("Kør de vedlagte kommandoer på Mac. Simulatorbygningen skal bestå, før test på iPhone.")
    elif project is None:
        steps.append("Intet entydigt Xcode-projekt blev fundet. Vælg projekt og scheme på Mac; ingen IPA er bygget.")
    steps.append(facts["nextCheck"])
    if facts["kind"] == "missingFramework":
        steps.append("Åbn den producerede app/IPA, og kontrollér, at det manglende framework faktisk er indlejret og kan indlæses ved opstart.")
    packet = {"repository": repository, "baseRevision": revision, "approvedRevision": approved,
              "project": project, "scheme": scheme, "commands": commands, "steps": steps,
              "evidenceDigest": facts["digest"], "patchDigest": sha256(patch.encode()).hexdigest(),
              "testDigest": test_digest, "state": "waitingForMac", "ipaAvailable": False,
              "detail": "Ingen Apple-bygning er kørt her. En Mac skal bygge og returnere den faktiske byggelog. Ingen ændring er sendt til GitHub."}
    packet["sourceCommands"] = []
    if approved and approved_branch:
        packet["sourceCommands"] = [["git", "bundle", "verify", "approved-change.bundle"],
                                    ["git", "fetch", "approved-change.bundle", "refs/heads/" + approved_branch],
                                    ["git", "checkout", "--detach", approved]]
        steps.insert(1, "Når grundrevisionen findes lokalt på Mac, importér approved-change.bundle med de vedlagte Git-kommandoer. Det giver den præcise godkendte revision uden push.")
    packet["id"] = sha256(json.dumps(packet, sort_keys=True).encode()).hexdigest()
    return packet
