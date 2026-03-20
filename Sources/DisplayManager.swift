import SwiftUI
import CoreGraphics
import AppKit
import Foundation

struct DisplayInfo: Identifiable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    var brightness: Double
    var supportsBrightness: Bool
    var isPoweredOff: Bool
}

class DisplayManager: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var softwareBrightness: [CGDirectDisplayID: Double] = [:]

    private var ddcServices: [CGDirectDisplayID: CFTypeRef] = [:]
    private var ddcMaxBrightness: [CGDirectDisplayID: UInt16] = [:]
    private var servicesDiscovered = false
    private let ddcQueue = DispatchQueue(label: "com.displaybuddy.ddc", qos: .userInitiated)

    // Remember powered-off displays so they stay in UI
    private var poweredOffDisplays: [CGDirectDisplayID: DisplayInfo] = [:]

    // Track last DDC write time to avoid flooding the I2C bus
    private var lastDDCWrite: [CGDirectDisplayID: Date] = [:]
    private let ddcMinInterval: TimeInterval = 0.05

    init() {
        loadDisplayList()
        discoverDDCAsync()
    }

    // MARK: - Display list

    private func loadDisplayList() {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(16, &displayIDs, &displayCount)

        var newDisplays: [DisplayInfo] = []
        var seenIDs = Set<CGDirectDisplayID>()

        for i in 0..<Int(displayCount) {
            let displayID = displayIDs[i]
            seenIDs.insert(displayID)

            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let name = getDisplayName(displayID)
                ?? poweredOffDisplays[displayID]?.name
                ?? (isBuiltIn ? "Built-in Display" : "External Display")

            let existing = displays.first(where: { $0.id == displayID })
            let isPoweredOff = poweredOffDisplays[displayID]?.isPoweredOff
                ?? existing?.isPoweredOff
                ?? false
            let brightness = existing?.brightness ?? (isBuiltIn ? getBuiltInBrightness(displayID) : 0.5)
            let supportsBrightness = existing?.supportsBrightness ?? isBuiltIn

            if !isBuiltIn && softwareBrightness[displayID] == nil {
                softwareBrightness[displayID] = 1.0
            }

            newDisplays.append(DisplayInfo(
                id: displayID,
                name: name,
                isBuiltIn: isBuiltIn,
                brightness: brightness,
                supportsBrightness: supportsBrightness,
                isPoweredOff: isPoweredOff
            ))
        }

        for (id, info) in poweredOffDisplays where !seenIDs.contains(id) {
            newDisplays.append(info)
        }

        displays = newDisplays
    }

    // MARK: - DDC Discovery (background)

    private func discoverDDCAsync() {
        ddcQueue.async { [weak self] in
            guard let self else { return }

            let avServices = DDCService.discoverServices()

            var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
            var displayCount: UInt32 = 0
            CGGetOnlineDisplayList(16, &displayIDs, &displayCount)

            var externalIndex = 0
            var newServices: [CGDirectDisplayID: CFTypeRef] = [:]
            var newMaxBrightness: [CGDirectDisplayID: UInt16] = [:]
            var brightnessUpdates: [(CGDirectDisplayID, Double)] = []

            for i in 0..<Int(displayCount) {
                let displayID = displayIDs[i]
                let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0

                if !isBuiltIn && externalIndex < avServices.count {
                    let service = avServices[externalIndex]
                    newServices[displayID] = service
                    externalIndex += 1

                    if let value = DDCService.readBrightness(service: service) {
                        newMaxBrightness[displayID] = value.max
                        let brightness = Double(value.current) / Double(max(value.max, 1))
                        brightnessUpdates.append((displayID, brightness))
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (id, svc) in newServices { self.ddcServices[id] = svc }
                for (id, max) in newMaxBrightness { self.ddcMaxBrightness[id] = max }
                self.servicesDiscovered = true

                for (displayID, brightness) in brightnessUpdates {
                    if let index = self.displays.firstIndex(where: { $0.id == displayID }) {
                        self.displays[index].brightness = brightness
                        self.displays[index].supportsBrightness = true
                    }
                }
            }
        }
    }

    // MARK: - Refresh

    func refreshDisplays() {
        loadDisplayList()
        for i in displays.indices where displays[i].isBuiltIn {
            displays[i].brightness = getBuiltInBrightness(displays[i].id)
        }
        if !servicesDiscovered {
            discoverDDCAsync()
        }
    }

    // MARK: - Brightness Bindings

    func brightnessBinding(for id: CGDirectDisplayID) -> Binding<Double> {
        Binding(
            get: { [weak self] in
                self?.displays.first { $0.id == id }?.brightness ?? 0.5
            },
            set: { [weak self] newValue in
                self?.setBrightness(id, value: newValue)
            }
        )
    }

    func softwareBrightnessBinding(for id: CGDirectDisplayID) -> Binding<Double> {
        Binding(
            get: { [weak self] in
                self?.softwareBrightness[id] ?? 1.0
            },
            set: { [weak self] newValue in
                self?.setSoftwareBrightness(id, value: newValue)
            }
        )
    }

    // MARK: - Brightness Control

    func setBrightness(_ id: CGDirectDisplayID, value: Double) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        displays[index].brightness = value

        let isBuiltIn = displays[index].isBuiltIn

        if isBuiltIn {
            // Built-in display: apply immediately (fast API)
            _ = DisplayServicesSetBrightness(id, Float(value))
        } else if let service = ddcServices[id] {
            // DDC: rate-limit to avoid flooding I2C bus
            let now = Date()
            if let last = lastDDCWrite[id], now.timeIntervalSince(last) < ddcMinInterval {
                // Schedule the latest value after the minimum interval
                let delay = ddcMinInterval - now.timeIntervalSince(last)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    // Only fire if the value hasn't changed again
                    if self.displays.first(where: { $0.id == id })?.brightness == value {
                        self.lastDDCWrite[id] = Date()
                        let maxVal = self.ddcMaxBrightness[id] ?? 100
                        let ddcValue = UInt16(value * Double(maxVal))
                        self.ddcQueue.async {
                            DDCService.writeBrightness(service: service, value: ddcValue)
                        }
                    }
                }
                return
            }

            lastDDCWrite[id] = now
            let maxVal = ddcMaxBrightness[id] ?? 100
            let ddcValue = UInt16(value * Double(maxVal))
            ddcQueue.async {
                DDCService.writeBrightness(service: service, value: ddcValue)
            }
        }
    }

    func setSoftwareBrightness(_ id: CGDirectDisplayID, value: Double) {
        softwareBrightness[id] = value
        // Apply immediately
        let gamma = Float(max(value, 0.01))
        CGSetDisplayTransferByFormula(
            id,
            0, gamma, 1.0,
            0, gamma, 1.0,
            0, gamma, 1.0
        )
    }

    // MARK: - Power Control (mirror + blackout + DDC)

    func togglePower(_ id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let isPoweredOff = displays[index].isPoweredOff

        if isPoweredOff {
            // === POWER ON ===
            var config: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&config)
            CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
            CGCompleteDisplayConfiguration(config, .forSession)

            CGDisplayRestoreColorSyncSettings()

            poweredOffDisplays.removeValue(forKey: id)
            displays[index].isPoweredOff = false

            ddcQueue.async { [weak self] in
                if let service = self?.ddcServices[id] {
                    DDCService.writeVCP(service: service, code: 0xD6, value: 1)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.loadDisplayList()
            }
        } else {
            // === POWER OFF ===
            let mainDisplay = CGMainDisplayID()

            let mirrorTarget: CGDirectDisplayID
            if id == mainDisplay {
                let otherDisplay = displays.first(where: { $0.id != id && !$0.isPoweredOff })?.id ?? id
                mirrorTarget = otherDisplay
            } else {
                mirrorTarget = mainDisplay
            }

            displays[index].isPoweredOff = true
            poweredOffDisplays[id] = displays[index]

            if id != mirrorTarget {
                var config: CGDisplayConfigRef?
                CGBeginDisplayConfiguration(&config)
                CGConfigureDisplayMirrorOfDisplay(config, id, mirrorTarget)
                CGCompleteDisplayConfiguration(config, .forSession)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                let zeroTable = [CGGammaValue](repeating: 0.0, count: 256)
                CGSetDisplayTransferByTable(id, 256, zeroTable, zeroTable, zeroTable)
                self?.loadDisplayList()
            }

            ddcQueue.async { [weak self] in
                if let service = self?.ddcServices[id] {
                    DDCService.writeVCP(service: service, code: 0xD6, value: 5)
                }
            }
        }
    }

    // MARK: - Helpers

    private func getDisplayName(_ displayID: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               screenNumber == displayID {
                return screen.localizedName
            }
        }
        return nil
    }

    private func getBuiltInBrightness(_ displayID: CGDirectDisplayID) -> Double {
        var br: Float = 0.5
        if DisplayServicesGetBrightness(displayID, &br) == 0 {
            return Double(br)
        }
        return 0.5
    }
}

// MARK: - Private DisplayServices Framework (loaded dynamically)

private let displayServicesHandle: UnsafeMutableRawPointer? = {
    dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
}()

private typealias DSGetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
private typealias DSSetBrightness = @convention(c) (UInt32, Float) -> Int32

func DisplayServicesGetBrightness(_ display: CGDirectDisplayID, _ brightness: UnsafeMutablePointer<Float>) -> Int32 {
    guard let handle = displayServicesHandle,
          let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return -1 }
    let fn = unsafeBitCast(sym, to: DSGetBrightness.self)
    return fn(display, brightness)
}

func DisplayServicesSetBrightness(_ display: CGDirectDisplayID, _ brightness: Float) -> Int32 {
    guard let handle = displayServicesHandle,
          let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return -1 }
    let fn = unsafeBitCast(sym, to: DSSetBrightness.self)
    return fn(display, brightness)
}
