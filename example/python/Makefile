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

# Windows sets OS=Windows_NT, the others leave it unset
ifeq ($(OS),Windows_NT)

    # cmd is the shell every Windows machine has, so make behaves the same from PowerShell or cmd, with no Unix tools needed
    SHELL = cmd.exe
    .SHELLFLAGS = /c

    PYTHON = python

    # Windows looks for the library next to the program, so put a copy there (cmd only accepts backslashes)
    COPY_LIBRARY = copy /Y $(subst /,\,$(LIB_DIR))\*.dll .

    CLEAN = del /Q *.dll 2>nul & if exist __pycache__ rmdir /S /Q __pycache__

else

    PYTHON = python3

    COPY_LIBRARY = true

    CLEAN = rm -f *.dll && rm -rf __pycache__

endif

all: library

# The shared library holds the C interface ctypes calls. The project file picks the OS on its own
library:
	gprbuild -P $(ROOT)/cpuload.gpr -XCPULOAD_LIBRARY_TYPE=relocatable -p
	$(COPY_LIBRARY)

# Follow an application as well:  make run APP=firefox
run: all
	$(PYTHON) main.py $(APP)

clean:
	$(CLEAN)

.PHONY: all library run clean
