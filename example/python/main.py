#!/usr/bin/env python3
#
# Copyright (c) 2026, Adel Noureddine.
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the
# GNU Lesser General Public License v3.0 only (LGPL-3.0-only)
# which accompanies this distribution, and is available at:
# https://www.gnu.org/licenses/lgpl-3.0.en.html
#
# Author : Adel Noureddine
#

"""Prints the CPU load of the machine, of this very program, and of an application named on the command line, once per second, until stopped with Ctrl+C, using the C interface of CPU Load through ctypes.

Build the shared library first, from the root of the repository:

    gprbuild -P cpuload.gpr -XCPULOAD_LIBRARY_TYPE=relocatable

Then run this program:

    python3 example/python/main.py firefox

Or use the Makefile next to this file, which does both:

    make run APP=firefox

The C declarations mirrored here are in include/cpuload.h.
"""

import ctypes
import os
import signal
import sys
import time
from pathlib import Path

# Repository root, and where gprbuild puts the shared library
ROOT = Path(__file__).resolve().parents[2]
LIBRARY_DIR = ROOT / "lib" / "relocatable"

INTERVAL = 1.0


class Sample(ctypes.Structure):
    """struct cpuload_sample: three int64_t on every machine."""

    _fields_ = [
        ("busy", ctypes.c_int64),   # machine time not spent idle
        ("total", ctypes.c_int64),  # machine time altogether, idle included
        ("used", ctypes.c_int64),   # CPU time of what was sampled, 0 for a sample of the system
    ]


def library_names():
    """The names the shared library may have on this OS."""
    if sys.platform == "win32":
        return ("libcpuload.dll", "cpuload.dll")
    if sys.platform == "darwin":
        return ("libcpuload.dylib",)
    return ("libcpuload.so",)


def find_library():
    """The shared library's path; exits with build instructions if there is none."""
    # Next to this program first: Windows has no rpath and wants a copy of the DLL there
    for folder in (Path(__file__).resolve().parent, LIBRARY_DIR):
        for name in library_names():
            candidate = folder / name
            if candidate.exists():
                return candidate

    sys.exit(
        "CPU Load shared library not found in {}\n"
        "Build it first, from the root of the repository:\n"
        "    gprbuild -P cpuload.gpr -XCPULOAD_LIBRARY_TYPE=relocatable".format(LIBRARY_DIR)
    )


def load_library():
    """Loads the shared library and declares its function types.

    ctypes defaults every result to int, which would silently truncate the doubles.
    """
    library_file = find_library()

    try:
        library = ctypes.CDLL(str(library_file))
    except OSError as error:
        # First line only: the loader follows it with every folder it searched
        sys.exit("CPU Load shared library found, but could not be loaded:\n"
                 "    {}".format(str(error).splitlines()[0]))

    library.cpuload_take_system.argtypes = [ctypes.POINTER(Sample)]
    library.cpuload_take_system.restype = None

    library.cpuload_take_pid.argtypes = [ctypes.c_uint, ctypes.POINTER(Sample)]
    library.cpuload_take_pid.restype = None

    library.cpuload_take_app.argtypes = [ctypes.c_char_p, ctypes.POINTER(Sample)]
    library.cpuload_take_app.restype = None

    library.cpuload_take_pid_with.argtypes = [ctypes.c_uint,
                                              ctypes.POINTER(Sample),
                                              ctypes.POINTER(Sample)]
    library.cpuload_take_pid_with.restype = None

    library.cpuload_take_app_with.argtypes = [ctypes.c_char_p,
                                              ctypes.POINTER(Sample),
                                              ctypes.POINTER(Sample)]
    library.cpuload_take_app_with.restype = None

    library.cpuload_system_usage.argtypes = [ctypes.POINTER(Sample), ctypes.POINTER(Sample)]
    library.cpuload_system_usage.restype = ctypes.c_double

    library.cpuload_process_usage.argtypes = [ctypes.POINTER(Sample), ctypes.POINTER(Sample)]
    library.cpuload_process_usage.restype = ctypes.c_double

    library.cpuload_version.argtypes = []
    library.cpuload_version.restype = ctypes.c_char_p

    return library


def load_text(name, load):
    """One load as a percentage of the whole machine: one core fully busy out of eight reads 12.5%.

    Negative: the load could not be read (process gone, or not allowed).
    """
    if load < 0.0:
        return "{} n/a".format(name)

    return "{} {:.2f}%".format(name, 100.0 * load)


def main():
    library = load_library()

    # No name given: follow no application (NULL is no name to the library)
    app = sys.argv[1].encode() if len(sys.argv) > 1 else None

    ours = os.getpid()

    # Read the machine once per loop so all three loads cover the same interval
    machine_before, machine_after = Sample(), Sample()
    mine_before, mine_after = Sample(), Sample()
    app_before, app_after = Sample(), Sample()

    # The Ada runtime in the library installs its own Ctrl+C handler when loaded, replacing Python's
    # Put Python's back so Ctrl+C raises KeyboardInterrupt
    signal.signal(signal.SIGINT, signal.default_int_handler)

    print("CPU Load", library.cpuload_version().decode())

    if app is None:
        print("Following the machine and this program."
              " Name an application to follow it as well: {} firefox".format(sys.argv[0]))
    else:
        print("Following the machine, this program, and {}".format(app.decode()))

    library.cpuload_take_system(ctypes.byref(machine_before))
    library.cpuload_take_pid_with(ours, ctypes.byref(machine_before), ctypes.byref(mine_before))
    library.cpuload_take_app_with(app, ctypes.byref(machine_before), ctypes.byref(app_before))

    # Total 0: the counters could not be read (e.g. a library built for another system); without this it would print 0% forever and look idle
    if machine_before.total == 0:
        sys.exit("The machine's counters could not be read at all."
                 " This is what a library built for another system does:"
                 " build it again with -XPJ_OS for this one (linux, macos, windows or freebsd).")

    try:
        while True:
            time.sleep(INTERVAL)

            library.cpuload_take_system(ctypes.byref(machine_after))
            library.cpuload_take_pid_with(ours, ctypes.byref(machine_after), ctypes.byref(mine_after))
            library.cpuload_take_app_with(app, ctypes.byref(machine_after), ctypes.byref(app_after))

            line = [load_text("machine", library.cpuload_system_usage(
                        ctypes.byref(machine_before), ctypes.byref(machine_after))),
                    load_text("this program", library.cpuload_process_usage(
                        ctypes.byref(mine_before), ctypes.byref(mine_after)))]

            if app is not None:
                line.append(load_text(app.decode(), library.cpuload_process_usage(
                    ctypes.byref(app_before), ctypes.byref(app_after))))

            # flush so piped output still comes out once a second
            print(*line, sep=" | ", flush=True)

            # Copies, so the next reading does not overwrite them
            machine_before = Sample.from_buffer_copy(machine_after)
            mine_before = Sample.from_buffer_copy(mine_after)
            app_before = Sample.from_buffer_copy(app_after)
    except KeyboardInterrupt:
        # Ctrl+C interrupts the sleep above
        print("\nStopping")


if __name__ == "__main__":
    main()
