/*
 * Copyright (c) 2026, Adel Noureddine.
 * All rights reserved. This program and the accompanying materials
 * are made available under the terms of the
 * GNU Lesser General Public License v3.0 only (LGPL-3.0-only)
 * which accompanies this distribution, and is available at:
 * https://www.gnu.org/licenses/lgpl-3.0.en.html
 *
 * Author : Adel Noureddine
 */

/*
 * Prints the CPU load of the machine, of this very program, and of an application named on the command line, once per second, until stopped with Ctrl+C, using the C interface of CPU Load
 *
 * Build it with the Makefile next to this file, which builds the shared library of CPU Load as well:
 *   make
 *   ./example_c firefox
 *
 * Or by hand, against the relocatable (shared) library, from the root of the repository:
 *   gprbuild -P cpuload.gpr -XCPULOAD_LIBRARY_TYPE=relocatable
 *   gcc example/c/main.c -Iinclude -Llib/relocatable -lCPU_Load -Wl,-rpath,"$PWD/lib/relocatable" -o example/c/example_c
 *
 * -I is the folder holding cpuload.h, -L and -l the library to link with, and -rpath the folder where the program looks for the library when it runs
 */

#include <signal.h>
#include <stdio.h>

#ifdef _WIN32
#include <windows.h>
#define sleep_one_second() Sleep(1000)
#define current_pid() ((unsigned int) GetCurrentProcessId())
#else
#include <unistd.h>
#define sleep_one_second() sleep(1)
#define current_pid() ((unsigned int) getpid())
#endif

#include "cpuload.h"

/* Set to 1 when Ctrl+C is pressed, so the reading loop stops
 * volatile sig_atomic_t is the only type a signal handler may safely write */
static volatile sig_atomic_t stop_asked = 0;

/* Called when Ctrl+C is pressed
 * It only asks the loop to stop, as printing is not safe to do from a signal handler */
static void on_ctrl_c(int signal_number)
{
    (void) signal_number;
    stop_asked = 1;
}

/* Prints one load as a percentage of the whole machine
 * A load is a share of the whole machine, so one core fully busy on an eight core machine reads 12.5% */
static void print_load(const char *name, double load)
{
    printf("%s %.2f%%", name, 100.0 * load);
}

int main(int argc, char **argv)
{
    /* The application to follow, named on the command line
     * No name given means no application is followed */
    const char *app = (argc > 1) ? argv[1] : NULL;

    unsigned int ours = current_pid();

    /* The machine is read once per reading, and the other two are measured against that one reading
     * Each of the three is then measured over exactly the same stretch of time, and the machine's counters are read once a second rather than three times */
    cpuload_sample machine_before, machine_after;
    cpuload_sample mine_before, mine_after;
    cpuload_sample app_before, app_after;

    printf("CPU Load %s\n", cpuload_version());

    if (app == NULL)
        printf("Following the machine and this program. Name an application to follow it as well: %s firefox\n", argv[0]);
    else
        printf("Following the machine, this program, and %s\n", app);

    /* Stop cleanly on Ctrl+C, instead of being killed on the spot */
    signal(SIGINT, on_ctrl_c);

    /* The first sample of each, which the first reading below is measured against */
    cpuload_take_system(&machine_before);
    cpuload_take_pid_with(ours, &machine_before, &mine_before);
    cpuload_take_app_with(app, &machine_before, &app_before);

    /* A total of zero is the library saying it could not read the machine's counters at all
     * It is what a library built for another system does here, and it would otherwise show as a row of 0% every second, which looks like an idle machine rather than a build to redo */
    if (machine_before.total == 0) {
        printf("The machine's counters could not be read at all."
               " This is what a library built for another system does:"
               " build it again with -XPJ_OS for this one (linux, macos or windows).\n");
        return 1;
    }

    while (!stop_asked) {
        sleep_one_second();

        /* Ctrl+C interrupts the sleep above, so don't print one last reading after it */
        if (stop_asked)
            break;

        cpuload_take_system(&machine_after);
        cpuload_take_pid_with(ours, &machine_after, &mine_after);
        cpuload_take_app_with(app, &machine_after, &app_after);

        print_load("machine", cpuload_system_usage(&machine_before, &machine_after));
        printf(" | ");
        print_load("this program", cpuload_process_usage(&mine_before, &mine_after));

        if (app != NULL) {
            printf(" | ");
            print_load(app, cpuload_process_usage(&app_before, &app_after));
        }

        printf("\n");

        /* This reading becomes the one the next is measured against */
        machine_before = machine_after;
        mine_before = mine_after;
        app_before = app_after;
    }

    printf("Stopping\n");
    return 0;
}
