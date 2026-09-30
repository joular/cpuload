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

with Interfaces.C;
with System;
with System.Multiprocessors;
with Ada.Characters.Handling;
with GNAT.Directory_Operations;

package body CPU_Load.Platform is

    use type Interfaces.C.int;
    use type Interfaces.C.unsigned;

    subtype Mach_Port is Interfaces.C.unsigned;
    subtype Kern_Return is Interfaces.C.int;

    -- 32-bit tick counters, 100 per second per core: they wrap after ~50 days on 10 cores
    -- Total does not use them, so only the one reading across the wrap shows 0% (Share rejects a negative Busy)
    subtype Counter is Interfaces.C.unsigned;

    KERN_SUCCESS : constant Kern_Return := 0;
    HOST_CPU_LOAD_INFO : constant Interfaces.C.int := 3;
    PROC_PIDTASKINFO : constant Interfaces.C.int := 4;
    PROC_ALL_PIDS : constant Interfaces.C.unsigned := 1;

    -- host_cpu_load_info, summed over all cores
    type CPU_Ticks is
        record
            User_Ticks : Counter := 0;
            System_Ticks : Counter := 0;
            Idle_Ticks : Counter := 0;
            Nice_Ticks : Counter := 0;
        end record
        with Convention => C;

    for CPU_Ticks'Size use 128;

    -- Ticks are 1/100 s (kern.clockrate hz)
    Microseconds_Per_Tick : constant := 10_000;

    -- struct proc_taskinfo (96 bytes); proc_pidinfo fails unless given all of it
    type Unread_Bytes is array (1 .. 64) of Interfaces.C.unsigned_char;

    type Task_Info is
        record
            Virtual_Size : Unsigned_64 := 0;
            Resident_Size : Unsigned_64 := 0;
            Total_User : Unsigned_64 := 0;
            Total_System : Unsigned_64 := 0;
            Rest : Unread_Bytes := (others => 0);
        end record
        with Convention => C;

    Task_Info_Size : constant Interfaces.C.int := 96;

    for Task_Info use
        record
            Virtual_Size at 0 range 0 .. 63;
            Resident_Size at 8 range 0 .. 63;
            Total_User at 16 range 0 .. 63;
            Total_System at 24 range 0 .. 63;
            Rest at 32 range 0 .. 511;
        end record;

    for Task_Info'Size use Task_Info_Size * 8;

    -- mach_timebase_info_data_t: ns = units * Numer / Denom
    type Timebase_Info is
        record
            Numer : Interfaces.C.unsigned := 1;
            Denom : Interfaces.C.unsigned := 1;
        end record
        with Convention => C;

    --------------------------------------------------

    function Mach_Host_Self return Mach_Port
        with Import, Convention => C, External_Name => "mach_host_self";

    function Host_Statistics (Host : in Mach_Port;
                              Flavor : in Interfaces.C.int;
                              Info : in System.Address;
                              Count : access Counter) return Kern_Return
        with Import, Convention => C, External_Name => "host_statistics";

    function Mach_Timebase_Info (Info : access Timebase_Info) return Kern_Return
        with Import, Convention => C, External_Name => "mach_timebase_info";

    -- Monotonic, in the same units as the proc_pidinfo task times
    -- Not under Rosetta: there a process is still counted in 24 MHz units
    function Mach_Absolute_Time return Unsigned_64
        with Import, Convention => C, External_Name => "mach_absolute_time";

    -- Returns the number of bytes written
    function Proc_PID_Info (PID : in Interfaces.C.int;
                            Flavor : in Interfaces.C.int;
                            Arg : in Unsigned_64;
                            Buffer : in System.Address;
                            Buffer_Size : in Interfaces.C.int) return Interfaces.C.int
        with Import, Convention => C, External_Name => "proc_pidinfo";

    function Proc_PID_Path (PID : in Interfaces.C.int;
                            Buffer : in System.Address;
                            Buffer_Size : in Interfaces.C.unsigned) return Interfaces.C.int
        with Import, Convention => C, External_Name => "proc_pidpath";

    -- Returns the number of bytes written, not the number of PIDs
    function Proc_List_PIDs (Kind : in Interfaces.C.unsigned;
                             Type_Info : in Interfaces.C.unsigned;
                             Buffer : in System.Address;
                             Buffer_Size : in Interfaces.C.int) return Interfaces.C.int
        with Import, Convention => C, External_Name => "proc_listpids";

    --------------------------------------------------

    -- 125/3 on Apple Silicon, 1/1 on Intel
    function Read_Timebase return Timebase_Info is
        Answer : aliased Timebase_Info;
    begin
        if Mach_Timebase_Info (Answer'Access) /= KERN_SUCCESS or else Answer.Denom = 0 then
            return (Numer => 1, Denom => 1);
        end if;

        return Answer;
    end Read_Timebase;

    -- Once: each mach_host_self call adds a port right we would have to deallocate
    Host : constant Mach_Port := Mach_Host_Self;

    Timebase : constant Timebase_Info := Read_Timebase;

    -- Only macOS needs this: Total comes from a clock, not from per-CPU ticks
    Cores : constant Integer_64 := Integer_64 (System.Multiprocessors.Number_Of_CPUs);

    -- Multiplied before divided, so the fraction is not lost
    function To_Microseconds (Units : in Integer_64) return Integer_64 is
        (Units * Integer_64 (Timebase.Numer) / (Integer_64 (Timebase.Denom) * 1_000));

    --------------------------------------------------

    -- Program name without its folders, or "" if unknown
    function Program_Of (PID : in Process_ID) return String is
        -- proc_pidpath refuses a smaller buffer
        Path : String (1 .. 4_096);
        Length : Interfaces.C.int;
    begin
        Length := Proc_PID_Path (Interfaces.C.int (PID), Path'Address, Path'Length);

        if Length <= 0 then
            return "";
        end if;

        return GNAT.Directory_Operations.Base_Name (Path (1 .. Natural (Length)));
    end Program_Of;

    --------------------------------------------------

    function Measure_System return Sample is
        Ticks : CPU_Ticks;
        Count : aliased Counter := CPU_Ticks'Size / Counter'Size;

        Result : Sample;
    begin
        if Host_Statistics (Host, HOST_CPU_LOAD_INFO, Ticks'Address, Count'Access) /= KERN_SUCCESS then
            return Result;
        end if;

        Result.Busy := (Integer_64 (Ticks.User_Ticks)
                        + Integer_64 (Ticks.System_Ticks)
                        + Integer_64 (Ticks.Nice_Ticks)) * Microseconds_Per_Tick;

        -- Monotonic clock rather than idle ticks: macOS updates those only every ~90 ms
        Result.Total := To_Microseconds (Integer_64 (Mach_Absolute_Time)) * Cores;

        return Result;
    exception
        when others =>
            return (others => 0);
    end Measure_System;

    --------------------------------------------------

    -- Fails for other users' processes unless root
    function Used_By_PID (PID : in Process_ID) return Integer_64 is
        Info : Task_Info;
    begin
        if Proc_PID_Info (Interfaces.C.int (PID), PROC_PIDTASKINFO, 0, Info'Address, Task_Info_Size)
           /= Task_Info_Size
        then
            return Not_Read;
        end if;

        return To_Microseconds (Integer_64 (Info.Total_User) + Integer_64 (Info.Total_System));
    exception
        when others =>
            return Not_Read;
    end Used_By_PID;

    --------------------------------------------------

    function Runs (PID : in Process_ID; App : in String) return Boolean is
        use Ada.Characters.Handling;
    begin
        return To_Lower (Program_Of (PID)) = To_Lower (App);
    exception
        when others =>
            return False;
    end Runs;

    --------------------------------------------------

    type PID_List is array (Positive range <>) of Interfaces.C.int;

    PID_Bytes : constant := Interfaces.C.int'Size / 8;

    function For_Each_Process (Action : not null access procedure (PID : in Process_ID))
        return Boolean is
        -- With no buffer, proc_listpids answers the room needed, with some spare
        Needed : constant Interfaces.C.int := Proc_List_PIDs (PROC_ALL_PIDS, 0, System.Null_Address, 0);
    begin
        if Needed <= 0 then
            return False;
        end if;

        declare
            PIDs : PID_List (1 .. Natural (Needed) / PID_Bytes);
            Filled : constant Interfaces.C.int :=
                Proc_List_PIDs (PROC_ALL_PIDS, 0, PIDs'Address, Interfaces.C.int (PIDs'Length * PID_Bytes));
        begin
            if Filled <= 0 then
                return False;
            end if;

            for PID of PIDs (1 .. Natural (Filled) / PID_Bytes) loop
                -- PID 0 is the kernel
                if PID > 0 then
                    Action (Process_ID (PID));
                end if;
            end loop;
        end;

        return True;
    exception
        when others =>
            return False;
    end For_Each_Process;

end CPU_Load.Platform;
