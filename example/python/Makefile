# Builds the shared library the Python example of CPU Load needs, on Linux, macOS and Windows
#
#   make          builds the shared library
#   make run      builds it, then runs the example (stop it with Ctrl+C)
#   make clean    removes what was built here
#
# The example itself is not compiled: ctypes calls the shared library directly

# The root of the repository, holding the library
ROOT = ../..
LIB_DIR = $(ROOT)/lib/relocatable

# The application to follow when running the example
APP =

# Windows sets OS=Windows_NT, Linux and the others leave it unset
ifeq ($(OS),Windows_NT)

    # Run the commands below in cmd, the shell every Windows machine has, so make behaves the same whether it was started from PowerShell or from cmd, and no Unix tools (bash, cp, rm) are needed
    SHELL = cmd.exe
    .SHELLFLAGS = /c

    PJ_OS = windows
    PYTHON = python

    # Windows has no way to record where the library is, but looks for it next to the program, so put a copy there
    # The commands of cmd only accept backslashes in paths, hence the slashes of LIB_DIR turned around
    COPY_LIBRARY = copy /Y $(subst /,\,$(LIB_DIR))\*.dll .

    CLEAN = del /Q *.dll & if exist __pycache__ rmdir /S /Q __pycache__

else

    # Nothing but Windows sets OS, so ask uname which of the others this is
    ifeq ($(shell uname),Darwin)

        PJ_OS = macos

        # gprbuild cannot put the Ada runtime inside the library on macOS, and the library looks for it next to itself, so put a copy there
        ADALIB = $(shell gnatls -v | grep adalib | head -1 | tr -d ' ')
        COPY_LIBRARY = cp -f $(ADALIB)/libgnat-*.dylib $(LIB_DIR)

    else

        PJ_OS = linux

        # Linux records the folder of the Ada runtime inside the library, so nothing to copy
        COPY_LIBRARY = true

    endif

    PYTHON = python3

    CLEAN = rm -f *.dll && rm -rf __pycache__

endif

all: library

# Build the shared library of CPU Load, which is the one holding the C interface ctypes calls
library:
	gprbuild -P $(ROOT)/cpuload.gpr -XPJ_OS=$(PJ_OS) -XCPULOAD_LIBRARY_TYPE=relocatable -p
	$(COPY_LIBRARY)

# Follow an application as well:  make run APP=firefox
run: all
	$(PYTHON) main.py $(APP)

clean:
	$(CLEAN)

.PHONY: all library run clean
