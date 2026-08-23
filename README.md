# MiddleAI

<p align="center">
  <img src="Resources/Brand/MiddleAI-AppIcon.png" alt="MiddleAI app icon" width="144">
</p>

[![CI](https://github.com/sschluet/middleai/actions/workflows/ci.yml/badge.svg)](https://github.com/sschluet/middleai/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

**Website:** [sschluet.github.io/middleai](https://sschluet.github.io/middleai/)

MiddleAI is a local-first macOS voice layer for dictation and spoken AI requests. It recognizes speech locally, selects the appropriate conversation automatically, can answer entirely on the Mac through Ollama or llama.cpp, optionally connects to OpenWebUI, the OpenAI Platform or OpenRouter, and speaks complete sentences locally.

By default, double-tap the left Option key to start dictation and tap it once to finish. Double-tap the right Option key for spoken requests to the configured AI provider. Single-press activation can be restored independently for either mode in Settings. A focus-free overlay directly below the MacBook notch shows recording, transcription and response status.

## Download

Ready-to-run Apple Silicon builds are available under [GitHub Releases](https://github.com/sschluet/middleai/releases). Download `MiddleAI-v<version>-macOS-arm64.zip`, unpack it and move `MiddleAI.app` to `/Applications`.

The current development releases are ad-hoc signed but not yet Developer-ID signed or notarized. On first launch, macOS can therefore require right-clicking `MiddleAI.app` and choosing **Open**. Microphone and Accessibility permissions, provider credentials and local speech models must be configured separately on every Mac.

Each release includes a SHA-256 checksum file and a machine-readable Swift dependency inventory. Models are downloaded on first use and are never included in the release archive.

## What is included

- Native SwiftUI menu-bar app with first-run settings, a searchable MiddleAI conversation window, status, profiles and current-chat link
- Native launch-at-login support with a live macOS registration status and direct access to Login Items settings
- Independently configurable single-press or intentional double-tap handling for the left and right Option keys
- Local Parakeet TDT v3 multilingual speech recognition through FluidAudio and Core ML
- Native 258-point island that overlaps the MacBook camera notch seamlessly, with rounded top and bottom transitions, macOS-sized typography, target-app icon and seven-bar level meter
- Silent dismissal for accidental, too-short or empty Option-key recordings
- Optional on-device dictation polishing with Apple Intelligence to remove filler words, repetitions and slips before insertion
- Conservative spoken formatting commands for configurable target applications, including paragraphs, line breaks, German quotation marks, punctuation and rich lists
- Accessibility-first text insertion for compatible plain-text fields, with a clipboard-preserving fallback for rich editors
- Shared Swift core plus `middleai` CLI
- Loopback-only synchronous `POST /input` plus queued `POST /command` for optional local integrations
- SQLite conversation/message cache plus persistent, editable profile system prompts
- `HeuristicRouter`, `EmbeddingRouter`, `LLMRouter` and default `HybridRouter`
- Password and API-key auth providers; passwords/tokens live in macOS Keychain
- Selectable answer provider: MiddleAI Lokal, OpenWebUI, OpenAI Platform or OpenRouter
- Fully local answer provider for an Ollama or llama.cpp loopback server, with streaming and conversation continuity
- Enforced strict-offline mode that blocks hosted providers, non-loopback endpoints and remote redirects
- Model discovery after authentication and streaming responses for all providers
- API keys and passwords stored only in macOS Keychain
- OpenWebUI adapter with TLS validation, optional private CA and server-side chat persistence
- Dedicated Devices settings with macOS-default or fixed microphone and speaker routing
- Supertonic 3 multilingual TTS with native Core ML inference, automatic German/English pronunciation, spoken German number normalization, five female voices, 44.1-kHz audio, local macOS fallback and immediate barge-in
- Structured privacy-safe logging, in-app diagnostics, redacted support export and `middleai doctor`
- Explicit local knowledge sources with safe-path validation, incremental reindexing, local citations and no whole-disk discovery
- Profile-scoped personal memory that is only created, edited or deleted by the user
- Local selected-text transformations with before/after preview and explicit apply
- Allow-listed local voice actions; side effects such as reminders require visible confirmation
- User-approved global, profile and application-specific STT correction lexicon plus local quality metrics
- Explicit microphone meeting capture with local transcription, summary, decisions, tasks and Markdown/JSON archive
- Shared priority-aware inference scheduler and a device-specific local model benchmark
- Configurable local system-integrity monitor for MDM/Intune profiles, macOS protections, local accounts, certificates, network settings, system extensions and persistence entries
- User-confirmed baseline, tamper-evident local finding history, bounded notifications, critical voice alerts, safe simulations and optional local-only AI explanations

## Install and build

### System requirements

| Component | Minimum | Recommended |
| --- | --- | --- |
| Mac | Apple Silicon M1 | M2 or newer for faster local speech generation |
| macOS | macOS 14 Sonoma | Current macOS release |
| Memory | 8 GB for dictation and Supertonic | 16 GB for Qwen3-TTS, 24 GB for Voxtral or heavy multitasking |
| Free disk space | 5 GB for one compact voice setup | 12–15 GB for all current models, downloads and temporary files |
| Network | Required for initial model downloads; optional afterward with a local answer provider | Stable broadband connection for first setup |

The distributed app is currently arm64-only and does not run on Intel Macs. Apple Intelligence based dictation polishing and spoken-response summaries require macOS 26, Apple Intelligence and an eligible Mac. On macOS 14 and later, MiddleAI remains usable and falls back to conservative local text cleanup and extractive summaries.

Building from source additionally requires Swift 6 Command Line Tools or Xcode:

```sh
cd ~/Codex/middleai
./setup.sh
open dist/MiddleAI.app
```

The setup builds an ad-hoc signed local `.app`, places the CLI at `dist/bin/middleai`, and creates `~/.middleai/config.yaml`. Nothing is installed system-wide.

The first launch downloads the Parakeet Core ML STT model and the selected TTS model once. Both run locally after those downloads. Settings → Speech shows download progress plus installed, incomplete, repair-required and locally updated states for every managed TTS model. Model manifests record the source, exact downloaded revision, license, expected artifacts, runtime versions and the last successful startup. Installed or partial downloads can be repaired, updated or moved to the macOS Trash; MiddleAI never deletes the shared managed runtime with an individual voice model. Managed Python runtime packages are pinned to exact versions and SHA-256 hashes; installation fails closed when a downloaded wheel does not match the lock file.

Voxtral remains available only after an explicit CC BY-NC 4.0 acknowledgement. If an older configuration selects Voxtral without that acknowledgement, MiddleAI safely switches to the local macOS voice. This is intended to prevent accidental business use of a non-commercial model.

### Local intelligence and chat routing

Settings → Intelligence separates conversation routing from answer generation. The provider selected under Settings → Connection always generates the actual answer. MiddleAI only decides whether an input continues the current conversation, switches to a recent one or starts a new chat.

The Hybrid strategy first compares recency, wording and local text similarity. If those signals disagree, one optional local intelligence source can break the tie:

- **Apple Intelligence** uses the on-device macOS Foundation Model on supported macOS 26 systems. If it is unavailable, Hybrid safely falls back to its built-in rules.
- **Ollama** uses its local `/v1` chat-completions API, normally at `http://127.0.0.1:11434`, with an already downloaded model such as `qwen3:4b`.
- **llama.cpp** uses a local `llama-server` or router with the same `/v1` endpoints. MiddleAI defaults this option to `http://127.0.0.1:18881` and calls `/v1/models` plus `/v1/chat/completions`.
- **MiddleAI rules only** disables the optional model and requires no separate AI runtime.

For Ollama or llama.cpp, the configured model ID or alias must be known to the server. A successful connection test with an empty `/v1/models` response means the server is reachable, but no model is currently advertised. Only the current input and the titles and summaries of up to eight recent local conversations are sent to this loopback service.

### Fully local answers and strict offline mode

Choose **MiddleAI Lokal** under Settings → Connection to use the configured Ollama or llama.cpp server for the complete answer, not only for routing. MiddleAI uses the loopback-only `/v1/models` and `/v1/chat/completions` interface, streams the answer and keeps conversation history in its permission-protected SQLite store. The local model can therefore continue earlier turns without a hosted provider.

The **Strict offline** switch is an enforced network boundary. It accepts only `localhost`, `127.0.0.1` or `::1`, blocks hosted answer providers before their client is created and refuses redirects from a local service to a remote host. A loopback OpenWebUI remains permitted. Enabling the switch automatically changes to MiddleAI Lokal when the current provider is remote.

The local benchmark sends one short, non-persistent request to the selected model and reports time to first token, estimated output speed, RAM, available disk, CPU, thermal state and the model-size class recommended for that Mac. It is a practical compatibility measurement, not a synthetic hardware score.

### Local system-integrity monitor

Settings → System Monitor provides an optional local security layer. It compares a user-confirmed baseline with the current MDM enrollment, configuration-profile contents and their security-sensitive payload types, managed preferences, firewall, stealth mode, FileVault, Gatekeeper, System Integrity Protection, SSH and Remote Management state, local users and administrators, individual system certificates and trust settings, DNS and proxy settings, system extensions, LaunchAgents, LaunchDaemons, privileged helpers, login items, the user crontab, `authorized_keys`, shell startup files, Microsoft Defender health and the MiddleAI executable. It also evaluates narrowly filtered local security events and repeated Microsoft Intune agent errors. No scan result or log text is sent to a hosted provider.

The default interval is 30 minutes. Important startup, SSH and managed-preference paths additionally trigger a debounced scan. Before a baseline can be confirmed, MiddleAI shows source coverage and blocks confirmation when a required source was unavailable. Findings are stored under `~/.middleai/system-integrity` with owner-only permissions; baseline and bounded history are authenticated with HMAC-SHA256 using a random device-bound secret in the macOS Keychain. Legacy hash-only files are verified and migrated locally.

Findings move through **New**, **Ongoing**, **Escalated**, **Reviewed** and **Resolved** states. The Open, Resolved and All filters form a local timeline. Every collector-controlled source offers a direct **Open source** action for the relevant file, application or System Settings pane; missing files open their containing folder when possible. Findings can be acknowledged and a local Markdown report can be exported. macOS notifications and voice output have independent per-finding cooldowns. Critical alerts use a separate daily reserve so ordinary warnings cannot suppress them.

Optional natural-language explanations use only the local intelligence source selected in Settings: Apple Intelligence, Ollama or llama.cpp. If no local model is available, deterministic detection continues and no hosted fallback occurs. The local model does not assign severity and receives findings as untrusted data.

Create the baseline only while the Mac is in a known, trusted state. First run the source check, inspect any coverage gaps, and only then explicitly confirm the pending snapshot. Review findings before replacing it. Built-in information, warning and critical simulations let you test the interface, notifications and voice output without changing the system.

When upgrading from the 0.9 baseline schema, MiddleAI continues evaluating every previously supported source but temporarily excludes collectors introduced in 0.10 from comparison. The settings page explains this state and offers the complete current snapshot for review. New collectors become active only after that expanded baseline is explicitly confirmed, so an application update does not manufacture a large set of new findings.

This implementation deliberately requires no Apple Developer account. It does not install an Endpoint Security system extension and therefore cannot observe every process or file access in real time. It is an integrity and anomaly assistant, not an antivirus, EDR or proof that an attack occurred. Keychain-backed authentication protects local files against undetected offline editing, but a fully compromised administrator who controls the running user, Keychain and application remains outside the protection model; the feature is not external attestation.

### Local knowledge and personal memory

Settings → Local Knowledge accepts only a file or concrete subfolder that the user explicitly grants. Supported files are UTF-8 or Latin-1 text, Markdown, CSV/TSV, JSON, YAML and HTML. Hidden files, symbolic links, credential stores, mail/message databases, key material, broad roots and files larger than 8 MB are rejected. Packages and hidden descendants are skipped. Enabled sources are reindexed locally after startup and can be disabled, refreshed or revoked individually; revocation deletes their indexed chunks.

Retrieval is lexical and local. Results carry the source filename and line range. Knowledge excerpts and personal profile memories are injected only when the selected answer endpoint is on this Mac. OpenAI, OpenRouter and remote OpenWebUI servers never receive this local context.

Personal memory is explicit CRUD rather than passive learning. Each entry belongs to one profile, may have an expiry date and remains visible and individually deletable. MiddleAI exposes no API that silently learns a memory from conversations.

### Selected text and safe local actions

Select text in another app and choose **Services → Mit MiddleAI bearbeiten…** from its context menu. MiddleAI remembers the last active external application and opens a compact action chooser. If Accessibility exposes an editable selection, MiddleAI binds that exact target and verifies it against the Services payload. Read-only selections from Safari, Edge and other browsers are still supported, but their result is copied instead of replacing webpage content. The menu-bar submenu **Markierten Text lokal bearbeiten** remains available for editable applications that hide macOS Services. MiddleAI reads only the explicit selection, rejects secure fields and limits one transformation to 50,000 characters. Correction, polishing, shortening, expansion, translation, bullets and reply drafting run through the configured local Ollama or llama.cpp model. The main window shows original and proposal side by side; replacement or copying happens only after an explicit click. Correction and polishing are rejected when the local result diverges too far from the source.

The service accepts only plain-text pasteboard types (`public.plain-text` and `public.utf8-plain-text`), returns no automatic replacement and never sends selected text to a hosted answer provider. macOS or the source application decides whether the command appears directly in the context menu or inside its **Services** submenu. On each Mac, enable it once under System Settings → Keyboard → Keyboard Shortcuts → Services → Text.

The assistant key also recognizes a closed set of deterministic local commands such as creating a new conversation, switching a profile, copying the last answer, summarizing the selection and creating a reminder. Structured model output is validated against the same allow-list and rejects unknown fields, URLs and commands. A reminder receives a short-lived, single-use authorization and a visible confirmation dialog before EventKit is called. No voice action can execute shell code.

### Adaptive STT and local meetings

The Speech Input settings contain an explicit correction lexicon. A user-approved mapping can be global or scoped to the active profile; the longest and most specific match wins. It is applied only after Parakeet transcription, so an empty dictionary is a complete no-op. The file is stored locally with owner-only permissions. Signal, density and confidence metrics contain no spoken content. Core APIs for reproducible engine comparisons calculate real-time factor and word error rate without changing the default engine automatically.

Start a meeting recording from Settings → Workflows or the menu bar. Recording never starts in the background. The current implementation records the selected microphone as one bounded local session, transcribes it with the same local STT stack, extracts an overview, decisions and action items, then writes owner-only JSON and Markdown files below `~/.middleai/meetings`. Stop finalizes the recording; Cancel discards it. The core capture interface also models system-audio capability without requesting Screen Recording permission implicitly; the shipping UI currently records the selected microphone only.

All STT, local LLM, TTS, embedding and background-indexing operations share a priority-aware inference scheduler. Interactive recording and generation are admitted before queued background indexing, avoiding simultaneous multi-model pressure on unified memory. Ollama and llama.cpp remain separate processes, so a local answer-runtime failure cannot terminate the menu-bar app.

### Copying MiddleAI to another Mac

`MiddleAI.app` contains the native application and its Swift dependencies. Copying only the app to `/Applications` on another Apple Silicon Mac is sufficient to start setup; Xcode, Homebrew and a separately installed Python are not required. Qwen3-TTS and Voxtral bootstrap their own managed Python/MLX runtime under `~/.middleai/runtime`.

The current development build is ad-hoc signed, not Developer-ID signed or notarized. Gatekeeper can therefore require right-clicking the app and choosing **Open**. A regular organizational release should be Developer-ID signed, notarized and distributed as a signed DMG or ZIP.

The following data deliberately does not travel inside the app and must be configured on each Mac:

- answer provider, model ID and any OpenWebUI server settings
- API keys or passwords, which remain in macOS Keychain
- microphone and speaker, either following the current macOS default or pinned by Core Audio UID
- Password or API token stored in that Mac's Keychain
- Microphone and Accessibility permissions
- Activation keys and user preferences under `~/.middleai`
- STT and TTS model caches

After the initial downloads, speech recognition and speech synthesis work offline. Assistant requests can also work offline when MiddleAI Lokal or a loopback OpenWebUI is selected and the corresponding service is running.

### Local model storage

| Component | Approximate installed size |
| --- | ---: |
| MiddleAI.app | 15 MB |
| Parakeet TDT v3 STT including Core ML data | 1 GB |
| Supertonic 3 | 0.2–0.4 GB |
| Qwen3-TTS 4-bit plus managed runtime | 2.8 GB |
| Voxtral 4-bit plus managed runtime | 3 GB |
| All listed TTS models including PocketTTS plus STT | 9–10 GB plus temporary download space |

Sizes are rounded and can change with upstream model revisions. Old model versions remain in the user's cache until removed and can increase total disk use. Voxtral is licensed under CC BY-NC 4.0 and must not be used for commercial or business purposes.

## First start

1. Open `dist/MiddleAI.app`; MiddleAI appears in the menu bar.
2. Open **Settings**.
3. Choose MiddleAI Lokal, OpenWebUI, OpenAI Platform or OpenRouter. Start the local Ollama/llama.cpp service or enter the required password/API key, then load and select a model returned by that provider.
4. Keep TLS verification enabled. Add a company CA PEM/DER path when required.
5. Select **Save & Test Connection**.
6. Allow MiddleAI under **Privacy & Security** for Microphone and Accessibility. Restart MiddleAI if macOS asks for it.
7. Under **Settings → General**, keep **Launch MiddleAI automatically with macOS** enabled. If macOS requests confirmation, allow MiddleAI under **General → Login Items & Extensions**.
8. Double-tap left Option, speak and tap it once to insert dictation into the active field.
9. Double-tap right Option to ask the configured provider. MiddleAI displays and speaks the response. One press cancels transcription, provider work or speech that is already running.

MiddleAI uses Apple's ServiceManagement framework for launch-at-login registration. New and existing installations enable it by default and remember a later opt-out. The app launches after the user signs in, remains in the menu bar and does not open its main window automatically. For a stable registration, keep `MiddleAI.app` in `/Applications`; moving or renaming the bundle can require registering it again.

For OpenWebUI, select either username/password or API-key authentication explicitly. The username field is used only for password login; both secret types are stored in a Keychain scope derived from the server and active profile. This lets an entered replacement secret be tested without exposing or overwriting another server's credential.

OpenAI and OpenRouter credentials are API keys, not consumer subscription logins. MiddleAI stores them under provider-specific Keychain accounts and never writes them to `~/.middleai/config.yaml`. OpenRouter uses its authenticated user-model endpoint when available so the picker reflects account privacy and routing preferences; it falls back to the public model catalog if that endpoint is unavailable. Their configurable context-token budget limits the earlier conversation history MiddleAI sends; it is not an output limit, and larger requests can increase provider API charges.

Settings → Devices owns audio routing. Choosing **macOS default** follows subsequent system changes automatically. Choosing a concrete microphone keeps recording on that Core Audio device. Choosing a concrete speaker routes MiddleAI-generated audio through that device without changing the global macOS default; if the device disappears, playback falls back to the system output.

Each recording uses a fresh AVAudioEngine and lets Core Audio negotiate the tap format at capture time. USB speakerphones, webcams, docks and displays may switch between 16, 44.1 and 48 kHz when activated; MiddleAI accepts the actual buffer format, downmixes locally and resamples only after capture instead of forcing a stale hardware rate.

Bluetooth headsets such as AirPods can briefly rebuild their Core Audio route when the microphone activates because macOS changes from the output-only profile to the bidirectional headset profile. MiddleAI tolerates that expected configuration change and retries capture startup for a short, bounded period while the new input becomes ready. Selecting **macOS default** therefore also follows a headset connected or chosen after MiddleAI was launched; a pinned device remains pinned until it is changed in Settings.

The Voice settings contain **Diktat vor dem Einfügen lokal glätten**. On macOS 26, this uses Apple's on-device Foundation Model with German locale support. MiddleAI accepts a generated correction only when numbers and protected terms remain present, the vocabulary stays close to the transcript and no substantial new wording is introduced. Otherwise it keeps a conservative local cleanup that only removes filler sounds and direct repetitions. Dictation text is never sent to OpenWebUI or another cloud service for polishing.

Settings → Spracheingabe documents the active STT stack and exposes the useful Parakeet TDT v3 controls. The microphone picker can follow the macOS default or pin one connected Core Audio input device, which prevents a display, headset or conference speaker from silently taking over recording. German mode keeps the decoder in a compatible Latin script, while multilingual mode removes that restriction. The int8 encoder is the recommended accuracy setting; int4 uses less storage. Automatic acceleration lets Core ML select CPU, GPU and Neural Engine, while the compatibility option restricts execution to CPU and GPU. For recordings longer than roughly 30 seconds, accurate long-form mode locally compares additional decoding paths at the cost of some processing time. A recording that contains no measurable input now identifies the selected microphone instead of disappearing silently.

### Spoken formatting in selected apps

MiddleAI can translate explicit German structure commands into formatted output. Microsoft Word (`com.microsoft.Word`), Microsoft PowerPoint (`com.microsoft.Powerpoint`), Microsoft Outlook (`com.microsoft.Outlook`) and Proton Mail (`ch.protonmail.desktop`) are enabled by default. Under Settings → Spracheingabe, each default can be disabled and additional installed `.app` bundles can be selected. MiddleAI stores only their bundle identifiers.

- `neue Zeile` inserts a line break; `neuer Absatz` starts a new paragraph.
- `in Anführungsstrichen Projekt Apollo` becomes `„Projekt Apollo“`.
- `Anführungszeichen auf … Anführungszeichen zu` and `Zitat Anfang … Zitat Ende` create paired German quotation marks.
- `Aufzählung, Punkt eins …, nächster Punkt …, Liste Ende` creates a bulleted list.
- `Aufzählung: 1. …, zweitens … und drittens …` also creates a bulleted list.
- Starting with `nummerierte Liste` creates an ordered list.
- Spoken `Komma`, `Doppelpunkt`, `Semikolon`, `Fragezeichen`, `Ausrufezeichen` and `Satzende` are converted conservatively.

MiddleAI captures the focused text field when recording starts and restores the target application before insertion. For compatible plain-text fields it writes through the macOS Accessibility API and verifies the resulting value. Rich editors and fields that do not expose a writable value use a clipboard-preserving paste fallback with one bounded verification retry when the target can be read safely. MiddleAI reports an unverified insertion as such instead of claiming success or pasting twice. Rich output places plain text, HTML and RTF representations on the pasteboard so Word, PowerPoint, Outlook and Proton Mail can preserve lists and paragraphs. The previous clipboard contents are restored only after the paste has completed. Detection is deliberately conservative: ordinary wording such as `Die neue Zeile ist rot` is not interpreted as a command, and all other applications continue to receive plain text only.

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
dist/bin/middleai api-secure
dist/bin/middleai api-token
dist/bin/middleai serve
```

`serve` runs the same loopback HTTP adapter without the menu-bar app. Do not run both on the same port.

## Local HTTP input

```sh
curl http://127.0.0.1:8765/input \
  -H "Authorization: Bearer $(dist/bin/middleai api-token)" \
  -H 'Content-Type: application/json' \
  -d '{"text":"Und wie sieht es mit Gardena aus?","source":"local-integration"}'
```

The server refuses configuration on `0.0.0.0`. New installations require a random local bearer token by default. It is stored separately from OpenWebUI credentials under the Keychain account `local_http_token`. Existing configurations keep their explicit setting; `middleai api-secure` enables authentication and prints the token. The bundled `middleai-input` and `middleai-ask` scripts read that token from Keychain automatically.

`POST /command` remains available for optional local automation and returns `202 Accepted` plus a request ID immediately. `GET /requests/{id}` reports its state and `POST /requests/{id}/cancel` cancels queued or active work. `/health` provides a content-free readiness check. Request size, timeout, concurrency and queue depth are bounded. These endpoints are not used by either native Voice mode.

## Conversation routing

Commands such as “Neuer Chat”, “Stopp”, “Nicht vorlesen”, “Zurück zum MacBook-Thema” and “Architekturmodus” are intercepted locally. Normal input is scored against the current and recent chats using time, title, summary, recent user/assistant messages and local semantic similarity. The hybrid router combines heuristic and vector decisions and can optionally ask a local `/v1/chat/completions` routing model. If that model is unavailable, the heuristic path remains operational.

Within the configured continuation window, a new voice request continues the active conversation and sends its prior user/assistant messages to OpenWebUI, OpenAI or OpenRouter. This keeps natural follow-ups such as “Warum ist das so?” in context even when they repeat no keywords. Say “Neue Frage” or “Neues Thema”, use the local “Neuer Chat” command, or open a new conversation from the menu to deliberately reset the context.

A newly opened conversation is an in-memory draft. MiddleAI writes it to the local history only when the first complete user/assistant exchange succeeds. Closing an unused compose window, cancelling input or encountering a provider failure therefore cannot create an empty conversation. Empty cache rows left by older versions are removed automatically when the conversation manager starts.

The assistant overlay remains visible while the provider streams and until the local spoken response has actually finished. Pressing the configured assistant activation key again during generation or speech cancels the remote request, the local TTS queue and the overlay together.

The local router only returns a routing decision; it is never asked to answer the user. Every model decision is validated against the current conversation IDs and confidence range before it can be applied. Local Ollama and llama.cpp requests have a short timeout and a circuit breaker, so an unavailable service cannot repeatedly delay dictation or assistant requests. Confidence thresholds, timeout and circuit-breaker limits are configurable in `~/.middleai/config.yaml`. The file contains schema-versioned JSON, which is valid YAML 1.2 and safely preserves quotes, hashes and arrays. Existing legacy files are migrated once with a `.legacy-backup` copy. MiddleAI validates the complete configuration, enforces `0700` on its data directory and `0600` on the configuration file.

The legacy `logging.level` and `logging.logPrompts` keys remain readable for configuration compatibility. Runtime logging intentionally uses a fixed privacy-safe event allow-list, and prompt/response logging stays disabled regardless of those reserved values.

## Profiles

The Standard, Management, Architecture, Coding and Research profiles can each carry a freely editable display name, an editable system prompt and optional overrides for answer provider, model, TTS voice, spoken-response mode and local context budget. The five established names remain the defaults and can be restored individually. Renaming changes only the visible label; a stable internal ID keeps existing conversations, memories, STT lexicon entries and overrides associated with the correct profile. Names must be unique and may contain up to 60 characters. Empty overrides inherit the global setting. Profiles are configured in Settings and saved in `~/.middleai/config.yaml`; switching a profile rebuilds the provider connection deliberately so all overrides become active together. STT and dictation polishing remain local and unchanged.

## TTS and privacy

`adaptive` is the default. It combines a natural local neural voice with the reliable German Apple voice for longer texts, numbers and difficult terminology. `supertonic3` can be selected directly and uses a multilingual Core ML model with explicit German synthesis, 44.1-kHz output and five female reference styles. Selecting a style in Settings immediately plays the same German sample, making the voices directly comparable. The model download is about 400 MB and is reused offline after the first preparation.

`pockettts` remains available for compatibility, but several of its styles can have a noticeable accent in German. A complete response is synthesized into one continuous WAV before playback to avoid player restarts between sentences. Audio is synthesized and played inside MiddleAI; no Python process, local server or cloud service is involved.

`macos` remains a completely local fallback. MiddleAI lists the installed German Apple voices with gender and quality information. Additional Apple voices can be opened for download from the Speech settings. `local_model` remains available for an optional custom executable. New user input interrupts playback and clears pending speech immediately.

In `smart_summary` mode MiddleAI waits for the complete provider response and then asks Apple Intelligence for a short grounded German spoken summary. If Apple Intelligence is unavailable, the configured loopback Ollama or llama.cpp model is tried with bounded input, a short timeout and the same circuit-breaker behavior as routing. Candidate summaries must end on a sentence boundary, stay within the word budget, contain no invented figures and remain lexically grounded in the answer. If either model is unavailable or fails validation, a deterministic local fallback ranks relevant conclusion and recommendation sentences across the response instead of reading only its opening paragraph.

STT microphone audio remains in memory and is never sent to an answer provider. Only the finished assistant-mode transcript and the context required within the selected profile budget are sent to the configured provider. Dictation-mode transcripts never leave the Mac. A private session can be enabled at runtime to keep MiddleAI's routing conversations entirely in memory; disabling it discards that memory. This does not prevent a configured remote provider from retaining requests according to its own policy.

## Tests and diagnostics

```sh
make test
dist/bin/middleai doctor
```

The portable test runner covers configuration migration and permissions, HTTP parsing and security, SQLite, command detection, formatting, routing, TTS queue/barge-in, OpenWebUI streaming, fallback and cancellation. An additional XCTest target provides structured IDE/CI reporting and coverage when a full Xcode toolchain is available. Standalone Command Line Tools can continue to use `make test` because that environment does not ship an importable XCTest module.

Settings → Diagnose checks permissions, configuration rights, disk space, local API protection, the selected OpenWebUI model and connection. The offline overview distinguishes ready components, missing local downloads, services that must be started and providers that require a network connection. Its privacy-safe support report uses an explicit allow-list and omits credentials, URLs, paths, model IDs, prompts, responses and failed diagnostic details. Settings → Hilfe can start a private in-memory session, inspect and delete the local routing cache without deleting canonical conversations in OpenWebUI. The cache defaults to a 90-day retention period; 30 days, one year or permanent local retention can be selected there.

See [ARCHITECTURE.md](ARCHITECTURE.md), [SECURITY.md](SECURITY.md) and [DEVELOPMENT.md](DEVELOPMENT.md) for implementation and maintenance details.

## License

MiddleAI source code is licensed under the [Apache License 2.0](LICENSE). Third-party libraries and optional downloaded speech models retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). In particular, the optional Voxtral model is CC BY-NC 4.0 and is not permitted for commercial or business use.
