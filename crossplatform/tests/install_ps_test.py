#!/usr/bin/env python3
"""Windows only: install/install.ps1 against a local stand-in for GitHub's releases API, installing the real NSIS installer
the desktop job just built, then removing it.

  python tests/install_ps_test.py <path to Theo-...-windows-x64-setup.exe>
"""
import hashlib, http.server, json, os, pathlib, subprocess, sys, threading, winreg

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE.parent / "install" / "install.ps1"
SETUP = pathlib.Path(sys.argv[1]).read_bytes()
BUILD = "202611130300"
NAME = "Theo-%s-windows-x64-setup.exe" % BUILD
STATE = {"tamper": False, "only_mac": False, "paths": []}


def release_list():
    """GitHub's release list, newest first: a newer Mac-only build (what /releases/latest would answer), a draft and a
    prerelease with Windows installers, a build with Linux only, then this Windows build and an older one."""
    setup = {"name": NAME, "url": "http://127.0.0.1:%d/a/setup" % PORT}
    sums = {"name": "SHA256SUMS", "url": "http://127.0.0.1:%d/a/sums" % PORT}
    mac_only = {"tag_name": "build-202611150000", "draft": False, "prerelease": False,
                "assets": [{"name": "Theo-202611150000.zip", "url": "http://127.0.0.1:%d/a/zip" % PORT}, sums]}
    if STATE["only_mac"]:
        return [mac_only]
    older = "202611120100"
    return [mac_only,
            {"tag_name": "build-202611149000", "draft": True, "prerelease": False, "assets": [setup, sums]},
            {"tag_name": "build-202611148000", "draft": False, "prerelease": True, "assets": [setup, sums]},
            {"tag_name": "build-202611140000", "draft": False, "prerelease": False,
             "assets": [{"name": "Theo-202611140000-linux-x86_64.AppImage", "url": "http://127.0.0.1:%d/a/app" % PORT}, sums]},
            {"tag_name": "build-" + older, "draft": False, "prerelease": False,
             "assets": [{"name": "Theo-%s-windows-x64-setup.exe" % older, "url": "http://127.0.0.1:%d/a/setup" % PORT}, sums]},
            {"tag_name": "build-" + BUILD, "draft": False, "prerelease": False, "assets": [setup, sums]}]


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, body, ctype="application/json", code=200):
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/repos/private/"):   # what GitHub answers for a private repo the request can't see
            return self.send(b'{"message":"Not Found"}', code=404)
        STATE["paths"].append(self.path)
        if self.path == "/repos/o/r/releases/latest":   # the Mac's latest: install.ps1 must never ask for it
            return self.send(b'{"message":"install.ps1 must list releases, not ask for the latest"}', code=500)
        if self.path == "/repos/o/r/releases?per_page=100":
            return self.send(json.dumps(release_list()).encode())
        if self.path == "/a/setup":
            return self.send(SETUP, "application/octet-stream")
        if self.path == "/a/sums":
            d = "0" * 64 if STATE["tamper"] else hashlib.sha256(SETUP).hexdigest()
            return self.send(("%s  %s\n" % (d, NAME)).encode(), "text/plain")
        self.send(b"{}", code=404)


srv = http.server.HTTPServer(("127.0.0.1", 0), H)
PORT = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()


def ps(*args, env_changes=None, script=SCRIPT):
    env = dict(os.environ, THEO_GITHUB_API="http://127.0.0.1:%d" % PORT, THEO_RELEASES_REPO="o/r")
    env.update(env_changes or {})
    r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script), *args], env=env, capture_output=True, text=True, timeout=600)
    return r.returncode, r.stdout + r.stderr


def installed():
    for root in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        try:
            k = winreg.OpenKey(root, r"Software\Microsoft\Windows\CurrentVersion\Uninstall")
        except OSError:
            continue
        for i in range(winreg.QueryInfoKey(k)[0]):
            try:
                sub = winreg.OpenKey(k, winreg.EnumKey(k, i))
                if winreg.QueryValueEx(sub, "DisplayName")[0] == "Theo":
                    loc = winreg.QueryValueEx(sub, "InstallLocation")[0].strip('"')
                    return loc
            except OSError:
                continue
    return None


results = {}
# Where releases come from: a private repo is said plainly; a copy with no repo doesn't guess; the release's copy needs nothing.
NO_TOKEN = {"THEO_GITHUB_TOKEN": "", "GH_TOKEN": "", "GITHUB_TOKEN": "", "GH_CONFIG_DIR": os.path.join(os.environ.get("TEMP", "."), "no-gh-config")}
code, out = ps("-NoLaunch", env_changes=dict(NO_TOKEN, THEO_RELEASES_REPO="private/r"))
results["private_repo_said_plainly"] = code != 0 and "updates are private" in out and "gh auth login" not in out and not installed()
import tempfile
with tempfile.TemporaryDirectory() as scratch:
    loose = pathlib.Path(scratch, "install.ps1"); loose.write_text(SCRIPT.read_text(encoding="utf-8"), encoding="utf-8")
    code, out = ps("-NoLaunch", env_changes=dict(NO_TOKEN, THEO_RELEASES_REPO=""), script=loose)
    results["unstamped_copy_asks_for_a_repo"] = code != 0 and "doesn't say where" in out and not installed()
STATE["only_mac"] = True
code, out = ps("-NoLaunch")
STATE["only_mac"] = False
results["no_windows_build_said_plainly"] = code != 0 and "has a Windows installer" in out and not installed()
STATE["tamper"] = True
code, out = ps("-NoLaunch")
results["refuses_on_checksum_mismatch"] = code != 0 and "refusing" in out and not installed()
STATE["tamper"] = False
code, out = ps("-NoLaunch")
loc = installed()
results["installs_without_admin"] = code == 0 and loc is not None and pathlib.Path(loc, "theo-desktop.exe").exists()
# The newest build-* release with a Windows installer, found by listing releases; the Mac's newer zip-only build is skipped.
marker = pathlib.Path(os.environ["APPDATA"], "Theo-Desktop", "INSTALLED_BUILD")
results["picks_newest_windows_build"] = marker.exists() and marker.read_text().strip() == BUILD
results["lists_releases_never_latest"] = (any(p.startswith("/repos/o/r/releases?") for p in STATE["paths"])
                                          and not any(p.endswith("/releases/latest") for p in STATE["paths"]))
# The connector hub's helper ships beside the app, where the engine looks for it (theo-core/src/hub.rs).
results["connector_helper_beside_app"] = loc is not None and pathlib.Path(loc, "theo-connectors.exe").exists()
code, out = ps("-NoLaunch")
results["already_installed_is_a_no_op"] = code == 0 and "already installed" in out
data = pathlib.Path(os.environ["APPDATA"], "Theo-Desktop"); data.mkdir(parents=True, exist_ok=True); (data / "keep").write_text("x")
code, out = ps("-Uninstall")
results["uninstall_removes_app_keeps_data"] = code == 0 and installed() is None and (data / "keep").exists()
code, out = ps("-Purge", "-Yes")
results["purge_removes_data"] = code == 0 and not data.exists()
for k, v in results.items():
    print("%-36s %s" % (k, "PASS" if v else "FAIL"))
print(out[-2000:])
sys.exit(0 if all(results.values()) else 1)
