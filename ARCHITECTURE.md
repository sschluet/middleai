# Architecture

## Runtime flow

```text
Right Option / CLI / synchronous HTTP / Quick Input
  -> CommandDetector
  -> ConversationManager
  -> HybridRouter (Heuristic + local vector + optional local LLM)
  -> AssistantRequestCoordinator (FIFO + explicit cancellation)
  -> selected AssistantClient (OpenWebUI / OpenAI / OpenRouter)
  -> bounded context window -> SSE token stream / background-task polling
  -> spoken-response summarizer -> TTSQueue
  -> selected local engine (Qwen3-TTS / Supertonic / Voxtral / Apple voice)
  -> validated local audio cache -> local playback with watchdog and immediate barge-in
```

The native Voice path starts before the engine:

```text
left Option  -> AVAudioEngine -> bounded 16-kHz accumulator -> configurable Parakeet TDT v3 -> conservative local cleanup -> restore target app -> verified accessibility insertion or focus-safe paste
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
Capture is incrementally downmixed and resampled instead of retaining a second full-size copy. A
configurable maximum duration bounds memory use; optional local energy-based silence detection can
finish a latched recording. Hardware-rate changes rebuild the converter, and device removal falls
back to the current macOS default without reusing a stale audio graph.
Non-content diagnostics record only duration, sample count, peak level and input-device name so a
muted or misrouted microphone can be distinguished from an STT decoding failure.

`MiddleAICore` is shared by the `MiddleAI` SwiftUI app, `middleai` CLI and test runner. Input adapters know only the engine. Provider-specific routes, headers and response formats live in `OpenWebUIClient` and `HostedAIClient` behind `AssistantClientProtocol`.

## Conversation state

SQLite stores `conversations`, `messages_cache`, `settings` and a reserved `embeddings` table. The
current dependency-free embedding router computes sparse vectors in memory; the table is available
for a future persistent vector implementation. OpenWebUI remains canonical when selected. OpenAI
and OpenRouter do not persist MiddleAI chat IDs, so the required locally cached context is sent with
each request. The hosted context builder preserves the system prompt and newest turns, summarizes
older history locally and enforces the configured token budget. User and assistant messages plus
conversation metadata are committed atomically. The local routing copy has a configurable retention
period.

Private mode substitutes an in-memory conversation store for SQLite. Enabling, disabling or
switching an effective profile creates a fresh conversation boundary so context cannot accidentally
cross persistence modes, providers, models or system prompts. Remote providers may still retain the
requests they receive according to their own policies.

The heuristic router combines exponential recency, token-vector cosine similarity and follow-up markers. The embedding router provides a dependency-free local sparse-vector baseline. `LLMRouter` targets Ollama, llama.cpp, MLX or another loopback server exposing `/v1/models` and `/v1/chat/completions`, then validates the structured `RoutingDecision`. `HybridRouter` favors agreement and safely degrades to local deterministic routing.

## Open WebUI compatibility boundary

The adapter implements password sign-in (`/api/v1/auths/signin`), model discovery, chat snapshots,
chat list and `/api/chat/completions` SSE. Its completion state machine distinguishes generated text,
tool/research preambles, finish reasons, `[DONE]`, server task IDs and persisted assistant-message
state. A tool preamble is therefore not exposed as the final answer. If a server returns a
background-task acknowledgement or closes before a terminal event, the adapter polls the persisted
assistant message with bounded backoff and deduplicates full-message rewrites. Cancellation closes
the active request and stops polling. The optional `/api/chat/completed` notification is best effort:
a valid answer is not discarded if that compatibility endpoint fails. It stores the user/assistant
message tree before triggering completion and updates the snapshot afterward so the UI keeps a
complete conversation. API-version changes require modifications only in this adapter.

The chat flow follows the official Open WebUI backend-controlled API guidance: create a user message plus assistant placeholder, then invoke a streamed completion with chat and message IDs.

## Extensibility

Protocols define `ConversationRoutingStrategy`, `ConversationStoreProtocol`, `AuthProvider`,
`CredentialStore`, `AssistantClientProtocol` and `TTSProvider`. Additional input adapters call
`MiddleAIEngine.handle`; future providers do not need to change conversation logic. All assistant
inputs share an `AssistantRequestCoordinator`: normal requests run FIFO, while explicit barge-in
cancels the active provider task, queued speech and UI lifecycle together. OpenAI and OpenRouter
retry only bounded transient `429` and `503` failures and honor a capped `Retry-After` value.

The app UI is split into state/composition, reusable settings components, diagnostics, menu and
quick-input views, activation-key monitoring and text insertion. Expensive support-report I/O and
coalesced TTS-model scans run outside the main actor. Managed TTS models use explicit manifests and
installation receipts instead of treating cache size alone as proof of readiness. Shared engine
initialization prevents duplicate multi-gigabyte model loads. Partially installed models are visible
and removable.

The TTS queue tracks both queued and currently rendering work. UI completion waits for actual audio
idle state rather than network completion. Renderer and player watchdogs turn missing callbacks into
bounded errors, and cancellation never enters a fallback voice. Synthesized WAV files use hashed
names, validation before reuse, owner-only permissions and configurable LRU eviction. Pronunciation
substitutions are applied locally before synthesis.
