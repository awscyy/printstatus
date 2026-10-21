import Foundation
import Testing
@testable import PrinterCore

private let now = Date(timeIntervalSince1970: 2_000_000_000)

private func printer(_ state: String, connect: String? = nil, progress: String = "31.9", age: Double = 0,
                     preview: String = #""/app/teams/12/files/model-hash/preview""#) throws -> Printer {
    let json = """
    {"uuid":"example", "name":"orangey", "printer_type_name":"Original Prusa MK4S",
     "printer_state":"\(state)", "connect_state":"\(connect ?? state)", "last_online":\(now.timeIntervalSince1970 - age),
     "job_info":{"progress":\(progress),"display_name":"part.bgcode","time_remaining":5220,"preview_url":\(preview)}}
    """
    return try JSONDecoder().decode(Printer.self, from: Data(json.utf8))
}

@Test func activeJobUsesPercentNotFractionAndNeverRoundsUp() throws {
    let p = try printer("PRINTING")
    #expect(p.progress(at: now) == 31)
    #expect(p.colour(at: now) == .green)
    #expect(try printer("PAUSED").progress(at: now) == 31)
    #expect(try printer("PAUSED").colour(at: now) == .yellow)
    #expect(try printer("ATTENTION").progress(at: now) == 31)
}

@Test(arguments: ["IDLE", "READY", "FINISHED", "STOPPED", "ERROR", "OFFLINE", "NEW_STATE"])
func retainedJobIsNotShownAsCurrent(state: String) throws {
    #expect(try printer(state).progress(at: now) == nil)
    #expect(try printer(state).currentPreviewURL(at: now) == nil)
}

@Test func offlineAndStaleTelemetryOverridePrinting() throws {
    let offline = try printer("PRINTING", connect: "OFFLINE")
    #expect(offline.colour(at: now) == .red)
    #expect(offline.progress(at: now) == nil)
    #expect(offline.currentPreviewURL(at: now) == nil)
    #expect(try printer("PRINTING", age: 120).progress(at: now) == 31)
    let stale = try printer("PRINTING", age: 121)
    #expect(stale.colour(at: now) == .yellow)
    #expect(stale.progress(at: now) == nil)
    #expect(stale.currentPreviewURL(at: now) == nil)
    #expect(try printer("ERROR").colour(at: now) == .red)
    #expect(try printer("SOMETHING_NEW").colour(at: now) == .yellow)
}

@Test func progressBoundariesAndMissingProgress() throws {
    #expect(try printer("PRINTING", progress: "0").progress(at: now) == 0)
    #expect(try printer("PRINTING", progress: "99.9").progress(at: now) == 99)
    #expect(try printer("PRINTING", progress: "100").progress(at: now) == 100)
    #expect(try printer("PRINTING", progress: "105").progress(at: now) == 100)
    #expect(try printer("PRINTING", progress: "-1").progress(at: now) == 0)
    #expect(try printer("PRINTING", progress: "null").progress(at: now) == nil)
}

@Test func idlePayloadWithoutJobAndEmptyAccountDecode() throws {
    let json = """
    {"printers":[{"uuid":"idle", "name":"Printer", "printer_type_name":"MK4S",
    "printer_state":"IDLE", "connect_state":"IDLE"}], "pager":{"total":1}}
    """
    let list = try JSONDecoder().decode(PrinterList.self, from: Data(json.utf8))
    #expect(list.printers[0].progress(at: now) == nil)
    #expect(list.printers[0].colour(at: now) == .green)
    let empty = try JSONDecoder().decode(PrinterList.self, from: Data(#"{"printers":[],"pager":{"total":0}}"#.utf8))
    #expect(empty.printers.isEmpty)
}

@Test func previewUsesOnlyCurrentJobsAndTheAuthenticatedPrusaOrigin() throws {
    let expected = URL(string: "https://connect.prusa3d.com/app/teams/12/files/model-hash/preview")!
    for state in ["PRINTING", "PAUSED", "ATTENTION"] {
        #expect(try printer(state, age: 120).currentPreviewURL(at: now) == expected)
    }
    #expect(try printer("PRINTING", preview: #""https://connect.prusa3d.com/app/teams/12/files/model-hash/preview""#)
        .currentPreviewURL(at: now) == expected)
    for invalid in ["null", #""""#, #""https://example.com/preview""#, #""//example.com/preview""#,
                    #""http://connect.prusa3d.com/preview""#, #""file:///tmp/preview.png""#,
                    #""https://connect.prusa3d.com:8443/preview""#, #""https://user@connect.prusa3d.com/preview""#] {
        let p = try printer("PRINTING", preview: invalid)
        #expect(p.currentPreviewURL(at: now) == nil)
        #expect(p.progress(at: now) == 31)
    }
}
