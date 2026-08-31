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
--  Build and run it with:
--    gprbuild -P example/example.gpr -p
--    ./example/example_cpu_load firefox

with Ada.Command_Line; use Ada.Command_Line;
with Ada.Strings; use Ada.Strings;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with Ada.Text_IO; use Ada.Text_IO;
with GNAT.Ctrl_C;
with GNAT.OS_Lib;
with System.Multiprocessors;

with CPU_Load; use CPU_Load;

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

    --  Goes back to the beginning of the line and erases it, so each reading overwrites the previous one instead of scrolling
    Clear_Line : constant String := ASCII.CR & Escape & "[2K";

    --  A load is a share of the whole machine, so one core fully busy on an eight core machine reads 12.5%
    --  Multiplied by the number of cores, it is the figure top and the task manager show
    Cores : constant Long_Float :=
        Long_Float (System.Multiprocessors.Number_Of_CPUs);

    --  Formats one load as a percentage with two decimals, of the whole machine and then of one core
    function Image (Colour : in String;
                    Name : in String;
                    Load : in Long_Float) return String is
        Machine_Share : String (1 .. 12);
        Core_Share : String (1 .. 12);
    begin
        Value_IO.Put (To => Machine_Share, Item => 100.0 * Load, Aft => 2, Exp => 0);
        Value_IO.Put (To => Core_Share, Item => 100.0 * Load * Cores, Aft => 2, Exp => 0);

        return Colour & Name
               & " " & Trim (Machine_Share, Left) & "%"
               & " (" & Trim (Core_Share, Left) & "% of one core)"
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

    --  Each thing followed keeps its own pair of samples, so each is measured over exactly the stretch of time between its own two
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
    Mine_Before := Take (Ours);
    App_Before := Take (App);

    while not Stop_Asked loop
        delay Interval;

        --  Ctrl+C interrupts the delay above, so don't print one last reading after it
        exit when Stop_Asked;

        Machine_After := Take;
        Mine_After := Take (Ours);
        App_After := Take (App);

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
