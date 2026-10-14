# Setup

Set up one compatible Tuya-based Elgin air conditioner and one Elgin smart light on the same local network as your Mac. You use Tuya Cloud to obtain local keys and device specifications; the app then sends controls over your LAN.

## Before you start

- Install Xcode with the macOS 27 SDK and complete its first-launch setup. The app targets macOS 13 and later.
- Install Python 3.13 with a compatible OpenSSL build. Check it with `python3.13 --version`.
- Clone this repository and run the commands below from its root directory.
- Have both devices working in a registered **Smart Life** account. Use the manufacturer's pairing instructions if you need to add them. Re-pairing resets local keys, so retrieve keys after pairing is complete. See [TinyTuya device preparation](https://github.com/jasonacox/tinytuya#tuya-device-preparation).

The account-linking route below uses Smart Life. An Elgin Smart account does not become a Smart Life account by using the same email. This guide does not establish an Elgin Smart-only linking route.

## 1. Check the account's data center

The current key and schema helpers both use **Western America (`us`)**. Your Smart Life account and cloud project must use that data center for these helpers to work unchanged.

Check the **App account data center distribution** link in Tuya's account-linking dialog. Select the data center for the app account, rather than guessing from your Mac's location. Account mappings can vary with the app and registration date; see [Tuya's data center guidance](https://developer.tuya.com/en/docs/iot/oem-app-data-center-distributed?id=Kafi0ku9l07qb).

If your account uses another data center, stop before running the helpers. Changing the project's region alone does not move an existing app account. This project currently requires code changes to both helpers for another region.

## 2. Create a Tuya Cloud project

1. Sign in to the [Tuya Developer Platform](https://platform.tuya.com/) or create a developer account.
2. Open **Cloud → Development** or **My Cloud Projects**, then **Create Cloud Project**.
3. Enter a project name, such as `Elgin Menu Bar`. Choose **Smart Home** as the development method if the form offers it.
4. Select the data center confirmed in step 1. For the current helpers, it must be **Western America**.
5. Create the project and complete the API authorization wizard.

The portal's labels can vary. Tuya documents project creation in its [Cloud quick start](https://developer.tuya.com/en/docs/archived-documents/quick-start1?id=K95ztz9u9t89n).

## 3. Authorize the setup APIs

In the project's **Service API** tab, check these services:

| Service | Purpose during setup |
| --- | --- |
| IoT Core | Device information and specifications |
| Authorization Token Management / Authorization | Authentication for API requests |
| Smart Home Basic Service | Access to the linked Smart Life account's devices |

If a service is missing, use **Go to Authorize**. If Tuya asks for a subscription, check the available trial or resource pack and its expiry before continuing. Subscribing to a service and authorizing this project are separate steps. See [Tuya's API authorization instructions](https://developer.tuya.com/en/docs/iot/applying-for-api-group-permissions?id=Ka6vf012u6q76).

## 4. Link the Smart Life account

1. Open the project, then **Devices → Link App Account**. Some versions label it **Link Tuya App Account**.
2. Choose **Add App Account** to display the QR code.
3. In **Smart Life** on your phone, open **Me → Scan** and scan the code. Confirm the authorization on your phone.
4. Choose **Custom Link** to select the air conditioner and light, then confirm.
5. Open **Manage Devices**, select both devices, and click **Link Device**. If you use **Automatic Link**, confirm that it includes both intended devices.
6. Check that the account shows **2/2** associated devices for this two-device setup. In **All Devices**, confirm that both devices appear and are online.

Continue only after both devices appear in the cloud project. Tuya describes this flow in [Link a Tuya app account](https://developer.tuya.com/en/docs/iot/link-devices?id=Ka471nu1sfmkl).

## 5. Discover devices on your Mac

Keep your Mac and both appliances on the same LAN. Allow local network access if macOS prompts you.

```sh
python3.13 -m venv local/cloud-venv
local/cloud-venv/bin/python -m pip install -r requirements.txt
local/cloud-venv/bin/python discover.py --active --seconds 25
```

Use this same Python environment for discovery and the setup helpers. Discovery saves addresses and protocol versions to `local/discovery.json`. Active discovery sends identification requests, without issuing device control commands.

Check that discovery finds both appliances. The key helper matches discovered IDs to the devices linked to your Tuya project and requires two valid matches.

## 6. Retrieve local keys

Open the cloud project's **Overview** and find its authorization keys:

| Terminal prompt | Copy from Tuya |
| --- | --- |
| Access ID / Client ID | The project's Access ID / Client ID |
| Access Secret / Client Secret | The project's Access Secret / Client Secret |

These are project credentials, not your Mac password or your Smart Life password.

Run:

```sh
open scripts/setup-local-keys.command
```

Paste each value into the Terminal window and press Enter. Input is hidden, so you will not see characters while typing or pasting. The helper keeps cloud credentials in memory for that run and saves device keys to `local/devices.json` with restrictive file permissions.

Wait for confirmation that keys for both devices were saved. If you entered the wrong value, run the helper again and supply the correct project credentials.

## 7. Retrieve the device specifications

```sh
open scripts/fetch-device-schema.command
```

Enter the same project's Access ID and Access Secret again. The helper saves `local/schema.json`, which describes the controls the app can read and change. It attempts to fetch the full model and falls back to the standard specification when the full model is unavailable. Neither setup helper sends appliance commands.

Before launching, you should have:

| Local path | Contents |
| --- | --- |
| `local/cloud-venv/` | Python runtime and TinyTuya dependency |
| `local/discovery.json` | Discovered devices and LAN addresses |
| `local/devices.json` | Device IDs, local keys, addresses, and protocol versions |
| `local/schema.json` | Device specifications and available controls |

Keep these files private. Git ignores `local/`.

## 8. Build and use the app

```sh
scripts/build-macos.sh
open 'local/Elgin Menu Bar.app'
```

Click the menu bar icon, wait for the connection status, and select **Air conditioner** or **Lighting**. Try one control and confirm the appliance responds. Click the menu bar icon again to close the panel; right-click it to quit.

You can also open `Package.swift` in Xcode, choose **ElginMenuBar → My Mac**, and run it. Keep the checkout in place because the app uses the Python environment and configuration inside it.

## Troubleshooting

| Problem | What to check |
| --- | --- |
| **QR code has expired** | Choose **Refresh QR Code** and scan the new code with Smart Life. Confirm on the phone while the dialog remains open. |
| **Data centers inconsistency** | The project's selected data center does not match the app account. Recheck step 1; the current helpers support Western America only. |
| **Account linked, but no devices** | Confirm both appliances exist in that Smart Life account. With Custom Link, use **Manage Devices** to link each appliance. |
| **Only 1/2 devices associated** | Link the remaining appliance in **Manage Devices** and confirm 2/2. |
| **Cloud authentication or permission error** | Copy credentials from the correct project's Overview. Check API authorization and subscription expiry. |
| **No devices discovered** | Check LAN access and guest-network isolation. Keep devices powered on, then rerun discovery. |
| **Fewer than two valid keys** | Check that the discovered IDs match both devices linked to the project and that the account uses the helper's region. |
| **Connection fails after pairing again** | Retrieve new local keys and specifications. Re-pairing changes local keys. |
| **Connection fails after an address change** | Rerun discovery, then the key helper to update saved addresses. A router DHCP reservation can keep addresses stable. |
| **A control is unavailable** | Check that the schema exposes a supported writable field. Different models may require mapping changes. |

Remove credentials, device identifiers, and network addresses before sharing an error report.
