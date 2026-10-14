"""Retrieve local device keys through Tuya Cloud without sending device commands."""
import getpass
import json
import logging
import os
from pathlib import Path
import sys

import tinytuya

ROOT = Path(__file__).resolve().parent.parent
LOCAL = ROOT / 'local'


def save_private(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, 'w') as output:
        json.dump(value, output, indent=2, ensure_ascii=False)
        output.write('\n')


def main():
    logging.getLogger('tinytuya').setLevel(logging.CRITICAL)
    print('Elgin Menu Bar — retrieve local device keys')
    print('This helper queries Tuya Cloud and does not send commands to your devices.')
    print('Use credentials for the project linked to both devices.')
    print('Open the project Overview and find Access ID / Client ID and Access Secret / Client Secret.')
    print('Input is hidden. Paste each value and press Enter.')
    print('Cloud credentials are kept in memory only for this run.\n')
    try:
        discovered = json.loads((LOCAL / 'discovery.json').read_text())
    except (OSError, ValueError):
        print('Run discover.py --active before using this helper.')
        return 1
    discovered = {item['id']: item for item in discovered if item.get('id')}
    if not discovered:
        print('No devices are listed. Discover devices on the network first.')
        return 1
    api_id = getpass.getpass('Access ID / Client ID: ').strip()
    api_secret = getpass.getpass('Access Secret / Client Secret: ').strip()
    if not api_id or not api_secret:
        print('Both values are required. No credentials were saved.')
        return 1
    print('\nQuerying the project in the Western America data center…', flush=True)
    try:
        cloud = tinytuya.Cloud(apiRegion='us', apiKey=api_id, apiSecret=api_secret,
                               apiDeviceID=next(iter(discovered)))
        if cloud.error:
            print('Authentication failed. Check the project credentials and authorized services.')
            return 1
        response = cloud.getdevices(verbose=True)
    except Exception:
        print('Unable to query the API. Check your connection, credentials, and authorized services.')
        return 1
    finally:
        api_id = api_secret = ''
    if not isinstance(response, dict) or not response.get('success'):
        code = response.get('code') if isinstance(response, dict) else None
        if isinstance(code, (int, str)) and str(code).isdigit():
            print(f'The API rejected the request (code {code}).')
        else:
            print('The API did not return a valid device list.')
        print('Check IoT Core, Smart Home Basic Service, and the device links for this project.')
        return 1
    selected = []
    missing = 0
    for device in response.get('result', []):
        device_id = device.get('id')
        if device_id not in discovered:
            continue
        key = device.get('local_key', '')
        if not isinstance(key, str) or len(key.encode('utf-8')) != 16:
            missing += 1
            continue
        network = discovered[device_id]
        selected.append({'name': device.get('name', 'Device'), 'id': device_id,
                         'key': key, 'ip': network['ip'], 'version': network['version'],
                         'category': device.get('category')})
    if missing or len(selected) != 2:
        print(f'Valid keys for discovered devices: {len(selected)} of 2.')
        print('Check that both devices are linked and rerun discovery. The existing local configuration was not replaced.')
        return 1
    LOCAL.mkdir(mode=0o700, exist_ok=True)
    os.chmod(LOCAL, 0o700)
    save_private(LOCAL / 'devices.json', selected)
    print('\nKeys for both devices were saved to local/devices.json.')
    print('Do not share this file; it contains local control keys.')
    print('No commands were sent. Next, read the authenticated device status.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        print('\nSetup cancelled.')
        sys.exit(1)
