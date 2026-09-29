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

--  Prints the CPU load of the machine, of this very program, and of an application named on the command line, every second, until stopped with Ctrl+C
--
--  Build and run it with (the system is detected on its own, -XPJ_OS overrides it: linux, macos or windows):
--    gprbuild -P example/example.gpr -p
--    ./example/example_cpu_load firefox
--
--  A number after the name stops the program after that many readings ("" follows no application):
--    ./example/example_cpu_load "" 3

with Ada.Command_Line; use Ada.Command_Line;
with Ada.Strings; use Ada.Strings;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with Ada.Text_IO; use Ada.Text_IO;
with GNAT.Ctrl_C;
with GNAT.OS_Lib;

with CPU_Load; use CPU_Load;

--  use type: the Total = 0 check below compares Integer_64
with Interfaces;
use type Interfaces.Integer_64;

procedure Example_CPU_Load is

    Interval : constant Duration := 1.0;

    --  Atomic, as the handler runs in another thread on Windows
    Stop_Asked : Boolean := False with Atomic;

    --  Only asks the loop to stop: printing is not safe from a handler
    procedure On_Ctrl_C is
    begin
        Stop_Asked := True;
    end On_Ctrl_C;

    package Value_IO is new Ada.Text_IO.Float_IO (Long_Float);

    --  ANSI colours: cyan machine, magenta this program, yellow application, green ready, red trouble
    Escape : constant Character := ASCII.ESC;
    Reset : constant String := Escape & "[0m";
    Machine_Colour : constant String := Escape & "[1;36m";
    Mine_Colour : constant String := Escape & "[1;35m";
    App_Colour : constant String := Escape & "[1;33m";
    Ready_Colour : constant String := Escape & "[1;32m";
    Trouble_Colour : constant String := Escape & "[1;31m";

    --  Back to the start of the line and erase it, so each reading overwrites the last
    Clear_Line : constant String := ASCII.CR & Escape & "[2K";

    --  A load is a share of the whole machine: one core fully busy out of eight reads 12.5%
    function Image (Colour : in String;
                    Name : in String;
                    Load : in Long_Float) return String is
        Machine_Share : String (1 .. 12);

        Unreadable : constant String := Colour & Name & " n/a" & Reset;
    begin
        --  Negative: the load could not be read (process gone, or not allowed)
        if Load < 0.0 then
            return Unreadable;
        end if;

        Value_IO.Put (To => Machine_Share, Item => 100.0 * Load, Aft => 2, Exp => 0);

        return Colour & Name
               & " " & Trim (Machine_Share, Left) & "%"
               & Reset;
    exception
        --  The value does not fit in the buffer
        when others =>
            return Unreadable;
    end Image;

    Ours : constant Process_ID :=
        GNAT.OS_Lib.Pid_To_Integer (GNAT.OS_Lib.Current_Process_Id);

    --  No name given means no application is followed
    App : constant String :=
        (if Argument_Count >= 1 then Argument (1) else "");

    --  How many readings to take before stopping, or zero to run until Ctrl+C
    Wanted_Readings : constant Natural :=
        (if Argument_Count >= 2 then Natural'Value (Argument (2)) else 0);
    Taken : Natural := 0;

    --  Read the machine once per loop so all three loads cover the same interval
    Machine_Before, Machine_After : Sample;
    Mine_Before, Mine_After : Sample;
    App_Before, App_After : Sample;

begin
    Put_Line (Ready_Colour & "CPU Load" & Reset);

    if App = "" then
        Put_Line ("Following the machine and this program."
                  & " Name an application to follow it as well:"
                  & " " & Command_Name & " firefox");
    else
        Put_Line ("Following the machine, this program, and " & App);
    end if;

    --  Unrestricted_Access: the handler is nested in this procedure
    GNAT.Ctrl_C.Install_Handler (On_Ctrl_C'Unrestricted_Access);

    Machine_Before := Take;
    Mine_Before := Take (Ours, Machine_Before);
    App_Before := Take (App, Machine_Before);

    --  Total 0: the counters could not be read; without this it would print 0% forever and look idle
    if Machine_Before.Total = 0 then
        Put_Line (Trouble_Colour
                  & "The machine's counters could not be read at all."
                  & Reset);

#if PJ_MACOS then
        Put_Line ("Was this built for another system? Rebuild with -XPJ_OS=macos");
#elsif PJ_WINDOWS then
        Put_Line ("Was this built for another system? Rebuild with -XPJ_OS=windows");
#else
        Put_Line ("Is /proc mounted? Otherwise rebuild with -XPJ_OS=linux");
#end if;

        Set_Exit_Status (Failure);
        return;
    end if;

    while not Stop_Asked loop
        delay Interval;

        --  Ctrl+C interrupts the delay above, so don't print one last reading after it
        exit when Stop_Asked;

        Machine_After := Take;
        Mine_After := Take (Ours, Machine_After);
        App_After := Take (App, Machine_After);

        Put (Clear_Line
             & Image (Machine_Colour, "machine",
                      System_Usage (Machine_Before, Machine_After))
             & " | "
             & Image (Mine_Colour, "this program",
                      Process_Usage (Mine_Before, Mine_After)));

        if App /= "" then
            Put (" | " & Image (App_Colour, App,
                                Process_Usage (App_Before, App_After)));
        end if;

        Flush;

        Machine_Before := Machine_After;
        Mine_Before := Mine_After;
        App_Before := App_After;

        Taken := Taken + 1;
        exit when Wanted_Readings > 0 and then Taken >= Wanted_Readings;
    end loop;

    --  The readings share one line; end it first
    New_Line;
    Put_Line (Ready_Colour & "Stopping" & Reset);
end Example_CPU_Load;
