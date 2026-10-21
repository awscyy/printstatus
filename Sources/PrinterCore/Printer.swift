import Foundation

public enum StatusColour: Sendable { case green, yellow, red }

public struct PrinterList: Decodable, Sendable {
    public let printers: [Printer]
    public let pager: Pager
    public struct Pager: Decodable, Sendable { public let total: Int }
}

public struct Printer: Decodable, Identifiable, Sendable {
    public let uuid: String
    public let name: String
    public let printerTypeName: String
    public let printerState: String
    public let connectState: String
    public let lastOnline: Double?
    public let jobInfo: Job?
    public var id: String { uuid }

    enum CodingKeys: String, CodingKey {
        case uuid, name
        case printerTypeName = "printer_type_name"
        case printerState = "printer_state"
        case connectState = "connect_state"
        case lastOnline = "last_online"
        case jobInfo = "job_info"
    }

    public struct Job: Decodable, Sendable {
        public let progress: Double?
        public let displayName: String?
        public let timeRemaining: Double?
        public let previewURL: String?
        enum CodingKeys: String, CodingKey {
            case progress
            case displayName = "display_name"
            case timeRemaining = "time_remaining"
            case previewURL = "preview_url"
        }
    }

    public func status(at now: Date = .now) -> String {
        if connectState == "OFFLINE" || printerState == "OFFLINE" { return "OFFLINE" }
        if let lastOnline, now.timeIntervalSince1970 - lastOnline > 120 { return "STALE" }
        return printerState
    }

    public func colour(at now: Date = .now) -> StatusColour {
        switch status(at: now) {
        case "IDLE", "READY", "PRINTING", "FINISHED": .green
        case "BUSY", "PREPARING", "PAUSED", "ATTENTION", "UNKNOWN", "STALE": .yellow
        case "ERROR", "STOPPED", "OFFLINE": .red
        default: .yellow
        }
    }

    // Connect can retain the previous job after it finishes. Never show it as current.
    public func hasCurrentJob(at now: Date = .now) -> Bool {
        ["PRINTING", "PAUSED", "ATTENTION"].contains(status(at: now)) && jobInfo != nil
    }

    public func currentPreviewURL(at now: Date = .now) -> URL? {
        guard hasCurrentJob(at: now), let path = jobInfo?.previewURL, !path.isEmpty,
              let url = URL(string: path, relativeTo: URL(string: "https://connect.prusa3d.com/"))?.absoluteURL,
              url.scheme == "https", url.host == "connect.prusa3d.com",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return nil }
        return url
    }

    public func progress(at now: Date = .now) -> Int? {
        guard hasCurrentJob(at: now), let value = jobInfo?.progress, value.isFinite else { return nil }
        return Int(min(100, max(0, value)).rounded(.down))
    }
}
