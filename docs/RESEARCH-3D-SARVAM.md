# Research notes (2026-11-01)

## Clicky's 3D feature
- It's in the closed-source HeyClicky app (heyclicky.com), not in the open farzaa/clicky repo (frozen since 27 Apr 2026).
- Release v1.1.1 (23 Oct 2026, mirrored in prasanthsasikumar/openclicky issue #17): "HeyClicky can draw in 3D, 2D and much more". When the answer is a real thing (an engine, a molecule, a building) it builds a 3D model you can drag around and click any part to ask about it; explanations come as cards with real photos.
- How it's built is not public. Because the model appears as the answer arrives, it is most likely the LLM writing a small labelled scene (parts as primitives/glTF + names), not slow image-to-3D. (Inference.)
- For Theo: the LLM emits a JSON/three.js scene with named, labelled parts; a WKWebView renders it with three.js; clicking a part sends "tell me about <part>" plus context. Real-asset option later: Meshy / Tripo / Rodin (paid APIs) or local Hunyuan3D-2 / TRELLIS (GPU, ask first).

## Sarvam AI (api.sarvam.ai, header api-subscription-key)
- Speech-to-text: saaras:v4 (REST 30 s max; WebSocket streaming; codemix mode for Hinglish; auto language detect). ₹0.49/min.
- Text-to-speech: bulbul:v4-flash (200+ voices, Hinglish `enhi`), bulbul:v3. REST, HTTP stream, WebSocket. ₹1 per 1k chars (v4 flash).
- Translate (mayura, sarvam-translate), transliterate, text language ID.
- LLM: sarvam-105b (128K, OpenAI-compatible /v2/chat/completions); also hosts glm5.3, gemma4, deepseekv4.1-flash and more.
- Voice cloning (beta), dubbing (beta), document AI (Sarvam Vision), Voice Agents platform (Samvaad, phone/web).
- Fit for Clicky voice calls: Saaras v4 streaming STT (codemix) → Claude (screen vision) → Bulbul v4 flash streaming TTS (Hinglish voices).
