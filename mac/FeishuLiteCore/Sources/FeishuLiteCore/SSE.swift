import Foundation

public struct SSEEvent: Equatable, Sendable {
    public var event: String
    public var data: String

    public init(event: String, data: String) {
        self.event = event
        self.data = data
    }
}

/// 按字节把流切成行，支持 \n、\r\n 和单独的 \r，空行也会原样产出。
/// URLSession.AsyncBytes.lines 会丢掉空行，而 SSE 靠空行分隔事件，所以得自己切。
public struct SSELineSplitter: Sendable {
    private var buffer: [UInt8] = []
    private var lastWasCR = false

    public init() {}

    public mutating func feed(_ byte: UInt8) -> String? {
        let followsCR = lastWasCR
        lastWasCR = byte == UInt8(ascii: "\r")
        switch byte {
        case UInt8(ascii: "\n") where followsCR:
            return nil
        case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
            defer { buffer.removeAll(keepingCapacity: true) }
            return String(decoding: buffer, as: UTF8.self)
        default:
            buffer.append(byte)
            return nil
        }
    }
}

/// 按 WHATWG 的 event stream 规则把行组装成事件：空行派发，冒号开头是注释，多行 data 用 \n 连接。
public struct SSEParser: Sendable {
    private var event = ""
    private var data: [String] = []

    public init() {}

    public mutating func feed(line: String) -> SSEEvent? {
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil
        }
        let (field, value) = Self.split(line)
        switch field {
        case "event": event = value
        case "data": data.append(value)
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            event = ""
            data.removeAll()
        }
        guard !data.isEmpty else { return nil }
        return SSEEvent(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"))
    }

    private static func split(_ line: String) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        var value = line[line.index(after: colon)...]
        if value.hasPrefix(" ") {
            value = value.dropFirst()
        }
        return (String(line[..<colon]), String(value))
    }
}

/// 字节进，事件出
public struct SSEStreamDecoder: Sendable {
    private var splitter = SSELineSplitter()
    private var parser = SSEParser()

    public init() {}

    public mutating func feed(_ byte: UInt8) -> SSEEvent? {
        guard let line = splitter.feed(byte) else { return nil }
        return parser.feed(line: line)
    }

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            if let event = feed(byte) {
                events.append(event)
            }
        }
        return events
    }
}
