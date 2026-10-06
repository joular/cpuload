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

with Ada.Characters.Handling;
with Ada.Unchecked_Deallocation;
with Interfaces.C;
with System;
with GNAT.Directory_Operations;

-- FreeBSD, 64-bit: every counter is read through sysctl
package body CPU_Load.Platform is

    use type Interfaces.C.int;
    use type Interfaces.C.size_t;
    use type Interfaces.C.char;

    subtype Int is Interfaces.C.int;
    subtype Size is Interfaces.C.size_t;

    -- A sysctl name: a few numbers saying what is asked for, from sys/sysctl.h
    type Name is array (Positive range <>) of Int;

    KERN_CLOCKRATE : constant Name := (1, 12);
    KERN_PROC_PID : constant Name := (1, 14, 1);
    KERN_PROC_PROC : constant Name := (1, 14, 8);       -- Every process once, where KERN_PROC_ALL lists every thread
    KERN_PROC_PATHNAME : constant Name := (1, 14, 12);

    SZOMB : constant := 5;

    -- A struct kinfo_proc, from sys/user.h, with the fields read here named
    Entry_Size : constant := 1_088;

    type Process is
        record
            PID : Int;                                      -- ki_pid
            Run_Time : Unsigned_64;                         -- ki_runtime, in microseconds
            State : Unsigned_8;                             -- ki_stat
            Command : Interfaces.C.char_array (0 .. 19);    -- ki_comm, cut short by the kernel
            Rest : Interfaces.C.char_array (0 .. 620);      -- The fields after it, to the end of the struct
        end record;

    for Process use
        record
            PID at 72 range 0 .. 31;
            Run_Time at 328 range 0 .. 63;
            State at 388 range 0 .. 7;
            Command at 447 range 0 .. 159;
            Rest at 467 range 0 .. 4_967;
        end record;

    for Process'Size use Entry_Size * 8;

    type Process_List is array (Positive range <>) of Process;

    type Process_List_Access is access Process_List;

    procedure Free is new Ada.Unchecked_Deallocation (Process_List, Process_List_Access);

    --------------------------------------------------

    -- Length is the room at Value, then how much was written
    function Sysctl (MIB : in System.Address;
                     Count : in Interfaces.C.unsigned;
                     Value : in System.Address;
                     Length : access Size;
                     New_Value : in System.Address;
                     New_Length : in Size) return Int
        with Import, Convention => C, External_Name => "sysctl";

    function Sysctl_By_Name (Wanted : in Interfaces.C.char_array;
                             Value : in System.Address;
                             Length : access Size;
                             New_Value : in System.Address;
                             New_Length : in Size) return Int
        with Import, Convention => C, External_Name => "sysctlbyname";

    -- Ask the kernel for MIB into Value; False if it will not answer, or Value is too small
    function Ask (MIB : in Name; Value : in System.Address; Length : in out Size) return Boolean is
        Room : aliased Size := Length;
    begin
        if Sysctl (MIB (MIB'First)'Address, MIB'Length, Value, Room'Access, System.Null_Address, 0) /= 0 then
            return False;
        end if;

        Length := Room;
        return True;
    end Ask;

    --------------------------------------------------

    -- kern.cp_time counts ticks of the statistics clock, stathz of them per second
    function Read_Stat_Hz return Integer_64 is
        -- struct clockinfo: hz, tick, spare, stathz, profhz
        Clock : array (1 .. 5) of Int := (others => 0);
        Length : Size := Clock'Size / 8;
    begin
        if not Ask (KERN_CLOCKRATE, Clock'Address, Length) then
            return 0;
        end if;

        return Integer_64 (Clock (4));
    end Read_Stat_Hz;

    Stat_Hz : constant Integer_64 := Read_Stat_Hz;

    -- Divided before multiplied, so the sum over every core of a long uptime can't overflow
    function To_Microseconds (Ticks : in Integer_64) return Integer_64 is
        (if Stat_Hz > 0 then (Ticks / Stat_Hz) * 1_000_000 + (Ticks mod Stat_Hz) * 1_000_000 / Stat_Hz else 0);

    --------------------------------------------------

    -- The kinfo_proc of PID; False if there is no such process
    -- The answer must be about PID: above the last process number, FreeBSD takes the number for a thread, and answers with its process
    function Read_Process (PID : in Process_ID; Data : out Process) return Boolean is
        Length : Size := Entry_Size;
    begin
        return Ask (KERN_PROC_PID & Int (PID), Data'Address, Length)
               and then Length = Entry_Size
               and then Data.PID = Int (PID);
    end Read_Process;

    -- Base name of the program PID runs, or its command name where that is not known (a kernel process runs none, a replaced program has no path)
    function Program_Of (PID : in Process_ID; Data : in Process) return String is
        -- PATH_MAX
        Path : Interfaces.C.char_array (0 .. 1_023) := (others => Interfaces.C.nul);
        Length : Size := Path'Length;
    begin
        if Ask (KERN_PROC_PATHNAME & Int (PID), Path'Address, Length) and then Path (0) /= Interfaces.C.nul then
            return GNAT.Directory_Operations.Base_Name (Interfaces.C.To_Ada (Path));
        end if;

        return Interfaces.C.To_Ada (Data.Command);
    end Program_Of;

    --------------------------------------------------

    function Measure_System return Sample is
        -- kern.cp_time: user, nice, system, interrupt and idle ticks, summed over every core
        Times : array (1 .. 5) of Interfaces.C.long := (others => 0);
        Length : aliased Size := Times'Size / 8;
        Busy : Integer_64 := 0;
    begin
        if Sysctl_By_Name (Interfaces.C.To_C ("kern.cp_time"), Times'Address, Length'Access, System.Null_Address, 0) /= 0
           or else Length /= Times'Size / 8
        then
            return (others => 0);
        end if;

        for I in 1 .. 4 loop
            Busy := Busy + Integer_64 (Times (I));
        end loop;

        return (Busy => To_Microseconds (Busy),
                Total => To_Microseconds (Busy + Integer_64 (Times (5))),
                Used => 0);
    exception
        when others =>
            return (others => 0);
    end Measure_System;

    --------------------------------------------------

    function Used_By_PID (PID : in Process_ID) return Integer_64 is
        Data : Process;
    begin
        if not Read_Process (PID, Data) or else Data.State = SZOMB then
            return Not_Read;
        end if;

        return Integer_64 (Data.Run_Time);
    exception
        when others =>
            return Not_Read;
    end Used_By_PID;

    --------------------------------------------------

    function Runs (PID : in Process_ID; App : in String) return Boolean is
        use Ada.Characters.Handling;

        Data : Process;
    begin
        -- A process that has ended keeps its name, so the state settles it
        return Read_Process (PID, Data) and then Data.State /= SZOMB
               and then To_Lower (Program_Of (PID, Data)) = To_Lower (App);
    exception
        when others =>
            return False;
    end Runs;

    --------------------------------------------------

    function For_Each_Process (Action : not null access procedure (PID : in Process_ID))
        return Boolean is
        Length : Size := 0;
        List : Process_List_Access;
    begin
        -- With no buffer, sysctl answers the room needed; processes may start meanwhile, so take twice that
        if not Ask (KERN_PROC_PROC, System.Null_Address, Length) then
            return False;
        end if;

        List := new Process_List (1 .. 2 * Natural (Length) / Entry_Size);
        Length := List'Length * Entry_Size;

        if not Ask (KERN_PROC_PROC, List.all'Address, Length) then
            Free (List);
            return False;
        end if;

        -- One entry per process; PID 0 is the kernel
        for Item of List (1 .. Natural (Length) / Entry_Size) loop
            if Item.PID > 0 then
                Action (Process_ID (Item.PID));
            end if;
        end loop;

        Free (List);
        return True;
    exception
        when others =>
            Free (List);
            return False;
    end For_Each_Process;

end CPU_Load.Platform;
