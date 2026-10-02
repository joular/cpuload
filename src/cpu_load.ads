--
--  Copyright (c) 2026, Adel Noureddine.
--  All rights reserved. This program and the accompanying materials
--  are made available under the terms of the
--  GNU Lesser General Public License v3.0 only (LGPL-3.0-only)
--  which accompanies this distribution, and is available at:
--  https://www.gnu.org/licenses/lgpl-3.0.en.html
--
--  Author : Adel Noureddine
--

-- CPU Load reports the CPU usage of the system, of one process, or of an application (all of its processes running when each sample is taken)
-- Works on Linux, macOS and Windows
-- It keeps no state. Linked statically, it can be called from any number of Ada tasks. The shared library must be called from one thread or task at a time (see include/cpuload.h)
-- Take a sample, wait, take another, compare:
--     Before := Take ("firefox");
--     delay 1.0;
--     After := Take ("firefox");
--     Put (System_Usage (Before, After)); -- System CPU load
--     Put (Process_Usage (Before, After)); -- Firefox's CPU load
-- Loads run from 0.0 to 1.0 as a share of the whole machine, not of one core: all of one core out of eight gives 0.125
-- Process_Usage is negative when the process could not be read at all

with Interfaces; use Interfaces;

package CPU_Load is

    subtype Process_ID is Natural;

    -- One reading, in microseconds on every OS
    -- Busy: machine time not spent idle, summed over every core
    -- Total: machine time there was to spend (elapsed time times the number of cores); 0 if the sample could not be taken
    -- Used: CPU time of the process or application sampled, 0 for the system alone, negative if it could not be read
    -- Same layout as struct cpuload_sample in include/cpuload.h
    type Sample is
        record
            Busy : Integer_64 := 0;
            Total : Integer_64 := 0;
            Used : Integer_64 := 0;
        end record
        with Convention => C;

    -- Sample the system alone
    function Take return Sample;

    -- Sample the system and one process
    function Take (PID : in Process_ID) return Sample;

    -- Sample the system and every process of an application
    -- App is the program's name without its folders, matched exactly, case-insensitive; "" samples the system alone
    -- Linux and macOS match the program the process runs: "firefox" matches every process of Firefox, and the firefox inside Firefox.app
    -- Windows also ignores a trailing ".exe"
    -- A process that ends between two samples takes its time out of the second one, so that stretch reads low, or 0.0
    function Take (App : in String) return Sample;

    -- The same two against a machine sample already taken: everything is measured over the same stretch, and the machine's counters are read once
    --     Machine := Take;
    --     Ours := Take (Our_PID, Machine);
    --     Theirs := Take ("firefox", Machine);
    function Take (PID : in Process_ID; Machine : in Sample) return Sample;
    function Take (App : in String; Machine : in Sample) return Sample;

    -- CPU load of the whole machine between two samples, 0.0 .. 1.0 (any kind of sample)
    function System_Usage (Before, After : in Sample) return Long_Float;

    -- CPU load of the process or application between two samples, 0.0 .. 1.0
    -- Negative if it could not be read at all: not running (or ended and not yet cleaned up), or the OS will not say. 0.0 is a real reading of no CPU time
    -- An application that is not running reads 0.0; negative only when none of its running processes could be read
    function Process_Usage (Before, After : in Sample) return Long_Float;

    -- Keep it the same as the version in alire.toml
    function Version return String is ("0.0.4");

end CPU_Load;
