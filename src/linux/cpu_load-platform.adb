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
with Ada.Characters.Handling;
with Interfaces.C;
with System;
with GNAT.Directory_Operations;
with GNAT.OS_Lib;

package body CPU_Load.Platform is

    -- Path to /proc folder
    Proc_Path : constant String := "/proc";

    -- Linux writes a program's path into a buffer of this size at most
    Path_Max : constant := 4_096;

    -- The most counters read out of any one line of /proc
    Max_Counters : constant := 8;

    type Counter_Fields is array (Positive range <>) of Integer_64;

    -- Path to a process's files in /proc
    -- i.e., for a PID = 33 and name = stat, this gives: /proc/33/stat
    function Proc_File (PID : in Process_ID; Name : in String) return String is
        (Proc_Path & "/" & Trim (Process_ID'Image (PID), Left) & "/" & Name);

    --------------------------------------------------

    -- Where a symbolic link points, ex. /proc/33/exe pointing at the program process 33 runs
    -- It writes no NUL of its own, and answers with how many characters it wrote
    function Read_Link (Path : in System.Address;
                        Buffer : in System.Address;
                        Size : in Interfaces.C.size_t)
        return Interfaces.C.ptrdiff_t
        with Import, Convention => C, External_Name => "readlink";

    -- Get how many of Linux own ticks make a second
    function Sysconf (Name : in Interfaces.C.int) return Interfaces.C.long
        with Import, Convention => C, External_Name => "sysconf";

    --------------------------------------------------

    -- The name sysconf answers about its own tick with
    Clk_Tck : constant Interfaces.C.int := 2;

    -- How many nanoseconds one of Linux's ticks is
    -- /proc counts the times it writes in those ticks, and they have to be turned into nanoseconds so that a process and the machine's clock can be compared
    function Read_Nanoseconds_Per_Jiffy return Integer_64 is
        use type Interfaces.C.long;

        Per_Second : constant Interfaces.C.long := Sysconf (Clk_Tck);
    begin
        if Per_Second <= 0 then
            -- A hundred a second, which is what every machine this is built for answers
            return 10_000_000;
        end if;

        return 1_000_000_000 / Integer_64 (Per_Second);
    end Read_Nanoseconds_Per_Jiffy;

    -- Asked once, as it does not change while the machine is running
    Nanoseconds_Per_Jiffy : constant Integer_64 := Read_Nanoseconds_Per_Jiffy;

    --------------------------------------------------

    -- Get first line of a file
    -- Used for /proc/stat, /proc/pid/stat or /proc/pid/comm
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

        begin
            Read_Status := Read (File, Buffer'Address, Buffer'Length);
        exception
            when others =>
                Read_Status := 0;
        end;

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

    -- Read the space separated numbers of one line of /proc, from field First_Field on
    -- A run of spaces counts as one separator, as /proc lines its columns up with them
    -- Count says how many were read, which is fewer than asked for on a line cut short
    -- Every counter /proc writes is a plain decimal number, and reading the digits here rather than with 'Value keeps this off the heap: this runs on every single sample
    procedure Scan_Counters (Line : in String;
                             First_Field : in Positive;
                             Values : out Counter_Fields;
                             Count : out Natural) is
        Index : Natural := Line'First;
        Field : Positive := 1;
        Value : Integer_64;
    begin
        Values := (others => 0);
        Count := 0;

        while Index <= Line'Last loop
            -- Step over the spaces before the field
            while Index <= Line'Last and then Line (Index) = ' ' loop
                Index := Index + 1;
            end loop;

            exit when Index > Line'Last;

            -- Read the number, digit by digit
            Value := 0;
            while Index <= Line'Last and then Line (Index) in '0' .. '9' loop
                Value := Value * 10
                       + Integer_64 (Character'Pos (Line (Index))
                                     - Character'Pos ('0'));
                Index := Index + 1;
            end loop;

            -- Keep it, if it is one of the fields asked for
            if Field >= First_Field then
                Count := Count + 1;
                Values (Values'First + Count - 1) := Value;
                exit when Count = Values'Length;
            end if;

            Field := Field + 1;

            -- Step over whatever was not a digit, so a field that is not a number still counts as one field
            while Index <= Line'Last and then Line (Index) /= ' ' loop
                Index := Index + 1;
            end loop;
        end loop;
    end Scan_Counters;

    --------------------------------------------------

    -- Returns the name of the program a process runs, in lower case, without the folders leading to it
    -- Returns "" if it has no name at all, or on any other issue
    function Program_Of (PID : in Process_ID) return String is
        use GNAT.Directory_Operations;
        use Ada.Characters.Handling;
        use type Interfaces.C.ptrdiff_t;

        -- readlink wants its path as C keeps one, ending in a NUL
        Link : constant String := Proc_File (PID, "exe") & ASCII.NUL;

        -- The path of the program the process runs, ex. /usr/lib/firefox/firefox
        Buffer : String (1 .. Path_Max);
        Filled : Interfaces.C.ptrdiff_t;

        -- What the kernel puts after the path of a program whose own file is gone
        Deleted : constant String := " (deleted)";
    begin
        Filled := Read_Link (Path => Link'Address,
                             Buffer => Buffer'Address,
                             Size => Interfaces.C.size_t (Buffer'Length));

        -- A kernel thread runs no program of its own, and another user's process is not ours to look at
        -- Its name is in comm, which anyone may read, so fall back on that one: fifteen characters at most, and the name the process gave itself rather than the name of its program, but better than passing the process over altogether
        if Filled <= 0
           or else Filled > Interfaces.C.ptrdiff_t (Buffer'Length)
        then
            return To_Lower (Get_First_Line (Proc_File (PID, "comm")));
        end if;

        declare
            -- readlink wrote no NUL, so what it wrote is exactly this much
            Path : constant String := Buffer (1 .. Natural (Filled));
        begin
            -- Drop the mark the kernel adds when the program's own file has been replaced or removed while it runs
            if Path'Length > Deleted'Length
               and then Path (Path'Last - Deleted'Length + 1 .. Path'Last) = Deleted
            then
                return To_Lower
                    (Base_Name (Path (Path'First .. Path'Last - Deleted'Length)));
            end if;

            return To_Lower (Base_Name (Path));
        end;
    exception
        when others =>
            return "";
    end Program_Of;

    --------------------------------------------------

    -- Measure a specific PID CPU time, in nanoseconds
    -- Returns Not_Read if the process does not exist, has stopped, or its line cannot be read
    function Ticks_Of_PID (PID : in Process_ID) return Integer_64 is
        -- /proc/pid/stat is one line, ex.:
        -- 4242 (bash) S 1 4242 4242 0 -1 4194304 512 0 0 0 37 5 0 0 ...
        Line : constant String := Get_First_Line (Proc_File (PID, "stat"));

        -- Index of where the name of the process ends
        -- In the example above: "(bash)" is the name so index of the last ")"
        -- Important because some names have spaces in them, ex. "(Web Content)"
        Closing_Index : constant Natural := Index (Line, ")", Going => Backward);

        Values : Counter_Fields (1 .. 2);
        Count : Natural;
    begin
        -- Unexpected file content or no process name
        if Closing_Index = 0 or else Closing_Index + 2 > Line'Last then
            return Not_Read;
        end if;

        -- After the process' name ")", the field is index 3, the state, so utime (field 14) is the 12th from there and stime (field 15) the 13th
        Scan_Counters (Line (Closing_Index + 2 .. Line'Last),
                       First_Field => 12,
                       Values => Values,
                       Count => Count);

        -- A line cut short before both of them is a line to make nothing of
        if Count < Values'Length then
            return Not_Read;
        end if;

        -- Return CPU time for process (utime + stime), turned from Linux's ticks into nanoseconds
        return (Values (1) + Values (2)) * Nanoseconds_Per_Jiffy;
    exception
        when others =>
            return Not_Read;
    end Ticks_Of_PID;

    --------------------------------------------------

    -- Measure CPU time of the entire system
    function Measure_System return Sample is
        -- The first line of /proc/stat is the CPU time of all CPU cores, ex.:
        -- cpu  83141 56 28074 2909632 3452 10196 3416 0 0 0
        -- user nice system idle   iowait irq softirq steal ...
        -- Field 1 is the word "cpu", so user time is field 2, and the eight read here run from there to steal
        -- Fields after 'steal' are already counted inside user and nice, so we can ignore them instead of counting them twice
        Line : constant String := Get_First_Line (Proc_Path & "/stat");

        Result : Sample;
        Values : Counter_Fields (1 .. Max_Counters);
        Count : Natural;
    begin
        -- If file content are not good, or no "cpu" at the beginning, then return empty Sample
        if Line'Length < 4
           or else Line (Line'First .. Line'First + 3) /= "cpu "
        then
            return Result;
        end if;

        -- "cpu" is followed by two spaces, and a run of them counts as one separator, so user time is the first counter that comes back
        Scan_Counters (Line,
                       First_Field => 2,
                       Values => Values,
                       Count => Count);

        -- A line cut short before steal is a line to make nothing of
        if Count < Max_Counters then
            return Result;
        end if;

        -- Everything the machine did other than idle, turned from Linux's ticks into nanoseconds
        Result.Busy := (Values (1)     -- user
                        + Values (2)   -- nice
                        + Values (3)   -- system
                        + Values (6)   -- irq
                        + Values (7)   -- softirq
                        + Values (8))  -- steal
                       * Nanoseconds_Per_Jiffy;

        -- Add the idle time to get total time
        Result.Total := Result.Busy
                      + (Values (4)     -- idle
                         + Values (5))  -- iowait
                        * Nanoseconds_Per_Jiffy;

        return Result;
    exception
        when others =>
            return (others => 0);
    end Measure_System;

    --------------------------------------------------

    function Used_By_App (App : in String) return Integer_64 is
        use GNAT.Directory_Operations;
        use Ada.Characters.Handling;

        Result : Integer_64 := 0;
        Unread : Natural := 0;
        Folder : Dir_Type;

        -- Read function fills a buffer with the number of actual content it read
        -- The remaining of the buffer is filled with random content we don't need
        Name : String (1 .. 64);
        Last : Natural; -- How much the Read function filled the buffer with data
        PID : Process_ID;

        -- App name in lower case, so we can be case insensitive
        App_Name : constant String := To_Lower (App);
    begin
        -- Open /proc folder, then we'll search for all processes of the app
        -- No /proc to read is no reading to give, rather than a reading of nothing
        begin
            Open (Folder, Proc_Path);
        exception
            when others =>
                return Not_Read;
        end;

        loop
            -- Read every process folder and check if it is one belonging to the app
            Read (Folder, Name, Last);
            exit when Last = 0; -- Exit when we finish reading the directory

            -- Check if we are reading a process folder (containing only digits, and no more than 9 characters)
            if Last <= 9 and then
                (for all Digit of Name (1 .. Last) => Digit in '0' .. '9') then
                -- Name (1 .. Last) gives the content of the buffer with actual data written by Read, which is the PID number we're looking for
                PID := Process_ID'Value (Name (1 .. Last));

                -- Asking the name first is what keeps this cheap: a process that is not the one wanted is never asked for its times
                if Program_Of (PID) = App_Name then
                    declare
                        Used : constant Integer_64 := Ticks_Of_PID (PID);
                    begin
                        -- A process of the application whose line could not be read is left out, and the sum is then short by however much it used
                        if Used = Not_Read then
                            Unread := Unread + 1;
                        else
                            Result := Result + Used;
                        end if;
                    end;
                end if;
            end if;
        end loop;

        Close (Folder);

        -- Processes of the application are running and their lines could not be read
        -- A sum of zero would read as an application sitting idle, which is not what was found out here
        if Unread > 0 and then Result = 0 then
            return Not_Read;
        end if;

        return Result;
    exception
        when others =>
            if Is_Open (Folder) then
                Close (Folder);
            end if;

            if Unread > 0 and then Result = 0 then
                return Not_Read;
            end if;

            return Result;
    end Used_By_App;

end CPU_Load.Platform;
