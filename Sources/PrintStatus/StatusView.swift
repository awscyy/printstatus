import AppKit
import PrinterCore
import SwiftUI

extension StatusColour {
    var colour: Color {
        switch self { case .green: .green; case .yellow: .yellow; case .red: .red }
    }
    var nsColour: NSColor {
        switch self { case .green: .systemGreen; case .yellow: .systemYellow; case .red: .systemRed }
    }
}

struct StatusView: View {
    @ObservedObject var store: ConnectStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("PrintStatus", systemImage: "printer.fill").font(.headline)
                Spacer()
                if store.refreshing { ProgressView().controlSize(.small) }
            }
            if store.printers.count > 1 || (store.selected == nil && !store.printers.isEmpty) {
                Picker("Printer", selection: $store.selectedID) {
                    ForEach(store.printers) { Text($0.name).tag($0.id) }
                }
                .onChange(of: store.selectedID) { Task { await store.refresh() } }
            }
            if let printer = store.selected {
                VStack(alignment: .leading, spacing: 4) {
                    Text(printer.name).font(.title2.weight(.semibold))
                    Text(printer.printerTypeName).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Circle().fill(store.colour.colour).frame(width: 9, height: 9)
                Text(store.statusText).font(.headline)
                Spacer()
            }
            if let message = store.message {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let printer = store.selected {
                if printer.hasCurrentJob(at: store.now) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let preview = store.currentPreview {
                            Image(nsImage: preview)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("Preview of \(printer.jobInfo?.displayName ?? "current print")")
                        }
                        if let percent = store.percent {
                            Text("\(percent)%").font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                            ProgressView(value: Double(percent), total: 100).tint(store.colour.colour)
                                .accessibilityLabel("Job completion")
                        } else {
                            Text("Progress not reported").foregroundStyle(.secondary)
                        }
                        if let name = printer.jobInfo?.displayName {
                            Text(name).font(.callout).lineLimit(2).truncationMode(.middle).help(name)
                        }
                        if let seconds = printer.jobInfo?.timeRemaining, seconds >= 0, seconds.isFinite {
                            let minutes = Int(min(seconds / 60, 525600))
                            Text("About \(minutes / 60)h \(minutes % 60)m remaining")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(printer.status(at: store.now) == "OFFLINE" ? "Printer is not connected to Prusa Connect."
                         : printer.status(at: store.now) == "STALE" ? "No recent telemetry from the printer."
                         : "No active print job.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let updated = store.updatedAt {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("Last checked \(updated, style: .relative) ago · Every 30s")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if store.needsSignIn {
                Button("Sign in to Prusa Connect…") { store.signIn() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.signingOut)
            } else {
                HStack {
                    Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .disabled(store.refreshing)
                    Spacer()
                    Button("Prusa Connect ↗") {
                        NSWorkspace.shared.open(URL(string: "https://connect.prusa3d.com/printers")!)
                    }
                }
            }
            Divider()
            HStack {
                if !store.needsSignIn {
                    Button("Sign out") { Task { await store.signOut() } }
                }
                Spacer()
                Button("Quit PrintStatus") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
    }
}
