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

-- FreeBSD, OpenBSD, NetBSD and DragonFly, detected when the library starts: all read the same counters through sysctl, and differ in the numbers naming them and in where each field sits in a kinfo_proc
-- The numbers come from sys/sysctl.h, sys/user.h (FreeBSD) and sys/kinfo.h (DragonFly), for 64-bit systems
package body CPU_Load.Platform is

    use type Interfaces.C.int;
    use type Interfaces.C.size_t;

    subtype Int is Interfaces.C.int;
    subtype Size is Interfaces.C.size_t;

    -- A sysctl name: a few numbers saying what is asked for
    type Name is array (Positive range <>) of Int;

    -- Bytes of a kernel structure, read at the offsets below
    type Bytes is array (Positive range <>) of Unsigned_8 with Alignment => 8;
    type Bytes_Access is access Bytes;

    procedure Free is new Ada.Unchecked_Deallocation (Bytes, Bytes_Access);

    CTL_KERN : constant Int := 1;
    KERN_OSTYPE : constant Int := 1;
    KERN_CLOCKRATE : constant Int := 12;
    KERN_PROC_PID : constant Int := 1;
    CTL_HW : constant Int := 6;
    HW_NCPU : constant Int := 3;

    --------------------------------------------------

    -- Length is the room at Value, then how much was written
    function Sysctl (MIB : in System.Address;
                     Count : in Interfaces.C.unsigned;
                     Value : in System.Address;
                     Length : access Size;
                     New_Value : in System.Address;
                     New_Length : in Size) return Int
        with Import, Convention => C, External_Name => "sysctl";

    -- Ask the kernel for MIB into Value; False if it will not answer, or Value is too small
    function Ask (MIB : in Name;
                  Value : in System.Address;
                  Length : in out Size;
                  New_Value : in System.Address := System.Null_Address;
                  New_Length : in Size := 0) return Boolean is
        Room : aliased Size := Length;
    begin
        if Sysctl (MIB (MIB'First)'Address, MIB'Length, Value, Room'Access, New_Value, New_Length) /= 0 then
            return False;
        end if;

        Length := Room;
        return True;
    end Ask;

    --------------------------------------------------

    function Word_32 (Data : in Bytes; From : in Natural) return Unsigned_32 is
        Value : Unsigned_32 with Import, Address => Data (Data'First + From)'Address;
    begin
        return Value;
    end Word_32;

    function Word_64 (Data : in Bytes; From : in Natural) return Unsigned_64 is
        Value : Unsigned_64 with Import, Address => Data (Data'First + From)'Address;
    begin
        return Value;
    end Word_64;

    -- The characters before the first NUL
    function Text (Data : in Bytes) return String is
        Result : String (1 .. Data'Length);
        Last : Natural := 0;
    begin
        for B of Data loop
            exit when B = 0;

            Last := Last + 1;
            Result (Last) := Character'Val (B);
        end loop;

        return Result (1 .. Last);
    end Text;

    --------------------------------------------------

    type System_Kind is (FreeBSD, OpenBSD, NetBSD, DragonFly, Other);

    -- From kern.ostype; Other reads nothing
    function Detect return System_Kind is
        Answer : Bytes (1 .. 32) := (others => 0);
        Length : Size := Answer'Length;
    begin
        if not Ask ((CTL_KERN, KERN_OSTYPE), Answer'Address, Length) then
            return Other;
        end if;

        declare
            OS : constant String := Text (Answer);
        begin
            return (if OS = "FreeBSD" then FreeBSD
                    elsif OS = "OpenBSD" then OpenBSD
                    elsif OS = "NetBSD" then NetBSD
                    elsif OS = "DragonFly" then DragonFly
                    else Other);
        end;
    exception
        when others =>
            return Other;
    end Detect;

    Kind : constant System_Kind := Detect;

    --------------------------------------------------

    -- How a kinfo_proc holds the CPU time of the process
    type Time_Form is
        (Microseconds,                -- One 64-bit count
         Seconds_And_Microseconds,    -- Two 32-bit counts
         Three_Microsecond_Counts);   -- Three 64-bit counts: user, system and interrupt time

    -- The states of a process that has ended (one repeated where there are fewer)
    type Ended_States is array (1 .. 3) of Unsigned_8;

    function Get_PID return Int
        with Import, Convention => C, External_Name => "getpid";

    -- DragonFly's kinfo_proc grows from one release to the next, so the kernel is asked its size: how much it writes about one process, this one
    -- 728 bytes reach the end of the fields read here
    function Process_Size return Natural is
        Data : Bytes (1 .. 4_096);
        Length : Size := Data'Length;
    begin
        if Ask ((CTL_KERN, 14, KERN_PROC_PID, Get_PID), Data'Address, Length) and then Length >= 728 then
            return Natural (Length);
        end if;

        return 0;
    end Process_Size;

    -- The numbers asking for processes, and where things are in the kinfo_proc each OS answers with
    type Layout is
        record
            Proc : Int;             -- KERN_PROC, KERN_PROC2 on NetBSD
            Every : Int;            -- The request listing every process once: KERN_PROC_PROC on FreeBSD, where KERN_PROC_ALL lists every thread
            Sized : Boolean;        -- OpenBSD and NetBSD take the size of an entry, and how many, as two more numbers
            Size : Natural;         -- Bytes in one entry: the whole struct, or on OpenBSD and NetBSD the part up to the last field read, as both allow
            PID_At : Natural;
            Time_At : Natural;
            Time : Time_Form;
            State_At : Natural;
            State_Bytes : Positive;
            Ended : Ended_States;
            Name_At : Natural;      -- The command name, and its room
            Name_Length : Natural;
        end record;

    Where : constant Layout :=
        (case Kind is
            when FreeBSD =>
                -- struct kinfo_proc: ki_pid, ki_runtime (microseconds), ki_stat (SZOMB), ki_comm
                (Proc => 14, Every => 8, Sized => False, Size => 1088, PID_At => 72,
                 Time_At => 328, Time => Microseconds,
                 State_At => 388, State_Bytes => 1, Ended => (others => 5),
                 Name_At => 447, Name_Length => 20),
            when OpenBSD =>
                -- struct kinfo_proc: p_pid, p_rtime_sec and p_rtime_usec, p_stat (SDEAD, as SZOMB is never given), p_comm
                (Proc => 66, Every => 0, Sized => True, Size => 336, PID_At => 108,
                 Time_At => 220, Time => Seconds_And_Microseconds,
                 State_At => 304, State_Bytes => 1, Ended => (others => 6),
                 Name_At => 312, Name_Length => 24),
            when NetBSD =>
                -- struct kinfo_proc2: p_pid, p_rtime_sec and p_rtime_usec, p_realstat (SDYING, SZOMB, SDEAD; p_stat is the state of a thread), p_comm
                (Proc => 47, Every => 0, Sized => True, Size => 640, PID_At => 116,
                 Time_At => 228, Time => Seconds_And_Microseconds,
                 State_At => 632, State_Bytes => 8, Ended => (3, 5, 6),
                 Name_At => 368, Name_Length => 24),
            when DragonFly =>
                -- struct kinfo_proc: kp_pid, kp_lwp.kl_uticks, kl_sticks and kl_iticks (microseconds), kp_stat (SZOMB), kp_comm
                (Proc => 14, Every => 0, Sized => False, Size => Process_Size, PID_At => 220,
                 Time_At => 704, Time => Three_Microsecond_Counts,
                 State_At => 12, State_Bytes => 4, Ended => (others => 4),
                 Name_At => 112, Name_Length => 17),
            when Other =>
                (Proc => 0, Every => 0, Sized => False, Size => 0, PID_At => 0,
                 Time_At => 0, Time => Microseconds,
                 State_At => 0, State_Bytes => 1, Ended => (others => 0),
                 Name_At => 0, Name_Length => 0));

    --------------------------------------------------

    -- kern.cp_time, the CPU time counters of the machine: a fixed number on NetBSD; FreeBSD and DragonFly give it none, so it is looked up by name
    -- OpenBSD only gives an average per CPU there, so its CPUs are read one by one instead (kern.cp_time2)
    function Find_CP_Time return Name is
        Found : Name (1 .. 8) := (others => 0);
        Length : Size := Found'Size / 8;
        Wanted : constant String := "kern.cp_time";
    begin
        case Kind is
            when NetBSD =>
                return (CTL_KERN, 51);   -- kern.cp_time

            when FreeBSD | DragonFly =>
                -- sysctl.name2oid
                if Ask ((0, 3), Found'Address, Length, Wanted'Address, Wanted'Length) then
                    return Found (1 .. Natural (Length) / (Int'Size / 8));
                end if;

                return Found (1 .. 0);

            when OpenBSD | Other =>
                return Found (1 .. 0);
        end case;
    end Find_CP_Time;

    CP_Time : constant Name := Find_CP_Time;

    -- hw.ncpu, for OpenBSD
    function Read_CPU_Count return Natural is
        Count : aliased Int := 0;
        Length : Size := Count'Size / 8;
    begin
        if Kind /= OpenBSD or else not Ask ((CTL_HW, HW_NCPU), Count'Address, Length) or else Count < 0 then
            return 0;
        end if;

        return Natural (Count);
    end Read_CPU_Count;

    CPU_Count : constant Natural := Read_CPU_Count;

    --------------------------------------------------

    -- The counters count statclock ticks, whose rate is stathz of kern.clockrate (hz where the two clocks are one); DragonFly counts microseconds instead
    function Read_Stat_Hz return Integer_64 is
        -- struct clockinfo: hz, tick, tickadj (spare on FreeBSD), stathz, profhz, four bytes each; OpenBSD leaves out the third
        Clock : Bytes (1 .. 20) := (others => 0);
        Length : Size := Clock'Length;
    begin
        if not Ask ((CTL_KERN, KERN_CLOCKRATE), Clock'Address, Length) then
            return 0;
        end if;

        return Integer_64 (Word_32 (Clock, (if Length = 16 then 8 else 12)));
    end Read_Stat_Hz;

    Stat_Hz : constant Integer_64 := Read_Stat_Hz;

    -- Ticks to microseconds, divided before multiplied so the sum over every core of a long uptime can't overflow; DragonFly already counts microseconds
    function To_Microseconds (Ticks : in Integer_64) return Integer_64 is
        (if Kind = DragonFly then Ticks
         elsif Stat_Hz > 0 then (Ticks / Stat_Hz) * 1_000_000 + (Ticks mod Stat_Hz) * 1_000_000 / Stat_Hz
         else 0);

    --------------------------------------------------

    -- The numbers asking for processes: every one of them, or the one of PID
    function Process_Name (What : in Int; PID : in Int; Count : in Int) return Name is
        (if Where.Sized then (CTL_KERN, Where.Proc, What, PID, Int (Where.Size), Count)
         elsif What = Where.Every then (CTL_KERN, Where.Proc, What)
         else (CTL_KERN, Where.Proc, What, PID));

    -- The kinfo_proc of PID, empty if there is no such process (some BSDs answer that with an error, others with nothing)
    -- The answer must be about PID: above the last process number, FreeBSD takes the number for a thread, and answers with its process
    function Read_Process (PID : in Process_ID) return Bytes is
        Data : Bytes (1 .. Where.Size) := (others => 0);
        Length : Size := Data'Length;
    begin
        if Where.Size = 0
           or else not Ask (Process_Name (KERN_PROC_PID, Int (PID), 1), Data'Address, Length)
           or else Natural (Length) /= Where.Size
           or else Word_32 (Data, Where.PID_At) /= Unsigned_32 (PID)
        then
            return Data (1 .. 0);
        end if;

        return Data;
    end Read_Process;

    -- Whether the process has ended, its times frozen
    function Has_Ended (Data : in Bytes) return Boolean is
        State : constant Unsigned_64 :=
            (case Where.State_Bytes is
                when 8 => Word_64 (Data, Where.State_At),
                when 4 => Unsigned_64 (Word_32 (Data, Where.State_At)),
                when others => Unsigned_64 (Data (Data'First + Where.State_At)));
    begin
        return (for some Ended of Where.Ended => State = Unsigned_64 (Ended));
    end Has_Ended;

    -- CPU time of the process, in microseconds
    function CPU_Time (Data : in Bytes) return Integer_64 is
        From : constant Natural := Where.Time_At;
    begin
        case Where.Time is
            when Microseconds =>
                return Integer_64 (Word_64 (Data, From));

            when Seconds_And_Microseconds =>
                return Integer_64 (Word_32 (Data, From)) * 1_000_000 + Integer_64 (Word_32 (Data, From + 4));

            when Three_Microsecond_Counts =>
                return Integer_64 (Word_64 (Data, From)) + Integer_64 (Word_64 (Data, From + 8)) + Integer_64 (Word_64 (Data, From + 16));
        end case;
    end CPU_Time;

    --------------------------------------------------

    -- Full path of the program PID runs, "" where the OS can't or won't say: OpenBSD never does, and kernel processes run none
    function Path_Of (PID : in Process_ID) return String is
        -- PATH_MAX on the BSDs
        Path : Bytes (1 .. 1_024) := (others => 0);
        Length : Size := Path'Length;

        Asked : constant Name :=
            (case Kind is
                when FreeBSD => (CTL_KERN, 14, 12, Int (PID)),        -- kern.proc.pathname
                when DragonFly => (CTL_KERN, 14, 9, Int (PID)),       -- kern.proc.pathname
                when NetBSD => (CTL_KERN, 48, Int (PID), 5),          -- kern.proc_args, KERN_PROC_PATHNAME
                when OpenBSD | Other => (1 .. 0 => 0));
    begin
        if Asked'Length = 0 or else not Ask (Asked, Path'Address, Length) then
            return "";
        end if;

        return Text (Path);
    end Path_Of;

    -- Base name of the program PID runs, or its command name (cut short by the kernel) where the program is not known
    function Program_Of (PID : in Process_ID; Data : in Bytes) return String is
        Path : constant String := Path_Of (PID);
        First : constant Positive := Data'First + Where.Name_At;
    begin
        if Path = "" then
            return Text (Data (First .. First + Where.Name_Length - 1));
        end if;

        return GNAT.Directory_Operations.Base_Name (Path);
    end Program_Of;

    --------------------------------------------------

    function Measure_System return Sample is
        Busy : Integer_64 := 0;
        Idle : Integer_64 := 0;

        -- Adds the counters named by MIB: user, nice, system, interrupt and idle (OpenBSD puts spin before interrupt), eight bytes each; idle is last
        procedure Add (MIB : in Name) is
            Times : array (1 .. 8) of Unsigned_64 := (others => 0);

            -- NetBSD sums its CPUs only when asked for exactly five counters, and gives one set per CPU for any other room
            Length : Size := (if Kind = NetBSD then 5 * 8 else Times'Size / 8);
            Count : Natural;
        begin
            if not Ask (MIB, Times'Address, Length) then
                return;
            end if;

            -- Five states, six on OpenBSD; anything else is a layout this body doesn't know
            Count := Natural (Length) / 8;

            if Count not in 5 .. 6 then
                return;
            end if;

            for I in 1 .. Count - 1 loop
                Busy := Busy + Integer_64 (Times (I));
            end loop;

            Idle := Idle + Integer_64 (Times (Count));
        end Add;
    begin
        -- A CPU number with no CPU behind it adds nothing
        if Kind = OpenBSD then
            for CPU in 0 .. CPU_Count - 1 loop
                Add ((CTL_KERN, 71, Int (CPU)));   -- kern.cp_time2
            end loop;
        elsif CP_Time'Length > 0 then
            Add (CP_Time);
        end if;

        -- Nothing added leaves Total at 0: the counters could not be read
        return (Busy => To_Microseconds (Busy),
                Total => To_Microseconds (Busy + Idle),
                Used => 0);
    exception
        when others =>
            return (others => 0);
    end Measure_System;

    --------------------------------------------------

    function Used_By_PID (PID : in Process_ID) return Integer_64 is
        Data : constant Bytes := Read_Process (PID);
    begin
        if Data'Length = 0 or else Has_Ended (Data) then
            return Not_Read;
        end if;

        return CPU_Time (Data);
    exception
        when others =>
            return Not_Read;
    end Used_By_PID;

    --------------------------------------------------

    function Runs (PID : in Process_ID; App : in String) return Boolean is
        use Ada.Characters.Handling;

        Data : constant Bytes := Read_Process (PID);
    begin
        -- A process that has ended keeps its name, so the state settles it
        return Data'Length > 0 and then not Has_Ended (Data)
               and then To_Lower (Program_Of (PID, Data)) = To_Lower (App);
    exception
        when others =>
            return False;
    end Runs;

    --------------------------------------------------

    function For_Each_Process (Action : not null access procedure (PID : in Process_ID))
        return Boolean is
        Length : Size := 0;
        List : Bytes_Access;
    begin
        -- With no buffer, sysctl answers the room needed; processes may start meanwhile, so take twice that
        if Where.Size = 0
           or else not Ask (Process_Name (Where.Every, 0, Int'Last), System.Null_Address, Length)
        then
            return False;
        end if;

        Length := Length * 2;
        List := new Bytes (1 .. Natural (Length));

        if not Ask (Process_Name (Where.Every, 0, Int (Natural (Length) / Where.Size)), List.all'Address, Length) then
            Free (List);
            return False;
        end if;

        -- One entry per process; PID 0 is the kernel
        for Entry_Number in 0 .. Natural (Length) / Where.Size - 1 loop
            declare
                PID : constant Unsigned_32 := Word_32 (List.all, Entry_Number * Where.Size + Where.PID_At);
            begin
                if PID in 1 .. Unsigned_32 (Process_ID'Last) then
                    Action (Process_ID (PID));
                end if;
            end;
        end loop;

        Free (List);
        return True;
    exception
        when others =>
            Free (List);
            return False;
    end For_Each_Process;

end CPU_Load.Platform;
