"""Read configured device status over the LAN; no control commands are sent."""
import json
import os
from pathlib import Path
import sys
import tinytuya

LOCAL = Path(__file__).resolve().parent.parent / 'local'


def main():
    try:
        devices = json.loads((LOCAL / 'devices.json').read_text())
    except (OSError, ValueError):
        print('Device key configuration is missing or invalid.')
        return 1
    results = []
    failed = False
    for item in devices:
        print(f"Reading {item['name']}…", flush=True)
        device = tinytuya.Device(item['id'], item['ip'], item['key'], version=float(item['version']))
        device.set_socketTimeout(4)
        device.set_socketRetryLimit(1)
        try:
            response = device.status()
            valid = isinstance(response, dict) and isinstance(response.get('dps'), dict) and bool(response['dps'])
            results.append({'name': item['name'], 'id': item['id'], 'ok': valid, 'response': response})
            if valid:
                print(f"  Received status with {len(response['dps'])} fields.")
            else:
                failed = True
                print('  Unable to read device status.')
        except Exception:
            failed = True
            results.append({'name': item['name'], 'id': item['id'], 'ok': False})
            print('  Local connection failed.')
        finally:
            device.close()
    path = LOCAL / 'status.json'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, 'w') as output:
        json.dump(results, output, indent=2, ensure_ascii=False)
        output.write('\n')
    print('Diagnostic data saved locally without device keys.')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
