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

Nothing has to be compiled here: ctypes calls the shared library directly.
The C declarations these classes mirror are in include/cpuload.h.
"""

import ctypes
import os
import signal
import sys
import time
from pathlib import Path

# The root of the repository, holding the shared library built by gprbuild
ROOT = Path(__file__).resolve().parents[2]
LIBRARY_DIR = ROOT / "lib" / "relocatable"

# Time between two samples
INTERVAL = 1.0


class Sample(ctypes.Structure):
    """The CPU counters at one moment, matches struct cpuload_sample.

    The counters are 64 bits whatever the machine, so this never has to guess how wide they are.
    """

    _fields_ = [
        ("busy", ctypes.c_int64),   # machine time not spent idle
        ("total", ctypes.c_int64),  # machine time altogether, idle included
        ("used", ctypes.c_int64),   # CPU time of what was sampled, 0 for a sample of the system
    ]


def library_names():
    """The name the shared library takes on this OS."""
    if sys.platform == "win32":
        return ("libCPU_Load.dll", "CPU_Load.dll")
    if sys.platform == "darwin":
        return ("libCPU_Load.dylib",)
    return ("libCPU_Load.so",)


def find_library():
    """The file holding the shared library, or a message on how to build it when there is none."""
    # Look next to this program first, as Windows has no rpath and wants a copy
    # of the DLL there, then in the folder gprbuild builds the library into
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
    """Loads the shared library, and declares the types of its functions.

    ctypes assumes every function returns an int and takes anything, which would silently truncate the double values on the way back, so each one is declared.
    """
    library_file = find_library()

    try:
        library = ctypes.CDLL(str(library_file))
    except OSError as error:
        # Only the first line, which names what is missing: the loader follows it with every folder it looked into, which is pages long
        sys.exit("CPU Load shared library found, but could not be loaded:\n"
                 "    {}".format(str(error).splitlines()[0]))

    library.cpuload_take_system.argtypes = [ctypes.POINTER(Sample)]
    library.cpuload_take_system.restype = None

    library.cpuload_take_pid.argtypes = [ctypes.c_uint, ctypes.POINTER(Sample)]
    library.cpuload_take_pid.restype = None

    library.cpuload_take_app.argtypes = [ctypes.c_char_p, ctypes.POINTER(Sample)]
    library.cpuload_take_app.restype = None

    library.cpuload_system_usage.argtypes = [ctypes.POINTER(Sample), ctypes.POINTER(Sample)]
    library.cpuload_system_usage.restype = ctypes.c_double

    library.cpuload_process_usage.argtypes = [ctypes.POINTER(Sample), ctypes.POINTER(Sample)]
    library.cpuload_process_usage.restype = ctypes.c_double

    library.cpuload_version.argtypes = []
    library.cpuload_version.restype = ctypes.c_char_p

    return library


def load_text(name, load):
    """One load as a percentage of the whole machine.

    A load is a share of the whole machine, so one core fully busy on an eight core machine reads 12.5%.
    """
    return "{} {:.2f}%".format(name, 100.0 * load)


def main():
    library = load_library()

    # The application to follow, named on the command line
    # No name given means no application is followed, and NULL is what the library reads as no name
    app = sys.argv[1].encode() if len(sys.argv) > 1 else None

    ours = os.getpid()

    # Each thing followed keeps its own pair of samples, so each is measured over exactly the stretch of time between its own two
    machine_before, machine_after = Sample(), Sample()
    mine_before, mine_after = Sample(), Sample()
    app_before, app_after = Sample(), Sample()

    # The Ada runtime inside the shared library installs its own Ctrl+C handler while it starts up, which takes the place of the one Python installed before it
    # Putting Python's back here, after the library is loaded, is what makes Ctrl+C raise KeyboardInterrupt and stop the loop below
    signal.signal(signal.SIGINT, signal.default_int_handler)

    print("CPU Load", library.cpuload_version().decode())

    if app is None:
        print("Following the machine and this program."
              " Name an application to follow it as well: {} firefox".format(sys.argv[0]))
    else:
        print("Following the machine, this program, and {}".format(app.decode()))

    # The first sample of each, which the first reading below is measured against
    library.cpuload_take_system(ctypes.byref(machine_before))
    library.cpuload_take_pid(ours, ctypes.byref(mine_before))
    library.cpuload_take_app(app, ctypes.byref(app_before))

    try:
        while True:
            time.sleep(INTERVAL)

            library.cpuload_take_system(ctypes.byref(machine_after))
            library.cpuload_take_pid(ours, ctypes.byref(mine_after))
            library.cpuload_take_app(app, ctypes.byref(app_after))

            line = [load_text("machine", library.cpuload_system_usage(
                        ctypes.byref(machine_before), ctypes.byref(machine_after))),
                    load_text("this program", library.cpuload_process_usage(
                        ctypes.byref(mine_before), ctypes.byref(mine_after)))]

            if app is not None:
                line.append(load_text(app.decode(), library.cpuload_process_usage(
                    ctypes.byref(app_before), ctypes.byref(app_after))))

            # flush so the readings still come out one per second when the output is piped into another program or into a file
            print(*line, sep=" | ", flush=True)

            # This reading becomes the one the next is measured against, as a copy of its own, so the next reading does not overwrite it
            machine_before = Sample.from_buffer_copy(machine_after)
            mine_before = Sample.from_buffer_copy(mine_after)
            app_before = Sample.from_buffer_copy(app_after)
    except KeyboardInterrupt:
        # Ctrl+C interrupts the sleep above, so the loop stops here instead of being killed on the spot
        print("\nStopping")


if __name__ == "__main__":
    main()
