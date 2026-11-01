#!/usr/bin/env python3
"""Clicky's voice numbers against the running app (debug inbox), with the real voice playing at zero volume.

  ttfa       keyUp to first audio on short answers
  long       long answers play to their last segment, at a believable speed
  interrupt  Esc, push-to-talk, "stop" on the open mic and a new question each cut the voice off; how fast

Nothing is audible (testMute realVoice) and nothing takes focus. Usage: python3 -I Tools/eval/voice_numbers.py [--only ttfa,long,interrupt]
Prints JSON lines and a summary; exits 1 if a check failed.
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import threading
import time

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CLICKYCTL = os.path.join(REPO_ROOT, "Tools", "clickyctl.sh")

SHORT_ASKS = ["what's the capital of Japan?", "give me one tip for sleeping better", "what's 17 plus 26?",
              "in one line, what is DNS?", "who wrote Hamlet?", "how many legs does a spider have?",
              "what does HTTP stand for?", "in one line, why is the sky blue?"]
LONG_ASKS = ["explain how a car engine works, in about 200 words, in plain talk with no lists",
             "walk me through how a web page gets from a server to my screen, in about 250 words, no lists",
             "tell me the story of the Apollo 11 landing, in about 300 words, no lists"]
INTERRUPT_ASK = "explain how vaccines train the immune system, in about 200 words, no lists"
FOLLOW_UP = "what's 12 times 12?"


def ctl(command, timeout_seconds=240):
    completed = subprocess.run([CLICKYCTL, json.dumps(command), str(timeout_seconds)], capture_output=True, text=True)
    try:
        return json.loads(completed.stdout.strip() or "{}")
    except ValueError:
        return {"ok": False, "error": completed.stdout[:200]}


def turn_of(reply):
    turn_dir = reply.get("turnDir")
    if not turn_dir:
        return {}
    try:
        with open(os.path.join(turn_dir, "turn.json")) as turn_file:
            return json.load(turn_file)
    except (OSError, ValueError):
        return {}


def speech_state():
    return ctl({"cmd": "speechState"}, 10).get("result") or {}


def start_ask(text, prewarm_ms=800):
    """Runs the ask on a thread. Returns the thread and a dict that gets the reply."""
    box = {}

    def run():
        box["reply"] = ctl({"cmd": "ask", "text": text, "speak": True, "prewarmMs": prewarm_ms}, 300)

    thread = threading.Thread(target=run)
    thread.start()
    return thread, box


def wait_speaking(timeout_seconds=60):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        state = speech_state()
        if state.get("isPlaying") or state.get("captionCurrent"):
            return True
        time.sleep(0.1)
    return False


def wait_silent(timeout_seconds=240):
    start = time.time()
    while time.time() - start < timeout_seconds:
        if not speech_state().get("isSpeaking"):
            return time.time() - start
        time.sleep(0.05)
    return None


def case_ttfa():
    rows = []
    for text in SHORT_ASKS:
        ctl({"cmd": "reset"}, 10)
        reply = ctl({"cmd": "ask", "text": text, "speak": True, "prewarmMs": 800}, 120)
        turn = turn_of(reply)
        timings = turn.get("timings") or {}
        wait_silent()
        rows.append({"ask": text, "engine": (turn.get("speech") or {}).get("engine") or reply.get("engine"),
                     "firstText": round(timings.get("firstDelta", 0) - timings.get("keyUp", 0), 2),
                     "firstAudio": round(timings.get("firstAudio", 0) - timings.get("keyUp", 0), 2) if timings.get("firstAudio") else None,
                     "usedFallback": (turn.get("speech") or {}).get("fallback")})
        print(json.dumps(rows[-1]), flush=True)
    audio = [r["firstAudio"] for r in rows if r["firstAudio"]]
    ok = len(audio) == len(rows)
    summary = f"first audio median {statistics.median(audio):.2f} s, worst {max(audio):.2f} s, n={len(audio)}" if audio else "no audio"
    return ok, summary


def case_long():
    all_ok = True
    lines = []
    for text in LONG_ASKS:
        ctl({"cmd": "reset"}, 10)
        started = time.time()
        thread, box = start_ask(text)
        wait_speaking()
        last_caption = None
        seen_captions = 0
        while True:
            state = speech_state()
            caption = state.get("captionCurrent")
            if caption and caption != last_caption:
                last_caption = caption
                seen_captions += 1
            if not state.get("isSpeaking") and not thread.is_alive():
                break
            if time.time() - started > 280:
                break
            time.sleep(0.2)
        thread.join(30)
        turn = turn_of(box.get("reply") or {})
        timings = turn.get("timings") or {}
        segments = turn.get("segments") or []
        words = len(" ".join(segments).split())
        spoken_seconds = timings.get("end", 0) - timings.get("firstAudio", 0)
        speech = turn.get("speech") or {}
        # Normal speech is 2 to 4 words a second, so much faster means audio got cut.
        finished_all = bool(last_caption) and bool(segments) and last_caption.strip().split()[-1:] == segments[-1].strip().split()[-1:]
        believable = spoken_seconds > 0 and words / spoken_seconds < 4.5
        ok = finished_all and believable and not speech.get("fallback") and words >= 80
        all_ok = all_ok and ok
        row = {"ask": text[:40], "ok": ok, "words": words, "segments": len(segments), "captionsSeen": seen_captions,
               "spokenSeconds": round(spoken_seconds, 1), "wordsPerSecond": round(words / spoken_seconds, 2) if spoken_seconds > 0 else None,
               "fallback": speech.get("fallback"), "lastCaptionEndsAnswer": finished_all, "firstAudio": round(timings.get("firstAudio", 0) - timings.get("keyUp", 0), 2)}
        print(json.dumps(row), flush=True)
        lines.append(f"{words} words in {spoken_seconds:.0f} s")
    return all_ok, "; ".join(lines)


def interrupt(trigger):
    ctl({"cmd": "reset"}, 10)
    thread, box = start_ask(INTERRUPT_ASK)
    if not wait_speaking():
        thread.join(60)
        return {"trigger": trigger, "ok": False, "error": "never spoke"}
    time.sleep(3)
    was_speaking = speech_state().get("isSpeaking")
    if trigger == "stopWord":
        answer = ctl({"cmd": "heard", "text": "stop"}, 10).get("result") or {}
    elif trigger == "newQuestion":
        second_thread, second_box = start_ask(FOLLOW_UP)
        answer = {}
    else:
        answer = ctl({"cmd": "bargeIn", "trigger": trigger}, 10).get("result") or {}
    started = time.time()
    if trigger == "newQuestion":
        # The old answer's audio has to stop before the new one starts.
        second_thread.join(120)
        turn = turn_of(second_box.get("reply") or {})
        thread.join(60)
        first_turn = turn_of(box.get("reply") or {})
        wait_silent()
        said = " ".join(turn.get("segments") or [])
        ok = "144" in said or "forty" in said.lower()
        return {"trigger": trigger, "ok": ok and was_speaking, "secondAnswer": said[:60],
                "firstEnded": round((first_turn.get("timings") or {}).get("end", 0) - (turn.get("timings") or {}).get("keyUp", 0), 2)}
    stopped_after = wait_silent(15)
    thread.join(60)
    return {"trigger": trigger, "ok": bool(was_speaking) and stopped_after is not None and stopped_after < 1.0,
            "wasSpeaking": was_speaking, "stoppedAfterSeconds": round(stopped_after, 2) if stopped_after is not None else None, "reply": answer}


def case_interrupt():
    rows = []
    for trigger in ["escape", "pushToTalk", "voiceCommand", "stopWord", "newQuestion"]:
        rows.append(interrupt(trigger))
        print(json.dumps(rows[-1]), flush=True)
        time.sleep(2)
    times = [r.get("stoppedAfterSeconds") for r in rows if r.get("stoppedAfterSeconds") is not None]
    return all(r.get("ok") for r in rows), f"stopped in at most {max(times):.2f} s" if times else "no timing"


CASES = {"ttfa": case_ttfa, "long": case_long, "interrupt": case_interrupt}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", default="")
    arguments = parser.parse_args()
    names = [n.strip() for n in arguments.only.split(",") if n.strip()] or list(CASES)
    if not ctl({"cmd": "ping"}, 10).get("ok"):
        sys.exit("Clicky isn't answering the debug inbox")
    ctl({"cmd": "testMute", "on": True, "realVoice": True}, 10)
    results = []
    try:
        for name in names:
            passed, detail = CASES[name]()
            results.append(passed)
            print(f"{'PASS' if passed else 'FAIL'}  {name:10s} {detail}", flush=True)
    finally:
        ctl({"cmd": "testMute", "on": False}, 10)
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
