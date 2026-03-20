# DisplayBuddy

A lightweight macOS menu bar app for controlling external display brightness and power state.

## Features

- **Brightness Control** — Adjust external monitor brightness via DDC/CI protocol (Apple Silicon)
- **Built-in Display** — Control built-in display brightness using macOS private APIs
- **Software Brightness** — Gamma-based fallback for monitors without DDC support
- **Power Off / On** — Disable a display so macOS stops using it as a separate screen, and re-enable it anytime from the menu bar
- **Mirror Toggle** — Quickly mirror/unmirror any external display

## How It Works

- External monitor brightness is controlled through DDC/CI commands over I2C (Apple Silicon Macs)
- "Power Off" mirrors the display to the primary screen and blacks it out, so macOS treats your setup as a single display. Windows won't get lost on a screen you're not using
- "Power On" reverses the process — unmirrors and restores the display

## Requirements

- macOS 14.0+
- Apple Silicon Mac
- Swift 5.9+

## Build

```bash
# Clone
git clone https://github.com/dcatmakas/DisplayBuddy.git
cd DisplayBuddy

# Build and create .app bundle
chmod +x build.sh
./build.sh

# Run
open DisplayBuddy.app
```

Or open `Package.swift` in Xcode and build from there.

## License

MIT
