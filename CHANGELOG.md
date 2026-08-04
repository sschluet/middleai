# Changelog

All notable MiddleAI changes are documented here. Versions follow semantic versioning.

## 0.5.1 — 2026-08-04

### Dictation

- Fixed false insertion errors caused by stale Accessibility elements in SwiftUI, Electron and Microsoft Office editors.
- Reacquired the active text field after returning focus to the target application.
- Prevented verification retries from duplicating text in rich-text editors and normalized line endings during verification.
- Added privacy-safe insertion diagnostics without recording dictated content.

## 0.5.0 — 2026-08-04

### Reliability

- Added a completion state machine for OpenWebUI streams, background research and tool tasks.
- Serialized concurrent assistant requests without confusing normal callers with voice barge-in.
- Added bounded retries for transient OpenAI and OpenRouter responses and bounded hosted context.
- Made user/assistant exchanges atomic and isolated profile, provider and private-session context.
- Added verified Accessibility-first text insertion with a clipboard-preserving fallback.

### Local speech

- Reworked microphone capture around a bounded incremental 16-kHz accumulator, optional silence stop and device-hotplug fallback.
- Added TTS initialization sharing, cancellation-safe fallback behavior and renderer/player watchdogs.
- Added a validated owner-only LRU audio cache and a configurable pronunciation dictionary.
- Added installed, partial, repair and removal states for managed TTS models.
- Added grounded local Ollama/llama.cpp summaries before the deterministic spoken-summary fallback.

### Settings and privacy

- Added per-profile provider, model, voice, spoken-mode and context overrides.
- Added runtime-only private sessions backed by an in-memory conversation store.
- Added real offline-readiness checks and a privacy-safe support report.
- Clarified password/API-key authentication, local-LLM timeouts and hosted API context costs.

### Maintenance

- Removed the unused native MLX Audio Swift dependency and obsolete UI/model code.
- Expanded portable and XCTest regression coverage and CI app-bundle verification.
- Updated the README, architecture, security notes and GitHub Pages product site.
