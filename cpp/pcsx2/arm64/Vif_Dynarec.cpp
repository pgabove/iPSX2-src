// SPDX-FileCopyrightText: 2002-2025 PCSX2 Dev Team
// SPDX-License-Identifier: GPL-3.0

#include "arm64/Vif_UnpackNEON.h"
#include "MTVU.h"

#include "common/Assertions.h"
#include "common/Perf.h"
#include "common/StringUtil.h"

#include "iPSX2Diagnostics.h"

#include <cstring>

namespace a64 = vixl::aarch64;

static void mVUmergeRegs(const vixl::aarch64::VRegister& dest, const vixl::aarch64::VRegister& src, int xyzw, bool modXYZW = false, bool canModifySrc = false)
{
	xyzw &= 0xf;
	if ((dest.GetCode() != src.GetCode()) && (xyzw != 0))
	{
		if (xyzw == 0x8)
			armAsm->Mov(dest.V4S(), 0, src.V4S(), 0);
		else if (xyzw == 0xf)
			armAsm->Mov(dest.Q(), src.Q());
		else
		{
			if (modXYZW)
			{
				if (xyzw == 1)
				{
					armAsm->Ins(dest.V4S(), 3, src.V4S(), 0);
					return;
				}
				else if (xyzw == 2)
				{
					armAsm->Ins(dest.V4S(), 2, src.V4S(), 0);
					return;
				}
				else if (xyzw == 4)
				{
					armAsm->Ins(dest.V4S(), 1, src.V4S(), 0);
					return;
				}
			}

			if (xyzw == 0)
				return;
			if (xyzw == 15)
			{
				armAsm->Mov(dest, src);
				return;
			}
			if (xyzw == 14 && canModifySrc)
			{
				// xyz - we can get rid of the mov if we swap the RA around
				armAsm->Mov(src.V4S(), 3, dest.V4S(), 3);
				armAsm->Mov(dest.V16B(), src.V16B());
				return;
			}

			// reverse
			xyzw = ((xyzw & 1) << 3) | ((xyzw & 2) << 1) | ((xyzw & 4) >> 1) | ((xyzw & 8) >> 3);

			if ((xyzw & 3) == 3)
			{
				// xy
				armAsm->Mov(dest.V2D(), 0, src.V2D(), 0);
				xyzw &= ~3;
			}
			else if ((xyzw & 12) == 12)
			{
				// zw
				armAsm->Mov(dest.V2D(), 1, src.V2D(), 1);
				xyzw &= ~12;
			}

			// xyzw
			for (u32 i = 0; i < 4; i++)
			{
				if (xyzw & (1u << i))
					armAsm->Mov(dest.V4S(), i, src.V4S(), i);
			}
		}
	}
}

static void maskedVecWrite(const a64::VRegister& reg, const a64::MemOperand& addr, int xyzw)
{
	switch (xyzw)
	{
		case 5: // YW
			armGetMemOperandInRegister(RSCRATCHADDR, addr, 4);
			armAsm->St1(reg.V4S(), 1, a64::MemOperand(RSCRATCHADDR)); // Y
			armGetMemOperandInRegister(RSCRATCHADDR, addr, 12);
			armAsm->St1(reg.V4S(), 3, a64::MemOperand(RSCRATCHADDR)); // W
			break;

		case 9: // XW
			armGetMemOperandInRegister(RSCRATCHADDR, addr, 12);
			armAsm->Str(reg.S(), addr); // X
			armAsm->St1(reg.V4S(), 3, a64::MemOperand(RSCRATCHADDR)); // W
			break;

		case 10: //XZ
			armGetMemOperandInRegister(RSCRATCHADDR, addr, 8);
			armAsm->Str(reg.S(), addr); // X
			armAsm->St1(reg.V4S(), 2, a64::MemOperand(RSCRATCHADDR)); // Z
			break;

		case 3: // ZW
			armGetMemOperandInRegister(RSCRATCHADDR, addr, 8);
			armAsm->St1(reg.V2D(), 1, a64::MemOperand(RSCRATCHADDR));
			break;

		case 11: //XZW
			armGetMemOperandInRegister(RSCRATCHADDR, addr, 8);
			armAsm->Str(reg.S(), addr); // X
			armAsm->St1(reg.V2D(), 1, a64::MemOperand(RSCRATCHADDR)); // ZW
			break;

		case 13: // XYW
			armGetMemOperandInRegister(RSCRATCHADDR, addr, 12);
			armAsm->Str(reg.D(), addr);
			armAsm->St1(reg.V4S(), 3, a64::MemOperand(RSCRATCHADDR));
			break;

		case 6: // YZ
			armGetMemOperandInRegister(RSCRATCHADDR, addr, 4);
			armAsm->St1(reg.V4S(), 1, a64::MemOperand(RSCRATCHADDR, 4, a64::PostIndex));
			armAsm->St1(reg.V4S(), 2, a64::MemOperand(RSCRATCHADDR));
			break;

		case 7: // YZW
			armGetMemOperandInRegister(RSCRATCHADDR, addr, 4);
			armAsm->St1(reg.V4S(), 1, a64::MemOperand(RSCRATCHADDR, 4, a64::PostIndex));
			armAsm->St1(reg.V2D(), 1, a64::MemOperand(RSCRATCHADDR));
			break;

		case 12: // XY
			armAsm->Str(reg.D(), addr);
			break;

		case 14: // XYZ
			armGetMemOperandInRegister(RSCRATCHADDR, addr, 8);
			armAsm->Str(reg.D(), addr);
			armAsm->St1(reg.V4S(), 2, a64::MemOperand(RSCRATCHADDR)); // Z
			break;

		case 4:
			armGetMemOperandInRegister(RSCRATCHADDR, addr, 4);
			armAsm->St1(reg.V4S(), 1, a64::MemOperand(RSCRATCHADDR));
			break; // Y
		case 2:
			armGetMemOperandInRegister(RSCRATCHADDR, addr, 8);
			armAsm->St1(reg.V4S(), 2, a64::MemOperand(RSCRATCHADDR));
			break; // Z
		case 1:
			armGetMemOperandInRegister(RSCRATCHADDR, addr, 12);
			armAsm->St1(reg.V4S(), 3, a64::MemOperand(RSCRATCHADDR));
			break; // W
		case 8:
			armAsm->Str(reg.S(), addr);
			break; // X

		case 0:
			Console.Error("maskedVecWrite case 0!");
			break;

		default:
			armAsm->Str(reg.Q(), addr);
			break; // XYZW
	}
}

void dVifReset(int idx)
{
	nVif[idx].vifBlocks.reset();

	const size_t offset = idx ? HostMemoryMap::VIF1recOffset : HostMemoryMap::VIF0recOffset;
	const size_t size = idx ? HostMemoryMap::VIF1recSize : HostMemoryMap::VIF0recSize;
	nVif[idx].recWritePtr = SysMemory::GetCodePtr(offset);
	nVif[idx].recEndPtr = nVif[idx].recWritePtr + (size - _256kb);
}

void dVifRelease(int idx)
{
	nVif[idx].vifBlocks.clear();
}

VifUnpackNEON_Dynarec::VifUnpackNEON_Dynarec(const nVifStruct& vif_, const nVifBlock& vifBlock_)
	: v(vif_)
	, vB(vifBlock_)
{
	const int wl = vB.wl ? vB.wl : 256; //0 is taken as 256 (KH2)
	isFill = (vB.cl < wl);
	usn = (vB.upkType >> 5) & 1;
	doMask = (vB.upkType >> 4) & 1;
	doMode = vB.mode & 3;
	IsAligned = vB.aligned;
	vCL = 0;
}

__fi void makeMergeMask(u32& x)
{
	x = ((x & 0x40) >> 6) | ((x & 0x10) >> 3) | (x & 4) | ((x & 1) << 3);
}

__fi void VifUnpackNEON_Dynarec::SetMasks(int cS) const
{
	const int idx = v.idx;
	const vifStruct& vif = MTVU_VifX;

	//This could have ended up copying the row when there was no row to write.1810080
	u32 m0 = vB.mask; //The actual mask example 0x03020100
	u32 m3 = ((m0 & 0xaaaaaaaa) >> 1) & ~m0; //all the upper bits, so our example 0x01010000 & 0xFCFDFEFF = 0x00010000 just the cols (shifted right for maskmerge)
	u32 m2 = (m0 & 0x55555555) & (~m0 >> 1); // 0x1000100 & 0xFE7EFF7F = 0x00000100 Just the row

	if ((doMask && m2) || doMode)
	{
		armLoadPtr(xmmRow, &vif.MaskRow);
		MSKPATH3_LOG("Moving row");
	}
	if (doMask && m3)
	{
		VIF_LOG("Merging Cols");
		armLoadPtr(xmmCol0, &vif.MaskCol);
		if ((cS >= 2) && (m3 & 0x0000ff00))
			armAsm->Dup(xmmCol1.V4S(), xmmCol0.V4S(), 1);
		if ((cS >= 3) && (m3 & 0x00ff0000))
			armAsm->Dup(xmmCol2.V4S(), xmmCol0.V4S(), 2);
		if ((cS >= 4) && (m3 & 0xff000000))
			armAsm->Dup(xmmCol3.V4S(), xmmCol0.V4S(), 3);
		if ((cS >= 1) && (m3 & 0x000000ff))
			armAsm->Dup(xmmCol0.V4S(), xmmCol0.V4S(), 0);
	}
	//if (doMask||doMode) loadRowCol((nVifStruct&)v);
}

void VifUnpackNEON_Dynarec::doMaskWrite(const vixl::aarch64::VRegister& regX) const
{
	pxAssertMsg(regX.GetCode() <= 1, "Reg Overflow! XMM2 thru XMM6 are reserved for masking.");

	const int cc = std::min(vCL, 3);
	u32 m0 = (vB.mask >> (cc * 8)) & 0xff; //The actual mask example 0xE4 (protect, col, row, clear)
	u32 m3 = ((m0 & 0xaa) >> 1) & ~m0; //all the upper bits (cols shifted right) cancelling out any write protects 0x10
	u32 m2 = (m0 & 0x55) & (~m0 >> 1); // all the lower bits (rows)cancelling out any write protects 0x04
	u32 m4 = (m0 & ~((m3 << 1) | m2)) & 0x55; //  = 0xC0 & 0x55 = 0x40 (for merge mask)

	makeMergeMask(m2);
	makeMergeMask(m3);
	makeMergeMask(m4);

	if (doMask && m2) // Merge MaskRow
	{
		mVUmergeRegs(regX, xmmRow, m2);
	}

	if (doMask && m3) // Merge MaskCol
	{
		mVUmergeRegs(regX, armQRegister(xmmCol0.GetCode() + cc), m3);
	}

	if (doMode)
	{
		u32 m5 = ~(m2 | m3 | m4) & 0xf;

		if (!doMask)
			m5 = 0xf;

		if (m5 < 0xf)
		{
			armAsm->Movi(xmmTemp.V4S(), 0);
			if (doMode == 3)
			{
				mVUmergeRegs(xmmRow, regX, m5, false, false);
			}
			else
			{
				mVUmergeRegs(xmmTemp, xmmRow, m5, false, false);
				armAsm->Add(regX.V4S(), regX.V4S(), xmmTemp.V4S());
				if (doMode == 2)
					mVUmergeRegs(xmmRow, regX, m5, false, false);
			}
		}
		else
		{
			if (doMode == 3)
			{
				armAsm->Mov(xmmRow, regX);
			}
			else
			{
				armAsm->Add(regX.V4S(), regX.V4S(), xmmRow.V4S());
				if (doMode == 2)
				{
					armAsm->Mov(xmmRow, regX);
				}
			}
		}
	}

	if (doMask && m4)
		maskedVecWrite(regX, dstIndirect, m4 ^ 0xf);
	else
		armAsm->Str(regX, dstIndirect);
}

void VifUnpackNEON_Dynarec::writeBackRow() const
{
	const int idx = v.idx;
	armStorePtr(xmmRow, &(MTVU_VifX.MaskRow));

	VIF_LOG("nVif: writing back row reg! [doMode = %d]", doMode);
}

void VifUnpackNEON_Dynarec::ModUnpack(int upknum, bool PostOp)
{
	switch (upknum)
	{
		case 0:
		case 1:
		case 2:
			if (PostOp)
			{
				UnpkLoopIteration++;
				UnpkLoopIteration = UnpkLoopIteration & 0x3;
			}
			break;

		case 4:
		case 5:
		case 6:
			if (PostOp)
			{
				UnpkLoopIteration++;
				UnpkLoopIteration = UnpkLoopIteration & 0x1;
			}
			break;

		case 8:
			if (PostOp)
			{
				UnpkLoopIteration++;
				UnpkLoopIteration = UnpkLoopIteration & 0x1;
			}
			break;
		case 9:
			if (!PostOp)
			{
				UnpkLoopIteration++;
			}
			break;
		case 10:
			if (!PostOp)
			{
				UnpkLoopIteration++;
			}
			break;

		case 12:
			break;
		case 13:
			break;
		case 14:
			break;
		case 15:
			break;

		case 3:
		case 7:
		case 11:
			// TODO: Needs hardware testing.
			// Dynasty Warriors 5: Empire  - Player 2 chose a character menu.
			Console.Warning("Vpu/Vif: Invalid Unpack %d", upknum);
			break;
	}
}

void VifUnpackNEON_Dynarec::ProcessMasks()
{
	skipProcessing = false;
	inputMasked = false;

	if (!doMask)
		return;

	const int cc = std::min(vCL, 3);
	const u32 full_mask = (vB.mask >> (cc * 8)) & 0xff;
	const u32 rowcol_mask = ((full_mask >> 1) | full_mask) & 0x55; // Rows or Cols being written instead of data, or protected.

	// Every channel is write protected for this cycle, no need to process anything.
	skipProcessing = full_mask == 0xff;

	// All channels are masked, no reason to process anything here.
	inputMasked = rowcol_mask == 0x55;
}

void VifUnpackNEON_Dynarec::CompileRoutine()
{
	const int wl = vB.wl ? vB.wl : 256; //0 is taken as 256 (KH2)
	const int upkNum = vB.upkType & 0xf;
	const u8& vift = nVifT[upkNum];
	const int cycleSize = isFill ? vB.cl : wl;
	const int blockSize = isFill ? wl : vB.cl;
	const int skipSize = blockSize - cycleSize;

	uint vNum = vB.num ? vB.num : 256;
	doMode = (upkNum == 0xf) ? 0 : doMode; // V4_5 has no mode feature.
	UnpkNoOfIterations = 0;
	VIF_LOG("Compiling new block, unpack number %x, mode %x, masking %x, vNum %x", upkNum, doMode, doMask, vNum);

	pxAssume(vCL == 0);

	// Value passed determines # of col regs we need to load
	SetMasks(isFill ? blockSize : cycleSize);

	while (vNum)
	{
		// Determine if reads/processing can be skipped.
		ProcessMasks();

		if (vCL < cycleSize)
		{
			ModUnpack(upkNum, false);
			xUnpack(upkNum);
			xMovDest();
			ModUnpack(upkNum, true);

			dstIndirect = armOffsetMemOperand(dstIndirect, 16);
			srcIndirect = armOffsetMemOperand(srcIndirect, vift);

			vNum--;
			if (++vCL == blockSize)
				vCL = 0;
		}
		else if (isFill)
		{
			xUnpack(upkNum);
			xMovDest();

			// dstIndirect += 16;
			dstIndirect = armOffsetMemOperand(dstIndirect, 16);

			vNum--;
			if (++vCL == blockSize)
				vCL = 0;
		}
		else
		{
			// dstIndirect += (16 * skipSize);
			dstIndirect = armOffsetMemOperand(dstIndirect, 16 * skipSize);
			vCL = 0;
		}
	}

	if (doMode >= 2)
		writeBackRow();

	armAsm->Ret();
}

static u16 dVifComputeLength(uint cl, uint wl, u8 num, bool isFill)
{
	uint length = (num > 0) ? (num * 16) : 4096; // 0 = 256

	if (!isFill)
	{
		uint skipSize = (cl - wl) * 16;
		uint blocks = (num + (wl - 1)) / wl; //Need to round up num's to calculate skip size correctly.
		length += (blocks - 1) * skipSize;
	}

	return std::min(length, 0xFFFFu);
}

_vifT __fi nVifBlock* dVifCompile(nVifBlock& block, bool isFill)
{
	nVifStruct& v = nVif[idx];

	// Check size before the compilation
	if (v.recWritePtr >= v.recEndPtr)
	{
		DevCon.WriteLn("nVif Recompiler Cache Reset! [0x%016" PRIXPTR " > 0x%016" PRIXPTR "]",
			v.recWritePtr, v.recEndPtr);
		dVifReset(idx);
	}

	// Compile the block now
	armSetAsmPtr(v.recWritePtr, v.recEndPtr - v.recWritePtr, nullptr);

	block.startPtr = (uptr)armStartBlock();
	block.length = dVifComputeLength(block.cl, block.wl, block.num, isFill);
	v.vifBlocks.add(block);

	VifUnpackNEON_Dynarec(v, block).CompileRoutine();

	Perf::vif.RegisterPC(v.recWritePtr, armGetCurrentCodePointer() - v.recWritePtr, block.upkType /* FIXME ideally a key*/);
	v.recWritePtr = armEndBlock();

	return &block;
}

// ----------------------------------------------------------------------------
// [iPSX2 #16] VIF unpack check (Settings > Emulator > Diagnostics > "VIF Unpacks" = Check)
// ----------------------------------------------------------------------------
// Runs the recompiled unpack into a copy of the destination, then the C unpackers into VU memory,
// compares the two and keeps the C result. Logs @@VIF_CHECK@@ lines.

namespace
{
	struct VifCheckStats
	{
		u64 checks = 0;
		u64 mismatches = 0;
		u64 w_only = 0; // V2/V3 differing only in W: the C unpackers don't model the W quirks
		u64 next_report = 1u << 12;
		u32 logged = 0;
		u32 per_type_checks[64][4] = {}; // [usn:mask:upk][mode]
		u32 per_type_bad[64][4] = {};
	};
} // namespace

static VifCheckStats s_vif_check;
alignas(16) static u8 s_vif_check_buf[0x4000];

static const char* iPSX2_VifUnpackName(u32 upk)
{
	static const char* const names[16] = {"S-32", "S-16", "S-8", "?3", "V2-32", "V2-16", "V2-8", "?7",
		"V3-32", "V3-16", "V3-8", "?11", "V4-32", "V4-16", "V4-8", "V4-5"};
	return names[upk & 0xf];
}

static void iPSX2_VifCheckLog16(const char* label, const u8* p)
{
	u32 w[4];
	std::memcpy(w, p, sizeof(w));
	Console.WriteLn("@@VIF_CHECK@@   %-6s %08X %08X %08X %08X", label, w[0], w[1], w[2], w[3]);
}

static void iPSX2_VifCheckReport()
{
	Console.WriteLn("@@VIF_CHECK@@ summary: %llu unpacks checked, %llu mismatched, %llu V2/V3 W-only differences",
		static_cast<unsigned long long>(s_vif_check.checks), static_cast<unsigned long long>(s_vif_check.mismatches),
		static_cast<unsigned long long>(s_vif_check.w_only));
	for (u32 t = 0; t < 64; t++)
	{
		for (u32 m = 0; m < 4; m++)
		{
			if (!s_vif_check.per_type_checks[t][m])
				continue;
			Console.WriteLn("@@VIF_CHECK@@   %s%s%s mode=%u: %u checked, %u bad", iPSX2_VifUnpackName(t),
				(t & 0x10) ? " masked" : "", (t & 0x20) ? " unsigned" : "", m, s_vif_check.per_type_checks[t][m],
				s_vif_check.per_type_bad[t][m]);
		}
	}
}

_vifT static void iPSX2_VifCheckUnpack(const nVifBlock& b, u8* startmem, const u8* data, bool isFill)
{
	vifStruct& vif = MTVU_VifX;
	VIFregisters& vifRegs = MTVU_VifXRegs;
	const u32 len = std::min<u32>(b.length, sizeof(s_vif_check_buf));
	const u32 addr = vif.tag.addr;
	const u32 num = vifRegs.num;
	const u32 mode = vifRegs.mode & 3;
	const u32 upk = b.upkType & 0x3f;

	// Recompiled unpack into a copy of the destination, from the current row register.
	std::memcpy(s_vif_check_buf, startmem, len);
	const u128 row_before = vif.MaskRow;
	((nVifrecCall)b.startPtr)((uptr)s_vif_check_buf, (uptr)data);
	const u128 row_jit = vif.MaskRow;
	vif.MaskRow = row_before;

	// C unpackers into VU memory; this is the result that's kept.
	_nVifUnpack(idx, data, vifRegs.mode, isFill);

	s_vif_check.checks++;
	s_vif_check.per_type_checks[upk][mode]++;

	const u32 upk_num = upk & 0xf;
	const bool w_quirk_type = (upk_num >= 4 && upk_num <= 10); // V2-x, V3-x
	u32 first_bad = len;
	bool w_only_seen = false;
	for (u32 off = 0; off + 16 <= len; off += 16)
	{
		if (std::memcmp(s_vif_check_buf + off, startmem + off, 16) == 0)
			continue;
		const bool xyz_same = std::memcmp(s_vif_check_buf + off, startmem + off, 12) == 0;
		if (w_quirk_type && xyz_same)
		{
			w_only_seen = true;
			continue;
		}
		first_bad = off;
		break;
	}
	const bool row_bad = std::memcmp(&row_jit, &vif.MaskRow, sizeof(u128)) != 0 && mode >= 2;

	if (w_only_seen && first_bad == len && !row_bad)
		s_vif_check.w_only++;

	if (first_bad != len || row_bad)
	{
		s_vif_check.mismatches++;
		s_vif_check.per_type_bad[upk][mode]++;
		if (s_vif_check.logged < 40)
		{
			s_vif_check.logged++;
			Console.WriteLn("@@VIF_CHECK@@ MISMATCH #%u VIF%d %s%s%s mode=%u mask=%08X cl=%u wl=%u num=%u addr=%04X "
							"aligned=%u fill=%d len=%u first=+%u%s",
				s_vif_check.logged, idx, iPSX2_VifUnpackName(upk), (upk & 0x10) ? " masked" : "",
				(upk & 0x20) ? " unsigned" : "", mode, b.mask, b.cl, b.wl, num, addr, b.aligned, isFill ? 1 : 0, len,
				first_bad, row_bad ? " ROW" : "");
			if (first_bad != len)
			{
				iPSX2_VifCheckLog16("jit", s_vif_check_buf + first_bad);
				iPSX2_VifCheckLog16("interp", startmem + first_bad);
			}
			iPSX2_VifCheckLog16("src", data);
			iPSX2_VifCheckLog16("src+16", data + 16);
			iPSX2_VifCheckLog16("row", reinterpret_cast<const u8*>(&row_before));
			if (row_bad)
			{
				iPSX2_VifCheckLog16("rowjit", reinterpret_cast<const u8*>(&row_jit));
				iPSX2_VifCheckLog16("rowint", reinterpret_cast<const u8*>(&vif.MaskRow));
			}
		}
	}

	if (s_vif_check.checks >= s_vif_check.next_report)
	{
		iPSX2_VifCheckReport();
		s_vif_check.next_report = (s_vif_check.next_report < (1u << 20)) ? (s_vif_check.next_report << 2) :
																			  (s_vif_check.next_report + (1u << 20));
	}
}

_vifT __fi void dVifUnpack(const u8* data, bool isFill)
{
	nVifStruct& v = nVif[idx];
	vifStruct& vif = MTVU_VifX;
	VIFregisters& vifRegs = MTVU_VifXRegs;

	const u8 upkType = (vif.cmd & 0x1f) | (vif.usn << 5);
	const int doMask = isFill ? 1 : (vif.cmd & 0x10);

	nVifBlock block;

	// Performance note: initial code was using u8/u16 field of the struct
	// directly. However reading back the data (as u32) in HashBucket.find
	// leads to various memory stalls. So it is way faster to manually build the data
	// in u32 (aka x86 register).
	//
	// Warning the order of data in hash_key/key0/key1 depends on the nVifBlock struct
	u32 hash_key = (u32)(upkType & 0xFF) << 8 | (vifRegs.num & 0xFF);

	u32 key1 = ((u32)vifRegs.cycle.wl << 24) | ((u32)vifRegs.cycle.cl << 16) | ((u32)(vif.start_aligned & 0xFF) << 8) | ((u32)vifRegs.mode & 0xFF);
	if ((upkType & 0xf) != 9)
		key1 &= 0xFFFF01FF;

	// Zero out the mask parameter if it's unused -- games leave random junk
	// values here which cause false recblock cache misses.
	u32 key0 = doMask ? vifRegs.mask : 0;

	block.hash_key = hash_key;
	block.key0 = key0;
	block.key1 = key1;

	//DevCon.WriteLn("nVif%d: Recompiled Block!", idx);
	//DevCon.WriteLn(L"[num=% 3d][upkType=0x%02x][scl=%d][cl=%d][wl=%d][mode=%d][m=%d][mask=%s]",
	//	block.num, block.upkType, block.scl, block.cl, block.wl, block.mode,
	//	doMask >> 4, doMask ? wxsFormat( L"0x%08x", block.mask ).c_str() : L"ignored"
	//);

	// Seach in cache before trying to compile the block
	nVifBlock* b = v.vifBlocks.find(block);
	if (!b) [[unlikely]]
	{
		b = dVifCompile<idx>(block, isFill);
	}

	{ // Execute the block
		const VURegs& VU = g_cpuRegistersPack.vuRegs[idx];
		const uint vuMemLimit = idx ? 0x4000 : 0x1000;

		u8* startmem = VU.Mem + (vif.tag.addr & (vuMemLimit - 0x10));
		u8* endmem = VU.Mem + vuMemLimit;

		if ((startmem + b->length) <= endmem) [[likely]]
		{
#if 1
			// No wrapping, you can run the fast dynarec
			if (g_iPSX2_VIFUnpackMode == 2) [[unlikely]]
				iPSX2_VifCheckUnpack<idx>(*b, startmem, data, isFill);
			else
				((nVifrecCall)b->startPtr)((uptr)startmem, (uptr)data);
#else
			// comparison mode
			static u8 tmpbuf[512 * 1024];
			((nVifrecCall)b->startPtr)((uptr)tmpbuf, (uptr)data);

			_nVifUnpack(idx, data, vifRegs.mode, isFill);

			const u32 words = b->length / 4;
			for (u32 i = 0; i < words; i++)
			{
				if (*((u32*)tmpbuf + i) != *((u32*)startmem + i))
				{
					// fprintf(stderr, "%08X %08X @ %u\n", *((u32*)tmpbuf + i), *((u32*)startmem + i), i);
					pauseCCC(*((u32*)tmpbuf + i), *((u32*)startmem + i), i);
					((nVifrecCall)b->startPtr)((uptr)tmpbuf, (uptr)data);
					break;
				}
			}
#endif
		}
		else
		{
			VIF_LOG("Running Interpreter Block: nVif%x - VU Mem Ptr Overflow; falling back to interpreter. Start = %x End = %x num = %x, wl = %x, cl = %x",
				v.idx, vif.tag.addr, vif.tag.addr + (block.num * 16), block.num, block.wl, block.cl);
			_nVifUnpack(idx, data, vifRegs.mode, isFill);
		}
	}
}

template void dVifUnpack<0>(const u8* data, bool isFill);
template void dVifUnpack<1>(const u8* data, bool isFill);
