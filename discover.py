"""Discover Tuya devices; by default, listen for local announcements only."""
import argparse
import json
import os
from pathlib import Path
import select
import socket
import time

import tinytuya


def discover(seconds):
    sockets = []
    found = {}
    try:
        for port in (6666, 6667, 7000):
            listener = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sockets.append(listener)
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("", port))
        print(f"Listening for device announcements for {seconds} seconds…", flush=True)
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            readable, _, _ = select.select(sockets, [], [], max(0, deadline - time.monotonic()))
            for listener in readable:
                packet, address = listener.recvfrom(65535)
                try:
                    payload = json.loads(tinytuya.decrypt_udp(packet))
                except Exception:
                    # Ignore malformed announcements and unsupported protocols.
                    continue
                if not isinstance(payload, dict) or not payload.get("gwId"):
                    continue
                device_id = str(payload["gwId"])
                found[device_id] = {
                    "id": device_id,
                    "ip": address[0],
                    "version": payload.get("version"),
                    "product_key": payload.get("productKey"),
                }
    finally:
        for listener in sockets:
            listener.close()
    return list(found.values())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--active", action="store_true", help="Send device identification requests; no control commands are sent.")
    args = parser.parse_args()
    if not 1 <= args.seconds <= 120:
        parser.error("Duration must be between 1 and 120 seconds.")
    try:
        if args.active:
            from tinytuya.scanner import devices as scan
            print(f"Requesting device identification for {args.seconds} seconds…", flush=True)
            results = scan(scantime=args.seconds, verbose=False, poll=False,
                           forcescan=False, tuyadevices=[], show_timer=False)
            devices = [{"id": item.get("gwId"), "ip": ip,
                        "version": item.get("version"),
                        "product_key": item.get("productKey")}
                       for ip, item in results.items()]
        else:
            devices = discover(args.seconds)
    except OSError as error:
        print(f"Unable to listen on the local network: {error}")
        return 1
    directory = Path(__file__).resolve().parent / "local"
    directory.mkdir(mode=0o700, exist_ok=True)
    path = directory / "discovery.json"
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(devices, output, indent=2, ensure_ascii=False)
        output.write("\n")
    print(f"Devices found: {len(devices)}.")
    for index, device in enumerate(devices, 1):
        version = device['version'] or 'unknown'
        print(f"  {index}. IP {device['ip']} — protocol {version}")
    print(f"Local results: {path}")
    if not devices:
        print("No devices found. This does not rule out Tuya compatibility; check local network access and device isolation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
