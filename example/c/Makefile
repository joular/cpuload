# Builds the C example of CPU Load, on Linux, macOS, Windows and FreeBSD
# This is GNU make: on FreeBSD, run gmake instead of make
#
#   make          builds the shared library and the example
#   make run      builds it, then runs it (stop it with Ctrl+C)
#   make clean    removes what was built here

# The root of the repository, holding the header and the library
ROOT = ../..
LIB_DIR = $(ROOT)/lib/relocatable

CC = gcc
CFLAGS = -O2 -Wall -I$(ROOT)/include
LDFLAGS = -L$(LIB_DIR) -lcpuload

# The application to follow when running the example
APP =

# Windows sets OS=Windows_NT, the others leave it unset
ifeq ($(OS),Windows_NT)

    # cmd is the shell every Windows machine has, so make behaves the same from PowerShell or cmd, with no Unix tools needed
    SHELL = cmd.exe
    .SHELLFLAGS = /c

    EXE = example_c.exe

    # Windows looks for the library next to the program, so put a copy there (cmd only accepts backslashes)
    COPY_LIBRARY = copy /Y $(subst /,\,$(LIB_DIR))\*.dll .

    RUN = .\$(EXE) $(APP)
    DELETE = del /Q

else

    EXE = example_c

    # Linux, macOS and FreeBSD record the folder of the library inside the program, so it is found when running
    LDFLAGS += -Wl,-rpath,$(abspath $(LIB_DIR))

    COPY_LIBRARY = true

    RUN = ./$(EXE) $(APP)
    DELETE = rm -f

endif

all: library $(EXE)

# The shared library holds the C interface. The project file picks the OS on its own
library:
	gprbuild -P $(ROOT)/cpuload.gpr -XCPULOAD_LIBRARY_TYPE=relocatable -p
	$(COPY_LIBRARY)

$(EXE): main.c $(ROOT)/include/cpuload.h
	$(CC) $(CFLAGS) main.c $(LDFLAGS) -o $(EXE)

# Follow an application as well:  make run APP=firefox
run: all
	$(RUN)

clean:
	$(DELETE) example_c example_c.exe *.dll

# Build the library before the example, even with several jobs
.NOTPARALLEL:

.PHONY: all library run clean
