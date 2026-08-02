#!/usr/bin/env python3
"""Persistent local MLX TTS worker used by MiddleAI.

The worker keeps the MLX model in memory between utterances. Communication is
newline-delimited JSON over stdin/stdout; unrelated mlx-audio progress output is
ignored by the Swift client because protocol messages use the MIDDLEAI prefix.
"""

import json
import sys
import traceback

import mlx.core as mx
from mlx_audio.audio_io import write as audio_write
from mlx_audio.tts.utils import load

MODEL = sys.argv[1]
ENGINE = sys.argv[2]


def emit(payload):
    print("MIDDLEAI:" + json.dumps(payload, ensure_ascii=False), flush=True)


try:
    emit({"event": "loading"})
    model = load(MODEL)
    emit({"event": "ready"})
except Exception as error:
    traceback.print_exc(file=sys.stderr)
    emit({"event": "error", "message": str(error)})
    raise SystemExit(1)


for raw_line in sys.stdin:
    try:
        request = json.loads(raw_line)
        if request.get("action") == "quit":
            break
        if request.get("action") != "speak":
            raise ValueError("Unbekannte Voxtral-Anfrage")

        text = str(request.get("text", "")).strip()
        output = str(request.get("output", "")).strip()
        voice = str(request.get("voice", "de_female"))
        instruct = str(request.get("instruct", ""))
        rate = float(request.get("rate", 1.0))
        if not text or not output:
            raise ValueError("Text oder Ausgabedatei fehlt")

        chunks = []
        sample_rate = int(getattr(model, "sample_rate", 24000))
        generation = (
            model.generate(
                text=text,
                instruct=instruct,
                speed=rate,
                lang_code="German",
            )
            if ENGINE == "qwen3_tts"
            else model.generate(text=text, voice=voice)
        )
        for result in generation:
            chunks.append(result.audio)
            sample_rate = int(result.sample_rate)
        if not chunks:
            raise RuntimeError("Voxtral hat keine Audiodaten erzeugt")

        audio = mx.concatenate(chunks, axis=0) if len(chunks) > 1 else chunks[0]
        audio_write(output, audio, sample_rate, format="wav")
        emit({"event": "generated", "path": output})
    except Exception as error:
        traceback.print_exc(file=sys.stderr)
        emit({"event": "error", "message": str(error)})
