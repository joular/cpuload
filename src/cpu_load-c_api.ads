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

with Interfaces;
with Interfaces.C;
with Interfaces.C.Strings;
with System;

-- The C interface of the library, so it can be used from any language with a C FFI (C, C++, Java, Python, Rust, etc.)
-- The C declarations of these functions are in include/cpuload.h
-- Ada programs should use the CPU_Load package directly instead of this one
package CPU_Load.C_API is

    -- One sample in C, matches struct cpuload_sample in cpuload.h
    -- The counters are 64 bits whatever the machine, so the C side never has to guess how wide an Ada Long_Integer is
    type C_Sample is
        record
            Busy : Interfaces.Integer_64 := 0;
            Total : Interfaces.Integer_64 := 0;
            Used : Interfaces.Integer_64 := 0;
        end record
        with Convention => C;

    -- Three 64 bit counters and nothing else, exactly as cpuload.h declares it
    -- Were it ever padded out to more, every sample read from C would be nonsense
    pragma Compile_Time_Error
        (C_Sample'Size /= 192, "struct cpuload_sample must be exactly 24 bytes");

    -- Same as CPU_Load.Take: writes a sample of the whole system into Result
    procedure C_Take_System (Result : access C_Sample)
        with Export, Convention => C, External_Name => "cpuload_take_system";

    -- Same as CPU_Load.Take (PID): writes a sample of the system and of that one process
    -- Used comes back 0 if that process is not running
    procedure C_Take_PID (PID : in Interfaces.C.unsigned; Result : access C_Sample)
        with Export, Convention => C, External_Name => "cpuload_take_pid";

    -- Same as CPU_Load.Take (App): writes a sample of the system and of every process of that application
    -- App is a NUL terminated C string; NULL or "" samples the system alone
    procedure C_Take_App (App : in Interfaces.C.Strings.chars_ptr;
                          Result : access C_Sample)
        with Export, Convention => C, External_Name => "cpuload_take_app";

    -- Same as CPU_Load.System_Usage: how busy the machine was between the two samples, 0.0 .. 1.0
    -- A NULL pointer gives 0.0
    function C_System_Usage (Before, After : access constant C_Sample)
        return Interfaces.C.double
        with Export, Convention => C, External_Name => "cpuload_system_usage";

    -- Same as CPU_Load.Process_Usage: how much of the machine the process or application used, 0.0 .. 1.0
    function C_Process_Usage (Before, After : access constant C_Sample)
        return Interfaces.C.double
        with Export, Convention => C, External_Name => "cpuload_process_usage";

    -- Same as CPU_Load.Version: the version of the library, as a C string owned by the library (the caller must not free it)
    function C_Version return System.Address
        with Export, Convention => C, External_Name => "cpuload_version";

end CPU_Load.C_API;
