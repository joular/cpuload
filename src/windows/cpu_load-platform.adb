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
with Ada.Unchecked_Deallocation;
with GNAT.Directory_Operations;

package body CPU_Load.Platform is

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
    -- 'Object_Size and not 'Size: what is asked here is how much room the record actually takes, padding and all, which is what Windows writes into
    pragma Compile_Time_Error
        (FILETIME'Object_Size /= 64, "FILETIME must be exactly 8 bytes");

    -- A wide character in Windows is sixteen bits
    pragma Compile_Time_Error
        (Wide_Character'Size /= 16,
         "Wide_Character must be 16 bits to pass a buffer to Windows");

    Query_Limited_Information : constant DWORD := 16#1000#;

    -- How many processes one list holds, and how many the largest one ever asked for holds
    -- The first is taken on the stack and is what every machine of a usual size takes; the second is only reached by a machine running more processes than that, and is taken off the heap
    Room_For : constant := 4096;
    Max_Processes : constant := 65_536;

    Bytes_Per_Number : constant := DWORD'Size / 8;

    -- Windows writes a program's path as wide characters, and this holds all but the very longest of them
    -- A path may reach 32767 characters once long paths are turned on, and a process whose path is longer than this is passed over
    Path_Max : constant := 4_096;

    type Number_Array is array (Positive range <>) of aliased DWORD;
    type Number_Array_Access is access Number_Array;

    procedure Free is
        new Ada.Unchecked_Deallocation (Number_Array, Number_Array_Access);

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

        -- Forgotten as soon as it is given back, so the handler below never gives back a handle twice
        -- The number of a handle just closed is Windows' to hand out again, and closing it a second time is closing whatever it now belongs to
        Process := Invalid_Handle;

        return Used;
    exception
        when others =>
            if Process /= Invalid_Handle then
                Ignored := Close_Handle (Process);
                Process := Invalid_Handle;
            end if;

            return 0;
    end Ticks_Of_PID;

    --------------------------------------------------

    -- Measure the CPU time of one process, but only if its program is the one named
    -- Returns 0 if it runs another program, or if it cannot be read at all
    -- The process is opened once here for both questions, and asking the name first is what keeps this cheap: a process that is not the one wanted is never asked for its times
    function Ticks_If_Named (PID : in Process_ID;
                             App_Name : in String) return Integer_64 is
        use GNAT.Directory_Operations;
        use Ada.Strings.UTF_Encoding.Wide_Strings;

        Process : Handle := Invalid_Handle;
        Ignored : BOOL;

        Buffer : aliased Wide_String (1 .. Path_Max);
        Room : aliased DWORD := Buffer'Length;

        Created, Finished, Kernel, User : aliased FILETIME;
        Used : Integer_64 := 0;
    begin
        Process := Open_Process (Access_Wanted => Query_Limited_Information,
                                 Inherit => 0,
                                 PID => DWORD (PID));

        if Process = Invalid_Handle then
            return 0;
        end if;

        -- Windows writes the path and says how many characters it wrote, the closing NUL not counted
        -- Encode is what turns those wide characters into a String, and it is also what may raise here, on a path holding one half of a character pair and not the other
        if Query_Image_Name (Process, 0, Buffer'Address, Room'Access) /= 0
           and then Room /= 0
           and then Natural (Room) <= Buffer'Length
           and then Plain_Name (Base_Name (Encode (Buffer (1 .. Natural (Room)))))
                    = App_Name
           and then Get_Process_Times (Process,
                                       Created'Access, Finished'Access,
                                       Kernel'Access, User'Access) /= 0
        then
            Used := Joined (Kernel) + Joined (User);
        end if;

        Ignored := Close_Handle (Process);
        Process := Invalid_Handle;

        return Used;
    exception
        when others =>
            if Process /= Invalid_Handle then
                Ignored := Close_Handle (Process);
                Process := Invalid_Handle;
            end if;

            return 0;
    end Ticks_If_Named;

    --------------------------------------------------

    -- Add up the CPU time of every process of the application, out of the Count process numbers Windows listed
    function Sum_Named (Numbers : in Number_Array;
                        Count : in Natural;
                        App_Name : in String) return Integer_64 is
        Result : Integer_64 := 0;
    begin
        for Walked in Numbers'First .. Numbers'First + Count - 1 loop
            -- Number 0 is the idle process, and a number too large for a Process_ID is not a valid one
            if Numbers (Walked) > 0
               and then Numbers (Walked) <= DWORD (Process_ID'Last)
            then
                Result := Result
                        + Ticks_If_Named (Process_ID (Numbers (Walked)), App_Name);
            end if;
        end loop;

        return Result;
    end Sum_Named;

    --------------------------------------------------

    -- The same, for a machine running more processes than a list on the stack holds
    -- Only reached when the list came back filled to the brim, which is Windows saying there may be more of them, and which no machine of a usual size ever does
    -- The list is taken twice as large until it comes back with room to spare, and off the heap, being too large for the stack by then
    function Used_By_Many (App_Name : in String) return Integer_64 is
        Capacity : Natural := Room_For * 2;
        Numbers : Number_Array_Access;
        Filled : aliased DWORD := 0;
        Room : DWORD;
        Result : Integer_64 := 0;
    begin
        loop
            Numbers := new Number_Array (1 .. Capacity);
            Room := DWORD (Capacity * Bytes_Per_Number);

            if Enum_Processes (Into => Numbers.all (1)'Address,
                               Room => Room,
                               Filled => Filled'Access) = 0
            then
                Free (Numbers);
                return 0;
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
            return 0;
    end Used_By_Many;

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

    function Used_By_App (App : in String) return Integer_64 is
        App_Name : constant String := Plain_Name (App);

        -- The list every machine of a usual size fits in, taken on the stack
        -- Left as it comes: Windows fills it, and only as much of it as Windows says it filled is ever read
        Numbers : Number_Array (1 .. Room_For);
        Filled : aliased DWORD := 0;
        Room : constant DWORD := DWORD (Room_For * Bytes_Per_Number);
    begin
        if Enum_Processes (Into => Numbers'Address,
                           Room => Room,
                           Filled => Filled'Access) = 0
        then
            return 0;
        end if;

        -- A list filled to the brim is Windows saying there may be more processes than fit in it
        -- Anything short of that is all of them
        if Filled = Room then
            return Used_By_Many (App_Name);
        end if;

        return Sum_Named (Numbers, Natural (Filled) / Bytes_Per_Number, App_Name);
    exception
        when others =>
            return 0;
    end Used_By_App;

end CPU_Load.Platform;
