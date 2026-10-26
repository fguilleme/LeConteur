# Le Conteur

[Français](https://github.com/fguilleme/LeConteur/blob/main/README.md) · [English](https://github.com/fguilleme/LeConteur/blob/main/README.en.md)

Le Conteur is a local audiobook reader for iPhone, built with SwiftUI. Bundle identifier: `com.guilleme.conteur`. The reference device is an iPhone 15 Pro running iOS 18 or later.

## Features

- A local library for DRM-free EPUB files, text-based PDFs, TXT and Markdown files, DOCX documents, and text pasted into the app. Embedded EPUB covers are displayed in both the library and the reader, including translated editions.
- Import from Files, open a document with Le Conteur, or use **Share → Le Conteur**. After sharing a file, open the app to find the book in the library.
- Offline narration using Apple voices or local neural voices after their models have been installed.
- Paragraph display, passage tracking, and word highlighting. Scrolling follows the current line—even inside paragraphs spanning several screens—and keeps the highlighted word above the playback controls. Apple voices provide word positions; neural voices use an audio-based estimate.
- Optional translation into the iPhone language when opening a foreign-language book, with **Read original** immediately available. Language packs may need to be downloaded the first time.
- Playback speed, bookmarks, saved progress, a sleep timer, and lock-screen controls.

A book written in the phone language opens directly. When a foreign-language book without a saved translation is opened for the first time, Le Conteur offers to translate it. **Read original** cancels immediately and remembers that choice. Once a translation has been saved, the original and translated editions appear and open independently, each with its own reading position. A partial translation resumes only when that edition is selected. The reader's **Translate into…** action can reopen an existing translation or create a new one without changing a global language setting.

The most recently opened book is persisted independently from playback. After the app is terminated or relaunched, its card, cover, and position return without starting audio automatically. Deleting that book also clears the persisted selection.

The first translated passages open as soon as they are ready. More passages are appended to the same document while reading without shifting existing words or bookmarks. If narration catches up with the available text, it waits and resumes automatically. A deliberate pause remains respected. Leaving the reader or moving the app to the background suspends translation; completed passages remain readable and work resumes when that edition is opened again.

During an active translation, an Apple voice temporarily replaces a neural voice so that two large models are not kept in memory at once. The reader clearly displays this fallback. Once translation finishes or is suspended, the selected neural voice returns without overriding a deliberate pause.

In **Voices → Your iPhone voices → Preferred voices by language**, a star identifies the preferred Apple voice for each language. Choosing an English voice does not overwrite the French or Spanish selection. Regional variants are grouped by language, so a British voice can be preferred for English texts. **Automatic** clears only that language's preference. Choices survive relaunches and the former single global preference is migrated to its language. If a voice disappears, another available voice for the same language is used without deleting the preference.

Apple voice previews use text matching the voice language. System speed is natural at 1×; other values are approximate because the iOS synthesizer rate is not a playback multiplier. A bounded conversion avoids saturating the synthesizer at its maximum rate when 2× is selected.

Apple voices receive several sentences from one paragraph. Neural narration receives coherent bounded passages and prepares the next one while current audio is playing. Exceptionally long sentences keep the safe chunks created during import. Highlighting preserves source-text offsets, including Unicode characters.

EPUB 3 `cover-image` metadata, EPUB 2 `meta name="cover"`, and XHTML/SVG cover pages containing a raster image are supported. A thumbnail up to 800 pixels is stored separately from the text. Reimporting an older book can recover its cover without creating a duplicate or losing progress and bookmarks. Pure vector covers without an embedded raster image keep the generic artwork.

## Run on an iPhone

1. Open `LeConteur.xcodeproj` in Xcode and let Swift Package Manager resolve the dependencies.
2. The development team selected for **LeConteur** is also defined at project level, so **ConteurShare** and the tests inherit it. If the team changes, verify that the app and extension still use the same team under **Signing & Capabilities**.
3. Configure the `group.com.guilleme.conteur` app group for both targets. It transfers documents received by the share extension, and the selected team must be able to provision this capability.
4. Select an iPhone 15 Pro and run the **LeConteur** scheme. Run uses **Release** to optimize inference, while tests use **Debug**. To inspect Swift variables, select Debug under Edit Scheme → Run. Neural model weights are not bundled in the production binary; install them from the Voices tab.

The minimum deployment target is iOS 18. The project currently builds with the iOS 27.1 SDK.

The project uses Apple's generic versioning system. An archive pre-action runs `agvtool` to increment the build number automatically. A preparation phase repairs ONNX Runtime's `MinimumOSVersion` metadata, re-signs the framework, and emits its dSYM when requested by the debug-information format so archives can be accepted by App Store Connect.

## Voice engines

### Supertonic

Supertonic is the default local neural engine. Its model is installed from the Voices tab and runs entirely on the iPhone. Generated PCM is queued ahead of playback so complete passages can play continuously. The app uses an audio playback session and keeps preparing audio while it is allowed to run in the background.

iOS applies a strict CPU budget when Le Conteur is no longer the visible app—even if the screen stays on. Supertonic therefore limits background inference to protect the process from termination. It uses six diffusion steps while Le Conteur is visible and four in the background to preserve narration quality. A prepared audio reserve reduces interruptions, but occasional waits can still occur when another app is active or the screen is locked. Older devices may need Apple voices for uninterrupted background playback.

### Optional Qwen support

Qwen is enabled by default through the target setting `CONTEUR_QWEN_CONDITION = CONTEUR_QWEN`. To build a variant focused on Supertonic and Apple voices, replace it with `CONTEUR_NO_QWEN`, or override it from the command line:

```sh
xcodebuild -project LeConteur.xcodeproj -scheme LeConteur \
  CONTEUR_QWEN_CONDITION=CONTEUR_NO_QWEN build
```

This variant hides the Qwen card, prevents Qwen selection and previews, creates no Qwen download tasks, and migrates an existing Qwen preference to Supertonic when installed or to an Apple voice otherwise. Existing weights are not deleted, so switching variants remains reversible. The repository currently keeps `CONTEUR_QWEN` as its default.

### Qwen on iPhone

Under **Voices → Qwen**, choose one of **Ryan, Aiden, Serena, Vivian, Uncle Fu, Ono Anna, Sohee, Dylan, and Eric**, then select **Warm**, **Natural**, or **Dramatic** and tap the preview action. All nine speakers are part of the same model and require no additional download. The displayed native language describes the speaker; narration still follows the book language. Accents may vary between speakers.

Speaker and style selection activates Qwen and is saved. Descriptions follow the [official Qwen model card](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice). Intonation prompts are written in the language being read—French, English, Spanish, German, Italian, Portuguese, Russian, Japanese, Korean, or Chinese—and are sent with an explicit language. For a translation, this is the target language. A shared instruction requests complete articulation and a consistent accent, but cannot by itself guarantee pronunciation quality. The 0.6B variants, which ignore style instructions, are not used.

The model is pinned to `mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit`, revision `f35faf19b0cc2160865af64ecf0f22f83d335135`. Wi-Fi installation checks every file's size and SHA-256. Completed files survive cancellation. Weights live in Application Support, are excluded from iCloud backup, and can be removed in the app. Book text is never sent to the model repository.

Qwen downloads use one background `URLSessionConfiguration`, identified by `com.guilleme.conteur.voice-downloads.v1`. Transfers may continue over Wi-Fi while the app is suspended, another app is visible, or the screen is locked. Missing files are scheduled together to avoid repeated iOS wake-ups. The session recovers its tasks after relaunch and retains its installation plan, received files, and server-supported resume data. Completed files are verified before installation. Cancellation invalidates late callbacks while preserving already verified files for a later resume.

Temporary downloads are immediately moved into durable storage. Voice files, metadata, and resume data use `completeUntilFirstUserAuthentication`, allowing reception after locking once the iPhone has been unlocked after boot. iOS decides the actual transfer schedule according to network and system resources. Force-quitting from the app switcher may cancel transfers; reopening reconstructs the remaining work. See Apple's [background download documentation](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).

The local `Packages/ConteurQwen` package adapts mlx-audio-swift's Qwen implementation with 1.5-second block decoding, a 64 MiB Metal cache, serialized cancellation, and loading without the unused CustomVoice audio encoder. The app requests the iOS `increased-memory-limit` entitlement, checks available memory before loading, and unloads the model during interruptions and before translation.

Qwen playback queues complete passages. A passage reaches the PCM player only after generation finishes. **Voices → Qwen → Audio reserve** offers **Automatic, 10 s, 30 s, or 60 s**. These are listening seconds at the selected speed: 30 seconds at 2× represents 60 seconds of source audio. Automatic mode estimates upcoming preparation time and the difference between generation and listening speed from recent warm renders. Generation continues during playback with a bounded look-ahead and a maximum of 128 passages.

The reserve uses the known duration of fully generated passages. Playback starts or resumes as soon as its time target is reached, even if one passage alone satisfies it. A deliberate pause keeps immediate access to remaining audio. A larger reserve delays startup but reduces waits between passages. Changing the setting does not interrupt current playback. If generation remains slower than listening, waits can still occur.

A gauge shows the **actual prepared reserve** in the reader, mini-player, and Qwen preview. It compares listening seconds available against the start or refill target and continues updating during playback and pause. Work in progress is not counted until playable. When all remaining text is ready, the gauge says so even if the book is shorter than the selected reserve.

Qwen keeps its own speed setting, initially 2×, with tempo correction that does not change pitch and does not regenerate audio. Word highlighting remains estimated: it realigns for every passage and distributes words across active areas of the waveform, excluding long silences.

Qwen generation requires the foreground because it uses Metal. Switching apps or locking the screen suspends only generation; already prepared passages remain queued and continue playing. Lock-screen Pause and Play use that same reserve. Once it is empty, Le Conteur waits for a return to the foreground and does not silently switch to an Apple voice. Preparation resumes at the first ungenerated passage without replaying completed audio.

## Translation

Translation uses bounded paragraph blocks and saves every completed result locally so work can resume after interruption. Preparation uses an activity indicator rather than a misleading estimated percentage. A watchdog covers model preparation and stops a session cleanly if translation stops responding. Selecting a different target language always starts again from the original edition.

On current iOS versions, Le Conteur prefers Apple's lower-latency translation path for sustained book translation because it leaves more CPU and GPU time for scrolling and playback. When a language pair is not recognized by one availability check but is supported by the traditional models shared with Apple's Translate app, the app retries using the compatible strategy and accepts Apple's regional-language fallback. Regional variants such as `en-US` and `en-GB` are normalized appropriately.

Translation inference is paced to protect interface responsiveness. Progress publication is also coalesced so SwiftUI is not invalidated after every small block. The neural voice model is unloaded before translation begins, and an engine that has not yet been used is not initialized merely to clear its cache.

## Limits and components

DRM-protected EPUB files, encrypted PDFs, and scanned PDFs without a text layer are not supported. Import limits are 50 MB and two million characters. Translations are machine generated and stored separately from the original.

The library and downloaded voices are stored locally and excluded from the app's iCloud backup. Original files selected in Files keep their own storage policy. Apple may collect Translation framework metrics, but not the book text through Le Conteur.

Pinned dependencies include ZIPFoundation 0.9.19, MLX Swift 0.32.3, swift-transformers 1.1.6, mlx-audio-swift revision `d8e2cafea891928075d3c8577b1a05b99396594e`, ONNX Runtime, and their resolved dependencies in the Xcode project. See `LeConteur/Resources/ThirdPartyNotices.txt` for credits and licenses.
