import Foundation
import Network

/// One OSC argument. symphonyd only uses int32, float32 and string.
enum OSCValue {
    case int(Int32), float(Float), string(String)

    var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .float(let f): return Double(f)
        case .string: return nil
        }
    }
}

struct OSCMessage {
    var path: String
    var args: [OSCValue] = []

    func encode() -> Data {
        var d = Data()
        func pad(_ s: String) {
            var b = Data(s.utf8)
            b.append(0)
            while b.count % 4 != 0 { b.append(0) }
            d.append(b)
        }
        func be32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        pad(path)
        pad("," + args.map { a -> String in
            switch a { case .int: return "i"; case .float: return "f"; case .string: return "s" }
        }.joined())
        for a in args {
            switch a {
            case .int(let i): be32(UInt32(bitPattern: i))
            case .float(let f): be32(f.bitPattern)
            case .string(let s): pad(s)
            }
        }
        return d
    }

    static func decode(_ data: Data) -> OSCMessage? {
        let b = [UInt8](data)
        var pos = 0
        func string() -> String? {
            guard pos < b.count, let end = b[pos...].firstIndex(of: 0) else { return nil }
            let s = String(decoding: b[pos..<end], as: UTF8.self)
            pos = (end + 4) & ~3
            return s
        }
        func be32() -> UInt32? {
            guard pos + 4 <= b.count else { return nil }
            let v = UInt32(b[pos]) << 24 | UInt32(b[pos + 1]) << 16 | UInt32(b[pos + 2]) << 8 | UInt32(b[pos + 3])
            pos += 4
            return v
        }
        guard let path = string(), path.hasPrefix("/") else { return nil }
        var msg = OSCMessage(path: path)
        guard pos < b.count, let tags = string(), tags.hasPrefix(",") else { return msg }
        for t in tags.dropFirst() {
            switch t {
            case "i": guard let v = be32() else { return nil }; msg.args.append(.int(Int32(bitPattern: v)))
            case "f": guard let v = be32() else { return nil }; msg.args.append(.float(Float(bitPattern: v)))
            case "s": guard let s = string() else { return nil }; msg.args.append(.string(s))
            default: return nil
            }
        }
        return msg
    }
}

/// UDP connection to symphonyd. Replies arrive on the same socket.
final class OSCClient {
    private var connection: NWConnection?
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    var onMessage: ((OSCMessage) -> Void)?

    init(host: String, port: UInt16) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    /// (Re)opens the socket. Safe to call any time; UDP has no handshake.
    func restart() {
        connection?.cancel()
        let c = NWConnection(host: host, port: port, using: .udp)
        connection = c
        c.start(queue: .main)
        receive(on: c)
    }

    private func receive(on c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, c === self.connection else { return }
            if let data, let msg = OSCMessage.decode(data) { self.onMessage?(msg) }
            if error == nil { self.receive(on: c) }
        }
    }

    func send(_ msg: OSCMessage) {
        if connection == nil { restart() }
        connection?.send(content: msg.encode(), completion: .idempotent)
    }
}
