#!/usr/bin/env python3
"""Stand-in web for the VM screens and research tests, on 127.0.0.1: a results page shaped like DuckDuckGo's plain one, and
the pages it links to. No network.

  python3 vm_pages.py <log-folder>      prints its port on the first line, then serves until killed

  /search?q=<words>   a results page: four pages per question (/page/<slug>-1 … -4), and /check when the words say captcha
  /page/<name>        an article with "MARKER-<name>" in its words, plus a line its own script adds once it runs
                      ("SCRIPTED-<name>"), so a test can tell a real browser read it from a plain fetch
  /check              a short "verify you are human" page
  /moved              sends the browser to 192.168.0.1 (a page must never be followed onto the network around the computer)
  /blank              a page with no words

Each request is appended to <log-folder>/requests.log as one line: the path and the User-Agent's first word.
"""
import html, os, re, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(LOG, exist_ok=True)


def slug(words):
    kept = re.sub(r"[^a-z0-9]+", "-", words.lower()).strip("-")
    return kept[:40] or "q"


def article(name):
    paragraphs = "".join("<p>Paragraph %d about %s. It says useful things in plain words, and MARKER-%s is here.</p>" % (n, html.escape(name), html.escape(name)) for n in range(1, 6))
    return ("<!doctype html><html><head><title>Page %s</title></head><body>"
            "<nav>Home | About | Sign in</nav><header>Site header words</header>"
            "<main><article><h1>All about %s</h1>%s<p id=\"late\"></p></article></main>"
            "<footer>Footer words</footer>"
            "<script>document.getElementById('late').textContent = 'SCRIPTED-%s was added by the page itself.';</script>"
            "</body></html>") % (html.escape(name), html.escape(name), paragraphs, html.escape(name))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, status, body, kind="text/html; charset=utf-8", headers=None):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        agent = (self.headers.get("User-Agent") or "").split(" ")[0]
        with open(os.path.join(LOG, "requests.log"), "a", encoding="utf-8") as log:
            log.write("%s %s\n" % (self.path, agent))
        base = "http://127.0.0.1:%d" % self.server.server_address[1]
        if parsed.path == "/search":
            words = urllib.parse.parse_qs(parsed.query).get("q", [""])[0]
            # The pages' own words never say "captcha": only /check is a page asking for a person.
            name = slug(words.lower().replace("captcha", ""))
            links = []
            if "captcha" in words.lower():
                links.append(("%s/check" % base, "A page that checks"))
            links += [("%s/page/%s-%d" % (base, name, n), "Result %d for %s" % (n, words)) for n in range(1, 5)]
            items = "".join('<div class="result"><h2><a rel="nofollow" class="result__a" href="%s">%s</a></h2></div>' % (html.escape(href), html.escape(title)) for href, title in links)
            return self.send(200, "<!doctype html><html><head><title>%s at DuckDuckGo</title></head><body><div id=\"links\">%s</div></body></html>" % (html.escape(words), items))
        if parsed.path.startswith("/page/"):
            return self.send(200, article(parsed.path[len("/page/"):]))
        if parsed.path == "/check":
            return self.send(200, "<!doctype html><html><head><title>Just a moment...</title></head><body><p>Please verify you are human to continue.</p></body></html>")
        if parsed.path == "/moved":
            return self.send(302, "", headers={"Location": "http://192.168.0.1/admin-panel"})
        if parsed.path == "/blank":
            return self.send(200, "<!doctype html><html><head><title>Blank</title></head><body></body></html>")
        self.send(404, "not here", "text/plain")


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
