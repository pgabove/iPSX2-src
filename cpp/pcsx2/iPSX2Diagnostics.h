// SPDX-FileCopyrightText: 2002-2025 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

#pragma once

// [iPSX2 #16] Diagnostic switches, set at boot from Settings > Emulator > Diagnostics by
// VMManager::LoadSettings() (INI section "iPSX2/Debug"). Each one takes:
//   0 = JIT (normal)
//   1 = Interpreter
//   2 = Check: run both, log differences to the console log, keep the interpreter's result
extern int g_iPSX2_COP2MacroMode; // VU0 macro (COP2) ops - x86/microVU_Macro.inl
extern int g_iPSX2_VIFUnpackMode; // VIF unpacks         - Vif_Unpack.cpp, arm64/Vif_Dynarec.cpp
extern int g_iPSX2_FPUMode;       // EE FPU (COP1) ops    - x86/ix86-32/iR5900Templates.cpp
