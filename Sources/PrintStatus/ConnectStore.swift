import AppKit
import PrinterCore
import SwiftUI
import WebKit

@MainActor
final class ConnectStore: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var printers: [Printer] = []
    @Published var selectedID = UserDefaults.standard.string(forKey: "selectedPrinter") ?? "" {
        didSet { UserDefaults.standard.set(selectedID, forKey: "selectedPrinter") }
    }
    @Published var message: String? = "Connecting to Prusa Connect…"
    @Published var needsSignIn = false
    @Published var signingOut = false
    @Published var refreshing = false
    @Published var updatedAt: Date?
    @Published var now = Date()
    @Published var loadedPreview: (url: URL, image: NSImage)?
    let webView: WKWebView
    private var loginWindow: NSWindow?
    private var timer: Timer?
    private var generation = 0
    private var recoveringSession = false
    private var signedOut = false
    #if DEBUG
    var loginCredentials: [String: String]?
    var onVerified: (() -> Void)?
    #endif

    override init() {
        let configuration = WKWebViewConfiguration()
        // A dedicated persistent browser profile, managed by WebKit, never exported.
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier:
            UUID(uuidString: "7E720F07-747A-47F1-A2C3-AD4C8F8A2B5A")!)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 760), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    var selected: Printer? { printers.first { $0.id == selectedID } }
    var colour: StatusColour {
        if message != nil || needsSignIn || selected == nil { return .yellow }
        return selected!.colour(at: now)
    }
    var percent: Int? { message == nil ? selected?.progress(at: now) : nil }
    var currentPreview: NSImage? {
        guard message == nil, !needsSignIn, let url = selected?.currentPreviewURL(at: now),
              loadedPreview?.url == url else { return nil }
        return loadedPreview?.image
    }
    var statusText: String {
        if needsSignIn { return "Sign in required" }
        if message != nil { return "Status unavailable" }
        guard let selected else { return "No printer selected" }
        switch selected.status(at: now) {
        case "STALE": return "Telemetry delayed"
        case "ATTENTION": return "Needs attention"
        default: return selected.status(at: now).lowercased().capitalized
        }
    }

    func start() {
        loadSession()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.now = .now
                guard !self.signedOut else { return }
                if self.webView.url?.host == "connect.prusa3d.com" { await self.refresh() }
                else if !self.needsSignIn { self.loadSession() }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func woke() {
        now = .now
        guard !signedOut else { return }
        // Hide pre-sleep readings until the first fresh response.
        message = "Reconnecting after sleep…"
        loadSession()
    }

    private func loadSession() {
        webView.load(URLRequest(url: URL(string: "https://connect.prusa3d.com/login/prusa-auth")!))
    }

    func signIn() {
        guard !signingOut else { return }
        signedOut = false
        if loginWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Sign in to Prusa Connect"
            window.contentView = webView
            window.isReleasedWhenClosed = false
            window.center()
            loginWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        loginWindow?.makeKeyAndOrderFront(nil)
        loadSession()
    }

    func signOut() async {
        guard !signingOut else { return }
        signingOut = true
        defer { signingOut = false }
        signedOut = true
        generation += 1
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        loginWindow?.orderOut(nil)
        printers = []
        loadedPreview = nil
        updatedAt = nil
        selectedID = ""
        needsSignIn = true
        message = "Sign in to see your printer."
        await webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func refresh() async {
        guard !refreshing, !signedOut, webView.url?.host == "connect.prusa3d.com" else { return }
        refreshing = true
        let requestGeneration = generation
        defer { refreshing = false }
        do {
            // Same-origin, read-only requests. The official page owns OAuth/session refresh.
            let result = try await webView.callAsyncJavaScript("""
                const printers = [];
                let offset = 0;
                const token = localStorage.getItem('auth.access_token');
                do {
                    const controller = new AbortController();
                    const timeout = setTimeout(() => controller.abort(), 15000);
                    let response;
                    try {
                        response = await fetch('/app/printers?limit=100&offset=' + offset, {
                            credentials: 'include', cache: 'no-store', signal: controller.signal,
                            headers: token ? {Authorization: 'Bearer ' + token} : {}
                        });
                        // Read the body under the same timeout as the request.
                        var body = await response.text();
                    } finally { clearTimeout(timeout); }
                    if (response.status === 401 || response.status === 403) return 'AUTH';
                    if (!response.ok) return 'HTTP:' + response.status;
                    if (!(response.headers.get('content-type') || '').includes('application/json')) return 'AUTH';
                    const page = JSON.parse(body);
                    if (!Array.isArray(page.printers) || !Number.isInteger(page.pager?.total)) return 'FORMAT';
                    printers.push(...page.printers);
                    offset += page.printers.length;
                    if (offset >= page.pager.total) break;
                    if (!page.printers.length || offset > 10000) return 'FORMAT';
                } while (true);
                return JSON.stringify({printers, pager: {total: printers.length}});
                """, arguments: [:], in: nil, contentWorld: .defaultClient)
            guard requestGeneration == generation, !signedOut else { return }
            guard let json = result as? String else { throw ConnectError.format }
            if json == "AUTH" {
                message = "Your Prusa session has expired. Reconnecting…"
                if !recoveringSession {
                    recoveringSession = true
                    loadSession()
                } else {
                    needsSignIn = true
                    message = "Sign in again to reconnect to Prusa Connect."
                }
                return
            }
            if json.hasPrefix("HTTP:") { throw ConnectError.server(String(json.dropFirst(5))) }
            if json == "FORMAT" { throw ConnectError.format }
            let list = try JSONDecoder().decode(PrinterList.self, from: Data(json.utf8))
            printers = list.printers
            if selectedID.isEmpty { selectedID = printers.first?.id ?? "" }
            now = .now
            updatedAt = now
            needsSignIn = false
            recoveringSession = false
            message = printers.isEmpty ? "No printers in this Prusa Connect account."
                : selected == nil ? "Your selected printer is no longer available. Choose another printer." : nil
            loginWindow?.orderOut(nil)
            await refreshPreview()
            guard requestGeneration == generation, !signedOut else { return }
            #if DEBUG
            onVerified?()
            #endif
        } catch {
            guard requestGeneration == generation, !signedOut else { return }
            message = (error as? ConnectError)?.localizedDescription
                ?? "Couldn’t refresh Prusa Connect. Check your connection; retrying every 30 seconds."
        }
    }

    func refreshPreview() async {
        guard message == nil, !needsSignIn, let url = selected?.currentPreviewURL(at: now) else {
            loadedPreview = nil
            return
        }
        guard loadedPreview?.url != url else { return }
        loadedPreview = nil
        let requestGeneration = generation
        // Preview URLs require the same session as polling. Never export the bearer token.
        let result = try? await webView.callAsyncJavaScript("""
            const url = new URL(previewURL);
            if (url.origin !== 'https://connect.prusa3d.com') return null;
            const controller = new AbortController();
            const timeout = setTimeout(() => controller.abort(), 10000);
            try {
                const token = localStorage.getItem('auth.access_token');
                const response = await fetch(url.href, {
                    credentials: 'include', redirect: 'error', signal: controller.signal,
                    headers: token ? {Authorization: 'Bearer ' + token} : {}
                });
                if (!response.ok || !(response.headers.get('content-type') || '').startsWith('image/')) return null;
                const blob = await response.blob();
                if (blob.size > 5 * 1024 * 1024) return null;
                return await new Promise((resolve, reject) => {
                    const reader = new FileReader();
                    reader.onload = () => resolve(reader.result.split(',')[1]);
                    reader.onerror = reject;
                    reader.readAsDataURL(blob);
                });
            } finally { clearTimeout(timeout); }
            """, arguments: ["previewURL": url.absoluteString], in: nil, contentWorld: .defaultClient)
        // A changed printer/job or sign-out must not receive an old request's image.
        guard requestGeneration == generation, !signedOut, message == nil,
              selected?.currentPreviewURL(at: now) == url,
              let base64 = result as? String, let data = Data(base64Encoded: base64),
              let image = NSImage(data: data) else { return }
        loadedPreview = (url, image)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !signedOut else { return }
        if webView.url?.host == "account.prusa3d.com" {
            needsSignIn = true
            message = "Sign in securely with your Prusa account."
            #if DEBUG
            if let credentials = loginCredentials {
                Task {
                    let submittedPassword = try? await webView.callAsyncJavaScript("""
                        const emailField = document.querySelector('#id_email');
                        const passwordField = document.querySelector('#id_password');
                        if (!emailField) throw new Error('Login form changed');
                        emailField.value = email;
                        if (passwordField) passwordField.value = password;
                        emailField.form.requestSubmit();
                        return !!passwordField;
                        """, arguments: credentials, in: nil, contentWorld: .page)
                    if submittedPassword as? Bool == true { loginCredentials = nil }
                }
            }
            #endif
        } else if webView.url?.host == "connect.prusa3d.com" {
            Task { await refresh() }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled && !signedOut {
            message = "Couldn’t reach Prusa Connect. Check your connection and try again."
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        let allowed = url.scheme == "https" && ["connect.prusa3d.com", "account.prusa3d.com"].contains(url.host ?? "")
        return allowed || url.absoluteString == "about:blank" ? .allow : .cancel
    }
}

private enum ConnectError: LocalizedError {
    case format, server(String)
    var errorDescription: String? {
        switch self {
        case .format: "Prusa Connect returned an unexpected response. Its unofficial API may have changed."
        case .server(let code): "Prusa Connect returned HTTP \(code). Retrying every 30 seconds."
        }
    }
}
