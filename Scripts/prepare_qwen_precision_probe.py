#!/usr/bin/env python3
"""Stage a pinned 6-bit diagnostic model. Reuse byte-identical installed assets.

Only diagnostic files are staged; the production model manifest is unchanged.
Run after downloading the revision listed below to .build/models/.
"""
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / ".build/models/Qwen3-TTS-1.7B-CustomVoice-6bit"
STAGE = ROOT / ".build/qwen-precision-transfer"
REVISION = "1c6c0ff58c43afa8df571facde2efa077efd85e2"
PINNED_WEIGHTS = "097b66a8c63570b88abc2fb393d1dc2360394ca7741c818455ba9da257ac2f3b"
baseline = json.loads((ROOT / "LeConteur/Resources/QwenModelManifest.json").read_text())
files = []
transfer_bytes = 0
for original in baseline["files"]:
    relative = original["path"]
    source = SOURCE / relative
    digest = hashlib.file_digest(source.open("rb"), "sha256").hexdigest()
    if relative == "model.safetensors":
        assert digest == PINNED_WEIGHTS, "Unexpected model revision"
    entry = {"path": relative, "bytes": source.stat().st_size, "sha256": digest}
    files.append(entry)
    if digest == original["sha256"]:
        continue
    target = STAGE / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        os.link(source, target)
    else:
        assert os.path.samefile(source, target), f"Unexpected existing file: {target}"
    transfer_bytes += entry["bytes"]
STAGE.mkdir(parents=True, exist_ok=True)
(STAGE / "manifest.json").write_text(json.dumps({
    "repository": "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-6bit",
    "revision": REVISION, "files": files
}, indent=2) + "\n")
print(json.dumps({"stage": str(STAGE), "transferBytes": transfer_bytes,
                  "modelBytes": sum(f["bytes"] for f in files)}))
