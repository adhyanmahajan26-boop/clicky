#!/usr/bin/env python3
"""Runs Tools/install/install.sh on any Linux or Mac against stand-ins, to check its decisions without a real Theo build:

- a stand-in Mac: small programs named codesign, ditto, plutil, osascript, sw_vers and uname that act like the real
  ones on fake apps (a Theo.app whose "signature" is a JSON file), first on PATH. osascript runs the script's own
  JavaScript for Automation under Node with a tiny shim, so the release-reading code that ships is the code tested.
- a stand-in GitHub: releases with zips, SHA256SUMS and SIGNER files, and a private repo that answers 404.

  python3 Tools/install/test-install-stand-in.py

Needs python3, bash, curl and node. Never touches an installed Theo: everything is in a temporary folder.
Tools/install/test-install.sh is the end-to-end test with real builds, signatures and macOS; this one covers where
releases come from, what a private repo says, and how the signer rule is chosen and enforced.
"""
import hashlib, http.server, io, json, os, pathlib, plistlib, shutil, subprocess, sys, tempfile, threading, zipfile

HERE = pathlib.Path(__file__).resolve().parent
INSTALLER = HERE / "install.sh"
STAMPER = HERE / "stamp-installer.py"
BUNDLE_ID = "com.personal.clicky"
TEAM_A, TEAM_B = "AAAAA11111", "BBBBB22222"
RULE_A = 'identifier "com.personal.clicky" and anchor apple generic and certificate leaf[subject.OU] = "%s"' % TEAM_A
RULE_B = 'identifier "com.personal.clicky" and anchor apple generic and certificate leaf[subject.OU] = "%s"' % TEAM_B

# ---------- stand-in Mac tools ----------

CODESIGN = r'''#!/usr/bin/env python3
# Stand-in for codesign: the "signature" is Contents/_CodeSignature/stand-in.json.
import json, pathlib, plistlib, re, sys
arguments = sys.argv[1:]
app = pathlib.Path(arguments[-1])
def signature():
    try: return json.loads((app / "Contents/_CodeSignature/stand-in.json").read_text())
    except OSError: return None
def bundle_id():
    return plistlib.loads((app / "Contents/Info.plist").read_bytes()).get("CFBundleIdentifier", "")
def designated(sig):
    if sig["kind"] == "adhoc": return 'cdhash H"%s"' % sig["cdhash"]
    if sig["kind"] == "certificate": return 'identifier "%s" and certificate leaf = H"%s"' % (bundle_id(), sig["leaf"])
    return ('identifier "%s" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: someone (%s)" '
            'and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */' % (bundle_id(), sig["certificate"]))
def satisfies(sig, requirement):
    for clause in requirement.split(" and "):
        clause = clause.strip()
        match = re.fullmatch(r'identifier "([^"]+)"', clause)
        if match: ok = match.group(1) == bundle_id()
        elif clause == "anchor apple generic": ok = sig["kind"] == "team"
        elif re.fullmatch(r"certificate 1\[field\.1\.2\.840\.113635\.100\.6\.2\.1\] /\* exists \*/", clause): ok = sig["kind"] == "team"
        else:
            match = re.fullmatch(r'certificate leaf\[subject\.OU\] = "?([A-Z0-9]+)"?', clause)
            if match: ok = sig["kind"] == "team" and sig["team"] == match.group(1)
            else:
                match = re.fullmatch(r'certificate leaf\[subject\.CN\] = "Apple Development: someone \(([^)]+)\)"', clause)
                if match: ok = sig["kind"] == "team" and sig["certificate"] == match.group(1)
                else:
                    match = re.fullmatch(r'certificate leaf = H"([0-9a-fA-F]{40})"', clause)
                    if match: ok = sig["kind"] == "certificate" and sig["leaf"].lower() == match.group(1).lower()
                    else:
                        match = re.fullmatch(r'cdhash H"([0-9a-f]+)"', clause)
                        if match: ok = sig["kind"] == "adhoc" and sig["cdhash"] == match.group(1)
                        else: sys.exit("stand-in codesign: can't read requirement clause %r" % clause)
        if not ok: return False
    return True
sig = signature()
if "--verify" in arguments:
    if sig is None or not sig.get("valid", True): sys.exit(1)
    if "-R" in arguments:
        requirement = arguments[arguments.index("-R") + 1]
        if not requirement.startswith("="): sys.exit(2)
        sys.exit(0 if satisfies(sig, requirement[1:]) else 3)
    sys.exit(0)
if "-r-" in arguments:
    if sig is None: sys.exit(1)
    print("Executable=%s" % app, file=sys.stderr)
    print("designated => " + designated(sig))
    sys.exit(0)
if sig is None: print("%s: code object is not signed at all" % app, file=sys.stderr); sys.exit(1)
lines = ["Executable=%s/Contents/MacOS/Clicky" % app, "Identifier=" + bundle_id()]
if sig["kind"] == "adhoc": lines += ["Signature=adhoc", "TeamIdentifier=not set"]
elif sig["kind"] == "certificate": lines += ["Authority=Theo self-signed", "TeamIdentifier=not set"]
else: lines += ["Authority=Apple Development: someone (%s)" % sig["certificate"], "TeamIdentifier=" + sig["team"]]
print("\n".join(lines), file=sys.stderr)
'''

DITTO = r'''#!/usr/bin/env python3
# Stand-in for ditto: "-x -k zip folder" unzips, "source destination" copies a folder.
import shutil, sys, zipfile
arguments = sys.argv[1:]
if arguments[:2] == ["-x", "-k"]:
    zipfile.ZipFile(arguments[2]).extractall(arguments[3])
else:
    shutil.copytree(arguments[-2], arguments[-1], symlinks=True)
'''

PLUTIL = r'''#!/usr/bin/env python3
# Stand-in for "plutil -extract KEY raw -o - FILE".
import plistlib, sys
arguments = sys.argv[1:]
if arguments[0] != "-extract" or arguments[2] != "raw": sys.exit(2)
value = plistlib.loads(open(arguments[-1], "rb").read()).get(arguments[1])
if value is None: sys.exit(1)
print(value)
'''

# osascript -l JavaScript - FILE: runs the JXA from stdin under Node, with the two Foundation calls it uses.
OSASCRIPT = r'''#!/bin/bash
[ "$1" = "-l" ] && [ "$2" = "JavaScript" ] && [ "$3" = "-" ] || exit 2
shift 3
shim='const fs = require("fs");
globalThis.ObjC = { import: () => {} };
globalThis.$ = { NSUTF8StringEncoding: 4,
  NSString: { stringWithContentsOfFileEncodingError: (path) => ({ js: fs.readFileSync(path, "utf8") }) } };'
script="$(cat)"
exec node -e "$shim
$script
process.stdout.write(String(run(process.argv.slice(1))) + \"\\n\");" -- "$@"
'''


def write_stand_in_tools(folder):
    real_uname = shutil.which("uname")
    tools = {
        "codesign": CODESIGN, "ditto": DITTO, "plutil": PLUTIL, "osascript": OSASCRIPT,
        "sw_vers": "#!/bin/sh\necho 15.1\n",
        "uname": '#!/bin/sh\nif [ "$1" = "-s" ]; then echo Darwin; else exec %s "$@"; fi\n' % real_uname,
        "shasum": '#!/bin/sh\n[ "$1" = "-a" ] && shift 2\nexec sha256sum "$@"\n' if not shutil.which("shasum") else None,
        "xattr": "#!/bin/sh\nexit 0\n",
        "open": "#!/bin/sh\nexit 0\n",
        "gh": "#!/bin/sh\nexit 1\n",   # a signed-in gh on this machine must not add a token
    }
    folder.mkdir(parents=True, exist_ok=True)
    for name, text in tools.items():
        if text is None:
            continue
        path = folder / name
        path.write_text(text)
        path.chmod(0o755)


# ---------- fake Theo builds ----------

def theo_zip(build, signature, bundle_id=BUNDLE_ID):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("Theo.app/Contents/Info.plist", plistlib.dumps({"CFBundleIdentifier": bundle_id, "CFBundleVersion": str(build)}))
        archive.writestr("Theo.app/Contents/MacOS/Clicky", "#!/bin/sh\n")
        archive.writestr("Theo.app/Contents/_CodeSignature/stand-in.json", json.dumps(signature))
    return buffer.getvalue()


def team_signature(team, certificate="CERT000001"):
    return {"kind": "team", "team": team, "certificate": certificate}


# ---------- stand-in GitHub ----------

RELEASES = {}   # repo -> {"tag", "assets": {name: bytes}, "notes"}


class GitHub(http.server.BaseHTTPRequestHandler):
    def log_message(self, *arguments):
        pass

    def send(self, body, content_type="application/json", code=200):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        base = "http://127.0.0.1:%d" % PORT
        for repo, release in RELEASES.items():
            if self.path == "/repos/%s/releases/latest" % repo:
                assets = [{"name": name, "browser_download_url": "%s/download/%s/%s" % (base, repo, name),
                           "url": "%s/api-asset/%s/%s" % (base, repo, name)} for name in release["assets"]]
                return self.send(json.dumps({"tag_name": release["tag"], "body": release.get("notes", ""), "assets": assets}).encode())
            for prefix in ("/download/%s/" % repo, "/api-asset/%s/" % repo):
                if self.path.startswith(prefix):
                    name = self.path[len(prefix):]
                    if name in release["assets"]:
                        return self.send(release["assets"][name], "application/octet-stream")
        self.send(b'{"message":"Not Found"}', code=404)


SERVER = http.server.ThreadingHTTPServer(("127.0.0.1", 0), GitHub)
PORT = SERVER.server_address[1]
threading.Thread(target=SERVER.serve_forever, daemon=True).start()


def publish(repo, build, zip_bytes, signer=None, signer_in_sums=True, sums=True):
    zip_name = "Theo-%s.zip" % build
    assets = {zip_name: zip_bytes}
    lines = ["%s  %s" % (hashlib.sha256(zip_bytes).hexdigest(), zip_name)]
    if signer is not None:
        assets["SIGNER"] = (signer + "\n").encode()
        if signer_in_sums:
            lines.append("%s  SIGNER" % hashlib.sha256(assets["SIGNER"]).hexdigest())
    if sums:
        assets["SHA256SUMS"] = ("\n".join(lines) + "\n").encode()
    RELEASES[repo] = {"tag": "build-%s" % build, "assets": assets,
                      "notes": "" if sums else "sha256: %s" % hashlib.sha256(zip_bytes).hexdigest()}


# ---------- running install.sh ----------

def main():
    results = {}
    with tempfile.TemporaryDirectory() as scratch:
        scratch = pathlib.Path(scratch)
        tools = scratch / "stand-in-mac"
        write_stand_in_tools(tools)
        apps = scratch / "Applications"
        home = scratch / "home"
        home.mkdir()
        log_folder = scratch / "logs"
        log_folder.mkdir()

        def run(*arguments, script=INSTALLER, env=None, stdin_script=False):
            environment = {"HOME": str(home), "PATH": "%s:/usr/local/bin:/usr/bin:/bin" % tools, "TMPDIR": str(scratch),
                           "THEO_GITHUB_API": "http://127.0.0.1:%d" % PORT, "THEO_RELEASES_REPO": "o/r"}
            environment.update(env or {})
            environment = {key: value for key, value in environment.items() if value is not None}
            if stdin_script:   # like curl ... | bash -s -- options: no script path
                command = ["bash", "-s", "--", "--dir", str(apps), "--no-launch", *arguments]
                result = subprocess.run(command, input=pathlib.Path(script).read_text(), env=environment, capture_output=True, text=True, timeout=120)
            else:
                command = ["bash", str(script), "--dir", str(apps), "--no-launch", *arguments]
                result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=120)
            return result.returncode, result.stdout + result.stderr

        def installed_build():
            plist = apps / "Theo.app/Contents/Info.plist"
            return plistlib.loads(plist.read_bytes())["CFBundleVersion"] if plist.exists() else None

        def check(name, condition, output):
            results[name] = bool(condition)
            if not condition:
                (log_folder / (name + ".log")).write_text(output)
                print("---- %s ----\n%s" % (name, output[-1500:]))

        # 1. A fresh install from a release whose SIGNER names the team that signed it.
        publish("o/r", 100, theo_zip(100, team_signature(TEAM_A)), signer=RULE_A)
        code, out = run()
        check("fresh_install_with_signer_file", code == 0 and installed_build() == "100" and "Signature OK" in out, out)

        # 2. The same build again is a no-op; an upgrade signed by the same certificate goes through.
        code, out = run()
        check("same_build_is_a_no_op", code == 0 and "already installed" in out, out)
        publish("o/r", 101, theo_zip(101, team_signature(TEAM_A)), signer=RULE_A)
        code, out = run()
        check("upgrade_same_signer", code == 0 and installed_build() == "101", out)

        # 3. Someone replaces the release with their own build and their own SIGNER file: the installed Theo's rule refuses it.
        publish("o/r", 102, theo_zip(102, team_signature(TEAM_B, "CERT000002")), signer=RULE_B)
        code, out = run()
        check("upgrade_from_another_signer_refused", code != 0 and "not by the same signer" in out and installed_build() == "101", out)
        code, out = run("--allow-new-signer")
        check("allow_new_signer_lets_it_through", code == 0 and installed_build() == "102" and "ask for Theo's permissions again" in out, out)
        shutil.rmtree(apps, ignore_errors=True)

        # 4. Fresh installs: a SIGNER file that names another team, one that's too loose, one SHA256SUMS doesn't list, none at all.
        publish("o/r", 100, theo_zip(100, team_signature(TEAM_A)), signer=RULE_B)
        code, out = run()
        check("fresh_install_wrong_signer_refused", code != 0 and "not Theo's signing identity" in out and installed_build() is None, out)
        for loose_rule in ('identifier "com.personal.clicky" and anchor apple generic',
                           RULE_A + " or anchor apple generic",
                           'identifier "com.example.other" and anchor apple generic and certificate leaf[subject.OU] = "%s"' % TEAM_A):
            publish("o/r", 100, theo_zip(100, team_signature(TEAM_A)), signer=loose_rule)
            code, out = run()
            check("loose_rule_refused: " + loose_rule[-40:], code != 0 and "too loose" in out and installed_build() is None, out)
        publish("o/r", 100, theo_zip(100, team_signature(TEAM_A)), signer=RULE_A, signer_in_sums=False)
        code, out = run()
        check("signer_file_not_in_sums_is_ignored", code != 0 and "can't tell who should have signed" in out and installed_build() is None, out)
        publish("o/r", 100, theo_zip(100, team_signature(TEAM_A)))
        code, out = run()
        check("no_signer_anywhere_refused", code != 0 and "can't tell who should have signed" in out and installed_build() is None, out)
        code, out = run(env={"THEO_SIGNER_REQUIREMENT": RULE_A})
        check("signer_from_environment", code == 0 and installed_build() == "100", out)
        shutil.rmtree(apps, ignore_errors=True)

        # 5. Ad hoc builds are refused even by a matching-looking release, and a self-signed certificate rule works.
        publish("o/r", 100, theo_zip(100, {"kind": "adhoc", "cdhash": "ab12"}), signer=RULE_A)
        code, out = run()
        check("ad_hoc_build_refused", code != 0 and "not Theo's signing identity" in out and installed_build() is None, out)
        leaf = "0123456789abcdef0123456789abcdef01234567"
        self_signed_rule = 'identifier "com.personal.clicky" and certificate leaf = H"%s"' % leaf
        publish("o/r", 100, theo_zip(100, {"kind": "certificate", "leaf": leaf}), signer=self_signed_rule)
        code, out = run()
        check("self_signed_certificate_rule", code == 0 and installed_build() == "100", out)
        shutil.rmtree(apps, ignore_errors=True)

        # 6. The published copy (stamped by release.sh) carries the repo and the signer: no settings and no SIGNER file needed.
        stamped = scratch / "published-install.sh"
        subprocess.run([sys.executable, str(STAMPER), str(INSTALLER), str(stamped), "--repo", "o/r", "--signer", RULE_A], check=True)
        publish("o/r", 100, theo_zip(100, team_signature(TEAM_A)))
        code, out = run(script=stamped, env={"THEO_RELEASES_REPO": None}, stdin_script=True)
        check("published_copy_needs_nothing", code == 0 and installed_build() == "100" and "in o/r" in out, out)
        shutil.rmtree(apps, ignore_errors=True)
        publish("o/r", 100, theo_zip(100, team_signature(TEAM_B, "CERT000002")), signer=RULE_B)
        code, out = run(script=stamped, env={"THEO_RELEASES_REPO": None}, stdin_script=True)
        check("published_copy_pin_beats_release_signer_file", code != 0 and "not Theo's signing identity" in out and installed_build() is None, out)

        # 7. Where releases come from, and what a private repo says.
        code, out = run(env={"THEO_RELEASES_REPO": "private/theo"})
        check("private_repo_said_plainly", code != 0 and "this build's updates are private" in out and "private/theo" in out
              and "gh auth login" not in out, out)
        code, out = run(env={"THEO_RELEASES_REPO": "private/theo", "THEO_GITHUB_TOKEN": "not-a-real-token"})
        check("private_repo_with_token", code != 0 and "token can't read that repo" in out and "not-a-real-token" not in out, out)
        xcconfig_repo = next(line.split("=", 1)[1].strip() for line in (HERE.parents[1] / "Config/Theo.xcconfig").read_text().splitlines()
                             if line.strip().startswith("THEO_RELEASES_REPO"))
        code, out = run(env={"THEO_RELEASES_REPO": None})
        check("checkout_reads_config_xcconfig", "in %s" % xcconfig_repo in out, out)
        code, out = run(env={"THEO_RELEASES_REPO": None}, stdin_script=True)
        check("unstamped_piped_copy_asks_for_a_repo", code != 0 and "doesn't say where" in out, out)

        # 8. A checksum that doesn't match changes nothing; a cut-off download runs nothing.
        publish("o/r", 100, theo_zip(100, team_signature(TEAM_A)), signer=RULE_A)
        RELEASES["o/r"]["assets"]["SHA256SUMS"] = ("0" * 64 + "  Theo-100.zip\n").encode()
        code, out = run()
        check("checksum_mismatch_refused", code != 0 and "doesn't match its checksum" in out and installed_build() is None, out)
        cut = scratch / "cut-install.sh"
        text = INSTALLER.read_text()
        cut.write_text(text[: len(text) // 2])
        code, out = run(script=cut)
        check("cut_off_download_runs_nothing", installed_build() is None, out)

    width = max(len(name) for name in results)
    for name, passed in results.items():
        print("%-*s %s" % (width, name, "PASS" if passed else "FAIL"))
    sys.exit(0 if all(results.values()) else 1)


main()
