#!/usr/bin/env python3
"""Check the runtime DLL dependency graph of a packaged Windows x64 libmpv build.

This is a small, standard-library-only PE32+ reader. It parses import and
delay-load tables without loading Windows binaries, so it can also run on Linux.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from collections import deque
from pathlib import Path
from typing import Any


# Windows 10/11 x64 inbox DLLs considered safe to leave unbundled. Extend here
# when a new Windows base dependency is intentionally accepted.
WINDOWS_DLLS = frozenset("""
    kernel32 user32 gdi32 advapi32 shell32 ole32 oleaut32 ws2_32 crypt32
    secur32 bcrypt dxgi d3d11 d3dcompiler_47 dwmapi shlwapi winmm imm32
    setupapi cfgmgr32 avrt ntdll msvcrt ucrtbase version powrprof uxtheme
    dwrite d2d1 comdlg32 gdiplus dxva2 mmdevapi propsys iphlpapi normaliz
    wldap32 dbghelp hid xinput1_4 windowscodecs rpcrt4 sspicli userenv
    netapi32 winhttp wininet urlmon dnsapi ncrypt wintrust dsound msacm32
    dcomp d3d9 opengl32
""".split())

MSVC_PREFIXES = ("vcruntime140", "msvcp140", "concrt140", "vccorlib140")
MSVC_REQUIREMENT = "requires Microsoft Visual C++ Redistributable 2015-2022 x64"


class NotPE(ValueError):
    """Input is not a PE file."""


class PEError(ValueError):
    """PE file is malformed or unsupported."""


class PEImage:
    """Read the x64 PE metadata needed to enumerate DLL dependencies."""

    def __init__(self, path: Path):
        self.path = path
        self.data = path.read_bytes()
        self.sections: list[tuple[int, int, int, int]] = []
        self._parse_headers()

    def _need(self, offset: int, size: int) -> None:
        if offset < 0 or size < 0 or offset + size > len(self.data):
            raise PEError(f"out-of-bounds data at 0x{offset:x} (size {size})")

    def _u16(self, offset: int) -> int:
        self._need(offset, 2)
        return struct.unpack_from("<H", self.data, offset)[0]

    def _u32(self, offset: int) -> int:
        self._need(offset, 4)
        return struct.unpack_from("<I", self.data, offset)[0]

    def _parse_headers(self) -> None:
        if len(self.data) < 64 or self.data[:2] != b"MZ":
            raise NotPE("missing DOS MZ signature")
        peoff = self._u32(0x3C)
        self._need(peoff, 24)
        if self.data[peoff:peoff + 4] != b"PE\0\0":
            raise NotPE("missing PE signature")
        coff = peoff + 4
        machine, nsections, _, _, _, optsize, _ = struct.unpack_from("<HHIIIHH", self.data, coff)
        if machine != 0x8664:
            raise PEError(f"expected x64 PE (machine 0x8664), got 0x{machine:04x}")
        opt = coff + 20
        self._need(opt, optsize)
        magic = self._u16(opt)
        if magic == 0x10B:
            raise PEError("PE32 (32-bit) is unsupported; expected PE32+ x64")
        if magic != 0x20B:
            raise PEError(f"unsupported optional-header magic 0x{magic:04x}")
        if optsize < 112:
            raise PEError("truncated PE32+ optional header")
        self.image_base = struct.unpack_from("<Q", self.data, opt + 24)[0]
        self.size_headers = self._u32(opt + 60)
        n_dirs = self._u32(opt + 108)
        dirs = opt + 112
        self.directories: list[tuple[int, int]] = []
        for i in range(min(n_dirs, max(0, (optsize - 112) // 8))):
            self.directories.append(struct.unpack_from("<II", self.data, dirs + i * 8))
        secpos = opt + optsize
        self._need(secpos, nsections * 40)
        for i in range(nsections):
            pos = secpos + i * 40
            vsize, va, rawsize, rawptr = struct.unpack_from("<IIII", self.data, pos + 8)
            self.sections.append((va, max(vsize, rawsize), rawptr, rawsize))

    def rva_offset(self, rva: int, size: int = 1) -> int:
        if rva < self.size_headers:
            self._need(rva, size)
            return rva
        for va, span, rawptr, rawsize in self.sections:
            if va <= rva < va + span:
                delta = rva - va
                if delta + size > rawsize:
                    raise PEError(f"RVA 0x{rva:x} points outside section file data")
                self._need(rawptr + delta, size)
                return rawptr + delta
        raise PEError(f"RVA 0x{rva:x} is not mapped by any section")

    def cstring(self, rva: int) -> str:
        pos = self.rva_offset(rva)
        end = self.data.find(b"\0", pos, min(len(self.data), pos + 4096))
        if end < 0:
            raise PEError(f"unterminated string at RVA 0x{rva:x}")
        try:
            return self.data[pos:end].decode("ascii")
        except UnicodeDecodeError as exc:
            raise PEError(f"non-ASCII DLL name at RVA 0x{rva:x}") from exc

    def directory(self, index: int) -> tuple[int, int]:
        return self.directories[index] if index < len(self.directories) else (0, 0)

    def export_name(self) -> str | None:
        rva, size = self.directory(0)
        if not rva or not size:
            return None
        pos = self.rva_offset(rva, 40)
        name_rva = self._u32(pos + 12)
        return self.cstring(name_rva) if name_rva else None

    def imports(self) -> list[dict[str, Any]]:
        result: list[dict[str, Any]] = []
        rva, _ = self.directory(1)
        if rva:
            pos = self.rva_offset(rva, 20)
            for _ in range(65536):
                self._need(pos, 20)
                desc = struct.unpack_from("<IIIII", self.data, pos)
                if not any(desc):
                    break
                name = self.cstring(desc[3])
                result.append({"name": name, "delay": False})
                pos += 20
            else:
                raise PEError("unterminated import descriptor table")
        # IMAGE_DELAYLOAD_DESCRIPTOR is 8 DWORDs. Attributes bit 0 means RVAs;
        # older descriptors store VAs and require subtracting the image base.
        rva, _ = self.directory(13)
        if rva:
            pos = self.rva_offset(rva, 32)
            for _ in range(65536):
                self._need(pos, 32)
                desc = struct.unpack_from("<IIIIIIII", self.data, pos)
                if not any(desc):
                    break
                attrs, name_value = desc[0], desc[1]
                name_rva = name_value if attrs & 1 else name_value - self.image_base
                if name_rva <= 0 or name_rva > 0xFFFFFFFF:
                    raise PEError("invalid delay-load DLL name address")
                result.append({"name": self.cstring(name_rva), "delay": True})
                pos += 32
            else:
                raise PEError("unterminated delay-load descriptor table")
        return result


def dll_key(name: str) -> str:
    key = Path(name.replace("\\", "/")).name.casefold()
    return key[:-4] if key.endswith(".dll") else key


def classify(name: str, bundled: set[str]) -> str:
    key = dll_key(name)
    if key in bundled:
        return "bundled"
    if key == "vulkan-1":
        return "vulkan"
    if key.startswith(("api-ms-win-", "ext-ms-")) or key in WINDOWS_DLLS or key.startswith("mf"):
        return "windows"
    if key.startswith(MSVC_PREFIXES):
        return "msvc_runtime"
    return "unknown"


def analyze(paths: list[Path], allow: set[str]) -> dict[str, Any]:
    by_key: dict[str, Path] = {}
    images: dict[str, PEImage] = {}
    warnings: list[str] = []
    for path in paths:
        try:
            image = PEImage(path)
        except NotPE as exc:
            warnings.append(f"WARNING: skipping {path.name}: {exc}")
            continue
        except (OSError, PEError) as exc:
            warnings.append(f"WARNING: skipping {path.name}: {exc}")
            continue
        key = dll_key(path.name)
        by_key[key] = path
        images[key] = image
    bundled = set(images)
    records: dict[str, dict[str, Any]] = {}
    queue = deque(sorted(images))
    visited: set[str] = set()
    while queue:
        key = queue.popleft()
        if key in visited:
            continue
        visited.add(key)
        path, image = by_key[key], images[key]
        try:
            imports = image.imports()
            export = image.export_name()
        except PEError as exc:
            warnings.append(f"WARNING: could not inspect {path.name}: {exc}")
            imports, export = [], None
        deps = []
        for imp in imports:
            bucket = classify(imp["name"], bundled)
            imp["bucket"] = bucket
            imp["allowed"] = bucket == "unknown" and dll_key(imp["name"]) in allow
            deps.append(imp)
            depkey = dll_key(imp["name"])
            if depkey in bundled and depkey not in visited:
                queue.append(depkey)
        records[path.name] = {"export_name": export, "imports": deps}
    return {"files": records, "warnings": warnings}


def print_report(result: dict[str, Any]) -> tuple[bool, list[str]]:
    failed = False
    runtimes: set[str] = set()
    for warning in result["warnings"]:
        print(warning, file=sys.stderr)
    for filename, record in result["files"].items():
        print(f"\n{filename} (export name: {record['export_name'] or 'none'})")
        grouped: dict[str, list[dict[str, Any]]] = {}
        for imp in record["imports"]:
            grouped.setdefault(imp["bucket"], []).append(imp)
            if imp["bucket"] == "msvc_runtime":
                runtimes.add(imp["name"])
            if imp["bucket"] == "vulkan" or (imp["bucket"] == "unknown" and not imp["allowed"]):
                failed = True
        for bucket in ("bundled", "windows", "msvc_runtime", "vulkan", "unknown"):
            entries = grouped.get(bucket, [])
            if entries:
                print(f"  {bucket}:")
                for imp in entries:
                    suffix = " (delay)" if imp["delay"] else ""
                    if imp["allowed"]:
                        suffix += " (allowed)"
                    print(f"    {imp['name']}{suffix}")
    print("\nSummary: " + ("FAIL" if failed else "PASS"))
    if runtimes:
        print(f"Runtime requirements: {MSVC_REQUIREMENT}")
        for name in sorted(set(runtimes), key=str.casefold):
            print(f"  {name}")
    return failed, runtimes


def selftest(directory: Path) -> int:
    expected = [directory / x for x in ("libmpv-2.dll", "libEGL.dll", "libGLESv2.dll")]
    missing = [p.name for p in expected if not p.is_file()]
    if missing:
        print("Self-test missing: " + ", ".join(missing), file=sys.stderr)
        return 2
    result = analyze(expected, set())
    print_report(result)
    for warning in result["warnings"]:
        print(warning, file=sys.stderr)
    files = result["files"]
    mpv = files.get("libmpv-2.dll")
    if not mpv:
        raise AssertionError("libmpv-2.dll was not parsed")
    mpv_imports = mpv["imports"]
    # mpv (egl-angle-win32) loads ANGLE at run time with LoadLibrary, so libEGL/libGLESv2 are NOT in the
    # import table; the runtime dependency shows up as the DLL names embedded as strings. Verified against
    # objdump -p on the milutv r2 build (2026-09-30).
    blob = (directory / "libmpv-2.dll").read_bytes()
    assert b"libEGL.dll" in blob and b"libGLESv2.dll" in blob, \
        "libmpv-2.dll must reference libEGL.dll and libGLESv2.dll (runtime-loaded ANGLE)"
    assert not any(dll_key(i["name"]) == "vulkan-1" for i in mpv_imports), \
        "libmpv-2.dll must not import vulkan-1.dll"
    for name in ("libEGL.dll", "libGLESv2.dll"):
        assert name in files, f"{name} was not parsed"
        bad = [i["name"] for i in files[name]["imports"] if i["bucket"] not in {"windows", "msvc_runtime", "bundled"}]
        assert not bad, f"{name} has disallowed imports: {', '.join(bad)}"
    print("Self-test: PASS")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", type=Path, help="package directory containing DLL files")
    parser.add_argument("--json", type=Path, help="write full dependency graph as JSON")
    parser.add_argument("--allow", nargs="*", default=[], metavar="NAME", help="unknown DLL basename(s) to allow")
    parser.add_argument("--selftest", type=Path, metavar="DIR", help="run assertions against the three test DLLs")
    args = parser.parse_args()
    if args.selftest:
        return selftest(args.selftest)
    if not args.dir or not args.dir.is_dir():
        parser.error("--dir must name an existing package directory")
    result = analyze(sorted(args.dir.glob("*.dll"), key=lambda p: p.name.casefold()), {dll_key(n) for n in args.allow})
    failed, _ = print_report(result)
    if args.json:
        args.json.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as exc:
        print(f"Self-test: FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
