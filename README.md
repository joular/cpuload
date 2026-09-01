# <a href="https://www.noureddine.org/research/joular/"><img src="https://raw.githubusercontent.com/joular/.github/main/profile/joular.png" alt="Joular Project" width="64" /></a> CPU Load :bar_chart:

[![License: LGPL v3](https://img.shields.io/badge/License-LGPLv3-blue)](https://www.gnu.org/licenses/lgpl-3.0) [![Ada](https://img.shields.io/badge/Made%20with-Ada-blue)](https://www.adaic.org)

CPU Load is a library that reports CPU load of the system, of a specific process by its ID, or a specific application by its name (meaning every one of its processes, tracking process creation/destruction).

The library is thread-safe, written in Ada, and also provides a [C interface](include/cpuload.h) so it can be used from any language with a C FFI (C, C++, Java, Python, Rust, etc.).

> CPU Load is under active development and currently in beta quality. Expect rough edges and features still being worked on and polished.

## :satellite: Supported platforms

| What is measured | OS | Method |
|---|---|---|
| The whole system | Linux | The `cpu` line of `/proc/stat` |
| The whole system | macOS | `host_statistics`, the machine's own CPU counters |
| The whole system | Windows | `GetSystemTimes` |
| One process, by its number | Linux | `utime` + `stime` of `/proc/<pid>/stat` |
| One process, by its number | macOS | `proc_pidinfo`, the user and system time of the process |
| One process, by its number | Windows | `OpenProcess` + `GetProcessTimes` |
| An application, every process of it | Linux | `/proc` scanned, each process named by `/proc/<pid>/comm` |
| An application, every process of it | macOS | `proc_listpids`, each process named by `proc_pidpath` |
| An application, every process of it | Windows | `EnumProcesses` + `QueryFullProcessImageNameW` |

macOS is supported on Apple Silicon.
BSD support is planned and will come in a future version.

## Building

With [Alire](https://alire.ada.dev):

```bash
alr build
```

Or directly with GNAT:

```bash
gprbuild -P cpuload.gpr -XPJ_OS=macos
```

The build produces a static library by default. `-XPJ_OS` says which system to build for: `linux`, `macos` or `windows`. Windows is the only one recognised on its own, as nothing tells macOS from Linux at build time, so **pass `-XPJ_OS` yourself on the other two**. Alire sets it on its own, and so do the Makefiles of the examples, which ask `uname`. A library built for another system reads no counters at all and reports 0% for everything.

For other library types (shared, etc.), set `-XCPULOAD_LIBRARY_TYPE`:

```bash
gprbuild -P cpuload.gpr -XPJ_OS=macos -XCPULOAD_LIBRARY_TYPE=relocatable
```

`relocatable` builds the shared library (`libCPU_Load.so` / `.dll` / `.dylib`) that carries the C interface and is standalone: it starts itself up when loaded. On Linux and Windows it is encapsulated as well, carrying the Ada runtime with it, so it is one self-contained file.
gprbuild cannot encapsulate on macOS, so the library reads the Ada runtime from its own file there, and looks for it next to itself. Copy it in once the library is built (the Makefiles of the examples do this for you):

```bash
cp "$(gnatls -v | grep adalib | tr -d ' ')"/libgnat-*.dylib lib/relocatable/
```

## Using from Ada

```ada
with Ada.Text_IO; use Ada.Text_IO;
with CPU_Load; use CPU_Load;

procedure Measure is
    --  The first sample, which the first reading below is measured against
    Before : Sample := Take ("firefox");
    After : Sample;
begin
    for I in 1 .. 5 loop
        delay 1.0;
        After := Take ("firefox");

        --  The same pair of samples gives both figures
        Put_Line ("machine:" & Long_Float'Image (100.0 * System_Usage (Before, After)) & " %");
        Put_Line ("firefox:" & Long_Float'Image (100.0 * Process_Usage (Before, After)) & " %");

        --  This reading becomes the one the next is measured against
        Before := After;
    end loop;
end Measure;
```

The whole interface is five functions: `Sample`, the three `Take` functions (the system alone, one `Process_ID`, or an application by name), and the two functions that compare a pair of samples.

A full example program is in [example/src/example_cpu_load.adb](example/src/example_cpu_load.adb). It follows the machine, itself, and an application named on the command line, once per second until stopped with Ctrl+C:

```bash
gprbuild -P example/example.gpr -XPJ_OS=macos -p
./example/example_cpu_load firefox
```

Give `-XPJ_OS` here too: the example builds the library with it, and one built for another system reads no counters at all and reports 0% for everything.

With Alire, add the library to your project with `alr with cpuload`.

## Using from C (and any other language)

The C declarations are in [include/cpuload.h](include/cpuload.h). Build the relocatable library, then:

```c
#include "cpuload.h"

cpuload_sample before, after;

cpuload_take_app("firefox", &before);
sleep(1);
cpuload_take_app("firefox", &after);

printf("machine: %.2f%%\n", 100.0 * cpuload_system_usage(&before, &after));
printf("firefox: %.2f%%\n", 100.0 * cpuload_process_usage(&before, &after));
```

A full example program is in [example/c/main.c](example/c/main.c). Like the Ada one, it follows the machine, itself, and an application named on the command line, once per second until stopped with Ctrl+C. It comes with a [Makefile](example/c/Makefile) that builds the shared library and the program:

```bash
make -C example/c run APP=firefox
```

To build it by hand instead, from the root of the repository, first compile the library:

```bash
gprbuild -P cpuload.gpr -XPJ_OS=macos -XCPULOAD_LIBRARY_TYPE=relocatable
```

Then compile the C program:

```bash
gcc example/c/main.c -Iinclude -Llib/relocatable -lCPU_Load -Wl,-rpath,"$PWD/lib/relocatable" -o example/c/example_c
```

`-I` is the folder holding `cpuload.h`, `-L` and `-l` the library to link with, and `-rpath` the folder where the program looks for the library when it runs. Without `-rpath`, the program still compiles but stops on start with a "library not loaded" error, unless you set `LD_LIBRARY_PATH` yourself. macOS works the same way, as long as the Ada runtime sits next to the library as above. Windows has no `-rpath`: put a copy of the DLL next to the program instead (which is what the Makefile does).

## Using from Python

From Python, the same interface through ctypes:

```python
import ctypes, time

class Sample(ctypes.Structure):
    _fields_ = [("busy", ctypes.c_int64), ("total", ctypes.c_int64), ("used", ctypes.c_int64)]

lib = ctypes.CDLL("lib/relocatable/libCPU_Load.so")  # libCPU_Load.dylib on macOS, CPU_Load.dll on Windows
lib.cpuload_system_usage.restype = ctypes.c_double
lib.cpuload_process_usage.restype = ctypes.c_double
lib.cpuload_version.restype = ctypes.c_char_p

before, after = Sample(), Sample()

lib.cpuload_take_app(b"firefox", ctypes.byref(before))
time.sleep(1)
lib.cpuload_take_app(b"firefox", ctypes.byref(after))

print("machine:", 100.0 * lib.cpuload_system_usage(ctypes.byref(before), ctypes.byref(after)), "%")
print("firefox:", 100.0 * lib.cpuload_process_usage(ctypes.byref(before), ctypes.byref(after)), "%")
```

Note that Python puts its own Ctrl+C handler back after loading the library if you want to stop a reading loop that way: the Ada runtime installs its own while it starts up.

Java (through FFM or JNA), Rust (through `libloading` or FFI declarations), and every other language with a C FFI work the same way.

## Adding a new OS

The package spec [src/cpu_load.ads](src/cpu_load.ads) is shared by every OS, and holds the usage functions. Each OS brings its own body of the three `Take` functions ([src/linux](src/linux/cpu_load.adb), [src/macos](src/macos/cpu_load.adb), [src/windows](src/windows/cpu_load.adb)), and [cpuload.gpr](cpuload.gpr) picks the folder for the OS being built from the `PJ_OS` symbol. To support a new OS, write the implementation body and add its folder there.

## 📜 License

CPU Load is licensed under the GNU Lesser General Public License 3 license only (LGPL-3.0-only).

Copyright © 2026, Adel Noureddine.
All rights reserved. This program and the accompanying materials are made available under the terms of the [GNU Lesser General Public License v3.0 (LGPL-3.0-only)](https://www.gnu.org/licenses/lgpl-3.0.en.html) which accompanies this distribution.

Author: Prof. Adel Noureddine
