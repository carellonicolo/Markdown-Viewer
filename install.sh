#!/bin/bash
# Installa (o aggiorna) MD Viewer scaricando l'ultima versione pubblicata su GitHub.
# Da incollare nel Terminale:
#   curl -fsSL https://raw.githubusercontent.com/carellonicolo/Markdown-Viewer/main/install.sh | bash
set -euo pipefail

REPO="carellonicolo/Markdown-Viewer"
URL="https://github.com/$REPO/releases/latest/download/MD-Viewer.zip"
APP_NAME="MD Viewer.app"

if (( $(sw_vers -productVersion | cut -d. -f1) < 13 )); then
  echo "✗ MD Viewer richiede macOS 13 (Ventura) o successivo." >&2
  exit 1
fi

# Chi non è amministratore del Mac non può scrivere in /Applications: si usa la cartella Applicazioni personale.
if [[ -w /Applications ]]; then
  DEST_DIR="/Applications"
else
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/$APP_NAME"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "→ Scaricamento dell'ultima versione…"
curl -fL --progress-bar "$URL" -o "$TMP/MD-Viewer.zip"
ditto -x -k "$TMP/MD-Viewer.zip" "$TMP"
if [[ ! -d "$TMP/$APP_NAME" ]]; then
  echo "✗ L'archivio scaricato non contiene MD Viewer." >&2
  exit 1
fi

if pgrep -x MDViewer >/dev/null; then
  echo "→ Chiusura di MD Viewer…"
  osascript -e 'tell application id "com.nicolocarello.MDViewer" to quit' || true
  for _ in {1..20}; do pgrep -x MDViewer >/dev/null || break; sleep 0.25; done
fi

echo "→ Installazione in $DEST_DIR…"
pluginkit -r "$DEST/Contents/PlugIns/MDViewerQuickLook.appex" 2>/dev/null || true
rm -rf "$DEST"
ditto "$TMP/$APP_NAME" "$DEST"
# Scaricata da Terminale l'app non è "in quarantena", ma per sicurezza si toglie l'attributo:
# così macOS non mostra l'avviso "sviluppatore non identificato".
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/MDViewerQuickLook.appex" 2>/dev/null || true
qlmanage -r >/dev/null 2>&1 || true

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DEST/Contents/Info.plist" 2>/dev/null || echo "?")
echo "✓ MD Viewer $VERSION installato in $DEST"
echo "  Aprilo da Launchpad o da Applicazioni, oppure fai doppio clic su un file .md."
