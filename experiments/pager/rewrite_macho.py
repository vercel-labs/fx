#!/usr/bin/env python3
"""Bounded arm64 Mach-O parser and guest-only pager layout writer.

No input or output binary is executed. Unknown offset-bearing commands and
unsupported fixups are rejected instead of being copied speculatively.
"""
import struct

PAGE = 16384
SEGMENT = 0x19
MAIN = 0x80000028
SYMTAB = 2
DYSYMTAB = 0xB
SIGNATURE = 0x1D
CHAINED = 0x80000034
EXPORTS = 0x80000033
DYLD_INFO = 0x80000022
LINKEDIT_DATA = {SIGNATURE, CHAINED, EXPORTS, 0x26, 0x29}


def align(n, alignment=PAGE):
    return (n + alignment - 1) & -alignment


def require(condition, message):
    if not condition:
        raise ValueError(message)


def parse(data):
    require(len(data) >= 32, "truncated Mach-O header")
    hdr = struct.unpack_from('<8I', data)
    require(hdr[0] == 0xFEEDFACF and hdr[1] == 0x100000C, "expected arm64 Mach-O")
    require(hdr[3] == 2 and hdr[6] & 0x200000, "expected PIE executable")
    end = 32 + hdr[5]
    require(end <= len(data), "truncated load commands")
    commands = []
    segments = []
    off = 32
    for _ in range(hdr[4]):
        require(off + 8 <= end, "truncated load command")
        cmd, size = struct.unpack_from('<II', data, off)
        require(size >= 8 and size % 8 == 0 and off + size <= end, "invalid load command size")
        raw = data[off:off + size]
        commands.append((cmd, raw))
        if cmd == SEGMENT:
            require(size >= 72, "truncated segment")
            f = struct.unpack_from('<II16sQQQQiiII', raw)
            require(size == 72 + 80 * f[9], "invalid section count")
            seg = dict(name=f[2].rstrip(b'\0'), va=f[3], vs=f[4], fo=f[5], fs=f[6],
                       max=f[7], init=f[8], flags=f[10], sections=[])
            require(seg['fs'] <= seg['vs'] and seg['fo'] + seg['fs'] <= len(data), "segment out of file bounds")
            for n in range(f[9]):
                s = list(struct.unpack_from('<16s16sQQ8I', raw, 72 + n * 80))
                require(s[6] == 0 and s[7] == 0, "section relocations unsupported")
                seg['sections'].append(s)
            segments.append(seg)
        off += size
    require(off == end, "load command size mismatch")
    return hdr, commands, segments


def segment_command(s):
    sections = s['sections']
    return struct.pack('<II16sQQQQiiII', SEGMENT, 72 + 80 * len(sections), s['name'],
                       s['va'], s['vs'], s['fo'], s['fs'], s['max'], s['init'], len(sections), s['flags']) + b''.join(
                           struct.pack('<16s16sQQ8I', *sec) for sec in sections)


def inspect(data):
    hdr, commands, segments = parse(data)
    by_name = {s['name']: s for s in segments}
    require(set(by_name) == {b'__PAGEZERO', b'__TEXT', b'__DATA_CONST', b'__DATA', b'__LINKEDIT'}, "unsupported input segments")
    text = by_name[b'__TEXT']
    sec = next(s for s in text['sections'] if s[0].rstrip(b'\0') == b'__text')
    start = align(max(sec[2], text['va'] + 32 + hdr[5]))
    end = (sec[2] + sec[3]) & -PAGE
    require(start < end and (end - start) // PAGE <= 4096, "invalid pageable text range")
    main = next(raw for cmd, raw in commands if cmd == MAIN)
    entry = text['va'] + struct.unpack_from('<Q', main, 8)[0]
    # Resolve the actual imported sigaction stub from the indirect symbol table.
    sym = next(raw for cmd, raw in commands if cmd == SYMTAB)
    _, _, symoff, count, stroff, strsize = struct.unpack('<6I', sym)
    require(symoff + 16 * count <= len(data) and stroff + strsize <= len(data), "invalid symbols")
    dysym = next(raw for cmd, raw in commands if cmd == DYSYMTAB)
    ds = struct.unpack('<20I', dysym)
    indirect, ni = ds[14:16]
    require(indirect + 4 * ni <= len(data), "invalid indirect symbols")
    sigaction = None
    for s in text['sections']:
        if s[8] & 0xFF != 8:  # S_SYMBOL_STUBS
            continue
        require(s[10] > 0 and s[3] % s[10] == 0, "invalid stub size")
        for i in range(s[3] // s[10]):
            idx = s[9] + i
            require(idx < ni, "stub indirect index out of bounds")
            symbol = struct.unpack_from('<I', data, indirect + idx * 4)[0]
            if symbol & 0xC0000000:
                continue
            require(symbol < count, "stub symbol out of bounds")
            nameoff = struct.unpack_from('<I', data, symoff + symbol * 16)[0]
            require(nameoff < strsize, "symbol name out of bounds")
            name = data[stroff + nameoff:stroff + strsize].split(b'\0', 1)[0]
            if name == b'_sigaction':
                sigaction = s[2] + i * s[10]
    require(sigaction is not None and sigaction >= end, "missing resident sigaction stub")
    return dict(start=start, end=end, entry=entry, sigaction=sigaction,
                base=text['va'], pager_base=align(max(s['va'] + s['vs'] for s in segments if s['name'] != b'__LINKEDIT')))


def rewrite(data, layout, code, state_addr, state_len, meta_addr, meta, entry):
    hdr, commands, original = parse(data)
    text = next(s for s in original if s['name'] == b'__TEXT')
    le = next(s for s in original if s['name'] == b'__LINKEDIT')
    start, end = layout['start'], layout['end']
    segments = []
    contents = {}
    for old in original:
        s = {**old, 'sections': [list(sec) for sec in old['sections']]}
        if s['name'] == b'__TEXT':
            prefix = next(sec for sec in s['sections'] if sec[0].rstrip(b'\0') == b'__text')
            tail_size = prefix[2] + prefix[3] - end
            prefix[3] = start - prefix[2]
            s.update(vs=end - s['va'], fs=start - s['va'], max=7, init=5, sections=[prefix])
            segments.append(s)
            contents[s['name']] = data[old['fo']:old['fo'] + s['fs']]
            tail_sections = [list(sec) for sec in old['sections'] if sec[0].rstrip(b'\0') != b'__text']
            if tail_size:
                tail_sections.insert(0, [b'__text_tail', b'__TEXTB', end, tail_size,
                                        old['fo'] + end - old['va'], 2, 0, 0, 0x80000400, 0, 0, 0])
            for sec in tail_sections:
                sec[1] = b'__TEXTB'
            tail = dict(name=b'__TEXTB', va=end, vs=old['va'] + old['vs'] - end,
                        fo=old['fo'] + end - old['va'], fs=old['fs'] - (end - old['va']),
                        max=5, init=5, flags=0, sections=tail_sections)
            segments.append(tail)
            contents[tail['name']] = data[tail['fo']:tail['fo'] + tail['fs']]
        elif s['name'] == b'__LINKEDIT':
            for name, va, content, vs, prot in (
                (b'__PGCODE', layout['pager_base'], code, align(len(code)), 5),
                (b'__PGSTATE', state_addr, b'', align(state_len), 3),
                (b'__PGMETA', meta_addr, meta, align(len(meta)), 1),
            ):
                segments.append(dict(name=name, va=va, vs=vs, fo=0, fs=len(content), max=prot, init=prot, flags=0, sections=[]))
                contents[name] = content
            s['va'] = align(meta_addr + len(meta))
            segments.append(s)
        else:
            segments.append(s)
            contents[s['name']] = data[s['fo']:s['fo'] + s['fs']]
    # Rewrite fixup segment indices and their image-relative virtual offsets.
    fixup_lc = next((raw for cmd, raw in commands if cmd == CHAINED), None)
    new_payload = None
    old_fix_end = 0
    growth = 0
    if fixup_lc:
        fixoff, fixsize = struct.unpack_from('<II', fixup_lc, 8)
        payload = data[fixoff:fixoff + fixsize]
        require(len(payload) == fixsize and fixsize >= 28, "invalid fixup payload")
        fields = list(struct.unpack_from('<7I', payload))
        _, starts, imports, symbols, _, _, _ = fields
        count = struct.unpack_from('<I', payload, starts)[0]
        require(count == len(original), "fixup segment count mismatch")
        old_offsets = struct.unpack_from('<' + 'I' * count, payload, starts + 4)
        blobs = {}
        old_end = starts + 4 + 4 * count
        for s, offset in zip(original, old_offsets):
            if not offset:
                continue
            pos = starts + offset
            size = struct.unpack_from('<I', payload, pos)[0]
            require(size >= 22 and pos + size <= len(payload), "invalid fixup starts")
            require(s['name'] != b'__TEXT', "fixups in paged text unsupported")
            b = bytearray(payload[pos:pos + size])
            blobs[s['name']] = b
            old_end = max(old_end, pos + size)
        require(imports >= old_end and symbols >= old_end, "overlapping fixup regions")
        body = bytearray(struct.pack('<I', len(segments)) + bytes(4 * len(segments)))
        for i, s in enumerate(segments):
            if s['name'] in blobs:
                b = blobs[s['name']]
                struct.pack_into('<Q', b, 8, s['va'] - layout['base'])
                struct.pack_into('<I', body, 4 + i * 4, len(body))
                body += b
        growth = len(body) - (old_end - starts)
        fields[2] += growth
        fields[3] += growth
        new_payload = struct.pack('<7I', *fields) + payload[28:starts] + body + payload[old_end:]
        old_fix_end = fixoff + fixsize
        le_content = bytearray(data[le['fo']:le['fo'] + le['fs']])
        le_content[fixoff-le['fo']:old_fix_end-le['fo']] = new_payload
        contents[b'__LINKEDIT'] = bytes(le_content)
    else:
        legacy = next((raw for cmd, raw in commands if cmd == DYLD_INFO), None)
        require(legacy is not None, 'requires dyld fixups')
        contents[b'__LINKEDIT'] = data[le['fo']:le['fo'] + le['fs']]
        le_content = bytearray(contents[b'__LINKEDIT'])
        fields = struct.unpack_from('<10I', legacy, 8)
        index_map = {i: next(j for j, n in enumerate(segments) if n['name'] == s['name'])
                     for i, s in enumerate(original)}
        for stream in range(4):
            off, size = fields[stream * 2:stream * 2 + 2]
            if not size:
                continue
            require(le['fo'] <= off and off + size <= le['fo'] + le['fs'], 'legacy fixups outside LINKEDIT')
            begin = off - le['fo']
            payload = le_content[begin:begin + size]
            rewrite_opcodes(payload, index_map, is_bind=stream != 0)
            le_content[begin:begin + size] = payload
        contents[b'__LINKEDIT'] = bytes(le_content)
    cursor = 0
    for s in segments:
        old_fo = s['fo']
        s['fo'] = align(cursor) if s['fs'] else 0
        if s['name'] == b'__LINKEDIT':
            s['fs'] = len(contents[s['name']])
            s['vs'] = align(s['fs'])
        for sec in s['sections']:
            if sec[4]:
                sec[4] += s['fo'] - old_fo
        if s['fs']:
            cursor = s['fo'] + s['fs']
    new_le = next(s for s in segments if s['name'] == b'__LINKEDIT')
    def remap(off):
        if off == 0:
            return 0
        require(le['fo'] <= off < le['fo'] + le['fs'], 'offset outside LINKEDIT')
        return off - le['fo'] + new_le['fo'] + (growth if off >= old_fix_end else 0)
    out_cmds = [segment_command(s) for s in segments]
    # Commands without file offsets, or handled explicitly below.
    passthrough = {0x1B, 0xE, 0xC, 0x80000018, 0x8000001F, 0x8000001C, 0x32, 0x24, 0x2A, 0x2B}
    for cmd, raw in commands:
        b = bytearray(raw)
        if cmd in (SEGMENT, SIGNATURE):
            continue
        if cmd == MAIN:
            struct.pack_into('<Q', b, 8, entry - layout['base'])
        elif cmd in LINKEDIT_DATA:
            off, size = struct.unpack_from('<II', b, 8)
            struct.pack_into('<II', b, 8, remap(off), size + (growth if cmd == CHAINED else 0))
        elif cmd == DYLD_INFO:
            for pos in (8, 16, 24, 32, 40):
                struct.pack_into('<I', b, pos, remap(struct.unpack_from('<I', b, pos)[0]))
        elif cmd == SYMTAB:
            for pos in (8, 16):
                struct.pack_into('<I', b, pos, remap(struct.unpack_from('<I', b, pos)[0]))
        elif cmd == DYSYMTAB:
            for pos in (32, 40, 48, 56, 64, 72):
                struct.pack_into('<I', b, pos, remap(struct.unpack_from('<I', b, pos)[0]))
        else:
            require(cmd in passthrough, f'unsupported load command {cmd:#x}')
        out_cmds.append(bytes(b))
    blob = b''.join(out_cmds)
    require(32 + len(blob) <= start - layout['base'], 'load commands overlap resident code')
    first_text = next(sec for sec in text['sections'] if sec[0].rstrip(b'\0') == b'__text')
    require(32 + len(blob) <= first_text[4], 'new load commands overwrite original code')
    out = bytearray(cursor)
    for s in segments:
        if s['fs']:
            out[s['fo']:s['fo'] + s['fs']] = contents[s['name']]
    hdr = list(hdr)
    hdr[4], hdr[5] = len(out_cmds), len(blob)
    out[:32] = struct.pack('<8I', *hdr)
    out[32:32 + len(blob)] = blob
    return bytes(out)


def rewrite_opcodes(payload, index_map, is_bind):
    """Change segment ordinals while preserving the byte length of dyld streams."""
    pos = 0
    def leb():
        nonlocal pos
        for _ in range(10):
            require(pos < len(payload), 'truncated LEB128')
            byte = payload[pos]
            pos += 1
            if byte < 128:
                return
        raise ValueError('oversized LEB128')
    while pos < len(payload):
        byte = payload[pos]
        op = byte & 0xF0
        if op == (0x70 if is_bind else 0x20):
            index = byte & 15
            require(index in index_map and index_map[index] < 16, 'invalid segment ordinal')
            # Rewriting text pointers would conflict with compressed original bytes.
            require(index != 1, 'fixups in text unsupported')
            payload[pos] = op | index_map[index]
            pos += 1
            leb()
        else:
            pos += 1
            if is_bind:
                require(op in (0, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x80, 0x90, 0xA0, 0xB0, 0xC0), 'unsupported bind opcode')
                if op == 0x40:
                    while pos < len(payload) and payload[pos] != 0:
                        pos += 1
                    require(pos < len(payload), 'unterminated symbol')
                    pos += 1
                elif op in (0x20, 0x60, 0x80, 0xA0):
                    leb()
                elif op == 0xC0:
                    leb()
                    leb()
            else:
                require(op in (0, 0x10, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80), 'unsupported rebase opcode')
                if op in (0x30, 0x60, 0x70, 0x80):
                    leb()
                    if op == 0x80:
                        leb()
