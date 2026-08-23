# Architecture

## Runtime flow

```text
Right Option / CLI / synchronous HTTP / Quick Input
  -> CommandDetector
  -> ConversationManager
  -> HybridRouter (Heuristic + local vector + optional local LLM)
  -> AssistantRequestCoordinator (FIFO + explicit cancellation)
  -> optional explicit local knowledge + profile-memory context
  -> selected AssistantClient (MiddleAI Local / OpenWebUI / OpenAI / OpenRouter)
  -> bounded context window -> SSE token stream / background-task polling
  -> spoken-response summarizer -> TTSQueue
  -> selected local engine (Qwen3-TTS / Supertonic / Voxtral / Apple voice)
  -> validated local audio cache -> local playback with watchdog and immediate barge-in
```

Strict-offline construction permits only the local client or a loopback OpenWebUI. Local URL
sessions reject redirects to non-loopback hosts. Knowledge and personal-memory context are injected
only when the resolved answer scope is loopback, so a hosted provider cannot receive the local
context by configuration accident.

The native Voice path starts before the engine:

```text
left Option  -> AVAudioEngine -> bounded 16-kHz accumulator -> configurable Parakeet TDT v3 -> conservative local cleanup -> restore target app -> verified accessibility insertion or focus-safe paste
right Option -> AVAudioEngine -> Parakeet TDT v3 -> MiddleAIEngine -> answer provider -> local TTS
```

The global modifier-key monitor supports independently configurable single-press and double-tap
activation. Double-tap is the default and requires two presses within 450 ms; the second release
latches recording until one further press finishes it. During transcription, provider work or TTS,
one press cancels immediately without waiting for a second tap. A normal key or mouse action while
an activation key is held cancels capture, preserving standard modifier-key combinations. The
overlay uses a non-activating `NSPanel`, so it does not replace the
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

SQLite stores `conversations`, `messages_cache`, `settings` and a reserved `embeddings` table. A
new conversation remains an in-memory draft until its first complete user/assistant exchange, so
unused compose windows, cancellation and provider failures never create empty history rows. Legacy
empty rows and their routing metadata are removed when a manager starts. The
current dependency-free embedding router computes sparse vectors in memory; the table is available
for a future persistent vector implementation. OpenWebUI remains canonical when selected. OpenAI
and OpenRouter do not persist MiddleAI chat IDs, so the required locally cached context is sent with
each request. The hosted context builder preserves the system prompt and newest turns, summarizes
older history locally and enforces the configured token budget. User and assistant messages plus
conversation metadata are committed atomically. The local routing copy has a configurable retention
period.

A separate owner-only `local-context.sqlite` holds explicitly granted knowledge sources, indexed
chunks and explicit profile memories. `LocalKnowledgeBase` has no discovery API: the application
must pass a user-selected URL through `KnowledgePathPolicy`. Broad roots, hidden paths, symlinks,
credentials, databases and mail/browser stores are rejected. Retrieval is local and citations keep
the source path plus line range. `ProfileMemoryService` exposes explicit CRUD and expiry only; it
never observes conversations.

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

## Local workload coordination and actions

`InferenceScheduler` serializes memory-intensive STT, local generation, TTS, embeddings and
background indexing by priority. Interactive voice work is admitted before queued maintenance. The
local answer client, router and spoken summarizer share this scheduler and use bounded timeouts plus
circuit breakers. Ollama and llama.cpp remain out-of-process loopback services; redirect filtering
keeps their trust boundary local.

Selected-text transformations capture only `kAXSelectedTextAttribute`, reject secure fields and
produce a preview before `kAXSelectedTextAttribute` is set. The transformation model is loopback
only, treats the selection as untrusted data and validates conservative edits for similarity and
preserved numbers.

Voice actions use a closed `VoiceActionKind` enum. Unknown JSON fields are rejected, and platform
executors see only validated typed requests. Side effects use short-lived, request-bound, single-use
confirmation tokens. The macOS executor currently supports reminders through EventKit after a
visible confirmation; arbitrary URLs and shell commands are not representable.

The adaptive STT layer runs after Parakeet. It only applies user-approved lexicon entries and is a
complete no-op with an empty store. The local meeting coordinator has an explicit start/stop/cancel
lifecycle, bounded microphone capture, local transcription and deterministic Markdown/JSON export.
Its core audio-source protocol can represent system audio, but the shipping UI deliberately uses the
selected microphone and requests no Screen Recording permission.

## Local system-integrity monitor

`SystemIntegrityCollector` invokes only fixed absolute macOS tool paths and bounded arguments; it
never invokes a shell. It normalizes security states and stores hashes instead of full account,
certificate, DNS or proxy output. It inventories configuration profiles and security-relevant
payload classes, individual system certificates and trust settings, system extensions, login
items, crontab, SSH authorized keys, shell startup files, LaunchAgents, LaunchDaemons and privileged
helpers, including code-signing status where macOS exposes it. An installed Microsoft Defender is
queried locally through its fixed vendor executable and generates deterministic health signals.
A small `DispatchSource` watcher coalesces changes in relevant directories, while
`NSBackgroundActivityScheduler` performs the configurable periodic scan without a busy timer.

`SystemIntegrityRuleEngine` is deterministic and assigns severity before any model is called. A
temporarily unavailable source is excluded from comparison so a permission or command failure does
not appear as a removal. The user must first inspect source coverage and then explicitly establish
or replace the baseline; missing required sources block confirmation. Baseline and owner-only
bounded history use HMAC-SHA256 with a random `ThisDeviceOnly` secret stored in the macOS Keychain.
The history reconciler preserves New, Ongoing, Escalated, Reviewed and Resolved lifecycle states.

Optional explanation runs at background priority through `InferenceScheduler` and accepts only
Apple Intelligence or an OpenAI-compatible loopback Ollama/llama.cpp endpoint. There is no hosted
fallback. Log-derived content is delimited as untrusted data and cannot change rule severity or
execute an action. Notifications and spoken alerts use separate per-finding cooldowns and counters;
critical notices have their own reserve. Spoken alerts are generic, severity-gated, quiet-hour aware
and globally cooled down. Source locators are collector-created typed values and the UI opens only
allow-listed local paths, applications and System Settings URLs. A local timeline and Markdown
report expose coverage and lifecycle without uploading telemetry.

The shipping build intentionally does not use Endpoint Security or a system extension because those
capabilities require Apple-controlled entitlements, Developer ID signing and notarization. The
monitor therefore provides scheduled and event-triggered state integrity plus selected local log
signals, not complete real-time endpoint telemetry.
