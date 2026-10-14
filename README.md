# Elgin Menu Bar

I built Elgin Menu Bar to give Mac users a quick way to operate compatible Elgin Wi-Fi air conditioners and smart lights over their local network. The native menu bar app provides quick access to power, temperature, operating mode, fan and airflow settings for the air conditioner, plus power, brightness, color, and white-light temperature for a supported RGB bulb.

The app uses SwiftUI/AppKit for its interface and TinyTuya for local device communication. A small Python bridge reads the device state and sends the commands selected in the menu bar. Device credentials stay in local files on your Mac and are excluded from Git.

## Compatibility

- macOS 13 or later, with Xcode or the Swift toolchain installed.
- Python 3.9 or later for discovery; Python 3.13 with a compatible OpenSSL installation is recommended for the Tuya Cloud setup helper.
- Elgin Wi-Fi devices that use compatible Tuya LAN protocols and expose supported controls.
- The current controller expects one Tuya air conditioner (`kt`) and one Tuya light (`dj`). It has been developed with an Elgin Eco III Wi-Fi air conditioner and an Elgin RGB bulb. Other models may expose different capabilities and need schema or mapping changes.
- The cloud key helper currently uses the Tuya Western America (`us`) data center and expects exactly two discovered devices: one air conditioner and one light.

Compatibility depends on each device's Tuya protocol version and data model. A device appearing in discovery does not guarantee that every control is supported.

## Get started

1. Clone this repository and open `Package.swift` in Xcode.
2. Discover devices on the same local network and set up the local keys and schema. Follow [Setup](docs/SETUP.md).
3. Build and run `ElginMenuBar` for **My Mac** in Xcode, or build and launch from Terminal:

   ```sh
   scripts/build-macos.sh
   open 'local/Elgin Menu Bar.app' --args --show
   ```

The menu bar app follows the macOS language setting. It polls device status and only sends commands after you interact with a control.

## Privacy and credentials

This project communicates with configured devices on your local network. The setup helper uses Tuya Cloud only to retrieve local keys and device specifications. It does not store Tuya Cloud credentials. Local keys, device IDs, discovery results, schemas, and status snapshots are kept under the ignored `local/` directory. Never commit or share those files.

## References

- [Technical references](docs/REFERENCES.md)

## License

This project is licensed under the [MIT License](LICENSE).

Elgin Menu Bar is an independent community project and is not affiliated with or endorsed by Elgin or Tuya.
