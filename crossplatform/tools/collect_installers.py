#!/usr/bin/env python3
"""Copies the installers Tauri built into one folder under release names, and writes SHA256SUMS ("<hex>  <name>").

  python3 tools/collect_installers.py <bundle dir> <out dir> <build>

Names follow the release conventions of the Mac app's releases: nothing ends in .zip (the Mac app's updater takes the first
.zip in a release), and Windows and Linux assets say so in their names (the Mac install.sh skips those).
"""
import hashlib, pathlib, shutil, sys

bundle, out, build = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
out.mkdir(parents=True, exist_ok=True)
rules = [
    ("*.AppImage", "Theo-{b}-linux-x86_64.AppImage"),
    ("*.deb", "Theo-{b}-linux-amd64.deb"),
    ("*.rpm", "Theo-{b}-linux-x86_64.rpm"),
    ("*.msi", "Theo-{b}-windows-x64.msi"),
    ("*-setup.exe", "Theo-{b}-windows-x64-setup.exe"),
    ("*.dmg", "Theo-{b}-desktop-macos-{arch}.dmg"),
]
import platform
arch = "arm64" if platform.machine().lower() in ("arm64", "aarch64") else "x64"
made = []
for pattern, name in rules:
    for f in sorted(bundle.rglob(pattern)):
        target = out / name.format(b=build, arch=arch)
        shutil.copy2(f, target)
        made.append(target)
        break
sums = out / "SHA256SUMS"
lines = [l for l in (sums.read_text().splitlines() if sums.exists() else []) if l.strip()]
names = {l.split("  ", 1)[1] for l in lines}
for f in made:
    if f.name not in names:
        lines.append("%s  %s" % (hashlib.sha256(f.read_bytes()).hexdigest(), f.name))
sums.write_text("\n".join(lines) + "\n")
for f in made:
    print(f.name, f.stat().st_size)
if not made:
    sys.exit("no installers found under %s" % bundle)
