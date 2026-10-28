import Foundation
import Testing
import WebKit
@testable import PrintStatus

@Test @MainActor
func signInDetectsTokenCreatedAfterPageLoad() async throws {
    let store = ConnectStore(websiteDataStore: .nonPersistent())
    let selectedID = store.selectedID
    defer { store.selectedID = selectedID }
    store.needsSignIn = true
    store.webView.configuration.userContentController.addUserScript(WKUserScript(source: """
        window.fetch = async (url, options) => {
            if (options.headers.Authorization !== 'Bearer test-session') {
                return new Response('', {status: 401});
            }
            return new Response(JSON.stringify({
                printers: [{uuid: 'signed-in', name: 'Test printer', printer_type_name: 'MK4S',
                    printer_state: 'IDLE', connect_state: 'OK'}],
                pager: {total: 1}
            }), {headers: {'content-type': 'application/json'}});
        };
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
    // Simulate the official page finishing OAuth asynchronously, without another navigation.
    store.webView.loadHTMLString("""
        <body id="oauth-callback">
        <script>
        addEventListener('load', () => setTimeout(() => {
            localStorage.setItem('auth.access_token', 'test-session');
            history.replaceState(null, '', '/');
        }, 600));
        </script>
        </body>
        """, baseURL: URL(string: "https://connect.prusa3d.com/login/auth-callback")!)

    // No 30-second polling timer: the navigation itself must retrieve the printers.
    let deadline = Date().addingTimeInterval(5)
    while store.updatedAt == nil && Date() < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.updatedAt != nil)
    #expect(!store.needsSignIn)
    #expect(store.printers.map(\.id) == ["signed-in"])
    // A premature unauthenticated request must not navigate away and restart OAuth.
    let keptCallback = try await store.webView.callAsyncJavaScript(
        "return document.body.id === 'oauth-callback'", arguments: [:], in: nil, contentWorld: .page)
    #expect(keptCallback as? Bool == true)
    await store.signOut()
}
