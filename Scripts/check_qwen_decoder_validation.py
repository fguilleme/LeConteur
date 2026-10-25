#!/usr/bin/env python3
"""Check the real-device same-token streaming/batch decoder regression.

Run the launch-only --qwen-decoder-validation probe before and after the fix,
copy its synthetic output to <root>/before and <root>/after, then run this file.
No model download or audio playback is performed by this check.
"""
import json
import pathlib
import sys


def check(root: pathlib.Path) -> dict:
    rows = []
    for index in range(2):
        name = f"passage-{index}"
        before = root / "before" / name
        after = root / "after" / name
        old = json.loads((before / "report.json").read_text())
        new = json.loads((after / "report.json").read_text())
        old_codes = json.loads((before / "codec-frames.json").read_text())
        new_codes = json.loads((after / "codec-frames.json").read_text())
        assert old_codes == new_codes, f"{name}: synthesis changed; not a controlled decoder comparison"
        for key in ("text", "speaker", "language", "seed", "temperature", "samples", "comparedCodecFrames"):
            assert old[key] == new[key], f"{name}: {key} differs"
        assert old["normalizedRMSE"] > 0.01, f"{name}: baseline did not reproduce the defect"
        assert new["normalizedRMSE"] < 0.001, f"{name}: streaming/batch mismatch remains"
        assert new["maxAbsoluteError"] < 0.01, f"{name}: isolated large distortion remains"
        assert new["normalizedRMSE"] < old["normalizedRMSE"] / 100, f"{name}: insufficient improvement"
        rows.append({"passage": index, "identicalCodecFrames": len(old_codes),
                     "beforeNormalizedRMSE": old["normalizedRMSE"],
                     "afterNormalizedRMSE": new["normalizedRMSE"],
                     "afterMaxAbsoluteError": new["maxAbsoluteError"],
                     "comparedSeconds": new["seconds"]})
    return {"status": "passed", "device": "iPhone 15 Pro", "passages": rows,
            "scope": "Streaming decoder agrees with batch decoding of the same generated tokens. Does not certify accent, prosody or absence of model-generated howls."}


if __name__ == "__main__":
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "AudioDemos/iPhone15Pro/QwenDecoderValidation")
    report = check(root)
    data = json.dumps(report, indent=2, ensure_ascii=False) + "\n"
    (root / "comparison.json").write_text(data)
    print(data)
