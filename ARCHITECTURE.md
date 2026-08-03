# Architecture

## Runtime flow

```text
Right Option / CLI / synchronous HTTP / Quick Input
  -> CommandDetector
  -> ConversationManager
  -> HybridRouter (Heuristic + local vector + optional local LLM)
  -> selected AssistantClient (OpenWebUI / OpenAI / OpenRouter)
  -> SSE token stream
  -> spoken-response summarizer -> TTSQueue
  -> selected local engine (Qwen3-TTS / Supertonic / Voxtral / Apple voice)
  -> local audio playback with immediate barge-in
```

The native Voice path starts before the engine:

```text
left Option  -> AVAudioEngine -> configurable Parakeet TDT v3 -> conservative local cleanup -> restore target app -> focus-safe paste sequence
right Option -> AVAudioEngine -> Parakeet TDT v3 -> MiddleAIEngine -> answer provider -> local TTS
```

The global Option-key monitor supports both tap-to-toggle and push-to-talk. A short tap latches
recording until the same Option key is tapped again. Holding and releasing finishes immediately. A
normal key or mouse action while an Option key is held cancels capture, preserving standard
Option-key combinations. The overlay uses a non-activating `NSPanel`, so it does not replace the
dictation target or take keyboard focus.

The island adapts to the physical MacBook notch and starts at the top safe-area boundary. On an
external display without a camera notch it becomes a compact floating capsule. Recording and
processing use the same focus-free status surface.

The STT configuration retains the multilingual Parakeet TDT v3 model while allowing an int8 or
int4 encoder, automatic Core ML scheduling or CPU/GPU-only execution, German-script filtering or
open multilingual decoding, and an additional long-form arbitration pass. A Core Audio device UID
can pin recording to one input instead of following the system default. Output follows the same
model: use the current macOS speaker or route MiddleAI playback to a fixed Core Audio UID without
changing the global system output. Changing model settings
invalidates the in-memory ASR manager and reloads matching Core ML assets before the next recording.
Non-content diagnostics record only duration, sample count, peak level and input-device name so a
muted or misrouted microphone can be distinguished from an STT decoding failure.

`MiddleAICore` is shared by the `MiddleAI` SwiftUI app, `middleai` CLI and test runner. Input adapters know only the engine. Provider-specific routes, headers and response formats live in `OpenWebUIClient` and `HostedAIClient` behind `AssistantClientProtocol`.

## Conversation state

SQLite stores `conversations`, `messages_cache`, `settings` and a prepared `embeddings` table. OpenWebUI remains canonical when selected. OpenAI and OpenRouter do not persist MiddleAI chat IDs, so the required locally cached context is sent with each request. The local routing copy has a configurable retention period.

The heuristic router combines exponential recency, token-vector cosine similarity and follow-up markers. The embedding router provides a dependency-free local sparse-vector baseline. `LLMRouter` targets Ollama, llama.cpp, MLX or another loopback server exposing `/v1/models` and `/v1/chat/completions`, then validates the structured `RoutingDecision`. `HybridRouter` favors agreement and safely degrades to local deterministic routing.

## Open WebUI compatibility boundary

The adapter implements password sign-in (`/api/v1/auths/signin`), model discovery, chat snapshots, chat list and `/api/chat/completions` SSE. Incremental SSE events feed the notch and sentence pipeline immediately. If a server returns a background-task acknowledgement instead of an event stream, the adapter polls the persisted assistant message as a compatibility fallback. Cancellation closes the active request and stops polling. It stores the user/assistant message tree before triggering completion and updates the snapshot afterward so the UI keeps a complete conversation. API-version changes require modifications only in this adapter.

The chat flow follows the official Open WebUI backend-controlled API guidance: create a user message plus assistant placeholder, then invoke a streamed completion with chat and message IDs.

## Extensibility

Protocols define `ConversationRoutingStrategy`, `ConversationStoreProtocol`, `AuthProvider`, `CredentialStore`, `AssistantClientProtocol` and `TTSProvider`. Additional input adapters call `MiddleAIEngine.handle`; future providers do not need to change conversation logic. `LocalInputServer` serializes asynchronous command inputs before they reach the main-actor engine.

The app UI is split into state/composition, reusable settings components, diagnostics, menu and quick-input views, activation-key monitoring and text insertion. Managed TTS models use explicit manifests and installation receipts instead of treating cache size alone as proof of readiness.
