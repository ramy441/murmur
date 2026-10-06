#!/usr/bin/env python3
"""Persistent Parakeet worker with an optional local cleanup model.

Loads the models once at startup, then answers one request per stdin line with
one JSON line on stdout. A request is a WAV path, or JSON {"path": ..., "polish": bool}.
Keeping it resident is what buys sub-second dictation — a cold `import mlx` costs
more than the transcription itself.
"""
import json
import os
import sys
import time
import wave

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

CACHE_LIMIT_BYTES = 512 * 1024 * 1024
FOOTPRINT_WARN_BYTES = 6 * 1024 * 1024 * 1024
CHUNK_THRESHOLD_SECONDS = 30.0
CHUNK_DURATION_SECONDS = 20.0
CHUNK_OVERLAP_SECONDS = 2.0


POLISH_MIN_WORDS = 3
POLISH_MAX_TOKENS = 700
POLISH_SYSTEM = """You are a dictation cleanup filter. Input is raw speech-to-text. Return the same text, cleaned:
- Delete filler words and sounds: uh, um, er, hmm, "like" when used as filler, "you know", "I mean" when used as filler, "so" at the start of a sentence, "basically", "actually" when meaningless.
- Delete false starts and stutters: "my sentence, my sentences" becomes "my sentences"; "or uh or do you" becomes "or do you".
- Apply the speaker's self-corrections: "on Monday, no, on Tuesday" becomes "on Tuesday".
- Fix punctuation and capitalization. Capitalize product names.
- Keep every idea, every fact and the speaker's own wording and language. Never add, answer, summarize, translate or reorder. Never comment.
Output only the cleaned text, nothing else."""


class Polisher:
    def __init__(self, model_id):
        from mlx_lm import load
        self.model, self.tokenizer = load(model_id)
        self.model_id = model_id

    def run(self, text):
        from mlx_lm import generate
        messages = [{"role": "system", "content": POLISH_SYSTEM}, {"role": "user", "content": text}]
        kwargs = {"add_generation_prompt": True, "tokenize": False}
        if "qwen3" in self.model_id.lower():
            kwargs["enable_thinking"] = False
        prompt = self.tokenizer.apply_chat_template(messages, **kwargs)
        out = generate(self.model, self.tokenizer, prompt=prompt, max_tokens=POLISH_MAX_TOKENS, verbose=False)
        return out.strip().strip('"').strip()


def plausible(raw, clean):
    # a cleanup only removes fillers, so a big shrink or any growth means the model wandered
    n_raw, n_clean = len(raw.split()), len(clean.split())
    if n_clean == 0:
        return False
    if n_clean > n_raw + 3:
        return False
    return n_clean >= max(1, int(n_raw * 0.55))


def emit(payload):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def wav_duration_seconds(path):
    with wave.open(path, "rb") as handle:
        frames = handle.getnframes()
        rate = handle.getframerate()
        return frames / float(rate) if rate else 0.0


def main():
    model_id = os.environ.get("MURMUR_PARAKEET_MODEL", "mlx-community/parakeet-tdt-0.6b-v3")
    try:
        import mlx.core as mx
        from parakeet_mlx import from_pretrained
        model = from_pretrained(model_id)
    except Exception as exc:
        emit({"error": f"load failed: {exc}"})
        return 1

    # mlx never clears its buffer cache on its own, so freed metal buffers never return to the os
    mx.set_cache_limit(CACHE_LIMIT_BYTES)

    polisher = None
    polish_id = os.environ.get("MURMUR_POLISH_MODEL", "mlx-community/Qwen3-4B-Instruct-2507-4bit")
    if polish_id:
        try:
            polisher = Polisher(polish_id)
        except Exception as exc:
            print(f"parakeetd: cleanup model unavailable, raw transcripts only: {exc}", file=sys.stderr)

    emit({"ready": True, "model": model_id, "polish": polisher.model_id if polisher else None})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        want_polish = polisher is not None
        path = line
        if line.startswith("{"):
            try:
                request = json.loads(line)
                path = request.get("path", "")
                want_polish = want_polish and bool(request.get("polish", True))
            except Exception:
                emit({"error": "bad request line"})
                continue
        try:
            try:
                duration = wav_duration_seconds(path)
            except Exception:
                duration = 0.0
            if duration > CHUNK_THRESHOLD_SECONDS:
                result = model.transcribe(
                    path, chunk_duration=CHUNK_DURATION_SECONDS, overlap_duration=CHUNK_OVERLAP_SECONDS
                )
            else:
                result = model.transcribe(path)
            text = (result.text or "").strip()
            reply = {"text": text}
            if want_polish and len(text.split()) >= POLISH_MIN_WORDS:
                started = time.time()
                try:
                    clean = polisher.run(text)
                    reply["polish_ms"] = int((time.time() - started) * 1000)
                    if plausible(text, clean):
                        reply["clean"] = clean
                    else:
                        reply["polish_rejected"] = f"{len(text.split())} words in, {len(clean.split())} out"
                except Exception as exc:
                    reply["polish_error"] = str(exc)
            emit(reply)
        except Exception as exc:
            emit({"error": str(exc)})
        finally:
            mx.clear_cache()
            footprint = mx.get_active_memory() + mx.get_cache_memory()
            if footprint > FOOTPRINT_WARN_BYTES:
                print(f"parakeetd: mlx footprint {footprint / 1e9:.2f}GB after clear_cache", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
