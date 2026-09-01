# Builds the C example of CPU Load, on Linux, macOS and Windows
#
#   make          builds the shared library and the example
#   make run      builds it, then runs it (stop it with Ctrl+C)
#   make clean    removes what was built here

# The root of the repository, holding the header and the library
ROOT = ../..
LIB_DIR = $(ROOT)/lib/relocatable

CC = gcc
CFLAGS = -O2 -Wall -I$(ROOT)/include
LDFLAGS = -L$(LIB_DIR) -lCPU_Load

# The application to follow when running the example
APP =

# Windows sets OS=Windows_NT, Linux and the others leave it unset
ifeq ($(OS),Windows_NT)

    # Run the commands below in cmd, the shell every Windows machine has, so make behaves the same whether it was started from PowerShell or from cmd, and no Unix tools (bash, cp, rm) are needed
    SHELL = cmd.exe
    .SHELLFLAGS = /c

    PJ_OS = windows
    EXE = example_c.exe

    # Windows has no way to record where the library is, but looks for it next to the program, so put a copy there
    # The commands of cmd only accept backslashes in paths, hence the slashes of LIB_DIR turned around
    COPY_LIBRARY = copy /Y $(subst /,\,$(LIB_DIR))\*.dll .

    RUN = .\$(EXE) $(APP)
    DELETE = del /Q

else

    # Nothing but Windows sets OS, so ask uname which of the others this is
    ifeq ($(shell uname),Darwin)

        PJ_OS = macos

        # gprbuild cannot put the Ada runtime inside the library on macOS, and the library looks for it next to itself, so put a copy there
        ADALIB = $(shell gnatls -v | grep adalib | head -1 | tr -d ' ')
        COPY_LIBRARY = cp -f $(ADALIB)/libgnat-*.dylib $(LIB_DIR)

    else

        PJ_OS = linux

        # The library carries the Ada runtime inside it, so nothing to copy
        COPY_LIBRARY = true

    endif

    EXE = example_c

    # Linux and macOS record the folder of the library inside the program, so it is found when running
    LDFLAGS += -Wl,-rpath,$(abspath $(LIB_DIR))

    RUN = ./$(EXE) $(APP)
    DELETE = rm -f

endif

all: library $(EXE)

# Build the shared library of CPU Load, which is the one holding the C interface
library:
	gprbuild -P $(ROOT)/cpuload.gpr -XPJ_OS=$(PJ_OS) -XCPULOAD_LIBRARY_TYPE=relocatable -p

$(EXE): main.c $(ROOT)/include/cpuload.h
	$(CC) $(CFLAGS) main.c $(LDFLAGS) -o $(EXE)
	$(COPY_LIBRARY)

# Follow an application as well:  make run APP=firefox
run: all
	$(RUN)

clean:
	$(DELETE) example_c example_c.exe *.dll

# Build the library before the example, even when asked to run several jobs at once
.NOTPARALLEL:

.PHONY: all library run clean
