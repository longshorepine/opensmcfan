import Foundation

// MARK: - SMC Value

/// A parsed value read from an SMC key.
public enum SMCValue {
    case double(Double)
    case int(Int)
    case uint(UInt)
    case bool(Bool)
    case string(String)
    case bytes([UInt8])
    case none

    /// Convenience: extract as Double (works for numeric types).
    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v):    return Double(v)
        case .uint(let v):   return Double(v)
        case .bool(let v):   return v ? 1.0 : 0.0
        default:             return nil
        }
    }

    /// Convenience: extract as Int.
    public var intValue: Int? {
        switch self {
        case .double(let v): return Int(v)
        case .int(let v):    return v
        case .uint(let v):   return Int(v)
        case .bool(let v):   return v ? 1 : 0
        default:             return nil
        }
    }
}

// MARK: - Parser

/// Encodes and decodes SMC value types.
public enum SMCParser {

    /// Parse raw bytes given the SMC type string.
    public static func parse(bytes: [UInt8], type: String) -> SMCValue {
        guard !bytes.isEmpty else { return .none }

        switch type {
        case "sp78":
            // Signed 7.8 fixed point (temperature)
            let raw = (Int16(bytes[0]) << 8) | Int16(bytes[1])
            return .double(Double(raw) / 256.0)

        case "fpe2":
            // Unsigned 14.2 fixed point (fan RPM)
            let raw = (Int16(bytes[0]) << 8) | Int16(bytes[1])
            return .double(Double(raw) / 4.0)

        case "flt ","flt":
            // IEEE 754 single-precision float (big-endian)
            guard bytes.count >= 4 else { return .none }
            let bits = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) |
                       (UInt32(bytes[2]) << 8)  | UInt32(bytes[3])
            return .double(Double(Float(bitPattern: bits)))

        case "ui8 ", "ui8":
            return .uint(UInt(bytes[0]))

        case "ui16":
            let val = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return .uint(UInt(val))

        case "ui32":
            guard bytes.count >= 4 else { return .none }
            let val = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) |
                      (UInt32(bytes[2]) << 8)  | UInt32(bytes[3])
            return .uint(UInt(val))

        case "si8 ", "si8":
            return .int(Int(Int8(bitPattern: bytes[0])))

        case "si16":
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return .int(Int(Int16(bitPattern: raw)))

        case "flag":
            return .bool(bytes[0] != 0)

        default:
            if type.hasPrefix("ch8") {
                // ASCII string, null-terminated
                if let end = bytes.firstIndex(of: 0) {
                    return .string(String(bytes: Array(bytes[..<end]), encoding: .ascii) ?? "")
                }
                return .string(String(bytes: bytes, encoding: .ascii) ?? "")
            }
            return .bytes(bytes)
        }
    }

    // MARK: - Encoding

    /// Encode a Double into raw bytes for the given SMC type.
    public static func encode(value: Double, type: String) -> [UInt8]? {
        switch type {
        case "sp78":
            let raw = Int16(round(value * 256.0))
            return [UInt8(truncatingIfNeeded: raw >> 8),
                    UInt8(truncatingIfNeeded: raw)]

        case "fpe2":
            let raw = Int16(round(value * 4.0))
            return [UInt8(truncatingIfNeeded: raw >> 8),
                    UInt8(truncatingIfNeeded: raw)]

        case "flt ", "flt":
            let bits = Float(value).bitPattern
            return [UInt8(bits >> 24 & 0xFF), UInt8(bits >> 16 & 0xFF),
                    UInt8(bits >> 8 & 0xFF),  UInt8(bits & 0xFF)]

        case "ui8 ", "ui8":
            return [UInt8(clamping: Int(value))]

        case "ui16":
            let v = UInt16(clamping: Int(value))
            return [UInt8(v >> 8), UInt8(v & 0xFF)]

        case "ui32":
            let v = UInt32(clamping: Int(value))
            return [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF),
                    UInt8(v >> 8 & 0xFF),  UInt8(v & 0xFF)]

        case "flag":
            return [value != 0 ? 1 : 0]

        default:
            return nil
        }
    }

    /// Encode an RPM value as fpe2 bytes.
    public static func encodeFPE2(_ rpm: Double) -> [UInt8] {
        let raw = Int16(round(rpm * 4.0))
        return [UInt8(truncatingIfNeeded: raw >> 8),
                UInt8(truncatingIfNeeded: raw)]
    }
}
