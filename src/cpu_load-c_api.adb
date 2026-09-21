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

    -- The version as a C string (a NUL terminated array of C chars), built once here
    Version_C : aliased constant Interfaces.C.char_array := Interfaces.C.To_C (Version);

    -- The longest application name read from C
    -- No program is named anywhere near this long, and it keeps a pointer to something that is not a string from being walked over until it happens on a NUL
    Max_App_Name : constant Interfaces.C.size_t := 4_096;

    --------------------------------------------------

    -- Translate one sample to its C form
    -- Both hold Interfaces.Integer_64 counters, so nothing is narrowed on the way
    function To_C (Item : in Sample) return C_Sample is
        ((Busy => Item.Busy,
          Total => Item.Total,
          Used => Item.Used));

    -- And back, for the two functions that compare a pair of samples
    function From_C (Item : in C_Sample) return Sample is
        ((Busy => Item.Busy,
          Total => Item.Total,
          Used => Item.Used));

    -- The machine's counters as they were handed over from C
    -- A NULL pointer is no reading at all, which is a sample of zeros: the two usage functions answer 0.0 for one of those
    function Machine_Of (Machine : access constant C_Sample) return Sample is
        (if Machine = null then (others => 0) else From_C (Machine.all));

    -- The name of the application as it was handed over from C
    -- A NULL pointer is no name at all, which is a sample of the machine alone
    function App_Of (App : in Interfaces.C.Strings.chars_ptr) return String is
        (if App = Interfaces.C.Strings.Null_Ptr
         then ""
         else Interfaces.C.Strings.Value (App, Max_App_Name));

    --------------------------------------------------

    procedure C_Take_System (Result : access C_Sample) is
    begin
        if Result = null then
            return;
        end if;

        -- Start from an empty sample, so the caller gets zeros if anything fails below
        Result.all := (others => 0);

        Result.all := To_C (Take);
    exception
        when others =>
            -- No Ada exception may cross into the C caller
            null;
    end C_Take_System;

    --------------------------------------------------

    procedure C_Take_PID (PID : in Interfaces.C.unsigned; Result : access C_Sample) is
    begin
        if Result = null then
            return;
        end if;

        Result.all := (others => 0);

        -- A C unsigned holds numbers an Ada Process_ID does not, and no such number is a process
        if PID > Interfaces.C.unsigned (Process_ID'Last) then
            Result.all := To_C (Take);
        else
            Result.all := To_C (Take (Process_ID (PID)));
        end if;
    exception
        when others =>
            null;
    end C_Take_PID;

    --------------------------------------------------

    procedure C_Take_App (App : in Interfaces.C.Strings.chars_ptr;
                          Result : access C_Sample) is
    begin
        if Result = null then
            return;
        end if;

        Result.all := (others => 0);

        Result.all := To_C (Take (App_Of (App)));
    exception
        when others =>
            null;
    end C_Take_App;

    --------------------------------------------------

    procedure C_Take_PID_With (PID : in Interfaces.C.unsigned;
                               Machine : access constant C_Sample;
                               Result : access C_Sample) is
    begin
        if Result = null then
            return;
        end if;

        Result.all := (others => 0);

        -- A C unsigned holds numbers an Ada Process_ID does not, and no such number is a process
        -- PID 0 is none either, so it gives back the machine's reading alone
        if PID > Interfaces.C.unsigned (Process_ID'Last) then
            Result.all := To_C (Take (PID => 0, Machine => Machine_Of (Machine)));
        else
            Result.all := To_C (Take (PID => Process_ID (PID),
                                      Machine => Machine_Of (Machine)));
        end if;
    exception
        when others =>
            null;
    end C_Take_PID_With;

    --------------------------------------------------

    procedure C_Take_App_With (App : in Interfaces.C.Strings.chars_ptr;
                               Machine : access constant C_Sample;
                               Result : access C_Sample) is
    begin
        if Result = null then
            return;
        end if;

        Result.all := (others => 0);

        Result.all := To_C (Take (App => App_Of (App),
                                  Machine => Machine_Of (Machine)));
    exception
        when others =>
            null;
    end C_Take_App_With;

    --------------------------------------------------

    function C_System_Usage (Before, After : access constant C_Sample)
        return Interfaces.C.double is
    begin
        if Before = null or else After = null then
            return 0.0;
        end if;

        return Interfaces.C.double
                   (System_Usage (From_C (Before.all), From_C (After.all)));
    exception
        when others =>
            return 0.0;
    end C_System_Usage;

    --------------------------------------------------

    function C_Process_Usage (Before, After : access constant C_Sample)
        return Interfaces.C.double is
    begin
        if Before = null or else After = null then
            return 0.0;
        end if;

        return Interfaces.C.double
                   (Process_Usage (From_C (Before.all), From_C (After.all)));
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
