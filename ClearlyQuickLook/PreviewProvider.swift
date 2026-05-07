import Cocoa
import ClearlyCore
import QuickLookUI
import WebKit

class PreviewViewController: NSViewController, QLPreviewingController {
    private var webView: WKWebView!
    private var previewTask: Task<Void, Never>?

    deinit {
        previewTask?.cancel()
    }

    override func loadView() {
        webView = WKWebView()
        webView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        self.view = container
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        previewTask?.cancel()
        webView.loadHTMLString("", baseURL: nil)
        handler(nil)

        previewTask = Task { [weak self] in
            do {
                let html = try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    let markdownText = try String(contentsOf: url, encoding: .utf8)
                    try Task.checkCancellation()
                    let htmlBody = MarkdownRenderer.renderHTML(markdownText)
                    return Self.previewHTML(for: htmlBody)
                }.value
                try Task.checkCancellation()

                await MainActor.run {
                    guard let self else { return }
                    self.previewTask = nil
                    self.webView.loadHTMLString(html, baseURL: MermaidSupport.resourceBaseURL)
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self else { return }
                    self.previewTask = nil
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.previewTask = nil
                    self.webView.loadHTMLString(Self.errorHTML(error), baseURL: nil)
                }
            }
        }
    }

    private static func previewHTML(for htmlBody: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(PreviewCSS.css())</style>
        <style>
        @media (max-width: 400px) {
            body { font-size: 14px; padding: 10px 20px 20px; }
        }
        </style>
        </head>
        <body>\(htmlBody)</body>
        \(MathSupport.scriptHTML(for: htmlBody))
        \(TableSupport.scriptHTML(for: htmlBody))
        \(MermaidSupport.scriptHTML)
        \(SyntaxHighlightSupport.scriptHTML(for: htmlBody))
        </html>
        """
    }

    private static func errorHTML(_ error: Error) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        :root { color-scheme: light dark; }
        body { margin: 0; padding: 24px; background: Canvas; color: CanvasText; font: 14px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
        h1 { font-size: 16px; margin: 0 0 8px; }
        p { margin: 0; opacity: 0.7; overflow-wrap: anywhere; }
        </style>
        </head>
        <body>
        <h1>Preview failed</h1>
        <p>\(escapeHTML(error.localizedDescription))</p>
        </body>
        </html>
        """
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
