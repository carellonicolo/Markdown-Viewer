#!/bin/zsh
# Compila MD Viewer.app (con l'anteprima Quick Look) come app universale (Apple Silicon + Intel).
#   ./build.sh            → solo compilazione, in build/
#   ./build.sh --install  → compila e installa in /Applications (chiude l'app se è aperta)
#   ./build.sh --zip      → crea anche build/MD-Viewer.zip (usato da install.sh)
#   ./build.sh --dmg      → crea anche build/MD-Viewer.dmg (da trascinare in Applicazioni)
# Le opzioni si possono combinare, es. ./build.sh --zip --dmg
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=false ZIP=false DMG=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --zip) ZIP=true ;;
    --dmg) DMG=true ;;
    *) echo "Opzione sconosciuta: $arg (valide: --install --zip --dmg)" >&2; exit 1 ;;
  esac
done

APP="build/MD Viewer.app"
APPEX="$APP/Contents/PlugIns/MDViewerQuickLook.appex"
ARCHS=(arm64 x86_64)
MIN_MACOS="13.0"
RENDER_RESOURCES=(Resources/marked.min.js Resources/highlight.min.js Resources/katex.min.js
                  Resources/katex.min.css Resources/setup.js Resources/style.css Resources/katex-fonts)
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/App/Info.plist)

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources" build/obj

# Compila per ogni architettura e unisce i risultati in un unico binario universale.
build_universal() {
  local output="$1"; shift
  local parts=()
  for arch in $ARCHS; do
    swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_MACOS" "$@" -o "build/obj/$(basename "$output")-$arch"
    parts+=("build/obj/$(basename "$output")-$arch")
  done
  lipo -create "${parts[@]}" -output "$output"
}

echo "→ Compilazione app $VERSION (${ARCHS[*]})…"
build_universal "$APP/Contents/MacOS/MDViewer" -module-name MDViewer \
  Sources/Shared/Renderer.swift Sources/App/main.swift

echo "→ Compilazione estensione Quick Look (${ARCHS[*]})…"
build_universal "$APPEX/Contents/MacOS/MDViewerQuickLook" -module-name MDViewerQuickLook \
  -parse-as-library -application-extension \
  Sources/Shared/Renderer.swift Sources/QuickLook/PreviewProvider.swift \
  -framework QuickLookUI -Xlinker -e -Xlinker _NSExtensionMain
rm -rf build/obj

echo "→ Icona…"
if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONTMP=$(mktemp -d)
  swift Tools/make_icon.swift "$ICONTMP/AppIcon.iconset"
  iconutil -c icns "$ICONTMP/AppIcon.iconset" -o Resources/AppIcon.icns
  rm -rf "$ICONTMP"
fi

echo "→ Risorse…"
cp Sources/App/Info.plist "$APP/Contents/Info.plist"
cp -R "${RENDER_RESOURCES[@]}" Resources/mermaid.min.js Resources/mermaid-init.js Resources/AppIcon.icns \
  Resources/Licenze.md "$APP/Contents/Resources/"
cp Sources/QuickLook/Info.plist "$APPEX/Contents/Info.plist"
# L'estensione ha sempre la stessa versione dell'app (si cambia solo in Sources/App/Info.plist).
for key in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set :$key $(/usr/libexec/PlistBuddy -c "Print :$key" Sources/App/Info.plist)" \
    "$APPEX/Contents/Info.plist"
done
cp -R "${RENDER_RESOURCES[@]}" "$APPEX/Contents/Resources/"

echo "→ Firma ad-hoc…"
codesign --force --sign - --entitlements Sources/QuickLook/QuickLook.entitlements "$APPEX"
codesign --force --sign - "$APP"

if $ZIP; then
  echo "→ Archivio zip…"
  ditto -c -k --keepParent "$APP" build/MD-Viewer.zip
fi

if $DMG; then
  echo "→ Immagine disco…"
  DMGTMP=$(mktemp -d)
  cp -R "$APP" "$DMGTMP/"
  ln -s /Applications "$DMGTMP/Applicazioni"
  cat > "$DMGTMP/Come installare.txt" <<'EOF'
1. Trascina «MD Viewer» sulla cartella «Applicazioni».
2. Apri MD Viewer da Applicazioni. La prima volta macOS avvisa che non può verificarne lo sviluppatore:
   premi «Fine» (o «OK»), poi apri Impostazioni di Sistema → Privacy e sicurezza,
   scorri in basso e premi «Apri comunque» accanto a MD Viewer.
   (Su macOS 13 e 14 basta anche: clic destro sull'app → Apri → Apri.)
Serve solo la prima volta.
EOF
  hdiutil create -quiet -volname "MD Viewer $VERSION" -srcfolder "$DMGTMP" -ov -format UDZO build/MD-Viewer.dmg
  rm -rf "$DMGTMP"
fi

if $INSTALL; then
  DEST="/Applications/MD Viewer.app"
  # Sostituire l'app mentre è aperta può farla bloccare: prima la si chiude.
  if pgrep -x MDViewer >/dev/null; then
    echo "→ Chiusura di MD Viewer…"
    osascript -e 'tell application id "com.nicolocarello.MDViewer" to quit' || true
    for _ in {1..20}; do pgrep -x MDViewer >/dev/null || break; sleep 0.25; done
    if pgrep -x MDViewer >/dev/null; then
      echo "✗ MD Viewer è ancora aperto: chiudilo e riprova." >&2
      exit 1
    fi
  fi
  echo "→ Installazione in /Applications…"
  pluginkit -r "$DEST/Contents/PlugIns/MDViewerQuickLook.appex" 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
  pluginkit -a "$DEST/Contents/PlugIns/MDViewerQuickLook.appex"
  qlmanage -r >/dev/null 2>&1 || true
fi

echo "✓ Fatto: $APP (versione $VERSION)"
if $ZIP; then echo "  build/MD-Viewer.zip"; fi
if $DMG; then echo "  build/MD-Viewer.dmg"; fi
