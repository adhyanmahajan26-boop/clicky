#!/usr/bin/env python3
"""Calls with any bot, in a test profile of its own (`test-botcalls`), on a stand-in brain: no network, no real key.

  python3 Tools/tests/call_any_bot.py --app <Clicky.app or its binary> --out <folder>

Checks, against the real app:
  1. A call with a bot that isn't Vello's own: the window is "Call with <name>", the call's prompt has the bot's name,
     instructions, nature, memory and own chat and none of Vello's controls, it thinks with the bot's own engine and
     model, and nothing of a thinking model's thinking or its [TELL: …] line is ever in the call's lines.
  2. The same for a model that starts mid-think and one whose server sends reasoning_content.
  3. One call at a time: asking for another bot while a call runs brings up the running one.
  4. A bot whose engine can't take a call says so on the call, with its fix.
  5. A bot's own call voice is the one its call speaks with.
  6. A bot's instructions.md wins over its settings field, and nature.md comes right after, in its chat prompt.
  7. Normal bot chat over an API key never shows the thinking either.
  8. The call's transcript lands in that bot's own chat, titled with its name.

Uses Tools/tests/stand_in_openai.py, which plays thinking models (see its docstring). Never touches the owner's Vello.
"""
import argparse, json, os, pathlib, shutil, subprocess, sys, time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from stranger_mac import Profile, start_stand_in_provider, stand_in_requests, custom_provider_data, system_text, PROVIDER_ID, AGENTS  # noqa: E402

SECRET = "SECRET-THOUGHT"
OWNER = "Priya"


def wipe(profile):
    """A fresh profile: its folder and preferences gone. Test secrets live in its own file, so nothing touches the Keychain."""
    profile.stop()
    shutil.rmtree(profile.root, ignore_errors=True)
    subprocess.run(["defaults", "delete", profile.domain], capture_output=True)


def installed_english_voice():
    """An English voice installed on this Mac, by its id: what the bot's settings would offer."""
    script = 'import AVFoundation\nfor v in AVSpeechSynthesisVoice.speechVoices() where v.language.hasPrefix("en") && v.identifier.contains(".compact.") { print(v.identifier) }\n'
    listed = subprocess.run(["swift", "-"], input=script, capture_output=True, text=True, timeout=120).stdout.split()
    return listed[0] if listed else ""


def wait_for_call(profile, done, seconds=60):
    deadline = time.time() + seconds
    status = {}
    while time.time() < deadline:
        status = profile.result({"cmd": "uiCallStatus"})
        if done(status):
            return status
        time.sleep(0.4)
    return status


def bot_lines(status):
    return [line.get("text", "") for line in status.get("lines", []) if line.get("who") == "theo"]


def answered(status):
    lines = [line for line in status.get("lines", []) if line.get("who") == "theo"]
    return bool(lines) and not lines[-1].get("live") and bool(lines[-1].get("text"))


def end_call(profile):
    profile.send({"cmd": "uiCallEnd"})
    time.sleep(1.0)


def check(results, name, ok, detail=""):
    results.append({"check": name, "ok": bool(ok), "detail": detail})
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  -> " + str(detail)[:600]), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    options = parser.parse_args()
    app = pathlib.Path(options.app)
    binary = str(app / "Contents/MacOS/Clicky") if app.suffix == ".app" else str(app)
    out = pathlib.Path(options.out)
    out.mkdir(parents=True, exist_ok=True)
    record = out / "stand-in-requests"
    shutil.rmtree(record, ignore_errors=True)
    server, port = start_stand_in_provider(record)
    profile = Profile("botcalls")
    wipe(profile)
    profile.write_default("v2.setup.completed", "-bool", "true")
    profile.write_default("test.engines.missing", "-array", *AGENTS)
    profile.write_default("theo.providers.custom", "-data", custom_provider_data(port))
    results = []
    try:
        profile.start(binary)
        profile.result({"cmd": "uiTestKey", "provider": PROVIDER_ID, "value": "sk-not-a-real-key"})
        profile.send({"cmd": "uiSet", "key": "v4.owner.name", "value": OWNER})
        # The key list is read at launch: start again so the stand-in counts as a brain.
        profile.stop()
        profile.start(binary)

        api = "api:" + PROVIDER_ID
        made = {}
        for name, model in [("Ledger", "stand-in-thinker"), ("Mira", "stand-in-qwen3-midthink"), ("Orin", "stand-in-reasoner")]:
            made[name] = profile.result({"cmd": "botCreate", "name": name, "description": "test bot", "provider": api, "model": model,
                                         "instructions": "You are %s, who keeps the household accounts." % name}).get("id")
        made["Grokker"] = profile.result({"cmd": "botCreate", "name": "Grokker", "provider": "grok", "model": "grok-5"}).get("id")
        ledger = made["Ledger"]
        check(results, "bots made", all(made.values()), made)

        # 6. Own files: instructions.md wins, nature.md right after.
        files = profile.result({"cmd": "botUpdate", "id": ledger, "makeFile": "nature"})
        nature_file = pathlib.Path(files.get("natureFile", ""))
        nature_file.write_text("<!-- note -->\nDry, exact and fond of round numbers.\n", encoding="utf-8")
        profile.result({"cmd": "botUpdate", "id": ledger, "makeFile": "instructions"})
        instructions_file = pathlib.Path(files.get("instructionsFile", ""))
        made_from_field = instructions_file.read_text(encoding="utf-8") if instructions_file.exists() else ""
        check(results, "instructions file starts as the field", "keeps the household accounts" in made_from_field, made_from_field)
        instructions_file.write_text("You are Ledger. FROM-THE-FILE: you answer about money only.\n", encoding="utf-8")
        persona = profile.result({"cmd": "uiBotPrompt", "bot": ledger}).get("persona", "")
        check(results, "instructions file wins over the field", persona.startswith("You are Ledger. FROM-THE-FILE") and "keeps the household accounts" not in persona, persona[:300])
        check(results, "nature comes right after the instructions",
              "FROM-THE-FILE: you answer about money only.\n\nYour nature:\nDry, exact and fond of round numbers." in persona and "<!-- note -->" not in persona, persona[:400])
        # Editing the field writes the file.
        profile.result({"cmd": "botUpdate", "id": ledger, "instructions": "You are Ledger. EDITED-IN-SETTINGS."})
        check(results, "editing the field writes the instructions file", "EDITED-IN-SETTINGS" in instructions_file.read_text(encoding="utf-8"),
              instructions_file.read_text(encoding="utf-8"))

        # Ledger's memory and a line of its own chat, for the call's prompt.
        memory = pathlib.Path(profile.result({"cmd": "uiBotPrompt", "bot": ledger}).get("memory", ""))
        memory.parent.mkdir(parents=True, exist_ok=True)
        memory.write_text("- The rent is due on the 5th.\n", encoding="utf-8")

        # 7. Normal chat over an API key: no thinking, no matter how the model sends it.
        for name in ["Ledger", "Mira", "Orin"]:
            before = len(profile.chat(made[name], 60))
            profile.send({"cmd": "botSay", "bot": made[name], "text": "How much is left this month?"})
            reply = profile.wait_for_reply(made[name], before, 90)
            check(results, "chat over an API key shows no thinking (%s)" % name, reply and SECRET not in reply and "<think" not in reply and "</think" not in reply, reply)

        # 5. Ledger's own call voice (no Sarvam key here, so the Mac's voices).
        apple_voice = installed_english_voice()
        profile.result({"cmd": "botUpdate", "id": ledger, "callVoice": "apple:" + apple_voice})

        # 1. A call with Ledger.
        asked = len(stand_in_requests(record))
        started = profile.result({"cmd": "uiCallStart", "bot": ledger})
        check(results, "the call window is titled with the bot's name", started.get("title") == "Call with Ledger", started)
        status = wait_for_call(profile, answered)
        (out / "call-ledger.json").write_text(json.dumps(status, indent=2))
        check(results, "the call is with Ledger", status.get("botID") == ledger and status.get("botName") == "Ledger" and not status.get("isVellosOwnBot"), status.get("botID"))
        lines = bot_lines(status)
        check(results, "Ledger said hello on the call", any("Stand-in here." in line for line in lines), lines)
        check(results, "no thinking and no [TELL: …] on the call", all(SECRET not in l and "think>" not in l and "[" not in l and "book the room" not in l for l in lines), lines)
        requests = stand_in_requests(record)[asked:]
        call_requests = [r for r in requests if "live voice call" in system_text(r)]
        system = system_text(call_requests[0]) if call_requests else ""
        (out / "call-ledger-system-prompt.txt").write_text(system)
        check(results, "the call thinks with Ledger's own model", bool(call_requests) and call_requests[0].get("model") == "stand-in-thinker", [r.get("model") for r in requests])
        check(results, "the call asks for room to think (max_tokens)", bool(call_requests) and call_requests[0].get("max_tokens", 0) >= 16384, call_requests[0].get("max_tokens") if call_requests else None)
        check(results, "the call's prompt is Ledger's", all(part in system for part in ["You are Ledger.", "EDITED-IN-SETTINGS", "Your nature:\nDry, exact", "The rent is due on the 5th", "On this call you only talk.", "live voice call with Priya"]), system[:1500])
        check(results, "the call's prompt has none of Vello's controls", not any(c in system for c in ["[CLICKY", "[POINTER", "[ROUTINE", "[TELL: Vello", "Pointer Assistant works for you"]), system[:1500])
        check(results, "Ledger's call speaks with Ledger's own voice", status.get("appleVoiceUsed") == apple_voice or not apple_voice, status.get("appleVoiceUsed"))

        # 3. One call at a time.
        again = profile.result({"cmd": "uiCallStart", "bot": made["Mira"]})
        check(results, "another bot while a call runs brings up the running call", again.get("botID") == ledger and again.get("title") == "Call with Ledger", again)
        # A second turn, as if said before the call ("hey …, what's left?").
        profile.result({"cmd": "uiCallStart", "bot": ledger, "openingWords": "What's left this month?"})
        status = wait_for_call(profile, lambda s: len(bot_lines(s)) >= 2 and answered(s))
        lines = bot_lines(status)
        check(results, "a second turn answers without thinking or tags", len(lines) >= 2 and all(SECRET not in l and "[" not in l for l in lines), lines)
        end_call(profile)
        chat = profile.chat(ledger, 60)
        recorded = [m.get("text", "") for m in chat if (m.get("text") or "").startswith("📞 Call with Ledger")]
        check(results, "the call's transcript is in Ledger's own chat", bool(recorded) and "**Ledger:**" in recorded[-1], recorded[-1:] or [m.get("text", "")[:80] for m in chat[-3:]])
        vello_chat = profile.chat("theo", 60)
        check(results, "and not in Vello's", not any("Call with Ledger" in (m.get("text") or "") for m in vello_chat))

        # 2. Mid-think and reasoning_content on a call.
        for name in ["Mira", "Orin"]:
            profile.result({"cmd": "uiCallStart", "bot": made[name]})
            status = wait_for_call(profile, answered)
            lines = bot_lines(status)
            (out / ("call-%s.json" % name.lower())).write_text(json.dumps(status, indent=2))
            check(results, "call with %s: answer spoken, no thinking, no tags" % name,
                  any("Stand-in here." in l for l in lines) and all(SECRET not in l and "think>" not in l and "[" not in l for l in lines), lines)
            end_call(profile)

        # 4. An engine that can't take a call.
        profile.result({"cmd": "uiCallStart", "bot": made["Grokker"]})
        status = wait_for_call(profile, lambda s: bool(bot_lines(s)))
        lines = bot_lines(status)
        check(results, "a bot on Grok says on the call it can't take one, and the fix",
              any("can't take a voice call yet" in l and "Grokker's settings" in l for l in lines) and "can't take a voice call" in status.get("problem", ""), [lines, status.get("problem")])
        end_call(profile)

        # Vello's own call still has its controls.
        profile.result({"cmd": "uiCallStart"})
        status = wait_for_call(profile, lambda s: bool(s.get("lines")) or bool(s.get("problem")), 20)
        check(results, "a call with no bot is Vello's own", status.get("isVellosOwnBot") is True and status.get("botID") == "theo", status.get("botID"))
        end_call(profile)
    finally:
        profile.stop()
        server.terminate()
        (out / "results.json").write_text(json.dumps(results, indent=2))
    passed = sum(1 for r in results if r["ok"])
    print("\n%d of %d checks passed" % (passed, len(results)))
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
