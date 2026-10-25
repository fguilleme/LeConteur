# ConteurQwen

Qwen3-TTS subset of [mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift), pinned at `d8e2cafea891928075d3c8577b1a05b99396594e`, MIT license (included).

Only the six Qwen model source files and SendingBox are vendored. Shared MLXAudioCore, MLX and tokenization remain SwiftPM dependencies. This avoids linking unrelated TTS models into the app.

Local adaptations:

- CustomVoice loads the speech decoder without the unused audio encoder (about 225 MB saved).
- Cancellation checks during local model loading.
- Local-directory loading only; the app manages pinned, verified model downloads.
- Removed the SpeechGenerationModel conformance, which belongs to the full TTS product.
- Added synchronous chunk callbacks on the caller's task. Cancellation is a real serialization barrier before another generation touches the mutable decoder.
- Removed the text-length heuristic that could silently truncate expressive speech. A fixed token ceiling now reports a generation error unless EOS is reached.
- Streaming decoder overlap-add carries the transposed convolution tail without its bias; the next chunk already includes that bias. This avoids adding it twice at every audio chunk boundary.
- An opt-in diagnostic exports generated codec frames and decodes a bounded prefix in one batch to check equivalence with streaming. It does not change normal generation or sampling.
- Acoustic sampling applies temperature before top-k/top-p and accumulates probabilities in float32. The existing full-history repetition penalty and EOS escape hatch are retained: adopting the reference's recent-only history and filtered EOS together produced an abnormally long control passage. Numerical correctness alone does not establish perceptual speech quality.
- The residual code predictor uses its independent pinned-model defaults (temperature 0.9, top-k 50, top-p 1). It no longer inherits the reduced French narration temperature and nucleus cutoff. These separate settings are specified in the pinned model's `generation_config.json` and the [official Qwen wrapper](https://github.com/QwenLM/Qwen3-TTS/blob/main/qwen_tts/inference/qwen3_tts_model.py).
- Normal narration also uses the pinned temperature 0.9 and top-p 1. Reduced-temperature French control passages still stretched to 51.92 seconds even after separating the code predictor; the earlier language-specific 0.5 override has been removed. Diagnostics can override narration temperature without changing the code predictor. Five physical-device sampler tests pass.

- Text and instructions use the official Qwen2 NFC normalization before tokenization, including on existing installations whose generated tokenizer JSON has no normalizer. Newly generated tokenizers also include NFC and Qwen2’s single-digit pretokenization rule. This fixes a reproduced token mismatch for decomposed French accents without changing reader text or UTF-16 highlighting offsets. It is not a general cure for synthesis omissions or stuttering.

The app serializes requests, limits the Metal cache, and stops GPU generation before entering the background. No remote synthesis API is used.

`QwenTokenizerTests` compares the real Swift tokenizer against 14 reference strings, including decomposed accents and multiple languages, with both current and legacy tokenizer data. Set `CONTEUR_TOKENIZER_MODEL` in the test runner environment to the pinned local model folder. The test reads only tokenizer assets and does not load the model or use the GPU. Regenerate the fixture with `Scripts/generate_qwen_tokenizer_fixture.py`.
