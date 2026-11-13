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
STATE = {"tamper": False}


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, body, ctype="application/json", code=200):
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/repos/private/"):   # what GitHub answers for a private repo the request can't see
            return self.send(b'{"message":"Not Found"}', code=404)
        if self.path == "/repos/o/r/releases/latest":
            rel = {"tag_name": "build-" + BUILD, "assets": [{"name": NAME, "url": "http://127.0.0.1:%d/a/setup" % PORT}, {"name": "SHA256SUMS", "url": "http://127.0.0.1:%d/a/sums" % PORT}]}
            return self.send(json.dumps(rel).encode())
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
STATE["tamper"] = True
code, out = ps("-NoLaunch")
results["refuses_on_checksum_mismatch"] = code != 0 and "refusing" in out and not installed()
STATE["tamper"] = False
code, out = ps("-NoLaunch")
loc = installed()
results["installs_without_admin"] = code == 0 and loc is not None and pathlib.Path(loc, "theo-desktop.exe").exists()
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
