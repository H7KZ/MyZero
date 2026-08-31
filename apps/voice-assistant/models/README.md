# models/

Large model files live here on the Pi but are **gitignored** (tens of MB each).
Download them on the device; only this README is tracked.

Expected files (paths referenced by `.env`):

| File | What | How to get it |
|------|------|---------------|
| `vosk-model-small-cs/` | Vosk small Czech STT model (used for both wake word and commands) | Download + unzip from <https://alphacephei.com/vosk/models> (small Czech model). |
| `cs_CZ-*.onnx` (+ `.onnx.json`) | Piper Czech voice for spoken replies | Download a `cs_CZ` voice from the Piper voices release. |

The wake word needs no separate model — it's a word the Vosk model already
transcribes (set `WAKE_WORD` to its lowercase spelling). Keep filenames in sync
with `apps/voice-assistant/.env`.
