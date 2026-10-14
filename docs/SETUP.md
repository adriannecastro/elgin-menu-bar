# Setup

This guide prepares a local checkout for the current configuration: one supported Tuya air conditioner and one supported Tuya light on the same LAN as your Mac.

## 1. Discover devices

Install the Python dependency in a virtual environment and run active discovery:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python discover.py --active --seconds 25
```

Active discovery sends Tuya identity requests on the local network; it does not read state or send control commands. The result is saved to `local/discovery.json`, which is ignored by Git. If macOS asks, allow local network access for the process running the script.

## 2. Retrieve local device keys

The current helper expects the two devices to be linked to a Tuya Cloud project and uses the **Western America (`us`)** data center. It also expects exactly two discovered devices, one air conditioner and one light. Other Tuya regions or device combinations need changes to the helper before use.

Install Python 3.13 with a compatible OpenSSL build if your system Python cannot make the HTTPS request, then create the cloud environment:

```sh
python3.13 -m venv local/cloud-venv
local/cloud-venv/bin/python -m pip install -r requirements.txt
open scripts/setup-local-keys.command
```

The helper prompts for Tuya **Access ID / Client ID** and **Access Secret / Client Secret** in Terminal without echoing the text. It uses the credentials only for that run and does not save them. It writes the local keys to `local/devices.json` with restrictive file permissions. Do not share or commit this file.

## 3. Retrieve the device schema

Run `scripts/fetch-device-schema.command` and enter the Tuya Cloud credentials again when prompted. The helper saves the model and device schema under `local/`; the credentials are not saved. This cloud query does not send commands to the devices.

## 4. Build and run

Open `Package.swift` in Xcode, choose the `ElginMenuBar` scheme and **My Mac**, then run. Or use:

```sh
scripts/build-macos.sh
open 'local/Elgin Menu Bar.app' --args --show
```

The app requires the repository checkout because it launches the Python bridge and reads local configuration from `local/`. It polls status over the LAN and sends a command only after you use a control.

## Troubleshooting

- **No devices found:** confirm that the Mac and devices are on the same network and that macOS allows local network access. Discovery depends on the device's Tuya protocol and network configuration.
- **Cloud helper finds fewer than two keys:** confirm that both discovered devices are linked to the project, the project uses the Western America (`us`) data center, and the discovery result is current.
- **A feature is unavailable:** the device schema may not expose it as writable, or the current controller may not map that model.

Local discovery, key, schema, and status data are excluded from Git by `.gitignore`.
