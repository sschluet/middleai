# Security

MiddleAI is local-first and transmits only the user's assistant-mode request and required cached conversation context to the explicitly selected OpenWebUI, OpenAI Platform or OpenRouter endpoint.

- Passwords/API tokens are read from provider-specific macOS Keychain accounts; configuration and logs contain no credentials.
- OpenRouter receives the optional application attribution headers documented by the provider. No device name, account name or microphone data is included.
- Switching the answer provider starts a new local conversation so cached context from one provider is not forwarded to another implicitly.
- `.env` is gitignored and supported only as a development password fallback.
- TLS verification defaults to on. A private CA may be added without disabling the system trust store.
- The HTTP listener accepts only `127.0.0.1` or `::1`; `0.0.0.0` is rejected during config parsing and server startup.
- New installations require a randomly generated local API bearer token by default. Legacy configurations retain their explicit setting. The token uses a separate `local_http_token` Keychain account.
- All TTS implementations are local. There is no cloud provider or automatic external fallback.
- Reusable synthesized WAV files are stored in an owner-only cache (`0700` directory, `0600` files), validated before playback and bounded by configurable LRU eviction. The cache can be deleted from Settings.
- Microphone samples remain in memory and are transcribed locally with Core ML. MiddleAI does not save recordings.
- Parakeet model files are downloaded from the FluidInference Hugging Face repository on first use and cached locally by FluidAudio.
- Managed TTS model files are downloaded only after the corresponding local engine is selected. Supertonic and PocketTTS use FluidInference model repositories; Qwen3-TTS and Voxtral use their documented Hugging Face repositories.
- Qwen3-TTS and Voxtral install an isolated Python/MLX runtime under `~/.middleai/runtime`. The pinned `uv` bootstrap archive is verified with SHA-256 before execution. Python runtime dependencies are locked to exact versions and SHA-256 hashes and installed with hash enforcement. Managed models record source, revision, license and validation state in an installation receipt; synthesized text and audio remain local.
- Optional Apple Intelligence dictation polishing runs on-device. Candidate corrections are rejected if protected terms or numbers change or if the wording diverges substantially from the transcript.
- Plain dictation uses the focused accessibility element when supported and verifies the resulting value. Rich-text fallback briefly uses the macOS pasteboard, restores its prior items after app-specific delays and does not log the transcript. A failed or unverifiable insertion is reported instead of being silently declared successful or pasted repeatedly.
- INFO logging accepts only an allow-list of event metadata such as source, latency and sizes—not prompt/response text, usernames or arbitrary fields.
- There is no analytics, telemetry or crash upload. External transfer occurs only for assistant requests, explicit model downloads and user-triggered provider model discovery.
- The local SQLite cache is protected with owner-only file permissions. It is not independently SQLCipher-encrypted; encryption at rest therefore depends on macOS FileVault. Ephemeral sessions can be used when a conversation should not be written to the cache.
- A newly opened conversation is retained only in memory until its first complete exchange; cancelled or failed empty drafts are never written to SQLite.
- Private mode is runtime-only and uses an in-memory conversation store. Leaving it destroys that session. It does not change the retention policy of OpenWebUI, OpenAI or OpenRouter.

Optional model downloads remain subject to their own licenses. Voxtral is CC BY-NC 4.0 and must not be used for commercial or business purposes. See `THIRD_PARTY_NOTICES.md` for sources and terms.

`tls_verify=false` is technically understood for controlled development environments, but should not be used in production. The UI keeps verification enabled by default.

The local HTTP parser enforces header/body limits, timeouts, bounded concurrency and bounded queue depth. Request status and cancellation endpoints reveal only opaque IDs and processing state. Configuration is written atomically with `0600` permissions under a `0700` data directory.

The local model executable path is user-controlled configuration. MiddleAI launches that exact executable directly through `Process`; it does not invoke a shell or interpolate command strings.

CI runs formatting, Swift 6 builds, portable and XCTest suites, and a repository policy audit that rejects private-key material, likely hard-coded credentials, missing notices and unhashed TTS runtime dependencies. Tagged releases additionally publish a dependency inventory beside the application and checksum.
