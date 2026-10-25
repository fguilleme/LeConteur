#!/usr/bin/env python3
"""Offline regression probe: early synthesis policy versus current, no playback.

Uses the local Python implementation as a diagnostic approximation of Swift.
Keeps decoder, text, speaker and seed fixed; never changes production settings.
"""
import gc
import argparse
import json
import os
from pathlib import Path
import re
import time
import types
import unicodedata

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--refine", action="store_true", help="Compare old sampling with corrected arithmetic on new sentences/seeds")
args = parser.parse_args()
os.environ["HF_HOME"] = str(ROOT / ".build/hf-cache")
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
import mlx.core as mx
import numpy as np
import soundfile as sf
from mlx_audio.tts.utils import load_model

mx.set_cache_limit(64 * 1024 * 1024)
model = load_model(str(ROOT / ".build/models/Qwen3-TTS-1.7B-CustomVoice-4bit"))


def sample(self, logits, temperature=.9, top_k=50, top_p=1.,
           repetition_penalty=1., generated_tokens=None, suppress_tokens=None, **kwargs):
    # Old Swift policy at 2d6d865: coupled talker/subtalker, nucleus before
    # temperature, original probability dtype. Current: independent subtalker.
    old = variant in ("early", "early-sampling")
    logits = logits[:, -1, :]
    if not old:
        logits = logits.astype(mx.float32)
    temperature, top_p = (.75, .95) if old or variant == "early-corrected" else (.9, 1.)
    main = bool(suppress_tokens)
    if suppress_tokens:
        logits = mx.put_along_axis(logits, mx.array(suppress_tokens)[None, :],
                                  mx.array(-float("inf"), logits.dtype), axis=-1)
    if generated_tokens and repetition_penalty != 1.:
        ids = mx.array(sorted(set(generated_tokens)), dtype=mx.int32)[None, :]
        values = mx.take_along_axis(logits, ids, axis=-1)
        logits = mx.put_along_axis(logits, ids, mx.where(values < 0,
            values * repetition_penalty, values / repetition_penalty), axis=-1)
    if not old:
        logits = logits / temperature
    eos = self.config.talker_config.codec_eos_token_id
    if main:
        eos_logit = logits[:, eos:eos + 1]
    if top_k > 0:
        indices = mx.argpartition(-logits, kth=top_k - 1, axis=-1)[:, top_k:]
        logits = mx.put_along_axis(logits, indices, mx.array(-float("inf"), logits.dtype), axis=-1)
    if 0 < top_p < 1:
        probabilities = mx.softmax(logits, axis=-1)
        indices = mx.argsort(logits, axis=-1)
        cumulative = mx.cumsum(mx.take_along_axis(probabilities, indices, axis=-1), axis=-1)
        inverse = mx.put_along_axis(mx.zeros_like(indices), indices,
                                   mx.arange(indices.shape[-1])[None, :], axis=-1)
        logits = mx.where(mx.take_along_axis(cumulative, inverse, axis=-1) > 1 - top_p,
                          logits, mx.array(-float("inf"), logits.dtype))
    if main:
        logits = mx.put_along_axis(logits, mx.array([[eos]]), eos_logit, axis=-1)
    if old:
        logits = logits / temperature
    return mx.random.categorical(logits).reshape(1, 1)


model._sample_token = types.MethodType(sample, model)
current = json.loads((ROOT / "AudioDemos/QwenShortTextValidation/report.json").read_text())["runs"][0]["instruction"]
early = ("Read in French. Perform as an expressive dramatic storyteller. Build suspense, "
         "give questions genuine surprised disbelief, replies a warm reassuring smile, "
         "and endings a feeling of relief. Vary rhythm, pitch and intensity, with deliberate "
         "dramatic pauses. Speak clearly without shouting.")
cases = [
    ("subtitle", "Un récit de mystère médiéval."),
    ("morning", "Le soleil venait de se lever sur le port."),
    ("narration", "Elle reconnut aussitôt l’écriture de son frère."),
]
folder = ROOT / "AudioDemos/QwenEarlyComparison"
seeds = (740, 741)
variants = ("current", "early", "early-sampling", "early-prompt")
if args.refine:
    folder = folder / "refined"
    seeds = (742, 743)
    variants = ("current", "early-sampling", "early-corrected")
    cases = [
        ("dialogue", "« Tu n’as pas oublié notre promesse ? » lui a-t-elle demandé."),
        ("boat", "Élise ouvrit les volets et regarda les premiers bateaux quitter la rive."),
        ("scalpel", "À l’aide de son scalpel de précision, il gratta la surface dont la texture n’était d’aucune."),
        ("narration", "Malgré les années écoulées, il se souvenait de chaque détail : la maison au bord de l’eau, les fenêtres ouvertes et leurs longues conversations du dimanche."),
    ]
folder.mkdir(exist_ok=True, parents=True)
rows = []


def save():
    (folder / "report.json").write_text(json.dumps({
        "scope": "Mac Python approximation, not an iPhone or perceptual validation. Blind local ASR is only a diagnostic. No audio played.",
        "baseline": "Synthesis settings from commit 2d6d865, keeping the same corrected decoder and sentence splitting for all variants.",
        "speaker": "Serena", "language": "French", "style": "dramatic",
        "currentInstruction": current, "earlyInstruction": early, "runs": rows,
    }, ensure_ascii=False, indent=2) + "\n")


for seed in seeds:
    for case, text in cases:
        for variant in variants:
            mx.random.seed(seed)
            started = time.monotonic()
            chunks = []
            for result in model.generate_custom_voice(
                    text=text, speaker="Serena", language="French",
                    instruct=early if variant in ("early", "early-prompt") else current,
                    max_tokens=500, temperature=.9, top_k=50, top_p=1.,
                    repetition_penalty=1.05, stream=True, streaming_interval=1.5):
                chunks.append(np.asarray(result.audio))
            samples = np.concatenate(chunks)
            filename = f"{case}-{seed}-{variant}.wav"
            sf.write(folder / filename, samples, 24000, subtype="FLOAT")
            row = dict(file=filename, case=case, seed=seed, variant=variant, text=text,
                       seconds=len(samples) / 24000, generationSeconds=time.monotonic() - started,
                       hitLimit=len(samples) >= 500 * 1920)
            rows.append(row)
            save()
            print(json.dumps(row, ensure_ascii=False), flush=True)

del model
gc.collect()
mx.clear_cache()
from mlx_audio.stt.utils import load_model as load_stt
asr = load_stt("mlx-community/whisper-small-asr-fp16")


def words(text):
    text = unicodedata.normalize("NFKD", text.lower())
    return re.findall(r"[a-z0-9]+", "".join(x for x in text if not unicodedata.combining(x)))


def edits(expected, actual):
    previous = list(range(len(actual) + 1))
    for i, a in enumerate(expected, 1):
        current = [i]
        for j, b in enumerate(actual, 1):
            current.append(min(current[-1] + 1, previous[j] + 1, previous[j - 1] + (a != b)))
        previous = current
    return previous[-1]


for row in rows:
    result = asr.generate(str(folder / row["file"]), language="fr", temperature=0,
        condition_on_previous_text=False, return_timestamps=True, sample_len=120, verbose=None)
    row["asrText"] = "".join(s["text"] for s in result.segments
        if s["start"] < row["seconds"] and s["text"].strip() not in ("", "...")).strip()
    target = words(row["text"])
    row["wordErrorRate"] = edits(target, words(row["asrText"])) / len(target)
    save()
    print(json.dumps(row, ensure_ascii=False), flush=True)
