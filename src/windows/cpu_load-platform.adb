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

    subtype DWORD is Interfaces.C.unsigned;
    subtype BOOL is Interfaces.C.int;
    subtype Handle is System.Address;

    use type BOOL;
    use type DWORD;
    use type Handle;

    Null_Handle : constant Handle := System.Null_Address;

    PROCESS_QUERY_LIMITED_INFORMATION : constant DWORD := 16#1000#;

    -- 100 ns units, in two halves
    type FILETIME is
        record
            Low : DWORD := 0;
            High : DWORD := 0;
        end record
        with Convention => C;

    -- Must match the Windows struct: 8 bytes, Low first
    for FILETIME use
        record
            Low at 0 range 0 .. 31;
            High at 4 range 0 .. 31;
        end record;

    for FILETIME'Size use 64;

    pragma Compile_Time_Error
        (Wide_Character'Size /= 16,
         "Wide_Character must be 16 bits to pass a buffer to Windows");

    --------------------------------------------------

    function Get_System_Times (Idle : access FILETIME;
                               Kernel : access FILETIME;
                               User : access FILETIME) return BOOL
        with Import, Convention => Stdcall, External_Name => "GetSystemTimes";

    function Open_Process (Desired_Access : in DWORD;
                           Inherit_Handle : in BOOL;
                           PID : in DWORD) return Handle
        with Import, Convention => Stdcall, External_Name => "OpenProcess";

    function Get_Process_Times (Process : in Handle;
                                Creation : access FILETIME;
                                Finished : access FILETIME;
                                Kernel : access FILETIME;
                                User : access FILETIME) return BOOL
        with Import, Convention => Stdcall, External_Name => "GetProcessTimes";

    -- The BOOL result is dropped: nothing to do about a handle that will not close
    procedure Close_Handle (Object : in Handle)
        with Import, Convention => Stdcall, External_Name => "CloseHandle";

    function Enum_Processes (PIDs : in System.Address;
                             Size : in DWORD;
                             Bytes_Returned : access DWORD) return BOOL
        with Import, Convention => Stdcall, External_Name => "EnumProcesses";

    -- Size is in/out: room in the buffer, then characters written, NUL not counted
    function Query_Full_Process_Image_Name (Process : in Handle;
                                            Flags : in DWORD;
                                            Name : in System.Address;
                                            Size : access DWORD) return BOOL
        with Import, Convention => Stdcall,
             External_Name => "QueryFullProcessImageNameW";

    --------------------------------------------------

    -- Ten 100 ns units to a microsecond
    function To_Microseconds (Time : in FILETIME) return Integer_64 is
        ((Integer_64 (Time.High) * 2 ** 32 + Integer_64 (Time.Low)) / 10);

    -- Null_Handle if the process is gone, or another user's
    function Open_For_Query (PID : in Process_ID) return Handle is
        (Open_Process (PROCESS_QUERY_LIMITED_INFORMATION, 0, DWORD (PID)));

    --------------------------------------------------

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

    -- Program name without its folders, or "" if Windows will not say
    function Program_Of (PID : in Process_ID) return String is
        use Ada.Strings.UTF_Encoding.Wide_Strings;

        Process : constant Handle := Open_For_Query (PID);

        -- Paths longer than this (long-path mode, up to 32767) are skipped
        Path : Wide_String (1 .. 4_096);
        Length : aliased DWORD := Path'Length;
        Success : BOOL;
    begin
        if Process = Null_Handle then
            return "";
        end if;

        Success := Query_Full_Process_Image_Name (Process, 0, Path'Address, Length'Access);
        Close_Handle (Process);

        if Success = 0 or else Length = 0 or else Length > Path'Length then
            return "";
        end if;

        -- Encode raises on a lone surrogate; Runs catches it
        return GNAT.Directory_Operations.Base_Name (Encode (Path (1 .. Natural (Length))));
    end Program_Of;

    --------------------------------------------------

    function Measure_System return Sample is
        Result : Sample;
        Idle, Kernel, User : aliased FILETIME;
    begin
        if Get_System_Times (Idle'Access, Kernel'Access, User'Access) = 0 then
            return Result;
        end if;

        -- Kernel time includes idle time
        Result.Total := To_Microseconds (Kernel) + To_Microseconds (User);
        Result.Busy := Integer_64'Max (Result.Total - To_Microseconds (Idle), 0);

        return Result;
    exception
        when others =>
            return (others => 0);
    end Measure_System;

    --------------------------------------------------

    function Used_By_PID (PID : in Process_ID) return Integer_64 is
        Process : constant Handle := Open_For_Query (PID);
        Creation, Finished, Kernel, User : aliased FILETIME;
        Success : BOOL;
    begin
        if Process = Null_Handle then
            return Not_Read;
        end if;

        Success := Get_Process_Times (Process,
                                      Creation'Access, Finished'Access,
                                      Kernel'Access, User'Access);
        Close_Handle (Process);

        -- A process that has ended stays open to queries while a handle to it is held. Its exit time, zero until then, gives it away
        if Success = 0 or else To_Microseconds (Finished) /= 0 then
            return Not_Read;
        end if;

        return To_Microseconds (Kernel) + To_Microseconds (User);
    exception
        when others =>
            return Not_Read;
    end Used_By_PID;

    --------------------------------------------------

    function Runs (PID : in Process_ID; App : in String) return Boolean is
    begin
        return Plain_Name (Program_Of (PID)) = Plain_Name (App);
    exception
        when others =>
            return False;
    end Runs;

    --------------------------------------------------

    type PID_List is array (Positive range <>) of DWORD;
    type PID_List_Access is access PID_List;

    procedure Free is new Ada.Unchecked_Deallocation (PID_List, PID_List_Access);

    -- Processes past Max_Capacity are passed over
    First_Capacity : constant := 4_096;
    Max_Capacity : constant := 65_536;

    PID_Bytes : constant := DWORD'Size / 8;

    function For_Each_Process (Action : not null access procedure (PID : in Process_ID))
        return Boolean is
        Capacity : Positive := First_Capacity;
        PIDs : PID_List_Access;
        Room : DWORD;
        Filled : aliased DWORD := 0;
        Success : BOOL;
    begin
        -- A full list may be truncated, so retry with twice the room
        loop
            PIDs := new PID_List (1 .. Capacity);
            Room := DWORD (Capacity * PID_Bytes);
            Success := Enum_Processes (PIDs (1)'Address, Room, Filled'Access);

            exit when Success = 0 or else Filled < Room or else Capacity >= Max_Capacity;

            Free (PIDs);
            Capacity := Capacity * 2;
        end loop;

        if Success = 0 then
            Free (PIDs);
            return False;
        end if;

        for PID of PIDs (1 .. Natural (Filled) / PID_Bytes) loop
            -- PID 0 is the idle process
            if PID in 1 .. DWORD (Process_ID'Last) then
                Action (Process_ID (PID));
            end if;
        end loop;

        Free (PIDs);
        return True;
    exception
        when others =>
            -- Free of null is a no-op
            Free (PIDs);
            return False;
    end For_Each_Process;

end CPU_Load.Platform;
