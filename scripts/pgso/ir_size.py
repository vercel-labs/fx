#!/usr/bin/env python3
"""Size passes for PGSO bitcode, run through the pinned LLVM C library.

    ir_size.py --libllvm <libLLVM.dylib> outline-helpers <in.bc> <out.bc>
    ir_size.py --libllvm <libLLVM.dylib> sparse-constants <in.bc> <out.bc>
    ir_size.py --libllvm <libLLVM.dylib> overlay-constants <in.bc> <out.bc>
    ir_size.py --libllvm <libLLVM.dylib> expand-constant-exprs <in.bc> <out.bc>
    ir_size.py --libllvm <libLLVM.dylib> swap-compares <in.bc> <out.bc>
    ir_size.py --libllvm <libLLVM.dylib> widen-constants <in.bc> <out.bc>
    ir_size.py --libllvm <libLLVM.dylib> check-outlined <in.bc>
    ir_size.py --libllvm <libLLVM.dylib> dropped-outputs <in.bc>
    ir_size.py --libllvm <libLLVM.dylib> minsize-functions <in.bc> <out.json>
    ir_size.py --libllvm <libLLVM.dylib> no-outline <in.bc> <out.bc> --functions <names.txt>
    ir_size.py --libllvm <libLLVM.dylib> name-functions <in.bc> <out.bc>

outline-helpers marks small shared std helpers as noinline: the allocator's
slice free, remap, and aligned allocation, the writer's write, writeAll,
writeByte, and allocating writer setup and teardown, the byte list's append,
every list's teardown, slice equality and prefix checks, case-insensitive
ASCII equality, and the Io mutex's lock and unlock.
Zig inlines them at thousands of call sites (free alone at about
11,000 in fx); one out-of-line copy per instantiation keeps the same checks,
poisoning, and calls. Run it on the emitted bitcode, before instrumentation,
so training and profile use see the same inlining.

sparse-constants rewrites copies from mostly undefined internal constants
into stores of their defined scalar leaves. Zig materializes `return error.X`
from a function returning a large `E!T` as a constant `{ T undef, code,
padding undef }` copied into the result. Copying undefined bytes is refined
by leaving the destination bytes unchanged, so only the defined bytes are
stored. A constant with too many defined bytes for that, such as the default
value of a large struct, whose leaves are almost all zero, is copied instead
as a zero fill of the copied bytes followed by stores of its nonzero leaves.
Run `opt -passes=globaldce,verify` afterwards to drop dead constants.

overlay-constants packs the mostly undefined internal constants that are
still referenced, the same `return error.X` results plus `return null` results
`{ T undef, i8 0 }`, into one shared constant. They are `unnamed_addr`, so
only their contents matter, and an undefined byte may hold any value: two
constants can overlap wherever neither defines a byte the other defines
differently. Each keeps its alignment and its full size inside the blob and
becomes an alias of its offset, so every reference stays its own symbol. A
constant that hot code uses, or one small enough for codegen to expand its
copies into stores, never gets another constant's nonzero byte in its
undefined bytes, so those copies still read zeros and compile as before.
Constants that hold relocated pointers, compare or convert their address,
live in a named section, are thread-local, or are listed in llvm.used stay as
they are. Run it after sparse-constants, then `opt -passes=globaldce,verify`.

expand-constant-exprs rebuilds each constant expression an instruction uses
as an operand, such as `getelementptr (i8, ptr @g, i64 16)`, as an
instruction of its own. LLVM's IR outliner does not see constants nested in
a constant expression when it matches regions, so two regions that differ
only in an instruction's constant, one with 16 and one with 8898, can share a
parameter that also replaces the nested 16: the second region then reads
`@g + 8898`. With the expressions rebuilt as instructions, every constant is
an operand the outliner compares. Run it on the outliner's input right
before `opt -passes=iroutliner`, with no pass between that could fold them
back.
PHI nodes, landing pads, call targets, and intrinsic calls keep their
expressions: the outliner never moves an intrinsic call or a PHI's incoming
constant into a region, and a call target must stay a direct callee.

swap-compares rewrites each greater-than comparison, such as `icmp ugt %a,
%b`, as the less-than comparison with its operands swapped, `icmp ult %b,
%a`, keeping its flags and debug location. LLVM's IR outliner matches the two
forms as one region by reversing the operands it compares, but it passes the
reversed region's operands to the outlined function in their original order,
so that region computes `a < b` instead of `a > b`. A PGSO build of the
current source turned a skill file read's bounds check around this way and
panicked on the first chunk. With no greater-than comparison left, the
outliner matches only comparisons written the same way. Run it on the
outliner's input right before `opt -passes=iroutliner`, after
expand-constant-exprs.

widen-constants rebuilds each i1 and i16 integer constant an instruction uses
as an operand, such as the `i1 true` in `call void @f(i1 true)`, as a trunc of
an i8 or i32 constant. When regions differ in a constant, LLVM's IR outliner
passes it as a parameter and replaces every use of the first region's constant
in the outlined function, including the constant each exit returns to tell the
caller where to continue: i1 for two exits, i16 for more. A region that passes
`true` where the first passed `false` then returns `true` from the `false`
exit, and the caller takes the other branch. A PGSO build of the unit tests
took a slash menu test's `orelse` panic this way on a non-null result. With
those constants rebuilt, the outliner only passes them as i8 and i32
parameters, which no exit returns. PHI incoming constants keep their
constants: rebuilding one at the end of its incoming block turns it into a
value the region must hand back, and the outliner then sometimes drops that
store. check-outlined catches a PHI constant that becomes an exit's value.
Intrinsic arguments that must be immediate, assume-like intrinsics, inline
asm, GEP indices, and switch cases also keep their constants. Run it on the
outliner's input right before `opt -passes=iroutliner`, after swap-compares.
The LLVM bug is https://github.com/llvm/llvm-project/issues/239125.

check-outlined fails when an outlined function holds a constant expression
that the outliner rebuilt from a parameter: an instruction LLVM named
`constexpr`, or a constant expression with a non-constant operand. It also
fails when an outlined function returns something other than a constant,
because each exit returns its own constant, and when it has a block other
than its entry that nothing branches to (see dropped-outputs). After
expand-constant-exprs and widen-constants the first two should not exist, so
a hit is a form these guards do not cover.

dropped-outputs prints, as JSON, each outlined function with a block other
than its entry that nothing branches to, and the functions that call it.
When two regions store the same outputs in two different ways, LLVM's IR
outliner needs a switch to pick the stores, but it builds the switch only
when the stored outputs differ, and the release build skips the assertion
that catches the case. The stores are left in blocks nothing branches to, so
each caller reads its output uninitialized. A transformed unit test read a
garbage error code this way. Nothing else the outliner builds is
unreachable. The pipeline marks those callers `nooutline` and outlines
again. The LLVM bug is https://github.com/llvm/llvm-project/issues/239126.

minsize-functions writes the names of the defined functions, and of those
that carry `minsize`, to a JSON file. Profile use marks the functions it
judges cold `minsize`.

name-functions gives each defined private function internal linkage. Zig
emits every function private, and a private function has no symbol in the
object, so a link that orders by symbol cannot place it. Internal linkage
generates the same code and keeps a local symbol, which the final link strips.

no-outline adds `nooutline` to the defined functions listed one per line in
the --functions file. The IR outliner and llc's machine outliner both skip
such functions, so their code stays in place instead of moving into shared
helpers elsewhere in the binary. It fails when no listed function is defined.

Every command prints a JSON summary on stdout and exits nonzero when the
input cannot be read. outline-helpers also fails when no allocator free helper
matches, because that means std naming changed and the pass went stale.
"""
from __future__ import annotations

import argparse
import bisect
import ctypes as C
import json
import pathlib
import re
import sys

OUT_OF_LINE_HELPERS = (
    r"mem\.Allocator\.free(?:__func_\d+)?",
    r"mem\.Allocator\.(?:remap|allocBytesAligned)__func_\d+",
    r"Io\.Writer\.(?:writeAll|write|writeByte|Allocating\.deinit|Allocating\.initCapacity)",
    r"array_list\.Aligned\(u8,null\)\.appendSlice",
    r"array_list\.Aligned\(.*\)\.deinit",
    r"mem\.eql__func_\d+",
    r"mem\.startsWith(?:__func_\d+)?",
    r"ascii\.eqlIgnoreCase",
    r"Io\.Mutex\.(?:lock|lockUncancelable|unlock)",
)

MIN_CONSTANT_BYTES = 32
MAX_DEFINED_BYTES = 128
MAX_LEAVES = 16
MEMCPY_SITE_BYTES = 16
STORE_BYTES = 8
# sparse-constants: a constant too large for leaf stores alone, such as a
# struct's default value, is copied as a zero fill plus stores of its nonzero
# leaves, at most this many and this many bytes.
ZERO_FILL_COPY_MAX_LEAVES = 64
ZERO_FILL_COPY_MAX_BYTES = 512
MEMSET_SITE_BYTES = 16
# overlay-constants: at most this share of a member's bytes may be defined
# and nonzero, and members below OVERLAY_GUARD_BYTES (the largest copy
# AArch64 expands into stores in size-optimized code) keep zeros in their
# undefined bytes.
OVERLAY_MAX_NONZERO_SHARE = 0.25
OVERLAY_GUARD_BYTES = 64
OVERLAY_MAX_ALIGN = 16
OVERLAY_BLOB = b"pgso.overlaid_constants"
# zero-fill-globals: writable globals at least this large whose nonzero
# defined bytes fit in ZERO_FILL_MAX_STORED_BYTES move to zero-fill.
ZERO_FILL_MIN_BYTES = 4096
ZERO_FILL_MAX_STORED_BYTES = 64
ZERO_FILL_MAX_STORES = 8

P = C.c_void_p
STRUCT, ARRAY, INTEGER, POINTER = 10, 11, 8, 12
FLOATS = (1, 2, 3)
INTERNAL_LINKAGE, PRIVATE_LINKAGE = 8, 9
FUNCTION_INDEX = 0xFFFFFFFF
GET_ELEMENT_PTR = 29
PTR_TO_INT, INT_TO_PTR = 39, 40
GLOBAL_UNNAMED_ADDR = 2
CASTS = {30: "trunc", 39: "ptrtoint", 40: "inttoptr", 41: "bitcast", 60: "addrspacecast", 69: "ptrtoaddr"}
OUTLINED_PREFIX = "outlined_ir_func"

# LLVMIntPredicate and LLVMRealPredicate values: each greater-than predicate
# that LLVM's IR similarity analysis reverses, mapped to its swapped form.
SWAPPED_INT_PREDICATES = {34: 36, 35: 37, 38: 40, 39: 41}  # ugt, uge, sgt, sge
SWAPPED_REAL_PREDICATES = {2: 4, 3: 5, 10: 12, 11: 13}  # ogt, oge, ugt, uge
TRUNC = 30
# widen-constants: the IR outliner's exit selectors are i1 or i16, so those
# constants are rebuilt from constants of these widths.
WIDENED_WIDTHS = {1: 8, 16: 32}
# The intrinsics LLVM calls assume-like, which the IR outliner never moves.
ASSUME_LIKE_INTRINSICS = (
    "llvm.assume",
    "llvm.sideeffect",
    "llvm.pseudoprobe",
    "llvm.dbg.",
    "llvm.invariant.",
    "llvm.lifetime.",
    "llvm.experimental.noalias.scope.decl",
    "llvm.objectsize.",
    "llvm.ptr.annotation.",
    "llvm.var.annotation.",
)


class PassError(Exception):
    pass


class _Skip(Exception):
    pass


class Llvm:
    def __init__(self, library: pathlib.Path) -> None:
        self.lib = C.CDLL(str(library))
        f = self._fn
        self.ContextCreate = f("LLVMContextCreate", P)
        self.CreateMemBuf = f("LLVMCreateMemoryBufferWithContentsOfFile", C.c_int, C.c_char_p, C.POINTER(P), C.POINTER(C.c_char_p))
        self.ParseBC = f("LLVMParseBitcodeInContext2", C.c_int, P, P, C.POINTER(P))
        self.WriteBC = f("LLVMWriteBitcodeToFile", C.c_int, P, C.c_char_p)
        self.GetDL = f("LLVMGetDataLayoutStr", C.c_char_p, P)
        self.CreateTD = f("LLVMCreateTargetData", P, C.c_char_p)
        self.FirstGlobal = f("LLVMGetFirstGlobal", P, P)
        self.NextGlobal = f("LLVMGetNextGlobal", P, P)
        self.FirstFunction = f("LLVMGetFirstFunction", P, P)
        self.NextFunction = f("LLVMGetNextFunction", P, P)
        self.IsDeclaration = f("LLVMIsDeclaration", C.c_int, P)
        self.GetLinkage = f("LLVMGetLinkage", C.c_int, P)
        self.IsGlobalConstant = f("LLVMIsGlobalConstant", C.c_int, P)
        self.GetInitializer = f("LLVMGetInitializer", P, P)
        self.GlobalValueType = f("LLVMGlobalGetValueType", P, P)
        self.ABISize = f("LLVMABISizeOfType", C.c_ulonglong, P, P)
        self.ABIAlign = f("LLVMABIAlignmentOfType", C.c_uint, P, P)
        self.OffsetOfElement = f("LLVMOffsetOfElement", C.c_ulonglong, P, P, C.c_uint)
        self.TypeOf = f("LLVMTypeOf", P, P)
        self.TypeKind = f("LLVMGetTypeKind", C.c_int, P)
        self.CountStructElems = f("LLVMCountStructElementTypes", C.c_uint, P)
        self.ArrayLen = f("LLVMGetArrayLength2", C.c_ulonglong, P)
        self.ElementType = f("LLVMGetElementType", P, P)
        self.AggElem = f("LLVMGetAggregateElement", P, P, C.c_uint)
        self.IsUndef = f("LLVMIsUndef", C.c_int, P)
        self.IsNull = f("LLVMIsNull", C.c_int, P)
        self.IsConstant = f("LLVMIsConstant", C.c_int, P)
        self.IsAConstantInt = f("LLVMIsAConstantInt", P, P)
        self.IsAConstantFP = f("LLVMIsAConstantFP", P, P)
        self.FirstUse = f("LLVMGetFirstUse", P, P)
        self.NextUse = f("LLVMGetNextUse", P, P)
        self.GetUser = f("LLVMGetUser", P, P)
        self.IsACallInst = f("LLVMIsACallInst", P, P)
        self.CalledValue = f("LLVMGetCalledValue", P, P)
        self.GetValueName2 = f("LLVMGetValueName2", C.c_char_p, P, C.POINTER(C.c_size_t))
        self.GetOperand = f("LLVMGetOperand", P, P, C.c_uint)
        self.ConstZExt = f("LLVMConstIntGetZExtValue", C.c_ulonglong, P)
        self.Int8Ty = f("LLVMInt8TypeInContext", P, P)
        self.Int64Ty = f("LLVMInt64TypeInContext", P, P)
        self.ConstInt = f("LLVMConstInt", P, P, C.c_ulonglong, C.c_int)
        self.CreateBuilder = f("LLVMCreateBuilderInContext", P, P)
        self.PositionBefore = f("LLVMPositionBuilderBefore", None, P, P)
        self.BuildGEP2 = f("LLVMBuildInBoundsGEP2", P, P, P, P, C.POINTER(P), C.c_uint, C.c_char_p)
        self.BuildStore = f("LLVMBuildStore", P, P, P, P)
        self.BuildMemSet = f("LLVMBuildMemSet", P, P, P, P, P, C.c_uint)
        self.SetAlignment = f("LLVMSetAlignment", None, P, C.c_uint)
        self.Erase = f("LLVMInstructionEraseFromParent", None, P)
        self.EnumAttrKind = f("LLVMGetEnumAttributeKindForName", C.c_uint, C.c_char_p, C.c_size_t)
        self.CreateEnumAttr = f("LLVMCreateEnumAttribute", P, P, C.c_uint, C.c_ulonglong)
        self.CreateStringAttr = f("LLVMCreateStringAttribute", P, P, C.c_char_p, C.c_uint, C.c_char_p, C.c_uint)
        self.AddAttr = f("LLVMAddAttributeAtIndex", None, P, C.c_uint, P)
        self.GetEnumAttrAt = f("LLVMGetEnumAttributeAtIndex", P, P, C.c_uint, C.c_uint)
        self.CallSiteEnumAttr = f("LLVMGetCallSiteEnumAttribute", P, P, C.c_uint, C.c_uint)
        self.EnumAttrValue = f("LLVMGetEnumAttributeValue", C.c_ulonglong, P)
        self.FirstBlock = f("LLVMGetFirstBasicBlock", P, P)
        self.NextBlock = f("LLVMGetNextBasicBlock", P, P)
        self.FirstInstruction = f("LLVMGetFirstInstruction", P, P)
        self.NextInstruction = f("LLVMGetNextInstruction", P, P)
        self.NumOperands = f("LLVMGetNumOperands", C.c_int, P)
        self.SetOperand = f("LLVMSetOperand", None, P, C.c_uint, P)
        self.IsAConstantExpr = f("LLVMIsAConstantExpr", P, P)
        self.ConstOpcode = f("LLVMGetConstOpcode", C.c_int, P)
        self.IsAPHINode = f("LLVMIsAPHINode", P, P)
        self.IsALandingPad = f("LLVMIsALandingPadInst", P, P)
        self.IsAInvoke = f("LLVMIsAInvokeInst", P, P)
        self.IsACallBr = f("LLVMIsACallBrInst", P, P)
        self.IsAIntrinsic = f("LLVMIsAIntrinsicInst", P, P)
        self.GEPSourceType = f("LLVMGetGEPSourceElementType", P, P)
        self.GEPNoWrapFlags = f("LLVMGEPGetNoWrapFlags", C.c_uint, P)
        self.BuildGEPNoWrap = f("LLVMBuildGEPWithNoWrapFlags", P, P, P, P, C.POINTER(P), C.c_uint, C.c_char_p, C.c_uint)
        self.BuildCast = f("LLVMBuildCast", P, P, C.c_int, P, P, C.c_char_p)
        self.BuildFreeze = f("LLVMBuildFreeze", P, P, P, C.c_char_p)
        self.IsAInstruction = f("LLVMIsAInstruction", P, P)
        self.IsAICmpInst = f("LLVMIsAICmpInst", P, P)
        self.IsAFCmpInst = f("LLVMIsAFCmpInst", P, P)
        self.ICmpPredicate = f("LLVMGetICmpPredicate", C.c_int, P)
        self.FCmpPredicate = f("LLVMGetFCmpPredicate", C.c_int, P)
        self.BuildICmp = f("LLVMBuildICmp", P, P, C.c_int, P, P, C.c_char_p)
        self.BuildFCmp = f("LLVMBuildFCmp", P, P, C.c_int, P, P, C.c_char_p)
        self.ICmpSameSign = f("LLVMGetICmpSameSign", C.c_int, P)
        self.SetICmpSameSign = f("LLVMSetICmpSameSign", None, P, C.c_int)
        self.FastMathFlags = f("LLVMGetFastMathFlags", C.c_uint, P)
        self.SetFastMathFlags = f("LLVMSetFastMathFlags", None, P, C.c_uint)
        self.DebugLoc = f("LLVMInstructionGetDebugLoc", P, P)
        self.SetDebugLoc = f("LLVMInstructionSetDebugLoc", None, P, P)
        self.ReplaceAllUses = f("LLVMReplaceAllUsesWith", None, P, P)
        self.SetValueName2 = f("LLVMSetValueName2", None, P, C.c_char_p, C.c_size_t)
        self.GetUnnamedAddress = f("LLVMGetUnnamedAddress", C.c_int, P)
        self.SetUnnamedAddress = f("LLVMSetUnnamedAddress", None, P, C.c_int)
        self.GetSection = f("LLVMGetSection", C.c_char_p, P)
        self.IsThreadLocal = f("LLVMIsThreadLocal", C.c_int, P)
        self.IsExternallyInitialized = f("LLVMIsExternallyInitialized", C.c_int, P)
        self.GetComdat = f("LLVMGetComdat", P, P)
        self.GetAlignment = f("LLVMGetAlignment", C.c_uint, P)
        self.IsAConstantDataSequential = f("LLVMIsAConstantDataSequential", P, P)
        self.GetAsString = f("LLVMGetAsString", C.c_void_p, P, C.POINTER(C.c_size_t))
        self.IntWidth = f("LLVMGetIntTypeWidth", C.c_uint, P)
        self.IsAGlobalValue = f("LLVMIsAGlobalValue", P, P)
        self.InstOpcode = f("LLVMGetInstructionOpcode", C.c_int, P)
        self.InstParent = f("LLVMGetInstructionParent", P, P)
        self.BlockParent = f("LLVMGetBasicBlockParent", P, P)
        self.GetNamedGlobal = f("LLVMGetNamedGlobal", P, P, C.c_char_p)
        self.AddGlobal = f("LLVMAddGlobal", P, P, P, C.c_char_p)
        self.AddAlias2 = f("LLVMAddAlias2", P, P, P, C.c_uint, P, C.c_char_p)
        self.SetInitializer = f("LLVMSetInitializer", None, P, P)
        self.SetGlobalConstant = f("LLVMSetGlobalConstant", None, P, C.c_int)
        self.SetLinkage = f("LLVMSetLinkage", None, P, C.c_int)
        self.ArrayType2 = f("LLVMArrayType2", P, P, C.c_ulonglong)
        self.ConstString = f("LLVMConstStringInContext2", P, P, C.c_char_p, C.c_size_t, C.c_int)
        self.ConstGEP2 = f("LLVMConstInBoundsGEP2", P, P, P, C.POINTER(P), C.c_uint)
        self.DeleteGlobal = f("LLVMDeleteGlobal", None, P)
        self.IsALoadInst = f("LLVMIsALoadInst", P, P)
        self.IsAGEPInst = f("LLVMIsAGetElementPtrInst", P, P)
        self.CountIncoming = f("LLVMCountIncoming", C.c_uint, P)
        self.IncomingValue = f("LLVMGetIncomingValue", P, P, C.c_uint)
        self.IncomingBlock = f("LLVMGetIncomingBlock", P, P, C.c_uint)
        self.BuildPhi = f("LLVMBuildPhi", P, P, P, C.c_char_p)
        self.AddIncoming = f("LLVMAddIncoming", None, P, C.POINTER(P), C.POINTER(P), C.c_uint)
        self.BuildCall2 = f("LLVMBuildCall2", P, P, P, P, C.POINTER(P), C.c_uint, C.c_char_p)
        self.BuildExtractValue = f("LLVMBuildExtractValue", P, P, P, C.c_uint, C.c_char_p)
        self.BuildInsertValue = f("LLVMBuildInsertValue", P, P, P, P, C.c_uint, C.c_char_p)
        self.BuildLoad2 = f("LLVMBuildLoad2", P, P, P, P, C.c_char_p)
        self.BuildSub = f("LLVMBuildSub", P, P, P, P, C.c_char_p)
        self.BuildRet = f("LLVMBuildRet", P, P, P)
        self.PositionAtEnd = f("LLVMPositionBuilderAtEnd", None, P, P)
        self.AppendBlock = f("LLVMAppendBasicBlockInContext", P, P, P, C.c_char_p)
        self.AddFunction = f("LLVMAddFunction", P, P, C.c_char_p, P)
        self.FunctionType = f("LLVMFunctionType", P, P, C.POINTER(P), C.c_uint, C.c_int)
        self.StructType = f("LLVMStructTypeInContext", P, P, C.POINTER(P), C.c_uint, C.c_int)
        self.PointerType = f("LLVMPointerTypeInContext", P, P, C.c_uint)
        self.Int16Ty = f("LLVMInt16TypeInContext", P, P)
        self.Int32Ty = f("LLVMInt32TypeInContext", P, P)
        self.GetParam = f("LLVMGetParam", P, P, C.c_uint)
        self.CountParams = f("LLVMCountParams", C.c_uint, P)
        self.GetPoison = f("LLVMGetPoison", P, P)
        self.ConstArray2 = f("LLVMConstArray2", P, P, C.POINTER(P), C.c_ulonglong)
        self.BuildAlloca = f("LLVMBuildAlloca", P, P, P, C.c_char_p)
        self.GetNamedFunction = f("LLVMGetNamedFunction", P, P, C.c_char_p)
        self.EntryBlock = f("LLVMGetEntryBasicBlock", P, P)
        self.ConstNull = f("LLVMConstNull", P, P)
        self.IsAAllocaInst = f("LLVMIsAAllocaInst", P, P)
        self.GetNamedAlias = f("LLVMGetNamedGlobalAlias", P, P, C.c_char_p, C.c_size_t)
        self.AliasTarget = f("LLVMAliasGetAliasee", P, P)
        self.IsAFunction = f("LLVMIsAFunction", P, P)
        self.IsAInlineAsm = f("LLVMIsAInlineAsm", P, P)
        self.IsATerminator = f("LLVMIsATerminatorInst", P, P)
        self.IsABranch = f("LLVMIsABranchInst", P, P)
        self.IsAReturn = f("LLVMIsAReturnInst", P, P)
        self.NumArgOperands = f("LLVMGetNumArgOperands", C.c_uint, P)
        self.IntTy = f("LLVMIntTypeInContext", P, P, C.c_uint)
        self.BlockTerminator = f("LLVMGetBasicBlockTerminator", P, P)
        self.NumSuccessors = f("LLVMGetNumSuccessors", C.c_uint, P)
        self.Successor = f("LLVMGetSuccessor", P, P, C.c_uint)
        self.BlockName = f("LLVMGetBasicBlockName", C.c_char_p, P)
        self.IsAArgument = f("LLVMIsAArgument", P, P)
        self.IsAStoreInst = f("LLVMIsAStoreInst", P, P)

    def _fn(self, name, res, *args):
        fn = getattr(self.lib, name)
        fn.restype = res
        fn.argtypes = list(args)
        return fn

    def load(self, path: pathlib.Path):
        ctx = self.ContextCreate()
        buf, msg, mod = P(), C.c_char_p(), P()
        if self.CreateMemBuf(str(path).encode(), C.byref(buf), C.byref(msg)):
            raise PassError(f"cannot read {path}")
        if self.ParseBC(ctx, buf, C.byref(mod)):
            raise PassError(f"cannot parse bitcode {path}")
        return ctx, mod

    def save(self, mod, path: pathlib.Path) -> None:
        if self.WriteBC(mod, str(path).encode()):
            raise PassError(f"cannot write bitcode {path}")

    def name(self, value) -> str:
        n = C.c_size_t()
        s = self.GetValueName2(value, C.byref(n))
        return s.decode("utf-8", "replace") if s else ""

    def kind(self, attribute: str) -> int:
        raw = attribute.encode()
        return self.EnumAttrKind(raw, len(raw))


def outline_helpers(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    ctx, mod = llvm.load(source)
    patterns = [re.compile(p) for p in OUT_OF_LINE_HELPERS]
    noinline = llvm.kind("noinline")
    always = llvm.kind("alwaysinline")
    per_pattern = [0] * len(patterns)
    fn = llvm.FirstFunction(mod)
    while fn:
        if not llvm.IsDeclaration(fn):
            name = llvm.name(fn)
            index = next((i for i, p in enumerate(patterns) if p.fullmatch(name)), None)
            if index is not None:
                if llvm.GetEnumAttrAt(fn, FUNCTION_INDEX, always):
                    raise PassError(f"helper is alwaysinline: {name}")
                llvm.AddAttr(fn, FUNCTION_INDEX, llvm.CreateEnumAttr(ctx, noinline, 0))
                per_pattern[index] += 1
        fn = llvm.NextFunction(fn)
    if per_pattern[0] == 0:
        raise PassError("no out-of-line helper matched; std naming may have changed")
    llvm.save(mod, output)
    return {
        "pass": "outline-helpers",
        "marked_functions": sum(per_pattern),
        "marked_by_pattern": dict(zip(OUT_OF_LINE_HELPERS, per_pattern)),
    }


def _leaves(llvm: Llvm, td, value, base: int, out: list) -> None:
    if llvm.IsUndef(value):
        return
    ty = llvm.TypeOf(value)
    kind = llvm.TypeKind(ty)
    if kind == STRUCT:
        for i in range(llvm.CountStructElems(ty)):
            _leaves(llvm, td, llvm.AggElem(value, i), base + llvm.OffsetOfElement(td, ty, i), out)
        return
    if kind == ARRAY:
        element = llvm.ElementType(ty)
        stride = llvm.ABISize(td, element)
        count = llvm.ArrayLen(ty)
        if count * stride > 4096 and not llvm.IsNull(value):
            raise _Skip("large defined array")
        for i in range(count):
            item = llvm.AggElem(value, i)
            if not item:
                raise _Skip("unreadable array element")
            _leaves(llvm, td, item, base + i * stride, out)
            if len(out) > MAX_LEAVES:
                raise _Skip("too many defined leaves")
        return
    scalar = (
        (kind == INTEGER and llvm.IsAConstantInt(value))
        or (kind == POINTER and llvm.IsConstant(value))
        or (kind in FLOATS and llvm.IsAConstantFP(value))
    )
    if not scalar:
        raise _Skip(f"unsupported leaf kind {kind}")
    out.append((base, value, llvm.ABISize(td, ty), llvm.ABIAlign(td, ty)))
    if len(out) > MAX_LEAVES or sum(leaf[2] for leaf in out) > MAX_DEFINED_BYTES:
        raise _Skip("too many defined bytes")


def _copy_leaves(llvm: Llvm, td, init) -> tuple[list, bool]:
    """The leaves a rewritten copy of `init` stores, and whether it zero-fills
    the copied bytes first. A constant within the leaf limits stores every
    defined leaf, zeros included; a larger one stores only its nonzero leaves
    after the zero fill."""
    leaves: list = []
    try:
        _leaves(llvm, td, init, 0, leaves)
        return leaves, False
    except _Skip as skip:
        if str(skip) not in ("too many defined bytes", "too many defined leaves", "large defined array"):
            raise
    leaves = []
    _nonzero_leaves(llvm, td, init, 0, leaves, ZERO_FILL_COPY_MAX_LEAVES, ZERO_FILL_COPY_MAX_BYTES)
    return leaves, True


def sparse_constants(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    ctx, mod = llvm.load(source)
    td = llvm.CreateTD(llvm.GetDL(mod))
    i8, i64 = llvm.Int8Ty(ctx), llvm.Int64Ty(ctx)
    builder = llvm.CreateBuilder(ctx)
    align_kind = llvm.kind("align")
    summary = {
        "pass": "sparse-constants",
        "rewritten_constants": 0,
        "zero_filled_constants": 0,
        "rewritten_copies": 0,
        "constant_bytes": 0,
    }
    glob = llvm.FirstGlobal(mod)
    while glob:
        following = llvm.NextGlobal(glob)
        try:
            if llvm.GetLinkage(glob) not in (INTERNAL_LINKAGE, PRIVATE_LINKAGE) or not llvm.IsGlobalConstant(glob):
                raise _Skip("not an internal constant")
            init = llvm.GetInitializer(glob)
            if not init:
                raise _Skip("no initializer")
            size = llvm.ABISize(td, llvm.GlobalValueType(glob))
            if size < MIN_CONSTANT_BYTES:
                raise _Skip("small")
            copies = []
            use = llvm.FirstUse(glob)
            if not use:
                raise _Skip("unused")
            while use:
                user = llvm.GetUser(use)
                if not llvm.IsACallInst(user):
                    raise _Skip("non-call use")
                if not llvm.name(llvm.CalledValue(user)).startswith("llvm.memcpy.p0.p0."):
                    raise _Skip("non-copy call use")
                if llvm.GetOperand(user, 1) != glob or llvm.GetOperand(user, 0) == glob:
                    raise _Skip("constant is not only the copy source")
                length, volatile = llvm.GetOperand(user, 2), llvm.GetOperand(user, 3)
                if not llvm.IsAConstantInt(length) or not 0 < llvm.ConstZExt(length) <= size:
                    raise _Skip("variable or oversized copy")
                if not llvm.IsAConstantInt(volatile) or llvm.ConstZExt(volatile) != 0:
                    raise _Skip("volatile copy")
                copies.append((user, llvm.ConstZExt(length)))
                use = llvm.NextUse(use)
            leaves, zero_fill = _copy_leaves(llvm, td, init)
            extra = 0
            for _, length in copies:
                if any(offset < length < offset + width for offset, _, width, _ in leaves):
                    raise _Skip("copy splits a defined leaf")
                inside = sum(1 for offset, _, width, _ in leaves if offset + width <= length)
                fill = MEMSET_SITE_BYTES if zero_fill else 0
                extra += max(0, fill + STORE_BYTES * inside - MEMCPY_SITE_BYTES)
            if extra >= size:
                raise _Skip("stores would cost more than the constant")
            for call, length in copies:
                destination = llvm.GetOperand(call, 0)
                attribute = llvm.CallSiteEnumAttr(call, 1, align_kind)
                destination_align = llvm.EnumAttrValue(attribute) if attribute else 1
                llvm.PositionBefore(builder, call)
                if zero_fill:
                    llvm.BuildMemSet(
                        builder, destination, llvm.ConstInt(i8, 0, 0), llvm.ConstInt(i64, length, 0), destination_align
                    )
                for offset, value, width, natural in leaves:
                    if offset + width > length:
                        continue
                    pointer = destination
                    if offset:
                        index = (P * 1)(llvm.ConstInt(i64, offset, 0))
                        pointer = llvm.BuildGEP2(builder, i8, destination, index, 1, b"")
                    store = llvm.BuildStore(builder, value, pointer)
                    alignment = natural
                    while alignment > 1 and (offset % alignment or destination_align % alignment):
                        alignment //= 2
                    llvm.SetAlignment(store, max(alignment, 1))
                llvm.Erase(call)
                summary["rewritten_copies"] += 1
            summary["rewritten_constants"] += 1
            summary["constant_bytes"] += size
            if zero_fill:
                summary["zero_filled_constants"] += 1
        except _Skip:
            pass
        glob = following
    llvm.save(mod, output)
    return summary


def _image(llvm: Llvm, td, value, base: int, image: bytearray, defined: bytearray) -> None:
    """Record the defined bytes of a constant; undefined bytes stay unset."""
    if llvm.IsUndef(value):
        return
    ty = llvm.TypeOf(value)
    size = llvm.ABISize(td, ty)
    if llvm.IsNull(value):
        defined[base:base + size] = b"\1" * size
        return
    kind = llvm.TypeKind(ty)
    if kind == STRUCT:
        for i in range(llvm.CountStructElems(ty)):
            _image(llvm, td, llvm.AggElem(value, i), base + llvm.OffsetOfElement(td, ty, i), image, defined)
        return
    if kind == ARRAY:
        element = llvm.ElementType(ty)
        if llvm.IsAConstantDataSequential(value):
            if llvm.TypeKind(element) != INTEGER or llvm.IntWidth(element) != 8:
                raise _Skip("dense numeric array")
            length = C.c_size_t()
            raw = C.string_at(llvm.GetAsString(value, C.byref(length)), length.value)
            image[base:base + len(raw)] = raw
            defined[base:base + len(raw)] = b"\1" * len(raw)
            return
        stride = llvm.ABISize(td, element)
        for i in range(llvm.ArrayLen(ty)):
            item = llvm.AggElem(value, i)
            if not item:
                raise _Skip("unreadable array element")
            _image(llvm, td, item, base + i * stride, image, defined)
        return
    if kind == INTEGER and llvm.IsAConstantInt(value) and llvm.IntWidth(ty) <= 64:
        width = (llvm.IntWidth(ty) + 7) // 8
        image[base:base + width] = llvm.ConstZExt(value).to_bytes(8, "little")[:width]
        defined[base:base + size] = b"\1" * size
        return
    if kind == POINTER and llvm.IsAConstantExpr(value) and llvm.ConstOpcode(value) == INT_TO_PTR:
        inner = llvm.GetOperand(value, 0)
        if llvm.IsAConstantInt(inner):
            image[base:base + 8] = llvm.ConstZExt(inner).to_bytes(8, "little")
            defined[base:base + 8] = b"\1" * 8
            return
    raise _Skip("relocated or unsupported leaf")


def _address_used(llvm: Llvm, value, depth: int = 0) -> bool:
    """True when a use compares the address or converts it to an integer."""
    use = llvm.FirstUse(value)
    while use:
        user = llvm.GetUser(use)
        if llvm.IsAInstruction(user):
            if llvm.IsAICmpInst(user) or llvm.InstOpcode(user) == PTR_TO_INT:
                return True
        elif llvm.IsAConstantExpr(user) and llvm.ConstOpcode(user) == PTR_TO_INT:
            return True
        elif not llvm.IsAGlobalValue(user) and (depth >= 4 or _address_used(llvm, user, depth + 1)):
            return True
        use = llvm.NextUse(use)
    return False


def _used_by_hot_code(llvm: Llvm, value, minsize: int, depth: int = 0) -> bool:
    use = llvm.FirstUse(value)
    while use:
        user = llvm.GetUser(use)
        if llvm.IsAInstruction(user):
            if not llvm.GetEnumAttrAt(llvm.BlockParent(llvm.InstParent(user)), FUNCTION_INDEX, minsize):
                return True
        elif not llvm.IsAGlobalValue(user) and (depth >= 4 or _used_by_hot_code(llvm, user, minsize, depth + 1)):
            return True
        use = llvm.NextUse(use)
    return False


def _listed_as_used(llvm: Llvm, mod) -> set:
    """Globals that llvm.used or llvm.compiler.used keep; an alias cannot
    stand in for them there."""
    listed = set()
    for name in (b"llvm.used", b"llvm.compiler.used"):
        used = llvm.GetNamedGlobal(mod, name)
        init = llvm.GetInitializer(used) if used else None
        if init:
            for i in range(llvm.NumOperands(init)):
                listed.add(llvm.GetOperand(init, i))
    return listed


def _overlay_members(llvm: Llvm, mod, td, minsize: int) -> list:
    members = []
    listed = _listed_as_used(llvm, mod)
    glob = llvm.FirstGlobal(mod)
    while glob:
        try:
            if glob in listed:
                raise _Skip("listed as used")
            if llvm.GetLinkage(glob) not in (INTERNAL_LINKAGE, PRIVATE_LINKAGE) or not llvm.IsGlobalConstant(glob):
                raise _Skip("not an internal constant")
            if llvm.GetUnnamedAddress(glob) != GLOBAL_UNNAMED_ADDR:
                raise _Skip("significant address")
            if llvm.GetSection(glob) or llvm.IsThreadLocal(glob) or llvm.GetComdat(glob) or llvm.IsExternallyInitialized(glob):
                raise _Skip("placed constant")
            size = llvm.ABISize(td, llvm.GlobalValueType(glob))
            align = max(llvm.GetAlignment(glob), 1)
            init = llvm.GetInitializer(glob)
            if not init or size < MIN_CONSTANT_BYTES or align > OVERLAY_MAX_ALIGN or not llvm.FirstUse(glob):
                raise _Skip("not a candidate")
            image, defined = bytearray(size), bytearray(size)
            _image(llvm, td, init, 0, image, defined)
            leaves = [(offset, image[offset]) for offset in range(size) if defined[offset]]
            nonzero = sum(1 for _, byte in leaves if byte)
            if nonzero > OVERLAY_MAX_NONZERO_SHARE * size or _address_used(llvm, glob):
                raise _Skip("dense or address used")
            guarded = size < OVERLAY_GUARD_BYTES or _used_by_hot_code(llvm, glob, minsize)
            members.append((nonzero, size, align, guarded, leaves, glob))
        except _Skip:
            pass
        glob = llvm.NextGlobal(glob)
    # The members with the most nonzero bytes are the hardest to place.
    members.sort(key=lambda m: (-m[0], -m[1], -m[2]))
    return members


def _pack(members: list) -> tuple[bytearray, list[int]]:
    """First fit: each member at the lowest aligned offset where its defined
    bytes agree with the blob and no guarded member's undefined byte would
    receive a nonzero byte."""
    blob, defined, guard = bytearray(), bytearray(), bytearray()
    nonzero_at: list[int] = []
    offsets = []
    for _, size, align, guarded, leaves, _ in members:
        own = {offset: byte for offset, byte in leaves if byte}
        base = 0
        while True:
            end = len(blob)
            ok = all(
                base + offset >= end
                or not (defined[base + offset] and blob[base + offset] != byte)
                and not (byte and guard[base + offset] and not defined[base + offset])
                for offset, byte in leaves
            )
            if ok and guarded:
                i = bisect.bisect_left(nonzero_at, base)
                while ok and i < len(nonzero_at) and nonzero_at[i] < base + size:
                    ok = own.get(nonzero_at[i] - base) == blob[nonzero_at[i]]
                    i += 1
            if ok:
                break
            base += align
        grow = base + size - len(blob)
        if grow > 0:
            blob.extend(bytes(grow))
            defined.extend(bytes(grow))
            guard.extend(bytes(grow))
        for offset, byte in leaves:
            if byte and not (defined[base + offset] and blob[base + offset] == byte):
                bisect.insort(nonzero_at, base + offset)
            blob[base + offset] = byte
            defined[base + offset] = 1
        if guarded:
            mine = {offset for offset, _ in leaves}
            for offset in range(size):
                if offset not in mine:
                    guard[base + offset] = 1
        offsets.append(base)
    return blob, offsets


def overlay_constants(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    ctx, mod = llvm.load(source)
    td = llvm.CreateTD(llvm.GetDL(mod))
    i8, i64 = llvm.Int8Ty(ctx), llvm.Int64Ty(ctx)
    members = _overlay_members(llvm, mod, td, llvm.kind("minsize"))
    summary = {
        "pass": "overlay-constants",
        "members": len(members),
        "guarded_members": sum(1 for m in members if m[3]),
        "member_bytes": sum(m[1] for m in members),
        "blob_bytes": 0,
    }
    if members:
        blob_bytes, offsets = _pack(members)
        summary["blob_bytes"] = len(blob_bytes)
        blob = llvm.AddGlobal(mod, llvm.ArrayType2(i8, len(blob_bytes)), OVERLAY_BLOB)
        llvm.SetInitializer(blob, llvm.ConstString(ctx, bytes(blob_bytes), len(blob_bytes), 1))
        llvm.SetGlobalConstant(blob, 1)
        llvm.SetLinkage(blob, INTERNAL_LINKAGE)
        llvm.SetUnnamedAddress(blob, GLOBAL_UNNAMED_ADDR)
        llvm.SetAlignment(blob, max(m[2] for m in members))
        for (_, _, _, _, _, glob), base in zip(members, offsets):
            index = (P * 1)(llvm.ConstInt(i64, base, 0))
            target = llvm.ConstGEP2(i8, blob, index, 1) if base else blob
            # One alias per member keeps each reference its own symbol, so
            # codegen does not share a blob base across a function's offsets.
            name = llvm.name(glob).encode()
            llvm.SetValueName2(glob, b"", 0)
            alias = llvm.AddAlias2(mod, llvm.GlobalValueType(glob), 0, target, name)
            llvm.SetLinkage(alias, INTERNAL_LINKAGE)
            llvm.SetUnnamedAddress(alias, GLOBAL_UNNAMED_ADDR)
            llvm.ReplaceAllUses(glob, alias)
            llvm.DeleteGlobal(glob)
    summary["saved_bytes"] = summary["member_bytes"] - summary["blob_bytes"]
    llvm.save(mod, output)
    return summary


def _nonzero_leaves(
    llvm: Llvm,
    td,
    value,
    base: int,
    out: list,
    max_leaves: int = ZERO_FILL_MAX_STORES,
    max_bytes: int = ZERO_FILL_MAX_STORED_BYTES,
) -> None:
    """Collects (offset, constant, size, alignment) for each defined nonzero
    scalar in `value`; undefined and zero parts hold nothing to restore."""
    if llvm.IsUndef(value) or llvm.IsNull(value):
        return
    ty = llvm.TypeOf(value)
    kind = llvm.TypeKind(ty)
    if kind == STRUCT:
        for i in range(llvm.CountStructElems(ty)):
            _nonzero_leaves(
                llvm, td, llvm.AggElem(value, i), base + llvm.OffsetOfElement(td, ty, i), out, max_leaves, max_bytes
            )
        return
    if kind == ARRAY:
        element = llvm.ElementType(ty)
        stride = llvm.ABISize(td, element)
        for i in range(llvm.ArrayLen(ty)):
            item = llvm.AggElem(value, i)
            if not item:
                raise _Skip("unreadable array element")
            _nonzero_leaves(llvm, td, item, base + i * stride, out, max_leaves, max_bytes)
        return
    scalar = (
        (kind == INTEGER and llvm.IsAConstantInt(value))
        or (kind == POINTER and llvm.IsConstant(value))
        or (kind in FLOATS and llvm.IsAConstantFP(value))
    )
    if not scalar:
        raise _Skip(f"unsupported leaf kind {kind}")
    out.append((base, value, llvm.ABISize(td, ty), llvm.ABIAlign(td, ty)))
    if len(out) > max_leaves or sum(leaf[2] for leaf in out) > max_bytes:
        raise _Skip("too many nonzero bytes")


def _zero_fill_plan(llvm: Llvm, td, glob):
    if llvm.IsDeclaration(glob) or llvm.IsGlobalConstant(glob):
        return None
    if llvm.GetLinkage(glob) not in (INTERNAL_LINKAGE, PRIVATE_LINKAGE):
        return None
    if llvm.IsThreadLocal(glob) or llvm.IsExternallyInitialized(glob) or llvm.GetSection(glob) or llvm.GetComdat(glob):
        return None
    ty = llvm.GlobalValueType(glob)
    size = llvm.ABISize(td, ty)
    initializer = llvm.GetInitializer(glob)
    if size < ZERO_FILL_MIN_BYTES or not initializer or llvm.IsNull(initializer) or llvm.IsUndef(initializer):
        return None
    stores: list = []
    try:
        _nonzero_leaves(llvm, td, initializer, 0, stores)
    except _Skip:
        return None
    # Without a nonzero byte, LLVM already puts the global in zero-fill.
    return (glob, ty, size, stores) if stores else None


def _entry_function(llvm: Llvm, mod):
    """`main`, or the function it aliases: Zig defines the program's `main`
    as an alias of an internal function."""
    entry = llvm.GetNamedFunction(mod, b"main")
    if entry:
        return entry
    alias = llvm.GetNamedAlias(mod, b"main", 4)
    return llvm.IsAFunction(llvm.AliasTarget(alias)) if alias else None


def zero_fill_globals(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    """Moves large writable globals that are almost all zero or undefined to
    zero-fill, which takes no space in the file, and stores their few nonzero
    bytes at the start of `main` instead.

    A writable global with even one nonzero byte in its initializer is
    written out whole. `main` runs before anything else in the program reads
    these globals, and no later pipeline stage evaluates stores back into an
    initializer, so every read sees the same value as before."""
    ctx, mod = llvm.load(source)
    td = llvm.CreateTD(llvm.GetDL(mod))
    summary = {"pass": "zero-fill-globals", "zero_filled_globals": 0, "zero_filled_bytes": 0, "stored_bytes": 0}
    entry_fn = _entry_function(llvm, mod)
    if not entry_fn or llvm.IsDeclaration(entry_fn):
        llvm.save(mod, output)
        summary["skipped"] = "no main"
        return summary
    plans = []
    glob = llvm.FirstGlobal(mod)
    while glob:
        plan = _zero_fill_plan(llvm, td, glob)
        if plan:
            plans.append(plan)
        glob = llvm.NextGlobal(glob)
    if plans:
        i8, i64 = llvm.Int8Ty(ctx), llvm.Int64Ty(ctx)
        builder = llvm.CreateBuilder(ctx)
        first = llvm.FirstInstruction(llvm.EntryBlock(entry_fn))
        while first and llvm.IsAAllocaInst(first):
            first = llvm.NextInstruction(first)
        if not first:
            raise PassError("main has an empty entry block")
        llvm.PositionBefore(builder, first)
        for glob, ty, size, stores in plans:
            llvm.SetInitializer(glob, llvm.ConstNull(ty))
            for offset, value, width, align in stores:
                index = (P * 1)(llvm.ConstInt(i64, offset, 0))
                address = llvm.BuildGEP2(builder, i8, glob, index, 1, b"")
                store = llvm.BuildStore(builder, value, address)
                llvm.SetAlignment(store, align)
                summary["stored_bytes"] += width
            summary["zero_filled_globals"] += 1
            summary["zero_filled_bytes"] += size
    llvm.save(mod, output)
    return summary


ERROR_NAME_TABLE = b"__zig_error_name_table"
ZEXT = 31


def _users(llvm: Llvm, value) -> list:
    out = []
    use = llvm.FirstUse(value)
    while use:
        out.append(llvm.GetUser(use))
        use = llvm.NextUse(use)
    return out


def _error_names(llvm: Llvm, td, table) -> list[bytes]:
    """Each entry's name: Zig fills the table with (pointer, length) pairs
    into NUL-terminated strings, and leaves entry 0 undefined."""
    ty = llvm.GlobalValueType(table)
    initializer = llvm.GetInitializer(table)
    if (
        llvm.IsDeclaration(table)
        or not llvm.IsGlobalConstant(table)
        or llvm.GetLinkage(table) not in (INTERNAL_LINKAGE, PRIVATE_LINKAGE)
        or not initializer
        or llvm.TypeKind(ty) != ARRAY
        or llvm.ABISize(td, llvm.ElementType(ty)) != 16
    ):
        raise _Skip("unexpected error name table")
    names = []
    for i in range(llvm.ArrayLen(ty)):
        entry = llvm.AggElem(initializer, i)
        if not entry:
            raise _Skip("unreadable error name entry")
        if llvm.IsUndef(entry):
            names.append(b"")
            continue
        pointer, length = llvm.AggElem(entry, 0), llvm.AggElem(entry, 1)
        string = llvm.IsAGlobalValue(pointer) if pointer else None
        if not string or not length or not llvm.IsAConstantInt(length) or not llvm.IsGlobalConstant(string):
            raise _Skip("error name entry is not a string and length")
        data = llvm.GetInitializer(string)
        if not data or not llvm.IsAConstantDataSequential(data):
            raise _Skip("error name is not constant bytes")
        size = C.c_size_t()
        raw = C.string_at(llvm.GetAsString(data, C.byref(size)), size.value)
        count = llvm.ConstZExt(length)
        if count >= len(raw) or raw[count] != 0:
            raise _Skip("error name is not NUL-terminated")
        names.append(raw[:count])
    return names


def _passes_to_reader(llvm: Llvm, call, entry) -> bool:
    """Whether `call` passes `entry` only as arguments of a function defined in
    the module that only reads them, like the pair copies the IR outliner
    makes. The callee is left unchanged."""
    callee = llvm.IsAFunction(llvm.CalledValue(call))
    if not callee or llvm.IsDeclaration(callee):
        return False
    # The called function is a call's last operand.
    arguments = llvm.NumOperands(call) - 1
    if arguments != llvm.CountParams(callee):
        return False
    passed = False
    for i in range(arguments):
        if llvm.GetOperand(call, i) == entry:
            passed = True
            try:
                _entry_reads(llvm, llvm.GetParam(callee, i), allow_phi=False, allow_calls=False)
            except _Skip:
                return False
    return passed


def _entry_reads(llvm: Llvm, entry, allow_phi: bool, allow_calls: bool = True) -> tuple[list, list, list, list, list]:
    """The loads of an entry's name pointer and length, the length-field
    addresses, the PHIs that merge entries, and the calls that pass the entry
    to a function that only reads it. Anything else stops the pass."""
    name_loads, length_loads, length_fields, phis, calls = [], [], [], [], []
    for user in _users(llvm, entry):
        if llvm.IsALoadInst(user) and llvm.TypeKind(llvm.TypeOf(user)) == POINTER:
            name_loads.append(user)
        elif llvm.IsAGEPInst(user) and llvm.NumOperands(user) == 2 and llvm.GetOperand(user, 0) == entry:
            source, offset = llvm.GEPSourceType(user), llvm.GetOperand(user, 1)
            if (
                llvm.TypeKind(source) != INTEGER
                or llvm.IntWidth(source) != 8
                or not llvm.IsAConstantInt(offset)
                or llvm.ConstZExt(offset) != 8
            ):
                raise _Skip("error name entry read at an unexpected offset")
            for load in _users(llvm, user):
                ty = llvm.TypeOf(load)
                if not llvm.IsALoadInst(load) or llvm.TypeKind(ty) != INTEGER or llvm.IntWidth(ty) != 64:
                    raise _Skip("error name length used other than by a load")
                length_loads.append(load)
            length_fields.append(user)
        elif allow_phi and llvm.IsAPHINode(user):
            phis.append(user)
        elif allow_calls and llvm.IsACallInst(user) and _passes_to_reader(llvm, user, entry):
            if user not in calls:
                calls.append(user)
        else:
            raise _Skip("error name entry used other than by reading it")
    return name_loads, length_loads, length_fields, phis, calls


def _error_name_function(llvm: Llvm, ctx, mod, names: list[bytes]):
    """`pgso.error_name(index)` returns the same (pointer, length) pair as the
    table entry. The names share one blob, each still NUL-terminated, and an
    entry's length is the distance to the next name minus its NUL."""
    i8, i64 = llvm.Int8Ty(ctx), llvm.Int64Ty(ctx)
    blob = b"".join(name + b"\x00" for name in names)
    offsets = [0]
    for name in names:
        offsets.append(offsets[-1] + len(name) + 1)
    width = llvm.Int16Ty(ctx) if offsets[-1] < 1 << 16 else llvm.Int32Ty(ctx)
    values = (P * len(offsets))(*[llvm.ConstInt(width, offset, 0) for offset in offsets])
    offset_table = llvm.AddGlobal(mod, llvm.ArrayType2(width, len(offsets)), b"pgso.error_name_offsets")
    llvm.SetInitializer(offset_table, llvm.ConstArray2(width, values, len(offsets)))
    blob_global = llvm.AddGlobal(mod, llvm.ArrayType2(i8, len(blob)), b"pgso.error_names")
    llvm.SetInitializer(blob_global, llvm.ConstString(ctx, blob, len(blob), 1))
    for glob in (offset_table, blob_global):
        llvm.SetGlobalConstant(glob, 1)
        llvm.SetLinkage(glob, INTERNAL_LINKAGE)
        llvm.SetUnnamedAddress(glob, GLOBAL_UNNAMED_ADDR)

    pointer = llvm.PointerType(ctx, 0)
    pair = llvm.StructType(ctx, (P * 2)(pointer, i64), 2, 0)
    fn_type = llvm.FunctionType(pair, (P * 1)(i64), 1, 0)
    fn = llvm.AddFunction(mod, b"pgso.error_name", fn_type)
    llvm.SetLinkage(fn, INTERNAL_LINKAGE)
    for attribute in ("noinline", "minsize", "optsize", "nounwind"):
        llvm.AddAttr(fn, FUNCTION_INDEX, llvm.CreateEnumAttr(ctx, llvm.kind(attribute), 0))
    builder = llvm.CreateBuilder(ctx)
    llvm.PositionAtEnd(builder, llvm.AppendBlock(ctx, fn, b"entry"))
    index = llvm.GetParam(fn, 0)
    start_at = llvm.BuildGEP2(builder, width, offset_table, (P * 1)(index), 1, b"")
    end_at = llvm.BuildGEP2(builder, width, start_at, (P * 1)(llvm.ConstInt(i64, 1, 0)), 1, b"")
    start = llvm.BuildCast(builder, ZEXT, llvm.BuildLoad2(builder, width, start_at, b""), i64, b"")
    end = llvm.BuildCast(builder, ZEXT, llvm.BuildLoad2(builder, width, end_at, b""), i64, b"")
    name = llvm.BuildGEP2(builder, i8, blob_global, (P * 1)(start), 1, b"")
    length = llvm.BuildSub(builder, llvm.BuildSub(builder, end, start, b""), llvm.ConstInt(i64, 1, 0), b"")
    result = llvm.BuildInsertValue(builder, llvm.GetPoison(pair), name, 0, b"")
    result = llvm.BuildInsertValue(builder, result, length, 1, b"")
    llvm.BuildRet(builder, result)
    return fn, fn_type


def compact_error_names(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    """Reads error names through one function over a compact table.

    Zig's `__zig_error_name_table` holds a 16-byte (pointer, length) entry
    per error and is read in place at every `@errorName`, so its pointers
    keep it in relocated data. Each read becomes a call to
    `pgso.error_name`, which returns the same pair from 16-bit offsets into
    one blob of the same NUL-terminated names. Where a PHI merges an entry's
    address with another pointer, or a call passes it to a function that only
    reads it, the pair goes to a stack slot laid out like the entry, and the
    PHI or call carries the slot. Any table entry or use the pass does not
    recognize leaves the module unchanged."""
    ctx, mod = llvm.load(source)
    td = llvm.CreateTD(llvm.GetDL(mod))
    summary = {"pass": "compact-error-names", "rewritten_reads": 0, "spilled_reads": 0, "names": 0}
    table = llvm.GetNamedGlobal(mod, ERROR_NAME_TABLE)
    try:
        if not table:
            raise _Skip("no error name table")
        names = _error_names(llvm, td, table)
        plans, phis = [], {}
        for user in _users(llvm, table):
            if not llvm.IsAGEPInst(user) or llvm.NumOperands(user) != 2 or llvm.GetOperand(user, 0) != table:
                raise _Skip("error name table used other than by indexing it")
            index = llvm.GetOperand(user, 1)
            index_type = llvm.TypeOf(index)
            if llvm.ABISize(td, llvm.GEPSourceType(user)) != 16 or llvm.TypeKind(index_type) != INTEGER or llvm.IntWidth(index_type) != 64:
                raise _Skip("unexpected error name index")
            reads = _entry_reads(llvm, user, allow_phi=True)
            plans.append((user, index, reads))
            for phi in reads[3]:
                phis[phi] = None
        for phi in phis:
            # The merged pointer must itself be read only as an entry.
            _entry_reads(llvm, phi, allow_phi=False)
    except _Skip as reason:
        llvm.save(mod, output)
        summary["skipped"] = str(reason)
        return summary

    fn, fn_type = _error_name_function(llvm, ctx, mod, names)
    builder = llvm.CreateBuilder(ctx)
    i8, i64 = llvm.Int8Ty(ctx), llvm.Int64Ty(ctx)
    pair = llvm.StructType(ctx, (P * 2)(llvm.PointerType(ctx, 0), i64), 2, 0)

    def new_slot(inst):
        entry_block = llvm.EntryBlock(llvm.BlockParent(llvm.InstParent(inst)))
        llvm.PositionBefore(builder, llvm.FirstInstruction(entry_block))
        slot = llvm.BuildAlloca(builder, pair, b"")
        llvm.SetAlignment(slot, 8)
        return slot

    def store_pair(slot, name, length):
        llvm.SetAlignment(llvm.BuildStore(builder, name, slot), 8)
        length_at = llvm.BuildGEP2(builder, i8, slot, (P * 1)(llvm.ConstInt(i64, 8, 0)), 1, b"")
        llvm.SetAlignment(llvm.BuildStore(builder, length, length_at), 8)

    slots = {phi: new_slot(phi) for phi in phis}
    for gep, index, (name_loads, length_loads, length_fields, gep_phis, gep_calls) in plans:
        call_slot = new_slot(gep) if gep_calls else None
        llvm.PositionBefore(builder, gep)
        call = llvm.BuildCall2(builder, fn_type, fn, (P * 1)(index), 1, b"")
        name = llvm.BuildExtractValue(builder, call, 0, b"")
        length = llvm.BuildExtractValue(builder, call, 1, b"")
        for load in name_loads:
            llvm.ReplaceAllUses(load, name)
            llvm.Erase(load)
        for load in length_loads:
            llvm.ReplaceAllUses(load, length)
            llvm.Erase(load)
        for field in length_fields:
            llvm.Erase(field)
        for phi in gep_phis:
            slot = slots[phi]
            store_pair(slot, name, length)
            for k in range(llvm.CountIncoming(phi)):
                if llvm.IncomingValue(phi, k) == gep:
                    llvm.SetOperand(phi, k, slot)
            summary["spilled_reads"] += 1
        if call_slot is not None:
            store_pair(call_slot, name, length)
            for passing in gep_calls:
                for k in range(llvm.NumOperands(passing) - 1):
                    if llvm.GetOperand(passing, k) == gep:
                        llvm.SetOperand(passing, k, call_slot)
            summary["spilled_reads"] += 1
        if name_loads or length_loads:
            summary["rewritten_reads"] += 1
        llvm.Erase(gep)
    summary["names"] = len(names)
    llvm.save(mod, output)
    return summary


def _instructions(llvm: Llvm, fn):
    block = llvm.FirstBlock(fn)
    while block:
        inst = llvm.FirstInstruction(block)
        while inst:
            following = llvm.NextInstruction(inst)
            yield inst
            inst = following
        block = llvm.NextBlock(block)


def _expandable_operands(llvm: Llvm, inst) -> range:
    count = llvm.NumOperands(inst)
    if llvm.IsAPHINode(inst) or llvm.IsALandingPad(inst) or llvm.IsAIntrinsic(inst):
        return range(0)
    if llvm.IsACallInst(inst) or llvm.IsAInvoke(inst) or llvm.IsACallBr(inst):
        # The last operand is the callee.
        return range(count - 1)
    return range(count)


def _rebuild(llvm: Llvm, builder, expression, before, summary: dict):
    """An instruction before `before` computing `expression`, or None when its
    opcode is not one this pass rebuilds. The builder folds an instruction
    whose operands are all constants back into an expression, so each one is
    built on a frozen placeholder and then given the constant."""
    opcode = llvm.ConstOpcode(expression)
    if opcode != GET_ELEMENT_PTR and opcode not in CASTS:
        summary["kept_expressions"] += 1
        return None
    operands = []
    for i in range(llvm.NumOperands(expression)):
        operand = llvm.GetOperand(expression, i)
        if llvm.IsAConstantExpr(operand):
            operand = _rebuild(llvm, builder, operand, before, summary) or operand
        operands.append(operand)
    llvm.PositionBefore(builder, before)
    placeholder = llvm.BuildFreeze(builder, operands[0], b"")
    if opcode == GET_ELEMENT_PTR:
        indices = (P * (len(operands) - 1))(*operands[1:])
        inst = llvm.BuildGEPNoWrap(
            builder,
            llvm.GEPSourceType(expression),
            placeholder,
            indices,
            len(operands) - 1,
            b"pgso.expr",
            llvm.GEPNoWrapFlags(expression),
        )
    else:
        inst = llvm.BuildCast(builder, opcode, placeholder, llvm.TypeOf(expression), b"pgso.expr")
    if not inst or inst == placeholder:
        raise PassError(f"constant expression with opcode {opcode} did not become an instruction")
    llvm.SetOperand(inst, 0, operands[0])
    llvm.Erase(placeholder)
    summary["rebuilt_instructions"] += 1
    return inst


def expand_constant_exprs(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    ctx, mod = llvm.load(source)
    builder = llvm.CreateBuilder(ctx)
    summary = {"pass": "expand-constant-exprs", "rewritten_operands": 0, "rebuilt_instructions": 0, "kept_expressions": 0}
    fn = llvm.FirstFunction(mod)
    while fn:
        if not llvm.IsDeclaration(fn):
            for inst in _instructions(llvm, fn):
                for index in _expandable_operands(llvm, inst):
                    operand = llvm.GetOperand(inst, index)
                    if not llvm.IsAConstantExpr(operand):
                        continue
                    rebuilt = _rebuild(llvm, builder, operand, inst, summary)
                    if rebuilt:
                        llvm.SetOperand(inst, index, rebuilt)
                        summary["rewritten_operands"] += 1
        fn = llvm.NextFunction(fn)
    llvm.save(mod, output)
    return summary


def _swapped_compare(llvm: Llvm, builder, inst):
    """The less-than form of `inst` before it, or None when `inst` is not a
    greater-than comparison."""
    if llvm.IsAICmpInst(inst):
        predicate = SWAPPED_INT_PREDICATES.get(llvm.ICmpPredicate(inst))
        build = llvm.BuildICmp
    elif llvm.IsAFCmpInst(inst):
        predicate = SWAPPED_REAL_PREDICATES.get(llvm.FCmpPredicate(inst))
        build = llvm.BuildFCmp
    else:
        return None
    if predicate is None:
        return None
    llvm.PositionBefore(builder, inst)
    swapped = build(builder, predicate, llvm.GetOperand(inst, 1), llvm.GetOperand(inst, 0), b"")
    if llvm.IsAICmpInst(swapped):
        llvm.SetICmpSameSign(swapped, llvm.ICmpSameSign(inst))
    elif llvm.IsAFCmpInst(swapped):
        llvm.SetFastMathFlags(swapped, llvm.FastMathFlags(inst))
    else:
        # The builder folded two constants into one.
        return swapped
    location = llvm.DebugLoc(inst)
    if location:
        llvm.SetDebugLoc(swapped, location)
    return swapped


def swap_compares(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    ctx, mod = llvm.load(source)
    builder = llvm.CreateBuilder(ctx)
    summary = {"pass": "swap-compares", "swapped_compares": 0}
    fn = llvm.FirstFunction(mod)
    while fn:
        if not llvm.IsDeclaration(fn):
            for inst in _instructions(llvm, fn):
                swapped = _swapped_compare(llvm, builder, inst)
                if swapped is None:
                    continue
                name = llvm.name(inst).encode()
                llvm.ReplaceAllUses(inst, swapped)
                llvm.Erase(inst)
                if name and llvm.IsAInstruction(swapped):
                    llvm.SetValueName2(swapped, name, len(name))
                summary["swapped_compares"] += 1
        fn = llvm.NextFunction(fn)
    llvm.save(mod, output)
    return summary


def _widenable_operands(llvm: Llvm, inst) -> range:
    """The operands of `inst` that the IR outliner could turn into parameters
    and that may hold a value other than a constant."""
    if (
        # A trunc for a PHI's incoming constant would sit in the incoming
        # block, and where that block is in a region and the PHI is not, the
        # outliner can drop the region's store of the PHI's value.
        llvm.IsAPHINode(inst)
        or llvm.IsALandingPad(inst)
        or llvm.IsAAllocaInst(inst)
        # The outliner only matches GEPs with equal indices, and struct
        # indices must stay constant.
        or llvm.IsAGEPInst(inst)
        # Switch cases must stay constant. Other terminators but `br` never
        # join a region.
        or (llvm.IsATerminator(inst) and not llvm.IsABranch(inst))
    ):
        return range(0)
    if not llvm.IsACallInst(inst):
        return range(llvm.NumOperands(inst))
    callee = llvm.CalledValue(inst)
    if llvm.IsAInlineAsm(callee):
        # An inline asm operand may need an immediate.
        return range(0)
    if llvm.IsAIntrinsic(inst) and llvm.name(callee).startswith(ASSUME_LIKE_INTRINSICS):
        return range(0)
    return range(llvm.NumArgOperands(inst))


def _wide_constant(llvm: Llvm, ctx, constant):
    """The wider constant `constant` is rebuilt from, or None when it is not
    an i1 or i16 integer."""
    if not llvm.IsAConstantInt(constant):
        return None
    width = WIDENED_WIDTHS.get(llvm.IntWidth(llvm.TypeOf(constant)))
    if width is None:
        return None
    return llvm.ConstInt(llvm.IntTy(ctx, width), llvm.ConstZExt(constant), 0)


def _truncated(llvm: Llvm, builder, wide, narrow_type, before):
    """`trunc wide to narrow_type` as an instruction before `before`."""
    llvm.PositionBefore(builder, before)
    # The builder folds a cast of a constant, so cast a placeholder.
    placeholder = llvm.BuildFreeze(builder, wide, b"")
    inst = llvm.BuildCast(builder, TRUNC, placeholder, narrow_type, b"pgso.wide")
    llvm.SetOperand(inst, 0, wide)
    llvm.Erase(placeholder)
    return inst


def widen_constants(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    ctx, mod = llvm.load(source)
    builder = llvm.CreateBuilder(ctx)
    immarg = llvm.kind("immarg")
    summary = {"pass": "widen-constants", "widened_operands": 0}
    fn = llvm.FirstFunction(mod)
    while fn:
        if not llvm.IsDeclaration(fn):
            for inst in _instructions(llvm, fn):
                callee = llvm.CalledValue(inst) if llvm.IsAIntrinsic(inst) else None
                for index in _widenable_operands(llvm, inst):
                    if callee is not None and llvm.GetEnumAttrAt(callee, index + 1, immarg):
                        continue
                    constant = llvm.GetOperand(inst, index)
                    wide = _wide_constant(llvm, ctx, constant)
                    if wide is None:
                        continue
                    llvm.SetOperand(inst, index, _truncated(llvm, builder, wide, llvm.TypeOf(constant), inst))
                    summary["widened_operands"] += 1
        fn = llvm.NextFunction(fn)
    llvm.save(mod, output)
    return summary


def _holds_parameter(llvm: Llvm, expression) -> bool:
    for i in range(llvm.NumOperands(expression)):
        operand = llvm.GetOperand(expression, i)
        if not llvm.IsConstant(operand):
            return True
        if llvm.IsAConstantExpr(operand) and _holds_parameter(llvm, operand):
            return True
    return False


def _unreachable_blocks(llvm: Llvm, fn) -> list[tuple[str, bool]]:
    """The non-entry blocks of `fn` that no terminator branches to, each with
    whether it stores through one of `fn`'s parameters."""
    blocks, targets = [], set()
    block = llvm.FirstBlock(fn)
    while block:
        blocks.append(block)
        terminator = llvm.BlockTerminator(block)
        if terminator:
            for index in range(llvm.NumSuccessors(terminator)):
                targets.add(llvm.Successor(terminator, index))
        block = llvm.NextBlock(block)
    found = []
    for position, block in enumerate(blocks[1:], start=1):
        if block in targets:
            continue
        stores = False
        inst = llvm.FirstInstruction(block)
        while inst:
            if llvm.IsAStoreInst(inst) and llvm.IsAArgument(llvm.GetOperand(inst, 1)):
                stores = True
            inst = llvm.NextInstruction(inst)
        name = llvm.BlockName(block)
        found.append((name.decode("utf-8", "replace") if name else f"#{position}", stores))
    return found


def _callers(llvm: Llvm, fn) -> list[str]:
    return sorted({
        llvm.name(llvm.BlockParent(llvm.InstParent(user)))
        for user in _users(llvm, fn)
        if llvm.IsAInstruction(user)
    })


def _dropped_outputs(llvm: Llvm, mod) -> tuple[int, list[dict]]:
    """The number of outlined functions in `mod`, and those with a non-entry
    block that nothing branches to.

    The IR outliner leaves such blocks when two regions store the same
    outputs in two different ways, which needs a switch it only builds when
    the stored outputs differ. The blocks hold the stores of the region's
    outputs, so those stores never run and each caller reads its output slot
    uninitialized. Nothing else the outliner or CodeExtractor builds is
    unreachable.
    """
    count, instances = 0, []
    fn = llvm.FirstFunction(mod)
    while fn:
        name = llvm.name(fn)
        if not llvm.IsDeclaration(fn) and name.startswith(OUTLINED_PREFIX):
            count += 1
            blocks = _unreachable_blocks(llvm, fn)
            if blocks:
                instances.append({
                    "function": name,
                    "blocks": [block for block, _ in blocks],
                    "stores_to_parameter": any(stores for _, stores in blocks),
                    "callers": _callers(llvm, fn),
                })
        fn = llvm.NextFunction(fn)
    return count, instances


def dropped_outputs(llvm: Llvm, source: pathlib.Path) -> dict:
    _, mod = llvm.load(source)
    count, instances = _dropped_outputs(llvm, mod)
    return {
        "pass": "dropped-outputs",
        "outlined_functions": count,
        "instances": instances,
        "callers": sorted({caller for instance in instances for caller in instance["callers"]}),
    }


def check_outlined(llvm: Llvm, source: pathlib.Path) -> dict:
    _, mod = llvm.load(source)
    summary = {"pass": "check-outlined", "outlined_functions": 0}
    findings = []
    fn = llvm.FirstFunction(mod)
    while fn:
        name = llvm.name(fn)
        if not llvm.IsDeclaration(fn) and name.startswith(OUTLINED_PREFIX):
            summary["outlined_functions"] += 1
            for inst in _instructions(llvm, fn):
                if llvm.name(inst).startswith("constexpr"):
                    findings.append(f"{name}: rebuilt constant expression {llvm.name(inst)}")
                if llvm.IsAReturn(inst) and llvm.NumOperands(inst) and not llvm.IsConstant(llvm.GetOperand(inst, 0)):
                    findings.append(f"{name}: exit selector replaced by a parameter")
                for index in range(llvm.NumOperands(inst)):
                    operand = llvm.GetOperand(inst, index)
                    if llvm.IsAConstantExpr(operand) and _holds_parameter(llvm, operand):
                        findings.append(f"{name}: constant expression with a parameter operand")
        fn = llvm.NextFunction(fn)
    for instance in _dropped_outputs(llvm, mod)[1]:
        findings.append(
            f"{instance['function']}: output stores in blocks with no predecessors "
            f"({', '.join(instance['blocks'])}), called from {', '.join(instance['callers']) or 'nothing'}"
        )
    if findings:
        raise PassError(
            "IR outliner miscompiled an outlined function: "
            + "; ".join(findings[:8])
            + ". scripts/pgso/README.md describes each case; a caller can be kept out of outlining with no-outline"
        )
    return summary


def minsize_functions(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    """Write the defined functions, and those marked `minsize`, to `output`.

    Profile use marks the functions it judges cold `minsize`. The lists go to
    a file because a whole program's names outgrow captured output.
    """
    _, mod = llvm.load(source)
    minsize = llvm.kind("minsize")
    defined: list[str] = []
    small: list[str] = []
    fn = llvm.FirstFunction(mod)
    while fn:
        if not llvm.IsDeclaration(fn):
            name = llvm.name(fn)
            defined.append(name)
            if llvm.GetEnumAttrAt(fn, FUNCTION_INDEX, minsize):
                small.append(name)
        fn = llvm.NextFunction(fn)
    output.write_text(
        json.dumps({"defined": sorted(defined), "minsize": sorted(small)}, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return {"pass": "minsize-functions", "defined_functions": len(defined), "minsize_functions": len(small)}


def no_outline(llvm: Llvm, source: pathlib.Path, output: pathlib.Path, functions: pathlib.Path) -> dict:
    names = {line.strip() for line in functions.read_text(encoding="utf-8").splitlines() if line.strip()}
    ctx, mod = llvm.load(source)
    marked = 0
    fn = llvm.FirstFunction(mod)
    while fn:
        if not llvm.IsDeclaration(fn) and llvm.name(fn) in names:
            llvm.AddAttr(fn, FUNCTION_INDEX, llvm.CreateStringAttr(ctx, b"nooutline", 9, b"", 0))
            marked += 1
        fn = llvm.NextFunction(fn)
    if marked == 0:
        raise PassError(f"no function listed in {functions} is defined")
    llvm.save(mod, output)
    return {"pass": "no-outline", "listed_functions": len(names), "marked_functions": marked}


def name_functions(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    ctx, mod = llvm.load(source)
    named = 0
    fn = llvm.FirstFunction(mod)
    while fn:
        if not llvm.IsDeclaration(fn) and llvm.GetLinkage(fn) == PRIVATE_LINKAGE:
            llvm.SetLinkage(fn, INTERNAL_LINKAGE)
            named += 1
        fn = llvm.NextFunction(fn)
    llvm.save(mod, output)
    return {"pass": "name-functions", "named_functions": named}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--libllvm", required=True, type=pathlib.Path)
    parser.add_argument(
        "command",
        choices=(
            "outline-helpers",
            "sparse-constants",
            "overlay-constants",
            "zero-fill-globals",
            "compact-error-names",
            "expand-constant-exprs",
            "swap-compares",
            "widen-constants",
            "check-outlined",
            "dropped-outputs",
            "minsize-functions",
            "no-outline",
            "name-functions",
        ),
    )
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path, nargs="?")
    parser.add_argument("--functions", type=pathlib.Path)
    args = parser.parse_args(argv)
    if (args.output is None) != (args.command in ("check-outlined", "dropped-outputs")):
        parser.error("check-outlined and dropped-outputs take only an input; the other commands need an output")
    if (args.functions is None) == (args.command == "no-outline"):
        parser.error("--functions goes with no-outline, and only with it")
    try:
        llvm = Llvm(args.libllvm)
        if args.command == "check-outlined":
            summary = check_outlined(llvm, args.source)
        elif args.command == "dropped-outputs":
            summary = dropped_outputs(llvm, args.source)
        elif args.command == "no-outline":
            summary = no_outline(llvm, args.source, args.output, args.functions)
        else:
            run = {
                "outline-helpers": outline_helpers,
                "sparse-constants": sparse_constants,
                "overlay-constants": overlay_constants,
                "zero-fill-globals": zero_fill_globals,
                "compact-error-names": compact_error_names,
                "expand-constant-exprs": expand_constant_exprs,
                "swap-compares": swap_compares,
                "widen-constants": widen_constants,
                "minsize-functions": minsize_functions,
                "name-functions": name_functions,
            }[args.command]
            summary = run(llvm, args.source, args.output)
    except (OSError, PassError) as error:
        sys.stderr.write(f"ir_size: {error}\n")
        return 1
    sys.stdout.write(json.dumps(summary, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
