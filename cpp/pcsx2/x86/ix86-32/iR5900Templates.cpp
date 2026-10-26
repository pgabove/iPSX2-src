// SPDX-FileCopyrightText: 2002-2025 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0+

#include "Common.h"
#include "Memory.h"
#include "R5900OpcodeTables.h"
#include "VU.h"
#include "VUmicro.h"
#include "vtlb.h"
#include "x86/iCOP0.h"
#include "x86/iFPU.h"
#include "x86/iMMI.h"
#include "x86/iR5900.h"
#include "iPSX2Diagnostics.h"

#include <cmath>
#include <cstring>

#if !defined(__ANDROID__)
using namespace x86Emitter;
#endif

////////////////////
// Code Templates //
////////////////////

void _eeOnWriteReg(int reg, int signext)
{
	GPR_DEL_CONST(reg);
}

void _deleteEEreg(int reg, int flush)
{
	if (!reg)
		return;
	if (flush && GPR_IS_CONST1(reg))
	{
		_flushConstReg(reg);
	}
	GPR_DEL_CONST(reg);
	_deleteGPRtoXMMreg(reg, flush ? DELETE_REG_FREE : DELETE_REG_FLUSH_AND_FREE);
	_deleteGPRtoX86reg(reg, flush ? DELETE_REG_FREE : DELETE_REG_FLUSH_AND_FREE);
}

void _deleteEEreg128(int reg)
{
	if (!reg)
		return;

	GPR_DEL_CONST(reg);
	_deleteGPRtoXMMreg(reg, DELETE_REG_FREE_NO_WRITEBACK);
	_deleteGPRtoX86reg(reg, DELETE_REG_FREE_NO_WRITEBACK);
}

void _flushEEreg(int reg, bool clear)
{
	if (!reg)
		return;

	if (GPR_IS_DIRTY_CONST(reg))
		_flushConstReg(reg);
	if (clear)
		GPR_DEL_CONST(reg);

	_deleteGPRtoXMMreg(reg, clear ? DELETE_REG_FLUSH_AND_FREE : DELETE_REG_FLUSH);
	_deleteGPRtoX86reg(reg, clear ? DELETE_REG_FLUSH_AND_FREE : DELETE_REG_FLUSH);
}

int _eeTryRenameReg(int to, int from, int fromx86, int other, int xmminfo)
{
	// can't rename when in form Rd = Rs op Rt and Rd == Rs or Rd == Rt
	if ((xmminfo & XMMINFO_NORENAME) || fromx86 < 0 || to == from || to == other || !EEINST_RENAMETEST(from))
		return -1;

	RALOG("Renaming %s to %s\n", R3000A::disRNameGPR[from], R3000A::disRNameGPR[to]);

	// flush back when it's been modified
	if (x86regs[fromx86].mode & MODE_WRITE && EEINST_LIVETEST(from))
		_writebackX86Reg(fromx86);

	// remove all references to renamed-to register
	_deleteGPRtoX86reg(to, DELETE_REG_FREE_NO_WRITEBACK);
	_deleteGPRtoXMMreg(to, DELETE_REG_FLUSH_AND_FREE);
	GPR_DEL_CONST(to);

	// and do the actual rename, new register has been modified.
	x86regs[fromx86].reg = to;
	x86regs[fromx86].mode |= MODE_READ | MODE_WRITE;
	return fromx86;
}


static bool FitsInImmediate(int reg, int fprinfo)
{
	if (fprinfo & XMMINFO_64BITOP)
		return (s32)g_cpuConstRegs[reg].SD[0] == g_cpuConstRegs[reg].SD[0];
	else
		return true; // all 32bit ops fit
}

void eeRecompileCodeRC0(R5900FNPTR constcode, R5900FNPTR_INFO constscode, R5900FNPTR_INFO consttcode, R5900FNPTR_INFO noconstcode, int xmminfo)
{
	if (!_Rd_ && (xmminfo & XMMINFO_WRITED))
		return;

	if (GPR_IS_CONST2(_Rs_, _Rt_))
	{
		if (_Rd_ && (xmminfo & XMMINFO_WRITED))
		{
			_deleteGPRtoX86reg(_Rd_, DELETE_REG_FREE_NO_WRITEBACK);
			_deleteGPRtoXMMreg(_Rd_, DELETE_REG_FLUSH_AND_FREE);
			GPR_SET_CONST(_Rd_);
		}
		constcode();
		return;
	}

	// this function should not be used for lo/hi.
	pxAssert(!(xmminfo & (XMMINFO_READLO | XMMINFO_READHI | XMMINFO_WRITELO | XMMINFO_WRITEHI)));

	// we have to put these up here, because the register allocator below will wipe out const flags
	// for the destination register when/if it switches it to write mode.
	const bool s_is_const = GPR_IS_CONST1(_Rs_);
	const bool t_is_const = GPR_IS_CONST1(_Rt_);
	const bool d_is_const = GPR_IS_CONST1(_Rd_);
	const bool s_is_used = EEINST_USEDTEST(_Rs_);
	const bool t_is_used = EEINST_USEDTEST(_Rt_);
	const bool s_in_xmm = _hasXMMreg(XMMTYPE_GPRREG, _Rs_);
	const bool t_in_xmm = _hasXMMreg(XMMTYPE_GPRREG, _Rt_);

	// regular x86
	if ((xmminfo & XMMINFO_READS) && !s_is_const)
		_addNeededGPRtoX86reg(_Rs_);
	if ((xmminfo & XMMINFO_READT) && !t_is_const)
		_addNeededGPRtoX86reg(_Rt_);
	if ((xmminfo & XMMINFO_READD) && !d_is_const)
		_addNeededGPRtoX86reg(_Rd_);

	// when it doesn't fit in an immediate, we'll flush it to a reg early to save code
	u32 info = 0;
	int regs = -1, regt = -1;
	if (xmminfo & XMMINFO_READS)
	{
		regs = _checkX86reg(X86TYPE_GPR, _Rs_, MODE_READ);
		if (regs < 0 && (!s_is_const || !FitsInImmediate(_Rs_, xmminfo)) && (s_is_used || s_in_xmm || ((xmminfo & XMMINFO_WRITED) && _Rd_ == _Rs_) || (xmminfo & XMMINFO_FORCEREGS)))
		{
			regs = _allocX86reg(X86TYPE_GPR, _Rs_, MODE_READ);
		}
		if (regs >= 0)
			info |= PROCESS_EE_SET_S(regs);
	}

	if (xmminfo & XMMINFO_READT)
	{
		regt = _checkX86reg(X86TYPE_GPR, _Rt_, MODE_READ);
		if (regt < 0 && (!t_is_const || !FitsInImmediate(_Rt_, xmminfo)) && (t_is_used || t_in_xmm || ((xmminfo & XMMINFO_WRITED) && _Rd_ == _Rt_) || (xmminfo & XMMINFO_FORCEREGT)))
		{
			regt = _allocX86reg(X86TYPE_GPR, _Rt_, MODE_READ);
		}
		if (regt >= 0)
			info |= PROCESS_EE_SET_T(regt);
	}

	if (xmminfo & (XMMINFO_WRITED | XMMINFO_READD))
	{
		// _eeTryRenameReg() sets READ | WRITE already, so this is only needed when allocating.
		const int moded = ((xmminfo & XMMINFO_WRITED) ? MODE_WRITE : 0) | ((xmminfo & XMMINFO_READD) ? MODE_READ : 0);

		// If S is no longer live, swap D for S. Saves the move.
		int regd = (_Rd_ && xmminfo & XMMINFO_WRITED) ? _eeTryRenameReg(_Rd_, (xmminfo & XMMINFO_READS) ? _Rs_ : 0, regs, (xmminfo & XMMINFO_READT) ? _Rt_ : 0, xmminfo) : 0;
		if (regd < 0)
			regd = _allocX86reg(X86TYPE_GPR, _Rd_, moded);

		pxAssert(regd >= 0);
		info |= PROCESS_EE_SET_D(regd);
	}

	if (xmminfo & XMMINFO_WRITED)
		GPR_DEL_CONST(_Rd_);

	_validateRegs();

	if (s_is_const && regs < 0)
	{
		constscode(info /*| PROCESS_CONSTS*/);
		return;
	}

	if (t_is_const && regt < 0)
	{
		consttcode(info /*| PROCESS_CONSTT*/);
		return;
	}

	noconstcode(info);
}

void eeRecompileCodeRC1(R5900FNPTR constcode, R5900FNPTR_INFO noconstcode, int xmminfo)
{
	pxAssert((xmminfo & (XMMINFO_READS | XMMINFO_WRITET)) == (XMMINFO_READS | XMMINFO_WRITET));

	if (!_Rt_)
		return;

	if (GPR_IS_CONST1(_Rs_))
	{
		_deleteGPRtoXMMreg(_Rt_, DELETE_REG_FLUSH_AND_FREE);
		_deleteGPRtoX86reg(_Rt_, DELETE_REG_FREE_NO_WRITEBACK);
		GPR_SET_CONST(_Rt_);
		constcode();
		return;
	}

	const bool s_is_used = EEINST_USEDTEST(_Rs_);
	const bool s_in_xmm = _hasXMMreg(XMMTYPE_GPRREG, _Rs_);

	u32 info = 0;
	int regs = _checkX86reg(X86TYPE_GPR, _Rs_, MODE_READ);
	if (regs < 0 && (s_is_used || s_in_xmm || _Rt_ == _Rs_ || (xmminfo & XMMINFO_FORCEREGS)))
		regs = _allocX86reg(X86TYPE_GPR, _Rs_, MODE_READ);
	if (regs >= 0)
		info |= PROCESS_EE_SET_S(regs);

	// If S is no longer live, swap D for S. Saves the move.
	int regt = _eeTryRenameReg(_Rt_, _Rs_, regs, 0, xmminfo);
	if (regt < 0)
		regt = _allocX86reg(X86TYPE_GPR, _Rt_, MODE_WRITE);

	info |= PROCESS_EE_SET_T(regt);
	_validateRegs();

	GPR_DEL_CONST(_Rt_);
	noconstcode(info);
}

// rd = rt op sa
void eeRecompileCodeRC2(R5900FNPTR constcode, R5900FNPTR_INFO noconstcode, int xmminfo)
{
	pxAssert((xmminfo & (XMMINFO_READT | XMMINFO_WRITED)) == (XMMINFO_READT | XMMINFO_WRITED));

	if (!_Rd_)
		return;

	if (GPR_IS_CONST1(_Rt_))
	{
		_deleteGPRtoXMMreg(_Rd_, DELETE_REG_FLUSH_AND_FREE);
		_deleteGPRtoX86reg(_Rd_, DELETE_REG_FREE_NO_WRITEBACK);
		GPR_SET_CONST(_Rd_);
		constcode();
		return;
	}

	const bool t_is_used = EEINST_USEDTEST(_Rt_);
	const bool t_in_xmm = _hasXMMreg(XMMTYPE_GPRREG, _Rt_);

	u32 info = 0;
	int regt = _checkX86reg(X86TYPE_GPR, _Rt_, MODE_READ);
	if (regt < 0 && (t_is_used || t_in_xmm || (_Rd_ == _Rt_) || (xmminfo & XMMINFO_FORCEREGT)))
		regt = _allocX86reg(X86TYPE_GPR, _Rt_, MODE_READ);
	if (regt >= 0)
		info |= PROCESS_EE_SET_T(regt);

	// If S is no longer live, swap D for T. Saves the move.
	int regd = _eeTryRenameReg(_Rd_, _Rt_, regt, 0, xmminfo);
	if (regd < 0)
		regd = _allocX86reg(X86TYPE_GPR, _Rd_, MODE_WRITE);

	info |= PROCESS_EE_SET_D(regd);
	_validateRegs();

	GPR_DEL_CONST(_Rd_);
	noconstcode(info);
}

// EE XMM allocation code
int eeRecompileCodeXMM(int xmminfo)
{
	int info = PROCESS_EE_XMM;

	// add needed
	if (xmminfo & (XMMINFO_READLO | XMMINFO_WRITELO))
		_addNeededGPRtoXMMreg(XMMGPR_LO);
	if (xmminfo & (XMMINFO_READHI | XMMINFO_WRITEHI))
		_addNeededGPRtoXMMreg(XMMGPR_HI);
	if (xmminfo & XMMINFO_READS)
		_addNeededGPRtoXMMreg(_Rs_);
	if (xmminfo & XMMINFO_READT)
		_addNeededGPRtoXMMreg(_Rt_);
	if (xmminfo & XMMINFO_WRITED)
		_addNeededGPRtoXMMreg(_Rd_);

	// TODO: we could do memory operands here if not live. but the MMI implementations aren't hooked up to that at the moment.
	if (xmminfo & XMMINFO_READS)
	{
		const int reg = _allocGPRtoXMMreg(_Rs_, MODE_READ);
		info |= PROCESS_EE_SET_S(reg);
	}
	if (xmminfo & XMMINFO_READT)
	{
		const int reg = _allocGPRtoXMMreg(_Rt_, MODE_READ);
		info |= PROCESS_EE_SET_T(reg);
	}

	if (xmminfo & XMMINFO_WRITED)
	{
		int readd = MODE_WRITE | ((xmminfo & XMMINFO_READD) ? MODE_READ : 0);

		int regd = _checkXMMreg(XMMTYPE_GPRREG, _Rd_, readd);

		if (regd < 0)
		{
			if (!(xmminfo & XMMINFO_READD) && (xmminfo & XMMINFO_READT) && EEINST_RENAMETEST(_Rt_))
			{
				_deleteEEreg128(_Rd_);
				_reallocateXMMreg(EEREC_T, XMMTYPE_GPRREG, _Rd_, readd, EEINST_LIVETEST(_Rt_));
				regd = EEREC_T;
			}
			else if (!(xmminfo & XMMINFO_READD) && (xmminfo & XMMINFO_READS) && EEINST_RENAMETEST(_Rs_))
			{
				_deleteEEreg128(_Rd_);
				_reallocateXMMreg(EEREC_S, XMMTYPE_GPRREG, _Rd_, readd, EEINST_LIVETEST(_Rs_));
				regd = EEREC_S;
			}
			else
			{
				regd = _allocGPRtoXMMreg(_Rd_, readd);
			}
		}

		info |= PROCESS_EE_SET_D(regd);
	}
	if (xmminfo & (XMMINFO_READLO | XMMINFO_WRITELO))
	{
		info |= PROCESS_EE_SET_LO(_allocGPRtoXMMreg(XMMGPR_LO, ((xmminfo & XMMINFO_READLO) ? MODE_READ : 0) | ((xmminfo & XMMINFO_WRITELO) ? MODE_WRITE : 0)));
	}
	if (xmminfo & (XMMINFO_READHI | XMMINFO_WRITEHI))
	{
		info |= PROCESS_EE_SET_HI(_allocGPRtoXMMreg(XMMGPR_HI, ((xmminfo & XMMINFO_READHI) ? MODE_READ : 0) | ((xmminfo & XMMINFO_WRITEHI) ? MODE_WRITE : 0)));
	}

	if (xmminfo & XMMINFO_WRITED)
		GPR_DEL_CONST(_Rd_);

	_validateRegs();
	return info;
}

// EE COP1(FPU) XMM allocation code
#define _Ft_ _Rt_
#define _Fs_ _Rd_
#define _Fd_ _Sa_

// rd = rs op rt
static void eeFPURecompileCodeImpl(R5900FNPTR_INFO xmmcode, R5900FNPTR fpucode, int xmminfo)
{
	int mmregs = -1, mmregt = -1, mmregd = -1, mmregacc = -1;
	int info = PROCESS_EE_XMM;

	if (xmminfo & XMMINFO_READS)
		_addNeededFPtoXMMreg(_Fs_);
	if (xmminfo & XMMINFO_READT)
		_addNeededFPtoXMMreg(_Ft_);
	if (xmminfo & (XMMINFO_WRITED | XMMINFO_READD))
		_addNeededFPtoXMMreg(_Fd_);
	if (xmminfo & (XMMINFO_WRITEACC | XMMINFO_READACC))
		_addNeededFPACCtoXMMreg();

	if (xmminfo & XMMINFO_READT)
	{
		if (g_pCurInstInfo->fpuregs[_Ft_] & EEINST_LASTUSE)
			mmregt = _checkXMMreg(XMMTYPE_FPREG, _Ft_, MODE_READ);
		else
			mmregt = _allocFPtoXMMreg(_Ft_, MODE_READ);
	}

	if (xmminfo & XMMINFO_READS)
	{
		if ((!(xmminfo & XMMINFO_READT) || (mmregt >= 0)) && (g_pCurInstInfo->fpuregs[_Fs_] & EEINST_LASTUSE))
		{
			mmregs = _checkXMMreg(XMMTYPE_FPREG, _Fs_, MODE_READ);
		}
		else
		{
			mmregs = _allocFPtoXMMreg(_Fs_, MODE_READ);

			// if we just allocated S and Fs == Ft, share it
			if ((xmminfo & XMMINFO_READT) && _Fs_ == _Ft_)
				mmregt = mmregs;
		}
	}

	if (xmminfo & XMMINFO_READD)
	{
		pxAssert(xmminfo & XMMINFO_WRITED);
		mmregd = _allocFPtoXMMreg(_Fd_, MODE_READ);
	}

	if (xmminfo & XMMINFO_READACC)
	{
		if (!(xmminfo & XMMINFO_WRITEACC) && (g_pCurInstInfo->fpuregs[XMMFPU_ACC] & EEINST_LASTUSE))
			mmregacc = _checkXMMreg(XMMTYPE_FPACC, 0, MODE_READ);
		else
			mmregacc = _allocFPACCtoXMMreg(MODE_READ);
	}

	if (xmminfo & XMMINFO_WRITEACC)
	{

		// check for last used, if so don't alloc a new XMM reg
		int readacc = MODE_WRITE | ((xmminfo & XMMINFO_READACC) ? MODE_READ : 0);

		mmregacc = _checkXMMreg(XMMTYPE_FPACC, 0, readacc);

		if (mmregacc < 0)
		{
			if ((xmminfo & XMMINFO_READT) && mmregt >= 0 && FPUINST_RENAMETEST(_Ft_))
			{
				if (EE_WRITE_DEAD_VALUES && xmmregs[mmregt].mode & MODE_WRITE)
					_writebackXMMreg(mmregt);

				xmmregs[mmregt].reg = 0;
				xmmregs[mmregt].mode = readacc;
				xmmregs[mmregt].type = XMMTYPE_FPACC;
				mmregacc = mmregt;
			}
			else if ((xmminfo & XMMINFO_READS) && mmregs >= 0 && FPUINST_RENAMETEST(_Fs_))
			{
				if (EE_WRITE_DEAD_VALUES && xmmregs[mmregs].mode & MODE_WRITE)
					_writebackXMMreg(mmregs);

				xmmregs[mmregs].reg = 0;
				xmmregs[mmregs].mode = readacc;
				xmmregs[mmregs].type = XMMTYPE_FPACC;
				mmregacc = mmregs;
			}
			else
				mmregacc = _allocFPACCtoXMMreg(readacc);
		}

		xmmregs[mmregacc].mode |= MODE_WRITE;
	}
	else if (xmminfo & XMMINFO_WRITED)
	{
		// check for last used, if so don't alloc a new XMM reg
		int readd = MODE_WRITE | ((xmminfo & XMMINFO_READD) ? MODE_READ : 0);
		if (xmminfo & XMMINFO_READD)
			mmregd = _allocFPtoXMMreg(_Fd_, readd);
		else
			mmregd = _checkXMMreg(XMMTYPE_FPREG, _Fd_, readd);

		if (mmregd < 0)
		{
			if ((xmminfo & XMMINFO_READT) && mmregt >= 0 && FPUINST_RENAMETEST(_Ft_))
			{
				if (EE_WRITE_DEAD_VALUES && xmmregs[mmregt].mode & MODE_WRITE)
					_writebackXMMreg(mmregt);

				xmmregs[mmregt].reg = _Fd_;
				xmmregs[mmregt].mode = readd;
				mmregd = mmregt;
			}
			else if ((xmminfo & XMMINFO_READS) && mmregs >= 0 && FPUINST_RENAMETEST(_Fs_))
			{
				if (EE_WRITE_DEAD_VALUES && xmmregs[mmregs].mode & MODE_WRITE)
					_writebackXMMreg(mmregs);

				xmmregs[mmregs].inuse = 1;
				xmmregs[mmregs].reg = _Fd_;
				xmmregs[mmregs].mode = readd;
				mmregd = mmregs;
			}
			else if ((xmminfo & XMMINFO_READACC) && mmregacc >= 0 && FPUINST_RENAMETEST(XMMFPU_ACC))
			{
				if (EE_WRITE_DEAD_VALUES && xmmregs[mmregacc].mode & MODE_WRITE)
					_writebackXMMreg(mmregacc);

				xmmregs[mmregacc].reg = _Fd_;
				xmmregs[mmregacc].mode = readd;
				xmmregs[mmregacc].type = XMMTYPE_FPREG;
				mmregd = mmregacc;
			}
			else
				mmregd = _allocFPtoXMMreg(_Fd_, readd);
		}
	}

	pxAssert(mmregs >= 0 || mmregt >= 0 || mmregd >= 0 || mmregacc >= 0);

	if (xmminfo & XMMINFO_WRITED)
	{
		pxAssert(mmregd >= 0);
		info |= PROCESS_EE_SET_D(mmregd);
	}
	if (xmminfo & (XMMINFO_WRITEACC | XMMINFO_READACC))
	{
		if (mmregacc >= 0)
			info |= PROCESS_EE_SET_ACC(mmregacc) | PROCESS_EE_ACC;
		else
			pxAssert(!(xmminfo & XMMINFO_WRITEACC));
	}

	if (xmminfo & XMMINFO_READS)
	{
		if (mmregs >= 0)
			info |= PROCESS_EE_SET_S(mmregs);
	}
	if (xmminfo & XMMINFO_READT)
	{
		if (mmregt >= 0)
			info |= PROCESS_EE_SET_T(mmregt);
	}

	// at least one must be in xmm
	if ((xmminfo & (XMMINFO_READS | XMMINFO_READT)) == (XMMINFO_READS | XMMINFO_READT))
	{
		pxAssert(mmregs >= 0 || mmregt >= 0);
	}

	xmmcode(info);
}

//------------------------------------------------------------------
// [iPSX2 #16] EE FPU diagnostics (Settings > Emulator > Diagnostics > "EE FPU")
//------------------------------------------------------------------
// g_iPSX2_FPUMode: 0 = JIT, 1 = Interpreter (FPU arithmetic ops call their interpreter functions),
// 2 = Check (run the recompiled op, rerun it on the interpreter from the same state, log
// @@FPU_CHECK@@ differences, keep the interpreter's result). Covers every op that goes through
// eeFPURecompileCode (add/sub/mul/div/sqrt/rsqrt/madd/msub/min/max/abs/neg/mov/compares/cvt.s).
int g_iPSX2_FPUMode = 0;

namespace
{
	struct FPUCheckStat
	{
		u32 funct;
		u64 checks;
		u64 mismatches;
	};
} // namespace

static fpuRegisters s_fpu_before;
static fpuRegisters s_fpu_jit;
static FPUCheckStat s_fpu_stats[64];
static u64 s_fpu_checks = 0;
static u64 s_fpu_mismatches = 0;
static u64 s_fpu_next_report = 1u << 16;
static u32 s_fpu_logged = 0;

static bool iPSX2_FPUFloatClose(u32 a, u32 b)
{
	if (a == b)
		return true;
	const u32 ea = (a >> 23) & 0xff;
	const u32 eb = (b >> 23) & 0xff;
	if (ea == 0 && eb == 0)
		return true;
	const bool same_sign = ((a ^ b) & 0x80000000u) == 0;
	if (ea >= 0xfe && eb >= 0xfe)
		return same_sign;
	if (ea == 0xff || eb == 0xff)
		return false;
	if (same_sign)
	{
		const s64 ulps = static_cast<s64>(a & 0x7fffffffu) - static_cast<s64>(b & 0x7fffffffu);
		if (ulps >= -4 && ulps <= 4)
			return true;
	}
	float fa, fb;
	std::memcpy(&fa, &a, sizeof(fa));
	std::memcpy(&fb, &b, sizeof(fb));
	const float scale = std::max(1.0f, std::max(std::fabs(fa), std::fabs(fb)));
	return std::fabs(fa - fb) <= scale * (1.0f / 65536.0f);
}

static void iPSX2_FPUCheckSnapshot()
{
	s_fpu_before = fpuRegs;
}

static void iPSX2_FPUCheckReport()
{
	Console.WriteLn("@@FPU_CHECK@@ summary: %llu FPU ops checked, %llu mismatched",
		static_cast<unsigned long long>(s_fpu_checks), static_cast<unsigned long long>(s_fpu_mismatches));
	char line[256];
	size_t used = 0;
	line[0] = 0;
	for (u32 i = 0; i < 64; i++)
	{
		const FPUCheckStat& st = s_fpu_stats[i];
		if (!st.checks)
			continue;
		char item[64];
		if (st.mismatches)
			std::snprintf(item, sizeof(item), " f%02u=%llu(BAD %llu)", i, static_cast<unsigned long long>(st.checks),
				static_cast<unsigned long long>(st.mismatches));
		else
			std::snprintf(item, sizeof(item), " f%02u=%llu", i, static_cast<unsigned long long>(st.checks));
		const size_t len = std::strlen(item);
		if (used + len >= sizeof(line))
		{
			Console.WriteLn("@@FPU_CHECK@@ %s", line);
			used = 0;
			line[0] = 0;
		}
		std::memcpy(line + used, item, len + 1);
		used += len;
	}
	if (used)
		Console.WriteLn("@@FPU_CHECK@@ %s (fNN = COP1 function code, see R5900 FPU table)", line);
}

static void iPSX2_FPUCheckCompare(u32 code, R5900FNPTR interp, u32 pc)
{
	// Keep what the recompiled code produced, then rerun the op on the interpreter from the same state.
	s_fpu_jit = fpuRegs;
	fpuRegs = s_fpu_before;
	const u32 saved_code = cpuRegs.code;
	cpuRegs.code = code;
	interp();
	cpuRegs.code = saved_code;

	FPUCheckStat& stat = s_fpu_stats[code & 0x3f];
	stat.funct = code & 0x3f;
	stat.checks++;
	s_fpu_checks++;

	int diffs = 0;
	int first = -2; // register index, -1 = ACC, 32 = condition bit
	for (int r = 0; r < 32; r++)
	{
		if (!iPSX2_FPUFloatClose(s_fpu_jit.fpr[r].UL, fpuRegs.fpr[r].UL))
		{
			if (diffs++ == 0)
				first = r;
		}
	}
	if (!iPSX2_FPUFloatClose(s_fpu_jit.ACC.UL, fpuRegs.ACC.UL))
	{
		if (diffs++ == 0)
			first = -1;
	}
	// Only the condition bit (C) of FCR31 is compared: the recompiler doesn't track O/U like the interpreter.
	if ((s_fpu_jit.fprc[31] ^ fpuRegs.fprc[31]) & 0x00800000u)
	{
		if (diffs++ == 0)
			first = 32;
	}

	if (diffs != 0)
	{
		stat.mismatches++;
		s_fpu_mismatches++;
		if (s_fpu_logged < 60)
		{
			s_fpu_logged++;
			std::string disasm;
			R5900::disR5900Fasm(disasm, code, pc, false);
			const u32 fs = (code >> 11) & 0x1f;
			const u32 ft = (code >> 16) & 0x1f;
			Console.WriteLn("@@FPU_CHECK@@ MISMATCH #%u pc=%08X %08X %s (%d differ)", s_fpu_logged, pc, code, disasm.c_str(), diffs);
			Console.WriteLn("@@FPU_CHECK@@   in fs=f%02u %08X (%g) ft=f%02u %08X (%g) acc=%08X (%g) fcr31=%08X", fs,
				s_fpu_before.fpr[fs].UL, s_fpu_before.fpr[fs].f, ft, s_fpu_before.fpr[ft].UL, s_fpu_before.fpr[ft].f,
				s_fpu_before.ACC.UL, s_fpu_before.ACC.f, s_fpu_before.fprc[31]);
			if (first >= 0 && first < 32)
				Console.WriteLn("@@FPU_CHECK@@   f%02d jit=%08X (%g) interp=%08X (%g)", first, s_fpu_jit.fpr[first].UL,
					s_fpu_jit.fpr[first].f, fpuRegs.fpr[first].UL, fpuRegs.fpr[first].f);
			else if (first == -1)
				Console.WriteLn("@@FPU_CHECK@@   acc jit=%08X (%g) interp=%08X (%g)", s_fpu_jit.ACC.UL, s_fpu_jit.ACC.f,
					fpuRegs.ACC.UL, fpuRegs.ACC.f);
			else
				Console.WriteLn("@@FPU_CHECK@@   fcr31 jit=%08X interp=%08X", s_fpu_jit.fprc[31], fpuRegs.fprc[31]);
		}
	}

	// The interpreter's result stays in fpuRegs.

	if (s_fpu_checks >= s_fpu_next_report)
	{
		iPSX2_FPUCheckReport();
		s_fpu_next_report = (s_fpu_next_report < (1u << 22)) ? (s_fpu_next_report << 2) : (s_fpu_next_report + (1u << 22));
	}
}

void eeFPURecompileCode(R5900FNPTR_INFO xmmcode, R5900FNPTR fpucode, int xmminfo)
{
	if (g_iPSX2_FPUMode == 1)
	{
		recCall(fpucode);
		return;
	}
	if (g_iPSX2_FPUMode == 2)
	{
		// Inputs in memory and nothing cached across the op, then compare its results.
		iFlushCall(FLUSH_FREE_XMM);
		armEmitCall(reinterpret_cast<const void*>(iPSX2_FPUCheckSnapshot));
		eeFPURecompileCodeImpl(xmmcode, fpucode, xmminfo);
		iFlushCall(FLUSH_FREE_XMM);
		armAsm->Mov(a64::w0, static_cast<u32>(cpuRegs.code));
		armMoveAddressToReg(a64::x1, reinterpret_cast<const void*>(fpucode));
		armAsm->Mov(a64::w2, g_recompilingDelaySlot ? pc : (pc - 4));
		armEmitCall(reinterpret_cast<const void*>(iPSX2_FPUCheckCompare));
		return;
	}
	eeFPURecompileCodeImpl(xmmcode, fpucode, xmminfo);
}
