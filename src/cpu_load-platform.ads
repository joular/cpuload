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
-- Private, so it belongs to the library alone: programs use the CPU_Load package
private package CPU_Load.Platform is

    -- Measure CPU time of the entire system
    -- Busy and Total come back 0 if the machine's counters cannot be read at all, which is what a library built for another OS does
    function Measure_System return Sample;

    -- Measure a specific PID CPU time
    -- In whatever unit the OS counts time in, the same one Measure_System counts in, so the two can be compared
    -- Returns 0 if the process does not exist, stopped, or cannot be read
    function Ticks_Of_PID (PID : in Process_ID) return Integer_64;

    -- Measure the CPU time of every process of an application, added up
    -- The application is named by its program, matched exactly and without regard to case
    -- Never called with an empty name: CPU_Load answers that one on its own
    -- Returns 0 if the application is not running, or if none of its processes can be read
    function Used_By_App (App : in String) return Integer_64;

end CPU_Load.Platform;
