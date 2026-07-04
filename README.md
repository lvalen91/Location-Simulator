# Recreation of [Location Simulator by Schlaubischlump](https://github.com/Schlaubischlump/LocationSimulator)

#3 Location Simulator

A native macOS app for simulating GPS locations on USB-connected iPhones (iOS 17+). Built with SwiftUI and MapKit, following Apple Maps design language.

![macOS](https://img.shields.io/badge/macOS-27.0+-blue) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **Teleport** — Click or long-press anywhere on the map to instantly set your iPhone's GPS location
- **Route Navigation** — Search From/To destinations with autocomplete, calculate routes, and simulate movement along them
- **Transport Modes** — Walk, cycle, or drive at configurable speeds
- **Save & Reuse Routes** — Save favorite routes and access recent ones from the sidebar
- **Right-Click Context Menu** — Teleport, set route endpoints, or copy coordinates from any map point
- **Drag Marker** — Drag the location pin to fine-tune position
- **USB Device Management** — Detect and connect to iPhones over USB

## Requirements

- **macOS 27.0+**
- **Xcode 27+** (to build from source)
- **USB-connected iPhone** running iOS 17+ (with Developer Mode enabled)
- **pymobiledevice3** — Python tool for communicating with iOS devices. You do **not** need to install this manually:
  - **Release `.app`:** ships with a bundled copy (nothing to install).
  - **Built from source:** if it's missing, the app's **Devices** panel offers a one-click **Install with Homebrew** (runs `brew install pipx && pipx install pymobiledevice3`).

### Installing pymobiledevice3 manually (optional)

```bash
# Via pipx (recommended)
pipx install pymobiledevice3

# Or via pip
pip3 install pymobiledevice3
```

The tunneld service must be running for device communication:

```bash
# Start tunneld (requires admin privileges)
sudo pymobiledevice3 remote tunneld
```

The app will attempt to start tunneld automatically if it's not running.

## Build

### Using Xcode

Open `LocationSimulator2.xcodeproj` and build (⌘B).

### Using XcodeGen + Command Line

```bash
# Regenerate project (if you modify project.yml)
xcodegen generate

# Build
xcodebuild -project LocationSimulator2.xcodeproj \
  -scheme LocationSimulator2 \
  -configuration Release build \
  CODE_SIGNING_ALLOWED=NO
```

The built app will be in `DerivedData/.../Build/Products/Release/Location Simulator.app`.

### Building a zero-install release (bundled pymobiledevice3)

To ship a `.app` that needs no `pymobiledevice3` install on the user's machine,
freeze it into the bundle before building:

```bash
./Tools/bundle-dependencies.sh   # PyInstaller-freezes pymobiledevice3 + the daemon into Resources/vendor/
xcodegen generate                # picks up Resources/vendor as a folder reference
xcodebuild -project LocationSimulator2.xcodeproj -scheme LocationSimulator2 \
  -configuration Release build CODE_SIGNING_ALLOWED=NO
```

The bridge automatically prefers the bundled binaries when present and falls
back to a system/`pipx` install otherwise. The frozen binaries are arm64-only
(macOS 27 dropped Intel) and are not committed — regenerate them per release.
`tunneld` still requires admin privileges at runtime, and the device's Developer
Disk Image is still downloaded on first use.

## Install from Release

1. Download `Location.Simulator.dmg` from [Releases](../../releases)
2. Open the DMG and drag **Location Simulator** to Applications
3. Right-click → **Open** on first launch (the app is unsigned)

Or remove quarantine via terminal:
```bash
xattr -cr "/Applications/Location Simulator.app"
```

## Usage

1. Connect your iPhone via USB
2. Launch Location Simulator
3. Click **Scan** in the toolbar to detect your device
4. Click the device in the sidebar to connect
5. Long-press or right-click the map to teleport, or use the search fields to plan a route
6. Click **Go** on a calculated route to start simulated navigation

## Architecture

```
Sources/
├── App/                    # @main entry point
├── Models/                 # TransportMode, SavedRoute, DeviceInfo
├── ViewModels/             # AppState (@Observable), SearchCompleterManager
├── Views/
│   ├── ContentView         # NavigationSplitView + toolbar
│   ├── Sidebar/            # Device list, saved/recent routes
│   ├── Map/                # MKMapView via NSViewRepresentable
│   ├── Search/             # From/To route search with autocomplete
│   ├── Routes/             # Calculated route results panel
│   └── Controls/           # Speed control
├── Services/
│   ├── Pymobiledevice3Bridge   # Python daemon management, USB discovery
│   ├── LocationSpoofingService # High-level spoofing API
│   └── NavigationEngine        # Timer-based route follower
├── Extensions/             # CLLocationCoordinate2D routing helpers
└── Resources/
    └── location_daemon.py  # Persistent DVT connection script
```

Zero external dependencies — only system frameworks (SwiftUI, MapKit, CoreLocation).

## License

MIT
