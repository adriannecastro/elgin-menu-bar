"""Fetch device specifications without sending commands or saving cloud credentials."""
import getpass
import json
import logging
import os
from pathlib import Path
import sys
import tinytuya

LOCAL = Path(__file__).resolve().parent.parent / 'local'


def main():
    logging.getLogger('tinytuya').setLevel(logging.CRITICAL)
    print('Elgin Menu Bar — fetch supported device features')
    print('This query does not change device state or replace local keys.')
    print('Use the Access ID and Access Secret for the Tuya project linked to both devices.')
    print('Input is hidden. Cloud credentials are not saved.\n')
    devices = json.loads((LOCAL / 'devices.json').read_text())
    api_id = getpass.getpass('Access ID / Client ID: ').strip()
    api_secret = getpass.getpass('Access Secret / Client Secret: ').strip()
    if not api_id or not api_secret:
        print('Both values are required. No credentials were saved.')
        return 1
    try:
        cloud = tinytuya.Cloud(apiRegion='us', apiKey=api_id, apiSecret=api_secret,
                               apiDeviceID=devices[0]['id'])
        if cloud.error:
            print('Authentication failed. Check the credentials and project services.')
            return 1
        schemas = []
        for device in devices:
            print(f"Fetching features for {device['name']}…", flush=True)
            response = cloud.getdps(device['id'])
            specification = response.get('result') if isinstance(response, dict) else None
            if not isinstance(specification, dict) or not specification.get('functions'):
                print('The API returned no supported features. Check the project query permissions.')
                return 1
            model_response = cloud.cloudrequest('/v2.0/cloud/thing/%s/model' % device['id'])
            model = None
            if isinstance(model_response, dict) and model_response.get('success'):
                model = model_response.get('result', {}).get('model')
                if isinstance(model, str):
                    model = json.loads(model)
            schemas.append({'name': device['name'], 'id': device['id'], 'specification': specification, 'model': model})
            print(f"  Received {len(specification.get('functions', []))} writable features.")
            print('  Full model received.' if model else '  Full model unavailable; using the standard specification.')
        path = LOCAL / 'schema.json'
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as output:
            json.dump(schemas, output, indent=2, ensure_ascii=False)
            output.write('\n')
        print('\nDevice specifications were saved successfully.')
        print('Data is in local/schema.json. No device commands were sent.')
        return 0
    finally:
        api_id = api_secret = ''


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        print('\nQuery cancelled.')
        sys.exit(1)
    except Exception:
        print('Unable to complete the query. Check your connection and local configuration.')
        sys.exit(1)
