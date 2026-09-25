"""Load an executable's imported DLLs one by one (Windows) and report the first that fails,
with the Windows error (126: a module is missing, 127: an entry point is missing).
Usage: python scripts/windows-dll-check.py <exe or dll> [...]"""
import ctypes
import os
import sys

import pefile  # pip install pefile

seen = set()


def check(path, depth=0):
    pe = pefile.PE(path, fast_load=True)
    pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_IMPORT"]])
    for entry in getattr(pe, "DIRECTORY_ENTRY_IMPORT", []):
        name = entry.dll.decode()
        key = name.lower()
        if key in seen or key.startswith("api-ms-win") or key.startswith("ext-ms-"):
            continue
        seen.add(key)
        try:
            handle = ctypes.WinDLL(name, winmode=0)  # standard search order (PATH)
            where = ctypes.create_unicode_buffer(1024)
            ctypes.windll.kernel32.GetModuleFileNameW(ctypes.c_void_p(handle._handle), where, 1024)
            if depth == 0:
                print(f"ok   {name} -> {where.value}")
            if "system32" not in where.value.lower():
                check(where.value, depth + 1)
        except OSError as e:
            print(f"FAIL {name} (imported by {os.path.basename(path)}): winerror {getattr(e, "winerror", None)} {e}")


for p in sys.argv[1:]:
    print(f"== {p}")
    check(p)
