import Foundation

/// One server-sent event: its `event:` name (nil when the event had none) and its `data:`
/// lines joined with "\n".
struct ServerSentEvent: Sendable, Equatable {
    var event: String?
    var data: String
}

/// Incremental parser for the `text/event-stream` format (WHATWG HTML, "Server-sent
/// events"), fed one byte at a time.
///
/// It works on raw bytes rather than `URLSession.AsyncBytes.lines` because `lines` drops
/// empty lines, and an empty line is what ends an event. Buffering bytes until a line ends
/// also keeps a UTF-8 character that was split across network packets intact.
///
/// The current line and the current event's data are each capped at `limit` bytes, so a
/// misbehaving server can't grow them without bound.
struct ServerSentEventParser {
    /// Thrown when a line or an event's data exceeds the limit.
    struct TooLarge: Error {}

    static let defaultLimit = 1 << 20 // 1 MiB
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    private let limit: Int
    private var line: [UInt8] = []
    /// How much of a leading byte order mark has been read; nil once past the stream start.
    private var bomPosition: Int? = 0
    /// The previous byte was CR, so an LF right after it belongs to the same line break.
    private var afterCR = false
    private var eventName: String?
    /// nil until the current event has a `data:` field; an event without one isn't dispatched.
    private var data: String?
    private var dataBytes = 0

    init(limit: Int = defaultLimit) {
        self.limit = limit
    }

    /// Consumes one byte; returns an event when this byte completed one.
    mutating func feed(_ byte: UInt8) throws -> ServerSentEvent? {
        // The format allows one UTF-8 BOM at the very start of the stream; it isn't data.
        if let position = bomPosition {
            if byte == Self.byteOrderMark[position] {
                bomPosition = position + 1 < Self.byteOrderMark.count ? position + 1 : nil
                return nil
            }
            bomPosition = nil
            line.append(contentsOf: Self.byteOrderMark[..<position]) // a partial match was data
        }
        switch byte {
        case 0x0A: // LF
            if afterCR {
                afterCR = false
                return nil
            }
            return try endLine()
        case 0x0D: // CR
            afterCR = true
            return try endLine()
        default:
            afterCR = false
            guard line.count < limit else { throw TooLarge() }
            line.append(byte)
            return nil
        }
    }

    /// Call at end of stream: returns the last event if the stream ended without the blank
    /// line that normally dispatches it.
    mutating func finish() throws -> ServerSentEvent? {
        afterCR = false
        if let position = bomPosition {
            bomPosition = nil
            line.append(contentsOf: Self.byteOrderMark[..<position])
        }
        if !line.isEmpty { _ = try endLine() }
        return dispatch()
    }

    private mutating func endLine() throws -> ServerSentEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return dispatch() }
        let text = String(decoding: line, as: UTF8.self)
        if text.hasPrefix(":") { return nil } // comment, e.g. a keep-alive
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value.removeFirst() }
        } else {
            field = text[...]
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data":
            dataBytes += value.utf8.count + (data == nil ? 0 : 1)
            guard dataBytes <= limit else { throw TooLarge() }
            data = data.map { $0 + "\n" + value } ?? String(value)
        default: break // id, retry and unknown fields don't matter for a one-shot reply
        }
        return nil
    }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            eventName = nil
            data = nil
            dataBytes = 0
        }
        guard let data else { return nil }
        return ServerSentEvent(event: eventName, data: data)
    }
}
