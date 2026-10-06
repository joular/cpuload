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
 * A number after the name stops the program after that many readings ("" follows no application):
 *   ./example_c "" 3
 *
 * Or by hand, against the relocatable (shared) library, from the root of the repository:
 *   gprbuild -P cpuload.gpr -XCPULOAD_LIBRARY_TYPE=relocatable
 *   gcc example/c/main.c -Iinclude -Llib/relocatable -lcpuload -Wl,-rpath,"$PWD/lib/relocatable" -o example/c/example_c
 *
 * -rpath is where the program looks for the library when it runs
 */

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>

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

/* volatile sig_atomic_t is the only type a signal handler may safely write */
static volatile sig_atomic_t stop_asked = 0;

/* Only asks the loop to stop: printing is not safe in a signal handler */
static void on_ctrl_c(int signal_number)
{
    (void) signal_number;
    stop_asked = 1;
}

/* A load is a share of the whole machine: one core fully busy out of eight reads 12.5%
 * Negative: the load could not be read (process gone, or not allowed) */
static void print_load(const char *name, double load)
{
    if (load < 0.0)
        printf("%s n/a", name);
    else
        printf("%s %.2f%%", name, 100.0 * load);
}

int main(int argc, char **argv)
{
    /* No name, or an empty one: follow no application */
    const char *app = (argc > 1 && argv[1][0] != '\0') ? argv[1] : NULL;

    /* How many readings to take before stopping, or zero to run until Ctrl+C */
    int wanted = (argc > 2) ? atoi(argv[2]) : 0;
    int taken = 0;

    unsigned int ours = current_pid();

    /* Read the machine once per loop so all three loads cover the same interval */
    cpuload_sample machine_before, machine_after;
    cpuload_sample mine_before, mine_after;
    cpuload_sample app_before, app_after;

    printf("CPU Load %s\n", cpuload_version());

    if (app == NULL)
        printf("Following the machine and this program. Name an application to follow it as well: %s firefox\n", argv[0]);
    else
        printf("Following the machine, this program, and %s\n", app);

    signal(SIGINT, on_ctrl_c);

    cpuload_take_system(&machine_before);
    cpuload_take_pid_with(ours, &machine_before, &mine_before);
    cpuload_take_app_with(app, &machine_before, &app_before);

    /* Total 0: the counters could not be read (e.g. a library built for another system); without this it would print 0% forever and look idle */
    if (machine_before.total == 0) {
        printf("The machine's counters could not be read at all."
               " This is what a library built for another system does:"
               " build it again with -XPJ_OS for this one (linux, macos, windows or freebsd).\n");
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

        machine_before = machine_after;
        mine_before = mine_after;
        app_before = app_after;

        if (wanted > 0 && ++taken >= wanted)
            break;
    }

    printf("Stopping\n");
    return 0;
}
