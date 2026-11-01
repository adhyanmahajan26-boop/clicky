#!/usr/bin/env python3 -I
"""Builds leanring-buddy/Assets.xcassets/Logos from downloaded icon packages (lobe-icons MIT, gilbarbara/logos CC0,
simple-icons CC0). Run: make-logo-assets.py <download-dir> <t3code-repo>. Brand marks belong to their owners and are
used only to label the service they connect to."""
import glob, json, os, re, shutil, sys

dl, t3 = sys.argv[1], sys.argv[2]
lobe = glob.glob(f"{dl}/x-lobehub*/package/icons")[0]
simple = glob.glob(f"{dl}/x-simple-icons*/package/icons")[0]
iconify = json.load(open(f"{dl}/x-logos/package/icons.json"))
out = "leanring-buddy/Assets.xcassets/Logos"
shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)
json.dump({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": False}}, open(f"{out}/Contents.json", "w"), indent=2)


def from_iconify(name):
    icon = iconify["icons"][name]
    w, h = icon.get("width", iconify.get("width", 256)), icon.get("height", iconify.get("height", 256))
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{icon["body"]}</svg>'


def clean(svg):
    """No scripts, styles or remote references; sized so the asset compiler keeps it crisp."""
    svg = re.sub(r"<style.*?</style>", "", svg, flags=re.S)
    svg = re.sub(r"<title.*?</title>", "", svg, flags=re.S)
    # lobe-icons size themselves in em and with inline styles, which the asset compiler's SVG reader dislikes.
    svg = re.sub(r'\sstyle="[^"]*"', "", svg)
    svg = re.sub(r'(<svg[^>]*?)\sheight="[^"]*"', r"\1", svg, count=1)
    svg = re.sub(r'(<svg[^>]*?)\swidth="[^"]*"', r"\1", svg, count=1)
    svg = svg.replace("<svg ", '<svg width="64" height="64" ', 1)
    assert "<script" not in svg and "http://" not in svg.replace("http://www.w3.org", "") and "https://" not in svg
    return svg


def tinted(path, color):
    svg = open(path).read()
    return svg.replace("<svg ", f'<svg fill="{color}" ', 1)


def sarvam():
    svg = open(f"{dl}/sarvam-favicon.svg").read()
    svg = re.sub(r"<style.*?</style>", "", svg, flags=re.S)
    return svg.replace("<svg ", '<svg fill="#000" ', 1)


def t3_mark():
    """T3 Code's own wordmark path, without the black square behind it, centred in a square."""
    source = open(f"{t3}/apps/web/src/components/T3Wordmark.tsx").read()
    path = re.search(r'd="([^"]+)"', source).group(1)
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="15.5 18 94.4 94.4"><path d="{path}" fill="#000"/></svg>'


L = lambda name: open(f"{lobe}/{name}.svg").read()
LOGOS = {
    # Harnesses
    "claude": (L("claude-color"), False), "codex": (L("codex-color"), False), "cursor": (L("cursor"), True),
    "opencode": (L("opencode"), True), "grok": (L("grok"), True), "gemini": (from_iconify("google-gemini-icon"), False),
    "t3": (t3_mark(), True),
    # AI providers
    "anthropic": (L("anthropic"), True), "openai": (L("openai"), True), "xai": (L("xai"), True),
    "openrouter": (L("openrouter"), True), "groq": (L("groq"), True), "mistral": (L("mistral-color"), False),
    "deepseek": (L("deepseek-color"), False), "sarvam": (sarvam(), True), "perplexity": (L("perplexity-color"), False),
    "together": (L("together-color"), False), "fireworks": (L("fireworks-color"), False), "cerebras": (L("cerebras-color"), False),
    "elevenlabs": (L("elevenlabs"), True), "deepgram": (from_iconify("deepgram-icon"), False), "assemblyai": (L("assemblyai-color"), False),
    "ollama": (L("ollama"), True), "lmstudio": (L("lmstudio"), True),
    # Connectors
    "gmail": (from_iconify("google-gmail"), False), "notion": (from_iconify("notion-icon"), False), "drive": (from_iconify("google-drive"), False),
    "calendar": (from_iconify("google-calendar"), False), "chrome": (from_iconify("chrome"), False),
    "docs": (tinted(f"{simple}/googledocs.svg", "#4285F4"), False), "sheets": (tinted(f"{simple}/googlesheets.svg", "#0F9D58"), False),
    "hostinger": (tinted(f"{simple}/hostinger.svg", "#6747C7"), False),
    # Runs
    "github": (open(f"{simple}/github.svg").read(), True), "git": (tinted(f"{simple}/git.svg", "#F05032"), False),
}

for name, (svg, template) in LOGOS.items():
    folder = f"{out}/logo-{name}.imageset"
    os.makedirs(folder)
    open(f"{folder}/{name}.svg", "w").write(clean(svg))
    json.dump({"images": [{"filename": f"{name}.svg", "idiom": "universal"}], "info": {"author": "xcode", "version": 1},
               "properties": {"preserves-vector-representation": True,
                              "template-rendering-intent": "template" if template else "original"}},
              open(f"{folder}/Contents.json", "w"), indent=2)
print(len(LOGOS), "logos")
