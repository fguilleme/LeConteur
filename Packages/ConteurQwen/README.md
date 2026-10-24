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

The app serializes requests, limits the Metal cache, and stops GPU generation before entering the background. No remote synthesis API is used.
