# Elgin Menu Bar

A native macOS menu bar app for compatible Elgin Wi-Fi air conditioners and smart lights. Adjust the room temperature, switch on a light, and choose a color without reaching for your phone or remote.

I built Elgin Menu Bar with SwiftUI and AppKit, using TinyTuya to communicate with devices over the local network.

## Controls

| Air conditioner | Lighting |
| --- | --- |
| Power and target temperature | Power and brightness |
| Operating mode and fan speed | White and color modes |
| Eco and sleep modes | Color presets and a hue slider |
| Horizontal and vertical swing | Warm-to-cool white temperature |

Available controls depend on the device's reported capabilities. The app follows your macOS language setting, with English and Portuguese interfaces. Click the menu bar icon to open the panel; click it again to close it. Right-click the icon to quit.

## Tested devices

| Device | Tuya LAN protocol | Status |
| --- | --- | --- |
| Elgin Eco III Wi-Fi inverter air conditioner, 9,000 BTU | 3.5 | Local connection and temperature control confirmed |
| Elgin RGB smart bulb | 3.3 | Local connection and power control confirmed |

The bulb's exact model number is not recorded. Other Elgin models may use different protocols or control fields. Include your model and protocol version when reporting compatibility.

## Requirements

- macOS 13 or later to run the app.
- Xcode with the macOS 27 SDK to build the current source, which uses the native menu bar selection API on macOS 27 and retains a fallback for earlier versions.
- Python 3.9 or later for discovery. Python 3.13 with a compatible OpenSSL build is recommended for the cloud setup helper.
- One compatible Tuya-based air conditioner and one compatible Tuya-based light on the same local network as your Mac.
- A Tuya Cloud project linked to both devices, to retrieve their local keys and control specifications during setup.

## Get started

Clone the repository:

```sh
git clone https://github.com/adriannecastro/elgin-menu-bar.git
cd elgin-menu-bar
```

Follow the [setup guide](docs/SETUP.md) to discover your devices, retrieve their local keys, and download their control specifications. The current setup helper uses the **Western America (`us`)** Tuya data center and expects exactly two discovered devices.

The setup creates the Python environment at `local/cloud-venv/` and saves the device configuration under `local/`. Complete those steps before launching the app.

## Build and run

From the repository directory:

```sh
scripts/build-macos.sh
open 'local/Elgin Menu Bar.app'
```

The build script creates a locally signed app bundle under `local/`. Keep the repository in place: the app uses its Python bridge, environment, and device configuration at runtime. This build is not a standalone installer.

You can also open `Package.swift` in Xcode, select the **ElginMenuBar** scheme and **My Mac**, and run it after completing setup.

## Compatibility and limits

- The controller expects one air conditioner in Tuya category `kt` and one light in category `dj`. Other device combinations require code changes.
- Discovery alone does not establish support. The app needs valid local keys and a compatible device schema to read and change controls.
- Temperature adjustments require the air conditioner to use Celsius. The app restricts the range to 16–32 °C and applies any narrower limits reported by the device schema.
- The app polls device state every 10 seconds. Connection failures can delay confirmation of a change.
- Earlier macOS versions use the fallback menu bar behavior; the current UI checks ran on macOS 27.

## Privacy and local storage

Device control uses your local network. During setup, the helpers query Tuya Cloud for local keys and device specifications. They prompt for cloud credentials on each run and do not save those credentials.

The ignored `local/` directory contains device keys, IDs, IP addresses, discovery results, schemas, and status snapshots. Keep that directory private. Do not include it in screenshots, issues, pull requests, or shared copies of the project.

## Offline checks

Run the controller tests with the Python environment created during setup:

```sh
local/cloud-venv/bin/python -m unittest discover -s tests -p 'test_*.py'
```

These tests use fake devices and do not access your network or send commands to your appliances.

## Contributing

Issues and pull requests are welcome. For a bug report, include:

- Your macOS and Xcode versions.
- The affected device's model and Tuya LAN protocol version, if known.
- Steps to reproduce and the behavior you expected.
- An error message or screenshot with credentials and device identifiers removed.

Write contributions in English and preserve the app's English and Portuguese localization. Keep local keys, cloud secrets, device IDs, network addresses, and private diagnostic files out of public reports.

## References

- [Setup guide](docs/SETUP.md)
- [Technical references](docs/REFERENCES.md)

## License

[MIT](LICENSE). Copyright © 2026 Adrianne Castro.

Elgin Menu Bar is an independent community project, unaffiliated with Elgin or Tuya.
