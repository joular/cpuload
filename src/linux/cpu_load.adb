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
with GNAT.String_Split;
with GNAT.Directory_Operations;
with GNAT.OS_Lib;
with Ada.Characters.Handling;

package body CPU_Load is

    -- Path to /proc folder
    Proc_Path : constant String := "/proc";

    -- Path to a process's files in /proc
    -- i.e., for a PID = 33 and name = stat, this gives: /proc/33/stat
    function Proc_File (PID : in Process_ID; Name : in String) return String is
        (Proc_Path & "/" & Trim (Process_ID'Image (PID), Left) & "/" & Name);

    --------------------------------------------------

    -- Get first line of a file
    -- Used for /proc/stat or /proc/pid/stat
    function Get_First_Line (Path : in String) return String is
        use GNAT.OS_Lib;
        -- Open file in read mode
        File : constant File_Descriptor := Open_Read (Path, Binary);
        Buffer : String (1 .. 1_024);
        Read_Status : Integer;
        Ending : Natural; -- to store the index where the first line stops, or 0 if no end
    begin
        -- Invalid descriptor for file
        if File = Invalid_FD then
            return "";
        end if;

        Read_Status := Read (File, Buffer'Address, Buffer'Length);
        Close (File);

        -- Failed to read the file
        if Read_Status <= 0 then
            return "";
        end if;

        -- Get the index where the first line ends
        Ending := Index (Buffer (1 .. Read_Status), (1 => ASCII.LF));

        -- Return first line
        return Buffer (1 .. (if Ending = 0 then Read_Status else Ending - 1));
    end Get_First_Line;

    --------------------------------------------------

    -- Measure a specific PID CPU time, in the kernel's own ticks
    -- Returns 0 if process does not exist, stopped, or line cannot be read
    function Ticks_Of_PID (PID : in Process_ID) return Integer_64 is
        use Gnat.String_Split;
        
        -- /proc/pid/stat is one line, ex.:
        -- 4242 (bash) S 1 4242 4242 0 -1 4194304 512 0 0 0 37 5 0 0 ...
        Line : constant String := Get_First_Line (Proc_File (PID, "stat"));

        -- Index of where the name of the process ends
        -- In the example above: "(bash)" is the name so index of the last ")"
        -- Important because some names have spaces in them, ex. "(Web Content)"
        Closing_Index : constant Natural := Index (Line, ")", Going => Backward);

        Fields : Slice_Set;
    begin
        -- Unexpected file content or no process name
        if Closing_Index = 0 or else Closing_Index + 2 > Line'Last then
            return 0;
        end if;

        -- After the process' name ")", the field is index 3, the state, so utime (field 14) is the 12th from there and stime (field 15) the 13th
        -- Split the line with the spaces
        Create (Fields, Line (Closing_Index + 2 .. Line'Last), " ", Multiple);

        -- Return CPU time for process (utime + stime)
        return Integer_64'Value (Slice (Fields, 12))
             + Integer_64'Value (Slice (Fields, 13));
    exception
        when others =>
            return 0;
    end Ticks_Of_PID;

    --------------------------------------------------

    -- Measure CPU time of the entire system
    function Measure_System return Sample is
        use GNAT.String_Split;

        -- The first line of /proc/stat is the CPU time of all CPU cores, ex.:
        -- cpu  83141 56 28074 2909632 3452 10196 3416 0 0 0
        -- user nice system idle   iowait irq softirq steal ...
        -- Slice 1 is the word "cpu", so user time is slice 2, etc.
        -- Fields after 'steal' are already counted inside user and nice, so we can ignore them instead of counting them twice
        Line : constant String := Get_First_Line (Proc_Path & "/stat");

        Result : Sample;
        Fields : Slice_Set;
    begin
        -- If file content are not good, or no "cpu" at the beginning, then return empty Sample
        if Line'Length < 4
           or else Line (Line'First .. Line'First + 3) /= "cpu "
        then
            return Result;
        end if;

        -- Slice the line
        Create (Fields, Line, " ", Multiple);

        -- Calculate busy CPU time
        Result.Busy := Integer_64'Value (Slice (Fields, 2)) -- user
                     + Integer_64'Value (Slice (Fields, 3)) -- nice
                     + Integer_64'Value (Slice (Fields, 4)) -- system
                     + Integer_64'Value (Slice (Fields, 7)) -- irq
                     + Integer_64'Value (Slice (Fields, 8)) -- softirq
                     + Integer_64'Value (Slice (Fields, 9)); -- steal
        
        -- Calculate total CPU time by adding idle and iowait
        Result.Total := Result.Busy
                      + Integer_64'Value (Slice (Fields, 5)) -- idle
                      + Integer_64'Value (Slice (Fields, 6)); -- iowait
        
        return Result;
    exception
        when others =>
            return (others => 0);
    end Measure_System;

    --------------------------------------------------

    function Take return Sample is (Measure_System);
    
    --------------------------------------------------

    function Take (PID : in Process_ID) return Sample is
        Result : Sample := Measure_System;
    begin
        if PID = 0 then
            -- No PID, so return system CPU load
            return Result;
        else
            Result.Used := Ticks_Of_PID (PID);
            return Result;
        end if;
    end Take;

    --------------------------------------------------

    function Take (App : in String) return Sample is
        use GNAT.Directory_Operations;
        use Ada.Characters.Handling;

        Result : Sample := Measure_System;
        Folder : Dir_Type;

        -- Read function fills a buffer with the number of actual content it read
        -- The reamining of the buffer is filled with random content we don't need
        Name : String (1 .. 64);
        Last : Natural; -- How much the Read function filled the buffer with data
        PID : Process_ID;

        -- App name in lower case, so we can be case insensitive
        App_Name : constant String := To_Lower (App);
    begin
        if App = "" then
            -- No app name, so return system CPU load
            return Result;
        end if;

        -- Open /proc folder, then we'll search for all processes of the app
        Open (Folder, Proc_Path);

        loop
            -- Read every process folder and check if it is one belonging to the app
            Read (Folder, Name, Last);
            exit when Last = 0; -- Exit when we finish reading the directory

            -- Check if we are reading a process folder (containing only digits, and no more than 9 characters)
            if Last <= 9 and then 
                (for all Digit of Name (1 .. Last) => Digit in '0' .. '9') then
                -- Name (1 .. Last) gives the content of the buffer with actual data written by Read, which is the PID number we're looking for
                PID := Process_ID'Value (Name (1 .. Last));

                -- Check if process' name is the name of the app
                -- Process name is in /proc/pid/comm file
                if To_Lower (Get_First_Line (Proc_File (PID, "comm"))) = App_Name then
                    Result.Used := Result.Used + Ticks_Of_PID (PID);
                end if;
            end if;
        end loop;
        
        Close (Folder);
        return Result;
    exception
        when others =>
            if Is_Open (Folder) then
                Close (Folder);
            end if;

            return Result;
    end Take;

end CPU_Load;