# Migration from FluidVoice

FluidVoice is no longer part of the MiddleAI runtime. MiddleAI now owns microphone capture, local
speech recognition, Option-key routing and the notch overlay.

## Native MiddleAI modes

- Hold left Option to dictate into the currently active text field. Release to transcribe and paste.
- Hold right Option to ask MiddleAI. Release to transcribe, send the request to OpenWebUI and receive
  the answer through the notch, the MiddleAI window and local TTS.

Both modes use Parakeet TDT v3 locally. The first launch downloads the Core ML model; later launches
use the cached files. MiddleAI does not save microphone recordings.

## Disable FluidVoice

Quit FluidVoice before using the two MiddleAI shortcuts so both apps do not react to Option keys.
Disable FluidVoice's launch-at-login setting if it would otherwise start again after login.

The old `middleai-ask` bridge and FluidVoice Command Mode are not installed by `setup.sh`. The
loopback `POST /command` endpoint remains only for optional local automation.
