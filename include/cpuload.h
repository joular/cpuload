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
 * C interface of CPU Load, a library reporting how much of a machine's CPU is in use: the whole system, one process by its number, or an application, meaning every process running it
 *
 * Use it with the relocatable (shared) build of the library (libCPU_Load.so on Linux, CPU_Load.dll on Windows), which starts itself up when loaded: no other initialization call is needed
 *
 * Library is thread-safe
 *
 * How to use it: take a sample, wait, take another sample, and compare the two
 *
 *   cpuload_sample before, after;
 *   cpuload_take_app("firefox", &before);
 *   sleep(1);
 *   cpuload_take_app("firefox", &after);
 *   printf("%.2f%%\n", 100.0 * cpuload_process_usage(&before, &after));
 */

#ifndef CPULOAD_H
#define CPULOAD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The CPU counters at one moment */
typedef struct cpuload_sample {
    int64_t busy;   /* machine time not spent idle */
    int64_t total;  /* machine time altogether, idle included */
    int64_t used;   /* CPU time of what was sampled, 0 for a sample of the system */
} cpuload_sample;

/* Take a sample of the whole system and write it into *out */
void cpuload_take_system(cpuload_sample *out);

/* Take a sample of the system and of one process, by its number
 * used is 0 if that number is not running, and 0 is not a process number on either system */
void cpuload_take_pid(unsigned int pid, cpuload_sample *out);

/* Take a sample of the system and of every process running the named application
 * The name is the program's own, without its folder, and it is exactly matched and case insensitive, so "firefox" finds "Firefox"
 * On Windows a trailing ".exe" is ignored as well, so "firefox" also finds "firefox.exe"
*/
void cpuload_take_app(const char *app, cpuload_sample *out);

/* How busy the whole machine was between two samples, from 0.0 to 1.0
 * Two samples that cannot be compared (one that could not be taken, or a pair given the wrong way round) give 0.0, and so does a NULL pointer */
double cpuload_system_usage(const cpuload_sample *before, const cpuload_sample *after);

/* How much of the whole machine the process or application used, from 0.0 to 1.0
 * It is a share of the whole machine, not of one core: a process using all of one core of an eight core machine gives 0.125, not 1.0
*/
double cpuload_process_usage(const cpuload_sample *before, const cpuload_sample *after);

/* Return the version of the library, owned by the library (do not free it) */
const char *cpuload_version(void);

#ifdef __cplusplus
}
#endif

#endif /* CPULOAD_H */
