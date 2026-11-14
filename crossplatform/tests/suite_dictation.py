"""Dictation's suite cases (theo-voice through theod's inbox), registered into suite.py's list by `register(test)`.

There's no microphone on a test machine, so `dictationTest {wav}` runs a WAV file through the same path a held chord does:
transcribe (stand-in services from fake_voice.py, or Windows' own recognizer on a Windows runner), then the clean-up.
"""
import json, math, os, struct, subprocess, sys, wave
import lib as T
from lib import P

VOICE_KEY = "sk-voice-" + "v01ce" * 6


def tone_wav(path, seconds=1.5, rate=16000, amplitude=0.4):
    """A WAV with sound in it (a silent file is refused before any service is asked)."""
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(rate)
        frames = b"".join(struct.pack("<h", int(amplitude * 32767 * math.sin(2 * math.pi * 300 * i / rate))) for i in range(int(seconds * rate)))
        out.writeframes(frames)
    return path


class FakeVoice:
    def __init__(self):
        self.log = T.ROOT / ("voice-log-%s" % T.nonce()[:6])
        env = dict(os.environ, FAKE_VOICE_KEY=VOICE_KEY)
        self.process = subprocess.Popen([T.PY, str(T.HERE / "fake_voice.py"), str(self.log)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
        self.port = int(self.process.stdout.readline().strip())
        self.base = "http://127.0.0.1:%d" % self.port

    def requests(self, path_part=""):
        found = []
        for path in sorted(self.log.glob("*.json")) if self.log.exists() else []:
            entry = json.loads(path.read_text(encoding="utf-8"))
            if path_part in entry.get("path", ""):
                found.append(entry)
        return found

    def stop(self):
        self.process.kill()


def dset(key, value):
    return P({"cmd": "dictationSet", "key": key, "value": value})


def register(test):
    @test("D01", "Dictation: a WAV through transcribe (OpenAI, Sarvam, Deepgram stand-ins) and the clean-up brain, with the Mac's rules; keys never shown", "dictation")
    def d01():
        voice = FakeVoice()
        wav = tone_wav(T.ROOT / "dictation-test.wav")
        checks, evidence = {}, {}
        try:
            for provider in ("openai", "sarvam", "deepgram"):
                P({"cmd": "dictationKeySet", "provider": provider, "key": VOICE_KEY})
            T.setd("test.dictation.baseURL.openai", voice.base + "/openai/v1")
            T.setd("test.dictation.baseURL.sarvam", voice.base + "/sarvam")
            T.setd("test.dictation.baseURL.deepgram", voice.base)
            T.setd("brains.apiBaseURL.openai", voice.base + "/openai/v1")
            dset("cleanupBrain", "api:openai")
            dset("cleanup", True)
            dset("engine", "openai")

            tidied = P({"cmd": "dictationTest", "wav": str(wav)}, timeout=60)
            evidence["openai"] = tidied
            result = tidied.get("result", {})
            checks["openai_words"] = result.get("text") == "So I think we're going to ship it today."
            checks["openai_engine"] = result.get("engine") == "openai" and result.get("cleanup") == "cleaned"
            heard = voice.requests("/audio/transcriptions")
            checks["openai_request"] = bool(heard) and heard[-1]["key_right"] and heard[-1]["wav"] and heard[-1].get("model") == "gpt-4o-transcribe"
            tidy = voice.requests("/chat/completions")
            checks["cleanup_request"] = bool(tidy) and tidy[-1]["dictation_prompt"] and tidy[-1].get("model") == "gpt-4.1-mini"

            dset("cleanup", False)
            raw = P({"cmd": "dictationTest", "wav": str(wav)}, timeout=60).get("result", {})
            evidence["cleanup_off"] = raw
            checks["local_pass_only"] = raw.get("text") == "So I think we're gonna ship it today." and raw.get("cleanup") == "off"

            dset("engine", "sarvam")
            sarvam = P({"cmd": "dictationTest", "wav": str(wav)}, timeout=60).get("result", {})
            sent = voice.requests("/speech-to-text")
            evidence["sarvam"] = {"result": sarvam, "request": sent[-1] if sent else None}
            checks["sarvam"] = sarvam.get("engine") == "sarvam" and bool(sent) and sent[-1]["key_right"] and {"model", "mode", "language_code", "file"} <= set(sent[-1].get("fields", []))

            dset("engine", "deepgram")
            deepgram = P({"cmd": "dictationTest", "wav": str(wav)}, timeout=60).get("result", {})
            checks["deepgram"] = deepgram.get("engine") == "deepgram" and any(r["key_right"] and r["wav"] for r in voice.requests("/v1/listen"))

            # A refused key says where to fix it, and never says the key.
            P({"cmd": "dictationKeySet", "provider": "openai", "key": "sk-wrong-key-123"})
            dset("engine", "openai")
            refused = P({"cmd": "dictationTest", "wav": str(wav)}, timeout=90)
            evidence["refused"] = refused
            checks["refused_plain"] = refused.get("ok") is False and "Settings › Dictation" in refused.get("error", "") and "sk-wrong" not in refused.get("error", "")

            status = P({"cmd": "dictationStatus"}, timeout=60)
            evidence["status"] = {k: status.get("result", {}).get(k) for k in ("engine", "wouldListen", "cleanup", "chord", "last", "hotkey", "cleanupBrain", "cleanupNote")}
            log = (T.ROOT / "theod.log").read_text(encoding="utf-8", errors="replace") if (T.ROOT / "theod.log").exists() else ""
            checks["no_key_shown"] = VOICE_KEY not in json.dumps(status) and VOICE_KEY not in log
            checks["status_has_no_words"] = "ship it" not in json.dumps(status.get("result", {}).get("last", {}))
            checks["unknown_still_unknown"] = "Unknown command" in P({"cmd": "dictationNonsense"}).get("error", "")
        finally:
            voice.stop()
            for provider in ("openai", "sarvam", "deepgram"):
                P({"cmd": "dictationKeyRemove", "provider": provider})
            for key in ("test.dictation.baseURL.openai", "test.dictation.baseURL.sarvam", "test.dictation.baseURL.deepgram", "brains.apiBaseURL.openai"):
                T.setd(key, None)
            dset("engine", "auto")
            dset("cleanup", True)
            dset("cleanupBrain", "auto")
        return all(checks.values()), dict(checks=checks, evidence=evidence)

    @test("D02", "Dictation with no key: Windows' own recognizer reads the WAV (on Windows), or plain words say what's missing", "dictation")
    def d02():
        wav = tone_wav(T.ROOT / "dictation-windows.wav")
        dset("engine", "windows")
        try:
            answer = P({"cmd": "dictationTest", "wav": str(wav)}, timeout=120)
        finally:
            dset("engine", "auto")
        text = answer.get("error", "") if not answer.get("ok") else answer.get("result", {}).get("text", "")
        if sys.platform == "win32":
            # A tone has no words: a recognizer that ran says it didn't catch that; a PC without one says how to add one.
            plain = answer.get("ok") or any(words in text for words in ("Didn't catch that", "no Windows speech recognizer", "no speech recognizer for", "heard no words"))
            ran = "couldn't start" not in text and "took too long" not in text
            return bool(plain and ran), {"answer": answer}
        return (answer.get("ok") is False and "only on Windows" in text), {"answer": answer}
