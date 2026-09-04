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
--  Build and run it with (-XPJ_OS says which system to build for: linux, macos or windows):
--    gprbuild -P example/example.gpr -XPJ_OS=macos -p
--    ./example/example_cpu_load firefox

with Ada.Command_Line; use Ada.Command_Line;
with Ada.Strings; use Ada.Strings;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with Ada.Text_IO; use Ada.Text_IO;
with GNAT.Ctrl_C;
with GNAT.OS_Lib;

with CPU_Load; use CPU_Load;

--  A Sample's counters are Integer_64, so comparing one needs its operators here
with Interfaces;
use type Interfaces.Integer_64;

procedure Example_CPU_Load is

    --  Time between two samples
    Interval : constant Duration := 1.0;

    --  Set to True when Ctrl+C is pressed, so the reading loop stops
    --  Volatile, as it is written while the loop below is running
    Stop_Asked : Boolean := False;
    pragma Volatile (Stop_Asked);

    --  Called when Ctrl+C is pressed
    --  It only asks the loop to stop: printing is not safe to do from a handler
    procedure On_Ctrl_C is
    begin
        Stop_Asked := True;
    end On_Ctrl_C;

    --  Prints floats in plain digits rather than in exponent notation
    package Value_IO is new Ada.Text_IO.Float_IO (Long_Float);

    --  ANSI escape sequences: cyan for the machine, magenta for this program, yellow for the application, green for the start up message
    Escape : constant Character := ASCII.ESC;
    Reset : constant String := Escape & "[0m";
    Machine_Colour : constant String := Escape & "[1;36m";
    Mine_Colour : constant String := Escape & "[1;35m";
    App_Colour : constant String := Escape & "[1;33m";
    Ready_Colour : constant String := Escape & "[1;32m";
    Trouble_Colour : constant String := Escape & "[1;31m";

    --  Goes back to the beginning of the line and erases it, so each reading overwrites the previous one instead of scrolling
    Clear_Line : constant String := ASCII.CR & Escape & "[2K";

    --  Formats one load as a percentage with two decimals
    --  A load is a share of the whole machine, so one core fully busy on an eight core machine reads 12.5%
    function Image (Colour : in String;
                    Name : in String;
                    Load : in Long_Float) return String is
        Machine_Share : String (1 .. 12);
    begin
        Value_IO.Put (To => Machine_Share, Item => 100.0 * Load, Aft => 2, Exp => 0);

        return Colour & Name
               & " " & Trim (Machine_Share, Left) & "%"
               & Reset;
    exception
        --  The value does not fit in the buffer
        when others =>
            return Colour & Name & " n/a" & Reset;
    end Image;

    --  This program's own process number
    --  No conversion: a PID from anywhere else is already a number
    Ours : constant Process_ID :=
        GNAT.OS_Lib.Pid_To_Integer (GNAT.OS_Lib.Current_Process_Id);

    --  The application to follow, named on the command line
    --  No name given means no application is followed
    App : constant String :=
        (if Argument_Count >= 1 then Argument (1) else "");

    --  The machine is read once per reading, and the other two are measured against that one reading
    --  Each of the three is then measured over exactly the same stretch of time, and the machine's counters are read once a second rather than three times
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

    --  Stop cleanly on Ctrl+C, instead of being killed on the spot
    --  Unrestricted_Access is needed as the handler is declared inside this procedure rather than on its own
    GNAT.Ctrl_C.Install_Handler (On_Ctrl_C'Unrestricted_Access);

    --  The first sample of each, which the first reading below is measured against
    Machine_Before := Take;
    Mine_Before := Take (Ours, Machine_Before);
    App_Before := Take (App, Machine_Before);

    --  A Total of zero is the library saying it could not read the machine's counters at all
    --  It is what a library built for another system does here, and it would otherwise show as a row of 0% every second, which looks like an idle machine rather than a build to redo
    if Machine_Before.Total = 0 then
        Put_Line (Trouble_Colour
                  & "The machine's counters could not be read at all."
                  & " This is what a library built for another system does: build it again with -XPJ_OS for this one (linux, macos or windows)."
                  & Reset);
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

        --  This reading becomes the one the next is measured against
        Machine_Before := Machine_After;
        Mine_Before := Mine_After;
        App_Before := App_After;
    end loop;

    --  The readings are printed on a single line, so end it before printing anything else
    New_Line;
    Put_Line (Ready_Colour & "Stopping" & Reset);
end Example_CPU_Load;
