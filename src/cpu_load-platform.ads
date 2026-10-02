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

-- The OS-specific part of CPU Load: one body per OS in src/linux, src/macos and src/windows, picked by PJ_OS in cpuload.gpr
-- To support a new OS, write a body of this package for it, and nothing else
-- All times are in microseconds, and no function here raises an exception
private package CPU_Load.Platform is

    -- Time that could not be read (0 is a valid reading)
    Not_Read : constant Integer_64 := -1;

    -- Busy and Total of the whole machine, Used left at 0; all zeros if the counters cannot be read
    function Measure_System return Sample;

    -- CPU time of one process; Not_Read if it does not exist, has ended (even before the system cleans it up), or the OS will not let this user look at it
    function Used_By_PID (PID : in Process_ID) return Integer_64;

    -- Whether the process runs the program named App, by the rule of this OS (see Take (App) in CPU_Load); False if its program cannot be found
    function Runs (PID : in Process_ID; App : in String) return Boolean;

    -- Call Action once per process; False if the processes could not be listed
    function For_Each_Process (Action : not null access procedure (PID : in Process_ID))
        return Boolean;

end CPU_Load.Platform;
