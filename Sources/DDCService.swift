import Foundation
import IOKit

// MARK: - DDC/CI Service for Apple Silicon

class DDCService {

    // MARK: - Service Discovery

    /// Discover all DDC-capable external display services (Apple Silicon)
    static func discoverServices() -> [CFTypeRef] {
        var result: [CFTypeRef] = []
        var iterator: io_iterator_t = 0

        guard let matching = IOServiceMatching("DCPAVServiceProxy") else {
            return result
        }

        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        ) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            if let avService = avServiceCreate(service) {
                result.append(avService)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return result
    }

    // MARK: - Read VCP

    /// Read brightness (VCP code 0x10)
    static func readBrightness(service: CFTypeRef) -> (current: UInt16, max: UInt16)? {
        return readVCP(service: service, code: 0x10)
    }

    /// Read a VCP feature value from the display
    static func readVCP(service: CFTypeRef, code: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let writeFn = i2cWriteFn, let readFn = i2cReadFn else { return nil }

        // Build DDC/CI Get VCP Feature request
        var request: [UInt8] = [
            0x82,   // 0x80 | 2 (length = 2 bytes follow)
            0x01,   // Get VCP Feature opcode
            code    // VCP code
        ]

        // Checksum: XOR of destination address, source address, and all data
        var checksum: UInt8 = 0x6E ^ 0x51
        for byte in request { checksum ^= byte }
        request.append(checksum)

        // Send request via I2C
        guard request.withUnsafeMutableBufferPointer({ buf in
            writeFn(service, 0x37, 0x51, buf.baseAddress!, UInt32(buf.count))
        }) == KERN_SUCCESS else {
            return nil
        }

        // Wait for display to process the request
        usleep(50_000)

        // Read response (11 bytes expected)
        var response = [UInt8](repeating: 0, count: 11)
        guard response.withUnsafeMutableBufferPointer({ buf in
            readFn(service, 0x37, 0x51, buf.baseAddress!, UInt32(buf.count))
        }) == KERN_SUCCESS else {
            return nil
        }

        // Validate response
        guard response[0] == 0x88,  // length | 0x80
              response[1] == 0x02,  // Get VCP Feature Reply opcode
              response[2] == 0x00   // No error
        else {
            return nil
        }

        let maxValue = (UInt16(response[5]) << 8) | UInt16(response[6])
        let currentValue = (UInt16(response[7]) << 8) | UInt16(response[8])

        return (current: currentValue, max: maxValue)
    }

    // MARK: - Write VCP

    /// Set brightness (VCP code 0x10)
    static func writeBrightness(service: CFTypeRef, value: UInt16) {
        writeVCP(service: service, code: 0x10, value: value)
    }

    /// Write a VCP feature value to the display
    @discardableResult
    static func writeVCP(service: CFTypeRef, code: UInt8, value: UInt16) -> Bool {
        guard let writeFn = i2cWriteFn else { return false }

        var data: [UInt8] = [
            0x84,                   // 0x80 | 4 (length = 4 bytes follow)
            0x03,                   // Set VCP Feature opcode
            code,                   // VCP code
            UInt8(value >> 8),      // Value high byte
            UInt8(value & 0xFF)     // Value low byte
        ]

        // Checksum
        var checksum: UInt8 = 0x6E ^ 0x51
        for byte in data { checksum ^= byte }
        data.append(checksum)

        let result = data.withUnsafeMutableBufferPointer { buf in
            writeFn(service, 0x37, 0x51, buf.baseAddress!, UInt32(buf.count))
        }

        usleep(50_000)
        return result == KERN_SUCCESS
    }
}

// MARK: - Dynamically loaded IOAVService functions

private let ioKitHandle: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
}()

private typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
private typealias ReadI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> IOReturn
private typealias WriteI2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutablePointer<UInt8>, UInt32) -> IOReturn

private let avServiceCreateFn: CreateWithServiceFn? = {
    guard let handle = ioKitHandle,
          let sym = dlsym(handle, "IOAVServiceCreateWithService") else { return nil }
    return unsafeBitCast(sym, to: CreateWithServiceFn.self)
}()

private let i2cReadFn: ReadI2CFn? = {
    guard let handle = ioKitHandle,
          let sym = dlsym(handle, "IOAVServiceReadI2C") else { return nil }
    return unsafeBitCast(sym, to: ReadI2CFn.self)
}()

private let i2cWriteFn: WriteI2CFn? = {
    guard let handle = ioKitHandle,
          let sym = dlsym(handle, "IOAVServiceWriteI2C") else { return nil }
    return unsafeBitCast(sym, to: WriteI2CFn.self)
}()

private func avServiceCreate(_ service: io_service_t) -> CFTypeRef? {
    guard let fn = avServiceCreateFn else { return nil }
    return fn(kCFAllocatorDefault, service)?.takeRetainedValue()
}
