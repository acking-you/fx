#!/usr/bin/env python3
"""Build, exercise, and package one native static library on its target runner."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

TARGETS = {
    "x86_64-unknown-linux-gnu": ("x86_64-linux-gnu.2.28", ["pthread", "dl", "m"], "glibc 2.28"),
    "aarch64-unknown-linux-gnu": ("aarch64-linux-gnu.2.28", ["pthread", "dl", "m"], "glibc 2.28"),
    "x86_64-apple-darwin": ("x86_64-macos.13.0", [], "macOS 13"),
    "aarch64-apple-darwin": ("aarch64-macos.13.0", [], "macOS 13"),
    "x86_64-pc-windows-msvc": ("x86_64-windows-msvc", ["kernel32", "ntdll", "ws2_32", "crypt32"], "Windows 10, dynamic MSVC CRT"),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True, choices=TARGETS)
    parser.add_argument("--output", type=Path, default=Path("dist/native"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    os.chdir(root)
    zig = os.environ.get("ZIG", "zig")
    if subprocess.check_output([zig, "version"], text=True).strip() != "0.16.0":
        raise SystemExit("Native releases require Zig 0.16.0")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    version = re.search(r'pub const version = "([^"]+)";', (root / "src/main.zig").read_text())[1]
    target, libraries, minimum = TARGETS[args.target]
    prefix = root / "zig-out/native" / args.target
    subprocess.run([zig, "build", "libfx", "-j1", f"-Dtarget={target}", "-Dcpu=baseline",
                    "-Dembedded-strip=true", f"-Dgit-revision={revision}", "--prefix", str(prefix)], check=True)
    archive = "fx_core.lib" if "windows" in args.target else "libfx_core.a"
    native = prefix / "lib" / archive
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="fx-native-") as temporary:
        stage = Path(temporary)
        (stage / "lib").mkdir()
        (stage / "include").mkdir()
        shutil.copyfile(native, stage / "lib" / archive)
        shutil.copyfile(root / "include/fx.h", stage / "include/fx.h")
        for name in ["LICENSE", "THIRD_PARTY_NOTICES.md"]:
            shutil.copyfile(root / name, stage / name)
        manifest = {
            "schema_version": 1, "version": version, "revision": revision, "abi_version": 1,
            "target": args.target, "zig_target": target, "zig_version": "0.16.0",
            "optimization": "ReleaseSafe", "cpu": "baseline", "minimum_system": minimum,
            "linkage": "static", "library": f"lib/{archive}", "system_libraries": libraries,
            "library_sha256": hashlib.sha256(native.read_bytes()).hexdigest(),
        }
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        executable = prefix / ("native-smoke.exe" if os.name == "nt" else "native-smoke")
        command = [zig, "cc", "-target", target, "-I", str(stage / "include"),
                   str(root / "scripts/native-smoke.c"), str(stage / "lib" / archive), "-o", str(executable)]
        subprocess.run(command + [f"-l{name}" for name in libraries], check=True)
        (stage / "home").mkdir()
        (stage / "workspace").mkdir()
        config = stage / "config.json"
        config.write_text(json.dumps({"home": str(stage / "home"), "workspace_root": str(stage / "workspace")}))
        subprocess.run([str(executable), str(config), revision], check=True, timeout=30)
        subprocess.run([sys.executable, "scripts/smoke-native-cancel.py", str(executable), revision], check=True, timeout=60)
        destination = output / f"fx-native-{args.target}.tar.gz"
        with tarfile.open(destination, "w:gz") as bundle:
            for name in ["lib", "include", "LICENSE", "THIRD_PARTY_NOTICES.md", "manifest.json"]:
                bundle.add(stage / name, arcname=name)
    digest = hashlib.sha256(destination.read_bytes()).hexdigest()
    destination.with_name(destination.name + ".sha256").write_text(f"{digest}  {destination.name}\n")
    print(f"Verified {destination.name}: {destination.stat().st_size} bytes, SHA-256 {digest}")


if __name__ == "__main__":
    main()
