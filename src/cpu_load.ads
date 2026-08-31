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

-- CPU Load reports:
--     the system CPU usage
--     a specific process CPU usage
--     an application CPU usage (including all its processes, tracked on creation/destruction)
-- CPU Load works on Linux and Windows, and is thread-safe
-- How to use it: take a sample, wait, take another sample, calculate CPU load
--     Before := Take ("firefox");
--     delay 1.0;
--     After := Take ("firefox");
--     Put (System_Usage (Before, After)); -- System CPU load
--     Put (Process_Usage (Before, After)); -- Firefox's CPU load

with Interfaces; use Interfaces;

package CPU_Load is

    -- Type for Process ID
    subtype Process_ID is Natural;

    -- A sample reading
    -- Busy: machine time spend doing something
    -- Total: total machine time (busy + idle)
    -- Used: CPU time of the process or application monitored (0 if only monitoring the entire system)
    type Sample is
        record
            Busy : Integer_64 := 0;
            Total : Integer_64 := 0;
            Used : Integer_64 := 0;
        end record;
    
    -- Take a sample of the entire system only
    function Take return Sample;

    -- Take a sample of a specific process by its ID
    function Take (PID : in Process_ID) return Sample;

    -- Take a sample of an application (all of its PIDs)
    -- On Linux, application name is case-insensitive but with exact match
    -- On Windows, also, the trailing ".exe" is ignored (so "firefox" will also match "firefox.exe")
    -- An empty string means taking a sample reading of the entire system only
    function Take (App : in String) return Sample;

    -- Calculate the CPU load of the entire system (for any sample taken, PID, entire system or application)
    function System_Usage (Before, After : in Sample) return Long_Float is
        (if Before.Total = 0
            or else After.Total <= Before.Total
            or else After.Busy <= Before.Busy
         then 
            0.0
         elsif After.Busy - Before.Busy >= After.Total - Before.Total
         then
            1.0
         else Long_Float (After.Busy - Before.Busy) / Long_Float (After.Total - Before.Total))
        ;
    
    -- Calculate the CPU load of the process or the application
    function Process_Usage (Before, After : in Sample) return Long_Float is
        (if Before.Total = 0
            or else After.Total <= Before.Total
            or else After.Used <= Before.Used
         then 
            0.0
         elsif After.Used - Before.Used >= After.Total - Before.Total
         then
            1.0
         else Long_Float (After.Used - Before.Used) / Long_Float (After.Total - Before.Total)
        );
    
    -- Return the version of the library as a String
    function Version return String is
        (
            -- Keep it the same as the version in alire.toml
            "0.0.1"
        );

end CPU_Load;