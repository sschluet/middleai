#!/bin/zsh
set -euo pipefail

PROJECT_DIR=${0:A:h}
"$PROJECT_DIR/scripts/build-app.sh"
"$PROJECT_DIR/dist/bin/middleai" configure

echo
echo "MiddleAI ist bereit."
echo "1. Öffne $PROJECT_DIR/dist/MiddleAI.app"
echo "2. Wähle in Einstellungen > Verbindung OpenWebUI, OpenAI oder OpenRouter."
echo "3. Hinterlege die Zugangsdaten und lade die Modellliste."
echo "4. Wähle unter Geräte das macOS-Standardmikrofon oder ein festes Gerät."
echo "5. Wähle unter Sprachausgabe eine lokale Stimme und lade sie bei Bedarf dort."
echo "6. Halte die linke Optionstaste für Diktat oder die rechte für eine KI-Anfrage."
