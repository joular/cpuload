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
with Ada.Characters.Handling;
with GNAT.Directory_Operations;

package body CPU_Load is

    -- Variables for macOS types
    subtype Mach_Port is Interfaces.C.unsigned; -- The port
    subtype Kern_Return is Interfaces.C.int; -- What a machine call answers, zero when it worked
    subtype Counter is Interfaces.C.unsigned; -- The 32 bits numbers the machine counts its time in

    Kern_Success : constant Kern_Return := 0;

    use type Interfaces.C.int;
    use type Interfaces.C.unsigned;

    -- What each call is asked for
    CPU_Load_Info : constant Interfaces.C.int := 3; -- The machine's CPU counters
    Task_Times_Wanted : constant Interfaces.C.int := 4; -- One process's CPU counters
    All_Processes : constant Interfaces.C.unsigned := 1; -- Every process running

    Room_For : constant := 4096;
    Bytes_Per_Number : constant := Interfaces.C.int'Size / 8;

    -- The machine refuses to write a program's path into any smaller buffer
    Path_Max : constant := 1_024;

    type Number_Array is array (Positive range <>) of aliased Interfaces.C.int;

    -- The machine's four counters, in the order it fills them
    -- Each is counted once per CPU core, so a machine of twelve cores counts twelve seconds of time per second
    type CPU_State is (User_Time, System_Time, Idle_Time, Nice_Time);
    type CPU_Ticks is array (CPU_State) of Counter with Convention => C;

    -- macOS needs this as 16 bytes (four numbers of 32 bits)
    pragma Compile_Time_Error
        (CPU_Ticks'Size /= 128, "host_cpu_load_info must be exactly 16 bytes");

    -- A tick is a hundredth of a second (the hz of kern.clockrate, which is 100 on macOS)
    -- A process is counted in another unit altogether, so both are turned into nanoseconds here and the two can then be compared
    Nanoseconds_Per_Tick : constant := 10_000_000;

    -- The counters of one process, as the machine writes them
    -- It writes the whole record or nothing at all, so all of it has to be here, though only the two times are read
    type Unread_Numbers is array (1 .. 64) of Interfaces.C.unsigned_char;

    type Task_Times is
        record
            Virtual_Size : Unsigned_64 := 0;
            Resident_Size : Unsigned_64 := 0;
            Total_User : Unsigned_64 := 0;
            Total_System : Unsigned_64 := 0;
            Rest : Unread_Numbers := (others => 0); -- Page faults, context switches, thread counts: none of it is read here
        end record
        with Convention => C;

    -- macOS needs this as 96 bytes
    pragma Compile_Time_Error
        (Task_Times'Size /= 96 * 8, "proc_taskinfo must be exactly 96 bytes");

    Task_Times_Bytes : constant Interfaces.C.int := Task_Times'Size / 8;

    -- How the machine's own time units turn into nanoseconds: multiply by the first, divide by the second
    type Timebase is
        record
            Numerator : Interfaces.C.unsigned := 1;
            Denominator : Interfaces.C.unsigned := 1;
        end record
        with Convention => C;

    --------------------------------------------------

    -- macOS helper functions

    -- The port
    function Mach_Host_Self return Mach_Port
        with Import, Convention => C, External_Name => "mach_host_self";

    -- Write what was asked about the machine into Info, here its CPU counters
    function Host_Statistics (Host : in Mach_Port;
                              Wanted : in Interfaces.C.int;
                              Info : in System.Address;
                              Room : access Counter) return Kern_Return
        with Import, Convention => C, External_Name => "host_statistics";

    -- The two numbers turning the machine's time units into nanoseconds
    function Mach_Timebase (Info : access Timebase) return Kern_Return
        with Import, Convention => C, External_Name => "mach_timebase_info";

    -- Write the counters of one process into Info
    function Proc_Info (PID : in Interfaces.C.int;
                        Wanted : in Interfaces.C.int;
                        Unused : in Unsigned_64;
                        Info : in System.Address;
                        Room : in Interfaces.C.int) return Interfaces.C.int
        with Import, Convention => C, External_Name => "proc_pidinfo";

    -- The full path of a process's program
    function Proc_Path (PID : in Interfaces.C.int;
                        Buffer : in System.Address;
                        Room : in Interfaces.C.unsigned) return Interfaces.C.int
        with Import, Convention => C, External_Name => "proc_pidpath";

    -- Fill the array with process numbers
    function List_Processes (Kind : in Interfaces.C.unsigned;
                             Unused : in Interfaces.C.unsigned;
                             Buffer : in System.Address;
                             Room : in Interfaces.C.int) return Interfaces.C.int
        with Import, Convention => C, External_Name => "proc_listpids";

    --------------------------------------------------

    -- Read the two numbers turning the machine's time units into nanoseconds
    -- They are 125 and 3 on Apple Silicon, where a process is counted in 24 MHz units, but the machine is asked for them rather than told
    function Read_Timebase return Timebase is
        Answer : aliased Timebase;
    begin
        if Mach_Timebase (Answer'Access) /= Kern_Success
           or else Answer.Denominator = 0
        then
            -- Leave the times as they are, rather than divide by zero
            return (Numerator => 1, Denominator => 1);
        end if;

        return Answer;
    end Read_Timebase;

    -- Asked once: the machine hands out a new right to its port on every call, and every one of them would have to be given back
    Host : constant Mach_Port := Mach_Host_Self;

    -- Asked once as well, as it does not change while the machine is running
    Time_Unit : constant Timebase := Read_Timebase;

    --------------------------------------------------

    -- Returns the name of a program by its PID, in lower case
    -- Returns "" if it doesn't have a name or any other issue
    function Program_Of (PID : in Process_ID) return String is
        use GNAT.Directory_Operations;
        use Ada.Characters.Handling;

        -- The path of the program, ex. /Applications/Firefox.app/Contents/MacOS/firefox
        Buffer : String (1 .. Path_Max) := (others => ' ');
        Filled : Interfaces.C.int;
    begin
        Filled := Proc_Path (PID => Interfaces.C.int (PID),
                             Buffer => Buffer'Address,
                             Room => Buffer'Length);

        if Filled <= 0 or else Natural (Filled) > Buffer'Length then
            return "";
        end if;

        -- Keep the name of the program alone, without the folders leading to it
        return To_Lower (Base_Name (Buffer (1 .. Natural (Filled))));
    exception
        when others =>
            return "";
    end Program_Of;

    --------------------------------------------------

    -- Measure a specific PID CPU time, in nanoseconds
    -- Returns 0 if process does not exist, stopped, or belongs to another user (the machine only tells root about those)
    function Ticks_Of_PID (PID : in Process_ID) return Integer_64 is
        Times : Task_Times;
    begin
        -- The machine writes the whole record or nothing at all
        if Proc_Info (PID => Interfaces.C.int (PID),
                      Wanted => Task_Times_Wanted,
                      Unused => 0,
                      Info => Times'Address,
                      Room => Task_Times_Bytes) /= Task_Times_Bytes
        then
            return 0;
        end if;

        -- A process is counted in the machine's own time units, so they are turned into nanoseconds
        -- Multiplied before divided, so the fraction is not lost on the way
        return (Integer_64 (Times.Total_User) + Integer_64 (Times.Total_System))
               * Integer_64 (Time_Unit.Numerator)
               / Integer_64 (Time_Unit.Denominator);
    exception
        when others =>
            return 0;
    end Ticks_Of_PID;

    --------------------------------------------------

    -- Measure CPU time of the entire system
    function Measure_System return Sample is
        -- The machine's counters, ex. 561652 323108 6266574 0
        -- user system idle nice
        Ticks : CPU_Ticks := (others => 0);
        Room : aliased Counter := Ticks'Length;

        Result : Sample;
    begin
        if Host_Statistics (Host => Host,
                            Wanted => CPU_Load_Info,
                            Info => Ticks'Address,
                            Room => Room'Access) /= Kern_Success
        then
            return Result;
        end if;

        -- Everything the machine did other than idle
        Result.Busy := (Integer_64 (Ticks (User_Time))
                        + Integer_64 (Ticks (System_Time))
                        + Integer_64 (Ticks (Nice_Time))) * Nanoseconds_Per_Tick;

        -- And the idle time to get total time
        Result.Total := Result.Busy
                      + Integer_64 (Ticks (Idle_Time)) * Nanoseconds_Per_Tick;

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
        use Ada.Characters.Handling;

        Result : Sample := Measure_System;

        -- App name in lower case, so we can be case insensitive
        App_Name : constant String := To_Lower (App);

        Numbers : Number_Array (1 .. Room_For) := (others => 0);
        Filled : Interfaces.C.int;
        Counted : Natural;
    begin
        -- No app name, so return system CPU load
        if App = "" then
            return Result;
        end if;

        Filled := List_Processes (Kind => All_Processes,
                                  Unused => 0,
                                  Buffer => Numbers'Address,
                                  Room => Room_For * Bytes_Per_Number);

        if Filled <= 0 then
            return Result;
        end if;

        Counted := Natural'Min (Natural (Filled) / Bytes_Per_Number, Room_For);

        for Walked in 1 .. Counted loop
            -- Number 0 is the machine's own kernel, and a negative one is no process at all
            -- Nothing is checked above: macOS counts its processes in the very numbers a Process_ID holds
            if Numbers (Walked) > 0 then
                -- Asking the name first is what keeps this cheap: a process that is not the one wanted is never asked for its times
                if Program_Of (Process_ID (Numbers (Walked))) = App_Name then
                    Result.Used := Result.Used + Ticks_Of_PID (Process_ID (Numbers (Walked)));
                end if;
            end if;
        end loop;

        return Result;
    exception
        when others =>
            return Result;
    end Take;

end CPU_Load;
