# MD Viewer

Un visualizzatore Markdown per Mac, semplice e veloce: apri un file `.md` e lo leggi formattato.
Quando serve, premi **Modifica** per scriverlo con l'anteprima accanto, aggiornata mentre scrivi.

*A simple, fast Markdown viewer and editor for macOS (Italian interface). [English summary below.](#english)*

## Cosa fa

- Mostra i file Markdown formattati e li aggiorna da soli quando il file cambia.
- **Editor affiancato** (⌘E) con numeri di riga e anteprima dal vivo; ⌘S salva.
- **Indice dei titoli** nella barra laterale, per spostarsi nei documenti lunghi.
- **Ricerca** nel documento (⌘F).
- **Tre temi** di lettura (Standard, Libro, Compatto) e modalità scura automatica.
- Codice colorato, **formule matematiche** (`$…$`, `$$…$$`) e **diagrammi** Mermaid.
- **Esporta in PDF o HTML** (una pagina unica con immagini, formule e diagrammi incorporati) e stampa.
- **Anteprima nel Finder**: selezioni un file `.md` e premi la barra spaziatrice.
- Ricorda dove eri arrivato a leggere in ogni file.

Funziona su macOS 13 (Ventura) o successivo, su Mac con processore Apple (M1, M2…) e Intel.

## Installazione

### Metodo 1 — Terminale (il più semplice)

1. Apri l'app **Terminale** (la trovi in Applicazioni → Utility, oppure cercala con ⌘ Spazio).
2. Incolla questa riga e premi Invio:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/carellonicolo/Markdown-Viewer/main/install.sh | bash
   ```

3. Fatto: MD Viewer è nella cartella Applicazioni. Lo stesso comando serve anche per **aggiornarlo**.

Lo script scarica l'ultima versione da questa pagina, la copia in Applicazioni e attiva l'anteprima
nel Finder. Puoi leggerlo prima di eseguirlo: è il file [`install.sh`](install.sh).

### Metodo 2 — Scaricando il file

1. Vai alla pagina [**Releases**](https://github.com/carellonicolo/Markdown-Viewer/releases/latest) e scarica
   `MD-Viewer.dmg`.
2. Apri il file scaricato e trascina **MD Viewer** sulla cartella **Applicazioni**.
3. Apri MD Viewer da Applicazioni. **La prima volta** macOS mostra un avviso perché l'app non è
   firmata da Apple (vedi [domande frequenti](#domande-frequenti)):
   - premi **Fine**;
   - apri **Impostazioni di Sistema → Privacy e sicurezza**, scorri in basso e premi
     **Apri comunque** accanto a «MD Viewer»; conferma con la password del Mac.

   Su macOS 13 e 14 basta anche: clic destro sull'app → **Apri** → **Apri**.

## Primi passi

- **Aprire i file `.md` con un doppio clic**: nel Finder seleziona un file `.md`, premi ⌘I
  (Ottieni informazioni), in «Apri con» scegli **MD Viewer** e premi **Modifica tutto…**.
- **Anteprima con la barra spaziatrice**: se nel Finder non appare formattata, attivala in
  **Impostazioni di Sistema → Generali → Elementi login ed estensioni → Quick Look → MD Viewer**.
- **Modificare un file**: premi il pulsante **Modifica** (la matita) nella barra in alto.

### Scorciatoie da tastiera

| Tasti | Azione |
|---|---|
| ⌘O | Apri un file |
| ⌘E | Mostra/nascondi l'editor |
| ⌘S | Salva |
| ⌘F · ⌘G · ⇧⌘G | Cerca · successivo · precedente |
| ⌃⌘S | Mostra/nascondi l'indice |
| ⌘1 · ⌘2 · ⌘3 | Tema Standard · Libro · Compatto |
| ⌘+ · ⌘− · ⌘0 | Ingrandisci · riduci · dimensione reale |
| ⌘R | Ricarica dal disco |
| ⌥⌘P · ⇧⌘H · ⌘P | Esporta PDF · esporta HTML · stampa |
| ⇧⌘R | Mostra il file nel Finder |
| ⌥⌘E | Apri il file con un'altra app |

## Domande frequenti

**Perché macOS dice che non può verificare lo sviluppatore?**
Per evitare l'avviso un'app deve essere firmata con un account Apple Developer a pagamento
(99 €/anno). MD Viewer è gratuito e open source, quindi non lo è: l'avviso compare solo la prima
volta. Chi preferisce può [compilarlo da sé](#compilare-dai-sorgenti) partendo da questo codice.

**I miei file vengono inviati da qualche parte?**
No. Tutto avviene sul tuo Mac. L'unica eccezione sono le immagini da internet inserite in un
documento: puoi bloccarle da **Vista → Carica immagini da internet**.

**Come si disinstalla?**
Trascina **MD Viewer** dalla cartella Applicazioni al Cestino.

## Per chi sviluppa

### Compilare dai sorgenti

Servono solo gli strumenti da riga di comando di Xcode (`xcode-select --install`), non Xcode.

```sh
./build.sh                # compila in build/
./build.sh --install      # compila e installa in /Applications (chiude l'app se è aperta)
./build.sh --zip --dmg    # crea anche build/MD-Viewer.zip e build/MD-Viewer.dmg
```

### Struttura

| Percorso | Contenuto |
|---|---|
| `Sources/App/` | L'app (`main.swift`: finestre, menu, barra degli strumenti, ricerca, indice, editor) e il suo `Info.plist` |
| `Sources/Shared/Renderer.swift` | Conversione Markdown → HTML, condivisa con Quick Look |
| `Sources/QuickLook/` | Anteprima con la barra spaziatrice nel Finder |
| `Resources/setup.js` | Regole di conversione: titoli, formule, codice, diagrammi |
| `Resources/style.css` | Aspetto e temi |
| `Resources/*.min.js` | Librerie incluse (licenze in `Resources/Licenze.md`) |
| `Tools/make_icon.swift` | Genera l'icona dell'app |
| `install.sh` | Installazione da Terminale per gli utenti |

### Pubblicare una nuova versione

1. Aumenta la versione in `Sources/App/Info.plist` (`CFBundleShortVersionString`, es. 2.2, e
   `CFBundleVersion` di 1).
2. Aggiungi in cima a `CHANGELOG.md` una sezione `## 2.2 — data` con le novità.
3. Fai il commit e pubblicalo (Push).
4. Su GitHub apri la scheda **Actions**, scegli **Release** a sinistra e premi
   **Run workflow** → **Run workflow**.

In qualche minuto GitHub crea il tag `v2.2`, compila l'app e pubblica la release con
`MD-Viewer.dmg`, `MD-Viewer.zip` e le novità del CHANGELOG (vedi `.github/workflows/release.yml`).

## Licenza

MD Viewer è software libero, distribuito con licenza [GNU GPL versione 3](LICENSE)
© 2026 Prof. Nicolò Carello — [info@nicolocarello.it](mailto:info@nicolocarello.it).
Puoi usarlo, studiarlo, modificarlo e ridistribuirlo; le versioni modificate che distribuisci
devono restare libere con la stessa licenza.
Include marked, highlight.js, KaTeX e Mermaid, ciascuno con la propria licenza libera
(vedi [`Resources/Licenze.md`](Resources/Licenze.md)).

---

## English

MD Viewer is a minimal Markdown viewer for macOS 13+ (Apple Silicon and Intel) with an optional
side-by-side editor and live preview, table of contents, search, themes, syntax highlighting, math
(KaTeX), Mermaid diagrams, PDF and HTML export and a Finder Quick Look preview. The interface is in Italian.
Licensed under the GNU GPL v3.

Install from Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/carellonicolo/Markdown-Viewer/main/install.sh | bash
```

or download `MD-Viewer.dmg` from [Releases](https://github.com/carellonicolo/Markdown-Viewer/releases/latest).
The app is not notarized: on first launch, allow it in System Settings → Privacy & Security →
Open Anyway. Build from source with `./build.sh` (Xcode command line tools only).
