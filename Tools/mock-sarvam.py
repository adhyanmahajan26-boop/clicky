#!/usr/bin/env python3
"""A local stand-in for Sarvam's APIs, for testing Theo with no key and no spend.

It speaks the wire format from docs.sarvam.ai (read 2026-11-02): REST text-to-speech and speech-to-text, the text-to-speech
socket and both speech-to-text sockets. "Speech" is a tone and "listening" returns a line given on the command line. It proves
Theo's framing, flow and timing against the documented format; it can't prove Sarvam's real service accepts them.

  mock-sarvam.py [--port 8765] [--say "words it hears"] [--tts-delay 0.15] [--realtime-refused] [--mp3 file.mp3] [--log file]
  In Theo's test profile: uiSet test.sarvam.base = http://127.0.0.1:8765, and any key saved.
"""
import argparse, asyncio, base64, http, json, math, struct, sys, time
import websockets

args = None
LOG = []


def log(*parts):
    line = " ".join(str(p) for p in parts)
    LOG.append(line)
    print(line, flush=True)
    if args and args.log:
        with open(args.log, "a") as handle:
            handle.write(line + "\n")


def tone(seconds, rate=24000):
    return b"".join(struct.pack("<h", int(4000 * math.sin(2 * math.pi * 220 * n / rate))) for n in range(int(seconds * rate)))


def wav(pcm, rate=22050):
    return b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16) + b"data" + struct.pack("<I", len(pcm)) + pcm


def key_of(headers):
    return headers.get("Api-Subscription-Key") or headers.get("api-subscription-key")


async def tts_socket(ws):
    config = None
    log("tts: connected", ws.request.path)
    async for raw in ws:
        message = json.loads(raw)
        kind = message.get("type")
        if kind == "config":
            config = message["data"]
            missing = [f for f in ("speaker", "language_code") if f not in config]
            log("tts: config", json.dumps(config, sort_keys=True), "MISSING " + str(missing) if missing else "")
            if args.reject_linear16 and config.get("output_audio_codec") == "linear16":
                await ws.send(json.dumps({"type": "error", "data": {"message": "Only mp3 output_audio_codec is supported", "code": 400}}))
        elif kind == "text":
            log("tts: text", repr(message["data"]["text"][:80]))
            ws.pending = getattr(ws, "pending", "") + message["data"]["text"]
        elif kind == "flush":
            text = getattr(ws, "pending", "")
            ws.pending = ""
            log("tts: flush", len(text), "chars")
            if not text:
                continue
            await asyncio.sleep(args.tts_delay)
            seconds = max(0.4, len(text) * 0.05)
            codec = (config or {}).get("output_audio_codec", "mp3")
            if codec == "mp3":
                data = open(args.mp3, "rb").read()
                # Split anywhere, as a stream may.
                for start in range(0, len(data), 1777):
                    await ws.send(json.dumps({"type": "audio", "data": {"content_type": "audio/mp3", "audio": base64.b64encode(data[start:start + 1777]).decode(), "request_id": "mock"}}))
                    await asyncio.sleep(0.01)
            else:
                pcm = tone(seconds)
                for start in range(0, len(pcm), 9600):
                    await ws.send(json.dumps({"type": "audio", "data": {"content_type": "audio/l16;rate=24000", "audio": base64.b64encode(pcm[start:start + 9600]).decode(), "request_id": "mock"}}))
                    await asyncio.sleep(0.02)
            await ws.send(json.dumps({"type": "event", "data": {"event_type": "final", "message": "done", "timestamp": "2026-11-02T00:00:00Z"}}))
        elif kind == "ping":
            pass
        else:
            log("tts: UNKNOWN MESSAGE", raw[:120])
    log("tts: closed")


class Listener:
    """Finds the end of speech by level, as the real server's VAD would."""

    def __init__(self):
        self.loud = 0.0
        self.quiet = 0.0
        self.active = False

    def feed(self, pcm):
        count = len(pcm) // 2
        if not count:
            return None
        rms = math.sqrt(sum(s * s for (s,) in struct.iter_unpack("<h", pcm)) / count) / 32768
        seconds = count / 16000
        if rms > 0.01:
            self.loud += seconds
            self.quiet = 0
            if not self.active and self.loud > 0.12:
                self.active = True
                return "start"
        else:
            self.quiet += seconds
            if self.active and self.quiet > 0.5:
                self.active = False
                self.loud = 0
                return "end"
        return None


async def stt_realtime(ws):
    log("stt-realtime: connected", ws.request.path)
    await ws.send(json.dumps({"event": "session.begin", "request_id": "mock", "config": {}}))
    listener = Listener()
    utterance = 0
    words = args.say.split()
    async for raw in ws:
        message = json.loads(raw)
        if message.get("event") == "audio_input":
            state = listener.feed(base64.b64decode(message["audio"]))
            if state == "start":
                await ws.send(json.dumps({"event": "vad.speech_start", "utterance_idx": utterance, "confidence": "0.9"}))
                await ws.send(json.dumps({"event": "transcript.partial", "utterance_idx": utterance, "text": " ".join(words[:2])}))
            elif state == "end":
                await ws.send(json.dumps({"event": "vad.speech_end", "utterance_idx": utterance}))
                await asyncio.sleep(0.08)
                await ws.send(json.dumps({"event": "transcript.final", "utterance_idx": utterance, "text": args.say, "language": "en-IN", "language_confidence": 0.9}))
                log("stt-realtime: final sent")
                utterance += 1
        elif message.get("event") == "end":
            break
        else:
            log("stt-realtime: UNKNOWN MESSAGE", raw[:120])


async def stt_standard(ws):
    log("stt-standard: connected", ws.request.path)
    listener = Listener()
    async for raw in ws:
        message = json.loads(raw)
        if "audio" in message:
            audio = message["audio"]
            if not all(k in audio for k in ("data", "sample_rate", "encoding")):
                log("stt-standard: BAD AUDIO MESSAGE", raw[:120])
            state = listener.feed(base64.b64decode(audio["data"]))
            if state == "start":
                await ws.send(json.dumps({"type": "events", "data": {"event_type": "vad", "timestamp": 0, "signal_type": "START_SPEECH", "occured_at": 0}}))
            elif state == "end":
                await ws.send(json.dumps({"type": "events", "data": {"event_type": "vad", "timestamp": 0, "signal_type": "END_SPEECH", "occured_at": 0}}))
                await ws.send(json.dumps({"type": "data", "data": {"request_id": "mock", "transcript": args.say, "timestamps": None, "diarized_transcript": None, "language_code": "en-IN", "language_probability": 0.9, "metrics": {"audio_duration": 1, "processing_latency": 0.1}}}))
                log("stt-standard: final sent")
        elif message.get("type") == "flush":
            log("stt-standard: flush")
        else:
            log("stt-standard: UNKNOWN MESSAGE", raw[:120])


async def handler(ws):
    path = ws.request.path
    if not key_of(ws.request.headers):
        log("REFUSED, no key header", path)
        await ws.close(1003, "invalid key")
        return
    try:
        if path.startswith("/text-to-speech/ws"):
            await tts_socket(ws)
        elif path.startswith("/speech-to-text-realtime/ws"):
            if args.realtime_refused:
                log("stt-realtime: refusing, as the beta would")
                await ws.close(4000, "beta access denied")
                return
            await stt_realtime(ws)
        elif path.startswith("/speech-to-text/ws"):
            await stt_standard(ws)
        else:
            log("UNKNOWN SOCKET", path)
    except websockets.exceptions.ConnectionClosed:
        pass


def multipart_fields(body, boundary):
    fields = {}
    for part in body.split(b"--" + boundary):
        if b"name=\"" not in part:
            continue
        head, _, value = part.partition(b"\r\n\r\n")
        name = head.split(b"name=\"")[1].split(b"\"")[0].decode()
        fields[name] = len(value) if name == "file" else value.strip().decode()
    return fields


def http_reply(status, body):
    data = json.dumps(body).encode()
    return websockets.http11.Response(status.value, status.phrase, websockets.datastructures.Headers([("Content-Type", "application/json"), ("Content-Length", str(len(data)))]), data)


async def rest_server(reader, writer):
    """REST, on the next port up."""
    try:
        head = await reader.readuntil(b"\r\n\r\n")
        lines = head.decode().split("\r\n")
        path = lines[0].split(" ")[1]
        headers = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
        body = await reader.readexactly(int(headers.get("content-length", 0)))
        status, reply = 404, {"error": {"message": "not found"}}
        if "api-subscription-key" not in headers:
            status, reply = 403, {"error": {"message": "invalid key", "code": "invalid_api_key_error"}}
        elif path.startswith("/text-to-speech"):
            data = json.loads(body)
            log("rest tts:", json.dumps({k: v for k, v in data.items() if k != "text"}, sort_keys=True), repr(data.get("text", "")[:40]))
            await asyncio.sleep(args.tts_delay)
            status, reply = 200, {"request_id": "mock", "audios": [base64.b64encode(wav(tone(max(0.4, len(data.get("text", "")) * 0.05), 22050))).decode()]}
        elif path.startswith("/speech-to-text"):
            boundary = headers["content-type"].split("boundary=")[1].encode()
            fields = multipart_fields(body, boundary)
            log("rest stt:", json.dumps(fields, sort_keys=True))
            status, reply = 200, {"request_id": "mock", "transcript": args.say, "language_code": "en-IN", "language_probability": 0.9, "timestamps": None, "diarized_transcript": None}
        payload = json.dumps(reply).encode()
        writer.write(f"HTTP/1.1 {status} OK\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\nConnection: close\r\n\r\n".encode() + payload)
        await writer.drain()
    finally:
        writer.close()


async def main():
    async with websockets.serve(handler, "127.0.0.1", args.port, max_size=2**24, process_request=None):
        rest = await asyncio.start_server(rest_server, "127.0.0.1", args.port + 1)
        log(f"mock sarvam: sockets on {args.port}, REST on {args.port + 1}")
        async with rest:
            await asyncio.Future()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--say", default="hello from the mock listener")
    parser.add_argument("--tts-delay", type=float, default=0.15)
    parser.add_argument("--realtime-refused", action="store_true")
    parser.add_argument("--reject-linear16", action="store_true")
    parser.add_argument("--mp3", default="")
    parser.add_argument("--log", default="")
    args = parser.parse_args()
    asyncio.run(main())
