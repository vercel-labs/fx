"""Static parser/layout regression tests. Never execute generated Mach-O files."""
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from rewrite_macho import (PAGE, CHAINED, DYLD_INFO, DYSYMTAB, MAIN, SEGMENT,
                           SYMTAB, inspect, parse, rewrite, rewrite_opcodes, segment_command)
from verify_guest import INSTALL_SCRIPT


def fixture(chained=False, padding=True):
    base = 0x100000000
    def seg(name, va, vs, fo, fs, prot, sections=()):
        return dict(name=name, va=va, vs=vs, fo=fo, fs=fs, max=prot, init=prot, flags=0, sections=list(sections))
    def section(name, va, size, off, flags=0, r1=0, r2=0):
        return [name, b'__TEXT', va, size, off, 2, 0, 0, flags, r1, r2, 0]
    code_start = 0x4000 if padding else 0x400
    text = seg(b'__TEXT', base, 0x18000, 0, 0x18000, 5, [
        section(b'__text', base+code_start, 0x10004-code_start, code_start, 0x80000400),
        section(b'__stubs', base+0x11000, 12, 0x11000, 8, 0, 12)])
    segments = [seg(b'__PAGEZERO', 0, base, 0, 0, 0), text,
                seg(b'__DATA_CONST', base+0x18000, PAGE, 0x18000, PAGE, 3),
                seg(b'__DATA', base+0x1c000, PAGE, 0x1c000, PAGE, 3),
                seg(b'__LINKEDIT', base+0x20000, PAGE, 0x20000, PAGE, 1)]
    data = bytearray(0x24000)
    data[code_start:0x18000] = bytes([0xAA]) * (0x18000-code_start)
    struct.pack_into('<IBBHQ', data, 0x20100, 1, 1, 0, 0, 0)
    data[0x20200:0x2020c] = b'\0_sigaction\0'
    struct.pack_into('<I', data, 0x20300, 0)
    cmds = [segment_command(s) for s in segments]
    cmds += [struct.pack('<IIQQ', MAIN, 24, code_start, 0),
             struct.pack('<6I', SYMTAB, 24, 0x20100, 1, 0x20200, 12)]
    ds = [DYSYMTAB, 80] + [0]*18
    ds[14:16] = [0x20300, 1]
    cmds.append(struct.pack('<20I', *ds))
    if chained:
        # One starts-in-segment record for DATA_CONST.
        starts = struct.pack('<6I', 5, 0, 0, 24, 0, 0)
        starts += struct.pack('<IHHQIH', 24, PAGE, 2, 0x18000, 0, 1) + struct.pack('<H', 0xFFFF)
        payload = struct.pack('<7I', 0, 28, 28+len(starts), 28+len(starts), 0, 1, 0) + starts
        data[0x20400:0x20400+len(payload)] = payload
        cmds.append(struct.pack('<4I', CHAINED, 16, 0x20400, len(payload)))
    else:
        data[0x20400:0x20404] = bytes([0x22, 0, 0x51, 0])
        data[0x20410:0x20414] = bytes([0x73, 0, 0x90, 0])
        cmds.append(struct.pack('<12I', DYLD_INFO, 48, 0x20400, 4, 0x20410, 4, 0, 0, 0, 0, 0, 0))
    commands = b''.join(cmds)
    data[:32] = struct.pack('<8I', 0xFEEDFACF, 0x100000C, 0, 2, len(cmds), len(commands), 0x200000, 0)
    data[32:32+len(commands)] = commands
    return bytes(data)


class RewriteTests(unittest.TestCase):
    def make_output(self, chained=False):
        source = fixture(chained)
        layout = inspect(source)
        base = layout['pager_base']
        return source, layout, rewrite(source, layout, bytes(PAGE), base+PAGE, PAGE, base+2*PAGE, bytes(PAGE), base)

    def test_derive_range_and_import(self):
        d = inspect(fixture())
        self.assertEqual(d['start'], 0x100004000)
        self.assertEqual(d['end'], 0x100010000)
        self.assertEqual(d['sigaction'], 0x100011000)

    def test_immutable_segments_and_anonymous_state(self):
        _, _, output = self.make_output()
        _, _, segments = parse(output)
        by_name = {s['name']:s for s in segments}
        for s in segments:
            self.assertNotEqual(s['init'] & 6, 6)
        self.assertEqual(by_name[b'__PGSTATE']['fs'], 0)
        self.assertEqual(by_name[b'__PGSTATE']['max'], 3)
        self.assertEqual(by_name[b'__PGMETA']['max'], 1)
        self.assertEqual(by_name[b'__PGCODE']['max'], 5)
        self.assertEqual(by_name[b'__TEXTB']['max'], 5)

    def test_text_header_page_is_not_paged(self):
        source, layout, output = self.make_output()
        text = next(s for s in parse(output)[2] if s['name']==b'__TEXT')
        self.assertEqual(text['fs'], layout['start']-layout['base'])
        self.assertGreaterEqual(text['fs'], PAGE)
        tail = next(s for s in parse(output)[2] if s['name']==b'__TEXTB')
        self.assertEqual(output[tail['fo']:tail['fo']+tail['fs']], source[0x10000:0x18000])

    def test_legacy_fixup_indices_shift(self):
        _, _, output = self.make_output()
        raw = next(raw for cmd,raw in parse(output)[1] if cmd==DYLD_INFO)
        rebase, _, bind, _ = struct.unpack_from('<4I',raw,8)
        self.assertEqual(output[rebase], 0x23)
        self.assertEqual(output[bind], 0x74)

    def test_chained_fixup_count_and_segment_offset(self):
        _, _, output = self.make_output(True)
        raw = next(raw for cmd,raw in parse(output)[1] if cmd==CHAINED)
        off, size = struct.unpack_from('<II', raw, 8)
        payload = output[off:off+size]
        starts = struct.unpack_from('<I',payload,4)[0]
        self.assertEqual(struct.unpack_from('<I',payload,starts)[0], 9)
        record = struct.unpack_from('<I',payload,starts+4+3*4)[0]
        self.assertEqual(struct.unpack_from('<Q',payload,starts+record+8)[0], 0x18000)

    def test_reject_header_overwrite(self):
        data = fixture(padding=False)
        layout = inspect(data)
        base = layout['pager_base']
        with self.assertRaisesRegex(ValueError, 'overwrite original code'):
            rewrite(data,layout,bytes(PAGE),base+PAGE,PAGE,base+2*PAGE,bytes(PAGE),base)

    def test_reject_truncated_header_and_commands(self):
        for data in (b'', fixture()[:31], fixture()[:80]):
            with self.assertRaises(ValueError):
                parse(data)

    def test_reject_text_fixups(self):
        with self.assertRaisesRegex(ValueError, 'text unsupported'):
            rewrite_opcodes(bytearray([0x21,0]), {1:1}, False)

    def test_reject_truncated_leb_and_unknown_opcodes(self):
        for stream, bind in (([0x22,0x80],False),([0xD0],True),([0x40,65],True)):
            with self.assertRaises(ValueError):
                rewrite_opcodes(bytearray(stream), {2:3}, bind)


class GuestTransferTests(unittest.TestCase):
    def test_replacement_preserves_previous_inode_contents(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory)/'signed executable'
            target.write_bytes(b'old signed bytes')
            inode = target.stat().st_ino
            with target.open('rb') as previous:
                subprocess.run([sys.executable, '-c', INSTALL_SCRIPT, str(target)],
                               input=b'new signed bytes', check=True, capture_output=True)
                self.assertEqual(previous.read(), b'old signed bytes')
                self.assertNotEqual(target.stat().st_ino, inode)
            self.assertEqual(target.read_bytes(), b'new signed bytes')
            self.assertEqual(target.stat().st_mode & 0o777, 0o755)
            self.assertEqual(list(Path(directory).iterdir()), [target])


if __name__ == '__main__':
    unittest.main()
