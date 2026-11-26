//
//  FNYSystemSensors.swift
//  Fanny
//
//  Apple Silicon-compatible sensor reader.
//
//  The SMC is still present on Apple Silicon, but the keys and value types
//  differ from Intel Macs (fan RPMs and temperatures are usually `flt ` values
//  rather than `fpe2`/integer values). This reader asks the SMC for each key's
//  type before decoding it, and discovers temperature keys instead of assuming
//  a fixed Intel key list.
//

import Foundation
import IOKit

// MARK: - SMC wire format

private typealias SMCBytes32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

/// Mirrors the 80-byte `SMCKeyData_t` used by the AppleSMC user client.
///
/// `keyInfo` is deliberately spelled out field-by-field. Nested Swift structs
/// and tuples drop their tail padding, which shifts every following field and
/// makes the kernel reject the call with `kIOReturnBadArgument`.
private struct SMCKeyData {
    var key: UInt32 = 0

    var versionMajor: UInt8 = 0
    var versionMinor: UInt8 = 0
    var versionBuild: UInt8 = 0
    var versionReserved: UInt8 = 0
    var versionRelease: UInt16 = 0

    var limitVersion: UInt16 = 0
    var limitLength: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0

    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    var keyInfoPadding: (UInt8, UInt8, UInt8) = (0, 0, 0)

    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var padding: UInt8 = 0
    var data32: UInt32 = 0

    var bytes: SMCBytes32 = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

private enum SMCSelector {
    static let handleYPCEvent: UInt32 = 2
    static let readBytes: UInt8 = 5
    static let getKeyFromIndex: UInt8 = 8
    static let getKeyInfo: UInt8 = 9
}

private struct SMCValue {
    let type: String
    let bytes: [UInt8]

    var number: Double? {
        FNYSystemSensors.decode(type: type, bytes: bytes)
    }
}

// MARK: - Sensor reader

final class FNYSystemSensors {

    enum TemperatureKind: String {
        case cpu
        case gpu
    }

    static let shared: FNYSystemSensors = FNYSystemSensors()

    private var connection: io_connect_t?
    private var temperatureKeys: [TemperatureKind: [String]] = [:]

    // MARK: - Init

    private init() {
        precondition(
            MemoryLayout<SMCKeyData>.stride == 80,
            "SMCKeyData is \(MemoryLayout<SMCKeyData>.stride) bytes; AppleSMC requires 80"
        )

        let service: io_service_t = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return }
        self.connection = connection

        discoverTemperatureKeys()
    }

    deinit {
        if let connection: io_connect_t = connection {
            IOServiceClose(connection)
        }
    }

    // MARK: - Public API

    func fans() -> [Fan] {
        guard let count: Int = readValue(key: "FNum")?.number.map({ Int($0) }),
              count > 0,
              count <= 16 else { return [] }

        var fans: [Fan] = []
        for index in 0..<count {
            let identifier: String = "F\(index)"
            fans.append(
                Fan(identifier: index,
                    currentRPM: integerValue(key: identifier + "Ac"),
                    minimumRPM: integerValue(key: identifier + "Mn"),
                    maximumRPM: integerValue(key: identifier + "Mx"),
                    targetRPM: integerValue(key: identifier + "Tg"))
            )
        }
        return fans
    }

    func availableTemperatureKeys(for kind: TemperatureKind) -> [String] {
        return temperatureKeys[kind] ?? []
    }

    func cpuTemperature(key: String? = nil) -> Temperature? {
        return temperature(key: key, kind: .cpu)
    }

    func gpuTemperature(key: String? = nil) -> Temperature? {
        return temperature(key: key, kind: .gpu)
    }

    // MARK: - Temperature discovery

    private func discoverTemperatureKeys() {
        var candidates: [String] = []

        for index in 0..<2048 {
            var input: SMCKeyData = SMCKeyData()
            input.data8 = SMCSelector.getKeyFromIndex
            input.data32 = UInt32(index)

            guard let output: SMCKeyData = call(&input),
                  let key: String = FNYSystemSensors.fourCC(output.key),
                  let type: String = readKeyType(key: key),
                  FNYSystemSensors.isTemperatureType(type) else { continue }

            candidates.append(key)
        }

        // Apple Silicon uses Tp*/Te* for CPU clusters and Tg* for the GPU.
        // TC* keys are kept as a fallback for Intel Macs and older hardware.
        let cpuPreferred: [String] = candidates.filter({
            $0.hasPrefix("Tp") || $0.hasPrefix("Te")
        })
        let cpuFallback: [String] = candidates.filter({ $0.hasPrefix("TC") })
        let gpu: [String] = candidates.filter({
            $0.hasPrefix("Tg") || $0.hasPrefix("TG")
        })

        temperatureKeys[.cpu] = (cpuPreferred.isEmpty ? cpuFallback : cpuPreferred).sorted()
        temperatureKeys[.gpu] = gpu.sorted()
    }

    private func temperature(key: String?, kind: TemperatureKind) -> Temperature? {
        let keys: [String]
        if let key: String = key, !key.isEmpty {
            keys = [key]
        }
        else {
            keys = availableTemperatureKeys(for: kind)
        }

        let celsiusValues: [Double] = keys.compactMap({
            readValue(key: $0)?.number
        }).filter({ $0 >= 10.0 && $0 <= 125.0 })

        guard !celsiusValues.isEmpty else { return nil }

        let average: Double = celsiusValues.reduce(0.0, +) / Double(celsiusValues.count)
        return Temperature(celsius: average,
                           fahrenheit: Temperature.fahrenheit(celsius: average),
                           kelvin: Temperature.kelvin(celsius: average))
    }

    // MARK: - SMC reads

    private func integerValue(key: String) -> Int? {
        return readValue(key: key)?.number.map({ Int($0.rounded()) })
    }

    private func readValue(key: String) -> SMCValue? {
        guard let info: (size: UInt32, type: String) = readKeyInfo(key: key) else { return nil }

        var input: SMCKeyData = SMCKeyData()
        input.key = FNYSystemSensors.keyCode(key) ?? 0
        input.data8 = SMCSelector.readBytes
        input.dataSize = info.size

        guard let output: SMCKeyData = call(&input) else { return nil }

        let byteCount: Int = min(Int(info.size), MemoryLayout<SMCBytes32>.size)
        let bytes: [UInt8] = withUnsafeBytes(of: output.bytes) {
            Array($0.prefix(byteCount))
        }

        return SMCValue(type: info.type, bytes: bytes)
    }

    private func readKeyInfo(key: String) -> (size: UInt32, type: String)? {
        guard let keyCode: UInt32 = FNYSystemSensors.keyCode(key) else { return nil }

        var input: SMCKeyData = SMCKeyData()
        input.key = keyCode
        input.data8 = SMCSelector.getKeyInfo

        guard let output: SMCKeyData = call(&input),
              let type: String = FNYSystemSensors.fourCC(output.dataType) else { return nil }

        return (output.dataSize, type)
    }

    private func readKeyType(key: String) -> String? {
        return readKeyInfo(key: key)?.type
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        guard let connection: io_connect_t = connection else { return nil }

        var output: SMCKeyData = SMCKeyData()
        var outputSize: Int = MemoryLayout<SMCKeyData>.stride

        let result: kern_return_t = IOConnectCallStructMethod(
            connection,
            SMCSelector.handleYPCEvent,
            &input,
            MemoryLayout<SMCKeyData>.stride,
            &output,
            &outputSize
        )

        guard result == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    // MARK: - Decoding

    private static func isTemperatureType(_ type: String) -> Bool {
        return type == "flt " || type == "sp78" || type == "fpe2"
    }

    fileprivate static func decode(type: String, bytes: [UInt8]) -> Double? {
        guard !bytes.isEmpty else { return nil }

        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            var value: Float = 0.0
            memcpy(&value, bytes, 4)
            guard value.isFinite else { return nil }
            return Double(value)

        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1])) / 4.0

        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw: Int16 = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 256.0

        case "ui8 ":
            return Double(bytes[0])

        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))

        default:
            return nil
        }
    }

    // MARK: - FourCC helpers

    private static func keyCode(_ key: String) -> UInt32? {
        guard key.utf8.count == 4 else { return nil }
        return key.utf8.reduce(0, { ($0 << 8) | UInt32($1) })
    }

    private static func fourCC(_ value: UInt32) -> String? {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

}
