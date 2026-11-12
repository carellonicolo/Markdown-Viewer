// MD Viewer — un visualizzatore Markdown minimale per macOS.
import Cocoa
import WebKit
import UniformTypeIdentifiers

// Le stesse estensioni dichiarate in Info.plist: gli altri file li apre il Finder.
let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt"]

// MARK: - Preferenze

enum Theme: String, CaseIterable {
    case standard, libro, compatto

    var title: String {
        switch self {
        case .standard: "Standard"
        case .libro: "Libro"
        case .compatto: "Compatto"
        }
    }

    static var current: Theme {
        get { Theme(rawValue: UserDefaults.standard.string(forKey: "Theme") ?? "") ?? .standard }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "Theme")
            NotificationCenter.default.post(name: .themeDidChange, object: nil)
        }
    }
}

extension Notification.Name {
    static let themeDidChange = Notification.Name("MDViewerThemeDidChange")
    static let remoteImagesDidChange = Notification.Name("MDViewerRemoteImagesDidChange")
}

/// Immagini da internet: scaricarle permette a chi ha scritto il file di sapere quando lo apri.
enum RemoteImages {
    private static let key = "BlockRemoteImages"

    static var allowed: Bool {
        get { !UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(!newValue, forKey: key)
            NotificationCenter.default.post(name: .remoteImagesDidChange, object: nil)
        }
    }
}

/// Ricorda fin dove si era letto ogni file.
enum ScrollMemory {
    private static let key = "ScrollPositions"
    private static let maxEntries = 500

    static func position(for url: URL) -> Double? {
        UserDefaults.standard.dictionary(forKey: key)?[url.path] as? Double
    }

    static func save(_ y: Double, for url: URL) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        if y < 1 {
            all.removeValue(forKey: url.path)
        } else {
            all[url.path] = y
        }
        if all.count > maxEntries {
            for k in all.keys.prefix(all.count - maxEntries) where k != url.path { all.removeValue(forKey: k) }
        }
        UserDefaults.standard.set(all, forKey: key)
    }
}

// MARK: - Accesso ai file tramite schema mdview://
// mdview://local/<percorso>  → file locali (immagini relative al documento)
// mdview://bundle/<nome>     → risorse dell'app (script Mermaid)

final class LocalFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mdview"
    static let bundleBase = "mdview://bundle/"

    static func url(for fileURL: URL) -> URL {
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = "local"
        comps.path = fileURL.path
        return comps.url!
    }

    static func fileURL(from url: URL) -> URL? {
        switch url.host {
        case "local":
            return URL(fileURLWithPath: url.path)
        case "bundle":
            guard let res = Bundle.main.resourceURL?.standardizedFileURL else { return nil }
            let file = res.appendingPathComponent(url.path).standardizedFileURL
            return file.path.hasPrefix(res.path + "/") ? file : nil
        default:
            return nil
        }
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let fileURL = Self.fileURL(from: url),
              let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

// MARK: - Documento

@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    var markdown = ""
    /// Data di modifica del file al momento dell'ultima lettura o dell'ultimo salvataggio.
    private(set) var diskModificationDate: Date?

    override class var autosavesInPlace: Bool { false }

    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// I file dentro l'app (es. le licenze) non si modificano: si romperebbe la firma dell'app.
    var isReadOnly: Bool {
        guard let path = fileURL?.standardizedFileURL.path else { return true }
        return path.hasPrefix(Bundle.main.bundleURL.standardizedFileURL.path + "/")
    }

    override func read(from url: URL, ofType typeName: String) throws {
        diskModificationDate = Self.modificationDate(of: url)
        try super.read(from: url, ofType: typeName)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        markdown = decodeText(data)
    }

    // Si salva sempre in UTF-8, la codifica standard del Markdown.
    override func data(ofType typeName: String) throws -> Data {
        Data(markdown.utf8)
    }

    override func writeSafely(to url: URL, ofType typeName: String,
                              for saveOperation: NSDocument.SaveOperationType) throws {
        try super.writeSafely(to: url, ofType: typeName, for: saveOperation)
        // Il controllo dei cambiamenti sul disco non deve scambiare il nostro salvataggio per una modifica esterna.
        if saveOperation != .saveToOperation { diskModificationDate = Self.modificationDate(of: url) }
    }

    override func makeWindowControllers() {
        addWindowController(ViewerWindowController())
    }

    /// Rilegge il file dal disco; restituisce true se il contenuto è stato aggiornato.
    func reloadFromDisk() -> Bool {
        guard let url = fileURL, (try? read(from: url, ofType: fileType ?? "")) != nil else { return false }
        fileModificationDate = diskModificationDate
        return true
    }
}

// MARK: - Indice dei titoli (barra laterale)

final class TOCCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ heading: Heading, indent: Int) {
        label.stringValue = heading.text
        label.toolTip = heading.text
        leading.constant = 4 + CGFloat(indent) * 14
        label.font = indent == 0
            ? .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            : .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = indent >= 2 ? .secondaryLabelColor : .labelColor
    }
}

final class TOCViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "Nessun titolo nel documento")
    private var minLevel = 1
    var onSelect: ((Heading) -> Void)?

    var headings: [Heading] = [] {
        didSet {
            minLevel = headings.map(\.level).min() ?? 1
            emptyLabel.isHidden = !headings.isEmpty
            if isViewLoaded { tableView.reloadData() }
        }
    }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("heading"))
        // La colonna segue la larghezza della barra laterale (altrimenti i titoli restano troncati).
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.refusesFirstResponder = true // la ricerca resta sul documento
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = tableView
        scroll.autoresizingMask = [.width, .height]

        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = !headings.isEmpty
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: scroll.frame)
        container.addSubview(scroll)
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
        ])
        view = container
    }

    func numberOfRows(in tableView: NSTableView) -> Int { headings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("TOCCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? TOCCell ?? TOCCell(identifier: id)
        let heading = headings[row]
        cell.configure(heading, indent: heading.level - minLevel)
        return cell
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        onSelect?(headings[row])
    }
}

// MARK: - Numeri di riga dell'editor

final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    /// Posizione (in caratteri) dell'inizio di ogni riga; ricalcolata solo quando il testo cambia.
    private var lineStarts: [Int] = [0]
    private var lineStartsValid = false
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 36
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(textChanged),
                           name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage)
        center.addObserver(self, selector: #selector(redraw),
                           name: NSTextView.didChangeSelectionNotification, object: textView)
        center.addObserver(self, selector: #selector(redraw),
                           name: NSView.frameDidChangeNotification, object: textView)
        if let clip = textView.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: clip)
        }
    }

    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func textChanged() {
        lineStartsValid = false
        needsDisplay = true
    }

    @objc private func redraw() { needsDisplay = true }

    private func updateLineStarts() {
        guard !lineStartsValid, let text = textView?.string as NSString? else { return }
        var starts = [0]
        var i = 0
        while i < text.length {
            i = NSMaxRange(text.lineRange(for: NSRange(location: i, length: 0)))
            let last = text.character(at: i - 1)
            // Dopo un "a capo" finale c'è una riga vuota, che va numerata.
            if i < text.length || last == 0x0A || last == 0x0D { starts.append(i) }
        }
        lineStarts = starts
        lineStartsValid = true
        // Larghezza adatta al numero di cifre (99 → 2 cifre, 1000 → 4…).
        let digits = String(starts.count).count
        let width = ceil(("8" as NSString).size(withAttributes: [.font: font]).width * CGFloat(max(digits, 2))) + 16
        if ruleThickness != width { ruleThickness = width }
    }

    /// Indice della riga che contiene il carattere `location`.
    private func line(at location: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        updateLineStarts()
        let length = (textView.string as NSString).length
        let origin = textView.textContainerOrigin
        let visible = textView.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let chars = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let currentLine = line(at: textView.selectedRange().location)

        var index = line(at: chars.location)
        while index < lineStarts.count, lineStarts[index] <= NSMaxRange(chars) {
            let start = lineStarts[index]
            // Riga vuota in fondo al testo: non ha caratteri, ha un frammento "extra".
            let fragment = start < length
                ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
                : layout.extraLineFragmentRect
            if fragment.isEmpty && start >= length { break }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: index == currentLine ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            ]
            let label = String(index + 1) as NSString
            let size = label.size(withAttributes: attrs)
            let top = convert(NSPoint(x: 0, y: fragment.minY + origin.y), from: textView).y
            label.draw(at: NSPoint(x: ruleThickness - size.width - 8, y: top + (fragment.height - size.height) / 2),
                       withAttributes: attrs)
            index += 1
        }
    }
}

// MARK: - Barra di ricerca

final class FindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    var onSearch: ((_ text: String, _ backwards: Bool) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.placeholderString = "Cerca nel documento"
        field.sendsWholeSearchString = false
        field.delegate = self
        field.target = self
        field.action = #selector(searchChanged)

        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!,
                             target: self, action: action)
            b.bezelStyle = .accessoryBarAction
            b.toolTip = tip
            return b
        }
        let done = NSButton(title: "Fine", target: self, action: #selector(close))
        done.bezelStyle = .accessoryBarAction

        let stack = NSStackView(views: [field, countLabel,
                                        button("chevron.up", "Precedente (⇧⌘G)", #selector(previous)),
                                        button("chevron.down", "Successivo (⌘G)", #selector(next)), done])
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `current` è la posizione del risultato selezionato (0 se nessuno è selezionato).
    func setCount(current: Int = 0, total: Int?) {
        switch (current, total) {
        case (_, nil): countLabel.stringValue = ""
        case (_, 0?): countLabel.stringValue = "Nessun risultato"
        case (1..., let n?) where current <= n: countLabel.stringValue = "\(current) di \(n)"
        case (_, 1?): countLabel.stringValue = "1 risultato"
        case (_, let n?): countLabel.stringValue = "\(n) risultati"
        }
    }

    @objc private func searchChanged() { onSearch?(field.stringValue, false) }
    @objc func next() { onSearch?(field.stringValue, false) }
    @objc func previous() { onSearch?(field.stringValue, true) }
    @objc private func close() { onClose?() }

    // Invio = successivo, ⇧Invio = precedente, Esc = chiudi.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? previous() : next()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}

// MARK: - Intestazione dei pannelli

/// Intestazione di un pannello (Markdown, Anteprima, HTML): simbolo, nome, un'informazione utile
/// ed eventuali pulsanti. Stesso stile della barra di ricerca.
final class PaneHeader: NSView {
    private let detail = NSTextField(labelWithString: "")
    private let stack = NSStackView()

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize, weight: .medium)
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        name.textColor = .secondaryLabelColor
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.setViews([icon, name, detail], in: .leading)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: separator.topAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setDetail(_ text: String) { detail.stringValue = text }

    /// Pulsanti allineati a destra.
    func addButtons(_ buttons: [NSButton]) {
        for button in buttons {
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            stack.addView(button, in: .trailing)
        }
    }
}

/// Pulsante "Copia HTML" che per un momento diventa "Copiato ✓".
final class CopyButton: NSButton {
    private var restoreWork: DispatchWorkItem?

    convenience init(target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        imagePosition = .imageLeading
        toolTip = "Copia negli appunti il codice HTML del documento"
        setCopied(false)
    }

    func showCopied() {
        setCopied(true)
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setCopied(false) }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func setCopied(_ copied: Bool) {
        title = copied ? "Copiato" : "Copia HTML"
        image = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: nil)
    }
}

// MARK: - Finestra

final class ViewerWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate,
                                    NSWindowDelegate, NSMenuItemValidation, NSTextViewDelegate {
    /// I pannelli affiancati, sempre in quest'ordine: testo Markdown, anteprima, codice HTML.
    struct Panes: OptionSet {
        let rawValue: Int
        static let markdown = Panes(rawValue: 1 << 0)
        static let preview = Panes(rawValue: 1 << 1)
        static let html = Panes(rawValue: 1 << 2)
        static let all: [Panes] = [.markdown, .preview, .html]
        var count: Int { Self.all.filter { contains($0) }.count }
    }

    private let webView: WKWebView
    private let findBar = FindBar()
    private let toc = TOCViewController()
    private let tocItem: NSSplitViewItem
    private let split = NSSplitViewController()
    private var panes: Panes = .preview // si apre sempre in lettura
    private weak var panesItem: NSToolbarItemGroup?
    /// Cornice della finestra prima che venisse allargata per più pannelli, e quella allargata.
    private var frameBeforeWidening: (original: NSRect, widened: NSRect)?

    // Pannello Markdown: il testo, da modificare (o solo da leggere, per i file di sola lettura).
    private let editor: NSTextView
    private let markdownItem: NSSplitViewItem
    private let markdownHeader = PaneHeader(symbol: "square.and.pencil", title: "Markdown")
    private var editorRenderWork: DispatchWorkItem?
    /// Durante uno scorrimento dell'editor fatto dall'app (indice) gli altri pannelli non lo seguono.
    private var suppressScrollSync = false

    // Pannello Anteprima.
    private let previewItem: NSSplitViewItem
    private let previewColumn: NSStackView
    private let previewHeader = PaneHeader(symbol: "doc.richtext", title: "Anteprima")
    private var watchTimer: Timer?
    private var pendingScrollY: Double?
    private var lastScrollY: Double = 0
    private var allowsScripts = false

    // Pannello HTML: il codice generato, in una seconda WebView (creata solo la prima volta che serve).
    private let htmlItem: NSSplitViewItem
    private let htmlColumn: NSStackView
    private let htmlHeader = PaneHeader(symbol: "chevron.left.forwardslash.chevron.right", title: "HTML")
    private let copyButton = CopyButton(target: nil, action: #selector(ViewerWindowController.copyHTML(_:)))
    private var sourceView: WKWebView?
    private var sourceLoaded = false
    private var sourceGeneration = 0
    /// L'HTML prodotto dall'ultima conversione (quello che "Copia HTML" mette negli appunti).
    private var htmlFragment = ""

    /// La pagina attualmente caricata nell'anteprima.
    private struct LoadedPage {
        let path: String
        let math: Bool
        let mermaid: Bool
    }
    private var loadedPage: LoadedPage?
    // Il Markdown viene convertito in background, così i file grandi non bloccano la finestra.
    private static let renderQueue = DispatchQueue(label: "MDViewer.render", qos: .userInitiated)
    private var renderGeneration = 0

    private static let zoomKey = "PageZoom"
    private static let showTOCKey = "ShowTOC"

    private var markdownDocument: MarkdownDocument? { document as? MarkdownDocument }

    /// Colonna verticale di un pannello: intestazione in alto, contenuto sotto.
    private static func column(_ views: [NSView]) -> NSStackView {
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .width
        column.frame = NSRect(x: 0, y: 0, width: 600, height: 920)
        views.last?.setContentHuggingPriority(.defaultLow - 1, for: .vertical) // il contenuto occupa lo spazio
        return column
    }

    private static func paneItem(_ view: NSView) -> NSSplitViewItem {
        let controller = NSViewController()
        controller.view = view
        let item = NSSplitViewItem(viewController: controller)
        item.minimumThickness = 240
        return item
    }

    init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFileSchemeHandler(), forURLScheme: LocalFileSchemeHandler.scheme)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 860, height: 920), configuration: config)
        webView.allowsMagnification = true
        // Niente sfondo bianco durante il caricamento (evita il lampo in modalità scura).
        if webView.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        let zoom = UserDefaults.standard.double(forKey: Self.zoomKey)
        webView.pageZoom = zoom > 0 ? zoom : 1.0

        tocItem = NSSplitViewItem(sidebarWithViewController: toc)
        tocItem.minimumThickness = 160
        tocItem.maximumThickness = 420
        tocItem.canCollapse = true
        tocItem.isCollapsed = !UserDefaults.standard.bool(forKey: Self.showTOCKey)

        let editorScroll = NSTextView.scrollableTextView()
        editorScroll.frame = NSRect(x: 0, y: 0, width: 500, height: 920)
        editor = editorScroll.documentView as! NSTextView
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        editor.isIncrementalSearchingEnabled = true
        editor.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        editor.textContainerInset = NSSize(width: 10, height: 14)
        // Il Markdown va scritto così com'è: niente virgolette "intelligenti" o correzioni automatiche.
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editorScroll.verticalRulerView = LineNumberRuler(textView: editor)
        editorScroll.hasVerticalRuler = true
        editorScroll.rulersVisible = true
        markdownItem = Self.paneItem(Self.column([markdownHeader, editorScroll]))

        findBar.isHidden = true
        previewHeader.isHidden = true // da sola, l'anteprima non ha intestazione: solo il documento
        previewColumn = Self.column([previewHeader, findBar, webView])
        previewItem = Self.paneItem(previewColumn)

        htmlColumn = Self.column([htmlHeader])
        htmlItem = Self.paneItem(htmlColumn)

        split.addSplitViewItem(tocItem)
        split.addSplitViewItem(previewItem)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 920),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 360, height: 300)
        window.contentViewController = split
        window.initialFirstResponder = webView
        super.init(window: window)

        window.delegate = self
        // Nome nuovo a ogni cambio dei pulsanti predefiniti: una disposizione salvata li nasconderebbe.
        let toolbar = NSToolbar(identifier: "MDViewerToolbar4")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // Dimensione e posizione dopo la barra degli strumenti, che cambia l'altezza della finestra.
        window.setFrame(NSRect(origin: .zero, size: Self.initialWindowSize(withTOC: !tocItem.isCollapsed)),
                        display: false)
        Self.place(window)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        toc.onSelect = { [weak self] heading in self?.scroll(to: heading) }
        findBar.onSearch = { [weak self] text, backwards in self?.find(text, backwards: backwards) }
        findBar.onClose = { [weak self] in self?.hideFindBar() }
        copyButton.target = self
        let export = NSButton(title: "Esporta…", target: self, action: #selector(exportHTML(_:)))
        export.toolTip = "Salva come pagina HTML completa, con stile e immagini (⇧⌘H)"
        htmlHeader.addButtons([copyButton, export])
        editor.delegate = self
        editorScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(editorDidScroll),
                                               name: NSView.boundsDidChangeNotification, object: editorScroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(themeDidChange),
                                               name: .themeDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(remoteImagesDidChange),
                                               name: .remoteImagesDidChange, object: nil)
        startWatching()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non supportato") }

    // MARK: Dimensione e posizione della finestra

    private static let windowSizeKey = "WindowSize"
    private static var cascadePoint = NSPoint.zero

    /// L'ultima dimensione usata, o una predefinita; mai più grande dello schermo.
    private static func initialWindowSize(withTOC: Bool) -> NSSize {
        var size = NSSizeFromString(UserDefaults.standard.string(forKey: windowSizeKey) ?? "")
        if size.width < 360 || size.height < 300 {
            size = NSSize(width: withTOC ? 1080 : 860, height: 980)
        }
        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            size.width = min(size.width, visible.width)
            size.height = min(size.height, visible.height)
        }
        return size
    }

    /// La prima finestra al centro, le successive a cascata (non una sopra l'altra).
    private static func place(_ window: NSWindow) {
        let othersOpen = NSApp.windows.contains { $0 !== window && $0.isVisible && $0.windowController is ViewerWindowController }
        if !othersOpen { cascadePoint = .zero }
        window.center()
        cascadePoint = window.cascadeTopLeft(from: cascadePoint)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // Con più pannelli la finestra è più larga del solito: non diventa la nuova dimensione predefinita.
        guard let window, panes.count == 1 else { return }
        UserDefaults.standard.set(NSStringFromSize(window.frame.size), forKey: Self.windowSizeKey)
    }

    // Il documento viene collegato da addWindowController(_:), dopo l'init.
    override var document: AnyObject? {
        didSet {
            guard let doc = markdownDocument, let url = doc.fileURL else { return }
            editor.string = doc.markdown
            editor.isEditable = !doc.isReadOnly
            updateMarkdownHeader()
            render(restoring: ScrollMemory.position(for: url) ?? 0)
        }
    }

    /// Converte il documento e lo mostra.
    /// - `restoring`: posizione da ripristinare (apertura del file); se nil la posizione attuale resta com'è.
    /// - `reloadPage`: ricarica la pagina intera (serve quando cambiano le regole di sicurezza).
    private func render(restoring y: Double? = nil, reloadPage: Bool = false) {
        guard let doc = markdownDocument, let fileURL = doc.fileURL else { return }
        renderGeneration += 1
        let generation = renderGeneration
        let markdown = doc.markdown
        let theme = Theme.current.rawValue
        let allowRemoteImages = RemoteImages.allowed
        Self.renderQueue.async { [weak self] in
            let renderer = MarkdownRenderer.shared
            let rendered = renderer.render(markdown)
            let html = renderer.page(for: rendered, theme: theme, scriptsBaseURL: LocalFileSchemeHandler.bundleBase,
                                     allowRemoteImages: allowRemoteImages)
            DispatchQueue.main.async {
                // Scarta i risultati superati da una conversione più recente.
                guard let self, generation == self.renderGeneration else { return }
                self.show(rendered, html: html, fileURL: fileURL, restoring: y,
                          reloadPage: reloadPage, generation: generation)
            }
        }
    }

    private func show(_ rendered: RenderedMarkdown, html: String, fileURL: URL, restoring y: Double?,
                      reloadPage: Bool, generation: Int) {
        toc.headings = rendered.headings
        htmlFragment = rendered.html
        if panes.contains(.html) { updateSource() }
        if let y {
            load(html, rendered: rendered, fileURL: fileURL, scrollTo: y)
            return
        }
        // Aggiornamento sul posto: niente ricaricamento della pagina, la posizione resta dov'è.
        // Non si può se cambia file, se i diagrammi compaiono per la prima volta (servono i loro script)
        // o se compaiono formule per la prima volta (serve il loro stile).
        if !reloadPage, let page = loadedPage, page.path == fileURL.path, !webView.isLoading,
           page.mermaid || !rendered.mermaid, page.math || !rendered.math {
            webView.callAsyncJavaScript("document.querySelector('article.markdown-body').innerHTML = html",
                                        arguments: ["html": rendered.html], in: nil, in: .defaultClient) { [weak self] result in
                guard let self else { return }
                if case .failure = result {
                    self.load(html, rendered: rendered, fileURL: fileURL, scrollTo: self.lastScrollY)
                    return
                }
                if page.mermaid && rendered.mermaid { self.redrawDiagrams() }
                self.updateFindCount()
                self.updateWordCount()
                self.syncPanesToEditor()
            }
            return
        }
        webView.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
            guard let self, generation == self.renderGeneration else { return }
            self.load(html, rendered: rendered, fileURL: fileURL, scrollTo: result as? Double ?? self.lastScrollY)
        }
    }

    private func load(_ html: String, rendered: RenderedMarkdown, fileURL: URL, scrollTo y: Double) {
        // JavaScript attivo solo per disegnare i diagrammi Mermaid (e solo con gli script dell'app).
        allowsScripts = rendered.mermaid
        pendingScrollY = y
        loadedPage = LoadedPage(path: fileURL.path, math: rendered.math, mermaid: rendered.mermaid)
        webView.loadHTMLString(html, baseURL: LocalFileSchemeHandler.url(for: fileURL))
    }

    /// Ridisegna i diagrammi dopo un aggiornamento sul posto (gli script Mermaid sono già nella pagina).
    private func redrawDiagrams() {
        webView.callAsyncJavaScript("""
            try { window.mermaidReady = mermaid.run({querySelector: 'pre.mermaid', suppressErrors: true});
                  await window.mermaidReady; } catch (e) {}
            """, arguments: [:], in: nil, in: .page, completionHandler: nil)
    }

    @objc private func remoteImagesDidChange() { render(reloadPage: true) }

    // Il tema cambia solo la classe della pagina: nessun ricaricamento.
    @objc private func themeDidChange() {
        if let sourceView, !sourceView.isLoading {
            sourceView.callAsyncJavaScript("document.documentElement.className = cls",
                                           arguments: ["cls": "theme-\(Theme.current.rawValue)"],
                                           in: nil, in: .defaultClient, completionHandler: nil)
        } else {
            sourceLoaded = false // la pagina del codice verrà ricreata con il tema nuovo
            if panes.contains(.html) { updateSource() }
        }
        if webView.isLoading {
            render() // la pagina in arrivo potrebbe avere ancora il tema precedente
            return
        }
        webView.callAsyncJavaScript("document.documentElement.className = cls",
                                    arguments: ["cls": "theme-\(Theme.current.rawValue)"],
                                    in: nil, in: .defaultClient, completionHandler: nil)
    }

    /// Dall'indice: ogni pannello aperto va al titolo. Nell'anteprima il titolo, nel codice HTML la riga
    /// in cui inizia, nel testo Markdown la riga del titolo (con il cursore lì, pronto per scrivere).
    private func scroll(to heading: Heading) {
        let script = "document.getElementById(id)?.scrollIntoView({behavior: 'smooth'})"
        if panes.contains(.preview) {
            webView.callAsyncJavaScript(script, arguments: ["id": heading.id], in: nil, in: .defaultClient,
                                        completionHandler: nil)
        }
        if panes.contains(.html), let sourceView {
            sourceView.callAsyncJavaScript(script, arguments: ["id": "src-" + heading.id], in: nil,
                                           in: .defaultClient, completionHandler: nil)
        }
        if panes.contains(.markdown), let offset = heading.offset { scrollEditor(to: offset) }
    }

    private func scrollEditor(to offset: Int) {
        guard let layout = editor.layoutManager, offset < (editor.string as NSString).length else { return }
        layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: offset + 1))
        let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: offset), effectiveRange: nil)
        editor.setSelectedRange(NSRange(location: offset, length: 0))
        suppressScrollSync = true
        editor.scroll(NSPoint(x: 0, y: max(0, line.minY + editor.textContainerOrigin.y - 8)))
        suppressScrollSync = false
    }

    // MARK: Pannelli (Markdown · Anteprima · HTML)

    @objc func toggleMarkdownPane(_ sender: Any?) { setPanes(panes.symmetricDifference(.markdown)) }
    @objc func togglePreviewPane(_ sender: Any?) { setPanes(panes.symmetricDifference(.preview)) }
    @objc func toggleHTMLPane(_ sender: Any?) { setPanes(panes.symmetricDifference(.html)) }

    @objc func panesClicked(_ sender: NSToolbarItemGroup) {
        var chosen: Panes = []
        for (index, pane) in Panes.all.enumerated() where sender.isSelected(at: index) { chosen.insert(pane) }
        setPanes(chosen)
    }

    private func syncPanesItem() {
        guard let group = panesItem else { return }
        for (index, pane) in Panes.all.enumerated() { group.setSelected(panes.contains(pane), at: index) }
    }

    /// Mostra i pannelli scelti, nell'ordine fisso, divisi in parti uguali; almeno uno resta sempre aperto.
    private func setPanes(_ wanted: Panes) {
        guard let window, !wanted.isEmpty, wanted != panes else { return syncPanesItem() }
        let added = wanted.subtracting(panes)
        let responder = window.firstResponder as? NSView
        if added.contains(.markdown), let doc = markdownDocument, editor.string != doc.markdown {
            editor.string = doc.markdown
            doc.undoManager?.removeAllActions()
        }
        if added.contains(.html), sourceView == nil { sourceView = makeSourceView() }
        panes = wanted
        syncPanesItem()

        if wanted.count > 1 { widenWindow(forPanes: wanted.count) }
        let order: [(Panes, NSSplitViewItem)] = [(.markdown, markdownItem), (.preview, previewItem), (.html, htmlItem)]
        for (pane, item) in order where !wanted.contains(pane) && split.splitViewItems.contains(item) {
            split.removeSplitViewItem(item)
        }
        for (index, entry) in order.filter({ wanted.contains($0.0) }).enumerated()
        where !split.splitViewItems.contains(entry.1) {
            split.insertSplitViewItem(entry.1, at: 1 + index) // dopo l'indice dei titoli
        }
        if wanted.count == 1 { restoreWindowWidth() }
        previewHeader.isHidden = wanted == .preview
        distributePanes()

        if added.contains(.html) { updateSource() }
        if added.contains(.preview) || added.contains(.markdown) { updateWordCount() }
        relocateFindBar()
        // La tastiera va nel pannello appena aperto se è il Markdown (per scrivere subito),
        // altrimenti resta dov'era, se quel pannello c'è ancora.
        if added.contains(.markdown) {
            window.makeFirstResponder(editor)
        } else if responder == nil || responder?.window == nil {
            window.makeFirstResponder(wanted.contains(.preview) ? webView : wanted.contains(.markdown) ? editor : sourceView)
        }
        syncPanesToEditor()
    }

    /// Allarga la finestra perché ogni pannello abbia spazio, senza uscire dallo schermo.
    private func widenWindow(forPanes count: Int) {
        guard let window, !window.styleMask.contains(.fullScreen), let screen = window.screen?.visibleFrame else { return }
        let tocWidth = tocItem.isCollapsed ? 0 : tocItem.viewController.view.frame.width
        let wanted = min(screen.width, max(window.frame.width, CGFloat(count) * 600 + tocWidth))
        guard wanted > window.frame.width else { return }
        var frame = window.frame
        frame.size.width = wanted
        frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - wanted))
        frameBeforeWidening = (frameBeforeWidening?.original ?? window.frame, frame)
        window.setFrame(frame, display: true, animate: true)
    }

    /// Con un solo pannello la finestra torna com'era, se nel frattempo non è stata ridimensionata.
    private func restoreWindowWidth() {
        if let window, let frames = frameBeforeWidening, window.frame == frames.widened {
            window.setFrame(frames.original, display: true, animate: true)
        }
        frameBeforeWidening = nil
    }

    private func distributePanes() {
        let items = split.splitViewItems.filter { $0 !== tocItem }
        guard items.count > 1 else { return }
        let splitView = split.splitView
        splitView.layoutSubtreeIfNeeded()
        let start = items[0].viewController.view.frame.minX
        let gap = splitView.dividerThickness
        let width = (splitView.bounds.maxX - start - gap * CGFloat(items.count - 1)) / CGFloat(items.count)
        // Il divisore k separa l'elemento k dal k+1 (l'elemento 0 è l'indice dei titoli).
        for k in 1..<items.count {
            splitView.setPosition(start + CGFloat(k) * width + CGFloat(k - 1) * gap, ofDividerAt: k)
        }
    }

    private func makeSourceView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 900), configuration: config)
        if view.responds(to: NSSelectorFromString("setDrawsBackground:")) {
            view.setValue(false, forKey: "drawsBackground")
        }
        view.pageZoom = webView.pageZoom
        view.allowsMagnification = true
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setContentHuggingPriority(.defaultLow - 1, for: .vertical)
        htmlColumn.addArrangedSubview(view)
        sourceLoaded = false
        return view
    }

    /// Colora il codice HTML in background e lo mostra, aggiornando sul posto quando possibile
    /// (così mentre si scrive nell'editor la posizione nel codice non cambia).
    private func updateSource() {
        guard let view = sourceView else { return }
        sourceGeneration += 1
        let generation = sourceGeneration
        let fragment = htmlFragment
        let theme = Theme.current.rawValue
        let lines = fragment.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        htmlHeader.setDetail("\(lines) \(lines == 1 ? "riga" : "righe")")
        Self.renderQueue.async { [weak self] in
            let renderer = MarkdownRenderer.shared
            let code = "<pre class=\"html-source\"><code>\(renderer.highlightedSource(fragment))</code></pre>"
            DispatchQueue.main.async {
                guard let self, generation == self.sourceGeneration else { return }
                if self.sourceLoaded && !view.isLoading {
                    view.callAsyncJavaScript("document.querySelector('article.markdown-body').innerHTML = html",
                                             arguments: ["html": code], in: nil, in: .defaultClient) { [weak self] _ in
                        self?.updateFindCount()
                        self?.syncPanesToEditor()
                    }
                } else {
                    self.sourceLoaded = true
                    let page = renderer.page(for: RenderedMarkdown(html: code, headings: [], math: false, mermaid: false),
                                             theme: theme, allowRemoteImages: false)
                    view.loadHTMLString(page, baseURL: nil)
                }
            }
        }
    }

    @objc func copyHTML(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(htmlFragment, forType: .string)
        copyButton.showCopied()
    }

    private func updateMarkdownHeader() {
        let lines = editor.string.utf16.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        let readOnly = markdownDocument?.isReadOnly == true ? " · sola lettura" : ""
        markdownHeader.setDetail("\(lines) \(lines == 1 ? "riga" : "righe")\(readOnly)")
    }

    // Parole del testo (senza codice, formule e diagrammi) e tempo di lettura, nell'intestazione dell'anteprima.
    private static let wordCountScript = """
        const art = document.querySelector('article.markdown-body');
        if (!art) return 0;
        const copy = art.cloneNode(true);
        copy.querySelectorAll('pre, .katex, .math-block, svg').forEach(e => e.remove());
        return copy.textContent.split(/\\s+/).filter(w => /[\\p{L}\\p{N}]/u.test(w)).length;
        """

    private func updateWordCount() {
        guard !previewHeader.isHidden else { return }
        webView.callAsyncJavaScript(Self.wordCountScript, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            guard case .success(let value) = result, let words = value as? Int else { return }
            let number = NumberFormatter.localizedString(from: NSNumber(value: words), number: .decimal)
            let minutes = max(1, Int((Double(words) / 200).rounded(.up)))
            self?.previewHeader.setDetail("\(number) \(words == 1 ? "parola" : "parole") · \(minutes) min di lettura")
        }
    }

    // Ogni secondo: ricarica se il file è cambiato o è stato rinominato, e salva la posizione di lettura.
    private func startWatching() {
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let doc = self.markdownDocument, let url = doc.fileURL else { return }
            if let modified = MarkdownDocument.modificationDate(of: url), modified != doc.diskModificationDate {
                // Con modifiche non salvate il file non viene riletto (le cancellerebbe):
                // al salvataggio macOS avvisa che il file è stato cambiato da un'altra app.
                if !doc.isDocumentEdited { self.reloadFromDisk() }
            } else if let page = self.loadedPage, page.path != url.path {
                self.render() // file spostato o rinominato: aggiorna immagini e link relativi
            } else if self.pendingScrollY == nil, self.panes.contains(.preview) {
                self.webView.evaluateJavaScript("window.scrollY") { [weak self] result, _ in
                    // Salvata subito (non solo alla chiusura), così resta anche uscendo con ⌘Q.
                    guard let self, self.pendingScrollY == nil, let y = result as? Double,
                          abs(y - self.lastScrollY) >= 1 else { return }
                    self.lastScrollY = y
                    ScrollMemory.save(y, for: url)
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        watchTimer?.invalidate()
        watchTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Azioni di menu

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleTOC(_:)): item.state = tocItem.isCollapsed ? .off : .on
        case #selector(toggleMarkdownPane(_:)): item.state = panes.contains(.markdown) ? .on : .off
        case #selector(togglePreviewPane(_:)): item.state = panes.contains(.preview) ? .on : .off
        case #selector(toggleHTMLPane(_:)): item.state = panes.contains(.html) ? .on : .off
        default: break
        }
        return true
    }

    // Annulla/Ripeti dell'editor agiscono sul documento, che così sa se ci sono modifiche da salvare.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { markdownDocument?.undoManager }
    func undoManager(for view: NSTextView) -> UndoManager? { markdownDocument?.undoManager }

    @objc func reload(_ sender: Any?) {
        guard let doc = markdownDocument else { return }
        guard doc.isDocumentEdited else { return reloadFromDisk() }
        confirm("Ricaricare il file dal disco?", detail: "Le modifiche non salvate andranno perse.",
                buttons: ["Ricarica", "Annulla"]) { [weak self] choice in
            if choice == 0 { self?.reloadFromDisk() }
        }
    }

    private func reloadFromDisk() {
        guard let doc = markdownDocument, doc.reloadFromDisk() else { return }
        doc.updateChangeCount(.changeCleared)
        if editor.string != doc.markdown {
            let selection = editor.selectedRange()
            editor.string = doc.markdown
            let length = (doc.markdown as NSString).length
            editor.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            doc.undoManager?.removeAllActions() // le azioni da annullare si riferivano al testo precedente
            updateMarkdownHeader()
        }
        render()
    }

    // MARK: Editor

    // Anteprima e HTML aggiornati mentre si scrive: aspettano una breve pausa nella digitazione.
    func textDidChange(_ notification: Notification) {
        markdownDocument?.markdown = editor.string
        editorRenderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.render()
            self?.updateMarkdownHeader()
        }
        editorRenderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc private func editorDidScroll() { syncPanesToEditor() }

    /// Porta anteprima e codice HTML allo stesso punto (in proporzione) del testo Markdown.
    private func syncPanesToEditor() {
        guard panes.contains(.markdown), !suppressScrollSync, let scroll = editor.enclosingScrollView else { return }
        let range = editor.frame.height - scroll.contentView.bounds.height
        let fraction = range > 0 ? min(max(scroll.contentView.bounds.minY / range, 0), 1) : 0
        let script = "window.scrollTo(0, f * (document.documentElement.scrollHeight - window.innerHeight))"
        if panes.contains(.preview), pendingScrollY == nil {
            webView.callAsyncJavaScript(script, arguments: ["f": fraction], in: nil, in: .defaultClient,
                                        completionHandler: nil)
        }
        if panes.contains(.html), let sourceView {
            sourceView.callAsyncJavaScript(script, arguments: ["f": fraction], in: nil, in: .defaultClient,
                                           completionHandler: nil)
        }
    }

    @objc func toggleTOC(_ sender: Any?) {
        let collapse = !tocItem.isCollapsed
        tocItem.animator().isCollapsed = collapse
        UserDefaults.standard.set(!collapse, forKey: Self.showTOCKey)
    }

    // MARK: Ricerca

    /// La pagina in cui cerca la barra di ricerca: quella del pannello in cui si trova la barra.
    private var findTarget: WKWebView {
        findBar.superview === htmlColumn ? (sourceView ?? webView) : webView
    }

    /// Se si sta scrivendo nel testo Markdown, ⌘F e ⌘G cercano lì.
    private func editorFind(_ action: NSTextFinder.Action) -> Bool {
        guard panes.contains(.markdown), window?.firstResponder === editor else { return false }
        let item = NSMenuItem()
        item.tag = action.rawValue
        editor.performTextFinderAction(item)
        return true
    }

    @objc func showFindBar(_ sender: Any?) {
        if editorFind(.showFindInterface) { return }
        // Cerca nell'HTML se è lì che si sta lavorando (o se l'anteprima non c'è), altrimenti nell'anteprima.
        let responder = window?.firstResponder as? NSView
        let workingInHTML = sourceView.map { responder?.isDescendant(of: $0) == true } ?? false
        if panes.contains(.preview) && !(workingInHTML && panes.contains(.html)) {
            placeFindBar(in: previewColumn)
        } else if panes.contains(.html) {
            placeFindBar(in: htmlColumn)
        } else {
            window?.makeFirstResponder(editor) // c'è solo il testo Markdown
            _ = editorFind(.showFindInterface)
            return
        }
        findBar.isHidden = false
        window?.makeFirstResponder(findBar.field)
        findBar.field.selectText(nil)
        updateFindCount()
    }

    /// La barra di ricerca sta sotto l'intestazione del pannello in cui cerca.
    private func placeFindBar(in column: NSStackView) {
        guard findBar.superview !== column else { return }
        findBar.removeFromSuperview()
        column.insertArrangedSubview(findBar, at: 1)
        findBar.setCount(total: nil)
    }

    /// Se si chiude il pannello in cui si cercava, la ricerca passa all'altro (o si chiude).
    private func relocateFindBar() {
        guard !findBar.isHidden else { return }
        let inHTML = findBar.superview === htmlColumn
        if inHTML && !panes.contains(.html) || !inHTML && !panes.contains(.preview) {
            if panes.contains(.preview) {
                placeFindBar(in: previewColumn)
            } else if panes.contains(.html) {
                placeFindBar(in: htmlColumn)
            } else {
                return hideFindBar()
            }
            find(findBar.field.stringValue, backwards: false)
        }
    }

    private func hideFindBar() {
        let target = findTarget
        findBar.isHidden = true
        findBar.setCount(total: nil)
        if panes.contains(.preview) || panes.contains(.html) { window?.makeFirstResponder(target) }
    }

    @objc func toggleFindBar(_ sender: Any?) {
        findBar.isHidden ? showFindBar(nil) : hideFindBar()
    }

    @objc func findNext(_ sender: Any?) { findFromMenu(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { findFromMenu(backwards: true) }

    private func findFromMenu(backwards: Bool) {
        if editorFind(backwards ? .previousMatch : .nextMatch) { return }
        if findBar.isHidden || findBar.field.stringValue.isEmpty {
            showFindBar(nil)
        } else {
            find(findBar.field.stringValue, backwards: backwards)
        }
    }

    private func find(_ text: String, backwards: Bool) {
        guard !text.isEmpty else {
            findBar.setCount(total: nil)
            return
        }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.caseSensitive = false
        config.wraps = true
        findTarget.find(text, configuration: config) { [weak self] _ in self?.updateFindCount() }
    }

    // Conta le occorrenze (senza distinguere maiuscole/minuscole) e quante precedono
    // il risultato selezionato, per mostrare "3 di 7".
    private static let findCountScript = """
        const art = document.querySelector('article.markdown-body') || document.body;
        const q = query.toLowerCase();
        const count = t => { let n = 0, i = 0; while ((i = t.indexOf(q, i)) !== -1) { n++; i += q.length; } return n; };
        const total = count(art.textContent.toLowerCase());
        let current = 0;
        const sel = window.getSelection();
        if (sel.rangeCount && art.contains(sel.anchorNode)) {
            const r = document.createRange();
            r.setStart(art, 0);
            r.setEnd(sel.getRangeAt(0).startContainer, sel.getRangeAt(0).startOffset);
            current = count(r.toString().toLowerCase()) + 1;
        }
        return [current, total];
        """

    private func updateFindCount() {
        let text = findBar.field.stringValue
        guard !findBar.isHidden, !text.isEmpty else { return }
        findTarget.callAsyncJavaScript(Self.findCountScript, arguments: ["query": text],
                                       in: nil, in: .defaultClient) { [weak self] result in
            guard case .success(let value) = result, let numbers = value as? [Int], numbers.count == 2 else { return }
            self?.findBar.setCount(current: numbers[0], total: numbers[1])
        }
    }

    @objc func zoomIn(_ sender: Any?) { setZoom(webView.pageZoom * 1.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(webView.pageZoom / 1.1) }
    @objc func actualSize(_ sender: Any?) { setZoom(1.0) }

    private func setZoom(_ value: CGFloat) {
        let z = min(max(value, 0.5), 3.0)
        webView.pageZoom = z
        sourceView?.pageZoom = z
        UserDefaults.standard.set(Double(z), forKey: Self.zoomKey)
    }

    @objc func showInFinder(_ sender: Any?) {
        guard let url = markdownDocument?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func openInDefaultEditor(_ sender: Any?) {
        guard let url = markdownDocument?.fileURL else { return }
        // Apre con l'app predefinita per il file (se non è questa), altrimenti con TextEdit.
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let config = NSWorkspace.OpenConfiguration()
        if let handler = NSWorkspace.shared.urlForApplication(toOpen: url),
           handler.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL {
            NSWorkspace.shared.open([url], withApplicationAt: handler, configuration: config)
        } else {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: config)
        }
    }

    private func makePrintInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.topMargin = 40
        info.bottomMargin = 40
        info.leftMargin = 40
        info.rightMargin = 40
        return info
    }

    private func runPrint(_ info: NSPrintInfo, showPanel: Bool) {
        guard let window else { return }
        let op = webView.printOperation(with: info)
        op.showsPrintPanel = showPanel
        op.showsProgressPanel = true
        op.view?.frame = webView.bounds
        op.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// Stampa e PDF riproducono l'anteprima: se non è tra i pannelli aperti, la si apre.
    private func showPreviewForPrinting() {
        if !panes.contains(.preview) { setPanes(panes.union(.preview)) }
    }

    @objc func printContent(_ sender: Any?) {
        showPreviewForPrinting()
        runPrint(makePrintInfo(), showPanel: true)
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let window, let doc = markdownDocument else { return }
        showPreviewForPrinting()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = ((doc.fileURL?.lastPathComponent ?? doc.displayName) as NSString)
            .deletingPathExtension + ".pdf"
        if let dir = doc.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            DispatchQueue.main.async {
                let info = self.makePrintInfo()
                info.jobDisposition = .save
                info.dictionary().setObject(url, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString)
                self.runPrint(info, showPanel: false)
            }
        }
    }

    @objc func exportHTML(_ sender: Any?) {
        guard let window, let doc = markdownDocument, loadedPage != nil else { return NSSound.beep() }
        let name = ((doc.fileURL?.lastPathComponent ?? doc.displayName) as NSString).deletingPathExtension
        let title = toc.headings.first { $0.level == 1 }?.text ?? name
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = name + ".html"
        if let dir = doc.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.writeHTML(to: url, title: title)
        }
    }

    /// Salva il documento come pagina HTML autonoma: prende il contenuto così come è mostrato
    /// (diagrammi già disegnati, quindi senza script) e incorpora stile, formule e immagini locali.
    private func writeHTML(to url: URL, title: String) {
        guard let page = loadedPage, let baseDirectory = markdownDocument?.fileURL?.deletingLastPathComponent() else { return }
        let script = (page.mermaid ? "try { await window.mermaidReady; } catch (e) {}\n" : "")
            + "return document.querySelector('article.markdown-body').innerHTML;"
        let theme = Theme.current.rawValue
        webView.callAsyncJavaScript(script, arguments: [:], in: nil,
                                    in: page.mermaid ? .page : .defaultClient) { [weak self] result in
            guard case .success(let value) = result, let article = value as? String else {
                self?.confirm("Esportazione non riuscita", detail: "Riprova tra qualche istante.", buttons: ["OK"]) { _ in }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let rendered = RenderedMarkdown(html: embeddingLocalImages(in: article, baseDirectory: baseDirectory),
                                                headings: [], math: page.math, mermaid: false)
                let html = MarkdownRenderer.shared.page(for: rendered, theme: theme, title: title)
                do {
                    try Data(html.utf8).write(to: url, options: .atomic)
                } catch {
                    DispatchQueue.main.async { NSApp.presentError(error) }
                }
            }
        }
    }

    // MARK: Navigazione

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateFindCount()
        guard webView === self.webView else { // la pagina del codice HTML
            syncPanesToEditor()
            return
        }
        updateWordCount()
        guard let y = pendingScrollY else { return }
        // Con i diagrammi, aspetta che siano disegnati (cambiano l'altezza della pagina).
        let waitForDiagrams = loadedPage?.mermaid == true ? "try { await window.mermaidReady; } catch (e) {}\n" : ""
        webView.callAsyncJavaScript(waitForDiagrams + "window.scrollTo(0, y);", arguments: ["y": y],
                                    in: nil, in: .page) { [weak self] _ in
            guard let self, self.pendingScrollY == y else { return }
            self.lastScrollY = y
            self.pendingScrollY = nil
            self.syncPanesToEditor()
        }
    }

    // Se il caricamento fallisce, la memoria della posizione non deve restare bloccata.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if webView === self.webView { pendingScrollY = nil }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: any Error) {
        if webView === self.webView { pendingScrollY = nil }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // La pagina del codice HTML è solo testo: si carica e basta (un file trascinato si apre come al solito).
        if webView === sourceView {
            preferences.allowsContentJavaScript = false
            if let url = action.request.url, url.isFileURL {
                decisionHandler(.cancel, preferences)
                openLocal(url)
            } else {
                decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel, preferences)
            }
            return
        }
        preferences.allowsContentJavaScript = allowsScripts
        let allow = { decisionHandler(.allow, preferences) }
        let cancel = { decisionHandler(.cancel, preferences) }

        guard let url = action.request.url, action.targetFrame?.isMainFrame ?? true else { return cancel() }

        // File trascinato nella finestra.
        if url.isFileURL {
            cancel()
            openLocal(url)
            return
        }

        // Caricamento del documento o link interno (#sezione), anche se il file è stato appena rinominato.
        if url.scheme == LocalFileSchemeHandler.scheme, url.host == "local",
           [loadedPage?.path, markdownDocument?.fileURL?.path].contains(url.path) {
            return allow()
        }

        guard action.navigationType == .linkActivated else { return cancel() }
        cancel()
        openLink(url)
    }

    // Link con target="_blank".
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { openLink(url) }
        return nil
    }

    // MARK: Link

    private func openLink(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url) // nel browser / nella posta predefiniti
        case LocalFileSchemeHandler.scheme:
            if let target = LocalFileSchemeHandler.fileURL(from: url) { openLocal(target) }
        case "file":
            openLocal(url)
        default:
            // Altri schemi (vscode://, ssh://, …) possono far eseguire azioni ad altre app: chiedi prima.
            confirm("Aprire questo link con un'altra app?", detail: url.absoluteString,
                    buttons: ["Apri", "Annulla"]) { choice in
                if choice == 0 { NSWorkspace.shared.open(url) }
            }
        }
    }

    private func openLocal(_ url: URL) {
        if markdownExtensions.contains(url.pathExtension.lowercased()) {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
            return
        }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey])
        guard let values else {
            confirm("File non trovato", detail: url.path, buttons: ["OK"]) { _ in }
            return
        }
        // Cartelle, immagini, PDF, audio/video e testo semplice si aprono direttamente.
        let isFolder = values.isDirectory == true && values.isPackage != true
        let isSafeDocument = values.contentType.map { type in
            [UTType.image, .pdf, .audiovisualContent].contains { type.conforms(to: $0) }
                || (type.conforms(to: .plainText) && !type.conforms(to: .script))
        } ?? false
        if isFolder || isSafeDocument {
            NSWorkspace.shared.open(url)
            return
        }
        // App, script, eseguibili e tutto il resto: mai eseguiti con un semplice clic.
        confirm("«\(url.lastPathComponent)» potrebbe essere un'app o uno script.",
                detail: "Per sicurezza MD Viewer non apre direttamente questo tipo di file.",
                buttons: ["Mostra nel Finder", "Apri comunque", "Annulla"]) { choice in
            switch choice {
            case 0: NSWorkspace.shared.activateFileViewerSelecting([url])
            case 1: NSWorkspace.shared.open(url)
            default: break
            }
        }
    }

    /// Avviso nella finestra; `completion` riceve l'indice del pulsante scelto.
    private func confirm(_ message: String, detail: String, buttons: [String], completion: @escaping (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        buttons.forEach { alert.addButton(withTitle: $0) }
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            completion(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }
}

// MARK: - Barra degli strumenti

extension NSToolbarItem.Identifier {
    static let toc = Self("toc")
    static let panes = Self("panes")
    static let zoom = Self("zoom")
    static let theme = Self("theme")
    static let find = Self("find")
    static let export = Self("exportPDF") // nome storico: così le barre personalizzate lo ritrovano
    static let more = Self("more")
}

extension ViewerWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toc, .flexibleSpace, .panes, .zoom, .theme, .find, .export, .more]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func symbol(_ name: String, _ label: String) -> NSImage {
            NSImage(systemSymbolName: name, accessibilityDescription: label)!
        }
        func button(_ symbolName: String, _ label: String, _ tip: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = symbol(symbolName, label)
            item.label = label
            item.toolTip = tip
            item.target = self
            item.action = action
            item.isBordered = true
            return item
        }
        func menuItem(_ title: String, _ action: Selector, representing value: String? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.representedObject = value
            return item
        }

        switch id {
        case .toc:
            return button("sidebar.left", "Indice", "Mostra/nascondi l'indice dei titoli (⌃⌘S)",
                          #selector(toggleTOC(_:)))
        case .panes:
            // Un solo selettore per i tre pannelli: ognuno si accende e si spegne, anche tutti insieme.
            let group = NSToolbarItemGroup(
                itemIdentifier: id,
                images: [symbol("square.and.pencil", "Markdown"), symbol("doc.richtext", "Anteprima"),
                         symbol("chevron.left.forwardslash.chevron.right", "HTML")],
                selectionMode: .selectAny, labels: ["Markdown", "Anteprima", "HTML"],
                target: self, action: #selector(panesClicked(_:)))
            group.label = "Vista"
            group.toolTip = "Pannelli da affiancare: testo Markdown, anteprima, codice HTML"
            let tips = ["Markdown: il testo, da scrivere (⌥⌘1)", "Anteprima: il documento formattato (⌥⌘2)",
                        "HTML: il codice generato (⌥⌘3)"]
            for (subitem, tip) in zip(group.subitems, tips) { subitem.toolTip = tip }
            panesItem = group
            syncPanesItem()
            return group
        case .find:
            return button("magnifyingglass", "Cerca", "Cerca nel documento (⌘F)", #selector(toggleFindBar(_:)))
        case .export:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = symbol("arrow.down.doc", "Esporta")
            item.label = "Esporta"
            item.toolTip = "Esporta come PDF o come pagina HTML"
            let menu = NSMenu()
            menu.addItem(menuItem("PDF…", #selector(exportPDF(_:))))
            menu.addItem(menuItem("HTML…", #selector(exportHTML(_:))))
            menu.addItem(.separator())
            menu.addItem(menuItem("Copia codice HTML", #selector(copyHTML(_:))))
            item.menu = menu
            return item
        case .zoom:
            let group = NSToolbarItemGroup(
                itemIdentifier: id,
                images: [symbol("textformat.size.smaller", "Riduci"), symbol("textformat.size.larger", "Ingrandisci")],
                selectionMode: .momentary, labels: ["Riduci", "Ingrandisci"],
                target: self, action: #selector(zoomGroupClicked(_:)))
            group.label = "Dimensione testo"
            group.toolTip = "Riduci (⌘−) / ingrandisci (⌘+) il testo"
            return group
        case .theme:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = symbol("paintpalette", "Tema")
            item.label = "Tema"
            item.toolTip = "Tema di lettura"
            let menu = NSMenu()
            for theme in Theme.allCases {
                menu.addItem(menuItem(theme.title, #selector(AppDelegate.selectTheme(_:)), representing: theme.rawValue))
            }
            item.menu = menu
            return item
        case .more:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = symbol("ellipsis.circle", "Altro")
            item.label = "Altro"
            item.toolTip = "Altre azioni"
            let menu = NSMenu()
            menu.addItem(menuItem("Ricarica", #selector(reload(_:))))
            menu.addItem(menuItem("Apri con un'altra app", #selector(openInDefaultEditor(_:))))
            menu.addItem(menuItem("Mostra nel Finder", #selector(showInFinder(_:))))
            menu.addItem(.separator())
            menu.addItem(menuItem("Carica immagini da internet", #selector(AppDelegate.toggleRemoteImages(_:))))
            menu.addItem(.separator())
            menu.addItem(menuItem("Stampa…", #selector(printContent(_:))))
            item.menu = menu
            return item
        default:
            return nil
        }
    }

    @objc func zoomGroupClicked(_ sender: NSToolbarItemGroup) {
        sender.selectedIndex == 0 ? zoomOut(nil) : zoomIn(nil)
    }
}

// MARK: - Pannello "Apri"

/// Il pannello "Apri" standard è modale: finché è visibile blocca il resto dell'app
/// (il pannello Informazioni, per esempio, non risponde più). Questo lo apre non modale.
final class DocumentController: NSDocumentController {
    private var openPanel: NSOpenPanel?

    override func openDocument(_ sender: Any?) {
        if let openPanel {
            openPanel.makeKeyAndOrderFront(nil) // già aperto: niente secondo pannello
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        openPanel = panel
        beginOpenPanel(panel, forTypes: MarkdownDocument.readableTypes) { [weak self] response in
            self?.openPanel = nil
            guard response == NSApplication.ModalResponse.OK.rawValue else { return }
            for url in panel.urls {
                self?.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Se l'app è stata aperta senza file (dal Dock o da Applicazioni), mostra il pannello "Apri".
        // Se è stata aperta per un file (anche lento, es. da iCloud), macOS lo segnala e il pannello non serve.
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        guard isDefaultLaunch else { return }
        DispatchQueue.main.async {
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.openDocument(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return false
    }

    /// Se l'ultima finestra chiusa era un documento (non il pannello Informazioni o altri pannelli).
    private var lastClosedWindowWasDocument = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                               queue: .main) { [weak self] note in
            self?.lastClosedWindowWasDocument = (note.object as? NSWindow)?.windowController is ViewerWindowController
        }
    }

    // Esce chiudendo l'ultimo documento, ma non chiudendo il pannello Informazioni:
    // macOS non conta il pannello "Apri" come finestra e altrimenti l'app si chiuderebbe da sola.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        lastClosedWindowWasDocument && !NSApp.windows.contains { $0.isVisible }
    }

    @objc func selectTheme(_ sender: NSMenuItem) {
        guard let theme = sender.representedObject as? String, let t = Theme(rawValue: theme) else { return }
        Theme.current = t
    }

    @objc func toggleRemoteImages(_ sender: Any?) {
        RemoteImages.allowed.toggle()
    }

    @objc func showAbout(_ sender: Any?) {
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        func text(_ s: String, bold: Bool = false, color: NSColor = .labelColor) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [
                .font: bold ? NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize) : small,
                .foregroundColor: color, .paragraphStyle: center])
        }
        let email = "info@nicolocarello.it"
        let credits = NSMutableAttributedString()
        credits.append(text("""
            Un visualizzatore Markdown semplice e veloce: apri un file .md e lo leggi formattato. \
            Quando serve, affianca il testo Markdown da scrivere e il codice HTML generato, aggiornati mentre scrivi. \
            Si aggiorna da solo quando il file cambia e ricorda dove eri arrivato.

            """))
        credits.append(text("""
            Markdown, anteprima e HTML affiancati · indice dei titoli · ricerca · tre temi · modalità scura · evidenziazione del codice · \
            formule matematiche · diagrammi Mermaid · esportazione PDF · anteprima Quick Look nel Finder

            """, color: .secondaryLabelColor))
        credits.append(text("Sviluppato da Prof. Nicolò Carello\n", bold: true))
        credits.append(NSAttributedString(string: email, attributes: [
            .font: small, .link: URL(string: "mailto:\(email)")!, .paragraphStyle: center]))
        credits.append(text("\n\nLibrerie di terze parti: menu Aiuto → Licenze di terze parti",
                            color: .secondaryLabelColor))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func showLicenses(_ sender: Any?) {
        guard let url = Bundle.main.url(forResource: "Licenze", withExtension: "md") else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(selectTheme(_:)) {
            item.state = (item.representedObject as? String) == Theme.current.rawValue ? .on : .off
        } else if item.action == #selector(toggleRemoteImages(_:)) {
            item.state = RemoteImages.allowed ? .on : .off
        }
        return true
    }
}

// MARK: - Menu

func buildMainMenu() -> NSMenu {
    let appName = "MD Viewer"
    let main = NSMenu()

    func submenu(_ title: String, in parent: NSMenu? = nil) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        item.submenu = menu
        (parent ?? main).addItem(item)
        return menu
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
             _ mods: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.tag = tag
        return item
    }

    let app = submenu(appName)
    add(app, "Informazioni su \(appName)", #selector(AppDelegate.showAbout(_:)))
    app.addItem(.separator())
    add(app, "Nascondi \(appName)", #selector(NSApplication.hide(_:)), "h")
    add(app, "Nascondi altre", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
    add(app, "Mostra tutte", #selector(NSApplication.unhideAllApplications(_:)))
    app.addItem(.separator())
    add(app, "Esci da \(appName)", #selector(NSApplication.terminate(_:)), "q")

    let file = submenu("File")
    add(file, "Apri…", #selector(NSDocumentController.openDocument(_:)), "o")
    let recent = submenu("Apri recenti", in: file)
    add(recent, "Cancella menu", #selector(NSDocumentController.clearRecentDocuments(_:)))
    file.addItem(.separator())
    add(file, "Ricarica", #selector(ViewerWindowController.reload(_:)), "r")
    add(file, "Mostra nel Finder", #selector(ViewerWindowController.showInFinder(_:)), "r", [.command, .shift])
    add(file, "Apri con un'altra app", #selector(ViewerWindowController.openInDefaultEditor(_:)), "e", [.command, .option])
    file.addItem(.separator())
    add(file, "Chiudi", #selector(NSWindow.performClose(_:)), "w")
    add(file, "Salva", #selector(NSDocument.save(_:)), "s")
    add(file, "Esporta come PDF…", #selector(ViewerWindowController.exportPDF(_:)), "p", [.command, .option])
    add(file, "Esporta come HTML…", #selector(ViewerWindowController.exportHTML(_:)), "h", [.command, .shift])
    add(file, "Copia codice HTML", #selector(ViewerWindowController.copyHTML(_:)))
    add(file, "Stampa…", #selector(ViewerWindowController.printContent(_:)), "p")

    let edit = submenu("Modifica")
    add(edit, "Annulla", Selector(("undo:")), "z")
    add(edit, "Ripeti", Selector(("redo:")), "z", [.command, .shift])
    edit.addItem(.separator())
    add(edit, "Taglia", #selector(NSText.cut(_:)), "x")
    add(edit, "Copia", #selector(NSText.copy(_:)), "c")
    add(edit, "Incolla", #selector(NSText.paste(_:)), "v")
    add(edit, "Seleziona tutto", #selector(NSText.selectAll(_:)), "a")
    edit.addItem(.separator())
    let find = submenu("Trova", in: edit)
    add(find, "Trova…", #selector(ViewerWindowController.showFindBar(_:)), "f")
    add(find, "Trova successivo", #selector(ViewerWindowController.findNext(_:)), "g")
    add(find, "Trova precedente", #selector(ViewerWindowController.findPrevious(_:)), "g", [.command, .shift])

    let view = submenu("Vista")
    add(view, "Mostra indice", #selector(ViewerWindowController.toggleTOC(_:)), "s", [.command, .control])
    view.addItem(.separator())
    // I tre pannelli, come nel selettore "Vista" della barra in alto.
    add(view, "Markdown", #selector(ViewerWindowController.toggleMarkdownPane(_:)), "1", [.command, .option])
    add(view, "Anteprima", #selector(ViewerWindowController.togglePreviewPane(_:)), "2", [.command, .option])
    add(view, "HTML", #selector(ViewerWindowController.toggleHTMLPane(_:)), "3", [.command, .option])
    // Scorciatoie delle versioni precedenti: ⌘E (editor) e ⌥⌘U (codice HTML), nascoste ma attive.
    for (key, mods, action) in [("e", NSEvent.ModifierFlags.command, #selector(ViewerWindowController.toggleMarkdownPane(_:))),
                                ("u", [.command, .option], #selector(ViewerWindowController.toggleHTMLPane(_:)))] {
        let alias = add(view, "", action, key, mods)
        alias.isHidden = true
        alias.allowsKeyEquivalentWhenHidden = true
    }
    view.addItem(.separator())
    let themes = submenu("Tema", in: view)
    for (i, theme) in Theme.allCases.enumerated() {
        add(themes, theme.title, #selector(AppDelegate.selectTheme(_:)), "\(i + 1)").representedObject = theme.rawValue
    }
    add(view, "Carica immagini da internet", #selector(AppDelegate.toggleRemoteImages(_:)))
    view.addItem(.separator())
    add(view, "Ingrandisci", #selector(ViewerWindowController.zoomIn(_:)), "+")
    // ⌘= come alternativa a ⌘+ (tastiere americane): nascosta nel menu ma attiva.
    let zoomAlt = add(view, "Ingrandisci", #selector(ViewerWindowController.zoomIn(_:)), "=")
    zoomAlt.isHidden = true
    zoomAlt.allowsKeyEquivalentWhenHidden = true
    add(view, "Riduci", #selector(ViewerWindowController.zoomOut(_:)), "-")
    add(view, "Dimensione reale", #selector(ViewerWindowController.actualSize(_:)), "0")
    view.addItem(.separator())
    add(view, "Schermo intero", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

    let window = submenu("Finestra")
    add(window, "Riduci nel Dock", #selector(NSWindow.performMiniaturize(_:)), "m")
    add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
    window.addItem(.separator())
    add(window, "Porta tutto in primo piano", #selector(NSApplication.arrangeInFront(_:)))
    NSApp.windowsMenu = window

    let help = submenu("Aiuto")
    add(help, "Licenze di terze parti", #selector(AppDelegate.showLicenses(_:)))
    NSApp.helpMenu = help

    return main
}

// Il primo NSDocumentController creato diventa quello condiviso: deve essere il nostro.
_ = DocumentController()
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.mainMenu = buildMainMenu()
app.setActivationPolicy(.regular)
app.run()
