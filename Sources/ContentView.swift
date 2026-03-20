import SwiftUI

struct ContentView: View {
    @ObservedObject var manager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "display.2")
                    .foregroundStyle(.secondary)
                Text("DisplayBuddy")
                    .font(.headline)
                Spacer()
                Button {
                    manager.refreshDisplays()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Refresh displays")
            }
            .padding(.bottom, 4)

            if manager.displays.isEmpty {
                Text("No displays found")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(manager.displays) { display in
                    DisplayRow(display: display, manager: manager)
                }
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding()
        .frame(width: 340)
    }
}

struct DisplayRow: View {
    let display: DisplayInfo
    @ObservedObject var manager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                    .foregroundStyle(display.isPoweredOff ? .red : (display.isBuiltIn ? .blue : .orange))
                Text(display.name)
                    .font(.subheadline.bold())
                Spacer()
                if display.isPoweredOff {
                    Text("Off")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.red.opacity(0.2)))
                        .foregroundStyle(.red)
                } else if display.isMirrored {
                    Text("Mirrored")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
            }

            // Only show brightness controls when display is on
            if !display.isPoweredOff {
                if display.supportsBrightness {
                    HStack(spacing: 8) {
                        Image(systemName: "sun.min")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: manager.brightnessBinding(for: display.id),
                            in: 0...1
                        )
                        Image(systemName: "sun.max.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Int(display.brightness * 100))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 35, alignment: .trailing)
                    }
                } else if !display.isBuiltIn {
                    Text("DDC not supported — software brightness")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Image(systemName: "sun.min")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: manager.softwareBrightnessBinding(for: display.id),
                            in: 0.1...1
                        )
                        Image(systemName: "sun.max.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Int((manager.softwareBrightness[display.id] ?? 1.0) * 100))%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 35, alignment: .trailing)
                    }
                }
            }

            // External display controls
            if !display.isBuiltIn {
                HStack(spacing: 8) {
                    if !display.isPoweredOff {
                        Button {
                            manager.toggleMirror(display.id)
                        } label: {
                            Label(
                                display.isMirrored ? "Unmirror" : "Mirror",
                                systemImage: display.isMirrored ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(display.isMirrored ? .green : .orange)
                        .controlSize(.small)
                    }

                    Button {
                        manager.togglePower(display.id)
                    } label: {
                        Label(
                            display.isPoweredOff ? "Power On" : "Power Off",
                            systemImage: display.isPoweredOff ? "power.circle.fill" : "power.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(display.isPoweredOff ? .green : .red)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(display.isPoweredOff ? Color.red.opacity(0.05) : Color.clear).overlay(
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
        ))
    }
}
