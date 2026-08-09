# Changelog

All notable MiddleAI changes are documented here. Versions follow semantic versioning.

## 0.8.2 — 2026-08-09

### Selected text service

- Added the native macOS service **Mit MiddleAI bearbeiten…** for text selections exposed by other applications.
- Added a compact local action chooser before generation and retained the existing side-by-side preview plus explicit apply boundary.
- Bound editable Services requests to the last active application's exact Accessibility selection even when macOS activates MiddleAI before the provider callback.
- Added a safe read-only path for selected webpage text from Safari, Edge and similar applications; proposals are copied instead of attempting to modify webpage content.
- Kept the menu-bar selection workflow as a fallback for applications that do not expose macOS Services.
- Added bundle-policy checks for the plain-text-only service declaration and updated in-app help, README and GitHub Pages.

## 0.8.1 — 2026-08-09

### Profiles

- Made all five profile display names editable while retaining their stable internal IDs.
- Kept Standard, Management, Architecture, Coding and Research as the initial defaults and added one-click restoration of each default name.
- Applied custom names consistently in Settings, the menu bar, the conversation window, diagnostics and confirmed voice profile switching.
- Added migration-safe configuration defaults, length and uniqueness validation, and regression coverage for renamed profiles.

## 0.8.0 — 2026-08-09

### Fully local assistant

- Added a complete local answer provider for Ollama and llama.cpp with streaming conversation continuity, bounded timeouts, cancellation and a circuit breaker.
- Added an enforced strict-offline mode that blocks hosted providers, non-loopback endpoints and remote redirects.
- Added a device-specific local-model benchmark for response speed, memory, disk, battery and thermal guidance.

### Knowledge and personal context

- Added explicit local file and folder grants, safe-path validation, incremental text indexing, source citations and per-source revoke controls.
- Added profile-scoped personal memory with explicit create, edit, expiry, enable and delete controls; conversations are never learned silently.
- Added local selected-text correction, rewriting, translation and summarization with a side-by-side preview before replacement.

### Voice workflows

- Added allow-listed local voice actions with single-use confirmation for side effects such as reminders.
- Added a user-approved adaptive STT lexicon with global and profile scopes plus reproducible local quality metrics.
- Added explicit local meeting capture from the selected microphone with transcript, summary, decisions, tasks and owner-only Markdown/JSON export.

### Reliability and interface

- Added a shared priority-aware inference scheduler so interactive speech work runs ahead of background indexing.
- Added dedicated Knowledge and Workflows settings, local-provider help, offline explanations and resource visibility.
- Updated the in-app help, README, architecture documentation and GitHub Pages product site for the local feature suite.

## 0.7.0 — 2026-08-09

### macOS integration

- Added native launch-at-login registration through Apple's ServiceManagement framework.
- Enabled launch at login by default for existing and new installations, with a persistent user-controlled toggle.
- Added live enabled, disabled, approval-required and unavailable states plus a direct link to macOS Login Items settings.
- Kept automatic launches unobtrusive: MiddleAI starts in the menu bar without opening its main window.

## 0.6.1 — 2026-08-05

### Menu bar

- Removed the duplicate settings command from the MiddleAI menu.
- Renamed menu actions consistently in German.
- Changed the diagnostics shortcut to open the Diagnostics settings pane instead of sending a test message to the active conversation.

## 0.6.0 — 2026-08-05

### Voice activation

- Added independently configurable single-press or double-tap activation for dictation and assistant mode.
- Enabled intentional 450-ms double-tap activation by default for both Option keys.
- Kept one-press recording completion and one-press cancellation during transcription, provider streaming and speech output.

### Conversations

- New conversations now remain in memory until the first complete user/assistant exchange succeeds.
- Cancelled input, provider failures and unopened compose windows no longer add empty history entries.
- Existing empty local cache rows and their routing metadata are removed automatically on startup.

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
