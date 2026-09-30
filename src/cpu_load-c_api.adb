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

package body CPU_Load.C_API is

    use type Interfaces.C.unsigned;
    use type Interfaces.C.Strings.chars_ptr;

    Version_C : aliased constant Interfaces.C.char_array := Interfaces.C.To_C (Version);

    -- Bounds the scan of an unterminated C string; real program names are far shorter
    Max_App_Name : constant Interfaces.C.size_t := 4_096;

    --------------------------------------------------

    function Machine_Of (Machine : access constant Sample) return Sample is
        (if Machine = null then (others => 0) else Machine.all);

    function App_Of (App : in Interfaces.C.Strings.chars_ptr) return String is
        (if App = Interfaces.C.Strings.Null_Ptr
         then ""
         else Interfaces.C.Strings.Value (App, Max_App_Name));

    -- PIDs above Process_ID'Last cannot exist: report the process as unreadable
    function Take_PID (PID : in Interfaces.C.unsigned; Machine : in Sample) return Sample is
        (if PID <= Interfaces.C.unsigned (Process_ID'Last)
         then Take (Process_ID (PID), Machine)
         else (Busy => Machine.Busy, Total => Machine.Total, Used => -1));

    --------------------------------------------------

    procedure C_Take_System (Result : access Sample) is
    begin
        if Result = null then
            return;
        end if;

        -- Zeros if Take raises
        Result.all := (others => 0);

        Result.all := Take;
    exception
        when others =>
            -- No Ada exception may cross into the C caller
            null;
    end C_Take_System;

    --------------------------------------------------

    procedure C_Take_PID (PID : in Interfaces.C.unsigned; Result : access Sample) is
    begin
        if Result = null then
            return;
        end if;

        Result.all := (others => 0);

        Result.all := Take_PID (PID, Take);
    exception
        when others =>
            null;
    end C_Take_PID;

    --------------------------------------------------

    procedure C_Take_App (App : in Interfaces.C.Strings.chars_ptr;
                          Result : access Sample) is
    begin
        if Result = null then
            return;
        end if;

        Result.all := (others => 0);

        Result.all := Take (App_Of (App));
    exception
        when others =>
            null;
    end C_Take_App;

    --------------------------------------------------

    procedure C_Take_PID_With (PID : in Interfaces.C.unsigned;
                               Machine : access constant Sample;
                               Result : access Sample) is
    begin
        if Result = null then
            return;
        end if;

        Result.all := (others => 0);

        Result.all := Take_PID (PID, Machine_Of (Machine));
    exception
        when others =>
            null;
    end C_Take_PID_With;

    --------------------------------------------------

    procedure C_Take_App_With (App : in Interfaces.C.Strings.chars_ptr;
                               Machine : access constant Sample;
                               Result : access Sample) is
    begin
        if Result = null then
            return;
        end if;

        Result.all := (others => 0);

        Result.all := Take (App_Of (App), Machine_Of (Machine));
    exception
        when others =>
            null;
    end C_Take_App_With;

    --------------------------------------------------

    function C_System_Usage (Before, After : access constant Sample)
        return Interfaces.C.double is
    begin
        if Before = null or else After = null then
            return 0.0;
        end if;

        return Interfaces.C.double (System_Usage (Before.all, After.all));
    exception
        when others =>
            return 0.0;
    end C_System_Usage;

    --------------------------------------------------

    function C_Process_Usage (Before, After : access constant Sample)
        return Interfaces.C.double is
    begin
        if Before = null or else After = null then
            return 0.0;
        end if;

        return Interfaces.C.double (Process_Usage (Before.all, After.all));
    exception
        when others =>
            return 0.0;
    end C_Process_Usage;

    --------------------------------------------------

    function C_Version return System.Address is
    begin
        return Version_C'Address;
    end C_Version;

end CPU_Load.C_API;
