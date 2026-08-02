#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h}
"$PROJECT_DIR/scripts/build-app.sh"
"$PROJECT_DIR/dist/bin/middleai" configure
"$PROJECT_DIR/dist/bin/middleai" tts-prepare

echo
echo "MiddleAI is ready."
echo "1. Open $PROJECT_DIR/dist/MiddleAI.app"
echo "2. Open Settings and enter Open WebUI URL, username, password and model ID."
echo "3. Click Save & Test Connection."
echo "4. Hold left Option for dictation or right Option for a MiddleAI question."
