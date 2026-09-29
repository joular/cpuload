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

with Ada.Strings; use Ada.Strings;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with Ada.Strings.Maps;
with Ada.Characters.Handling;
with Interfaces.C;
with System;
with GNAT.Directory_Operations;
with GNAT.OS_Lib;

package body CPU_Load.Platform is

    -- e.g. Proc_File (33, "stat") is /proc/33/stat
    function Proc_File (PID : in Process_ID; Name : in String) return String is
        ("/proc/" & Trim (Process_ID'Image (PID), Left) & "/" & Name);

    --------------------------------------------------

    -- Writes no NUL; returns how many characters it wrote
    function Readlink (Path : in System.Address;
                       Buffer : in System.Address;
                       Size : in Interfaces.C.size_t) return Interfaces.C.ptrdiff_t
        with Import, Convention => C, External_Name => "readlink";

    function Sysconf (Name : in Interfaces.C.int) return Interfaces.C.long
        with Import, Convention => C, External_Name => "sysconf";

    -- sysconf name for clock ticks per second
    SC_CLK_TCK : constant Interfaces.C.int := 2;

    --------------------------------------------------

    -- /proc counts its times in clock ticks
    function Read_Microseconds_Per_Tick return Integer_64 is
        use type Interfaces.C.long;

        Per_Second : constant Interfaces.C.long := Sysconf (SC_CLK_TCK);
    begin
        -- Assume 100 ticks per second
        if Per_Second <= 0 then
            return 10_000;
        end if;

        return 1_000_000 / Integer_64 (Per_Second);
    end Read_Microseconds_Per_Tick;

    Microseconds_Per_Tick : constant Integer_64 := Read_Microseconds_Per_Tick;

    --------------------------------------------------

    -- The content of a small file in /proc, or "" if it cannot be read
    -- Read through a file descriptor rather than Ada.Text_IO, whose Open fails when several tasks call it at once
    function Read_File (Path : in String) return String is
        use GNAT.OS_Lib;

        File : constant File_Descriptor := Open_Read (Path, Binary);
        Buffer : String (1 .. 1_024);
        Last : Integer;
    begin
        if File = Invalid_FD then
            return "";
        end if;

        Last := Read (File, Buffer'Address, Buffer'Length);
        Close (File);

        return Buffer (1 .. Integer'Max (Last, 0));
    end Read_File;

    --------------------------------------------------

    -- For /proc/stat and /proc/PID/comm
    function First_Line (Path : in String) return String is
        Text : constant String := Read_File (Path);
        Line_End : constant Natural := Index (Text, (1 => ASCII.LF));
    begin
        return (if Line_End = 0 then Text else Text (Text'First .. Line_End - 1));
    end First_Line;

    --------------------------------------------------

    Spaces : constant Ada.Strings.Maps.Character_Set := Ada.Strings.Maps.To_Set (' ');

    -- Nth space-separated field of Line as a number; a run of spaces is one separator
    -- Raises Constraint_Error if there is no such field, or it is not a number
    function Field (Line : in String; N : in Positive) return Integer_64 is
        From : Positive := Line'First;
        First : Positive;
        Last : Natural;
    begin
        for Skipped in 1 .. N loop
            Find_Token (Line (From .. Line'Last), Spaces, Outside, First, Last);

            if Last = 0 then
                raise Constraint_Error;
            end if;

            From := Last + 1;
        end loop;

        return Integer_64'Value (Line (First .. Last));
    end Field;

    --------------------------------------------------

    -- Base name of the program a process runs, from /proc/PID/exe
    -- Falls back to comm (15 chars max, name chosen by the process) for kernel threads and other users' processes
    function Program_Of (PID : in Process_ID) return String is
        use type Interfaces.C.ptrdiff_t;

        -- NUL-terminated for C
        Link : constant String := Proc_File (PID, "exe") & ASCII.NUL;

        -- Appended by the kernel when the program's file was removed or replaced while it runs
        Deleted : constant String := " (deleted)";

        Path : String (1 .. 4_096);
        Length : Interfaces.C.ptrdiff_t;
        Last : Natural;
    begin
        Length := Readlink (Link'Address, Path'Address, Path'Length);

        if Length <= 0 then
            return First_Line (Proc_File (PID, "comm"));
        end if;

        Last := Natural (Length);

        if Last > Deleted'Length and then Path (Last - Deleted'Length + 1 .. Last) = Deleted then
            Last := Last - Deleted'Length;
        end if;

        return GNAT.Directory_Operations.Base_Name (Path (1 .. Last));
    end Program_Of;

    --------------------------------------------------

    function Measure_System return Sample is
        -- First line of /proc/stat, in ticks over all cores:
        -- cpu  user nice system idle iowait irq softirq steal guest guest_nice
        -- guest and guest_nice are already inside user and nice
        Line : constant String := First_Line ("/proc/stat");
        Busy : Integer_64;
        Idle : Integer_64;
    begin
        if Head (Line, 4) /= "cpu " then
            return (others => 0);
        end if;

        Busy := Field (Line, 2)     -- user
              + Field (Line, 3)     -- nice
              + Field (Line, 4)     -- system
              + Field (Line, 7)     -- irq
              + Field (Line, 8)     -- softirq
              + Field (Line, 9);    -- steal

        Idle := Field (Line, 5)     -- idle
              + Field (Line, 6);    -- iowait

        return (Busy => Busy * Microseconds_Per_Tick,
                Total => (Busy + Idle) * Microseconds_Per_Tick,
                Used => 0);
    exception
        when others =>
            return (others => 0);
    end Measure_System;

    --------------------------------------------------

    function Used_By_PID (PID : in Process_ID) return Integer_64 is
        -- /proc/PID/stat, e.g. 4242 (bash) S 1 4242 4242 0 -1 4194304 512 0 0 0 37 5 0 0 ...
        Line : constant String := Read_File (Proc_File (PID, "stat"));

        -- The name in brackets may hold spaces, ")" or a newline, e.g. "(Web Content)", so fields are counted from after the last ")"
        Name_End : constant Natural := Index (Line, ")", Going => Backward);
        After_Name : String renames Line (Name_End + 1 .. Line'Last);
    begin
        if Name_End = 0 then
            return Not_Read;
        end if;

        -- utime and stime are fields 14 and 15 of the line, 12 and 13 after the name
        return (Field (After_Name, 12) + Field (After_Name, 13)) * Microseconds_Per_Tick;
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

    function For_Each_Process (Action : not null access procedure (PID : in Process_ID))
        return Boolean is
        use GNAT.Directory_Operations;

        Folder : Dir_Type;
        Name : String (1 .. 64);
        Last : Natural;
    begin
        Open (Folder, "/proc");

        loop
            Read (Folder, Name, Last);
            exit when Last = 0;

            -- Process folders are named by PID: digits only, 9 at most
            if Last <= 9 and then (for all Digit of Name (1 .. Last) => Digit in '0' .. '9') then
                Action (Process_ID'Value (Name (1 .. Last)));
            end if;
        end loop;

        Close (Folder);
        return True;
    exception
        when others =>
            if Is_Open (Folder) then
                Close (Folder);
            end if;

            return False;
    end For_Each_Process;

end CPU_Load.Platform;
