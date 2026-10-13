// Port of photocraft-automation's control-server tests (crates/automation/src/rpc.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Skipped: `poisoned_session_keeps_serving` (a Rust lock-poisoning regression; Swift has no
// unwinding, so there is nothing to poison).

import Darwin
import Foundation
@testable import PCAutomation
import PCDocument
import PCEngine
import PCFoundation
import PCPlatform
import Testing

func decodePNG(_ base64: String?) throws -> DecodedImage {
    try ImageCodecs.decode(try #require(Data(base64Encoded: base64 ?? "")))
}

/// Serves `input` through `ControlServer.serveLines` and returns the reply lines.
func serveLines(_ h: Headless, _ input: Data) throws -> [JSONValue] {
    var out = Data()
    try ControlServer.serveLines(h, reader: LineReader(data: input, chunk: 8192)) { out.append($0) }
    return try String(decoding: out, as: UTF8.self).split(separator: "\n").map { try JSONValue.parse(String($0)) }
}

func waitUntil(_ seconds: Double = 60, _ done: () throws -> Bool) throws -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < seconds {
        if try done() { return true }
        usleep(5000)
    }
    return false
}

@Suite struct RPCTests {
    @Test func executeReportsInvalidFilterParametersWithoutChangingHistory() throws {
        let h = Headless.trustedLocal()
        #expect(h.respond(line: #"{"method":"doc.new","params":{"width":8,"height":8}}"#)["ok"] == true)
        let before = try h.inspect(nil)
        for (params, key) in [(["radius": "big"], "radius"), (["radus": 3], "radus"), (["radius": 5000], "radius"), (["radius": -4], "radius")] as [(JSONValue, String)] {
            for wait in [true, false] {
                let request: JSONValue = ["method": "engine.execute", "params": ["command": "filter.blur.gaussianBlur", "params": params, "wait": .bool(wait)]]
                let reply = h.respond(line: request.serialized())
                #expect(reply["ok"] == false)
                let error = reply["error"]?.stringValue ?? ""
                #expect(error.contains("filter.blur.gaussianBlur") && error.contains(key), "\(error)")
                #expect(try h.inspect(nil) == before)
            }
        }
    }

    @Test func linesRoundTripAndErrors() throws {
        let h = Headless.trustedLocal()
        let input = """
            {"id":1,"method":"doc.new","params":{"width":64,"height":32,"background":"white"}}

            {"id":2,"method":"engine.execute","params":{"command":"layer.new.layer","params":{"name":"Ink"}}}
            {"id":3,"method":"doc.inspect"}
            {"id":4,"method":"nope"}
            not json

            """
        let replies = try serveLines(h, Data(input.utf8))
        #expect(replies.count == 5)
        #expect(replies[0]["ok"] == true)
        #expect(replies[1]["id"] == 2)
        #expect(replies[2]["result"]?.serialized().contains("Ink") == true)
        #expect(replies[3]["ok"] == false)
        #expect(replies[3]["error"]?.stringValue?.contains("unknown method") == true)
        #expect(replies[4]["id"] == .null)
    }

    @Test func batchStopsOnErrorUnlessToldNotTo() throws {
        let h = Headless.trustedLocal()
        _ = try h.handle("doc.new", ["width": 16, "height": 16])
        let steps: JSONValue = [
            ["command": "layer.new.layer", "params": ["name": "A"]], ["command": "no.such.command"],
            ["command": "layer.new.layer", "params": ["name": "B"]], ["method": "doc.inspect"],
        ]
        let r = try h.handle("batch", ["steps": steps])
        #expect(r["completed"] == 1)
        #expect(r["failed"] == 1)
        #expect(r["results"]?.arrayValue?.count == 2)
        let r2 = try h.handle("batch", ["steps": steps, "stopOnError": false])
        #expect(r2["completed"] == 3)
        #expect(r2["results"]?[3]?["result"]?.serialized().contains("\"B\"") == true)
    }

    @Test func batchRejectsTooManySteps() throws {
        let h = Headless.trustedLocal()
        let steps = JSONValue.array(Array(repeating: ["command": "command.list"], count: ControlSecurity.maxBatchSteps + 1))
        do {
            _ = try h.handle("batch", ["steps": steps])
            Issue.record("accepted")
        } catch {
            #expect("\(error)".contains("maximum is 256"))
        }
    }

    @Test func renderToFileAndBase64() throws {
        let h = Headless.trustedLocal()
        _ = try h.handle("doc.new", ["width": 40, "height": 20, "background": "black"])
        let b = try h.handle("doc.render", ["maxSide": 10])
        #expect(try decodePNG(b["base64"]?.stringValue).size == PixelSize(width: 10, height: 5))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pc-rpc-\(getpid())-\(UUID().uuidString.prefix(6)).png")
        let r = try h.handle("doc.render", ["path": .string(path.path), "maxSide": 0])
        #expect((r["bytes"]?.intValue ?? 0) > 0)
        #expect(try ImageCodecs.decode(Data(contentsOf: path)).size == PixelSize(width: 40, height: 20))
        try? FileManager.default.removeItem(at: path)
    }

    @Test func backgroundJobsListWaitAndCancel() throws {
        let h = Headless()
        _ = try h.handle("doc.new", ["width": 600, "height": 400])
        _ = try h.handle("engine.execute", ["command": "layer.new.layer"])
        _ = try h.handle("engine.execute", ["command": "edit.fill", "params": ["color": "#808080"]])
        // Default: waits; the result is the command's.
        let r = try h.handle("engine.execute", ["command": "filter.noise.addNoise", "params": ["amount": 20]])
        #expect(r["filter"]?.objectValue != nil, "\(r)")
        // wait: false returns a job id at once.
        let started = try h.handle("engine.execute", ["command": "filter.blur.gaussianBlur", "params": ["radius": 40], "wait": false])
        let job = try #require(started["job"])
        let listed = try h.handle("jobs.list", .object([:]))
        #expect(listed["jobs"]?.arrayValue?.contains { $0["id"] == job } == true, "\(listed)")
        #expect(try waitUntil {
            let l = try h.handle("jobs.list", .object([:]))
            return l["jobs"]?.arrayValue?.first { $0["id"] == job }?["state"] == "done"
        })
        // Cancel: a second job, cancelled at once, leaves the document unchanged.
        let before = try #require(h.session.active?.doc)
        let second = try h.handle("engine.execute", ["command": "filter.blur.gaussianBlur", "params": ["radius": 40], "wait": false])
        let job2 = try #require(second["job"])
        _ = try h.handle("jobs.cancel", ["job": job2])
        #expect(throws: (any Error).self) { try h.handle("jobs.cancel", ["job": "nope"]) }
        #expect(try waitUntil {
            let l = try h.handle("jobs.list", .object([:]))
            return l["jobs"]?.arrayValue?.first { $0["id"] == job2 }?["state"] == "cancelled"
        })
        #expect(h.session.active?.doc == before)
    }

    @Test func batchStepsCanStartBackgroundJobs() throws {
        let h = Headless()
        _ = try h.handle("doc.new", ["width": 600, "height": 400])
        let steps: JSONValue = [
            ["command": "layer.new.layer"], ["command": "edit.fill", "params": ["color": "#808080"]],
            ["command": "filter.blur.gaussianBlur", "params": ["radius": 40], "wait": false],
        ]
        let r = try h.handle("batch", ["steps": steps])
        #expect(r["completed"] == 3, "\(r)")
        let job = try #require(r["results"]?[2]?["result"]?["job"], "no job id: \(r)")
        #expect(r["results"]?[2]?["result"]?["pending"] == true)
        let listed = try h.handle("jobs.list", .object([:]))
        #expect(listed["jobs"]?.arrayValue?.contains { $0["id"] == job } == true, "\(listed)")
        #expect(try waitUntil {
            let l = try h.handle("jobs.list", .object([:]))
            return l["jobs"]?.arrayValue?.first { $0["id"] == job }?["state"] == "done"
        })
    }

    /// #503: every request sees a finished background job (save, inspect, render, session.list).
    @Test func everyRequestSeesAFinishedBackgroundJob() throws {
        let dir = try tempDir("rpc-job-sync")
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = dir.appendingPathComponent("before.png"), after = dir.appendingPathComponent("after.png")
        let h = Headless.trustedLocal()
        _ = try h.handle("doc.new", ["width": 64, "height": 48])
        _ = try h.handle("engine.execute", ["command": "filter.noise.addNoise", "params": ["amount": 50]])
        _ = try h.handle("doc.save", ["path": .string(before.path)])
        let render = { try h.handle("doc.render", ["maxSide": 0])["base64"] }
        let unblurred = try render()
        let revision = { try h.handle("session.list", .object([:]))["documents"]?[0]?["revision"] }
        let start = try revision()
        _ = try h.handle("engine.execute", ["command": "filter.blur.gaussianBlur", "params": ["radius": 4], "wait": false])
        // Only reading requests from here on: no command and no `jobs.list`.
        #expect(try waitUntil { try revision() != start }, "session.list never saw the finished job")
        let history = try h.handle("doc.inspect", .object([:]))["history"]
        #expect(history?.arrayValue?.last == "Gaussian Blur", "\(String(describing: history))")
        _ = try h.handle("doc.save", ["path": .string(after.path)])
        #expect(try Data(contentsOf: before) != Data(contentsOf: after), "the export holds the blur")
        #expect(try render() != unblurred, "the preview holds the blur")
    }

    @Test func automationPreviewRejectsOversizedFullSizeAndNumericWraparound() throws {
        let h = Headless()
        _ = try h.handle("doc.new", ["width": 2049, "height": 1])
        for max in [0, 2049, Double(UInt32.max) + 1, -1, 1.5] as [Double] {
            #expect(throws: (any Error).self, "\(max)") { try h.handle("doc.render", ["maxSide": .number(max)]) }
        }
        // A smaller preview still works, and rejection leaves the source document intact.
        let rendered = try h.handle("doc.render", ["maxSide": 32])
        #expect(try decodePNG(rendered["base64"]?.stringValue).size == PixelSize(width: 32, height: 1))
        #expect(h.session.active?.doc.size.width == 2049)
    }

    @Test func stdioRejectsOversizedFramesBeforeDispatch() throws {
        let h = Headless()
        let replies = try serveLines(h, Data(String(repeating: " ", count: ControlSecurity.maxRequestBytes + 1).utf8))
        #expect(replies.count == 1)
        #expect(replies.first?["ok"] == false)
        #expect(replies.first?["error"]?.stringValue?.contains("request exceeds") == true)
        #expect(h.session.documents.isEmpty)
    }

    /// #505: an over-long or non-UTF-8 line gets one error reply, the rest of the line is skipped
    /// (never dispatched), and the next request is served.
    @Test func stdioSkipsARejectedLineAndKeepsTheSession() throws {
        let h = Headless()
        var input = Data(#"{"id":1,"method":"doc.new","params":{"width":8,"height":8}}"#.utf8 + [0x0A])
        input.append(Data(String(repeating: " ", count: ControlSecurity.maxRequestBytes + 1).utf8))
        input.append(Data(#"{"id":9,"method":"doc.close"}"#.utf8 + [0x0A]))
        input.append(Data([0xFF, 0xFE] + Array(#"{"id":8,"method":"doc.close"}"#.utf8) + [0x0A]))
        input.append(Data(#"{"id":2,"method":"session.list"}"#.utf8 + [0x0A]))
        let replies = try serveLines(h, input)
        #expect(replies.count == 4, "\(replies)")
        #expect(replies[0]["ok"] == true)
        #expect(replies[1]["error"]?.stringValue?.contains("request exceeds") == true)
        #expect(replies[2]["error"]?.stringValue?.contains("not valid UTF-8") == true)
        #expect(replies[3]["id"] == 2)
        #expect(replies[3]["result"]?["documents"]?.arrayValue?.count == 1, "the document stays open")
    }

    @Test func previewRejectionPrecedesOutputFileCreation() throws {
        let root = try tempDir("preview-budget")
        defer { try? FileManager.default.removeItem(at: root) }
        let h = Headless.withWorkspace(try AuthorizedWorkspace(writeRoot: root.path))
        _ = try h.handle("doc.new", ["width": 16, "height": 8])
        do {
            _ = try h.handle("doc.render", ["maxSide": 2049, "path": "rejected.png"])
            Issue.record("accepted")
        } catch {
            #expect("\(error)".contains("preview side exceeds"))
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("rejected.png").path))
        _ = try h.handle("doc.render", ["maxSide": 16, "path": "accepted.png"])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("accepted.png").path))
    }

    @Test func docPlaceReadsThroughTheReadRootAndNeverOutsideIt() throws {
        let base = try tempDir("doc-place")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("workspace"), outside = base.appendingPathComponent("outside")
        for d in [root, outside] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try writeTestPNG(root.appendingPathComponent("logo.png"), width: 8, height: 6)
        try writeTestPNG(outside.appendingPathComponent("logo.png"), width: 8, height: 6)
        let h = Headless.withWorkspace(try AuthorizedWorkspace(readRoot: root.path, writeRoot: root.path))
        _ = try h.handle("doc.new", ["width": 40, "height": 30])
        let placed = try h.handle("doc.place", ["path": "logo.png", "scale": 50])
        #expect(placed["layer"]?.uint64Value != nil, "\(placed)")
        #expect(placed["scale"]?.doubleValue == 50, "the options reach the command: \(placed)")
        #expect(try h.handle("doc.inspect", .object([:]))["layers"]?.arrayValue?.count == 2, "the placed layer is in the document")
        // A path outside the read root is refused the way the ambient command is (#2810).
        for (path, reason) in [("../outside/logo.png", "parent traversal"), (outside.appendingPathComponent("logo.png").path, "must be inside the automation root")] {
            do {
                _ = try h.handle("doc.place", ["path": .string(path)])
                Issue.record("accepted \(path)")
            } catch {
                #expect("\(error)".contains(reason), "\(error)")
            }
            #expect(try h.handle("doc.inspect", .object([:]))["layers"]?.arrayValue?.count == 2, "nothing was placed")
        }
        #expect(throws: (any Error).self) { try h.handle("engine.execute", ["command": "file.placeEmbedded", "params": ["path": "logo.png"]]) }
        // Trusted local keeps the ambient command: that caller may read the path itself.
        let t = Headless.trustedLocal()
        _ = try t.handle("doc.new", ["width": 40, "height": 30])
        let trusted = try t.handle("doc.place", ["path": .string(root.appendingPathComponent("logo.png").path)])
        #expect(trusted["layer"]?.uint64Value != nil, "\(trusted)")
    }

    @Test func docExportLayersWritesOnlyBeneathTheWriteRoot() throws {
        let base = try tempDir("doc-export-layers")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let h = Headless.withWorkspace(try AuthorizedWorkspace(readRoot: root.path, writeRoot: root.path))
        _ = try h.handle("doc.new", ["width": 12, "height": 8, "background": "white", "name": "card"])
        _ = try h.handle("engine.execute", ["command": "layer.new.layer", "params": ["name": "Badge"]])
        let out = root.appendingPathComponent("out")
        let exported = try h.handle("doc.exportLayers", ["dir": .string(out.path), "format": "png", "prefix": "card"])
        #expect(exported["count"] == 2, "\(exported)")
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        #expect(names.count == 2, "\(exported)")
        for name in names {
            #expect(name.hasPrefix("card_") && name.hasSuffix(".png"), "\(name)")
            let img = try ImageCodecs.decode(Data(contentsOf: out.appendingPathComponent(name)))
            #expect(img.size == PixelSize(width: 12, height: 8), "\(name)")
        }
        // Outside the write root nothing is created, not even the directory.
        let escaped = base.appendingPathComponent("escaped")
        do {
            _ = try h.handle("doc.exportLayers", ["dir": .string(escaped.path)])
            Issue.record("accepted")
        } catch {
            #expect("\(error)".contains("must be inside the automation root"), "\(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: escaped.path))
        // The ambient command keeps its refusal for the very same directory.
        do {
            _ = try h.handle("engine.execute", ["command": "file.export.layersToFiles", "params": ["dir": .string(out.path)]])
            Issue.record("accepted")
        } catch {
            #expect("\(error)".contains("ambient filesystem paths"), "\(error)")
        }
    }

    @Test func docExportDataSetsRefuseCollisionsAndImportReadsTheRoot() throws {
        let base = try tempDir("doc-data-sets")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let h = Headless.withWorkspace(try AuthorizedWorkspace(readRoot: root.path, writeRoot: root.path))
        _ = try h.handle("doc.new", ["width": 8, "height": 8, "background": "white", "name": "card"])
        let layer = try #require(try h.handle("doc.inspect", .object([:]))["layers"]?[0]?["id"])
        _ = try h.handle("engine.execute", ["command": "image.variables.define", "params": ["defs": [["name": "show", "layer": layer, "type": "visibility"]]]])
        _ = try h.handle("engine.execute", ["command": "image.variables.dataSets", "params": ["dataSets": [
            ["name": "one", "values": [["variable": "show", "kind": "visibility", "value": true]]],
            ["name": "two", "values": [["variable": "show", "kind": "visibility", "value": false]]],
        ]]])
        let sets = root.appendingPathComponent("sets")
        let exported = try h.handle("doc.exportDataSets", ["dir": .string(sets.path), "format": "png"])
        #expect(exported["count"] == 2, "\(exported)")
        #expect(contents(sets).count == 2, "\(exported)")
        // Colliding names are refused as in the command, before any file is written.
        let clash = root.appendingPathComponent("clash")
        do {
            _ = try h.handle("doc.exportDataSets", ["dir": .string(clash.path), "naming": "{document}"])
            Issue.record("accepted colliding names")
        } catch {
            #expect("\(error)".contains("{index}"), "\(error)")
        }
        #expect(contents(clash).isEmpty, "no file of the refused batch")
        // A CSV from the read root, and one outside it.
        try Data("Data Set,show\none,true\ntwo,false\n".utf8).write(to: root.appendingPathComponent("sets.csv"))
        let imported = try h.handle("doc.importDataSets", ["path": "sets.csv"])
        #expect(imported["imported"] == 2, "\(imported)")
        try Data("Data Set,show\none,true\n".utf8).write(to: base.appendingPathComponent("outside.csv"))
        do {
            _ = try h.handle("doc.importDataSets", ["path": .string(base.appendingPathComponent("outside.csv").path)])
            Issue.record("accepted")
        } catch {
            #expect("\(error)".contains("must be inside the automation root"), "\(error)")
        }
        // Non-UTF-8 text is refused before the parser sees it; the ambient command stays refused.
        try Data([0x41, 0xFF, 0x0A]).write(to: root.appendingPathComponent("bad.csv"))
        do {
            _ = try h.handle("doc.importDataSets", ["path": "bad.csv"])
            Issue.record("accepted")
        } catch {
            #expect("\(error)".contains("is not valid UTF-8"), "\(error)")
        }
        #expect(throws: (any Error).self) { try h.handle("engine.execute", ["command": "file.import.variableDataSets", "params": ["path": "sets.csv"]]) }
    }

    @Test func trustedLocalRenderKeepsFullSizeBehavior() throws {
        let h = Headless.trustedLocal()
        _ = try h.handle("doc.new", ["width": 2049, "height": 1])
        let rendered = try h.handle("doc.render", ["maxSide": 0])
        #expect(try decodePNG(rendered["base64"]?.stringValue).size == PixelSize(width: 2049, height: 1))
    }

    @Test func methodsListsTheJobMethodsAndEveryListedNameIsServed() throws {
        let h = Headless()
        let listed = try h.handle("methods", .null).arrayValue?.compactMap(\.stringValue) ?? []
        #expect(listed == RPC.methods)
        // The job methods `engine.execute {"wait": false}` depends on are discoverable (#414).
        #expect(listed.contains("jobs.list") && listed.contains("jobs.cancel"))
        for m in RPC.methods {
            do { _ = try h.handle(m, .null) } catch {
                #expect(!"\(error)".contains("unknown method"), "\(m) is listed but not served: \(error)")
            }
        }
        do {
            _ = try h.handle("jobs.nope", .null)
            Issue.record("accepted")
        } catch {
            #expect("\(error)".contains("unknown method"))
        }
    }

    @Test func batchResponseBudgetStopsLaterStepsEvenWhenStopOnErrorIsFalse() throws {
        let h = Headless()
        var steps = Array(repeating: ["command": "command.list"] as JSONValue, count: ControlSecurity.maxBatchSteps - 1)
        steps.append(["command": "file.new", "params": ["width": 8, "height": 8]])
        let result = try h.batch(["steps": .array(steps), "stopOnError": false])
        #expect(result["failed"] == 1)
        #expect(result["results"]?.arrayValue?.last?["error"]?.stringValue?.contains("batch response budget exceeded") == true)
        #expect(h.session.documents.isEmpty, "later edit must not execute after the quota is exhausted")
        _ = try Budgets.jsonBytes(result)
        _ = try h.handle("methods", .null)
    }

    // MARK: TCP

    static let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    /// A started loopback server and a connected client socket.
    static func tcp(token: String = token) throws -> (TCPControlServer, Int32, LineReader) {
        let server = try TCPControlServer("127.0.0.1:0", SharedHeadless(Headless()), token: token)
        server.start()
        let fd = try Sockets.connect(server.localAddress, timeout: 5)
        ControlSecurity.configureStream(fd)
        return (server, fd, LineReader(fd: fd))
    }

    static func send(_ fd: Int32, _ line: String) throws { try Sockets.writeAll(fd, Data((line + "\n").utf8)) }

    static func receive(_ reader: LineReader) throws -> JSONValue {
        guard case .line(let l) = try reader.readBoundedLine() else { throw EngineError.other("no reply") }
        return try JSONValue.parse(l)
    }

    @Test func tcpServesLoopback() throws {
        let (server, fd, reader) = try Self.tcp()
        defer { server.stop(); close(fd) }
        try Self.send(fd, #"{"id":"auth","method":"auth","params":{"token":"\#(Self.token)"}}"#)
        #expect(try Self.receive(reader)["result"]?["authenticated"] == true)
        try Self.send(fd, #"{"id":"a","method":"methods"}"#)
        let v = try Self.receive(reader)
        #expect(v["id"] == "a")
        #expect(v["result"]?.arrayValue?.contains("batch") == true)
    }

    @Test func tcpRepeatAuthReportsAlreadyAuthenticatedAndKeepsServing() throws {
        let (server, fd, reader) = try Self.tcp()
        defer { server.stop(); close(fd) }
        var again: JSONValue = .null
        for id in ["auth", "again"] {
            try Self.send(fd, #"{"id":"\#(id)","method":"auth","params":{"token":"\#(Self.token)"}}"#)
            again = try Self.receive(reader)
        }
        #expect(again["id"] == "again")
        #expect(again["ok"] == false)
        #expect(again["error"] == "already authenticated")
        try Self.send(fd, #"{"id":"m","method":"methods"}"#)
        let v = try Self.receive(reader)
        #expect(v["id"] == "m")
        #expect(v["ok"] == true)
    }

    @Test func tcpRejectsRequestsBeforeAuthentication() throws {
        let (server, fd, reader) = try Self.tcp(token: String(repeating: "a", count: 64))
        defer { server.stop(); close(fd) }
        try Self.send(fd, #"{"id":1,"method":"methods"}"#)
        let v = try Self.receive(reader)
        #expect(v["ok"] == false)
        #expect(v["error"] == "authentication required")
        #expect(v["result"] == nil)
        // The connection is closed after the refusal.
        #expect(try reader.readBoundedLine() == .eof)
    }

    @Test func tcpRefusesNonLoopbackAddresses() throws {
        #expect(throws: EngineError.self) { try TCPControlServer("0.0.0.0:0", SharedHeadless(Headless()), token: Self.token) }
    }
}
