#!/usr/bin/env python3
"""
SMC Fan Control — read/write Apple SMC keys via IOKit on Intel Macs.
Zero dependencies beyond the system Python + IOKit framework.
Works on macOS Catalina and earlier (Intel, pre-T2).
"""

import ctypes
from ctypes import (
    c_uint32, c_uint16, c_uint8, c_char, c_char_p,
    c_size_t, c_int, c_void_p,
    POINTER, Structure, byref,
)
import struct
import argparse
import sys
import time

# ── IOKit types ──────────────────────────────────────────────────
mach_port_t = c_uint32
io_service_t = mach_port_t
io_connect_t = mach_port_t

KERN_SUCCESS = 0

# ── SMC structs ───────────────────────────────────────────────────
class SMCVersion(Structure):
    _fields_ = [
        ("major", c_uint8), ("minor", c_uint8), ("build", c_uint8),
        ("reserved", c_uint8), ("release", c_uint16),
    ]

class SMCPLimitData(Structure):
    _fields_ = [
        ("version", c_uint16), ("length", c_uint16),
        ("cpuPLimit", c_uint32), ("gpuPLimit", c_uint32), ("memPLimit", c_uint32),
    ]

class SMCKeyInfoData(Structure):
    _fields_ = [
        ("dataSize", c_uint32), ("dataType", c_uint32), ("dataAttributes", c_uint8),
    ]

class SMCKeyData(Structure):
    _fields_ = [
        ("key", c_uint32),
        ("vers", SMCVersion),
        ("pLimitData", SMCPLimitData),
        ("keyInfo", SMCKeyInfoData),
        ("result", c_uint8),
        ("status", c_uint8),
        ("data8", c_uint8),
        ("data32", c_uint32),
        ("bytes", c_uint8 * 32),
    ]

# ── IOKit bindings ────────────────────────────────────────────────
IOKit = ctypes.cdll.LoadLibrary('/System/Library/Frameworks/IOKit.framework/IOKit')
libSystem = ctypes.cdll.LoadLibrary('/usr/lib/libSystem.B.dylib')
mach_task_self = ctypes.c_uint32.in_dll(libSystem, "mach_task_self_")

IOKit.IOServiceGetMatchingService.argtypes = [mach_port_t, c_void_p]
IOKit.IOServiceGetMatchingService.restype = io_service_t

IOKit.IOServiceMatching.argtypes = [c_char_p]
IOKit.IOServiceMatching.restype = c_void_p

IOKit.IOServiceOpen.argtypes = [io_service_t, c_uint32, c_uint32, POINTER(io_connect_t)]
IOKit.IOServiceOpen.restype = c_int

IOKit.IOServiceClose.argtypes = [io_connect_t]
IOKit.IOServiceClose.restype = c_int

IOKit.IOConnectCallStructMethod.argtypes = [
    mach_port_t, c_uint32, c_void_p, c_size_t, c_void_p, POINTER(c_size_t),
]
IOKit.IOConnectCallStructMethod.restype = c_int

# ── SMC connection ────────────────────────────────────────────────
class SMC:
    def __init__(self):
        service = IOKit.IOServiceGetMatchingService(0, IOKit.IOServiceMatching(b"AppleSMC"))
        if not service:
            raise RuntimeError("AppleSMC service not found — not an Intel Mac, or SIP blocks access")
        self._conn = io_connect_t(0)
        r = IOKit.IOServiceOpen(service, mach_task_self, c_uint32(0), byref(self._conn))
        if r != KERN_SUCCESS:
            raise RuntimeError(f"IOServiceOpen failed: 0x{r:x}")

    def close(self):
        if self._conn:
            IOKit.IOServiceClose(self._conn)
            self._conn = None

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()

    @staticmethod
    def _k2u(key):
        b = key.encode("ascii")
        return (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]

    def _call(self, selector, inp, outp):
        isz = c_size_t(ctypes.sizeof(inp))
        osz = c_size_t(ctypes.sizeof(outp))
        return IOKit.IOConnectCallStructMethod(
            self._conn, c_uint32(selector),
            byref(inp), isz, byref(outp), byref(osz),
        )

    def read(self, key_str):
        """Read an SMC key. Returns parsed Python value."""
        # Get key info first
        inp = SMCKeyData()
        ctypes.memset(ctypes.addressof(inp), 0, ctypes.sizeof(inp))
        inp.key = self._k2u(key_str)
        inp.data8 = 9  # kSMCGetKeyInfo
        out = SMCKeyData()
        ctypes.memset(ctypes.addressof(out), 0, ctypes.sizeof(out))
        r = self._call(2, inp, out)
        if r != KERN_SUCCESS:
            raise RuntimeError(f"SMC info failed for '{key_str}': 0x{r:x}")

        size = out.keyInfo.dataSize
        type_raw = out.keyInfo.dataType
        t = chr((type_raw >> 24) & 0xFF) + chr((type_raw >> 16) & 0xFF) + \
            chr((type_raw >> 8) & 0xFF) + chr(type_raw & 0xFF)
        t = t.rstrip("\x00").rstrip()

        # Read the value
        inp2 = SMCKeyData()
        ctypes.memset(ctypes.addressof(inp2), 0, ctypes.sizeof(inp2))
        inp2.key = self._k2u(key_str)
        inp2.keyInfo.dataSize = size
        inp2.data8 = 5  # kSMCReadKey
        out2 = SMCKeyData()
        ctypes.memset(ctypes.addressof(out2), 0, ctypes.sizeof(out2))
        r = self._call(2, inp2, out2)
        if r != KERN_SUCCESS:
            raise RuntimeError(f"SMC read failed for '{key_str}': 0x{r:x}")

        raw = bytes(out2.bytes[:size])
        return self._parse(raw, t)

    def write(self, key_str, raw_bytes):
        """Write raw bytes to an SMC key."""
        inp = SMCKeyData()
        ctypes.memset(ctypes.addressof(inp), 0, ctypes.sizeof(inp))
        inp.key = self._k2u(key_str)
        inp.keyInfo.dataSize = len(raw_bytes)
        inp.data8 = 6  # kSMCWriteKey
        for i, b in enumerate(raw_bytes):
            inp.bytes[i] = b

        out = SMCKeyData()
        ctypes.memset(ctypes.addressof(out), 0, ctypes.sizeof(out))
        r = self._call(2, inp, out)
        if r != KERN_SUCCESS:
            raise RuntimeError(f"SMC write failed for '{key_str}': 0x{r:x}")

    @staticmethod
    def _parse(raw, type_str):
        if len(raw) == 0:
            return None
        if type_str == "sp78":
            return int.from_bytes(raw[:2], "big", signed=True) / 256.0
        elif type_str == "fpe2":
            return int.from_bytes(raw[:2], "big", signed=True) / 4.0
        elif type_str == "flt":
            return struct.unpack(">f", raw[:4])[0]
        elif type_str == "ui8":
            return raw[0]
        elif type_str == "ui16":
            return int.from_bytes(raw[:2], "big")
        elif type_str == "ui32":
            return int.from_bytes(raw[:4], "big")
        elif type_str in ("si8",):
            return int.from_bytes(raw[:1], "big", signed=True)
        elif type_str == "si16":
            return int.from_bytes(raw[:2], "big", signed=True)
        elif type_str == "flag":
            return bool(raw[0])
        elif type_str.startswith("ch8"):
            return raw.rstrip(b"\x00").decode("ascii")
        else:
            return raw

    @staticmethod
    def _encode(value, type_str):
        if type_str == "sp78":
            v = int(round(value * 256.0))
            return v.to_bytes(2, "big", signed=True)
        elif type_str == "fpe2":
            v = int(round(value * 4.0))
            return v.to_bytes(2, "big", signed=True)
        elif type_str == "flt":
            return struct.pack(">f", float(value))
        elif type_str == "ui8":
            return int(value).to_bytes(1, "big")
        elif type_str == "ui16":
            return int(value).to_bytes(2, "big")
        elif type_str == "ui32":
            return int(value).to_bytes(4, "big")
        elif type_str == "flag":
            return b"\x01" if value else b"\x00"
        else:
            raise ValueError(f"Encoding not implemented for type '{type_str}'")


# ── Higher-level fan control API ──────────────────────────────────
KNOWN_TEMP_KEYS = [
    "TC0P", "TC0D", "TC0H", "TC1C", "TC2C", "TC3C", "TCGC",
    "TG0P", "TG0D", "TG0H", "TG1D", "TG1H",
    "Tm0P", "Tm1P", "Th0H", "Th1H", "Th2H",
    "TA0P", "TB0T", "TB1T", "TB2T", "TN0P",
]

# Fan mode constants
FAN_MODE_AUTO = 0
FAN_MODE_FORCED = 1


def get_all_temps(smc):
    """Return dict of temperature sensor -> °C (only valid readings)"""
    temps = {}
    for k in KNOWN_TEMP_KEYS:
        try:
            v = smc.read(k)
            if v is not None:
                temps[k] = v
        except Exception:
            pass
    return temps


def get_all_fans(smc):
    """Return list of fan dicts with all readable keys"""
    num = smc.read("FNum")
    fans = []
    for i in range(num):
        f = {"index": i}
        for suffix in ("Ac", "Mn", "Mx", "Tg"):
            try:
                v = smc.read(f"F{i}{suffix}")
                f[suffix] = v if v is not None else None
            except Exception:
                f[suffix] = None
        fans.append(f)
    return fans


def set_fan_target(smc, fan_index, rpm):
    """Set target RPM for a specific fan (F<Tg> = target speed)"""
    raw = int(round(rpm * 4.0)).to_bytes(2, "big", signed=True)
    smc.write(f"F{fan_index}Tg", raw)


def set_fan_mode(smc, fan_index, mode):
    """Set fan mode: 0 = automatic, 1 = forced/manual"""
    try:
        smc.write(f"F{fan_index}Md", bytes([mode]))
    except Exception:
        pass  # Not all Macs support this key


def set_fan_min(smc, fan_index, rpm):
    """Set minimum RPM for a specific fan"""
    raw = int(round(rpm * 4.0)).to_bytes(2, "big", signed=True)
    smc.write(f"F{fan_index}Mn", raw)


# ── CLI ───────────────────────────────────────────────────────────
def cmd_status(smc):
    fans = get_all_fans(smc)
    temps = get_all_temps(smc)

    # Find hottest temp
    hottest = max(temps.items(), key=lambda x: x[1]) if temps else ("?", 0)

    print(f"CPU/GPU temps: {hottest[0]}={hottest[1]:.0f}°C")
    print()
    for f in fans:
        i = f["index"]
        print(f"Fan {i}:")
        print(f"  Actual:  {f['Ac']:.0f} RPM" if f['Ac'] is not None else f"  Actual:  ? RPM")
        print(f"  Target:  {f['Tg']:.0f} RPM" if f['Tg'] is not None else f"  Target:  ? RPM")
        print(f"  Min:     {f['Mn']:.0f} RPM" if f['Mn'] is not None else f"  Min:     ? RPM")
        print(f"  Max:     {f['Mx']:.0f} RPM" if f['Mx'] is not None else f"  Max:     ? RPM")
        print()

    if temps:
        print("Temperatures:")
        for k, v in sorted(temps.items()):
            print(f"  {k}: {v:.0f}°C")


def cmd_set(smc, fan, rpm):
    """Set target RPM for a fan"""
    set_fan_target(smc, fan, rpm)
    print(f"Set Fan {fan} target → {rpm} RPM")
    time.sleep(0.3)
    actual = smc.read(f"F{fan}Ac")
    target = smc.read(f"F{fan}Tg")
    print(f"  Now: Actual={actual:.0f}  Target={target:.0f}")


def cmd_auto(smc, fan):
    """Reset fan to automatic control"""
    set_fan_mode(smc, fan, FAN_MODE_AUTO)
    # Also reset target to a reasonable value (or let SMC handle it)
    print(f"Fan {fan} set to AUTO mode")
    time.sleep(0.3)
    actual = smc.read(f"F{fan}Ac")
    target = smc.read(f"F{fan}Tg")
    print(f"  Now: Actual={actual:.0f}  Target={target:.0f}")


def cmd_monitor(smc, interval=2):
    """Continuously monitor fans + temps"""
    try:
        while True:
            temps = get_all_temps(smc)
            hottest = max(temps.values()) if temps else 0
            fans = get_all_fans(smc)
            fan_str = "  ".join(f"F{i['index']}={i['Ac']:.0f}RPM" if i['Ac'] is not None else f"F{i['index']}=?RPM" for i in fans)
            print(f"\r{time.strftime('%H:%M:%S')}  {hottest:.0f}°C  {fan_str}", end="")
            time.sleep(interval)
    except KeyboardInterrupt:
        print()


def cmd_profile(smc, profile_name):
    """Apply a named profile"""
    profiles = {
        "quiet":    {"rpm": 2000, "desc": "~2000 RPM — nearly silent"},
        "balanced": {"rpm": 3500, "desc": "~3500 RPM — moderate cooling"},
        "cool":     {"rpm": 5000, "desc": "~5000 RPM — aggressive cooling"},
        "max":      {"rpm": 6200, "desc": "Max RPM — full blast"},
    }
    p = profiles.get(profile_name)
    if not p:
        print(f"Unknown profile '{profile_name}'. Available: {', '.join(profiles)}")
        sys.exit(1)

    num = smc.read("FNum")
    for i in range(num):
        max_s = smc.read(f"F{i}Mx")
        rpm = min(p["rpm"], max_s)
        set_fan_target(smc, i, rpm)
        print(f"Fan {i}: {p['desc']} (set to {rpm:.0f} RPM)")


# ── Main ──────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="SMC Fan Control for Intel Macs")
    sub = parser.add_subparsers(dest="cmd")

    sub.add_parser("status", help="Show fan speeds and temperatures")

    p_set = sub.add_parser("set", help="Set fan target RPM")
    p_set.add_argument("fan", type=int, default=0, help="Fan index (default: 0)")
    p_set.add_argument("rpm", type=int, help="Target RPM")

    p_auto = sub.add_parser("auto", help="Set fan back to automatic mode")
    p_auto.add_argument("fan", type=int, default=0, help="Fan index (default: 0)")

    p_mon = sub.add_parser("monitor", help="Live monitor (Ctrl-C to stop)")
    p_mon.add_argument("-i", "--interval", type=float, default=2.0, help="Update interval in seconds")

    p_prof = sub.add_parser("profile", help="Apply a named profile")
    p_prof.add_argument("name", choices=["quiet", "balanced", "cool", "max"],
                        help="Profile name")

    args = parser.parse_args()
    if not args.cmd:
        parser.print_help()
        sys.exit(0)

    with SMC() as smc:
        if args.cmd == "status":
            cmd_status(smc)
        elif args.cmd == "set":
            cmd_set(smc, args.fan, args.rpm)
        elif args.cmd == "auto":
            cmd_auto(smc, args.fan)
        elif args.cmd == "monitor":
            cmd_monitor(smc, args.interval)
        elif args.cmd == "profile":
            cmd_profile(smc, args.name)


if __name__ == "__main__":
    main()
