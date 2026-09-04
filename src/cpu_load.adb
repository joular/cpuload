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

with CPU_Load.Platform;

package body CPU_Load is

    --------------------------------------------------

    function Take return Sample is (Platform.Measure_System);

    --------------------------------------------------

    function Take (PID : in Process_ID) return Sample is
        (Take (PID, Platform.Measure_System));

    --------------------------------------------------

    function Take (App : in String) return Sample is
        (Take (App, Platform.Measure_System));

    --------------------------------------------------

    function Take (PID : in Process_ID; Machine : in Sample) return Sample is
        -- Only the machine's own counters are kept: whatever Machine was measuring is not what is measured here
        Result : Sample := (Busy => Machine.Busy, Total => Machine.Total, Used => 0);
    begin
        -- No PID, so return the machine's reading alone
        if PID /= 0 then
            Result.Used := Platform.Ticks_Of_PID (PID);
        end if;

        return Result;
    end Take;

    --------------------------------------------------

    function Take (App : in String; Machine : in Sample) return Sample is
        Result : Sample := (Busy => Machine.Busy, Total => Machine.Total, Used => 0);
    begin
        -- No app name, so return the machine's reading alone
        if App /= "" then
            Result.Used := Platform.Used_By_App (App);
        end if;

        return Result;
    end Take;

end CPU_Load;
