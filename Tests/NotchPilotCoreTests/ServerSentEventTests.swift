import Foundation
import Testing
@testable import NotchPilotCore

/// Feeds `text` byte by byte, then ends the stream.
private func parse(_ text: String, limit: Int = ServerSentEventParser.defaultLimit) throws -> [ServerSentEvent] {
    var parser = ServerSentEventParser(limit: limit)
    var events = try Array(text.utf8).compactMap { try parser.feed($0) }
    if let last = try parser.finish() { events.append(last) }
    return events
}

@Suite("Server-sent events")
struct ServerSentEventTests {

    @Test("A blank line dispatches the event with its name and data")
    func basic() throws {
        #expect(try parse("event: ping\ndata: {\"a\":1}\n\nevent: stop\ndata: x\n\n") == [
            ServerSentEvent(event: "ping", data: "{\"a\":1}"),
            ServerSentEvent(event: "stop", data: "x"),
        ])
    }

    @Test("An event without a name has nil event")
    func unnamed() throws {
        #expect(try parse("data: [DONE]\n\n") == [ServerSentEvent(event: nil, data: "[DONE]")])
    }

    @Test("Multiple data lines join with a newline")
    func multiLineData() throws {
        #expect(try parse("data: one\ndata: two\ndata:\n\n") == [ServerSentEvent(event: nil, data: "one\ntwo\n")])
    }

    @Test("Comments and unknown fields are ignored; only one leading space is stripped")
    func commentsAndFields() throws {
        #expect(try parse(": keep-alive\nid: 7\nretry: 100\nfoo\ndata:  two spaces\n\n") == [
            ServerSentEvent(event: nil, data: " two spaces"),
        ])
    }

    @Test("A colon inside the value is kept")
    func colonInValue() throws {
        #expect(try parse("data: {\"k\":\"v\"}\n\n") == [ServerSentEvent(event: nil, data: "{\"k\":\"v\"}")])
    }

    @Test("CRLF, lone CR and LF line endings all work", arguments: ["\r\n", "\r", "\n"])
    func lineEndings(newline: String) throws {
        let text = ["event: a", "data: 1", "", "data: 2", "", ""].joined(separator: newline)
        #expect(try parse(text) == [ServerSentEvent(event: "a", data: "1"), ServerSentEvent(event: nil, data: "2")])
    }

    @Test("Blank lines without data dispatch nothing, and a name doesn't leak into the next event")
    func noDataNoEvent() throws {
        #expect(try parse("\n\nevent: lonely\n\ndata: x\n\n") == [ServerSentEvent(event: nil, data: "x")])
    }

    @Test("The last event is delivered at end of stream without a trailing blank line", arguments: ["data: end", "data: end\n"])
    func trailingEvent(text: String) throws {
        #expect(try parse("data: first\n\n" + text) == [
            ServerSentEvent(event: nil, data: "first"),
            ServerSentEvent(event: nil, data: "end"),
        ])
    }

    @Test("Multibyte UTF-8 survives byte-at-a-time feeding")
    func utf8() throws {
        #expect(try parse("data: héllo wörld 👋\n\n") == [ServerSentEvent(event: nil, data: "héllo wörld 👋")])
    }

    @Test("Events are returned from the byte that completes them")
    func dispatchTiming() throws {
        var parser = ServerSentEventParser()
        let bytes = Array("data: a\n\n".utf8)
        let results = try bytes.map { try parser.feed($0) }
        #expect(results.dropLast().allSatisfy { $0 == nil })
        #expect(results.last == ServerSentEvent(event: nil, data: "a"))
        #expect(try parser.finish() == nil)
    }

    @Test("A leading UTF-8 byte order mark is skipped")
    func byteOrderMark() throws {
        #expect(try parse("\u{FEFF}data: a\n\n") == [ServerSentEvent(event: nil, data: "a")])
        // Only at the start of the stream: a later BOM is part of the data.
        #expect(try parse("\u{FEFF}data: a\n\ndata: \u{FEFF}b\n\n").map(\.data) == ["a", "\u{FEFF}b"])
        // A stream that starts with a field name keeps its first bytes.
        #expect(try parse("data: x\n\n") == [ServerSentEvent(event: nil, data: "x")])
    }

    @Test("Bytes that only begin like a byte order mark are kept as data")
    func partialByteOrderMark() throws {
        var parser = ServerSentEventParser()
        var events: [ServerSentEvent] = []
        for byte in [0xEF, 0xBB] + Array(":c\ndata: z\n\n".utf8) {
            if let event = try parser.feed(byte) { events.append(event) }
        }
        // "\u{EF}\u{BB}:c" is a field with an unknown (invalid UTF-8) name, so it's ignored,
        // and the next line still parses.
        #expect(events == [ServerSentEvent(event: nil, data: "z")])

        var dataParser = ServerSentEventParser()
        var bytes: [UInt8] = Array("data".utf8)
        bytes.insert(0xEF, at: 0)
        _ = try bytes.map { try dataParser.feed($0) }
        // "\u{EF}data" is not the field "data": the partial BOM byte stayed in the line.
        #expect(try dataParser.finish() == nil)
    }

    @Test("A line or an event's data at the limit is accepted")
    func atLimit() throws {
        // "data: " plus 4 bytes is a 10-byte line; two 4-byte data lines join to 9 bytes.
        #expect(try parse("data: abcd\ndata: efgh\n\n", limit: 10) == [ServerSentEvent(event: nil, data: "abcd\nefgh")])
    }

    @Test("A line longer than the limit throws, even without a line break")
    func lineTooLong() {
        #expect(throws: ServerSentEventParser.TooLarge.self) { try parse("data: abcdef", limit: 10) }
        #expect(throws: ServerSentEventParser.TooLarge.self) { try parse(": " + String(repeating: "x", count: 20) + "\n", limit: 10) }
    }

    @Test("Data accumulated over many short lines is capped too")
    func dataTooLong() {
        #expect(throws: ServerSentEventParser.TooLarge.self) { try parse("data: abcd\ndata: efgh\ndata: i\n\n", limit: 10) }
    }

    @Test("The data budget resets for each event")
    func dataLimitPerEvent() throws {
        #expect(try parse("data: abcd\n\ndata: efgh\n\n", limit: 10).map(\.data) == ["abcd", "efgh"])
    }
}
