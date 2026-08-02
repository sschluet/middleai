# MiddleAI

<p align="center">
  <img src="Resources/Brand/MiddleAI-AppIcon.png" alt="MiddleAI app icon" width="144">
</p>

[![CI](https://github.com/sschluet/middleai/actions/workflows/ci.yml/badge.svg)](https://github.com/sschluet/middleai/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

MiddleAI is a local-first macOS voice layer for dictation and an existing private Open WebUI instance. It recognizes speech locally, selects the appropriate conversation automatically, keeps the canonical chat in Open WebUI, streams the answer and speaks complete sentences locally on the Mac.

MiddleAI replaces FluidVoice for this workflow. Tap the left Option key to start dictation and tap it again to finish, or hold it for push-to-talk. The right Option key works the same way for spoken requests to OpenWebUI. A focus-free overlay directly below the MacBook notch shows recording, transcription and response status.

## Download

Ready-to-run Apple Silicon builds are available under [GitHub Releases](https://github.com/sschluet/middleai/releases). Download `MiddleAI-<version>-macOS-arm64.zip`, unpack it and move `MiddleAI.app` to `/Applications`.

The current development releases are ad-hoc signed but not yet Developer-ID signed or notarized. On first launch, macOS can therefore require right-clicking `MiddleAI.app` and choosing **Open**. Microphone and Accessibility permissions, OpenWebUI credentials and local speech models must be configured separately on every Mac.

Each release includes a SHA-256 checksum file. Models are downloaded on first use and are never included in the release archive.

## What is included

- Native SwiftUI menu-bar app with first-run settings, quick input, status, profiles and current-chat link
- Native push-to-talk handling for the separate left and right Option keys
- Local Parakeet TDT v3 multilingual speech recognition through FluidAudio and Core ML
- FluidVoice-inspired 258-point island that overlaps the MacBook camera notch seamlessly, with rounded top and bottom transitions, macOS-sized typography, target-app icon and seven-bar level meter
- Silent dismissal for accidental, too-short or empty Option-key recordings
- Optional on-device dictation polishing with Apple Intelligence to remove filler words, repetitions and slips before insertion
- Conservative spoken formatting commands for Microsoft Word, PowerPoint, Outlook and Proton Mail, including paragraphs, line breaks, German quotation marks and rich lists
- Clipboard-preserving insertion into the previously active text field
- Shared Swift core plus `middleai` CLI
- Loopback-only synchronous `POST /input` plus queued `POST /command` for optional local integrations
- SQLite conversation/message cache and profile state
- `HeuristicRouter`, `EmbeddingRouter`, `LLMRouter` and default `HybridRouter`
- Password and API-key auth providers; passwords/tokens live in macOS Keychain
- Open WebUI adapter with TLS validation, optional private CA, chat persistence and SSE streaming
- Supertonic 3 multilingual TTS with native Core ML inference, automatic German/English pronunciation, spoken German number normalization, five female voices, 44.1-kHz audio, local macOS fallback and immediate barge-in
- Structured privacy-safe logging and `middleai doctor`

## Install and build

### System requirements

| Component | Minimum | Recommended |
| --- | --- | --- |
| Mac | Apple Silicon M1 | M2 or newer for faster local speech generation |
| macOS | macOS 14 Sonoma | Current macOS release |
| Memory | 8 GB for dictation and Supertonic | 16 GB for Qwen3-TTS, 24 GB for Voxtral or heavy multitasking |
| Free disk space | 5 GB for one compact voice setup | 12–15 GB for all current models, downloads and temporary files |
| Network | Required for initial model downloads and the OpenWebUI connection | Stable broadband connection for first setup |

The distributed app is currently arm64-only and does not run on Intel Macs. Apple Intelligence based dictation polishing and spoken-response summaries require macOS 26, Apple Intelligence and an eligible Mac. On macOS 14 and later, MiddleAI remains usable and falls back to conservative local text cleanup and extractive summaries.

Building from source additionally requires Swift 6 Command Line Tools or Xcode:

```sh
cd ~/Codex/middleai
./setup.sh
open dist/MiddleAI.app
```

The setup builds an ad-hoc signed local `.app`, places the CLI at `dist/bin/middleai`, and creates `~/.middleai/config.yaml`. Nothing is installed system-wide.

The first launch downloads the Parakeet Core ML STT model and the selected TTS model once. Both run locally after those downloads. Settings → Speech shows the installed state, actual local size and live approximate download progress for every managed TTS model. Installed or partial TTS model downloads can be moved to the macOS Trash from the same list; MiddleAI never deletes the shared managed runtime with an individual voice model.

### Local intelligence and chat routing

Settings → Intelligence separates conversation routing from answer generation. OpenWebUI always generates the actual answer. MiddleAI only decides whether an input continues the current conversation, switches to a recent one or starts a new chat.

The Hybrid strategy first compares recency, wording and local text similarity. If those signals disagree, one optional local intelligence source can break the tie:

- **Apple Intelligence** uses the on-device macOS Foundation Model on supported macOS 26 systems. If it is unavailable, Hybrid safely falls back to its built-in rules.
- **Ollama** uses the local OpenAI-compatible API, normally at `http://127.0.0.1:11434`, with an already downloaded model such as `qwen3:4b`.
- **llama.cpp** uses an OpenAI-compatible `llama-server` or router. MiddleAI defaults this option to `http://127.0.0.1:18881` and calls `/v1/models` plus `/v1/chat/completions`.
- **MiddleAI rules only** disables the optional model and requires no separate AI runtime.

For Ollama or llama.cpp, the configured model ID or alias must be known to the server. A successful connection test with an empty `/v1/models` response means the server is reachable, but no model is currently advertised. Only the current input and the titles and summaries of up to eight recent local conversations are sent to this loopback service.

### Copying MiddleAI to another Mac

`MiddleAI.app` contains the native application and its Swift dependencies. Copying only the app to `/Applications` on another Apple Silicon Mac is sufficient to start setup; Xcode, Homebrew and a separately installed Python are not required. Qwen3-TTS and Voxtral bootstrap their own managed Python/MLX runtime under `~/.middleai/runtime`.

The current development build is ad-hoc signed, not Developer-ID signed or notarized. Gatekeeper can therefore require right-clicking the app and choosing **Open**. A regular organizational release should be Developer-ID signed, notarized and distributed as a signed DMG or ZIP.

The following data deliberately does not travel inside the app and must be configured on each Mac:

- OpenWebUI server, username and model ID
- Password or API token stored in that Mac's Keychain
- Microphone and Accessibility permissions
- Activation keys and user preferences under `~/.middleai`
- STT and TTS model caches

After the initial downloads, speech recognition and speech synthesis work offline. Assistant requests still require access to the configured OpenWebUI server.

### Local model storage

| Component | Approximate installed size |
| --- | ---: |
| MiddleAI.app | 60 MB |
| Parakeet TDT v3 STT including Core ML data | 1 GB |
| Supertonic 3 | 0.2–0.4 GB |
| Qwen3-TTS 4-bit plus managed runtime | 2.8 GB |
| Voxtral 4-bit plus managed runtime | 3 GB |
| All listed TTS models including PocketTTS plus STT | 9–10 GB plus temporary download space |

Sizes are rounded and can change with upstream model revisions. Old model versions remain in the user's cache until removed and can increase total disk use. Voxtral is licensed under CC BY-NC 4.0 and must not be used for commercial or business purposes.

## First start

1. Open `dist/MiddleAI.app`; MiddleAI appears in the menu bar.
2. Open **Settings**.
3. Enter the Open WebUI base URL, account email/username, password and exact model ID.
4. Keep TLS verification enabled. Add a company CA PEM/DER path when required.
5. Select **Save & Test Connection**.
6. Allow MiddleAI under **Privacy & Security** for Microphone and Accessibility. Restart MiddleAI if macOS asks for it.
7. Tap left Option, speak and tap it again to insert dictation into the active field. Holding and releasing also works.
8. Use right Option the same way to ask OpenWebUI. MiddleAI displays and speaks the response.

The Voice settings contain **Diktat vor dem Einfügen lokal glätten**. On macOS 26, this uses Apple's on-device Foundation Model with German locale support. MiddleAI accepts a generated correction only when numbers and protected terms remain present, the vocabulary stays close to the transcript and no substantial new wording is introduced. Otherwise it keeps a conservative local cleanup that only removes filler sounds and direct repetitions. Dictation text is never sent to OpenWebUI or another cloud service for polishing.

### Spoken formatting in supported apps

When dictating into Microsoft Word (`com.microsoft.Word`), Microsoft PowerPoint (`com.microsoft.Powerpoint`), Microsoft Outlook (`com.microsoft.Outlook`) or Proton Mail (`ch.protonmail.desktop`), MiddleAI can translate explicit German structure commands into formatted output. The feature is enabled by default and can be disabled under Settings → Spracheingabe.

- `neue Zeile` inserts a line break; `neuer Absatz` starts a new paragraph.
- `in Anführungsstrichen Projekt Apollo` becomes `„Projekt Apollo“`.
- `Anführungszeichen auf … Anführungszeichen zu` and `Zitat Anfang … Zitat Ende` create paired German quotation marks.
- `Aufzählung, Punkt eins …, nächster Punkt …, Liste Ende` creates a bulleted list.
- Starting with `nummerierte Liste` creates an ordered list.

MiddleAI places plain text, HTML and RTF representations on the clipboard for supported targets so Office editors and mail composers can preserve lists and paragraphs. The previous clipboard contents are restored afterwards. Detection is deliberately conservative: ordinary wording such as `Die neue Zeile ist rot` is not interpreted as a command, and all other applications continue to receive plain text only.

The password is written to Keychain service `de.middleai.openwebui`, never to YAML. For development only, `MIDDLEAI_OPENWEBUI_PASSWORD` may be set from a gitignored `.env`-style shell environment.

## CLI

```sh
dist/bin/middleai ask "Wie hoch war nochmal die Förderleistung?"
dist/bin/middleai status
dist/bin/middleai new
dist/bin/middleai stop
dist/bin/middleai conversations
dist/bin/middleai doctor
dist/bin/middleai tts-use-supertonic
dist/bin/middleai tts-use-pocket
dist/bin/middleai tts-prepare
dist/bin/middleai tts-render ~/.middleai/tts-test.wav
dist/bin/middleai tts-test
dist/bin/middleai serve
```

`serve` runs the same loopback HTTP adapter without the menu-bar app. Do not run both on the same port.

## Local HTTP input

```sh
curl http://127.0.0.1:8765/input \
  -H 'Content-Type: application/json' \
  -d '{"text":"Und wie sieht es mit Gardena aus?","source":"fluidvoice"}'
```

The server refuses configuration on `0.0.0.0`. An optional local bearer token can be enabled in configuration and stored under the Keychain account `api_token`.

`POST /command` remains available for optional local automation and returns `202 Accepted` immediately. It is not used by either native Voice mode.

## Conversation routing

Commands such as “Neuer Chat”, “Stopp”, “Nicht vorlesen”, “Zurück zum MacBook-Thema” and “Architekturmodus” are intercepted locally. Normal input is scored against the current and recent chats using time, title, summary, recent user/assistant messages and local semantic similarity. The hybrid router combines heuristic and vector decisions and optionally asks an OpenAI-compatible local routing model. If that model is unavailable, the heuristic path remains operational.

The local router only returns a routing decision; it is never asked to answer the user. Confidence thresholds and continuation timeout are configurable in `~/.middleai/config.yaml`.

## TTS and privacy

`adaptive` is the default. It combines a natural local neural voice with the reliable German Apple voice for longer texts, numbers and difficult terminology. `supertonic3` can be selected directly and uses a multilingual Core ML model with explicit German synthesis, 44.1-kHz output and five female reference styles. Selecting a style in Settings immediately plays the same German sample, making the voices directly comparable. The model download is about 400 MB and is reused offline after the first preparation.

`pockettts` remains available for compatibility, but several of its styles can have a noticeable accent in German. A complete response is synthesized into one continuous WAV before playback to avoid player restarts between sentences. Audio is synthesized and played inside MiddleAI; no Python process, local server or cloud service is involved.

`macos` remains a completely local fallback. MiddleAI lists the installed German Apple voices with gender and quality information. Additional Apple voices can be opened for download from the Speech settings. `local_model` remains available for an optional custom executable. New user input interrupts playback and clears pending speech immediately.

STT microphone audio remains in memory and is never sent to OpenWebUI. Only the finished assistant-mode transcript is sent to the configured OpenWebUI instance. Dictation-mode transcripts never leave the Mac.

## Tests and diagnostics

```sh
make test
dist/bin/middleai doctor
```

The test runner covers configuration, SQLite, command detection, sentence parsing, heuristic/hybrid routing, confidence management, conversation management, TTS queue/barge-in and the Open WebUI adapter. It is framework-independent because the standalone Command Line Tools installation used here ships neither an importable XCTest nor Swift Testing module for its compatible SDK.

See [ARCHITECTURE.md](ARCHITECTURE.md), [SECURITY.md](SECURITY.md), [DEVELOPMENT.md](DEVELOPMENT.md) and [FLUIDVOICE.md](FLUIDVOICE.md) for migration notes.

## License

MiddleAI source code is licensed under the [Apache License 2.0](LICENSE). Third-party libraries and optional downloaded speech models retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). In particular, the optional Voxtral model is CC BY-NC 4.0 and is not permitted for commercial or business use.
