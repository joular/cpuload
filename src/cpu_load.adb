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

    -- Part as a share of Whole, 0.0 .. 1.0
    -- 0.0 when there is nothing to divide: no time passed, or the part went backwards
    function Share (Part, Whole : in Integer_64) return Long_Float is
        (if Whole <= 0 or else Part <= 0 then 0.0
         elsif Part >= Whole then 1.0
         else Long_Float (Part) / Long_Float (Whole));

    --------------------------------------------------

    function System_Usage (Before, After : in Sample) return Long_Float is
        (if Before.Total = 0 then 0.0
         else Share (After.Busy - Before.Busy, After.Total - Before.Total));

    --------------------------------------------------

    function Process_Usage (Before, After : in Sample) return Long_Float is
        (if Before.Used < 0 or else After.Used < 0 then -1.0
         elsif Before.Total = 0 then 0.0
         else Share (After.Used - Before.Used, After.Total - Before.Total));

    --------------------------------------------------

    -- CPU time of all processes of App, 0 if it is not running
    -- Unreadable processes are skipped; Not_Read if listing failed or all of App's processes were unreadable
    function Used_By_App (App : in String) return Integer_64 is
        Sum : Integer_64 := 0;
        Read_Any : Boolean := False;
        Unread_Any : Boolean := False;

        procedure Add (PID : in Process_ID) is
            Used : Integer_64;
        begin
            -- Check the name first: cheaper than reading times
            if Platform.Runs (PID, App) then
                Used := Platform.Used_By_PID (PID);

                if Used = Platform.Not_Read then
                    Unread_Any := True;
                else
                    Sum := Sum + Used;
                    Read_Any := True;
                end if;
            end if;
        end Add;
    begin
        if not Platform.For_Each_Process (Add'Access) then
            return Platform.Not_Read;
        end if;

        return (if Unread_Any and not Read_Any then Platform.Not_Read else Sum);
    end Used_By_App;

    --------------------------------------------------

    -- Machine.Used is ignored; PID 0 samples the system only
    function Take (PID : in Process_ID; Machine : in Sample) return Sample is
        ((Busy => Machine.Busy,
          Total => Machine.Total,
          Used => (if PID = 0 then 0 else Platform.Used_By_PID (PID))));

    --------------------------------------------------

    -- Used is read ~1 ms after Machine; the lag is the same in both samples, so it cancels out
    function Take (App : in String; Machine : in Sample) return Sample is
        ((Busy => Machine.Busy,
          Total => Machine.Total,
          Used => (if App = "" then 0 else Used_By_App (App))));

    --------------------------------------------------

    function Take return Sample is (Platform.Measure_System);

    function Take (PID : in Process_ID) return Sample is
        (Take (PID, Platform.Measure_System));

    function Take (App : in String) return Sample is
        (Take (App, Platform.Measure_System));

end CPU_Load;
