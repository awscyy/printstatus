#if DEBUG
import AppKit
import PrinterCore
import SwiftUI

// Deterministic UI fixtures; excluded from the distributed release build.
@MainActor
enum SnapshotRunner {
    static func run(store: ConnectStore) async {
        let selectedID = store.selectedID
        defer { store.selectedID = selectedID }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--preview-fixture"), arguments.indices.contains(index + 1),
           let image = NSImage(contentsOfFile: arguments[index + 1]) {
            store.loadedPreview = (URL(string: "https://connect.prusa3d.com/app/fixture/preview")!, image)
        }
        for state in ["PRINTING", "PAUSED", "OFFLINE", "IDLE", "ERROR"] {
            let json = """
            {"uuid":"preview","name":"orangey","printer_type_name":"Original Prusa MK4S",
            "printer_state":"\(state)","connect_state":"\(state)",
            "job_info":{"progress":31,"display_name":"nthv4(2)_0.4n_0.1mm_PETG_MK4S_1h59m.bgcode","time_remaining":5220,
            "preview_url":"/app/fixture/preview"}}
            """
            store.printers = [try! JSONDecoder().decode(Printer.self, from: Data(json.utf8))]
            store.selectedID = "preview"
            store.message = nil
            store.updatedAt = .now
            await capture(store: store, name: state.lowercased())
            if state == "PRINTING" {
                let preview = store.loadedPreview
                store.loadedPreview = nil
                await capture(store: store, name: "preview-unavailable")
                store.loadedPreview = preview
                let second = """
                {"uuid":"second","name":"Workshop printer","printer_type_name":"Original Prusa XL",
                "printer_state":"IDLE","connect_state":"IDLE"}
                """
                store.printers.append(try! JSONDecoder().decode(Printer.self, from: Data(second.utf8)))
                await capture(store: store, name: "multiple-printers")
            }
        }
        store.message = "Couldn’t refresh Prusa Connect. Check your connection; retrying every 30 seconds."
        await capture(store: store, name: "network-error")
        store.printers = []
        store.updatedAt = nil
        store.needsSignIn = true
        store.message = "Sign in securely with your Prusa account."
        await capture(store: store, name: "sign-in")
    }

    static func verifyPreviews(store: ConnectStore) async throws {
        guard let image = store.currentPreview, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            preconditionFailure("Expected a decoded preview for the live current job")
        }
        try png.write(to: URL(fileURLWithPath: ".amp/in/artifacts/model-preview.png"))
        let percent = store.percent
        let selectedID = store.selectedID
        let web = store.webView
        _ = try await web.callAsyncJavaScript("window.savedPreviewFetch = window.fetch", arguments: [:], in: nil, contentWorld: .defaultClient)
        for response in [
            "new Response('', {status: 404})",
            "new Response('', {status: 401})",
            "new Response('invalid image', {headers: {'content-type':'image/png'}})",
        ] {
            store.loadedPreview = nil
            _ = try await web.callAsyncJavaScript("window.fetch = async () => \(response)", arguments: [:], in: nil, contentWorld: .defaultClient)
            await store.refreshPreview()
            precondition(store.currentPreview == nil && store.percent == percent && store.message == nil)
        }
        await capture(store: store, name: "preview-unavailable")
        _ = try await web.callAsyncJavaScript("""
            window.previewPending = false;
            window.fetch = async () => {
                window.previewPending = true;
                await new Promise(resolve => setTimeout(resolve, 500));
                return new Response(Uint8Array.from(atob(png), c => c.charCodeAt(0)), {headers: {'content-type':'image/png'}});
            };
            """, arguments: ["png": png.base64EncodedString()], in: nil, contentWorld: .defaultClient)
        let pending = Task { await store.refreshPreview() }
        var started = false
        for _ in 0..<50 {
            started = try await web.callAsyncJavaScript("return window.previewPending", arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool == true
            if started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(started)
        store.selectedID = "another-printer"
        await pending.value
        precondition(store.loadedPreview == nil, "An old printer's image must be discarded")
        store.selectedID = selectedID
        _ = try await web.callAsyncJavaScript("window.fetch = window.savedPreviewFetch; delete window.savedPreviewFetch; delete window.previewPending", arguments: [:], in: nil, contentWorld: .defaultClient)
        await store.refreshPreview()
        precondition(store.currentPreview != nil && store.percent == percent)
        store.message = "Temporary status failure"
        precondition(store.currentPreview == nil)
        store.message = nil
        print("VERIFIED: live preview decoded; missing/unauthorized/corrupt previews preserve progress; late printer response discarded; retry recovers; status failure hides image")
    }

    static func verifyFailures(store: ConnectStore) async throws {
        let web = store.webView
        _ = try await web.callAsyncJavaScript("window.savedFetch = window.fetch", arguments: [:], in: nil, contentWorld: .defaultClient)
        for response in [
            "new Response('', {status: 503})",
            "new Response('not json', {headers: {'content-type':'application/json'}})",
        ] {
            _ = try await web.callAsyncJavaScript("window.fetch = async () => \(response)", arguments: [:], in: nil, contentWorld: .defaultClient)
            await store.refresh()
            precondition(store.message != nil && store.percent == nil && store.colour == .yellow)
        }
        _ = try await web.callAsyncJavaScript("window.fetch = window.savedFetch; delete window.savedFetch", arguments: [:], in: nil, contentWorld: .defaultClient)
        await store.refresh()
        precondition(store.message == nil && store.selected != nil)
        print("VERIFIED: server failure and malformed response hide progress; live retry recovers")
        await store.signOut()
        await store.refresh()
        precondition(store.printers.isEmpty && store.needsSignIn && store.percent == nil)
        precondition(store.currentPreview == nil && store.loadedPreview == nil)
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        precondition(cookies.isEmpty)
        let records = await web.configuration.websiteDataStore.dataRecords(ofTypes: ["WKWebsiteDataTypeLocalStorage"])
        precondition(records.isEmpty)
        print("VERIFIED: sign out clears cookies, local storage and printer readings")
    }

    static func capture(window: NSWindow, name: String) async {
        try? await Task.sleep(for: .milliseconds(300))
        // WindowServer capture preserves SwiftUI's vibrant text, unlike cacheDisplay.
        guard CGPreflightScreenCaptureAccess() else {
            print("Screenshot unavailable: grant Screen Recording access to the runner")
            return
        }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), ".amp/in/artifacts/\(name).png"]
        do {
            try capture.run()
            capture.waitUntilExit()
            precondition(capture.terminationStatus == 0, "Window capture failed")
        } catch { preconditionFailure("Window capture failed: \(error)") }
    }

    static func capture(view: NSView, name: String) async {
        try? await Task.sleep(for: .milliseconds(300))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        view.bounds.fill()
        bitmap.draw(in: view.bounds)
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let output = NSBitmapImageRep(data: tiff) {
            try? output.representation(using: .png, properties: [:])?.write(to:
                URL(fileURLWithPath: ".amp/in/artifacts/\(name).png"))
        }
    }

    static func capture(store: ConnectStore, name: String) async {
        let view = NSHostingView(rootView: StatusView(store: store).background(Color(nsColor: .windowBackgroundColor)))
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = view
        window.orderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".amp/in/artifacts/\(name).png")
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
            print("Rendered \(name): \(Int(size.width)) × \(Int(size.height))")
        }
        window.orderOut(nil)
    }
}
#endif
