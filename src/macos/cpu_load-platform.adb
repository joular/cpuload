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
with Ada.Unchecked_Deallocation;
with GNAT.Directory_Operations;

package body CPU_Load.Platform is

    -- Variables for macOS types
    subtype Mach_Port is Interfaces.C.unsigned; -- The port
    subtype Kern_Return is Interfaces.C.int; -- What a machine call answers, zero when it worked

    -- The 32 bits numbers the machine counts its time in
    -- Being only 32 bits, they come back round to zero after some weeks of the machine running: a hundred of them a second for every core, so about fifty days on ten cores and twenty on twenty-four
    -- Only Busy is built out of them, the total time coming from a clock that does not come round, so one reading of the machine then comes out at 0%, the guard in System_Usage catching a busy time that went backwards, and the reading after it is right again
    subtype Counter is Interfaces.C.unsigned;

    Kern_Success : constant Kern_Return := 0;

    use type Interfaces.C.int;
    use type Interfaces.C.unsigned;

    -- What each call is asked for
    CPU_Load_Info : constant Interfaces.C.int := 3; -- The machine's CPU counters
    Task_Times_Wanted : constant Interfaces.C.int := 4; -- One process's CPU counters
    All_Processes : constant Interfaces.C.unsigned := 1; -- Every process running

    -- How many processes one list holds, and how many the largest one ever asked for holds
    -- The first is taken on the stack and is what every machine of a usual size takes; the second is only reached by a machine running more processes than that, and is taken off the heap
    Room_For : constant := 4096;
    Max_Processes : constant := 65_536;

    Bytes_Per_Number : constant := Interfaces.C.int'Size / 8;

    -- The machine refuses to write a program's path into any smaller buffer, and writes no longer one than this
    Path_Max : constant := 4_096;

    type Number_Array is array (Positive range <>) of aliased Interfaces.C.int;
    type Number_Array_Access is access Number_Array;

    procedure Free is
        new Ada.Unchecked_Deallocation (Number_Array, Number_Array_Access);

    -- The machine's four counters, in the order it fills them
    -- Each is counted once per CPU core, so a machine of twelve cores counts twelve seconds of time per second
    type CPU_State is (User_Time, System_Time, Idle_Time, Nice_Time);
    type CPU_Ticks is array (CPU_State) of Counter with Convention => C;

    -- The idle time is no longer read, the total coming from a clock instead, but the machine still writes all four counters and the array has to hold room for every one of them
    pragma Unreferenced (Idle_Time);

    -- macOS needs this as 16 bytes (four numbers of 32 bits), laid out here rather than left to the compiler and checked afterwards, so it cannot come out any other way
    for CPU_Ticks'Component_Size use 32;
    for CPU_Ticks'Size use 128;

    -- A tick is a hundredth of a second (the hz of kern.clockrate, which is 100 on macOS)
    -- A process is counted in another unit altogether, and the machine's clock in a third, so all of them are turned into nanoseconds here and can then be compared
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

    -- macOS needs this as 96 bytes: the layout below is pinned to that number rather than left to the compiler and checked afterwards, and it is also the room the machine is told it has
    Task_Times_Bytes : constant Interfaces.C.int := 96;

    for Task_Times use
        record
            Virtual_Size at 0 range 0 .. 63;
            Resident_Size at 8 range 0 .. 63;
            Total_User at 16 range 0 .. 63;
            Total_System at 24 range 0 .. 63;
            Rest at 32 range 0 .. 511;
        end record;

    for Task_Times'Size use Task_Times_Bytes * 8;

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

    -- A clock that only ever moves forward, in the machine's own time units
    -- The very units a process's time comes in, so the timebase below turns both into nanoseconds
    function Mach_Now return Unsigned_64
        with Import, Convention => C, External_Name => "mach_absolute_time";

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

    -- How many CPUs the machine counts, asked once as it does not change while the machine is running
    -- macOS alone needs it, the total here coming from a clock rather than from a counter of the machine's own
    Cores : constant Integer_64 :=
        Integer_64 (System.Multiprocessors.Number_Of_CPUs);

    -- The machine's own time units turned into nanoseconds, the one place that conversion is done
    -- Multiplied before divided, so the fraction is not lost on the way
    function In_Nanoseconds (Units : in Integer_64) return Integer_64 is
        (Units
         * Integer_64 (Time_Unit.Numerator)
         / Integer_64 (Time_Unit.Denominator));

    --------------------------------------------------

    -- Returns the name of a program by its PID, in lower case
    -- Returns "" if it doesn't have a name or any other issue
    function Program_Of (PID : in Process_ID) return String is
        use GNAT.Directory_Operations;
        use Ada.Characters.Handling;

        -- The path of the program, ex. /Applications/Firefox.app/Contents/MacOS/firefox
        -- Left as it comes: the machine fills it, and only as much of it as the machine says it filled is ever read
        Buffer : String (1 .. Path_Max);
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
    -- Returns Not_Read if the process does not exist, has stopped, or belongs to another user: the machine only tells root about those, and it refuses about a third of what is running on a Mac of a usual size
    function Used_By_PID (PID : in Process_ID) return Integer_64 is
        Times : Task_Times;
    begin
        -- The machine writes the whole record or nothing at all
        if Proc_Info (PID => Interfaces.C.int (PID),
                      Wanted => Task_Times_Wanted,
                      Unused => 0,
                      Info => Times'Address,
                      Room => Task_Times_Bytes) /= Task_Times_Bytes
        then
            return Not_Read;
        end if;

        -- A process is counted in the machine's own time units, so they are turned into nanoseconds
        return In_Nanoseconds (Integer_64 (Times.Total_User)
                               + Integer_64 (Times.Total_System));
    exception
        when others =>
            return Not_Read;
    end Used_By_PID;

    --------------------------------------------------

    -- Add up the CPU time of every process of the application, out of the Count process numbers the machine listed
    -- A process of the application whose time the machine will not give is left out, and the sum is then short by however much it used
    -- Returns Not_Read when some of them were left out that way and what remained added up to nothing at all
    function Sum_Named (Numbers : in Number_Array;
                        Count : in Natural;
                        App_Name : in String) return Integer_64 is
        Result : Integer_64 := 0;
        Unread : Boolean := False;
    begin
        for Walked in Numbers'First .. Numbers'First + Count - 1 loop
            -- Number 0 is the machine's own kernel, and a negative one is no process at all
            -- Nothing is checked above: macOS counts its processes in the very numbers a Process_ID holds
            -- Asking the name first is what keeps this cheap: a process that is not the one wanted is never asked for its times
            if Numbers (Walked) > 0
               and then Program_Of (Process_ID (Numbers (Walked))) = App_Name
            then
                declare
                    Used : constant Integer_64 :=
                        Used_By_PID (Process_ID (Numbers (Walked)));
                begin
                    if Used = Not_Read then
                        Unread := True;
                    else
                        Result := Result + Used;
                    end if;
                end;
            end if;
        end loop;

        return Sum_Or_Not_Read (Result, Unread);
    end Sum_Named;

    --------------------------------------------------

    -- The same, for a machine running more processes than a list on the stack holds
    -- Only reached when the list came back filled to the brim, which is the machine saying there may be more of them, and which no machine of a usual size ever does
    -- The list is taken twice as large until it comes back with room to spare, and off the heap, being too large for the stack by then
    function Used_By_Many (App_Name : in String) return Integer_64 is
        Capacity : Natural := Room_For * 2;
        Numbers : Number_Array_Access;
        Filled : Interfaces.C.int;
        Room : Interfaces.C.int;
        Result : Integer_64 := 0;
    begin
        loop
            Numbers := new Number_Array (1 .. Capacity);
            Room := Interfaces.C.int (Capacity * Bytes_Per_Number);

            Filled := List_Processes (Kind => All_Processes,
                                      Unused => 0,
                                      Buffer => Numbers.all (1)'Address,
                                      Room => Room);

            if Filled <= 0 then
                Free (Numbers);
                return Not_Read;
            end if;

            -- Room to spare, or as large a list as this will ever ask for: count what came back
            if Filled < Room or else Capacity >= Max_Processes then
                Result := Sum_Named (Numbers.all,
                                     Natural (Filled) / Bytes_Per_Number,
                                     App_Name);
                Free (Numbers);
                return Result;
            end if;

            -- Still full, so ask again with twice the room
            Free (Numbers);
            Capacity := Capacity * 2;
        end loop;
    exception
        when others =>
            -- Nothing is left behind, whatever went wrong above
            -- Free does nothing at all when there is nothing left to free
            Free (Numbers);
            return Not_Read;
    end Used_By_Many;

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

        -- The CPU time the machine had to give over the same stretch
        -- From the forward-only clock, not Idle_Time: macOS writes that about once every 90 ms, so two samples closer together than that would show no time passing at all
        -- Only the difference between two readings of the clock means anything, which is all System_Usage takes of it
        Result.Total := In_Nanoseconds (Integer_64 (Mach_Now)) * Cores;

        return Result;
    exception
        when others =>
            return (others => 0);
    end Measure_System;

    --------------------------------------------------

    function Used_By_App (App : in String) return Integer_64 is
        use Ada.Characters.Handling;

        -- App name in lower case, so we can be case insensitive
        App_Name : constant String := To_Lower (App);

        -- The list every machine of a usual size fits in, taken on the stack
        -- Left as it comes: the machine fills it, and only as much of it as the machine says it filled is ever read
        Numbers : Number_Array (1 .. Room_For);
        Filled : Interfaces.C.int;
        Room : constant Interfaces.C.int := Room_For * Bytes_Per_Number;
    begin
        Filled := List_Processes (Kind => All_Processes,
                                  Unused => 0,
                                  Buffer => Numbers'Address,
                                  Room => Room);

        if Filled <= 0 then
            return Not_Read;
        end if;

        -- A list filled to the brim is the machine saying there may be more processes than fit in it
        -- Anything short of that is all of them
        if Filled = Room then
            return Used_By_Many (App_Name);
        end if;

        return Sum_Named (Numbers, Natural (Filled) / Bytes_Per_Number, App_Name);
    exception
        when others =>
            return Not_Read;
    end Used_By_App;

end CPU_Load.Platform;
