from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

from scripts.pgso.pipeline import _require_bitcode_header
from scripts.pgso.toolchain import IR_SIZE_SCRIPT

LLVM_BIN = pathlib.Path(os.environ.get("FX_PGSO_LLVM_BIN", "/opt/homebrew/opt/llvm@22/bin"))
LIBLLVM = (LLVM_BIN.parent / "lib" / ("libLLVM.dylib" if sys.platform == "darwin" else "libLLVM.so")).resolve()
AVAILABLE = (LLVM_BIN / "llvm-as").is_file() and LIBLLVM.is_file()

# The production module layout; alignment decisions depend on it.
TARGET = (
    'target datalayout = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"\n'
    'target triple = "aarch64-apple-macosx15.0.0-unknown"\n'
)
MEMCPY = "declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)\n"
ERROR_UNION = (
    "%Payload = type { [64 x i8] }\n"
    "@error_return = internal unnamed_addr constant { %Payload, i16, [6 x i8] } "
    "{ %Payload undef, i16 653, [6 x i8] undef }, align 8\n"
)


class LlvmCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(prefix="fx-pgso-ir-size-")
        self.root = pathlib.Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def assemble(self, name: str, ir: str) -> pathlib.Path:
        source = self.root / f"{name}.ll"
        source.write_text(TARGET + ir)
        output = self.root / f"{name}.bc"
        subprocess.run([str(LLVM_BIN / "llvm-as"), str(source), "-o", str(output)], check=True)
        return output

    def run_pass(self, command: str, source: pathlib.Path) -> tuple[subprocess.CompletedProcess, pathlib.Path]:
        output = self.root / f"{source.stem}.{command}.bc"
        result = subprocess.run(
            [sys.executable, str(IR_SIZE_SCRIPT), "--libllvm", str(LIBLLVM), command, str(source), str(output)],
            capture_output=True,
            text=True,
        )
        return result, output

    def cleaned_ir(self, bitcode: pathlib.Path) -> str:
        cleaned = self.root / f"{bitcode.stem}.clean.bc"
        subprocess.run(
            [str(LLVM_BIN / "opt"), "-passes=globaldce,verify", str(bitcode), "-o", str(cleaned)],
            check=True,
        )
        return subprocess.run(
            [str(LLVM_BIN / "llvm-dis"), str(cleaned), "-o", "-"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout


@unittest.skipUnless(AVAILABLE, "pinned LLVM 21 with libLLVM is not installed")
class IrSizeTests(LlvmCase):
    def test_error_union_return_copy_becomes_one_code_store(self) -> None:
        source = self.assemble(
            "error_union",
            ERROR_UNION + MEMCPY + "define void @fail(ptr align 8 %out) {\n"
            "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @error_return, i64 72, i1 false)\n"
            "  ret void\n}\n",
        )
        result, output = self.run_pass("sparse-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("", result.stderr)
        self.assertIn('"rewritten_copies": 1', result.stdout)
        ir = self.cleaned_ir(output)
        self.assertNotIn("llvm.memcpy.p0.p0.i64(ptr", ir.split("declare")[0])
        self.assertNotIn("@error_return", ir)
        self.assertIn("getelementptr inbounds i8, ptr %out, i64 64", ir)
        self.assertIn("store i16 653, ptr", ir)
        self.assertTrue(ir.split("store i16 653")[1].splitlines()[0].endswith("align 2"))

    def test_defined_zero_bytes_are_still_stored(self) -> None:
        source = self.assemble(
            "zeros",
            "@state = internal unnamed_addr constant { i64, [56 x i8] } { i64 0, [56 x i8] undef }\n"
            + MEMCPY
            + "define void @init(ptr align 8 %out) {\n"
            "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @state, i64 64, i1 false)\n"
            "  ret void\n}\n",
        )
        result, output = self.run_pass("sparse-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("store i64 0, ptr %out, align 8", self.cleaned_ir(output))

    def test_constants_with_other_uses_or_unsafe_copies_are_untouched(self) -> None:
        cases = {
            "loaded": "  %v = load i16, ptr getelementptr inbounds (i8, ptr @error_return, i64 64)\n"
            "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @error_return, i64 72, i1 false)\n",
            "volatile": "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @error_return, i64 72, i1 true)\n",
            "split_leaf": "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @error_return, i64 65, i1 false)\n",
            "variable": "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @error_return, i64 %n, i1 false)\n",
        }
        for name, body in cases.items():
            with self.subTest(case=name):
                source = self.assemble(
                    name,
                    ERROR_UNION + MEMCPY + f"define void @f(ptr align 8 %out, i64 %n) {{\n{body}  ret void\n}}\n",
                )
                result, output = self.run_pass("sparse-constants", source)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn('"rewritten_copies": 0', result.stdout)
                self.assertIn("@error_return", self.cleaned_ir(output))

    def test_shared_std_helpers_become_noinline(self) -> None:
        cases = (
            ("mem.Allocator.free__func_12", True),
            ("mem.Allocator.free", True),
            ("mem.Allocator.remap__func_7", True),
            ("Io.Writer.writeAll", True),
            ("Io.Writer.writeByte", True),
            ('"array_list.Aligned(u8,null).deinit"', True),
            ('"array_list.Aligned(u16,null).deinit"', True),
            ('"array_list.Aligned(u8,null).append"', False),
            ("mem.eql__func_4", True),
            ("mem.eqlBytes", False),
            ("mem.startsWith__func_9", True),
            ("mem.startsWith", True),
            ("ascii.eqlIgnoreCase", True),
            ("ascii.startsWithIgnoreCase", False),
            ("Io.Mutex.lockUncancelable", True),
            ("Io.Mutex.unlock", True),
            ("Io.Mutex.tryLock", False),
            ("mem.Allocator.dupe", False),
        )
        body = "".join(f"define internal void @{name}(ptr %p) {{\n  ret void\n}}\n" for name, _ in cases)
        calls = "".join(f"  call void @{name}(ptr %p)\n" for name, _ in cases)
        source = self.assemble("helpers", body + f"define void @use(ptr %p) {{\n{calls}  ret void\n}}\n")
        result, output = self.run_pass("outline-helpers", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(f'"marked_functions": {sum(marked for _, marked in cases)}', result.stdout)
        # The pipeline validates this output before it records the identity.
        _require_bitcode_header(output)
        ir = subprocess.run(
            [str(LLVM_BIN / "llvm-dis"), str(output), "-o", "-"], check=True, capture_output=True, text=True
        ).stdout
        attributes = {
            line.split("=", 1)[0].strip(): line for line in ir.splitlines() if line.startswith("attributes #")
        }
        for name, expected in cases:
            definition = next(line for line in ir.splitlines() if line.startswith("define") and f"@{name}(" in line)
            group = definition.rsplit("#", 1)[1].split()[0] if "#" in definition else None
            marked = group is not None and "noinline" in attributes.get(f"attributes #{group}", "")
            self.assertEqual(expected, marked, definition)

    def test_helper_pass_fails_closed_without_the_allocator_free_helper(self) -> None:
        source = self.assemble(
            "no_free",
            "define internal void @Io.Writer.writeAll(ptr %p) {\n  ret void\n}\n"
            "define void @main(ptr %p) {\n  call void @Io.Writer.writeAll(ptr %p)\n  ret void\n}\n",
        )
        result, output = self.run_pass("outline-helpers", source)

        self.assertEqual(1, result.returncode)
        self.assertIn("no out-of-line helper matched", result.stderr)
        self.assertFalse(output.exists())


# A struct's default value, 1,064 bytes: 1,024 zero bytes, then an i32, a
# pointer, padding, and an i64. Its defined bytes are far past sparse-constants' leaf limits.
DEFAULT_VALUE = (
    "%Default = type { [128 x i64], i32, ptr, [3 x i32], i64 }\n"
    "@target = internal global i32 7\n"
    "@default = internal unnamed_addr constant %Default "
    "{ [128 x i64] zeroinitializer, i32 7, ptr @target, [3 x i32] zeroinitializer, i64 -1 }, align 8\n"
    + MEMCPY
    + "declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)\n"
)
# Fill a buffer with 0xAB, copy the default value over it, and exit 0 only
# when every zero word, the i32, the pointer, and the i64 read back.
DEFAULT_VALUE_MAIN = (
    "define i32 @main() {\n"
    "entry:\n"
    "  %out = alloca %Default, align 8\n"
    "  call void @llvm.memset.p0.i64(ptr align 8 %out, i8 171, i64 1064, i1 false)\n"
    "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @default, i64 1064, i1 false)\n"
    "  br label %loop\n"
    "loop:\n"
    "  %i = phi i64 [ 0, %entry ], [ %next, %zero ]\n"
    "  %slot = getelementptr inbounds [128 x i64], ptr %out, i64 0, i64 %i\n"
    "  %word = load i64, ptr %slot\n"
    "  %is_zero = icmp eq i64 %word, 0\n"
    "  br i1 %is_zero, label %zero, label %bad\n"
    "zero:\n"
    "  %next = add i64 %i, 1\n"
    "  %more = icmp ult i64 %next, 128\n"
    "  br i1 %more, label %loop, label %fields\n"
    "fields:\n"
    "  %code_slot = getelementptr inbounds %Default, ptr %out, i32 0, i32 1\n"
    "  %code = load i32, ptr %code_slot\n"
    "  %pointer_slot = getelementptr inbounds %Default, ptr %out, i32 0, i32 2\n"
    "  %pointer = load ptr, ptr %pointer_slot\n"
    "  %pad_slot = getelementptr inbounds %Default, ptr %out, i32 0, i32 3, i64 2\n"
    "  %pad = load i32, ptr %pad_slot\n"
    "  %tail_slot = getelementptr inbounds %Default, ptr %out, i32 0, i32 4\n"
    "  %tail = load i64, ptr %tail_slot\n"
    "  %code_ok = icmp eq i32 %code, 7\n"
    "  %pointer_ok = icmp eq ptr %pointer, @target\n"
    "  %pad_ok = icmp eq i32 %pad, 0\n"
    "  %tail_ok = icmp eq i64 %tail, -1\n"
    "  %a = and i1 %code_ok, %pointer_ok\n"
    "  %b = and i1 %pad_ok, %tail_ok\n"
    "  %ok = and i1 %a, %b\n"
    "  %status = select i1 %ok, i32 0, i32 2\n"
    "  ret i32 %status\n"
    "bad:\n"
    "  ret i32 1\n"
    "}\n"
)
# Copy only the first 1,048 bytes of the default value, which end inside its
# zero [3 x i32] and leave out its i64, over a buffer filled with 0xAB. Copy
# the same bytes of @reference, an external constant the pass leaves alone,
# over a second such buffer, and exit 0 only when the two buffers match byte
# for byte. The four padding bytes after the i32 (1,028 to 1,031) are
# undefined in both constants, and the interpreter leaves whatever memory held
# there, so the comparison skips them.
PARTIAL_COPY_MAIN = (
    "@reference = constant %Default "
    "{ [128 x i64] zeroinitializer, i32 7, ptr @target, [3 x i32] zeroinitializer, i64 -1 }, align 8\n"
    "define i32 @main() {\n"
    "entry:\n"
    "  %out = alloca %Default, align 8\n"
    "  %expected = alloca %Default, align 8\n"
    "  call void @llvm.memset.p0.i64(ptr align 8 %out, i8 171, i64 1064, i1 false)\n"
    "  call void @llvm.memset.p0.i64(ptr align 8 %expected, i8 171, i64 1064, i1 false)\n"
    "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @default, i64 1048, i1 false)\n"
    "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %expected, ptr align 8 @reference, i64 1048, i1 false)\n"
    "  br label %loop\n"
    "loop:\n"
    "  %i = phi i64 [ 0, %entry ], [ %next, %same ]\n"
    "  %out_byte = getelementptr inbounds i8, ptr %out, i64 %i\n"
    "  %expected_byte = getelementptr inbounds i8, ptr %expected, i64 %i\n"
    "  %got = load i8, ptr %out_byte\n"
    "  %want = load i8, ptr %expected_byte\n"
    "  %equal = icmp eq i8 %got, %want\n"
    "  %after_code = icmp uge i64 %i, 1028\n"
    "  %before_pointer = icmp ult i64 %i, 1032\n"
    "  %padding = and i1 %after_code, %before_pointer\n"
    "  %matches = or i1 %equal, %padding\n"
    "  br i1 %matches, label %same, label %bad\n"
    "same:\n"
    "  %next = add i64 %i, 1\n"
    "  %more = icmp ult i64 %next, 1064\n"
    "  br i1 %more, label %loop, label %ok\n"
    "ok:\n"
    "  ret i32 0\n"
    "bad:\n"
    "  ret i32 1\n"
    "}\n"
)


@unittest.skipUnless(AVAILABLE and (LLVM_BIN / "lli").is_file(), "pinned LLVM with libLLVM and lli is not installed")
class ZeroFilledCopyTests(LlvmCase):
    def exit_code(self, bitcode: pathlib.Path) -> int:
        # LLVM's interpreter runs the module the same way on any host.
        result = subprocess.run(
            [str(LLVM_BIN / "lli"), "--force-interpreter", str(bitcode)], capture_output=True, text=True
        )
        self.assertEqual("", result.stderr)
        return result.returncode

    def test_mostly_zero_default_value_copy_becomes_a_zero_fill_and_its_nonzero_stores(self) -> None:
        source = self.assemble(
            "default_value",
            DEFAULT_VALUE + "define void @init(ptr align 8 %out) {\n"
            "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @default, i64 1064, i1 false)\n"
            "  ret void\n}\n",
        )
        result, output = self.run_pass("sparse-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        summary = json.loads(result.stdout)
        self.assertEqual(1, summary["zero_filled_constants"])
        self.assertEqual(1, summary["rewritten_copies"])
        ir = self.cleaned_ir(output)
        self.assertNotIn("@default", ir)
        body = ir.split("define void @init", 1)[1].split("\n}", 1)[0]
        self.assertNotIn("llvm.memcpy", body)
        self.assertIn("call void @llvm.memset.p0.i64(ptr align 8 %out, i8 0, i64 1064, i1 false)", body)
        stores = [line.strip() for line in body.splitlines() if line.strip().startswith("store ")]
        self.assertEqual(3, len(stores), stores)
        self.assertTrue(any(store.startswith("store i32 7, ptr") for store in stores), stores)
        self.assertTrue(any(store.startswith("store ptr @target, ptr") for store in stores), stores)
        self.assertTrue(any(store.startswith("store i64 -1, ptr") for store in stores), stores)

    def test_zero_filled_copy_reads_back_the_constant(self) -> None:
        source = self.assemble("default_main", DEFAULT_VALUE + DEFAULT_VALUE_MAIN)
        self.assertEqual(0, self.exit_code(source))
        result, output = self.run_pass("sparse-constants", source)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(1, json.loads(result.stdout)["zero_filled_constants"])
        self.assertEqual(0, self.exit_code(output))

    def test_partial_zero_filled_copy_leaves_the_bytes_past_its_length(self) -> None:
        source = self.assemble("partial_copy", DEFAULT_VALUE + PARTIAL_COPY_MAIN)
        self.assertEqual(0, self.exit_code(source))
        result, output = self.run_pass("sparse-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(1, json.loads(result.stdout)["zero_filled_constants"])
        ir = self.cleaned_ir(output)
        self.assertIn("call void @llvm.memset.p0.i64(ptr align 8 %out, i8 0, i64 1048, i1 false)", ir)
        self.assertNotIn("store i64 -1", ir)
        self.assertEqual(0, self.exit_code(output))

    def test_dense_constant_keeps_its_copy(self) -> None:
        values = ", ".join(f"i64 {n + 1}" for n in range(65))
        source = self.assemble(
            "dense",
            "@dense = internal unnamed_addr constant { [65 x i64], [128 x i64] } "
            f"{{ [65 x i64] [{values}], [128 x i64] zeroinitializer }}, align 8\n"
            + MEMCPY
            + "define void @init(ptr align 8 %out) {\n"
            "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @dense, i64 1544, i1 false)\n"
            "  ret void\n}\n",
        )
        result, output = self.run_pass("sparse-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(0, json.loads(result.stdout)["rewritten_copies"])
        self.assertIn("@dense", self.cleaned_ir(output))

    def test_constants_within_the_leaf_limits_keep_leaf_stores_without_a_zero_fill(self) -> None:
        source = self.assemble(
            "small_default",
            "@small = internal unnamed_addr constant { i64, i64, [48 x i8] } { i64 0, i64 5, [48 x i8] undef }\n"
            + MEMCPY
            + "define void @init(ptr align 8 %out) {\n"
            "  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @small, i64 64, i1 false)\n"
            "  ret void\n}\n",
        )
        result, output = self.run_pass("sparse-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(0, json.loads(result.stdout)["zero_filled_constants"])
        ir = self.cleaned_ir(output)
        self.assertNotIn("llvm.memset", ir)
        self.assertIn("store i64 0, ptr %out, align 8", ir)


def _blob_layout(ir: str) -> tuple[bytes, dict[str, int]]:
    """The overlaid blob's bytes and each alias's offset into it."""
    line = next(l for l in ir.splitlines() if l.startswith("@pgso.overlaid_constants = "))
    literal = line.split(' c"', 1)[1].rsplit('"', 1)[0]
    raw, i = bytearray(), 0
    while i < len(literal):
        if literal[i] == "\\":
            raw.append(int(literal[i + 1:i + 3], 16))
            i += 3
        else:
            raw.append(ord(literal[i]))
            i += 1
    offsets = {}
    for l in ir.splitlines():
        if " alias " in l and "@pgso.overlaid_constants" in l:
            name = l.split(" =", 1)[0].lstrip("@")
            offsets[name] = int(l.rsplit("i64 ", 1)[1].rstrip(")")) if "getelementptr" in l else 0
    return bytes(raw), offsets


# Cold (minsize) copies of three error-union results and one null optional.
OVERLAY = (
    "%Big = type { [120 x i8] }\n"
    "%Small = type { [40 x i8] }\n"
    "@big_a = internal unnamed_addr constant { %Big, i16, [6 x i8] } { %Big undef, i16 653, [6 x i8] undef }, align 8\n"
    "@big_b = internal unnamed_addr constant { %Big, i16, [6 x i8] } { %Big undef, i16 17, [6 x i8] undef }, align 8\n"
    "@small = internal unnamed_addr constant { %Small, i16, [6 x i8] } { %Small undef, i16 9, [6 x i8] undef }, align 8\n"
    "@none = internal unnamed_addr constant { %Big, i8, [7 x i8] } { %Big undef, i8 0, [7 x i8] undef }, align 8\n"
    + MEMCPY
    + "define void @cold(ptr %out, i2 %which) minsize {\n"
    "  switch i2 %which, label %d [ i2 0, label %a i2 1, label %b i2 -2, label %s ]\n"
    "a:\n  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @big_a, i64 %n.a, i1 false)\n  ret void\n"
    "b:\n  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @big_b, i64 %n.a, i1 false)\n  ret void\n"
    "s:\n  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @small, i64 %n.a, i1 false)\n  ret void\n"
    "d:\n  call void @llvm.memcpy.p0.p0.i64(ptr align 8 %out, ptr align 8 @none, i64 %n.a, i1 false)\n  ret void\n"
    "}\n"
).replace("%n.a", "128")


@unittest.skipUnless(AVAILABLE, "pinned LLVM with libLLVM is not installed")
class OverlayConstantTests(LlvmCase):
    def text(self, bitcode: pathlib.Path) -> str:
        return subprocess.run(
            [str(LLVM_BIN / "llvm-dis"), str(bitcode), "-o", "-"], check=True, capture_output=True, text=True
        ).stdout

    def test_mostly_undefined_constants_share_one_blob_and_keep_their_bytes(self) -> None:
        source = self.assemble(
            "overlay",
            OVERLAY
            + "define i16 @code_a() minsize {\n  %v = load i16, ptr getelementptr inbounds (i8, ptr @big_a, i64 120), align 8\n  ret i16 %v\n}\n"
            "define i16 @code_b() minsize {\n  %v = load i16, ptr getelementptr inbounds (i8, ptr @big_b, i64 120), align 8\n  ret i16 %v\n}\n"
            "define i8 @tag() minsize {\n  %v = load i8, ptr getelementptr inbounds (i8, ptr @none, i64 120), align 8\n  ret i8 %v\n}\n",
        )
        result, output = self.run_pass("overlay-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("", result.stderr)
        self.assertIn('"members": 4', result.stdout)
        ir = self.cleaned_ir(output)
        blob, offsets = _blob_layout(ir)
        self.assertEqual({"big_a", "big_b", "small", "none"}, set(offsets))
        self.assertLess(len(blob), 3 * 128 + 48)
        for name, offset in offsets.items():
            self.assertEqual(0, offset % 8, name)
            self.assertLessEqual(offset + (48 if name == "small" else 128), len(blob), name)
        self.assertEqual(653, int.from_bytes(blob[offsets["big_a"] + 120:][:2], "little"))
        self.assertEqual(17, int.from_bytes(blob[offsets["big_b"] + 120:][:2], "little"))
        self.assertEqual(9, int.from_bytes(blob[offsets["small"] + 40:][:2], "little"))
        self.assertEqual(0, blob[offsets["none"] + 120])
        # Loads through the aliases still fold to the original defined bytes.
        folded = self.root / "folded.bc"
        subprocess.run([str(LLVM_BIN / "opt"), "-passes=instsimplify", str(output), "-o", str(folded)], check=True)
        folded_ir = self.text(folded)
        self.assertIn("ret i16 653", folded_ir)
        self.assertIn("ret i16 17", folded_ir)
        self.assertIn("ret i8 0", folded_ir)

    def test_small_and_hot_members_read_zeros_in_their_undefined_bytes(self) -> None:
        source = self.assemble(
            "guarded",
            OVERLAY
            + "define i16 @hot() {\n  %v = load i16, ptr getelementptr inbounds (i8, ptr @big_b, i64 120), align 8\n  ret i16 %v\n}\n",
        )
        result, output = self.run_pass("overlay-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"guarded_members": 2', result.stdout)
        blob, offsets = _blob_layout(self.cleaned_ir(output))
        for name, size, code_at in (("small", 48, 40), ("big_b", 128, 120)):
            extent = bytearray(blob[offsets[name]:offsets[name] + size])
            extent[code_at:code_at + 2] = b"\0\0"
            self.assertEqual(bytes(size), bytes(extent), name)

    def test_pointer_address_and_placed_constants_are_untouched(self) -> None:
        source = self.assemble(
            "kept",
            "@target = global i64 0\n"
            "@relocated = internal unnamed_addr constant { ptr, [120 x i8] } { ptr @target, [120 x i8] undef }, align 8\n"
            "@compared = internal unnamed_addr constant { [120 x i8], i16, [6 x i8] } { [120 x i8] undef, i16 3, [6 x i8] undef }, align 8\n"
            "@named = internal unnamed_addr constant { [120 x i8], i16, [6 x i8] } { [120 x i8] undef, i16 4, [6 x i8] undef }, section \"__TEXT,__fx\", align 8\n"
            "@significant = internal constant { [120 x i8], i16, [6 x i8] } { [120 x i8] undef, i16 5, [6 x i8] undef }, align 8\n"
            "declare void @use(ptr)\n"
            "define i1 @f(ptr %p) minsize {\n"
            "  call void @use(ptr @relocated)\n  call void @use(ptr @named)\n  call void @use(ptr @significant)\n"
            "  %c = icmp eq ptr %p, @compared\n  ret i1 %c\n}\n",
        )
        result, output = self.run_pass("overlay-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"members": 0', result.stdout)
        ir = self.cleaned_ir(output)
        self.assertNotIn("@pgso.overlaid_constants", ir)
        for name in ("relocated", "compared", "named", "significant"):
            self.assertIn(f"@{name} = internal", ir)

    def test_constants_listed_as_used_stay_globals(self) -> None:
        source = self.assemble(
            "used",
            OVERLAY + '@llvm.used = appending global [1 x ptr] [ptr @big_a], section "llvm.metadata"\n',
        )
        result, output = self.run_pass("overlay-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"members": 3', result.stdout)
        ir = self.cleaned_ir(output)
        self.assertIn("@big_a = internal unnamed_addr constant", ir)
        self.assertIn("[ptr @big_a]", ir)
        self.assertEqual({"big_b", "small", "none"}, set(_blob_layout(ir)[1]))


if __name__ == "__main__":
    unittest.main()


# Two regions that differ only in an instruction's constant, 16 or 8898, next
# to a constant expression that nests the constant 16.
NESTED_CONSTANT = """@real_io = internal global { ptr, ptr, i8 } zeroinitializer, align 8
@sink = global i64 0
""" + "".join(
    f"""define i64 @{name}(ptr %app) {{
  %flag = load i8, ptr getelementptr inbounds (i8, ptr @real_io, i64 16), align 8
  %field = getelementptr inbounds i8, ptr %app, i64 {offset}
  %v = load i64, ptr %field, align 8
  %f = zext i8 %flag to i64
  %s = add i64 %v, %f
  store i64 %s, ptr @sink, align 8
  ret i64 %s
}}
"""
    for name, offset in (("first", 16), ("second", 8898))
)

# `low` is in bounds when x < 4; `high` is out of bounds when end > len.
REVERSED_COMPARE = "@sink = global i64 0\n" + "".join(
    f"""define i64 @{name}(ptr %app, {parameters}) {{
  %v = load i64, ptr %app, align 8
  %c = {compare}
  %z = zext i1 %c to i64
  %s = add i64 %v, %z
  store i64 %s, ptr @sink, align 8
  ret i64 %s
}}
"""
    for name, parameters, compare in (
        ("low", "i64 %x", "icmp ult i64 %x, 4"),
        ("high", "i64 %end, i64 %len", "icmp ugt i64 %end, %len"),
    )
)

# Pairs of regions that differ only in one i1 or i16 constant, where the
# first region's constant equals the value one of its exits returns to tell
# the caller where to continue. `slash_menu` is the shape of the slash menu
# test: an optional result, an `orelse` panic, and a bool argument.
EXIT_SELECTORS = {
    "slash_menu": """declare void @layout(ptr)
declare void @widths(ptr, i1)
declare void @panic()
""" + "".join(
        f"""define i32 @{name}(ptr %p) {{
  call void @layout(ptr %p)
  %flag = load i8, ptr %p, align 1
  %set = trunc i8 %flag to i1
  br i1 %set, label %some, label %none
some:
  call void @widths(ptr %p, i1 {value})
  br label %cont
cont:
  ret i32 0
none:
  call void @panic()
  unreachable
}}
"""
        for name, value in (("first", "false"), ("second", "true"))
    ),
    "three_exits": """declare void @work(ptr)
declare void @e1()
declare void @e2()
declare void @e3()
""" + "".join(
        f"""define void @{name}(ptr %p, i1 %c1, i1 %c2) {{
  call void @work(ptr %p)
  br i1 %c1, label %x, label %out1
x:
  store i16 {value}, ptr %p, align 2
  br i1 %c2, label %out2, label %out3
out1:
  call void @e1()
  ret void
out2:
  call void @e2()
  ret void
out3:
  call void @e3()
  ret void
}}
"""
        for name, value in (("first", 1), ("second", 2))
    ),
    "phi": """declare void @work(ptr)
declare void @use(i1)
declare void @panic()
""" + "".join(
        f"""define void @{name}(ptr %p, i1 %c, i1 %d) {{
  call void @work(ptr %p)
  br i1 %c, label %a, label %b
a:
  call void @work(ptr %p)
  br label %m
b:
  call void @work(ptr %p)
  br label %m
m:
  %v = phi i1 [ {value}, %a ], [ %d, %b ]
  call void @use(i1 %v)
  br i1 %d, label %ok, label %bad
ok:
  ret void
bad:
  call void @panic()
  unreachable
}}
"""
        for name, value in (("first", "false"), ("second", "true"))
    ),
}

# llvm-reduce's reduction of six fx footer functions. The outliner gives the
# two regions one outlined function with two copies of the exit PHI and two
# output blocks, and nothing branches to either block, so neither call site's
# result is ever stored.
DROPPED_OUTPUT = """declare void @llvm.memcpy.p0.p0.i64(ptr noalias writeonly captures(none), ptr noalias readonly captures(none), i64, i1 immarg) #0
define fastcc i16 @row() {
  br label %a
a:
  br i1 false, label %exit, label %b
b:
  br i1 false, label %exit, label %exit
1:
  br label %exit
2:
  br i1 false, label %exit, label %exit
e:
  br i1 false, label %exit, label %second
first:
  %3 = call fastcc i16 @append(ptr null, i64 0)
  %ok1 = icmp eq i16 0, 0
  br i1 false, label %5, label %4
4:
  store i32 0, ptr null, align 4
  br label %exit
5:
  call void @llvm.memcpy.p0.p0.i64(ptr null, ptr null, i64 0, i1 false)
  br label %exit
second:
  %6 = call fastcc i16 @append(ptr null, i64 0)
  %ok2 = icmp eq i16 0, 0
  br i1 false, label %8, label %7
7:
  store i32 0, ptr null, align 4
  br label %exit
8:
  call void @llvm.memcpy.p0.p0.i64(ptr null, ptr null, i64 0, i1 false)
  br label %exit
exit:
  %r = phi i16 [ 0, %2 ], [ 0, %2 ], [ 0, %b ], [ 0, %b ], [ 0, %1 ], [ 0, %5 ], [ 0, %4 ], [ 0, %a ], [ 0, %8 ], [ 0, %7 ], [ 0, %e ]
  ret i16 0
}
declare fastcc i16 @append(ptr, i64)
attributes #0 = { nocallback nofree nounwind willreturn memory(argmem: readwrite) }
"""


@unittest.skipUnless(AVAILABLE, "pinned LLVM with libLLVM is not installed")
class OutlinedConstantTests(LlvmCase):
    def outline(self, source: pathlib.Path) -> pathlib.Path:
        output = self.root / f"{source.stem}.outlined.bc"
        subprocess.run(
            [str(LLVM_BIN / "opt"), "-passes=iroutliner", "-ir-outlining-no-cost", str(source), "-o", str(output)],
            check=True,
        )
        return output

    def check(self, bitcode: pathlib.Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(IR_SIZE_SCRIPT), "--libllvm", str(LIBLLVM), "check-outlined", str(bitcode)],
            capture_output=True,
            text=True,
        )

    def text(self, bitcode: pathlib.Path) -> str:
        return subprocess.run(
            [str(LLVM_BIN / "llvm-dis"), str(bitcode), "-o", "-"], check=True, capture_output=True, text=True
        ).stdout

    def dropped(self, bitcode: pathlib.Path) -> dict:
        result = subprocess.run(
            [sys.executable, str(IR_SIZE_SCRIPT), "--libllvm", str(LIBLLVM), "dropped-outputs", str(bitcode)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, result.returncode, result.stderr)
        return json.loads(result.stdout)

    def test_dropped_outputs_names_the_outlined_function_and_its_callers(self) -> None:
        outlined = self.outline(self.assemble("dropped", DROPPED_OUTPUT))
        self.assertIn("; No predecessors!", self.text(outlined).split("define internal")[1])

        summary = self.dropped(outlined)

        self.assertEqual(1, summary["outlined_functions"])
        self.assertEqual(["row"], summary["callers"])
        [instance] = summary["instances"]
        self.assertEqual("outlined_ir_func_0", instance["function"])
        self.assertEqual(["output_block_0_0", "output_block_1_0"], instance["blocks"])
        self.assertTrue(instance["stores_to_parameter"])
        self.assertEqual(["row"], instance["callers"])

    def test_check_rejects_output_stores_that_nothing_reaches(self) -> None:
        result = self.check(self.outline(self.assemble("dropped", DROPPED_OUTPUT)))

        self.assertEqual(1, result.returncode, result.stdout)
        self.assertIn(
            "outlined_ir_func_0: output stores in blocks with no predecessors "
            "(output_block_0_0, output_block_1_0), called from row",
            result.stderr,
        )

    def test_dropped_outputs_finds_nothing_in_a_correct_outline(self) -> None:
        _, widened = self.run_pass("widen-constants", self.assemble("slash_menu", EXIT_SELECTORS["slash_menu"]))

        summary = self.dropped(self.outline(widened))

        self.assertEqual({"callers": [], "instances": [], "outlined_functions": 1, "pass": "dropped-outputs"}, summary)

    def test_check_rejects_a_nested_constant_the_outliner_folded_into_a_parameter(self) -> None:
        outlined = self.outline(self.assemble("nested", NESTED_CONSTANT))

        result = self.check(outlined)

        self.assertEqual(1, result.returncode, result.stdout)
        self.assertIn("IR outliner miscompiled an outlined function", result.stderr)
        self.assertIn("constant expression", result.stderr)

    def test_expanded_expressions_keep_each_region_constant(self) -> None:
        result, expanded = self.run_pass("expand-constant-exprs", self.assemble("nested", NESTED_CONSTANT))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"rewritten_operands": 2', result.stdout)
        outlined = self.outline(expanded)

        check = self.check(outlined)

        self.assertEqual(0, check.returncode, check.stderr)
        self.assertIn('"outlined_functions": 1', check.stdout)
        ir = self.text(outlined)
        self.assertEqual(2, ir.count("getelementptr inbounds i8, ptr @real_io, i64 16"))
        self.assertIn("i64 8898", ir)
        self.assertNotIn("@real_io, i64 %", ir)

    def test_outliner_passes_a_greater_than_region_its_operands_unreversed(self) -> None:
        ir = self.text(self.outline(self.assemble("reversed", REVERSED_COMPARE)))

        self.assertIn("icmp ult i64 %1, %2", ir)
        self.assertIn("call void @outlined_ir_func_0(ptr %app, i64 %end, i64 %len,", ir)

    def test_swapped_compares_keep_each_region_comparison(self) -> None:
        result, swapped = self.run_pass("swap-compares", self.assemble("reversed", REVERSED_COMPARE))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"swapped_compares": 1', result.stdout)

        ir = self.text(self.outline(swapped))

        self.assertIn("icmp ult i64 %1, %2", ir)
        self.assertIn("call void @outlined_ir_func_0(ptr %app, i64 %x, i64 4,", ir)
        self.assertIn("call void @outlined_ir_func_0(ptr %app, i64 %len, i64 %end,", ir)

    def test_swap_compares_rewrites_every_greater_than_predicate_and_keeps_flags(self) -> None:
        compares = (
            ("icmp ugt i64 %a, %b", "icmp ult i64 %b, %a"),
            ("icmp samesign uge i64 %a, %b", "icmp samesign ule i64 %b, %a"),
            ("icmp sgt i64 %a, 7", "icmp slt i64 7, %a"),
            ("icmp sge i64 %a, %b", "icmp sle i64 %b, %a"),
            ("fcmp nnan ogt double %x, %y", "fcmp nnan olt double %y, %x"),
            ("fcmp oge double %x, %y", "fcmp ole double %y, %x"),
            ("fcmp ugt double %x, %y", "fcmp ult double %y, %x"),
            ("fcmp uge double %x, %y", "fcmp ule double %y, %x"),
        )
        kept = ("icmp ult i64 %a, %b", "icmp eq i64 %a, %b", "fcmp olt double %x, %y")
        body = "".join(f"  %c{i} = {compare}\n  store volatile i1 %c{i}, ptr %out\n" for i, compare in enumerate(
            [compare for compare, _ in compares] + list(kept)
        ))
        source = self.assemble(
            "compares",
            f"define void @f(i64 %a, i64 %b, double %x, double %y, ptr %out) {{\n{body}  ret void\n}}\n",
        )

        result, output = self.run_pass("swap-compares", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(f'"swapped_compares": {len(compares)}', result.stdout)
        ir = self.cleaned_ir(output)
        for i, (_, swapped) in enumerate(compares):
            self.assertIn(f"%c{i} = {swapped}", ir)
        for i, compare in enumerate(kept, start=len(compares)):
            self.assertIn(f"%c{i} = {compare}", ir)
        for predicate in ("ugt", "uge", "sgt", "sge", "ogt", "oge"):
            self.assertNotIn(f" {predicate} ", ir)

    def test_check_rejects_an_exit_that_returns_a_parameter(self) -> None:
        for name, ir in EXIT_SELECTORS.items():
            with self.subTest(name):
                outlined = self.outline(self.assemble(name, ir))
                self.assertRegex(self.text(outlined), r"ret i(1|16) %")

                result = self.check(outlined)

                self.assertEqual(1, result.returncode, result.stdout)
                self.assertIn("exit selector replaced by a parameter", result.stderr)

    def test_widened_constants_keep_each_exit_selector(self) -> None:
        for name in ("slash_menu", "three_exits"):
            with self.subTest(name):
                ir = EXIT_SELECTORS[name]
                result, widened = self.run_pass("widen-constants", self.assemble(name, ir))
                self.assertEqual(0, result.returncode, result.stderr)
                outlined = self.outline(widened)

                check = self.check(outlined)

                self.assertEqual(0, check.returncode, check.stderr)
                self.assertIn('"outlined_functions": 1', check.stdout)
                text = self.text(outlined)
                self.assertNotRegex(text, r"ret i(1|16) %")
                selectors = ("i16 0", "i16 1", "i16 2") if name == "three_exits" else ("i1 true", "i1 false")
                for selector in selectors:
                    self.assertIn(f"ret {selector}\n", text)
                wide = "i32" if name == "three_exits" else "i8"
                self.assertRegex(text, rf"%pgso\.wide = trunc {wide} %\d+ to i(1|16)")

    def test_check_still_rejects_a_phi_constant_that_becomes_an_exit_selector(self) -> None:
        result, widened = self.run_pass("widen-constants", self.assemble("phi", EXIT_SELECTORS["phi"]))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"widened_operands": 0', result.stdout)

        check = self.check(self.outline(widened))

        self.assertEqual(1, check.returncode, check.stdout)
        self.assertIn("exit selector replaced by a parameter", check.stderr)

    def test_widen_constants_keeps_immediates_and_other_types(self) -> None:
        source = self.assemble(
            "widen",
            MEMCPY
            + "declare { i16, i1 } @llvm.uadd.with.overflow.i16(i16, i16)\n"
            "declare void @llvm.assume(i1)\n"
            "declare void @use(i1, i16, i32)\n"
            "define i16 @f(ptr %out, i16 %x, i8 %k, i1 %c) {\n"
            "entry:\n"
            "  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr %out, i64 8, i1 false)\n"
            "  call void @llvm.assume(i1 true)\n"
            "  call void asm sideeffect \"\", \"n\"(i16 7)\n"
            "  %sum = call { i16, i1 } @llvm.uadd.with.overflow.i16(i16 %x, i16 1)\n"
            "  call void @use(i1 true, i16 653, i32 5)\n"
            "  %e = getelementptr inbounds [4 x i8], ptr %out, i16 0, i16 3\n"
            "  store i16 2, ptr %e, align 2\n"
            "  switch i8 %k, label %a [ i8 1, label %b ]\n"
            "a:\n  br i1 %c, label %b, label %b\n"
            "b:\n"
            "  %p = phi i16 [ 4, %a ], [ 4, %a ], [ 0, %entry ]\n"
            "  %q = phi i1 [ true, %a ], [ true, %a ], [ %c, %entry ]\n"
            "  ret i16 9\n}\n",
        )

        result, output = self.run_pass("widen-constants", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(4, json.loads(result.stdout)["widened_operands"])
        ir = self.cleaned_ir(output)
        self.assertIn("i64 8, i1 false)", ir)
        self.assertIn("call void @llvm.assume(i1 true)", ir)
        self.assertIn('"n"(i16 7)', ir)
        self.assertIn("i16 %x, i16 %pgso.wide)", ir)
        self.assertRegex(ir, r"call void @use\(i1 %pgso\.wide\d*, i16 %pgso\.wide\d*, i32 5\)")
        self.assertIn("ptr %out, i16 0, i16 3", ir)
        self.assertRegex(ir, r"store i16 %pgso\.wide\d*, ptr %e")
        self.assertIn("i8 1, label %b", ir)
        self.assertIn("%p = phi i16 [ 4, %a ], [ 4, %a ], [ 0, %entry ]", ir)
        self.assertIn("%q = phi i1 [ true, %a ], [ true, %a ], [ %c, %entry ]", ir)
        self.assertIn("ret i16 9", ir)
        self.assertEqual(4, ir.count("= trunc "))

    def test_phi_and_intrinsic_expressions_stay_constant_and_call_arguments_expand(self) -> None:
        source = self.assemble(
            "kept",
            "@g = global [4 x i64] zeroinitializer\n"
            + MEMCPY
            + "declare void @use(ptr)\n"
            "define ptr @f(i1 %c, ptr %out) {\n"
            "entry:\n"
            "  call void @llvm.memcpy.p0.p0.i64(ptr %out, ptr getelementptr inbounds (i8, ptr @g, i64 8), i64 8, i1 false)\n"
            "  call void @use(ptr getelementptr inbounds (i8, ptr @g, i64 16))\n"
            "  br i1 %c, label %a, label %b\n"
            "a:\n  br label %b\n"
            "b:\n"
            "  %p = phi ptr [ getelementptr inbounds (i8, ptr @g, i64 24), %a ], [ %out, %entry ]\n"
            "  ret ptr %p\n}\n",
        )

        result, output = self.run_pass("expand-constant-exprs", source)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"rewritten_operands": 1', result.stdout)
        ir = self.cleaned_ir(output)
        self.assertIn("ptr getelementptr inbounds (i8, ptr @g, i64 8)", ir)
        self.assertIn("[ getelementptr inbounds (i8, ptr @g, i64 24), %a ]", ir)
        self.assertIn("%pgso.expr = getelementptr inbounds i8, ptr @g, i64 16", ir)
        self.assertIn("call void @use(ptr %pgso.expr)", ir)


@unittest.skipUnless(AVAILABLE, "pinned LLVM with libLLVM is not installed")
class MinsizeFunctionTests(LlvmCase):
    def test_lists_the_defined_functions_and_those_marked_minsize(self) -> None:
        source = self.assemble(
            "attributes",
            "define void @cold() minsize optsize { ret void }\n"
            "define void @hot() { ret void }\n"
            "declare void @external()\n",
        )
        output = self.root / "attributes.json"

        result = subprocess.run(
            [sys.executable, str(IR_SIZE_SCRIPT), "--libllvm", str(LIBLLVM), "minsize-functions", str(source), str(output)],
            capture_output=True,
            text=True,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual({"defined": ["cold", "hot"], "minsize": ["cold"]}, json.loads(output.read_text()))
        self.assertEqual(
            {"pass": "minsize-functions", "defined_functions": 2, "minsize_functions": 1},
            json.loads(result.stdout),
        )


@unittest.skipUnless(AVAILABLE, "pinned LLVM with libLLVM is not installed")
class NameFunctionsTests(LlvmCase):
    IR = (
        "define private void @cold() { ret void }\n"
        "define internal void @kept() { ret void }\n"
        "define void @exported() {\n"
        "  call void @cold()\n"
        "  call void @kept()\n"
        "  call void @external()\n"
        "  ret void\n"
        "}\n"
        "declare void @external()\n"
    )

    def test_only_private_definitions_become_internal(self) -> None:
        result, output = self.run_pass("name-functions", self.assemble("functions", self.IR))

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual({"pass": "name-functions", "named_functions": 1}, json.loads(result.stdout))
        text = subprocess.run(
            [str(LLVM_BIN / "llvm-dis"), str(output), "-o", "-"], check=True, capture_output=True, text=True
        ).stdout
        self.assertIn("define internal void @cold()", text)
        self.assertIn("define internal void @kept()", text)
        self.assertIn("define void @exported()", text)
        self.assertIn("declare void @external()", text)
        self.assertNotIn("private", text)


@unittest.skipUnless(AVAILABLE, "pinned LLVM with libLLVM is not installed")
class NoOutlineTests(LlvmCase):
    IR = (
        "define void @startup() { ret void }\n"
        "define void @other() { ret void }\n"
        "declare void @external()\n"
    )

    def no_outline(self, source: pathlib.Path, names: str) -> tuple[subprocess.CompletedProcess, pathlib.Path]:
        functions = self.root / "functions.txt"
        functions.write_text(names)
        output = self.root / "marked.bc"
        result = subprocess.run(
            [sys.executable, str(IR_SIZE_SCRIPT), "--libllvm", str(LIBLLVM), "--functions", str(functions),
             "no-outline", str(source), str(output)],
            capture_output=True,
            text=True,
        )
        return result, output

    def test_marks_only_the_listed_defined_functions(self) -> None:
        result, output = self.no_outline(self.assemble("functions", self.IR), "startup\nexternal\nmissing\n")

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(
            {"pass": "no-outline", "listed_functions": 3, "marked_functions": 1},
            json.loads(result.stdout),
        )
        text = subprocess.run(
            [str(LLVM_BIN / "llvm-dis"), str(output), "-o", "-"], check=True, capture_output=True, text=True
        ).stdout
        startup = next(line for line in text.splitlines() if line.startswith("define void @startup"))
        other = next(line for line in text.splitlines() if line.startswith("define void @other"))
        group = startup.split("#")[1].split()[0]
        self.assertIn('"nooutline"', next(line for line in text.splitlines() if line.startswith(f"attributes #{group} ")))
        self.assertNotIn("#", other)

    def test_fails_when_no_listed_function_is_defined(self) -> None:
        result, output = self.no_outline(self.assemble("functions", self.IR), "external\nmissing\n")

        self.assertEqual(1, result.returncode)
        self.assertIn("is defined", result.stderr)
        self.assertFalse(output.exists())

ZERO_FILL_STATE = (
    "@target = internal global i32 7, align 4\n"
    "@state = internal unnamed_addr global { [8192 x i8], i32, ptr, i64 } "
    "{ [8192 x i8] undef, i32 255, ptr @target, i64 0 }, align 8\n"
)
# Returns 255 + 7 when both restored fields read back.
ZERO_FILL_MAIN = (
    "define i32 @main() {\n"
    "entry:\n"
    "  %slot = alloca i32, align 4\n"
    "  %count_at = getelementptr inbounds i8, ptr @state, i64 8192\n"
    "  %count = load i32, ptr %count_at, align 8\n"
    "  %pointer_at = getelementptr inbounds i8, ptr @state, i64 8200\n"
    "  %pointer = load ptr, ptr %pointer_at, align 8\n"
    "  %value = load i32, ptr %pointer, align 4\n"
    "  %sum = add i32 %count, %value\n"
    "  store i32 %sum, ptr %slot, align 4\n"
    "  %result = load i32, ptr %slot, align 4\n"
    "  ret i32 %result\n"
    "}\n"
)


@unittest.skipUnless(AVAILABLE and (LLVM_BIN / "lli").is_file(), "pinned LLVM 21 with libLLVM and lli is not installed")
class ZeroFillGlobalTests(LlvmCase):
    def text(self, bitcode: pathlib.Path) -> str:
        return subprocess.run(
            [str(LLVM_BIN / "llvm-dis"), str(bitcode), "-o", "-"], check=True, capture_output=True, text=True
        ).stdout

    def exit_code(self, bitcode: pathlib.Path) -> int:
        # LLVM's interpreter runs the module the same way on any host; JIT
        # compiling its macOS target fails on Linux.
        result = subprocess.run(
            [str(LLVM_BIN / "lli"), "--force-interpreter", str(bitcode)], capture_output=True, text=True
        )
        self.assertEqual("", result.stderr)
        return result.returncode

    def test_mostly_undefined_global_moves_to_zero_fill_and_main_restores_its_bytes(self) -> None:
        source = self.assemble("state", ZERO_FILL_STATE + ZERO_FILL_MAIN)
        result, output = self.run_pass("zero-fill-globals", source)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"zero_filled_globals": 1', result.stdout)
        self.assertIn('"stored_bytes": 12', result.stdout)

        ir = self.text(output)
        self.assertIn("@state = internal unnamed_addr global { [8192 x i8], i32, ptr, i64 } zeroinitializer", ir)
        self.assertIn("@target = internal global i32 7", ir)
        body = ir[ir.index("define i32 @main()") :]
        # The stores come after the entry allocas and before the first read.
        self.assertLess(body.index("alloca i32"), body.index("store i32 255"))
        self.assertLess(body.index("store i32 255"), body.index("%count = load"))
        self.assertLess(body.index("store ptr @target"), body.index("%count = load"))
        self.assertEqual(262 % 256, self.exit_code(source))
        self.assertEqual(self.exit_code(source), self.exit_code(output))

    def test_main_defined_as_an_alias_like_zig_is_followed(self) -> None:
        aliased = ZERO_FILL_MAIN.replace("define i32 @main()", "define internal i32 @main.main()")
        source = self.assemble("aliased", ZERO_FILL_STATE + "@main = alias i32 (), ptr @main.main\n" + aliased)
        result, output = self.run_pass("zero-fill-globals", source)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"zero_filled_globals": 1', result.stdout)
        body = self.text(output)
        body = body[body.index("define internal i32 @main.main()") :]
        # LLVM's interpreter cannot start at an alias, so the plain-`main`
        # test above is the one that runs both modules.
        self.assertLess(body.index("store i32 255"), body.index("%count = load"))
        self.assertLess(body.index("store ptr @target"), body.index("%count = load"))

    def test_globals_that_must_keep_their_initializer_are_untouched(self) -> None:
        kept = (
            # Too many nonzero bytes to restore.
            "@dense = internal global [1024 x i64] [" + ", ".join(["i64 1"] * 1024) + "], align 8\n"
            # Too small to save a page.
            "@small = internal global { [1024 x i8], i32 } { [1024 x i8] undef, i32 1 }, align 4\n"
            "@constant = internal unnamed_addr constant { [8192 x i8], i32 } { [8192 x i8] undef, i32 1 }, align 4\n"
            "@external = global { [8192 x i8], i32 } { [8192 x i8] undef, i32 1 }, align 4\n"
            "@local = internal thread_local global { [8192 x i8], i32 } { [8192 x i8] undef, i32 1 }, align 4\n"
            '@placed = internal global { [8192 x i8], i32 } { [8192 x i8] undef, i32 1 }, section "__DATA,__fx", align 4\n'
        )
        uses = "".join(
            f"  %{name} = load i32, ptr @{name}, align 4\n"
            for name in ("dense", "small", "constant", "external", "local", "placed")
        )
        main = "define i32 @main() {\nentry:\n" + uses + "  ret i32 0\n}\n"
        result, output = self.run_pass("zero-fill-globals", self.assemble("kept", kept + main))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"zero_filled_globals": 0', result.stdout)
        self.assertNotIn("zeroinitializer", self.text(output))

    def test_a_module_without_main_is_unchanged(self) -> None:
        library = ZERO_FILL_STATE + "define i32 @read() {\n  %v = load i32, ptr @state, align 8\n  ret i32 %v\n}\n"
        result, output = self.run_pass("zero-fill-globals", self.assemble("library", library))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"skipped": "no main"', result.stdout)
        self.assertIn("i32 255", self.text(output))


ERROR_NAMES = (
    '@n1 = internal unnamed_addr constant [4 x i8] c"Foo\\00", align 1\n'
    '@n2 = internal unnamed_addr constant [7 x i8] c"BarBaz\\00", align 1\n'
    '@n3 = internal unnamed_addr constant [2 x i8] c"Q\\00", align 1\n'
    "@__zig_error_name_table = internal unnamed_addr constant [4 x { ptr, i64 }] [{ ptr, i64 } undef, "
    "{ ptr, i64 } { ptr @n1, i64 3 }, { ptr, i64 } { ptr @n2, i64 6 }, { ptr, i64 } { ptr @n3, i64 1 }], align 8\n"
)
# Reads a name the way Zig's `@errorName` does: 16 times its length plus its
# first byte, plus 1000 times the byte after it, which must be the NUL.
ERROR_NAME_SCORE = (
    "define internal i64 @score(i64 %e) {\n"
    "start:\n"
    "  %entry = getelementptr inbounds nuw [16 x i8], ptr @__zig_error_name_table, i64 %e\n"
    "  %name = load ptr, ptr %entry, align 8\n"
    "  %length_at = getelementptr inbounds nuw i8, ptr %entry, i64 8\n"
    "  %length = load i64, ptr %length_at, align 8\n"
    "  %first = load i8, ptr %name, align 1\n"
    "  %end = getelementptr inbounds i8, ptr %name, i64 %length\n"
    "  %sentinel = load i8, ptr %end, align 1\n"
    "  %first64 = zext i8 %first to i64\n"
    "  %sentinel64 = zext i8 %sentinel to i64\n"
    "  %scaled = mul i64 %length, 16\n"
    "  %partial = add i64 %scaled, %first64\n"
    "  %penalty = mul i64 %sentinel64, 1000\n"
    "  %score = add i64 %partial, %penalty\n"
    "  ret i64 %score\n"
    "}\n"
)
# A PHI that merges a table entry with a local slice, as in
# `core.indexer.bounded_read.readWith`.
ERROR_NAME_MERGED = (
    "define internal i64 @merged(i1 %from_table, i64 %e) {\n"
    "start:\n"
    "  %local = alloca { ptr, i64 }, align 8\n"
    "  store ptr @n1, ptr %local, align 8\n"
    "  %local_length = getelementptr inbounds i8, ptr %local, i64 8\n"
    "  store i64 2, ptr %local_length, align 8\n"
    "  br i1 %from_table, label %table, label %join\n"
    "table:\n"
    "  %entry = getelementptr inbounds nuw [16 x i8], ptr @__zig_error_name_table, i64 %e\n"
    "  br label %join\n"
    "join:\n"
    "  %slice = phi ptr [ %entry, %table ], [ %local, %start ]\n"
    "  %name = load ptr, ptr %slice, align 8\n"
    "  %length_at = getelementptr inbounds nuw i8, ptr %slice, i64 8\n"
    "  %length = load i64, ptr %length_at, align 8\n"
    "  %first = load i8, ptr %name, align 1\n"
    "  %first64 = zext i8 %first to i64\n"
    "  %sum = add i64 %length, %first64\n"
    "  ret i64 %sum\n"
    "}\n"
)
# (3*16 + 'F') + (6*16 + 'B') + (1*16 + 'Q') + (6 + 'B') + (2 + 'F') = 521.
ERROR_NAME_MAIN = (
    "define i32 @main() {\n"
    "start:\n"
    "  %a = call i64 @score(i64 1)\n"
    "  %b = call i64 @score(i64 2)\n"
    "  %c = call i64 @score(i64 3)\n"
    "  %d = call i64 @merged(i1 true, i64 2)\n"
    "  %e = call i64 @merged(i1 false, i64 0)\n"
    "  %ab = add i64 %a, %b\n"
    "  %abc = add i64 %ab, %c\n"
    "  %abcd = add i64 %abc, %d\n"
    "  %all = add i64 %abcd, %e\n"
    "  %result = trunc i64 %all to i32\n"
    "  ret i32 %result\n"
    "}\n"
)


# The IR outliner can move a name copy into a function that other callers
# share, as `outlined_ir_func_140` does for `core.indexer.bounded_read.readWith`.
# `@copied` scores a name as `@score` does; `@copied_local` passes a local pair.
ERROR_NAME_COPIED = (
    "define internal void @copy_pair(ptr %from, ptr %to) {\n"
    "start:\n"
    "  %name = load ptr, ptr %from, align 8\n"
    "  %length_at = getelementptr inbounds nuw i8, ptr %from, i64 8\n"
    "  %length = load i64, ptr %length_at, align 8\n"
    "  store ptr %name, ptr %to, align 8\n"
    "  %to_length = getelementptr inbounds nuw i8, ptr %to, i64 8\n"
    "  store i64 %length, ptr %to_length, align 8\n"
    "  ret void\n"
    "}\n"
    "define internal i64 @copied(i64 %e) {\n"
    "start:\n"
    "  %out = alloca { ptr, i64 }, align 8\n"
    "  %entry = getelementptr inbounds nuw [16 x i8], ptr @__zig_error_name_table, i64 %e\n"
    "  call void @copy_pair(ptr %entry, ptr %out)\n"
    "  %name = load ptr, ptr %out, align 8\n"
    "  %length_at = getelementptr inbounds nuw i8, ptr %out, i64 8\n"
    "  %length = load i64, ptr %length_at, align 8\n"
    "  %first = load i8, ptr %name, align 1\n"
    "  %end = getelementptr inbounds i8, ptr %name, i64 %length\n"
    "  %sentinel = load i8, ptr %end, align 1\n"
    "  %first64 = zext i8 %first to i64\n"
    "  %sentinel64 = zext i8 %sentinel to i64\n"
    "  %scaled = mul i64 %length, 16\n"
    "  %partial = add i64 %scaled, %first64\n"
    "  %penalty = mul i64 %sentinel64, 1000\n"
    "  %score = add i64 %partial, %penalty\n"
    "  ret i64 %score\n"
    "}\n"
    "define internal i64 @copied_local() {\n"
    "start:\n"
    "  %local = alloca { ptr, i64 }, align 8\n"
    "  %out = alloca { ptr, i64 }, align 8\n"
    "  store ptr @n2, ptr %local, align 8\n"
    "  %local_length = getelementptr inbounds i8, ptr %local, i64 8\n"
    "  store i64 4, ptr %local_length, align 8\n"
    "  call void @copy_pair(ptr %local, ptr %out)\n"
    "  %length_at = getelementptr inbounds nuw i8, ptr %out, i64 8\n"
    "  %length = load i64, ptr %length_at, align 8\n"
    "  ret i64 %length\n"
    "}\n"
    # (3*16 + 'F') + (1*16 + 'Q') + 4 = 219.
    "define i32 @main() {\n"
    "start:\n"
    "  %a = call i64 @copied(i64 1)\n"
    "  %b = call i64 @copied(i64 3)\n"
    "  %c = call i64 @copied_local()\n"
    "  %ab = add i64 %a, %b\n"
    "  %all = add i64 %ab, %c\n"
    "  %result = trunc i64 %all to i32\n"
    "  ret i32 %result\n"
    "}\n"
)

@unittest.skipUnless(AVAILABLE and (LLVM_BIN / "lli").is_file(), "pinned LLVM 21 with libLLVM and lli is not installed")
class CompactErrorNameTests(LlvmCase):
    def text(self, bitcode: pathlib.Path) -> str:
        return subprocess.run(
            [str(LLVM_BIN / "llvm-dis"), str(bitcode), "-o", "-"], check=True, capture_output=True, text=True
        ).stdout

    def exit_code(self, bitcode: pathlib.Path) -> int:
        result = subprocess.run(
            [str(LLVM_BIN / "lli"), "--force-interpreter", str(bitcode)], capture_output=True, text=True
        )
        self.assertEqual("", result.stderr)
        return result.returncode

    def test_error_names_read_through_one_function_give_the_same_results(self) -> None:
        source = self.assemble("names", ERROR_NAMES + ERROR_NAME_SCORE + ERROR_NAME_MERGED + ERROR_NAME_MAIN)
        result, output = self.run_pass("compact-error-names", source)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"rewritten_reads": 1', result.stdout)
        self.assertIn('"spilled_reads": 1', result.stdout)
        self.assertIn('"names": 4', result.stdout)

        ir = self.cleaned_ir(output)
        self.assertNotIn("@__zig_error_name_table", ir)
        self.assertNotIn("@n2", ir)
        self.assertIn('@pgso.error_names = internal unnamed_addr constant [14 x i8] c"\\00Foo\\00BarBaz\\00Q\\00"', ir)
        self.assertIn("@pgso.error_name_offsets = internal unnamed_addr constant [5 x i16] [i16 0, i16 1, i16 5, i16 12, i16 14]", ir)
        self.assertEqual(2, ir.count("call { ptr, i64 } @pgso.error_name("))
        self.assertEqual(521 % 256, self.exit_code(source))
        self.assertEqual(self.exit_code(source), self.exit_code(output))

    def test_an_entry_passed_to_a_function_that_only_reads_it_goes_through_a_slot(self) -> None:
        source = self.assemble("copied", ERROR_NAMES + ERROR_NAME_COPIED)
        result, output = self.run_pass("compact-error-names", source)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"rewritten_reads": 0', result.stdout)
        self.assertIn('"spilled_reads": 1', result.stdout)

        ir = self.cleaned_ir(output)
        self.assertNotIn("@__zig_error_name_table", ir)
        self.assertEqual(1, ir.count("call { ptr, i64 } @pgso.error_name("))
        # The shared copy is unchanged, so its other callers are too.
        self.assertIn("%name = load ptr, ptr %from, align 8", ir)
        self.assertEqual(2, ir.count("call void @copy_pair("))
        self.assertEqual(219, self.exit_code(source))
        self.assertEqual(self.exit_code(source), self.exit_code(output))

    def test_unrecognized_uses_leave_the_table_in_place(self) -> None:
        cases = {
            "escaping": (
                "declare void @keep(ptr)\n"
                "define void @use(i64 %e) {\n"
                "  %entry = getelementptr inbounds nuw [16 x i8], ptr @__zig_error_name_table, i64 %e\n"
                "  call void @keep(ptr %entry)\n"
                "  ret void\n}\n",
                "error name entry used other than by reading it",
            ),
            "kept": (
                "@kept = internal global ptr null\n"
                "define internal void @remember(ptr %p) {\n"
                "  store ptr %p, ptr @kept, align 8\n"
                "  ret void\n}\n"
                "define void @use(i64 %e) {\n"
                "  %entry = getelementptr inbounds nuw [16 x i8], ptr @__zig_error_name_table, i64 %e\n"
                "  call void @remember(ptr %entry)\n"
                "  ret void\n}\n",
                "error name entry used other than by reading it",
            ),
            "offset": (
                "define i32 @use(i64 %e) {\n"
                "  %entry = getelementptr inbounds nuw [16 x i8], ptr @__zig_error_name_table, i64 %e\n"
                "  %half = getelementptr inbounds nuw i8, ptr %entry, i64 4\n"
                "  %v = load i32, ptr %half, align 4\n"
                "  ret i32 %v\n}\n",
                "error name entry read at an unexpected offset",
            ),
            "stored": (
                "define void @use(ptr %slot) {\n"
                "  store ptr @__zig_error_name_table, ptr %slot, align 8\n"
                "  ret void\n}\n",
                "error name table used other than by indexing it",
            ),
            "narrow": (
                "define ptr @use(i32 %e) {\n"
                "  %entry = getelementptr inbounds nuw [16 x i8], ptr @__zig_error_name_table, i32 %e\n"
                "  %name = load ptr, ptr %entry, align 8\n"
                "  ret ptr %name\n}\n",
                "unexpected error name index",
            ),
        }
        for name, (use, reason) in cases.items():
            with self.subTest(name):
                result, output = self.run_pass("compact-error-names", self.assemble(name, ERROR_NAMES + use))
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertIn(f'"skipped": "{reason}"', result.stdout)
                ir = self.text(output)
                self.assertIn("@__zig_error_name_table = internal", ir)
                self.assertNotIn("pgso.error_name", ir)

    def test_a_module_without_an_error_table_is_unchanged(self) -> None:
        result, output = self.run_pass("compact-error-names", self.assemble("plain", "define i32 @main() {\n  ret i32 0\n}\n"))
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('"skipped": "no error name table"', result.stdout)
        self.assertNotIn("pgso.error_name", self.text(output))
