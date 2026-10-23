import Foundation
import CoreFoundation

enum SerialParity: String, CaseIterable, Codable, Sendable {
    case none = "无"
    case even = "偶校验"
    case odd = "奇校验"

    // Raw values remain stable for previously saved presets.
    var title: String {
        switch self {
        case .none: AppText.none
        case .even: AppText.evenParity
        case .odd: AppText.oddParity
        }
    }
}

enum SerialFlowControl: String, CaseIterable, Codable, Sendable {
    case none = "无"
    case hardware = "RTS/CTS"
    case software = "XON/XOFF"

    var title: String { self == .none ? AppText.none : rawValue }
}

struct SerialConfiguration: Sendable {
    var path: String
    var baudRate: Int = 115200
    var dataBits: Int = 8
    var stopBits: Int = 1
    var parity: SerialParity = .none
    var flowControl: SerialFlowControl = .none
}

struct SerialPort: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

enum TextEncoding: String, CaseIterable, Codable, Sendable {
    case utf8 = "UTF-8"
    case ascii = "ASCII"
    case gb18030 = "GB18030"
    case big5 = "Big5"
    case utf16LE = "UTF-16 LE"
    case shiftJIS = "Shift-JIS"

    var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: return .utf8
        case .ascii: return .ascii
        case .utf16LE: return .utf16LittleEndian
        case .shiftJIS: return .shiftJIS
        case .big5, .gb18030:
            let value = self == .big5 ? CFStringEncodings.big5.rawValue : CFStringEncodings.GB_18030_2000.rawValue
            return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value)))
        }
    }
}

enum LineEnding: String, CaseIterable, Codable, Sendable {
    case none = "无"
    case lf = "LF"
    case cr = "CR"
    case crlf = "CRLF"

    var title: String { self == .none ? AppText.none : rawValue }

    var bytes: Data {
        switch self {
        case .none: return Data()
        case .lf: return Data([10])
        case .cr: return Data([13])
        case .crlf: return Data([13, 10])
        }
    }
}

enum PayloadError: LocalizedError {
    case invalidHex
    case unencodable(String)
    case empty
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidHex: return AppText.invalidHex
        case .unencodable(let encoding): return AppText.unencodable(encoding)
        case .empty: return AppText.emptyPayload
        case .tooLarge: return AppText.payloadTooLarge
        }
    }
}

enum PayloadCodec {
    static func encode(_ text: String, hex: Bool, encoding: TextEncoding, ending: LineEnding) throws -> Data {
        var data: Data
        if hex {
            let compact = text.filter { !$0.isWhitespace }
            guard compact.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  compact.utf8.count.isMultiple(of: 2) else {
                throw PayloadError.invalidHex
            }
            let chars = Array(compact)
            data = Data()
            for offset in stride(from: 0, to: chars.count, by: 2) {
                guard let byte = UInt8(String(chars[offset...offset + 1]), radix: 16) else {
                    throw PayloadError.invalidHex
                }
                data.append(byte)
            }
        } else {
            guard let encoded = text.data(using: encoding.foundationEncoding, allowLossyConversion: false) else {
                throw PayloadError.unencodable(encoding.rawValue)
            }
            data = encoded
        }
        guard !data.isEmpty else { throw PayloadError.empty }
        data.append(ending.bytes)
        guard data.count <= 65_536 else { throw PayloadError.tooLarge }
        return data
    }

    private static let hexDigits = Array("0123456789ABCDEF".utf8)

    static func hex(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var output = [UInt8](repeating: 32, count: data.count * 3 - 1)
        for (index, byte) in data.enumerated() {
            output[index * 3] = hexDigits[Int(byte >> 4)]
            output[index * 3 + 1] = hexDigits[Int(byte & 0x0F)]
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// Keeps incomplete characters between reads: serial read boundaries are not text boundaries.
struct StreamingTextDecoder {
    let encoding: TextEncoding
    private var pending = Data()

    init(encoding: TextEncoding) {
        self.encoding = encoding
    }

    mutating func decode(_ data: Data) -> String {
        pending.append(data)
        guard !pending.isEmpty else { return "" }
        if encoding == .utf16LE {
            // Foundation may accept an odd byte count by truncating it. Keep that byte,
            // and keep a trailing high surrogate until its low surrogate arrives.
            var length = pending.count - pending.count % 2
            let bytes = Array(pending)
            if length >= 2 {
                let last = UInt16(bytes[length - 2]) | UInt16(bytes[length - 1]) << 8
                if (0xD800...0xDBFF).contains(last) { length -= 2 }
            }
            var units: [UInt16] = []
            for index in stride(from: 0, to: length, by: 2) {
                units.append(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
            }
            pending.removeFirst(length)
            return String(decoding: units, as: UTF16.self)
        }
        if let text = String(data: pending, encoding: encoding.foundationEncoding) {
            pending.removeAll(keepingCapacity: true)
            return text
        }
        // UTF-8 / GB18030 can use up to four bytes per character.
        for suffixLength in 1...min(3, pending.count) {
            let prefix = pending.dropLast(suffixLength)
            if !prefix.isEmpty, let text = String(data: prefix, encoding: encoding.foundationEncoding) {
                pending = Data(pending.suffix(suffixLength))
                return text
            }
        }
        if pending.count <= 3 { return "" }
        // Preserve evidence of malformed input rather than silently dropping it.
        let text = encoding == .utf8
            ? String(decoding: pending, as: UTF8.self)
            : AppText.undecodable(PayloadCodec.hex(pending))
        pending.removeAll(keepingCapacity: true)
        return text
    }
}

struct CommandPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var text: String
    var isHex: Bool
    var ending: LineEnding
    var encoding: TextEncoding
}

enum LogDirection: String, Sendable {
    case received = "RX"
    case sent = "TX"
    case system = "SYS"
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date: Date
    let direction: LogDirection
    let data: Data
    var text: String
}
