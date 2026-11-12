#!/usr/bin/env python3
"""Tests install/install-linux.sh against a local stand-in for GitHub's releases API (THEO_GITHUB_API). Runs anywhere bash runs."""
import hashlib, http.server, json, os, pathlib, subprocess, sys, tempfile, threading

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE.parent / "install" / "install-linux.sh"
ARCH = "aarch64" if os.uname().machine in ("arm64", "aarch64") else "x86_64"
APP = b"#!/bin/sh\necho theo\n"
STATE = {"tamper": False, "auth": [], "builds": ["202611130300", "202611120100"]}


def release(build):
    name = "Theo-%s-linux-%s.AppImage" % (build, ARCH)
    return {"tag_name": "build-" + build, "assets": [
        {"name": "Theo-%s.zip" % build, "url": "http://127.0.0.1:%d/asset/zip" % PORT},
        {"name": name, "url": "http://127.0.0.1:%d/asset/app/%s" % (PORT, build)},
        {"name": "SHA256SUMS", "url": "http://127.0.0.1:%d/asset/sums/%s" % (PORT, build)}]}


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, body, ctype="application/json", code=200):
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        STATE["auth"].append(self.headers.get("Authorization"))
        p = self.path
        if p == "/repos/o/r/releases/latest":
            return self.send(json.dumps(release(STATE["builds"][0])).encode())
        if p.startswith("/repos/o/r/releases/tags/build-"):
            b = p.rsplit("build-", 1)[1]
            return self.send(json.dumps(release(b)).encode()) if b in STATE["builds"] else self.send(b"{}", code=404)
        if p.startswith("/asset/app/"):
            return self.send(APP + p.encode(), "application/octet-stream")
        if p.startswith("/asset/sums/"):
            b = p.rsplit("/", 1)[1]
            body = APP + ("/asset/app/" + b).encode()
            digest = hashlib.sha256(body).hexdigest() if not STATE["tamper"] else "0" * 64
            return self.send(("%s  Theo-%s-linux-%s.AppImage\n%s  Theo-%s.zip\n" % (digest, b, ARCH, "1" * 64, b)).encode(), "text/plain")
        self.send(b"{}", code=404)


srv = http.server.HTTPServer(("127.0.0.1", 0), H)
PORT = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()


def run(home, *args, env=None):
    e = dict(os.environ, HOME=home, THEO_GITHUB_API="http://127.0.0.1:%d" % PORT, THEO_RELEASES_REPO="o/r", THEO_INSTALL_ANY_OS="1",
             THEO_GITHUB_TOKEN="secret-token", XDG_DATA_HOME=os.path.join(home, ".local/share"), DISPLAY="")
    e.update(env or {})
    r = subprocess.run(["bash", str(SCRIPT), "--no-launch", *args], env=e, capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout + r.stderr


def main():
    results = {}
    with tempfile.TemporaryDirectory() as home:
        opt = pathlib.Path(home, ".local/opt/theo")
        code, out = run(home)
        results["installs_latest"] = code == 0 and (opt / "BUILD").read_text().strip() == STATE["builds"][0] and os.access(opt / "Theo.AppImage", os.X_OK)
        results["links_and_menu_entry"] = pathlib.Path(home, ".local/bin/theo").is_symlink() and pathlib.Path(home, ".local/share/applications/theo.desktop").exists()
        results["token_sent_as_header"] = "Bearer secret-token" in STATE["auth"]
        code, out = run(home)
        results["already_installed_is_a_no_op"] = code == 0 and "already installed" in out
        code, out = run(home, "--version", "202611120100")
        results["installs_a_named_build"] = code == 0 and (opt / "BUILD").read_text().strip() == "202611120100"
        STATE["tamper"] = True
        code, out = run(home, "--force")
        results["refuses_on_checksum_mismatch"] = code != 0 and "refusing" in out and (opt / "BUILD").read_text().strip() == "202611120100"
        STATE["tamper"] = False
        f = pathlib.Path(home, "local.AppImage"); f.write_bytes(APP)
        code, out = run(home, "--from", str(f), "--sha256", "0" * 64)
        results["from_file_checks_sha"] = code != 0 and "mismatch" in out
        code, out = run(home, "--from", str(f), "--sha256", hashlib.sha256(APP).hexdigest())
        results["from_file_installs"] = code == 0 and (opt / "BUILD").read_text().strip() == "local"
        data = pathlib.Path(home, ".local/share/theo-desktop"); data.mkdir(parents=True); (data / "keep").write_text("x")
        code, out = run(home, "--uninstall")
        results["uninstall_keeps_data"] = code == 0 and not opt.exists() and (data / "keep").exists()
        code, out = run(home, "--purge")
        results["purge_needs_a_yes"] = code != 0 and (data / "keep").exists()
        code, out = run(home, "--purge", "--yes")
        results["purge_with_yes_removes_data"] = code == 0 and not data.exists()
        trunc = pathlib.Path(home, "trunc.sh"); trunc.write_text(SCRIPT.read_text()[: len(SCRIPT.read_text()) // 2])
        r = subprocess.run(["bash", str(trunc)], capture_output=True, text=True, env=dict(os.environ, HOME=home))
        results["truncated_download_runs_nothing"] = not opt.exists() and not pathlib.Path(home, ".local/bin/theo").exists()
    for k, v in results.items():
        print("%-36s %s" % (k, "PASS" if v else "FAIL"))
    sys.exit(0 if all(results.values()) else 1)


main()
