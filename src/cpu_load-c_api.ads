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

-- Without this the Ada runtime installs handlers for SIGSEGV, SIGBUS, SIGFPE, SIGILL and SIGABRT when the library loads; the JVM needs SIGSEGV and SIGBUS for null checks and safepoints, and Python expects its own handlers to stay
-- Only applies where this unit is bound (the shared library), not to Ada programs using CPU_Load directly
-- Cost: a stack overflow or bad memory access inside the library ends the process instead of raising
pragma Interrupts_System_By_Default;

with Interfaces.C;
with Interfaces.C.Strings;
with System;

-- The C interface, declared in include/cpuload.h; Sample has the same layout as struct cpuload_sample
-- Ada programs should use CPU_Load directly
package CPU_Load.C_API is

    -- CPU_Load.Take: a sample of the whole system into Result
    procedure C_Take_System (Result : access Sample)
        with Export, Convention => C, External_Name => "cpuload_take_system";

    -- CPU_Load.Take (PID): a sample of the system and of that process
    -- Used is -1 if the process could not be read, or if PID is too large to be any process
    procedure C_Take_PID (PID : in Interfaces.C.unsigned; Result : access Sample)
        with Export, Convention => C, External_Name => "cpuload_take_pid";

    -- CPU_Load.Take (App): a sample of the system and of every process of that application
    -- App is a NUL terminated C string; NULL or "" samples the system alone
    procedure C_Take_App (App : in Interfaces.C.Strings.chars_ptr;
                          Result : access Sample)
        with Export, Convention => C, External_Name => "cpuload_take_app";

    -- The same two against a machine sample already taken (see CPU_Load)
    -- A NULL Machine is a total of 0: System_Usage gives 0.0, and so does Process_Usage unless the process could not be read
    procedure C_Take_PID_With (PID : in Interfaces.C.unsigned;
                               Machine : access constant Sample;
                               Result : access Sample)
        with Export, Convention => C, External_Name => "cpuload_take_pid_with";

    procedure C_Take_App_With (App : in Interfaces.C.Strings.chars_ptr;
                               Machine : access constant Sample;
                               Result : access Sample)
        with Export, Convention => C, External_Name => "cpuload_take_app_with";

    -- CPU_Load.System_Usage: load of the whole machine between two samples, 0.0 .. 1.0; a NULL pointer gives 0.0
    function C_System_Usage (Before, After : access constant Sample)
        return Interfaces.C.double
        with Export, Convention => C, External_Name => "cpuload_system_usage";

    -- CPU_Load.Process_Usage: load of the process or application, 0.0 .. 1.0, negative if it could not be read; a NULL pointer gives 0.0
    function C_Process_Usage (Before, After : access constant Sample)
        return Interfaces.C.double
        with Export, Convention => C, External_Name => "cpuload_process_usage";

    -- CPU_Load.Version as a C string owned by the library (do not free it)
    function C_Version return System.Address
        with Export, Convention => C, External_Name => "cpuload_version";

end CPU_Load.C_API;
