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
 * C interface of CPU Load: how much of a machine's CPU is in use, for the whole system, one process, or an application (every process running it)
 *
 * Use the relocatable (shared) build (libcpuload.so, libcpuload.dylib, libcpuload.dll); it starts itself up when loaded, no init call needed
 *
 * Call these functions from one thread at a time: the Ada runtime inside the library has no tasking and one working stack for the whole process
 * A sample is a plain struct, so it can be taken in one thread and compared in another
 *
 * Take a sample, wait, take another, compare:
 *
 *   cpuload_sample before, after;
 *   cpuload_take_app("firefox", &before);
 *   sleep(1);
 *   cpuload_take_app("firefox", &after);
 *   printf("%.2f%%\n", 100.0 * cpuload_process_usage(&before, &after));
 *
 * Sample about a second apart: Linux counts a process in 10 ms units, Windows in ~15 ms, and the BSDs count the machine in ticks of 8 to 10 ms, too coarse for shorter waits. macOS counts in nanoseconds and reads well below a second
 */

#ifndef CPULOAD_H
#define CPULOAD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The CPU counters at one moment, in microseconds, on all systems
 * A total of 0 means the sample could not be taken at all */
typedef struct cpuload_sample {
    int64_t busy;   /* machine time not spent idle, added up over every core */
    int64_t total;  /* machine time altogether, idle included, added up over every core */
    int64_t used;   /* CPU time of what was sampled, 0 for a sample of the system, -1 if it could not be read */
} cpuload_sample;

/* Take a sample of the whole system and write it into *out */
void cpuload_take_system(cpuload_sample *out);

/* Take a sample of the system and of one process
 * used is -1 if the process could not be read (on macOS and Windows, another user's processes), or if pid is too large to be any process (e.g. a negative pid_t turned unsigned)
 * pid 0 samples the system alone */
void cpuload_take_pid(unsigned int pid, cpuload_sample *out);

/* Take a sample of the system and of every process running the named application
 * The name is the program's own, without its folder, matched exactly and case insensitive: "firefox" finds every process of Firefox
 * On macOS every program inside Firefox.app is found too, as its content processes run from a helper bundle in it
 * On Windows a trailing ".exe" is ignored as well, and at most 65536 processes are read
 * A process that ends between two samples takes its time out of the second one, so that stretch reads low, or 0.0
 * A process that could not be read is left out of used, which is -1 only when none of them could be read
*/
void cpuload_take_app(const char *app, cpuload_sample *out);

/* The same two against a machine sample already taken: everything is measured over the same stretch, and the machine's counters are read once
 *
 *   cpuload_sample machine, mine, theirs;
 *   cpuload_take_system(&machine);
 *   cpuload_take_pid_with(getpid(), &machine, &mine);
 *   cpuload_take_app_with("firefox", &machine, &theirs);
 *
 * A NULL machine is a total of 0: cpuload_system_usage gives 0.0, and so does cpuload_process_usage unless the process could not be read */
void cpuload_take_pid_with(unsigned int pid, const cpuload_sample *machine, cpuload_sample *out);
void cpuload_take_app_with(const char *app, const cpuload_sample *machine, cpuload_sample *out);

/* How busy the whole machine was between two samples, 0.0 to 1.0
 * 0.0 for samples that cannot be compared (one not taken, or given the wrong way round) and for a NULL pointer */
double cpuload_system_usage(const cpuload_sample *before, const cpuload_sample *after);

/* How much of the whole machine the process or application used, 0.0 to 1.0: all of one core out of eight gives 0.125, not 1.0
 * NEGATIVE if it could not be read at all (not running, or ended and not yet cleaned up, or the system will not say); 0.0 is a real reading of no CPU time
 * An application that is not running reads 0.0, and is negative only when none of its running processes could be read
*/
double cpuload_process_usage(const cpuload_sample *before, const cpuload_sample *after);

/* Version of the library, owned by the library (do not free it) */
const char *cpuload_version(void);

#ifdef __cplusplus
}
#endif

#endif /* CPULOAD_H */
