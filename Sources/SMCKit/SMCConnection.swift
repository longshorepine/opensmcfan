import Foundation
import IOKit

// MARK: - Errors

public enum SMCError: LocalizedError {
    case serviceNotFound
    case openFailed(Int32)
    case keyInfoFailed(String, Int32)
    case readFailed(String, Int32)
    case writeFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .serviceNotFound:
            return "AppleSMC service not found — not an Intel Mac, or SIP blocks access"
        case .openFailed(let code):
            return String(format: "IOServiceOpen failed: 0x%x", code)
        case .keyInfoFailed(let key, let code):
            return String(format: "SMC key info failed for '%@': 0x%x", key, code)
        case .readFailed(let key, let code):
            return String(format: "SMC read failed for '%@': 0x%x", key, code)
        case .writeFailed(let key, let code):
            return String(format: "SMC write failed for '%@': 0x%x", key, code)
        }
    }
}

// MARK: - SMC Key Info

/// Parsed info about an SMC key (type string + data size).
public struct SMCKeyInfo {
    public let dataSize: UInt32
    public let dataType: String   // e.g. "sp78", "fpe2", "flt"
}

// MARK: - SMC Connection

/// Low-level connection to the AppleSMC IOService.
/// Thread-safe: all IOKit calls are serialized on an internal queue.
public final class SMCConnection {
    private var connection: io_connect_t = 0
    private let queue = DispatchQueue(label: "com.mysmc.smc", qos: .userInitiated)

    public init() throws {
        let service = IOServiceGetMatchingService(
            0,  // kIOMasterPortDefault
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else {
            throw SMCError.serviceNotFound
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            throw SMCError.openFailed(result)
        }
    }

    deinit {
        close()
    }

    /// Close the IOKit connection. Safe to call multiple times.
    public func close() {
        queue.sync {
            if connection != 0 {
                IOServiceClose(connection)
                connection = 0
            }
        }
    }

    // MARK: - Key helpers

    /// Convert a 4-char key string to UInt32 (big-endian packed).
    static func keyToUInt32(_ key: String) -> UInt32 {
        let bytes = Array(key.utf8)
        precondition(bytes.count == 4, "SMC key must be exactly 4 ASCII characters")
        return (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) |
               (UInt32(bytes[2]) << 8)  | UInt32(bytes[3])
    }

    /// Convert a UInt32 type code back to a 4-char string.
    static func uint32ToTypeString(_ val: UInt32) -> String {
        let chars: [Character] = [
            Character(UnicodeScalar((val >> 24) & 0xFF)!),
            Character(UnicodeScalar((val >> 16) & 0xFF)!),
            Character(UnicodeScalar((val >> 8) & 0xFF)!),
            Character(UnicodeScalar(val & 0xFF)!),
        ]
        return String(chars).trimmingCharacters(in: .init(charactersIn: "\0 "))
    }

    // MARK: - Raw IOKit call

    private func callSMC(_ input: inout SMCKeyData_t) throws -> SMCKeyData_t {
        return try queue.sync {
            var output = SMCKeyData_t()
            var outputSize = MemoryLayout<SMCKeyData_t>.size

            let result = IOConnectCallStructMethod(
                connection,
                UInt32(KERNEL_INDEX_SMC),
                &input,
                MemoryLayout<SMCKeyData_t>.size,
                &output,
                &outputSize
            )
            guard result == kIOReturnSuccess else {
                throw SMCError.readFailed("raw", result)
            }
            return output
        }
    }

    // MARK: - Public API

    /// Get type info for an SMC key.
    public func keyInfo(for key: String) throws -> SMCKeyInfo {
        var input = SMCKeyData_t()
        input.key = SMCConnection.keyToUInt32(key)
        input.data8 = UInt8(SMC_CMD_READ_KEYINFO)

        let output: SMCKeyData_t
        do {
            output = try callSMC(&input)
        } catch {
            throw SMCError.keyInfoFailed(key, kIOReturnError)
        }

        let typeStr = SMCConnection.uint32ToTypeString(output.keyInfo.dataType)
        return SMCKeyInfo(dataSize: output.keyInfo.dataSize, dataType: typeStr)
    }

    /// Read raw bytes from an SMC key.
    public func readRaw(key: String) throws -> (bytes: [UInt8], type: String, size: UInt32) {
        // Step 1: get key info
        let info = try keyInfo(for: key)

        // Step 2: read the value
        var input = SMCKeyData_t()
        input.key = SMCConnection.keyToUInt32(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = UInt8(SMC_CMD_READ_BYTES)

        let output: SMCKeyData_t
        do {
            output = try callSMC(&input)
        } catch {
            throw SMCError.readFailed(key, kIOReturnError)
        }

        // Extract bytes from the fixed-size C array
        let size = Int(info.dataSize)
        var bytes = [UInt8](repeating: 0, count: size)
        withUnsafePointer(to: output.bytes) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 32) { buf in
                for i in 0..<size {
                    bytes[i] = buf[i]
                }
            }
        }

        return (bytes, info.dataType, info.dataSize)
    }

    /// Read an SMC key and parse it to a typed value.
    public func read(key: String) throws -> SMCValue {
        let (bytes, typeStr, _) = try readRaw(key: key)
        return SMCParser.parse(bytes: bytes, type: typeStr)
    }

    /// Write raw bytes to an SMC key.
    public func writeRaw(key: String, bytes: [UInt8]) throws {
        var input = SMCKeyData_t()
        input.key = SMCConnection.keyToUInt32(key)
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.data8 = UInt8(SMC_CMD_WRITE_BYTES)

        // Copy bytes into the fixed-size C array
        withUnsafeMutablePointer(to: &input.bytes) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: 32) { buf in
                for i in 0..<min(bytes.count, 32) {
                    buf[i] = bytes[i]
                }
            }
        }

        do {
            _ = try callSMC(&input)
        } catch {
            throw SMCError.writeFailed(key, kIOReturnError)
        }
    }

    /// Get the total number of SMC keys available.
    public func keyCount() throws -> Int {
        let val = try read(key: "#KEY")
        if case .uint(let n) = val { return Int(n) }
        return 0
    }
}
