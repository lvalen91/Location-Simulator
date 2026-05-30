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
import logging
import logging.handlers
import os
import sys
import time
import traceback
import urllib.request
from pathlib import Path

# ---------------------------------------------------------------------------
# File logging — captures full pymobiledevice3 debug output for offline
# analysis. Swift only sees the daemon's single-line protocol responses
# (READY / OK / ERROR …); everything richer goes here.
# ---------------------------------------------------------------------------
LOG_DIR = Path.home() / "Library" / "Logs" / "LocationSimulator"
LOG_DIR.mkdir(parents=True, exist_ok=True)
LOG_FILE = LOG_DIR / "daemon.log"

_handler = logging.handlers.RotatingFileHandler(
    LOG_FILE, maxBytes=2_000_000, backupCount=3, encoding="utf-8"
)
_handler.setFormatter(logging.Formatter(
    "%(asctime)s.%(msecs)03d [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
))
logging.basicConfig(level=logging.DEBUG, handlers=[_handler])
log = logging.getLogger("location_daemon")
# Capture pymobiledevice3 + asyncio internals too.
logging.getLogger("pymobiledevice3").setLevel(logging.DEBUG)
logging.getLogger("asyncio").setLevel(logging.INFO)

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
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(TUNNELD_URL, timeout=2) as resp:
            raw = resp.read().decode()
            data = json.loads(raw)
    except Exception as e:
        log.warning("tunneld HTTP probe failed in %.3fs: %s",
                    time.monotonic() - t0, e)
        return None

    log.debug("tunneld registry (latency %.3fs): %s",
              time.monotonic() - t0, raw[:512])

    if not data:
        log.info("tunneld registry empty")
        return None

    if udid and udid in data:
        tunnels = data[udid]
        if tunnels:
            t = tunnels[0]
            log.info("tunneld registry: matched udid %s → %s:%s",
                     udid[:8], t["tunnel-address"], t["tunnel-port"])
            return (t["tunnel-address"], int(t["tunnel-port"]))
        else:
            log.warning("tunneld registry: udid %s present but tunnel list empty",
                        udid[:8])

    if udid:
        log.warning("tunneld registry: udid %s absent; falling back to first tunnel",
                    udid[:8])
    for device_udid, tunnels in data.items():
        if tunnels:
            t = tunnels[0]
            log.info("tunneld registry: using first tunnel for %s → %s:%s",
                     device_udid[:8], t["tunnel-address"], t["tunnel-port"])
            return (t["tunnel-address"], int(t["tunnel-port"]))

    log.warning("tunneld registry: no usable tunnels in response")
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
    t0 = time.monotonic()
    try:
        log.info("ensure_ddi_mounted: connecting RSD at %s:%s", *tunnel_addr)
        async with RemoteServiceDiscoveryService(tunnel_addr) as rsd:
            respond("MOUNTING developer disk image")
            log.info("ensure_ddi_mounted: calling auto_mount (may download DDI on first run)")
            await auto_mount(rsd)
            log.info("ensure_ddi_mounted: DDI mount completed in %.2fs", time.monotonic() - t0)
        # Give the device a moment to start advertising developer services.
        await asyncio.sleep(2)
        return None
    except AlreadyMountedError:
        log.info("ensure_ddi_mounted: DDI already mounted (skip) elapsed=%.2fs", time.monotonic() - t0)
        return None
    except DeveloperModeIsNotEnabledError:
        log.error("ensure_ddi_mounted: Developer Mode is not enabled on device")
        return ("Developer Mode is not enabled. Enable it on the iPhone in "
                "Settings > Privacy & Security > Developer Mode, then reboot.")
    except Exception as e:
        log.error("ensure_ddi_mounted: failed after %.2fs\n%s",
                  time.monotonic() - t0, traceback.format_exc())
        return f"DDI mount failed: {e}"


async def run_daemon(tunnel_path, udid=None):
    """Main daemon loop with persistent DVT connection."""
    log.info("run_daemon start: udid=%s tunnel_path=%s pid=%d",
             udid[:8] if udid else "n/a", tunnel_path, os.getpid())
    tunnel_addr = discover_tunnel_from_tunneld(udid)
    if not tunnel_addr:
        log.info("no tunnel from tunneld; trying file fallback at %s", tunnel_path)
        tunnel_addr = read_tunnel_file(tunnel_path)
    if not tunnel_addr:
        log.error("no tunnel address discovered — bailing out")
        respond(f"ERROR no tunnel found (tunneld not running and no file at {tunnel_path})")
        return

    respond(f"CONNECTING {tunnel_addr[0]} {tunnel_addr[1]}")

    # The dtservicehub developer service requires the DDI to be mounted.
    mount_error = await ensure_ddi_mounted(tunnel_addr)
    if mount_error:
        respond(f"ERROR {mount_error}")
        return

    log.info("opening DVT + LocationSimulation on %s:%s", *tunnel_addr)
    dvt_start = time.monotonic()
    try:
        async with RemoteServiceDiscoveryService(tunnel_addr) as rsd:
            async with DvtProvider(rsd) as dvt, LocationSimulation(dvt) as loc_sim:
                log.info("DVT + LocationSimulation ready in %.2fs", time.monotonic() - dvt_start)
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
        log.error("DVT/LocationSimulation lifecycle failed after %.2fs\n%s",
                  time.monotonic() - dvt_start, traceback.format_exc())
        respond(f"ERROR connection failed: {e}")


def main():
    tunnel_path = sys.argv[1] if len(sys.argv) > 1 else TUNNEL_FILE
    udid = sys.argv[2] if len(sys.argv) > 2 else None
    sys.stdout.reconfigure(line_buffering=True)
    log.info("=" * 60)
    log.info("location_daemon launched: argv=%s log=%s", sys.argv, LOG_FILE)
    try:
        asyncio.run(run_daemon(tunnel_path, udid))
    except KeyboardInterrupt:
        log.info("interrupted")
    except Exception:
        log.error("fatal error in main\n%s", traceback.format_exc())
        respond(f"ERROR fatal: see {LOG_FILE}")
    finally:
        log.info("location_daemon exiting")


if __name__ == "__main__":
    main()
