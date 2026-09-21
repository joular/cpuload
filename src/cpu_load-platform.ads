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

-- The part of CPU Load that is specific to each OS
-- One body per OS lives in src/linux, src/macos and src/windows, and cpuload.gpr picks the folder for the OS being built from the PJ_OS symbol
-- To support a new OS, write a body of this package for it, and nothing else
-- Every time below is in nanoseconds, whatever unit the OS itself counts in, so the three can be compared and so one body reads the same as another
-- Private, so it belongs to the library alone: programs use the CPU_Load package
private package CPU_Load.Platform is

    -- What a time comes back as when it could not be read at all
    -- Not the same as a time of zero, which is a true reading of something that used no CPU time
    Not_Read : constant Integer_64 := -1;

    -- What Used_By_App answers, out of the sum its body added up
    -- Sum is the time of the processes that answered, and Any_Unread says whether any process of the application would not say how much it used
    -- A sum of zero means one of two things, and they must not look alike:
    --     1) nothing refused, so the application really used no CPU time, which is a true reading of zero
    --     2) or every process that matched refused, so there is nothing to report at all, which is Not_Read
    -- Written here once rather than in each body, so a body for a new OS cannot answer it differently by accident
    function Sum_Or_Not_Read (Sum : in Integer_64; Any_Unread : in Boolean) return Integer_64 is
        (if Any_Unread and then Sum = 0 then Not_Read else Sum);

    -- Measure CPU time of the entire system
    -- Busy is the nanoseconds the machine spent doing something, added up over every core
    -- Total is the nanoseconds the whole machine had to spend over that same stretch, idle time included
    -- Linux and Windows add up their own counters for it, which they keep current enough to divide by
    -- macOS reads a clock and multiplies by the number of cores instead: its own counters move only about once every 90 ms, so two samples taken closer together than that would show no time passing at all, and every reading between them would be thrown away
    -- Both come back 0 if the machine's counters cannot be read at all, which is what a library built for another OS does
    function Measure_System return Sample;

    -- Measure a specific PID CPU time, in nanoseconds
    -- Returns 0 if the process used no CPU time, and -1 if its time could not be read at all: it does not exist, it has stopped, or the OS does not let this user look at it
    function Used_By_PID (PID : in Process_ID) return Integer_64;

    -- Measure the CPU time of every process of an application, added up, in nanoseconds
    -- The application is named by its program, matched exactly and without regard to case
    -- Never called with an empty name: CPU_Load answers that one on its own
    -- Returns 0 if the application is not running, which is a true reading of no CPU time used
    -- Returns -1 if the processes of the machine could not be listed, or if some of them are the application's and none of their times could be read: there is no reading to give rather than a reading of zero
    -- A process that matched but could not be read on its own is left out of the sum, which is then short by however much it used
    function Used_By_App (App : in String) return Integer_64;

end CPU_Load.Platform;
