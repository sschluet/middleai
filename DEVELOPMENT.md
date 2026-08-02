# Development

## Commands

```sh
make build
make test
make run
```

The package uses FluidAudio 0.15.5 for local Parakeet speech recognition and Core ML speech synthesis, plus MLX Audio for optional Qwen3-TTS inference. Qwen3-TTS and Voxtral can bootstrap a MiddleAI-managed Python/MLX runtime under `~/.middleai/runtime`. The app links Apple's `AVFoundation`, `ApplicationServices`, `Security` and `Network` frameworks plus system SQLite.

Products:

- `MiddleAI`: native menu-bar executable
- `middleai-cli`: internal SwiftPM product, packaged as `dist/bin/middleai`; CLI and headless HTTP service
- `middleai-tests`: portable unit/integration test runner
- `MiddleAICore`: testable shared library

## Configuration and data

- User YAML: `~/.middleai/config.yaml`
- SQLite: `~/.middleai/middleai.sqlite`
- Keychain service: `de.middleai.openwebui`
- Default profiles: `config/profiles.yaml`

The repo's `config/profiles.yaml` is a distributable example. User-specific model selection belongs in `config.yaml` or the Settings UI.

## Adding an adapter

Input adapters should transform their source into `{text, source}` and call `MiddleAIEngine.handle`. They must not contain routing or Open WebUI logic. New auth, TTS and routing providers implement their corresponding protocol and are composed in `MiddleAIFactory`.

## Test policy

Tests use an in-memory store where persistence is irrelevant, a temporary real SQLite database for migrations, and a `URLProtocol` mock server for HTTP. No live credentials or external network access are used.
