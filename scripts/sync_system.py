#!/usr/bin/env python3
"""Reconcile one downloaded ROM set into the RomM library using hardlinks.

The library (``roms/<slug>/``) holds hardlinks to the files in
``downloads/complete/-games/<system>/``.  When a set is updated, the download
folder may contain new inodes, renamed files, or removed files.  This tool
computes a deduplicated target selection and emits a shell script that makes
the library match it without copying data or creating duplicates.

Usage:
    python3 sync_system.py "<download folder name>" [--explain]

The script is written to ``/tmp/roms/sync_<slug>.sh`` and must be executed
as uid 568 (the library owner), e.g.::

    docker run --rm -u 568:568 \\
        -v /mnt/bertha/medias:/mnt/bertha/medias \\
        -v /tmp/roms:/work:ro busybox:stable sh /work/sync_<slug>.sh
"""

from __future__ import annotations

import argparse
import re
import shlex
import tempfile
import unicodedata
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Literal

if TYPE_CHECKING:
    from collections.abc import Iterable

DOWNLOADS_ROOT = Path("/mnt/bertha/medias/downloads/complete/-games")
LIBRARY_ROOT = Path("/mnt/bertha/medias/romm/roms")
SCRIPT_DIR = Path(tempfile.gettempdir()) / "roms"

# How a download folder is laid out on disk (see SystemSpec.mode):
#   flat       - one file per game at the top level
#   multi      - multi-disc/multi-part games; parts may need grouping per game
#   x68k       - one subfolder per game, each holding several disk images
#   fairchild  - games nested in ChaFRen/ChaFRen/ and only *.chf are games
Mode = Literal["flat", "multi", "x68k", "fairchild"]

# ---------------------------------------------------------------------------
# Region handling
# ---------------------------------------------------------------------------

REGION_ALIASES = {
    "world": "world",
    "usa": "usa",
    "us": "usa",
    "europe": "europe",
    "uk": "europe",
    "eu": "europe",
    "japan": "japan",
    "jp": "japan",
}

KNOWN_REGION_TOKENS = frozenset(
    {
        "world",
        "usa",
        "us",
        "europe",
        "uk",
        "eu",
        "japan",
        "jp",
        "asia",
        "korea",
        "china",
        "brazil",
        "australia",
        "canada",
        "france",
        "germany",
        "spain",
        "italy",
        "netherlands",
        "sweden",
        "russia",
        "taiwan",
        "mexico",
        "argentina",
        "portugal",
        "poland",
        "norway",
        "denmark",
        "finland",
        "hungary",
        "czech",
        "hong kong",
        "new zealand",
    }
)

REGION_PRIORITY: dict[str, tuple[str, ...]] = {
    "us": ("world", "usa", "europe", "japan"),
    "eu": ("world", "europe", "usa", "japan"),
    "jp": ("world", "japan", "usa", "europe"),
}

EU_SYSTEMS = frozenset(
    {
        "amiga",
        "atari-st",
        "c64",
        "c-plus-4",
        "vic-20",
        "zxs",
        "acorn-archimedes",
        "bbcmicro",
        "sinclair-ql",
        "sam-coupe",
        "oric",
        "thomson-mo5",
        "atari8bit",
        "atari800",
        "memotech-mtx",
        "ti-994a",
        "trs-80-color-computer",
    }
)

JP_SYSTEMS = frozenset(
    {
        "sharp-x68000",
        "x1",
        "sharp-mz-2200",
        "hitachi-s1",
        "msx",
        "msx2",
        "pc-9800-series",
        "pc-fx",
        "tg16",
        "supergrafx",
        "wonderswan",
        "wonderswan-color",
        "neo-geo-pocket",
        "neo-geo-pocket-color",
    }
)

# ---------------------------------------------------------------------------
# Filesystem / naming rules
# ---------------------------------------------------------------------------

JUNK_EXTENSIONS = frozenset(
    {
        "txt",
        "log",
        "dat",
        "jpg",
        "jpeg",
        "png",
        "gif",
        "pdf",
        "sha1",
        "md5",
        "sfv",
        "xml",
        "nfo",
        "url",
        "ini",
        "cfg",
        "sav",
        "sh",
        "bat",
        "cmd",
        "diz",
        "doc",
    }
)

NON_GAME_PATTERN = re.compile(
    r"\(\s*(program|applications?|application systems|utilities?|utility|"
    r"productivity|coverdisk[^)]*|magazine|diskmag|bios|firmware|driver)\b",
    re.IGNORECASE,
)
TAG_PATTERN = re.compile(r"\(([^)]*)\)|\[([^\]]*)\]")
PART_PATTERN = re.compile(
    r"^\s*(disk|diskette|side|tape)s?\s*([0-9]+|[a-z])", re.IGNORECASE
)
BAD_DUMP_PATTERN = re.compile(
    r"^\(b\d*\)$|^\(h\d*\)$|^\(t\d*\)$|^\(o\d*\)$|^\(u\)$|^\(f\d*\)$",
    re.IGNORECASE,
)
DEMO_PATTERN = re.compile(r"demo|proto|beta|alpha|sample|preview|unl\b", re.IGNORECASE)
ALT_PATTERN = re.compile(r"^\s*alt", re.IGNORECASE)
VERSION_PATTERN = re.compile(r"(?:rev|v|r)\s*([0-9]+(?:\.[0-9]+)?)", re.IGNORECASE)


@dataclass(frozen=True)
class SystemSpec:
    """How a download folder maps into the library."""

    slug: str
    mode: Mode
    subdir: str | None = None


SYSTEMS: dict[str, SystemSpec] = {
    "Acorn - Archimedes": SystemSpec("acorn-archimedes", "multi"),
    "Apple - Bandai - Pippin": SystemSpec("apple-pippin", "flat"),
    "Apple - II (A2R)": SystemSpec("appleii", "multi"),
    "Apple - I (Tapes)": SystemSpec("apple", "flat"),
    "Arduboy Inc - Arduboy": SystemSpec("arduboy", "flat"),
    "Atari - 2600": SystemSpec("atari2600", "flat"),
    "Atari - 5200": SystemSpec("atari5200", "flat"),
    "Atari - 7800 (BIN)": SystemSpec("atari7800", "flat"),
    "Atari - 8-bit Family": SystemSpec("atari8bit", "multi"),
    "Atari - Jaguar (J64)": SystemSpec("jaguar", "flat"),
    "Atari - Lynx (LYX)": SystemSpec("lynx", "flat"),
    "Atari ST - Games": SystemSpec("atari-st", "multi", "roms"),
    "Bally - Astrocade": SystemSpec("astrocade", "flat"),
    "Bandai - WonderSwan": SystemSpec("wonderswan", "flat"),
    "Bandai - WonderSwan Color": SystemSpec("wonderswan-color", "flat"),
    "Benesse - Pocket Challenge V2": SystemSpec("pocket-challenge-v2", "flat"),
    "Benesse - Pocket Challenge W": SystemSpec("pocket-challenge-w", "flat"),
    "Bit Corporation - Gamate": SystemSpec("gamate", "flat"),
    "Casio - Loopy (BigEndian)": SystemSpec("casio-loopy", "flat"),
    "Casio - PV-1000": SystemSpec("casio-pv-1000", "flat"),
    "Coleco - ColecoVision": SystemSpec("colecovision", "flat"),
    "Commodore - Amiga": SystemSpec("amiga", "flat"),
    "Commodore - Commodore 64": SystemSpec("c64", "flat"),
    "Commodore - Plus-4": SystemSpec("c-plus-4", "flat"),
    "Commodore - VIC-20": SystemSpec("vic-20", "flat"),
    "Emerson - Arcadia 2001": SystemSpec("arcadia-2001", "flat"),
    "Entex - Adventure Vision": SystemSpec("adventure-vision", "flat"),
    "Epoch - Game Pocket Computer": SystemSpec("epoch-game-pocket-computer", "flat"),
    "Epoch - Super Cassette Vision": SystemSpec("epoch-super-cassette-vision", "flat"),
    "Fairchild Channel F - GoodChaF  v3.13 - Complete": SystemSpec(
        "fairchild-channel-f", "fairchild", "ChaFRen/ChaFRen"
    ),
    "Funtech - Super Acan": SystemSpec("super-acan", "flat"),
    "GamePark - GP32": SystemSpec("gp32", "flat"),
    "GCE - Vectrex": SystemSpec("vectrex", "flat"),
    "GoodCoCo 3.21 (-17)_GoodMerged_torrent7zipped": SystemSpec(
        "trs-80-color-computer", "flat"
    ),
    "Hartung - Game Master": SystemSpec("hartung", "flat"),
    "Hitachi - S1 (Waveform)": SystemSpec("hitachi-s1", "multi"),
    "Interton - VC 4000": SystemSpec("interton-vc-4000", "flat"),
    "LeapFrog - Explorer": SystemSpec("leapfrog-explorer", "flat"),
    "Magnavox - Odyssey 2": SystemSpec("odyssey-2", "flat"),
    "Mattel - Hyperscan": SystemSpec("hyperscan", "flat"),
    "Mattel - Intellivision": SystemSpec("intellivision", "flat"),
    "Memotech MTX": SystemSpec("memotech-mtx", "flat"),
    "Microsoft - MSX": SystemSpec("msx", "flat"),
    "Microsoft - MSX2": SystemSpec("msx2", "flat"),
    "Miles Gordon Sam Coupe": SystemSpec("sam-coupe", "flat"),
    "NEC - PC-98": SystemSpec("pc-9800-series", "flat"),
    "NEC - PC Engine SuperGrafx": SystemSpec("supergrafx", "flat"),
    "NEC - PC Engine - TurboGrafx-16": SystemSpec("tg16", "flat"),
    "NEC - PC-FX & PC-FXGA": SystemSpec("pc-fx", "flat"),
    "Nintendo - Game Boy": SystemSpec("gb", "flat"),
    "Nintendo - Game Boy Advance": SystemSpec("gba", "flat"),
    "Nintendo - Game Boy Color": SystemSpec("gbc", "flat"),
    "Nintendo - Game & Watch": SystemSpec("g-and-w", "flat"),
    "Nintendo - Nintendo 64 (BigEndian)": SystemSpec("n64", "flat"),
    "Nintendo - Nintendo Entertainment System (Headered)": SystemSpec("nes", "flat"),
    "Nintendo - Pokemon Mini": SystemSpec("pokemon-mini", "flat"),
    "Nintendo - Super Nintendo Entertainment System": SystemSpec("snes", "flat"),
    "Nintendo - Virtual Boy": SystemSpec("virtualboy", "flat"),
    "Nokia - N-Gage": SystemSpec("ngage", "flat"),
    "Ouya - Ouya": SystemSpec("ouya", "flat"),
    "Palm OS": SystemSpec("palm-os", "flat"),
    "Philips - Videopac+": SystemSpec("videopac-g7400", "flat"),
    "RCA - Studio II": SystemSpec("rca-studio-ii", "flat"),
    "Sega - Beena": SystemSpec("beena", "flat"),
    "Sega - Game Gear": SystemSpec("gamegear", "flat"),
    "Sega - Master System - Mark III": SystemSpec("sms", "flat"),
    "Sega - Mega Drive - Genesis": SystemSpec("genesis", "flat"),
    "Sega - PICO": SystemSpec("sega-pico", "flat"),
    "Sega - SG-1000": SystemSpec("sg1000", "flat"),
    "Sharp - MZ-2200 (Waveform)": SystemSpec("sharp-mz-2200", "flat"),
    "Sharp - X1 (Waveform)": SystemSpec("x1", "flat"),
    "Sharp X68000": SystemSpec("sharp-x68000", "x68k"),
    "Sinclair - ZX Spectrum +3": SystemSpec("zxs", "flat"),
    "SNK - Neo Geo CD": SystemSpec("neo-geo-cd", "flat"),
    "SNK - NeoGeo Pocket": SystemSpec("neo-geo-pocket", "flat"),
    "SNK - NeoGeo Pocket Color": SystemSpec("neo-geo-pocket-color", "flat"),
    "Tangerine Oric": SystemSpec("oric", "flat"),
    "Texas Instruments - TI-99-4A (A2R)": SystemSpec("ti-994a", "flat"),
    "Thomson MO5": SystemSpec("thomson-mo5", "flat"),
    "Tiger - Game.com": SystemSpec("game-dot-com", "flat"),
    "Tiger - Gizmondo": SystemSpec("gizmondo", "flat"),
    "Toshiba - Visicom": SystemSpec("vis", "flat"),
    "VM Labs - NUON (Digital)": SystemSpec("nuon", "flat"),
    "VTech - CreatiVision": SystemSpec("creativision", "flat"),
    "VTech - V.Smile": SystemSpec("vsmile", "flat"),
    "Watara - Supervision": SystemSpec("supervision", "flat"),
    "Welback - Mega Duck": SystemSpec("mega-duck-slash-cougar-boy", "flat"),
    "ZAPiT Games - Game Wave Family Entertainment System": SystemSpec(
        "game-wave", "flat"
    ),
    "Zeebo - Zeebo": SystemSpec("zeebo", "flat"),
}


@dataclass(frozen=True)
class SourceFile:
    """A candidate file from the download folder."""

    name: str
    path: Path
    folder_hint: str | None = None


@dataclass
class Plan:
    """Desired changes to apply to the library."""

    slug: str
    mode: Mode
    keep: int = 0
    relink: list[str] = field(default_factory=list)
    add: list[str] = field(default_factory=list)
    remove: list[str] = field(default_factory=list)
    empty_dirs: list[str] = field(default_factory=list)
    desired: dict[str, SourceFile] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Naming helpers
# ---------------------------------------------------------------------------


def is_bios_file(name: str) -> bool:
    lowered = name.lower()
    return lowered.startswith("[bios]") or lowered in {"bios.7z", "bios.zip"}


def is_rom_file(name: str) -> bool:
    """Return True if ``name`` looks like a game file worth importing."""
    if name.startswith("."):
        return False
    if is_bios_file(name):
        return False
    extension = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    if extension in JUNK_EXTENSIONS:
        return False
    return NON_GAME_PATTERN.search(name) is None


def stem(name: str) -> str:
    return Path(name).stem


def title_text(name: str) -> str:
    """Raw title: the text before the first parenthetical tag."""
    return re.split(r"\s+\(", stem(name), maxsplit=1)[0].strip()


def group_key(name: str) -> str:
    """Generic key for grouping versions of the same game.

    Handles common catalogue spelling drift without per-game rules: casing,
    ``&`` vs ``+`` (bundle naming), spaces/hyphens/underscores, and minor
    punctuation.  ``+`` is preserved so genuinely different products such as
    "Card e-Reader" and "Card e-Reader+" stay separate.
    """
    text = unicodedata.normalize("NFKC", title_text(name)).casefold()
    text = text.replace("&", "+")
    text = re.sub(r"[\s\-_]+", "", text)
    return re.sub(r"[!.,'\"`]+", "", text)


def tags_of(text: str) -> list[str]:
    return [
        match.group(1) if match.group(1) is not None else f"({match.group(2)})"
        for match in TAG_PATTERN.finditer(text)
    ]


def part_keys(text: str) -> list[tuple[str, str]]:
    """Extract (kind, number) pairs such as ('d', '1') or ('s', 'a')."""
    keys: list[tuple[str, str]] = []
    for tag in re.findall(r"\(([^)]*)\)", text):
        match = PART_PATTERN.match(tag)
        if match:
            keys.append((match.group(1).lower()[0], match.group(2).lower()))
    return keys


def region_priority(slug: str) -> tuple[str, ...]:
    if slug in JP_SYSTEMS:
        return REGION_PRIORITY["jp"]
    if slug in EU_SYSTEMS:
        return REGION_PRIORITY["eu"]
    return REGION_PRIORITY["us"]


def region_score(text: str, slug: str) -> int:
    regions: set[str] = set()
    for tag in re.findall(r"\(([^)]*)\)", text):
        tokens = [token.strip().lower() for token in tag.split(",")]
        if tokens and all(token in KNOWN_REGION_TOKENS for token in tokens):
            regions.update(REGION_ALIASES.get(token, token) for token in tokens)
    if not regions:
        return 0
    priority = region_priority(slug)
    best = max(
        100 - 20 * priority.index(region) if region in priority else 10
        for region in regions
    )
    return best + 3 * (len(regions) - 1)


def main_score(name: str, slug: str) -> float:
    """Score a candidate; higher is better.

    Prefer releases over demos/protos, good dumps, then region, then a newer
    revision, then fewer Alt versions and fewer tags.
    """
    text = stem(name)
    tags = tags_of(text)
    joined = " ".join(tags)
    score = 0.0

    if DEMO_PATTERN.search(joined):
        score -= 10_000
    if BAD_DUMP_PATTERN.search("".join(tags)):
        score -= 2_000

    score += region_score(text, slug)

    versions = VERSION_PATTERN.findall(joined)
    if versions:
        score += min(max(float(value) for value in versions), 50) * 10

    score -= 40 * sum(1 for tag in tags if ALT_PATTERN.match(tag))
    score -= 5 * len(tags)
    return score


def common_suffix(chosen: Iterable[SourceFile]) -> str:
    """Parenthesised tags shared by every chosen disc (excludes part/alt tags)."""
    names = [item.name for item in chosen]

    def meaningful_tags(name: str) -> list[str]:
        return [
            tag
            for tag in tags_of(stem(name))
            if not PART_PATTERN.match(tag.strip("()"))
            and not ALT_PATTERN.match(tag)
            and not tag.startswith("(")
        ]

    shared = set.intersection(*(set(meaningful_tags(n)) for n in names))
    ordered: list[str] = []
    for tag in tags_of(stem(names[0])):
        if tag in shared and tag not in ordered:
            ordered.append(tag)
    return "".join(f" ({tag})" for tag in ordered)


# ---------------------------------------------------------------------------
# Source discovery and desired selection
# ---------------------------------------------------------------------------


def _collect_x68k(root: Path) -> list[SourceFile]:
    files: list[SourceFile] = []
    for game_dir in sorted(root.iterdir()):
        if not game_dir.is_dir() or game_dir.name == "[BIOS]":
            continue
        files.extend(
            SourceFile(path.name, path, game_dir.name)
            for path in sorted(game_dir.iterdir())
            if path.is_file() and is_rom_file(path.name)
        )
    return files


def _collect_flat(root: Path, spec: SystemSpec) -> list[SourceFile]:
    source_dir = root / spec.subdir if spec.subdir else root
    return [
        SourceFile(path.name, path)
        for path in sorted(source_dir.iterdir())
        if path.is_file()
        and (
            path.name.lower().endswith(".chf")
            if spec.mode == "fairchild"
            else is_rom_file(path.name)
        )
    ]


def collect_source(spec: SystemSpec, system_name: str) -> list[SourceFile]:
    root = DOWNLOADS_ROOT / system_name
    if spec.mode == "x68k":
        return _collect_x68k(root)
    return _collect_flat(root, spec)


def _part_numbers(entries: list[SourceFile]) -> dict[str, set[str]]:
    parts: dict[str, set[str]] = defaultdict(set)
    for entry in entries:
        for kind, number in part_keys(stem(entry.name)):
            parts[kind].add(number)
    return parts


def _select_multi_part(entries: list[SourceFile], slug: str) -> list[SourceFile]:
    parts = _part_numbers(entries)
    chosen: list[SourceFile] = []
    for kind, numbers in parts.items():
        for number in sorted(numbers):
            candidates = [
                item for item in entries if (kind, number) in part_keys(stem(item.name))
            ]
            if candidates:
                chosen.append(
                    max(candidates, key=lambda item: main_score(item.name, slug))
                )

    non_part = [item for item in entries if not part_keys(stem(item.name))]
    if non_part:
        chosen.append(max(non_part, key=lambda item: main_score(item.name, slug)))

    seen: set[str] = set()
    return [item for item in chosen if not (item.name in seen or seen.add(item.name))]


def deduplicated_selection(
    sources: list[SourceFile], slug: str
) -> dict[str, SourceFile]:
    """Pick the main version per title, grouping multi-disc parts into folders."""
    by_title: dict[str, list[SourceFile]] = defaultdict(list)
    for source in sources:
        by_title[group_key(source.name)].append(source)

    desired: dict[str, SourceFile] = {}
    for entries in by_title.values():
        parts = _part_numbers(entries)
        if all(len(numbers) <= 1 for numbers in parts.values()):
            best = max(entries, key=lambda item: main_score(item.name, slug))
            desired[best.name] = best
            continue

        unique_chosen = _select_multi_part(entries, slug)
        folder = re.split(r"\s+\(", stem(unique_chosen[0].name), maxsplit=1)[
            0
        ] + common_suffix(unique_chosen)
        for item in unique_chosen:
            desired[item.name] = SourceFile(item.name, item.path, folder)

    return desired


def desired_selection(
    sources: list[SourceFile], spec: SystemSpec
) -> dict[str, SourceFile]:
    if spec.mode in ("x68k", "fairchild"):
        return {source.name: source for source in sources}
    return deduplicated_selection(sources, spec.slug)


# ---------------------------------------------------------------------------
# Library scan and planning
# ---------------------------------------------------------------------------


def scan_library(slug: str) -> tuple[dict[str, Path], dict[str, list[str]]]:
    root = LIBRARY_ROOT / slug
    files: dict[str, Path] = {}
    directories: dict[str, list[str]] = {}

    for entry in sorted(root.iterdir()):
        if entry.is_dir():
            contents: list[str] = []
            for child in sorted(entry.iterdir()):
                if child.is_file():
                    files[child.name] = child
                    contents.append(child.name)
            directories[entry.name] = contents
        elif entry.is_file():
            files[entry.name] = entry

    return files, directories


def same_inode(first: Path, second: Path) -> bool:
    a = first.stat()
    b = second.stat()
    return (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino)


def build_plan(system_name: str, spec: SystemSpec) -> Plan:
    sources = collect_source(spec, system_name)
    desired = desired_selection(sources, spec)
    source_names = {source.name for source in sources}
    existing, directories = scan_library(spec.slug)

    plan = Plan(slug=spec.slug, mode=spec.mode, desired=desired)

    def differs(name: str) -> bool:
        source = (
            desired[name].path
            if name in desired
            else next(s.path for s in sources if s.name == name)
        )
        return not same_inode(source, existing[name])

    if spec.mode in ("multi", "x68k"):
        # Conservative: never drop a file that still exists in the source, since
        # it may be a disc of a multi-file game.  Only update inodes, remove
        # names that disappeared, and add genuinely new titles.
        plan.remove = [name for name in existing if name not in source_names]
        plan.relink = [
            name for name in existing if name in source_names and differs(name)
        ]
        kept_titles = {group_key(name) for name in existing if name in source_names}
        plan.add = [
            name
            for name in desired
            if name not in existing and group_key(name) not in kept_titles
        ]
        plan.keep = sum(1 for name in existing if name in source_names)
    else:
        plan.remove = [name for name in existing if name not in desired]
        plan.relink = [name for name in desired if name in existing and differs(name)]
        plan.add = [name for name in desired if name not in existing]
        plan.keep = len(desired) - len(plan.add)

    if spec.mode in ("multi", "x68k"):
        plan.empty_dirs = [
            directory
            for directory, contents in directories.items()
            if contents and all(name in plan.remove for name in contents)
        ]
    else:
        plan.empty_dirs = [
            directory
            for directory, contents in directories.items()
            if contents and all(name not in desired for name in contents)
        ]

    return plan


# ---------------------------------------------------------------------------
# Script rendering
# ---------------------------------------------------------------------------


def quote(path: Path | str) -> str:
    return shlex.quote(str(path))


def render_script(plan: Plan, system_name: str) -> str:
    library = LIBRARY_ROOT / plan.slug
    lines = [
        "#!/bin/sh",
        "set -eu",
        f"# sync '{system_name}' -> {plan.slug}",
        (
            f"# keep={plan.keep} relink={len(plan.relink)} "
            f"add={len(plan.add)} remove={len(plan.remove)}"
        ),
    ]

    # Create every destination directory exactly once.
    create_dirs: set[Path] = set()
    for name in plan.add + plan.relink:
        source = plan.desired[name]
        destination = (
            library / source.folder_hint / name
            if source.folder_hint
            else library / name
        )
        create_dirs.add(destination.parent)
    if create_dirs:
        lines.append(
            "mkdir -p " + " ".join(quote(path) for path in sorted(create_dirs))
        )

    lines.extend(f"rm -f {quote(library / name)}" for name in plan.remove)
    lines.extend(
        f"rm -rf {quote(library / directory)}" for directory in plan.empty_dirs
    )

    for name in plan.add + plan.relink:
        source = plan.desired[name]
        destination = (
            library / source.folder_hint / name
            if source.folder_hint
            else library / name
        )
        if name in plan.relink:
            lines.append(f"rm -f {quote(destination)}")
        lines.append(f"ln {quote(source.path)} {quote(destination)}")

    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def explain(plan: Plan) -> None:
    """Print why each removed entry is removed (renamed/replaced vs missing)."""
    for name in plan.remove:
        normalized = group_key(name)
        replacements = sorted(
            other
            for other in plan.desired
            if other != name and group_key(other) == normalized
        )
        status = "present-in-source" if replacements else "no same-title match"
        print(f"- {name}")
        print(f"    {status}; replacement(s): {replacements or 'NONE'}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("system", nargs="?", help="download folder name under -games/")
    parser.add_argument("--explain", action="store_true", help="explain each removal")
    parser.add_argument(
        "--list-systems", action="store_true", help="list accepted system names"
    )
    args = parser.parse_args()

    if args.list_systems or not args.system:
        for name in sorted(SYSTEMS):
            print(name)
        return

    if args.system not in SYSTEMS:
        parser.error(
            f"unknown system {args.system!r}; use --list-systems to see accepted names"
        )

    spec = SYSTEMS[args.system]
    plan = build_plan(args.system, spec)

    print(f"system: {args.system} -> {plan.slug} (mode={plan.mode})")
    print(
        f"keep={plan.keep} relink={len(plan.relink)} "
        f"add={len(plan.add)} remove={len(plan.remove)} "
        f"empty_dirs={len(plan.empty_dirs)}"
    )

    if args.explain:
        explain(plan)
        return

    SCRIPT_DIR.mkdir(parents=True, exist_ok=True)
    script_path = SCRIPT_DIR / f"sync_{plan.slug}.sh"
    script_path.write_text(render_script(plan, args.system))
    print(f"wrote {script_path}")


if __name__ == "__main__":
    main()
