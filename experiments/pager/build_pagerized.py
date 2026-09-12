#!/usr/bin/env python3
"""Build and statically verify a guest-only pager, without executing it."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess

from rewrite_macho import PAGE, align, inspect, parse, require, rewrite

ROOT = Path(__file__).resolve().parent
MAGIC = int.from_bytes(b'FXPAGER2', 'little')


def elf_image(path):
    data = path.read_bytes()
    require(data[:6] == b'\x7fELF\x02\x01', 'expected little-endian ELF64')
    h = struct.unpack_from('<16sHHIQQQIHHHHHH', data)
    require(h[2] == 183, 'expected arm64 ELF')
    shoff, shsize, shnum, shstr = h[6], h[11], h[12], h[13]
    sections = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * shsize) for i in range(shnum)]
    strings = sections[shstr]
    names = data[strings[4]:strings[4] + strings[5]]
    def name(s):
        return names[s[0]:].split(b'\0', 1)[0].decode()
    by_name = {name(s): s for s in sections}
    for s in sections:
        if s[2] & 2:
            require(name(s) in ('.text', '.state'), f'unexpected allocated ELF section {name(s)}')
    text, state = by_name['.text'], by_name['.state']
    code = data[text[4]:text[4] + text[5]]
    template = bytearray(data[state[4]:state[4] + state[5]])
    relocs = []
    # All other accepted relocations are invariant when the whole image slides.
    relative_types = {0, 260, 261, 262, 273, 274, 275, 276, 277, 278, 279, 280,
                      282, 283, 284, 285, 286, 299, 311, 312}
    for s in sections:
        if s[1] != 4 or not sections[s[7]][2] & 2:  # SHT_RELA targeting allocated memory
            continue
        for off in range(s[4], s[4] + s[5], 24):
            addr, info, _ = struct.unpack_from('<QQq', data, off)
            kind = info & 0xFFFFFFFF
            if kind == 257:  # R_AARCH64_ABS64
                require(state[3] <= addr <= state[3] + state[5] - 8 and addr % 8 == 0,
                        'absolute relocation outside anonymous state')
                relocs.append(addr - state[3])
            else:
                require(kind in relative_types, f'unsupported relocation {kind} at {addr:#x}')
    require(len(relocs) == len(set(relocs)), 'duplicate relocation')
    symbols = by_name['.symtab']
    symbol_strings = sections[symbols[6]]
    strings = data[symbol_strings[4]:symbol_strings[4] + symbol_strings[5]]
    writable = None
    for off in range(symbols[4], symbols[4] + symbols[5], 24):
        name_off, _, _, _, value, _ = struct.unpack_from('<IBBHQQ', data, off)
        if strings[name_off:].split(b'\0', 1)[0] == b'pager_writable':
            writable = value
    require(writable is not None and state[3] <= writable <= state[3] + state[5], 'missing writable boundary')
    return code, state[3], bytes(template), sorted(relocs), h[4], writable - state[3]


def build(source, output, eager=False):
    data = source.read_bytes()
    layout = inspect(data)
    base = layout['pager_base']
    meta_addr = base + 0x200000
    output.mkdir(parents=True, exist_ok=True)
    script = output/'pager.ld'
    script.write_text(f'''ENTRY(_start)
SECTIONS {{
  . = {base:#x};
  .text : {{ *(.text .text.*) }}
  . = ALIGN(16384);
  .state : {{ *(.rodata .rodata.*) *(.data.rel.ro .data.rel.ro.*) *(.got .got.*) . = ALIGN(16384); pager_writable = .; *(.data .data.*) *(.bss .bss.*) *(COMMON) }}
  pager_config = {meta_addr:#x};
  /DISCARD/ : {{ *(.eh_frame*) *(.comment) *(.note*) }}
}}
''')
    elf = output/'pager.elf'
    subprocess.run(['zig', 'build-exe', str(ROOT/'pager_freestanding.zig'),
                    '-target', 'aarch64-freestanding-none', '-mcpu=generic+reserve_x18', '-O', 'ReleaseSmall', '-fPIC',
                    '-fno-stack-check', '-fno-stack-protector', '-fno-unwind-tables', '-fno-strip',
                    '--emit-relocs', '--script', str(script), '-femit-bin='+str(elf)], check=True)
    code, state_addr, template, relocs, entry, readonly_len = elf_image(elf)
    require(align(state_addr + len(template)) <= meta_addr, 'stub exceeds reserved address space')
    require(base <= entry < base + len(code), 'entry outside immutable code')
    # Header is read-only file data, followed by the state initializer, explicit
    # relocation offsets, frame table and compressed bytes. No runtime writes.
    template_off = align(128, 16)
    reloc_off = align(template_off + len(template), 8)
    table_off = reloc_off + len(relocs) * 8
    count = (layout['end'] - layout['start']) // PAGE
    blob_off = table_off + count * 16
    table, blob = bytearray(), bytearray()
    text_seg = next(s for s in parse(data)[2] if s['name'] == b'__TEXT')
    source_off = text_seg['fo'] + layout['start'] - text_seg['va']
    for i in range(count):
        page = data[source_off + i * PAGE:source_off + (i + 1) * PAGE]
        packed = subprocess.run(['zstd', '-19', '--zstd=wlog=14', '-q', '-c'], input=page, capture_output=True, check=True).stdout
        decoded = subprocess.run(['zstd', '-d', '-q', '-c'], input=packed, capture_output=True, check=True).stdout
        require(decoded == page, f'frame {i} does not round trip')
        checksum = 0xcbf29ce484222325
        for byte in page:
            checksum = ((checksum ^ byte) * 0x100000001b3) & 0xffffffffffffffff
        table += struct.pack('<IIQ', len(blob), len(packed), checksum)
        blob += packed
    values = [MAGIC, meta_addr, state_addr, len(template), meta_addr + template_off,
              meta_addr + reloc_off, len(relocs), layout['start'], count,
              meta_addr + table_off, meta_addr + blob_off, len(blob), layout['entry'],
              layout['sigaction'], int(eager), readonly_len]
    meta = bytearray(blob_off)
    struct.pack_into('<16Q', meta, 0, *values)
    meta[template_off:template_off + len(template)] = template
    for i, off in enumerate(relocs):
        struct.pack_into('<Q', meta, reloc_off + i * 8, off)
    meta[table_off:blob_off] = table
    meta += blob
    binary = output/'fx'
    binary.write_bytes(rewrite(data, layout, code, state_addr, len(template), meta_addr, meta, entry))
    subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(binary)], check=True)
    segments = parse(binary.read_bytes())[2]
    for s in segments:
        require(s['init'] & 6 != 6, 'initial RWX segment')
        if s['name'] == b'__PGSTATE':
            require(s['fs'] == 0 and s['init'] == 3 and s['max'] == 3, 'state must be anonymous RW')
        elif s['name'] in (b'__PGCODE', b'__TEXTB'):
            require(s['init'] == 5 and s['max'] == 5, 'code must be immutable RX')
        elif s['name'] == b'__PGMETA':
            require(s['init'] == 1 and s['max'] == 1, 'metadata must be immutable R')
    binary.chmod(0o755)
    report = dict(source=str(source), source_sha256=hashlib.sha256(data).hexdigest(),
                  stub_sources_sha256={name: hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in
                      ('pager_freestanding.zig', 'contract.zig', 'build_pagerized.py', 'rewrite_macho.py')},
                  binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                  mode='eager' if eager else 'demand', pages=count, relocations=len(relocs),
                  code_bytes=len(code), state_bytes=len(template), readonly_state_bytes=readonly_len, compressed_bytes=len(blob),
                  binary_bytes=binary.stat().st_size, layout=layout,
                  segments=[{k: (v.decode() if isinstance(v, bytes) else v) for k, v in s.items() if k != 'sections'} for s in segments])
    (output/'build-report.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ('segments', 'layout')}, indent=2))
    return binary


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, default=ROOT.parent.parent/'zig-out/bin/fx')
    p.add_argument('--output-dir', type=Path, default=ROOT.parent.parent/'zig-out/pager')
    p.add_argument('--eager', action='store_true', help='decompress all pages before entering fx')
    a = p.parse_args()
    build(a.source.resolve(), a.output_dir.resolve(), a.eager)
