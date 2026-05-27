#!/usr/bin/env python3
"""
Location simulation daemon for iOS 17+ devices.

Maintains a persistent DVT connection and reads coordinates from stdin.
Each line should be one of:
  SET lat lon       -- set simulated location
  CLEAR             -- clear simulated location
  PING              -- health check (responds PONG)
  QUIT              -- clean shutdown

Responds with OK or ERROR on stdout for each command.

Usage:
  python3 location_daemon.py [tunnel_file] [device_udid]

Tunnel discovery order:
  1. Query tunneld HTTP API at http://127.0.0.1:49151/ (always fresh)
  2. Fall back to tunnel_file if tunneld is not running

On connect, the Developer Disk Image is auto-mounted if needed (the
location-simulation service only exists once it is mounted). This
requires Developer Mode to be enabled on the device.
"""

import asyncio
import json
import sys
import os
import urllib.request
from pathlib import Path

from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
from pymobiledevice3.services.mobile_image_mounter import (
    auto_mount,
    AlreadyMountedError,
    DeveloperModeIsNotEnabledError,
)

TUNNEL_FILE = "/tmp/pymobiledevice3_tunnel.txt"
TUNNELD_URL = "http://127.0.0.1:49151/"


def discover_tunnel_from_tunneld(udid=None):
    """Query the tunneld HTTP API for a live tunnel address.
    Returns (host, port) or None."""
    try:
        with urllib.request.urlopen(TUNNELD_URL, timeout=2) as resp:
            data = json.loads(resp.read().decode())
    except Exception:
        return None

    if not data:
        return None

    if udid and udid in data:
        tunnels = data[udid]
        if tunnels:
            t = tunnels[0]
            return (t["tunnel-address"], int(t["tunnel-port"]))

    for device_udid, tunnels in data.items():
        if tunnels:
            t = tunnels[0]
            return (t["tunnel-address"], int(t["tunnel-port"]))

    return None


def read_tunnel_file(path):
    """Read RSD tunnel address from file (fallback)."""
    p = Path(path)
    if not p.exists():
        return None
    parts = p.read_text().strip().split()
    if len(parts) < 2:
        return None
    return (parts[0], int(parts[1]))


def respond(msg):
    """Write response to stdout and flush immediately."""
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


async def ensure_ddi_mounted(tunnel_addr):
    """Mount the Developer Disk Image if it isn't already.

    The location-simulation service (com.apple.instruments.dtservicehub)
    only exists once the DDI is mounted. auto_mount() downloads the
    personalized image on first use and caches it for later runs.

    Returns None on success, or an error string on failure.
    """
    try:
        async with RemoteServiceDiscoveryService(tunnel_addr) as rsd:
            respond("MOUNTING developer disk image")
            await auto_mount(rsd)
        # Give the device a moment to start advertising developer services.
        await asyncio.sleep(2)
        return None
    except AlreadyMountedError:
        return None
    except DeveloperModeIsNotEnabledError:
        return ("Developer Mode is not enabled. Enable it on the iPhone in "
                "Settings > Privacy & Security > Developer Mode, then reboot.")
    except Exception as e:
        return f"DDI mount failed: {e}"


async def run_daemon(tunnel_path, udid=None):
    """Main daemon loop with persistent DVT connection."""
    tunnel_addr = discover_tunnel_from_tunneld(udid)
    if not tunnel_addr:
        tunnel_addr = read_tunnel_file(tunnel_path)
    if not tunnel_addr:
        respond(f"ERROR no tunnel found (tunneld not running and no file at {tunnel_path})")
        return

    respond(f"CONNECTING {tunnel_addr[0]} {tunnel_addr[1]}")

    # The dtservicehub developer service requires the DDI to be mounted.
    mount_error = await ensure_ddi_mounted(tunnel_addr)
    if mount_error:
        respond(f"ERROR {mount_error}")
        return

    try:
        async with RemoteServiceDiscoveryService(tunnel_addr) as rsd:
            async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as loc_sim:
                respond("READY")

                for line in sys.stdin:
                    line = line.strip()
                    if not line:
                        continue

                    parts = line.split()
                    cmd = parts[0].upper()

                    if cmd == "SET" and len(parts) >= 3:
                        try:
                            lat = float(parts[1])
                            lon = float(parts[2])
                            await loc_sim.set(lat, lon)
                            respond("OK")
                        except (ValueError, IndexError) as e:
                            respond(f"ERROR invalid coords: {e}")
                        except Exception as e:
                            respond(f"ERROR set failed: {e}")

                    elif cmd == "CLEAR":
                        try:
                            await loc_sim.clear()
                            respond("OK")
                        except Exception as e:
                            respond(f"ERROR clear failed: {e}")

                    elif cmd == "PING":
                        respond("PONG")

                    elif cmd == "QUIT":
                        respond("BYE")
                        break

                    else:
                        respond(f"ERROR unknown command: {line}")

    except Exception as e:
        respond(f"ERROR connection failed: {e}")


def main():
    tunnel_path = sys.argv[1] if len(sys.argv) > 1 else TUNNEL_FILE
    udid = sys.argv[2] if len(sys.argv) > 2 else None
    sys.stdout.reconfigure(line_buffering=True)
    asyncio.run(run_daemon(tunnel_path, udid))


if __name__ == "__main__":
    main()
