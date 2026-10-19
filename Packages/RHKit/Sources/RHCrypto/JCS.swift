/// JSON value restricted to what may appear in a signed protocol object
/// (contracts/ scope "protocol"): strings, integers, booleans, null,
/// arrays and objects. Fractional numbers and exponents are rejected:
/// the protocol forbids them in signed objects.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

public enum JCSError: Error, Equatable, Sendable {
    case unexpectedEnd
    case unexpectedByte(UInt8, offset: Int)
    case invalidEscape(offset: Int)
    case loneSurrogate(offset: Int)
    case controlCharacterInString(offset: Int)
    case unsupportedNumber(offset: Int)
    case integerOutOfRange(offset: Int)
    case duplicateKey(String)
    case trailingData(offset: Int)
}

/// JSON Canonicalization Scheme, RFC 8785, for the "protocol" scope.
public enum JCS {
    /// Largest integer that serializes identically as an I-JSON (IEEE 754 double) number.
    public static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    /// Parses `text` and returns its canonical UTF-8 bytes.
    public static func canonicalize(jsonText text: String) throws -> [UInt8] {
        canonicalize(try parse(text))
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var parser = Parser(bytes: Array(text.utf8))
        return try parser.parseDocument()
    }

    public static func canonicalize(_ value: JSONValue) -> [UInt8] {
        var out: [UInt8] = []
        serialize(value, into: &out)
        return out
    }

    // MARK: - Serialization

    private static func serialize(_ value: JSONValue, into out: inout [UInt8]) {
        switch value {
        case .null:
            out.append(contentsOf: Array("null".utf8))
        case .bool(let flag):
            out.append(contentsOf: Array((flag ? "true" : "false").utf8))
        case .integer(let number):
            out.append(contentsOf: Array(String(number).utf8))
        case .string(let string):
            serialize(string, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                serialize(item, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let members):
            // RFC 8785 §3.2.3: keys sorted by their UTF-16 code units.
            let keys = members.keys.sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            out.append(UInt8(ascii: "{"))
            for (index, key) in keys.enumerated() {
                if index > 0 { out.append(UInt8(ascii: ",")) }
                serialize(key, into: &out)
                out.append(UInt8(ascii: ":"))
                serialize(members[key]!, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    /// RFC 8785 §3.2.2.2: ECMAScript JSON.stringify string escaping.
    private static func serialize(_ string: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])            // \"
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])            // \\
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x00..<0x20:
                out.append(contentsOf: Array("\\u00".utf8))
                out.append(hexDigit(UInt8(scalar.value >> 4)))
                out.append(hexDigit(UInt8(scalar.value & 0x0F)))
            default:
                out.append(contentsOf: Array(String(scalar).utf8))
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    private static func hexDigit(_ nibble: UInt8) -> UInt8 {
        nibble < 10 ? UInt8(ascii: "0") + nibble : UInt8(ascii: "a") + nibble - 10
    }

    // MARK: - Parsing

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        mutating func parseDocument() throws -> JSONValue {
            skipWhitespace()
            let value = try parseValue()
            skipWhitespace()
            guard offset == bytes.count else { throw JCSError.trailingData(offset: offset) }
            return value
        }

        mutating func parseValue() throws -> JSONValue {
            guard let byte = peek() else { throw JCSError.unexpectedEnd }
            switch byte {
            case UInt8(ascii: "{"): return try parseObject()
            case UInt8(ascii: "["): return try parseArray()
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
            case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
            case UInt8(ascii: "n"): try expectLiteral("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
            default: throw JCSError.unexpectedByte(byte, offset: offset)
            }
        }

        mutating func parseObject() throws -> JSONValue {
            offset += 1  // {
            var members: [String: JSONValue] = [:]
            skipWhitespace()
            if peek() == UInt8(ascii: "}") {
                offset += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard peek() == UInt8(ascii: "\"") else { throw unexpected() }
                let key = try parseString()
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                skipWhitespace()
                let value = try parseValue()
                guard members.updateValue(value, forKey: key) == nil else { throw JCSError.duplicateKey(key) }
                skipWhitespace()
                guard let byte = peek() else { throw JCSError.unexpectedEnd }
                offset += 1
                if byte == UInt8(ascii: "}") { return .object(members) }
                guard byte == UInt8(ascii: ",") else { throw JCSError.unexpectedByte(byte, offset: offset - 1) }
            }
        }

        mutating func parseArray() throws -> JSONValue {
            offset += 1  // [
            var items: [JSONValue] = []
            skipWhitespace()
            if peek() == UInt8(ascii: "]") {
                offset += 1
                return .array(items)
            }
            while true {
                skipWhitespace()
                items.append(try parseValue())
                skipWhitespace()
                guard let byte = peek() else { throw JCSError.unexpectedEnd }
                offset += 1
                if byte == UInt8(ascii: "]") { return .array(items) }
                guard byte == UInt8(ascii: ",") else { throw JCSError.unexpectedByte(byte, offset: offset - 1) }
            }
        }

        mutating func parseString() throws -> String {
            offset += 1  // opening quote
            var utf8: [UInt8] = []
            while true {
                guard let byte = peek() else { throw JCSError.unexpectedEnd }
                switch byte {
                case UInt8(ascii: "\""):
                    offset += 1
                    return String(decoding: utf8, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    let escapeOffset = offset
                    offset += 1
                    guard let escaped = peek() else { throw JCSError.unexpectedEnd }
                    offset += 1
                    switch escaped {
                    case UInt8(ascii: "\""): utf8.append(0x22)
                    case UInt8(ascii: "\\"): utf8.append(0x5C)
                    case UInt8(ascii: "/"): utf8.append(0x2F)
                    case UInt8(ascii: "b"): utf8.append(0x08)
                    case UInt8(ascii: "f"): utf8.append(0x0C)
                    case UInt8(ascii: "n"): utf8.append(0x0A)
                    case UInt8(ascii: "r"): utf8.append(0x0D)
                    case UInt8(ascii: "t"): utf8.append(0x09)
                    case UInt8(ascii: "u"):
                        let scalar = try parseUnicodeEscape(escapeOffset: escapeOffset)
                        utf8.append(contentsOf: Array(String(scalar).utf8))
                    default:
                        throw JCSError.invalidEscape(offset: escapeOffset)
                    }
                case 0x00..<0x20:
                    throw JCSError.controlCharacterInString(offset: offset)
                default:
                    // Input comes from a Swift String, so raw bytes are valid UTF-8.
                    utf8.append(byte)
                    offset += 1
                }
            }
        }

        /// Reads the four hex digits after `\u` (and a following low surrogate escape if needed).
        mutating func parseUnicodeEscape(escapeOffset: Int) throws -> Unicode.Scalar {
            let unit = try parseHex4(escapeOffset: escapeOffset)
            switch unit {
            case 0xD800...0xDBFF:
                guard peek() == UInt8(ascii: "\\"), peek(at: 1) == UInt8(ascii: "u") else {
                    throw JCSError.loneSurrogate(offset: escapeOffset)
                }
                offset += 2
                let low = try parseHex4(escapeOffset: escapeOffset)
                guard (0xDC00...0xDFFF).contains(low) else { throw JCSError.loneSurrogate(offset: escapeOffset) }
                let value = 0x10000 + ((UInt32(unit) - 0xD800) << 10) + (UInt32(low) - 0xDC00)
                return Unicode.Scalar(value)!
            case 0xDC00...0xDFFF:
                throw JCSError.loneSurrogate(offset: escapeOffset)
            default:
                return Unicode.Scalar(unit)!
            }
        }

        mutating func parseHex4(escapeOffset: Int) throws -> UInt16 {
            guard offset + 4 <= bytes.count else { throw JCSError.unexpectedEnd }
            var value: UInt16 = 0
            for _ in 0..<4 {
                let byte = bytes[offset]
                let digit: UInt8
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
                default: throw JCSError.invalidEscape(offset: escapeOffset)
                }
                value = value << 4 | UInt16(digit)
                offset += 1
            }
            return value
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = offset
            if peek() == UInt8(ascii: "-") { offset += 1 }
            guard let first = peek(), isDigit(first) else { throw unexpected() }
            if first == UInt8(ascii: "0") {
                offset += 1
            } else {
                while let byte = peek(), isDigit(byte) { offset += 1 }
            }
            if let byte = peek(), byte == UInt8(ascii: ".") || byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                throw JCSError.unsupportedNumber(offset: start)
            }
            let literal = String(decoding: bytes[start..<offset], as: UTF8.self)
            guard let number = Int64(literal), (-JCS.maxSafeInteger...JCS.maxSafeInteger).contains(number) else {
                throw JCSError.integerOutOfRange(offset: start)
            }
            return .integer(number)  // "-0" parses as 0, which is also its canonical form
        }

        mutating func expectLiteral(_ literal: String) throws {
            for expected in literal.utf8 {
                try expect(expected)
            }
        }

        mutating func expect(_ expected: UInt8) throws {
            guard let byte = peek() else { throw JCSError.unexpectedEnd }
            guard byte == expected else { throw JCSError.unexpectedByte(byte, offset: offset) }
            offset += 1
        }

        mutating func skipWhitespace() {
            while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                offset += 1
            }
        }

        func peek(at distance: Int = 0) -> UInt8? {
            offset + distance < bytes.count ? bytes[offset + distance] : nil
        }

        func isDigit(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }

        func unexpected() -> JCSError {
            peek().map { JCSError.unexpectedByte($0, offset: offset) } ?? .unexpectedEnd
        }
    }
}
