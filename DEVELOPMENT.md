# Development

## Commands

```sh
make build
make test
make run
./scripts/audit-repository.sh
```

The package uses FluidAudio 0.15.5 for local Parakeet speech recognition and Core ML speech synthesis, plus MLX Audio for optional Qwen3-TTS inference. Qwen3-TTS and Voxtral can bootstrap a MiddleAI-managed Python/MLX runtime under `~/.middleai/runtime`. The app links Apple's `AVFoundation`, `ApplicationServices`, `Security` and `Network` frameworks plus system SQLite.

Products:

- `MiddleAI`: native menu-bar executable
- `middleai-cli`: internal SwiftPM product, packaged as `dist/bin/middleai`; CLI and headless HTTP service
- `middleai-tests`: portable unit/integration test runner
- `MiddleAICoreTests`: XCTest suite for full-Xcode CI, IDE reporting and coverage
- `MiddleAICore`: testable shared library

## Configuration and data

- Schema-versioned JSON/YAML 1.2 configuration: `~/.middleai/config.yaml`
- SQLite: `~/.middleai/middleai.sqlite`
- Keychain service: `de.middleai.openwebui`
- Default profiles: `config/profiles.yaml`

The repo's `config/profiles.yaml` is a distributable example. User-specific model selection belongs in `config.yaml` or the Settings UI. Legacy hand-written YAML is migrated automatically and retained once as `config.yaml.legacy-backup`.

## Adding an adapter

Input adapters should transform their source into `{text, source}` and call `MiddleAIEngine.handle`. They must not contain routing or Open WebUI logic. New auth, TTS and routing providers implement their corresponding protocol and are composed in `MiddleAIFactory`.

## Test policy

Tests use an in-memory store where persistence is irrelevant, a temporary real SQLite database for migrations, and a `URLProtocol` mock server for HTTP. No live credentials or external network access are used.

`make test` always runs the portable runner. CI additionally runs `swift test --enable-code-coverage` with the selected Xcode toolchain. Swift sources compile in Swift 6 language mode; new unchecked-sendable boundaries require a comment explaining their synchronization or third-party compatibility constraint.

`scripts/audit-repository.sh` checks committed licensing and dependency-lock artifacts, searches tracked source files for private keys and likely embedded credentials, verifies SHA-256 hashes in the managed TTS runtime lock, and runs `git diff --check`. Run it before publishing a branch or tag.
