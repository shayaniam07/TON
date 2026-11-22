import UIKit
import WebKit

final class GameViewController: UIViewController, WKUIDelegate, WKNavigationDelegate {
    private var webView: WKWebView!
    private var server: LocalServer?
    private let messageLabel = UILabel()

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: - Appearance

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        // Disable text selection / callouts so long-press does not pop up iOS menus.
        let css = "*{-webkit-touch-callout:none;-webkit-user-select:none;-webkit-tap-highlight-color:transparent;}"
        let js = "var s=document.createElement('style');s.innerHTML='\(css)';document.documentElement.appendChild(s);"
        cfg.userContentController.addUserScript(
            WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.allowsLinkPreview = false
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        view.addSubview(webView)

        // Stay inside the safe area so the notch / camera cutout never covers the game.
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            webView.topAnchor.constraint(equalTo: guide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        ])

        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.numberOfLines = 0
        messageLabel.textColor = .white
        messageLabel.textAlignment = .center
        messageLabel.font = .systemFont(ofSize: 16)
        messageLabel.isHidden = true
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        prepareDocuments()
        NotificationCenter.default.addObserver(self, selector: #selector(appBecameActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        tryLaunch()
    }

    @objc private func appBecameActive() {
        // The user may have just copied the game in with the Files app.
        tryLaunch()
    }

    // MARK: - Setup

    private func prepareDocuments() {
        let fm = FileManager.default
        try? fm.createDirectory(at: documentsURL.appendingPathComponent("www"), withIntermediateDirectories: true)
        let readme = documentsURL.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) {
            let text = """
            Copy the game's "www" folder (the one containing index.html, js, img, audio, data...) \
            into this folder, so that you end up with:

              Nadia/www/index.html

            Then reopen the app.
            """
            try? text.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    /// Accepts Nadia/www/index.html, Nadia/www/www/index.html or Nadia/index.html.
    private func findGameRoot() -> URL? {
        let fm = FileManager.default
        var queue: [(URL, Int)] = [(documentsURL, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            if fm.fileExists(atPath: dir.appendingPathComponent("index.html").path) { return dir }
            guard depth < 4,
                  let items = try? fm.contentsOfDirectory(at: dir,
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                queue.append((item, depth + 1))
            }
        }
        return nil
    }

    private func describeFolder(_ url: URL) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.isEmpty ? "(empty)" : names.sorted().prefix(15).joined(separator: ", ")
    }

    private func tryLaunch() {
        guard server == nil else { return }
        guard let root = findGameRoot() else {
            show("Game files not found.\n\nOpen the Files app > On My iPhone > Nadia, and copy the game's \"www\" folder in there (so you have Nadia/www/index.html). Then come back to this app.\n\nThe app currently sees: \(describeFolder(documentsURL))\nInside www: \(describeFolder(documentsURL.appendingPathComponent("www")))")
            return
        }
        let s = LocalServer(root: root)
        server = s
        s.start { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let port):
                self.messageLabel.isHidden = true
                let url = URL(string: "http://127.0.0.1:\(port)/index.html")!
                self.webView.load(URLRequest(url: url))
            case .failure(let error):
                self.server = nil
                self.show("Could not start the local server:\n\(error.localizedDescription)")
            }
        }
    }

    private func show(_ text: String) {
        messageLabel.text = text
        messageLabel.isHidden = false
    }

    // MARK: - WKUIDelegate (JS alerts, useful for MV error messages)

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    // If iOS kills the web content process (memory), reload the game.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}
