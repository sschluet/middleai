# Third-party notices

MiddleAI itself is licensed under Apache License 2.0. The following components
and optional model downloads retain their own licenses.

## FluidAudio

MiddleAI uses FluidAudio for local Parakeet speech recognition and Core ML TTS
integration: <https://github.com/FluidInference/FluidAudio>.

FluidAudio is licensed under the Apache License 2.0. A copy of that license is
included in MiddleAI's `LICENSE` file.

## Parakeet TDT v3 Core ML

The local STT model is downloaded from
<https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml> and is
published under CC BY 4.0. Model files are not stored in this repository or
bundled in `MiddleAI.app`.

## Supertonic 3

The optional Supertonic 3 Core ML model is downloaded from
<https://huggingface.co/FluidInference/supertonic-3-coreml>. It is a conversion
of <https://huggingface.co/Supertone/supertonic-3> and remains subject to the
model's OpenRAIL terms. Model files are not stored in this repository or bundled
in `MiddleAI.app`.

## PocketTTS

The optional PocketTTS Core ML model is downloaded from
<https://huggingface.co/FluidInference/pocket-tts-coreml> and is published under
CC BY 4.0. Model files are not stored in this repository or bundled in
`MiddleAI.app`.

## DynamicNotchKit

MiddleAI adapts the notch shape and window geometry from DynamicNotchKit at
<https://github.com/altic-dev/DynamicNotchKit>. DynamicNotchKit is licensed
under the MIT License.

Copyright (c) 2025 Kai Azim

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Qwen3-TTS

The optional Qwen3-TTS VoiceDesign model is developed by the Qwen team:
<https://github.com/QwenLM/Qwen3-TTS>. The software and model repository are
distributed under the Apache License 2.0. Model weights are downloaded only
when the user selects this engine and remain in the local Hugging Face cache.

## Mistral Voxtral TTS

MiddleAI optionally supports Mistral Voxtral-4B-TTS-2603 through the MLX
Community 4-bit conversion. The model weights are distributed under CC BY-NC
4.0 and may only be used for non-commercial purposes. This optional model is
downloaded only after the user selects Voxtral in MiddleAI.

Source: <https://huggingface.co/mistralai/Voxtral-4B-TTS-2603>

## MLX Audio for Python

The optional Qwen3-TTS and Voxtral runtimes use MLX Audio, distributed under the MIT License.

Source: <https://github.com/Blaizzy/mlx-audio>
