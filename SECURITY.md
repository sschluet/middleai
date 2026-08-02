# Security

MiddleAI is local-first and transmits only the user's request and cached conversation context to the explicitly configured private Open WebUI instance.

- Passwords/API tokens are read from macOS Keychain; configuration and logs contain no credentials.
- `.env` is gitignored and supported only as a development password fallback.
- TLS verification defaults to on. A private CA may be added without disabling the system trust store.
- The HTTP listener accepts only `127.0.0.1` or `::1`; `0.0.0.0` is rejected during config parsing and server startup.
- Local API authentication is optionally supported through a bearer token in Keychain.
- All TTS implementations are local. There is no cloud provider or automatic external fallback.
- Microphone samples remain in memory and are transcribed locally with Core ML. MiddleAI does not save recordings.
- Parakeet model files are downloaded from the FluidInference Hugging Face repository on first use and cached locally by FluidAudio.
- Managed TTS model files are downloaded only after the corresponding local engine is selected. Supertonic and PocketTTS use FluidInference model repositories; Qwen3-TTS and Voxtral use their documented Hugging Face repositories.
- Qwen3-TTS and Voxtral install an isolated Python/MLX runtime under `~/.middleai/runtime`. The pinned `uv` bootstrap archive is verified with SHA-256 before execution. Python packages and model weights require network access during initial preparation; synthesized text and audio remain local.
- Optional Apple Intelligence dictation polishing runs on-device. Candidate corrections are rejected if protected terms or numbers change or if the wording diverges substantially from the transcript.
- Dictation briefly uses the macOS pasteboard, restores its prior items after pasting and does not log the transcript.
- INFO logging records event names, latency-ready metadata and sizes—not prompt/response text. Sensitive metadata keys are discarded.
- There is no analytics, telemetry, crash upload or automatic external data transfer.

Optional model downloads remain subject to their own licenses. Voxtral is CC BY-NC 4.0 and must not be used for commercial or business purposes. See `THIRD_PARTY_NOTICES.md` for sources and terms.

`tls_verify=false` is technically understood for controlled development environments, but should not be used in production. The UI keeps verification enabled by default.

The local model executable path is user-controlled configuration. MiddleAI launches that exact executable directly through `Process`; it does not invoke a shell or interpolate command strings.
