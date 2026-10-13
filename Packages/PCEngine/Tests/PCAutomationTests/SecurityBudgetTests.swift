// Port of photocraft-automation's security and budget tests (crates/automation/src/security.rs and budgets.rs `mod tests`), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import Foundation
@testable import PCAutomation
import PCDocument
import PCEngine
import Testing

@Suite struct SecurityTests {
    @Test func generatedTokensAreValidAndDistinct() throws {
        let a = try ControlSecurity.generateToken(), b = try ControlSecurity.generateToken()
        try ControlSecurity.validateToken(a)
        #expect(a != b)
        #expect(ControlSecurity.tokenMatches(a, a))
        #expect(!ControlSecurity.tokenMatches(a, b))
        #expect(!ControlSecurity.tokenMatches(a, "short"))
    }

    @Test func boundedReaderRejectsAnOversizedLine() throws {
        let max = ControlSecurity.maxRequestBytes
        let reader = LineReader(data: Data((String(repeating: "x", count: max + 1) + "\n").utf8))
        #expect(try reader.readBoundedLine() == .tooLong(bytes: max + 1, endsWithNewline: false))
        try reader.discardRestOfLine()
        #expect(try reader.readBoundedLine() == .eof)
    }

    @Test func boundedReaderReportsACutMultibyteLineAsTooLongAndBadUTF8AsInvalidData() throws {
        // The cut at the limit falls inside a two-byte character.
        let input = "xx" + String(repeating: "é", count: ControlSecurity.maxRequestBytes / 2) + "\nnext\n"
        let reader = LineReader(data: Data(input.utf8), chunk: 4096)
        guard case .tooLong = try reader.readBoundedLine() else { Issue.record("not too long"); return }
        try reader.discardRestOfLine()
        #expect(try reader.readBoundedLine() == .line("next\n"))
        // Invalid UTF-8 consumes its whole line, so the next read starts on the next line.
        let bad = LineReader(data: Data([0xFF, 0xFE, 0x0A] + Array("next\n".utf8)))
        #expect(try bad.readBoundedLine() == .invalidUTF8)
        #expect(try bad.readBoundedLine() == .line("next\n"))
    }

    @Test func authenticationDoesNotDispatchWithoutTheToken() throws {
        let token = try ControlSecurity.generateToken()
        let (reply, ok) = ControlSecurity.authenticationReply(#"{"id":1,"method":"methods","params":{}}"#, expectedToken: token)
        #expect(!ok)
        #expect(reply["error"] == "authentication required")
        #expect(reply["result"] == nil)
        let line = (["id": 2, "method": .string(ControlSecurity.authMethod), "params": ["token": .string(token)]] as JSONValue).serialized()
        let (reply2, ok2) = ControlSecurity.authenticationReply(line, expectedToken: token)
        #expect(ok2)
        #expect(reply2["result"]?["authenticated"] == true)
    }

    @Test func repeatAuthOnAnAuthenticatedConnectionSaysSo() throws {
        let line = (["id": 3, "method": "auth", "params": ["token": "anything"]] as JSONValue).serialized()
        let reply = try #require(ControlSecurity.repeatAuthReply(line))
        #expect(reply["id"] == 3)
        #expect(reply["ok"] == false)
        #expect(reply["error"] == "already authenticated")
        #expect(ControlSecurity.repeatAuthReply(#"{"id":4,"method":"methods"}"#) == nil)
        #expect(ControlSecurity.repeatAuthReply("{not json") == nil)
    }

    @Test func tokenFileRoundTripsBetweenServerAndClient() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("photocraft-control-token-\(getpid())-\(try ControlSecurity.generateToken()).txt").path
        let server = try ControlSecurity.serverToken(supplied: nil, tokenFile: path)
        let client = try ControlSecurity.clientToken(supplied: nil, tokenFile: path)
        #expect(server == client)
        #expect(ControlSecurity.tokenMatches(server, client))
        // Created owner-only, and reused on the next launch.
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
        #expect(try ControlSecurity.serverToken(supplied: nil, tokenFile: path) == server)
        #expect(throws: EngineError.self) { try ControlSecurity.serverToken(supplied: server, tokenFile: path) }
        #expect(throws: EngineError.self) { try ControlSecurity.clientToken(supplied: nil, tokenFile: nil) }
        try FileManager.default.removeItem(atPath: path)
    }

    @Test func connectionLimiterReleasesCapacity() throws {
        let limiter = ControlSecurity.ConnectionLimiter(max: 1)
        var permit = limiter.tryAcquire()
        #expect(permit != nil)
        #expect(limiter.tryAcquire() == nil)
        permit = nil
        #expect(limiter.tryAcquire() != nil)
    }
}

@Suite struct BudgetTests {
    @Test func previewChecksFullSizeRequestedEdgeAndSourceBeforeRendering() throws {
        let side = Budgets.maxPreviewSide
        try Budgets.checkPreview(width: 64, height: 32, maxSide: 0)
        try Budgets.checkPreview(width: side, height: side, maxSide: 0)
        #expect(throws: EngineError.self) { try Budgets.checkPreview(width: side + 1, height: 1, maxSide: 0) }
        #expect(throws: EngineError.self) { try Budgets.checkPreview(width: 64, height: 32, maxSide: side + 1) }
        try Budgets.checkPreview(width: 8192, height: 8192, maxSide: 1024)
        #expect(throws: EngineError.self) { try Budgets.checkPreview(width: 8193, height: 8192, maxSide: 1024) }
        #expect(throws: EngineError.self) { try Budgets.checkPreview(width: Int(UInt32.max), height: Int(UInt32.max), maxSide: 1) }
        #expect(throws: EngineError.self) { try Budgets.checkPreview(width: 0, height: 32, maxSide: 1) }
    }

    @Test func encodedBytesIncludeJSONEscapingAndAcceptExactBoundary() throws {
        #expect(try Budgets.encodeWithLimit("abc", 5) == Data(#""abc""#.utf8))
        #expect(throws: EngineError.self) { try Budgets.encodeWithLimit("abc", 4) }
        #expect(throws: EngineError.self) { try Budgets.encodeWithLimit("\n\n", 5) }
        #expect(throws: EngineError.self) { try Budgets.encodeWithLimit(.null, 0) }
        try Budgets.checkPNG(Budgets.maxPNGBytes)
        #expect(throws: EngineError.self) { try Budgets.checkPNG(Budgets.maxPNGBytes + 1) }
    }

    @Test func oversizedReplyIsOneCompleteErrorWithMatchingID() throws {
        let reply: JSONValue = ["id": 7, "ok": true, "result": .string(String(repeating: "x", count: Budgets.maxResponseBytes))]
        let out = Budgets.replyLine(reply)
        #expect(out.count < 1024)
        #expect(out.filter { $0 == 0x0A }.count == 1)
        let error = try JSONValue.parse(out)
        #expect(error["id"] == 7)
        #expect(error["ok"] == false)
        #expect(error["error"]?.stringValue?.contains("operation may have completed") == true)
    }

    @Test func batchCannotRetainMoreThanTheAggregateReplyBudget() throws {
        var budget = Budgets.BatchReplyBudget(remaining: 10, escaped: false)
        try budget.charge("abc")
        #expect(throws: EngineError.self) { try budget.charge("abc") }
        #expect(budget.remaining == 4)
    }

    @Test func escapedBudgetChargesTheSizeInsideAJSONString() throws {
        // `"a\"b"` is 6 bytes plain and 10 once embedded in a string.
        let value: JSONValue = "a\"b"
        let escaped = JSONValue.string(value.serialized()).serialized().utf8.count - 2
        #expect(escaped == 10)
        var budget = Budgets.BatchReplyBudget(remaining: 11, escaped: true)
        try budget.charge(value)
        #expect(budget.remaining == 0)
        var tight = Budgets.BatchReplyBudget(remaining: 10, escaped: true)
        #expect(throws: EngineError.self) { try tight.charge(value) }
        var plain = Budgets.BatchReplyBudget(remaining: 10, escaped: false)
        try plain.charge(value)
    }
}
