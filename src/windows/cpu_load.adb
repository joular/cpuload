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
with Ada.Strings.UTF_Encoding.Wide_Strings;
with GNAT.Directory_Operations;

package body CPU_Load is

    -- Variables for Windows types
    subtype DWORD is Interfaces.C.unsigned;
    subtype BOOL is Interfaces.C.int;
    subtype Handle is System.Address;

    Invalid_Handle : constant Handle := System.Null_Address;

    use type BOOL;
    use type DWORD;
    use type Handle;

    -- A length of time in units of a hundred nanoseconds
    -- Windows handles it as two halves, which needs to be put back together
    type FILETIME is
        record
            Low : DWORD := 0;
            High : DWORD := 0;
        end record
        with Convention => C;
    
    -- Windows needs this as 8 bytes
    pragma Compile_Time_Error
        (FILETIME'Size /= 64, "FILETIME must be exactly 8 bytes");

    -- A wide character in Windows is sixteen bits
    pragma Compile_Time_Error
        (Wide_Character'Size /= 16,
         "Wide_Character must be 16 bits to pass a buffer to Windows");
    
    Query_Limited_Information : constant DWORD := 16#1000#;
    Room_For : constant := 4096;
    Bytes_Per_Number : constant := DWORD'Size / 8;
    Path_Max : constant := 512;

    type Number_Array is array (Positive range <>) of aliased DWORD;

    --------------------------------------------------

    -- Windows helper functions
    function Get_System_Times (Idle : access FILETIME;
                               Kernel : access FILETIME;
                               User : access FILETIME) return BOOL
        with Import, Convention => Stdcall, External_Name => "GetSystemTimes";

    function Open_Process (Access_Wanted : in DWORD;
                           Inherit : in BOOL;
                           PID : in DWORD) return Handle
        with Import, Convention => Stdcall, External_Name => "OpenProcess";

    function Get_Process_Times (Process : in Handle;
                                Created : access FILETIME;
                                Finished : access FILETIME;
                                Kernel : access FILETIME;
                                User : access FILETIME) return BOOL
        with Import, Convention => Stdcall, External_Name => "GetProcessTimes";

    function Close_Handle (Object : in Handle) return BOOL
        with Import, Convention => Stdcall, External_Name => "CloseHandle";

    -- Fill the array with process numbers
    function Enum_Processes (Into : in System.Address;
                             Room : in DWORD;
                             Filled : access DWORD) return BOOL
        with Import, Convention => Stdcall, External_Name => "EnumProcesses";
    
    -- The full path of a process's program, as wide characters
    function Query_Image_Name (Process : in Handle;
                               Flags : in DWORD;
                               Buffer : in System.Address;
                               Size : access DWORD) return BOOL
        with Import, Convention => Stdcall,
             External_Name => "QueryFullProcessImageNameW";

    -- Join the two halves of a FILETIME as one number
    -- 64 bits are needed: a Long_Integer is 32 bits on Windows, so 2 ** 32 does not even fit in one
    function Joined (Value : in FILETIME) return Integer_64 is
        (Integer_64 (Value.High) * 2 ** 32
         + Integer_64 (Value.Low));
    
    --------------------------------------------------

    -- Get the plain name of the application (lowercase, remove trailing ".exe")
    function Plain_Name (Name : in String) return String is
        use Ada.Characters.Handling;
    begin
        if Name'Length > 4 and then To_Lower (Name (Name'Last - 3 .. Name'Last)) = ".exe" then
            return To_Lower (Name (Name'First .. Name'Last - 4));
        else
            return To_Lower (Name);
        end if;
    end Plain_Name;

    --------------------------------------------------

    -- Returns the plain name of a program by its PID
    -- Returns "" if it doesn't have a name or any other issue
    function Program_Of (PID : in Process_ID) return String is
        use GNAT.Directory_Operations;
        use Ada.Strings.UTF_Encoding.Wide_Strings;

        Process : Handle := Invalid_Handle;
        Ignored : BOOL;

        Buffer : aliased Wide_String (1 .. Path_Max) := (others => ' ');
        Room : aliased DWORD := Buffer'Length;
    begin
        Process := Open_Process (Access_Wanted => Query_Limited_Information,
                                 Inherit => 0,
                                 PID => DWORD (PID));

        if Process = Invalid_Handle then
            return "";
        end if;

        if Query_Image_Name (Process, 0, Buffer'Address, Room'Access) = 0
           or else Room = 0
           or else Natural (Room) > Buffer'Length
        then
            Ignored := Close_Handle (Process);
            return "";
        end if;

        Ignored := Close_Handle (Process);

        return Plain_Name (Base_Name (Encode (Buffer (1 .. Natural (Room)))));
    exception
        when others =>
            if Process /= Invalid_Handle then
                Ignored := Close_Handle (Process);
            end if;

            return "";
    end Program_Of;

    --------------------------------------------------

    -- Measure a specific PID CPU time, in hunderds of nanoseconds
    -- Returns 0 if process does not exist, stopped, or any other issue
    function Ticks_Of_PID (PID : in Process_ID) return Integer_64 is
        Process : Handle := Invalid_Handle;
        Ignored : BOOL;

        Created, Finished, Kernel, User : aliased FILETIME;
        Used : Integer_64 := 0;
    begin
        Process := Open_Process (Access_Wanted => Query_Limited_Information,
                                 Inherit => 0,
                                 PID => DWORD (PID));

        if Process = Invalid_Handle then
            return 0;
        end if;

        if Get_Process_Times (Process,
                              Created'Access, Finished'Access,
                              Kernel'Access, User'Access) /= 0
        then
            Used := Joined (Kernel) + Joined (User);
        end if;

        Ignored := Close_Handle (Process);

        return Used;
    exception
        when others =>
            if Process /= Invalid_Handle then
                Ignored := Close_Handle (Process);
            end if;

            return 0;
    end Ticks_Of_PID;

    --------------------------------------------------

    -- Measure CPU time of the entire system
    function Measure_System return Sample is
        Result : Sample;
        Idle, Kernel, User : aliased FILETIME;
    begin
        if Get_System_Times (Idle'Access, Kernel'Access, User'Access) = 0 then
            return Result;
        end if;

        -- Windows counts the idle time inside kernel time
        -- So the busy time is the total - the idle time
        Result.Total := Joined (Kernel) + Joined (User);
        Result.Busy := Integer_64'Max (Result.Total - Joined (Idle), 0);

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
        Result : Sample := Measure_System;
        App_Name : constant String := Plain_Name (App);
        Numbers : Number_Array (1 .. Room_For) := (others => 0);
        Filled : aliased DWORD := 0;
        Counted : Natural;
    begin
        -- No app name, so return system CPU load
        if App = "" then
            return Result;
        end if;

        if Enum_Processes (Into => Numbers'Address,
                           Room => DWORD (Room_For * Bytes_Per_Number),
                           Filled => Filled'Access) = 0
        then
            return Result;
        end if;

        Counted := Natural'Min (Natural (Filled) / Bytes_Per_Number, Room_For);

        for Walked in 1 .. Counted loop
            -- Number 0 is the idle process, and a number too large for a Process_ID is not a valid one
            if Numbers (Walked) > 0
               and then Numbers (Walked) <= DWORD (Process_ID'Last)
            then
                -- Asking the name first is what keeps this cheap: a process
                -- that is not the one wanted is never opened a second time
                -- for its times
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