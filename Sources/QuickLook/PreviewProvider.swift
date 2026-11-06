// Anteprima Quick Look (barra spaziatrice nel Finder) per i file Markdown.
import Foundation
import QuickLookUI
import UniformTypeIdentifiers

@objc(PreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let markdown = decodeText(try Data(contentsOf: url))
        let renderer = MarkdownRenderer.shared
        let (html, attachments) = Self.embedLocalImages(
            in: renderer.page(for: renderer.render(markdown), theme: "standard"),
            relativeTo: url.deletingLastPathComponent())

        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 900, height: 1100)) { reply in
            reply.stringEncoding = .utf8
            reply.attachments = attachments
            return Data(html.utf8)
        }
    }

    /// Le immagini con percorso relativo vengono allegate all'anteprima (cid:).
    private static func embedLocalImages(in html: String, relativeTo dir: URL)
        -> (String, [String: QLPreviewReplyAttachment]) {
        let regex = try! NSRegularExpression(pattern: #"(<img\b[^>]*?\bsrc=")([^"]+)(")"#, options: [.caseInsensitive])
        var result = html
        var attachments: [String: QLPreviewReplyAttachment] = [:]
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed() {
            let src = String(html[Range(match.range(at: 2), in: html)!])
            guard !src.contains(":"), !src.hasPrefix("//") else { continue }
            let path = (src.removingPercentEncoding ?? src).replacingOccurrences(of: "&amp;", with: "&")
            let fileURL = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let type = UTType(filenameExtension: fileURL.pathExtension) ?? .image
            let cid = "img\(attachments.count)"
            attachments[cid] = QLPreviewReplyAttachment(data: data, contentType: type)
            result.replaceSubrange(Range(match.range(at: 2), in: result)!, with: "cid:\(cid)")
        }
        return (result, attachments)
    }
}
