import AppKit
import Combine
import SwiftUI

@main
struct PrintStatusApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        var launchDefaults = UserDefaults.standard
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-launch-open") ||
            ProcessInfo.processInfo.arguments.contains("--verify-launch-closed") {
            launchDefaults = UserDefaults(suiteName: "org.aidans.PrintStatus.LaunchVerification")!
        }
        #endif
        let delegate = AppDelegate(launchDefaults: launchDefaults)
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = ConnectStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var observation: AnyCancellable?
    private var initialPopoverObservation: AnyCancellable?
    private let launchDefaults: UserDefaults

    init(launchDefaults: UserDefaults) {
        self.launchDefaults = launchDefaults
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory apps show no menu bar, but AppKit still routes ⌘V, ⌘C and friends through
        // the main menu's key equivalents. Without these, the sign-in page can't paste or be filled.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(editItem)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: StatusView(store: store))
        observation = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
        updateStatus()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--snapshots") {
            Task { await SnapshotRunner.run(store: store); NSApp.terminate(nil) }
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--verify-login") {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            store.loginCredentials = try? JSONDecoder().decode([String: String].self, from: data)
            Task {
                try? await Task.sleep(for: .seconds(75))
                print("LIVE TIMEOUT: \(store.statusText) | \(store.message ?? "no error") | host=\(store.webView.url?.host ?? "none")")
                exit(1)
            }
            var reads = 0
            store.onVerified = { [weak self] in
                guard let self else { return }
                reads += 1
                print("LIVE VERIFIED: \(self.store.selected?.name ?? "none") | \(self.store.statusText) | \(self.store.percent.map { "\($0)%" } ?? "no job")")
                guard reads == 2 else { return }
                self.store.onVerified = nil
                Task {
                    self.updateStatus()
                    if let button = self.statusItem.button {
                        precondition(button.title == self.store.percent.map { " \($0)%" } ?? "")
                        await SnapshotRunner.capture(view: button, name: "live-menu")
                    }
                    await SnapshotRunner.capture(store: self.store, name: "live")
                    if ProcessInfo.processInfo.arguments.contains("--verify-preview") {
                        self.showPopover()
                        do { try await SnapshotRunner.verifyPreviews(store: self.store) }
                        catch { print("Preview verification failed: \(error)"); exit(1) }
                        if let view = self.popover.contentViewController?.view, let window = view.window {
                            try? await Task.sleep(for: .milliseconds(800))
                            await SnapshotRunner.capture(window: window, name: "live-popover")
                            precondition(window.isVisible && view.bounds.height >= view.fittingSize.height)
                        } else { preconditionFailure("Missing live popover") }
                    }
                    if ProcessInfo.processInfo.arguments.contains("--verify-failures") {
                        do { try await SnapshotRunner.verifyFailures(store: self.store) }
                        catch { print("Failure verification failed: \(error)"); exit(1) }
                    }
                    NSApp.terminate(nil)
                }
            }
        }
        #endif
        if !launchDefaults.bool(forKey: "hasShownInitialPopover") {
            // AppKit initially supplies a zero-height status-item window. Wait for placement.
            initialPopoverObservation = NotificationCenter.default.publisher(
                for: NSWindow.didMoveNotification, object: statusItem.button?.window
            ).sink { [weak self] _ in
                Task { @MainActor in self?.showPopover() }
            }
            DispatchQueue.main.async { [self] in
                showPopover()
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--verify-launch-open") ||
            ProcessInfo.processInfo.arguments.contains("--verify-launch-closed") {
            store.needsSignIn = true
            store.message = "Sign in securely with your Prusa account."
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                guard let window = statusItem.button?.window, window.frame.height > 0 else {
                    FileHandle.standardError.write(Data("Cannot verify launch: macOS has not exposed a usable menu bar.\n".utf8))
                    exit(2)
                }
                let expectedOpen = ProcessInfo.processInfo.arguments.contains("--verify-launch-open")
                precondition(popover.isShown == expectedOpen, "Incorrect launch popover state")
                precondition(launchDefaults.bool(forKey: "hasShownInitialPopover"))
                if expectedOpen, let window = popover.contentViewController?.view.window {
                    precondition(window.isVisible)
                    await SnapshotRunner.capture(window: window, name: "first-launch")
                    popover.performClose(nil)
                    try? await Task.sleep(for: .milliseconds(800))
                }
                precondition(!popover.isShown, "Popover must be closed before manual reopening")
                togglePopover()
                try? await Task.sleep(for: .milliseconds(500))
                precondition(popover.isShown, "Menu bar must remain usable")
                popover.performClose(nil)
                print("VERIFIED: launch popover \(expectedOpen ? "open" : "closed"), preference persisted, manual opening works")
                NSApp.terminate(nil)
            }
            return
        }
        #endif
        store.start()
    }

    func popoverDidShow(_ notification: Notification) {
        launchDefaults.set(true, forKey: "hasShownInitialPopover")
        initialPopoverObservation = nil
    }

    private func updateStatus() {
        guard let button = statusItem.button else { return }
        let colour = store.colour.nsColour
        let image = NSImage(size: NSSize(width: 14, height: 18), flipped: false) { _ in
            colour.setFill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 4, width: 10, height: 10)).fill()
            return true
        }
        image.isTemplate = false
        button.image = image
        button.imagePosition = .imageLeading
        button.title = store.percent.map { " \($0)%" } ?? ""
        button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        button.toolTip = "PrintStatus — \(store.selected?.name ?? "Prusa Connect"): \(store.statusText)"
        button.setAccessibilityLabel(button.toolTip)
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button, let window = button.window,
              !window.frame.isEmpty, !popover.isShown else { return }
        // A new hosting controller has a zero-sized frame until its first layout.
        if let view = popover.contentViewController?.view {
            popover.contentSize = view.fittingSize
        }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
