# models/

Large model files live here on the Pi but are **gitignored** (tens of MB each).
Download/train them on the device; only this README is tracked.

Expected files (paths referenced by `.env`):

| File | What | How to get it |
|------|------|---------------|
| `jarvis.rpw` | rustpotter wake-word model | Train from your own recordings (see app README → "Train the wake word"). |
| `vosk-model-small-cs/` | Vosk small Czech STT model | Download + unzip from <https://alphacephei.com/vosk/models> (small Czech model). |
| `cs_CZ-*.onnx` (+ `.onnx.json`) | Piper Czech voice | Download a `cs_CZ` voice from the Piper voices release. |

Keep the filenames in sync with `apps/voice-assistant/.env`.
