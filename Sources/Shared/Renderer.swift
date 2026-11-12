// Motore di rendering condiviso tra l'app e l'estensione Quick Look.
import Foundation
import JavaScriptCore
import UniformTypeIdentifiers

struct Heading: Decodable {
    let level: Int
    let text: String
    let id: String
}

struct RenderedMarkdown: Decodable {
    let html: String
    let headings: [Heading]
    let math: Bool
    let mermaid: Bool
}

final class MarkdownRenderer {
    static let shared = MarkdownRenderer()

    private let context: JSContext
    private let css: String
    private let lock = NSLock()

    private init() {
        context = JSContext()!
        for name in ["marked.min", "highlight.min", "katex.min", "setup"] {
            context.evaluateScript(Self.resource(name, "js"))
        }
        css = Self.resource("style", "css")
    }

    private static func resource(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    // CSS di KaTeX con i font incorporati (così funziona anche in Quick Look).
    private lazy var katexCSS: String = {
        let css = Self.resource("katex.min", "css")
        let regex = try! NSRegularExpression(pattern: #"src:url\(fonts/([A-Za-z0-9_-]+)\.woff2\)[^;}]*"#)
        var result = css
        for match in regex.matches(in: css, range: NSRange(css.startIndex..., in: css)).reversed() {
            let name = String(css[Range(match.range(at: 1), in: css)!])
            guard let url = Bundle.main.url(forResource: name, withExtension: "woff2", subdirectory: "katex-fonts"),
                  let data = try? Data(contentsOf: url) else { continue }
            let replacement = "src:url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\")"
            result.replaceSubrange(Range(match.range, in: result)!, with: replacement)
        }
        return result
    }()

    func render(_ markdown: String) -> RenderedMarkdown {
        lock.lock()
        defer { lock.unlock() }
        let json = context.objectForKeyedSubscript("renderMarkdown")?
            .call(withArguments: [markdown])?.toString() ?? ""
        if let data = json.data(using: .utf8),
           let result = try? JSONDecoder().decode(RenderedMarkdown.self, from: data) {
            return result
        }
        return RenderedMarkdown(html: "<pre>\(markdown.htmlEscaped)</pre>", headings: [], math: false, mermaid: false)
    }

    /// Pagina HTML completa. `scriptsBaseURL` (es. "mdview://bundle/") abilita i diagrammi Mermaid;
    /// con `allowRemoteImages` falso le immagini da internet non vengono scaricate (privacy).
    func page(for rendered: RenderedMarkdown, theme: String, scriptsBaseURL: String? = nil,
              allowRemoteImages: Bool = true, title: String? = nil) -> String {
        var head = "<style>\(css)</style>"
        if rendered.math {
            lock.lock()
            head += "<style>\(katexCSS)</style>"
            lock.unlock()
        }
        var scripts = ""
        var scriptSrc = "'none'"
        if let base = scriptsBaseURL, rendered.mermaid {
            scripts = "<script src=\"\(base)mermaid.min.js\"></script><script src=\"\(base)mermaid-init.js\"></script>"
            scriptSrc = base
        }
        // Nessuno script proveniente dal file Markdown può essere eseguito, né cambiare
        // l'indirizzo di base dei link (<base>) o inviare moduli.
        let imgSrc = (allowRemoteImages ? "* " : "") + "data: cid: mdview:"
        let csp = "default-src 'none'; img-src \(imgSrc); style-src 'unsafe-inline'; font-src data:; "
            + "script-src \(scriptSrc); base-uri 'none'; form-action 'none'"
        return """
        <!DOCTYPE html>
        <html class="theme-\(theme)"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="color-scheme" content="light dark">
        \(title.map { "<title>\($0.htmlEscaped)</title>" } ?? "")
        \(head)</head>
        <body><article class="markdown-body">\(rendered.html)</article>\(scripts)</body></html>
        """
    }
}

/// Sostituisce le immagini locali (percorsi relativi a `baseDirectory` o file://) con il loro contenuto
/// incorporato (data:), così la pagina esportata funziona anche spostata o inviata ad altri.
/// Le immagini da internet restano collegamenti.
func embeddingLocalImages(in html: String, baseDirectory: URL, maxBytes: Int = 25_000_000) -> String {
    let regex = try! NSRegularExpression(pattern: #"(<img\b[^>]*?\ssrc=")([^"]+)(")"#, options: .caseInsensitive)
    var result = html
    for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
        let src = String(html[Range(match.range(at: 2), in: html)!]).replacingOccurrences(of: "&amp;", with: "&")
        let lower = src.lowercased()
        let fileURL: URL?
        if lower.hasPrefix("file:") {
            fileURL = URL(string: src)
        } else if lower.range(of: #"^[a-z][a-z0-9+.-]*:"#, options: .regularExpression) != nil || lower.hasPrefix("//") {
            continue // http:, https:, data: …
        } else {
            let path = (src.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? src)
            let decoded = path.removingPercentEncoding ?? path
            fileURL = decoded.hasPrefix("/") ? URL(fileURLWithPath: decoded)
                                             : baseDirectory.appendingPathComponent(decoded).standardizedFileURL
        }
        guard let fileURL,
              let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes,
              let data = try? Data(contentsOf: fileURL) else { continue }
        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        result.replaceSubrange(Range(match.range(at: 2), in: result)!,
                               with: "data:\(mime);base64,\(data.base64EncodedString())")
    }
    return result
}

extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Decodifica il testo: UTF-16 (se ha il BOM, es. "Unicode" del Blocco note di Windows),
/// poi UTF-8, poi le codifiche occidentali di Windows e Mac.
func decodeText(_ data: Data) -> String {
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
       let text = String(data: data, encoding: .utf16) {
        return text
    }
    return String(data: data, encoding: .utf8)
        ?? String(data: data, encoding: .windowsCP1252)
        ?? String(data: data, encoding: .isoLatin1)
        ?? String(decoding: data, as: UTF8.self)
}
