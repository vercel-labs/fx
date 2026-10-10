#!/usr/bin/env python3
"""Size passes for PGSO bitcode, run through the pinned LLVM C library.

    ir_size.py --libllvm <libLLVM.dylib> outline-helpers <in.bc> <out.bc>
    ir_size.py --libllvm <libLLVM.dylib> sparse-constants <in.bc> <out.bc>

outline-helpers marks small shared std helpers as noinline: the allocator's
slice free, remap, and aligned allocation, the writer's write, writeAll, and
allocating writer setup and teardown, and the byte list's append and
teardown. Zig inlines them at thousands of call sites (free alone at about
11,000 in fx); one out-of-line copy per instantiation keeps the same checks,
poisoning, and calls. Run it on the emitted bitcode, before instrumentation,
so training and profile use see the same inlining.

sparse-constants rewrites copies from mostly undefined internal constants
into stores of their defined scalar leaves. Zig materializes `return error.X`
from a function returning a large `E!T` as a constant `{ T undef, code,
padding undef }` copied into the result. Copying undefined bytes is refined
by leaving the destination bytes unchanged, so only the defined bytes are
stored. Run `opt -passes=globaldce,verify` afterwards to drop dead constants.

Both commands print a JSON summary on stdout and exit nonzero when the input
cannot be read. outline-helpers also fails when no allocator free helper
matches, because that means std naming changed and the pass went stale.
"""
from __future__ import annotations

import argparse
import ctypes as C
import json
import pathlib
import re
import sys

OUT_OF_LINE_HELPERS = (
    r"mem\.Allocator\.free(?:__anon_\d+)?",
    r"mem\.Allocator\.(?:remap|allocBytesWithAlignment)__anon_\d+",
    r"Io\.Writer\.(?:writeAll|write|Allocating\.deinit|Allocating\.initCapacity)",
    r"array_list\.Aligned\(u8,null\)\.(?:appendSlice|deinit)",
)

MIN_CONSTANT_BYTES = 32
MAX_DEFINED_BYTES = 128
MAX_LEAVES = 16
MEMCPY_SITE_BYTES = 16
STORE_BYTES = 8

P = C.c_void_p
STRUCT, ARRAY, INTEGER, POINTER = 10, 11, 8, 12
FLOATS = (1, 2, 3)
INTERNAL_LINKAGE, PRIVATE_LINKAGE = 8, 9
FUNCTION_INDEX = 0xFFFFFFFF


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
        self.SetAlignment = f("LLVMSetAlignment", None, P, C.c_uint)
        self.Erase = f("LLVMInstructionEraseFromParent", None, P)
        self.EnumAttrKind = f("LLVMGetEnumAttributeKindForName", C.c_uint, C.c_char_p, C.c_size_t)
        self.CreateEnumAttr = f("LLVMCreateEnumAttribute", P, P, C.c_uint, C.c_ulonglong)
        self.AddAttr = f("LLVMAddAttributeAtIndex", None, P, C.c_uint, P)
        self.GetEnumAttrAt = f("LLVMGetEnumAttributeAtIndex", P, P, C.c_uint, C.c_uint)
        self.CallSiteEnumAttr = f("LLVMGetCallSiteEnumAttribute", P, P, C.c_uint, C.c_uint)
        self.EnumAttrValue = f("LLVMGetEnumAttributeValue", C.c_ulonglong, P)

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


def sparse_constants(llvm: Llvm, source: pathlib.Path, output: pathlib.Path) -> dict:
    ctx, mod = llvm.load(source)
    td = llvm.CreateTD(llvm.GetDL(mod))
    i8, i64 = llvm.Int8Ty(ctx), llvm.Int64Ty(ctx)
    builder = llvm.CreateBuilder(ctx)
    align_kind = llvm.kind("align")
    summary = {"pass": "sparse-constants", "rewritten_constants": 0, "rewritten_copies": 0, "constant_bytes": 0}
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
            leaves: list = []
            _leaves(llvm, td, init, 0, leaves)
            extra = 0
            for _, length in copies:
                if any(offset < length < offset + width for offset, _, width, _ in leaves):
                    raise _Skip("copy splits a defined leaf")
                inside = sum(1 for offset, _, width, _ in leaves if offset + width <= length)
                extra += max(0, STORE_BYTES * inside - MEMCPY_SITE_BYTES)
            if extra >= size:
                raise _Skip("stores would cost more than the constant")
            for call, length in copies:
                destination = llvm.GetOperand(call, 0)
                attribute = llvm.CallSiteEnumAttr(call, 1, align_kind)
                destination_align = llvm.EnumAttrValue(attribute) if attribute else 1
                llvm.PositionBefore(builder, call)
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
        except _Skip:
            pass
        glob = following
    llvm.save(mod, output)
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--libllvm", required=True, type=pathlib.Path)
    parser.add_argument("command", choices=("outline-helpers", "sparse-constants"))
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("output", type=pathlib.Path)
    args = parser.parse_args(argv)
    try:
        llvm = Llvm(args.libllvm)
        run = outline_helpers if args.command == "outline-helpers" else sparse_constants
        summary = run(llvm, args.source, args.output)
    except (OSError, PassError) as error:
        sys.stderr.write(f"ir_size: {error}\n")
        return 1
    sys.stdout.write(json.dumps(summary, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
