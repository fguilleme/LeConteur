#!/usr/bin/env python3
"""Regenerate reference tokens using a locally installed, pinned Qwen model.

Usage: python Scripts/generate_qwen_tokenizer_fixture.py /path/to/Qwen-model
Requires transformers; never downloads weights or loads the audio model.
The reference Qwen2 tokenizer normalizes to NFC before byte-level BPE:
https://github.com/huggingface/transformers/blob/v4.57.3/src/transformers/models/qwen2/tokenization_qwen2.py
"""
import argparse
import json
from pathlib import Path
from transformers import AutoTokenizer

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("model", type=Path)
args = parser.parse_args()
tokenizer = AutoTokenizer.from_pretrained(str(args.model), local_files_only=True)
texts = [
    "Le soleil venait de se lever sur le port.",
    "À l’aide de son scalpel de précision, il gratta la surface dont la texture n’était d’aucune.",
    "Un récit de mystère médiéval.",
    "L'été est là. Élodie n'a rien oublié.",
    "L’e\u0301te\u0301 est la\u0300.",
    "Il voit 12345 étoiles, à 12,75 euros.",
    "Le train arrive.\n\nIl est 10 h 30.",
    "¿Dónde está la estación?",
    "Sie öffnet die Tür und lächelt.",
    "彼女は静かに本を開いた。",
    "그는 조용히 책을 펼쳤다.",
    "她轻轻地翻开书。",
    "Она открыла книгу.",
    "مرحبا بالعالم.",
]
rows = []
for text in texts:
    chat = f"<|im_start|>assistant\n{text}<|im_end|>\n<|im_start|>assistant\n"
    rows.append(dict(text=chat, ids=tokenizer.encode(chat)))
destination = Path(__file__).resolve().parent.parent / "LeConteurTests/Fixtures/QwenTokenizationCases.json"
destination.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
