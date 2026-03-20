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
    var isMirrored: Bool
    var isPoweredOff: Bool
}

class DisplayManager: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var softwareBrightness: [CGDirectDisplayID: Double] = [:]

    private var ddcServices: [CGDirectDisplayID: CFTypeRef] = [:]
    private var ddcMaxBrightness: [CGDirectDisplayID: UInt16] = [:]
    private var debounceTimers: [CGDirectDisplayID: Timer] = [:]
    private var servicesDiscovered = false
    private let ddcQueue = DispatchQueue(label: "com.displaybuddy.ddc", qos: .userInitiated)

    // Remember powered-off displays so they stay in UI
    private var poweredOffDisplays: [CGDirectDisplayID: DisplayInfo] = [:]

    init() {
        loadDisplayList()
        discoverDDCAsync()
    }

    // MARK: - Display list (uses Online list to include mirrored displays)

    private func loadDisplayList() {
        // CGGetOnlineDisplayList returns ALL connected displays, including mirrored ones
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
            let isMirrored = CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay

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
                isMirrored: isMirrored,
                isPoweredOff: isPoweredOff
            ))
        }

        // Also add any powered-off displays that disappeared from the online list
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
                // Merge with existing services (don't lose powered-off display services)
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

        debounceTimers[id]?.invalidate()
        debounceTimers[id] = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            self?.commitBrightness(id, value: value)
        }
    }

    private func commitBrightness(_ id: CGDirectDisplayID, value: Double) {
        let isBuiltIn = displays.first(where: { $0.id == id })?.isBuiltIn ?? false

        ddcQueue.async { [weak self] in
            if isBuiltIn {
                _ = DisplayServicesSetBrightness(id, Float(value))
            } else if let service = self?.ddcServices[id] {
                let maxVal = self?.ddcMaxBrightness[id] ?? 100
                let ddcValue = UInt16(value * Double(maxVal))
                DDCService.writeBrightness(service: service, value: ddcValue)
            }
        }
    }

    func setSoftwareBrightness(_ id: CGDirectDisplayID, value: Double) {
        softwareBrightness[id] = value

        debounceTimers[id]?.invalidate()
        debounceTimers[id] = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in
            let gamma = Float(max(value, 0.01))
            CGSetDisplayTransferByFormula(
                id,
                0, gamma, 1.0,
                0, gamma, 1.0,
                0, gamma, 1.0
            )
        }
    }

    // MARK: - Mirror / Disable Display

    func toggleMirror(_ id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let currentlyMirrored = displays[index].isMirrored

        var config: CGDisplayConfigRef?
        CGBeginDisplayConfiguration(&config)

        if currentlyMirrored {
            CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
        } else {
            let mainDisplay = CGMainDisplayID()
            if id != mainDisplay {
                CGConfigureDisplayMirrorOfDisplay(config, id, mainDisplay)
            }
        }

        CGCompleteDisplayConfiguration(config, .forSession)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.loadDisplayList()
        }
    }

    // MARK: - Power Control (mirror + blackout + DDC)

    func togglePower(_ id: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == id }) else { return }
        let isPoweredOff = displays[index].isPoweredOff

        if isPoweredOff {
            // === POWER ON ===
            // 1. Un-mirror
            var config: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&config)
            CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
            CGCompleteDisplayConfiguration(config, .forSession)

            // 2. Restore gamma
            CGDisplayRestoreColorSyncSettings()

            // 3. Remove from powered-off tracking
            poweredOffDisplays.removeValue(forKey: id)
            displays[index].isPoweredOff = false
            displays[index].isMirrored = false

            // 4. DDC power on
            ddcQueue.async { [weak self] in
                if let service = self?.ddcServices[id] {
                    DDCService.writeVCP(service: service, code: 0xD6, value: 1)
                }
            }

            // 5. Refresh display list after settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.loadDisplayList()
            }
        } else {
            // === POWER OFF ===
            let mainDisplay = CGMainDisplayID()

            // If this IS the main display, we need to pick another as main first
            // (mirror target must be the main display)
            let mirrorTarget: CGDirectDisplayID
            if id == mainDisplay {
                // Find another non-built-in display or built-in to be the target
                let otherDisplay = displays.first(where: { $0.id != id && !$0.isPoweredOff })?.id ?? id
                mirrorTarget = otherDisplay
            } else {
                mirrorTarget = mainDisplay
            }

            // 1. Save display info before it disappears
            displays[index].isPoweredOff = true
            displays[index].isMirrored = true
            poweredOffDisplays[id] = displays[index]

            // 2. Mirror (makes macOS treat it as same desktop)
            if id != mirrorTarget {
                var config: CGDisplayConfigRef?
                CGBeginDisplayConfiguration(&config)
                CGConfigureDisplayMirrorOfDisplay(config, id, mirrorTarget)
                CGCompleteDisplayConfiguration(config, .forSession)
            }

            // 3. Blackout after mirror settles
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                let zeroTable = [CGGammaValue](repeating: 0.0, count: 256)
                CGSetDisplayTransferByTable(id, 256, zeroTable, zeroTable, zeroTable)
                // Reload list so mirrored display still appears
                self?.loadDisplayList()
            }

            // 4. DDC standby
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
