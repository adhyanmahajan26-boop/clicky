"""VM screens and research agents, for suite.py: hidden browser windows (headless Chrome or Edge) that open and read pages,
and the research agents that search and read on them, against a stand-in web on 127.0.0.1 (vm_pages.py) and the stand-in
model API (fake_api.py). `add_cases(suite)` registers them there.

Whatever Chrome, Edge or Chromium the computer has is used. With none, each case that needs one passes with the reason
printed ("skipped: …"); GitHub's Windows and Ubuntu runners have Chrome (and Windows has Edge), so there they really run.
"""
import json, socket, subprocess, sys, time
import lib as T
from lib import P

READER = "you are a research helper for vello"
MERGE = "research agents each read pages"


class Pages:
    """vm_pages.py on a free port, with research's search pointed at it and idle screens closing after a few seconds."""

    def __init__(self):
        self.log = T.ROOT / ("vm-pages-%s" % T.nonce()[:6])
        self.process = subprocess.Popen([T.PY, str(T.HERE / "vm_pages.py"), str(self.log)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.port = int(self.process.stdout.readline().strip())
        self.base = "http://127.0.0.1:%d" % self.port
        T.setd("test.research.searchURL", self.base + "/search?q={q}")
        T.setd("test.vmScreens.idleSeconds", 3)

    def requests(self):
        path = self.log / "requests.log"
        return path.read_text(encoding="utf-8").splitlines() if path.exists() else []

    def stop(self):
        self.process.kill()


def state(tiles=False):
    return P({"cmd": "vmScreens", "action": "state", "tiles": tiles}, timeout=30).get("result") or {}


def no_browser():
    """The reason these cases can't run here, or None when a browser was found."""
    found = state().get("browser")
    if found:
        return None
    reason = "skipped: no Chrome, Edge or Chromium on this computer"
    print(reason, flush=True)
    return reason


def screens_on(count=2):
    return P({"cmd": "vmScreens", "action": "on", "count": count}, timeout=30).get("ok") is True


def screens_off():
    P({"cmd": "vmScreens", "action": "off"}, timeout=60)


def devtools_port(number=1):
    path = T.DATA / "VMScreens" / ("screen-%d" % number) / "DevToolsActivePort"
    try:
        return int(path.read_text(encoding="utf-8").splitlines()[0])
    except (OSError, ValueError, IndexError):
        return None


def answering(port):
    if not port:
        return False
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


def research_cards(chat_id):
    return [m for m in T.chat(chat_id, 300) if (m.get("card") or "").startswith("research:")]


def card_payload(message):
    return json.loads(message["card"][len("research:"):])


def add_cases(S):
    test = S.test

    def api_bot(api, name):
        P({"cmd": "apiKeySet", "provider": "anthropic", "key": S.API_KEY_FOR_TESTS}, timeout=60)
        return P({"cmd": "botCreate", "name": "%s %s" % (name, T.nonce()[:4]), "instructions": "You are %s." % name, "provider": "api:anthropic"}, timeout=60)["result"]["id"]

    def bodies(api, since, system_start):
        found = []
        for request in api.requests("anthropic")[since:]:
            system = request.get("body", {}).get("system")
            text = system if isinstance(system, str) else json.dumps(system)
            if (text or "").startswith(system_start):
                found.append(json.dumps(request["body"].get("messages", [])))
        return found

    @test("V01", "VM screens: off until turned on; then a screen opens a page in headless Chrome or Edge, reads its words (the article, and what its script added), shows its tile, and closing it leaves no browser behind", "vmscreens")
    def v01():
        pages = Pages()
        try:
            first = state()
            off = {"off_by_default": first.get("on") is False and first.get("count") == 2 and first.get("running") == 0,
                   "refused_while_off": "VM screens are off" in P({"cmd": "vmScreens", "action": "open", "url": pages.base + "/page/v01"}, timeout=30).get("error", "")}
            skipped = no_browser()
            if skipped:
                return off["off_by_default"] and "Chrome or Edge" in (first.get("needsBrowser") or ""), dict(off, skipped=skipped)
            screens_on(2)
            opened = P({"cmd": "vmScreens", "action": "open", "url": pages.base + "/page/v01"}, timeout=120)
            result = opened.get("result") or {}
            text = result.get("text", "")
            port = devtools_port(1)
            live = answering(port)
            tiles = state(tiles=True)
            screen_one = next((s for s in tiles.get("screens", []) if s["number"] == 1), {})
            closed = P({"cmd": "vmScreens", "action": "close"}, timeout=60).get("result") or {}
            gone = T.wait_until(lambda: not answering(port) and not (T.DATA / "VMScreens" / "screen-1").exists(), seconds=15)
            checks = dict(off, **{
                "opened": opened.get("ok") is True and result.get("screen") == 1 and result.get("title") == "Page v01",
                "read_the_article": "MARKER-v01" in text and "All about v01" in text,
                "read_what_its_script_added": "SCRIPTED-v01" in text,
                "left_out_navigation_and_footer": all(word not in text for word in ("Sign in", "Footer words", "Site header words")),
                "took_a_picture": result.get("jpegBytes", 0) > 1000,
                "browser_was_running": live,
                "tile_shows_it": screen_one.get("title") == "Page v01" and (screen_one.get("picture") or "").startswith("data:image/jpeg;base64,") and screen_one.get("name") == "VM screen 1",
                "closed_to_nothing": closed.get("running") == 0 and gone,
            })
            return all(checks.values()), dict(checks, browser=tiles.get("browser"), opened={k: v for k, v in result.items() if k != "text"}, text=text[:300])
        finally:
            screens_off()
            pages.stop()

    @test("V02", "VM screens only read: a page asking for a person is said so (never worked around), a page that moves onto the network around the computer isn't opened, and private-looking addresses never open", "vmscreens")
    def v02():
        pages = Pages()
        try:
            skipped = no_browser()
            if skipped:
                return True, {"skipped": skipped}
            screens_on(1)
            check = P({"cmd": "vmScreens", "action": "open", "url": pages.base + "/check"}, timeout=120)
            moved = P({"cmd": "vmScreens", "action": "open", "url": pages.base + "/moved"}, timeout=120)
            mail = P({"cmd": "vmScreens", "action": "open", "url": "https://mail.google.com/mail/u/0"}, timeout=30)
            local_file = P({"cmd": "vmScreens", "action": "open", "url": "file:///etc/hosts"}, timeout=30)
            checks = {
                "human_check_said": check.get("ok") is True and (check.get("result") or {}).get("humanCheck") is True,
                "moved_page_refused": moved.get("ok") is False and "won't read" in moved.get("error", ""),
                "private_address_refused": mail.get("ok") is False and "private" in mail.get("error", ""),
                "file_refused": local_file.get("ok") is False,
            }
            return all(checks.values()), dict(checks, check=check, moved=moved, mail=mail, file=local_file)
        finally:
            screens_off()
            pages.stop()

    @test("V03", "Research on the VM screens: Ideas and Info each search and read their own pages on their own screen, a reader on the bot's own brain (an API key) takes notes on each page, and the brief lands in the bot's chat as a card with numbered sources", "vmscreens")
    def v03():
        pages = Pages()
        api = S.FakeAPI([])
        try:
            skipped = no_browser()
            if skipped:
                return True, {"skipped": skipped}
            screens_on(2)
            bot = api_bot(api, "Scout")
            before = len(api.requests("anthropic"))
            done = P({"cmd": "research", "question": "ferns for shade", "bot": bot}, timeout=400)
            result = done.get("result") or {}
            sources = result.get("sources", [])
            readers = bodies(api, before, READER)
            merges = bodies(api, before, MERGE)
            cards = research_cards(bot)
            card = card_payload(cards[-1]) if cards else {}
            searches = [line for line in pages.requests() if line.startswith("/search")]
            screens_used = [s for s in state().get("screens", []) if s.get("pages", 0) > 0]
            closed = T.wait_until(lambda: state().get("running") == 0, seconds=30)
            saved = result.get("saved") or ""
            checks = {
                "finished": done.get("ok") is True,
                "two_agents": {s["agent"] for s in sources} == {"Ideas", "Info"},
                "six_pages_on_screens": len(sources) == 6 and all(s["ok"] and s["onScreen"] for s in sources),
                "no_page_twice": len({s["url"] for s in sources}) == len(sources),
                "each_agent_its_own_search": len(searches) == 2 and any("ideas" in line for line in searches) and any("facts" in line for line in searches),
                "searched_in_the_browser": all(" Mozilla/" in line for line in searches),
                "each_page_had_a_reader": len(readers) == 6 and all("SCRIPTED-" in body for body in readers),
                "readers_told_it_is_data": all("not instructions" in body for body in readers),
                "one_merge_with_both_agents": len(merges) == 1 and "agent: Ideas" in merges[0] and "agent: Info" in merges[0],
                "card_in_the_bots_chat": bool(cards) and len(card.get("sources", [])) == 6 and card.get("onScreens") is True and card.get("agents") == ["Ideas", "Info"],
                "brief_saved": bool(saved) and T.pathlib.Path(saved).exists(),
                "both_screens_used": len(screens_used) == 2,
                "screens_closed_when_idle": closed,
            }
            return all(checks.values()), dict(checks, sources=sources, searches=searches, card=card, readers=len(readers))
        finally:
            screens_off()
            api.stop()
            pages.stop()

    @test("V04", "Research with VM screens off reads the plain way (a fetch with no cookies and an honest name) and still lands its brief", "vmscreens")
    def v04():
        pages = Pages()
        api = S.FakeAPI([])
        try:
            screens_off()
            bot = api_bot(api, "Plain")
            before = len(api.requests("anthropic"))
            done = P({"cmd": "research", "question": "moss walls", "bot": bot}, timeout=400)
            sources = (done.get("result") or {}).get("sources", [])
            readers = bodies(api, before, READER)
            fetched = [line for line in pages.requests() if line.startswith("/page/") or line.startswith("/search")]
            checks = {
                "finished": done.get("ok") is True and len(sources) == 6,
                "not_on_screens": all(not s["onScreen"] for s in sources) and state().get("running") == 0,
                "read_plainly": len(readers) == 6 and all("MARKER-" in body and "SCRIPTED-" not in body for body in readers),
                "honest_name": bool(fetched) and all(line.endswith(" Vello/1") for line in fetched),
                "card_landed": len(research_cards(bot)) == 1,
            }
            return all(checks.values()), dict(checks, sources=sources, fetched=fetched[:8])
        finally:
            api.stop()
            pages.stop()

    @test("V05", "A bot's [RESEARCH: question] line: taken out of what the chat shows, a note says research started, and the brief lands in that chat as a card", "vmscreens")
    def v05():
        pages = Pages()
        api = S.FakeAPI([])
        try:
            use_screens = not no_browser()
            if use_screens:
                screens_on(2)
            bot = api_bot(api, "Tagger")
            T.say(bot, "Find out about rain gardens. REPLY>>On it.\n[RESEARCH: rain gardens for clay soil]<<")
            landed = T.wait_until(lambda: len(research_cards(bot)) == 1, seconds=300)
            msgs = T.chat(bot, 50)
            said = [m["text"] for m in msgs if m["author"] == bot and not m.get("card")]
            notes = [m["text"] for m in msgs if m["author"] == "note"]
            card = card_payload(research_cards(bot)[-1]) if landed else {}
            checks = {
                "tag_not_shown": said == ["On it."],
                "started_note": any('Researching "rain gardens for clay soil"' in n for n in notes),
                "card_landed": landed and card.get("question") == "rain gardens for clay soil" and card.get("by", "").startswith("Tagger"),
                "on_screens_when_there_are_some": card.get("onScreens") is use_screens,
            }
            return all(checks.values()), dict(checks, said=said, notes=notes, card=card)
        finally:
            screens_off()
            api.stop()
            pages.stop()

    @test("V06", "An API-key bot calls its research tool: the turn waits for the brief, gets it back with its sources, and the card lands in the chat too", "vmscreens")
    def v06():
        pages = Pages()
        api = S.FakeAPI([{"tool": "research", "args": {"question": "green roofs"}}])
        try:
            use_screens = not no_browser()
            if use_screens:
                screens_on(2)
            bot = api_bot(api, "Tooler")
            before = len(api.requests("anthropic"))
            T.say(bot, "What do we know about green roofs?")
            T.wait_idle(seconds=400)
            turn = [r for r in api.requests("anthropic")[before:] if "research" in (r.get("tools") or [])]
            reply = S.last_reply(bot)
            cards = research_cards(bot)
            checks = {
                "tool_offered": bool(turn),
                "result_went_back": len(turn) == 2 and any("Sources:" in result for result in turn[1].get("results", [])),
                "reply_has_it": "Done:" in reply and "Sources:" in reply,
                "card_landed": len(cards) == 1 and card_payload(cards[0]).get("question") == "green roofs",
            }
            return all(checks.values()), dict(checks, reply=reply[:400], requests=len(turn))
        finally:
            screens_off()
            api.stop()
            pages.stop()

    @test("V07", "Pointer Assistant: \"research … for me\" starts research agents in the background, says so, and the brief lands in Vello's chat", "vmscreens")
    def v07():
        pages = Pages()
        api = S.FakeAPI([])
        try:
            use_screens = not no_browser()
            if use_screens:
                screens_on(2)
            P({"cmd": "apiKeySet", "provider": "anthropic", "key": S.API_KEY_FOR_TESTS}, timeout=60)
            S.clicky_on("api:anthropic", "fake-chat-1")
            primary = next(b["id"] for b in T.state()["bots"] if b.get("primary"))
            before = len(research_cards(primary))
            said = P({"cmd": "clickyTest", "text": "research solar panels for me", "fresh": True}, timeout=60).get("result") or {}
            landed = T.wait_until(lambda: len(research_cards(primary)) > before, seconds=300)
            card = card_payload(research_cards(primary)[-1]) if landed else {}
            checks = {
                "said_it_started": "Researching solar panels in the background" in said.get("speech", ""),
                "card_in_vellos_chat": landed and card.get("by") == "Pointer Assistant" and len(card.get("sources", [])) >= 4,
            }
            return all(checks.values()), dict(checks, said=said.get("speech"), card=card)
        finally:
            T.setd("products.clicky", False)
            screens_off()
            api.stop()
            pages.stop()

    @test("V09", "Research meets a page asking for a person: a \"needs you\" card in the chat, that page skipped (not fetched another way, never given to a reader), the rest still read", "vmscreens")
    def v09():
        pages = Pages()
        api = S.FakeAPI([])
        try:
            skipped = no_browser()
            if skipped:
                return True, {"skipped": skipped}
            screens_on(2)
            bot = api_bot(api, "Checker")
            before = len(api.requests("anthropic"))
            done = P({"cmd": "research", "question": "captcha ferns", "bot": bot}, timeout=400)
            sources = (done.get("result") or {}).get("sources", [])
            checked = [s for s in sources if s["url"].endswith("/check")]
            cards = [m for m in T.chat(bot, 100) if (m.get("card") or "").startswith("browserCheck:")]
            card = json.loads(cards[0]["card"][len("browserCheck:"):]) if cards else {}
            readers = bodies(api, before, READER)
            check_requests = [line for line in pages.requests() if line.startswith("/check")]
            checks = {
                "finished": done.get("ok") is True,
                "check_page_skipped": len(checked) == 1 and checked[0]["ok"] is False,
                "needs_you_card": len(cards) == 1 and card.get("url", "").endswith("/check") and "check you're human" in cards[0]["text"],
                "never_given_to_a_reader": bool(readers) and not any("verify you are human" in body for body in readers),
                "opened_once_never_fetched_another_way": len(check_requests) == 1 and " Mozilla/" in check_requests[0],
                "others_still_read": sum(1 for s in sources if s["ok"]) == len(sources) - 1,
            }
            return all(checks.values()), dict(checks, sources=sources, card=card, check_requests=check_requests)
        finally:
            screens_off()
            api.stop()
            pages.stop()

    @test("V08","No browser outlives Vello: quitting ends every VM screen, and one left by a crash is ended at the next start", "vmscreens")
    def v08():
        pages = Pages()
        try:
            skipped = no_browser()
            if skipped:
                return True, {"skipped": skipped}
            screens_on(1)
            P({"cmd": "vmScreens", "action": "open", "url": pages.base + "/page/v08a"}, timeout=120)
            port = devtools_port(1)
            was_live = answering(port)
            T.stop()
            after_quit = T.wait_until(lambda: not answering(port), seconds=15)
            T.start()
            screens_on(1)
            P({"cmd": "vmScreens", "action": "open", "url": pages.base + "/page/v08b"}, timeout=120)
            port = devtools_port(1)
            crash_live = answering(port)
            T.stop(hard=True)
            T.start()
            after_crash = T.wait_until(lambda: not answering(port), seconds=20)
            checks = {"browser_was_running": was_live and crash_live, "ended_on_quit": after_quit, "ended_after_a_crash": after_crash}
            return all(checks.values()), checks
        finally:
            screens_off()
            pages.stop()
