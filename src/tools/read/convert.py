# read_file converters (D163). Run in the session's pooled "read" kernel, or
# as `python3 -I -c <this> <kind> <path> <arg>` when no kernel is available.
# Every converter only reads. SQLite opens read-only with query_only set.
import json
import os
import re
import sys
import zipfile
import zlib
from xml.etree import ElementTree


class ConverterMissing(Exception):
    pass


def _strip_xml_text(data):
    try:
        root = ElementTree.fromstring(data)
    except ElementTree.ParseError:
        return ""
    return "".join(root.itertext())


def _ns(tag):
    return tag.rsplit("}", 1)[-1]


def _try_markitdown(path):
    try:
        from markitdown import MarkItDown
    except Exception:
        return None
    try:
        return MarkItDown().convert(path).text_content
    except Exception:
        return None


def convert_docx(path):
    text = _try_markitdown(path)
    if text is not None:
        return text
    with zipfile.ZipFile(path) as z:
        root = ElementTree.fromstring(z.read("word/document.xml"))
    out = []
    for para in root.iter():
        if _ns(para.tag) != "p":
            continue
        style = ""
        parts = []
        for node in para.iter():
            name = _ns(node.tag)
            if name == "pStyle":
                style = next((v for k, v in node.attrib.items() if k.endswith("val")), "")
            elif name == "t" and node.text:
                parts.append(node.text)
            elif name == "tab":
                parts.append("\t")
        line = "".join(parts)
        m = re.match(r"Heading(\d)", style or "")
        if m and line:
            line = "#" * int(m.group(1)) + " " + line
        elif style.startswith("List") and line:
            line = "- " + line
        out.append(line)
    return "\n".join(out)


def convert_pptx(path):
    text = _try_markitdown(path)
    if text is not None:
        return text
    out = []
    with zipfile.ZipFile(path) as z:
        names = [n for n in z.namelist() if re.match(r"ppt/slides/slide\d+\.xml$", n)]
        names.sort(key=lambda n: int(re.findall(r"\d+", n)[-1]))
        for index, name in enumerate(names, 1):
            root = ElementTree.fromstring(z.read(name))
            out.append(f"## Slide {index}")
            for para in root.iter():
                if _ns(para.tag) != "p":
                    continue
                line = "".join(n.text or "" for n in para.iter() if _ns(n.tag) == "t")
                if line.strip():
                    out.append(line)
            out.append("")
    return "\n".join(out)


def _col_index(ref):
    letters = re.match(r"[A-Z]+", ref or "A").group(0)
    value = 0
    for ch in letters:
        value = value * 26 + (ord(ch) - 64)
    return value - 1


def convert_xlsx(path):
    text = _try_markitdown(path)
    if text is not None:
        return text
    out = []
    with zipfile.ZipFile(path) as z:
        shared = []
        if "xl/sharedStrings.xml" in z.namelist():
            for si in ElementTree.fromstring(z.read("xl/sharedStrings.xml")):
                shared.append("".join(n.text or "" for n in si.iter() if _ns(n.tag) == "t"))
        workbook = ElementTree.fromstring(z.read("xl/workbook.xml"))
        sheet_names = [s.attrib.get("name", "") for s in workbook.iter() if _ns(s.tag) == "sheet"]
        sheets = sorted(
            (n for n in z.namelist() if re.match(r"xl/worksheets/sheet\d+\.xml$", n)),
            key=lambda n: int(re.findall(r"\d+", n)[-1]),
        )
        for index, name in enumerate(sheets):
            title = sheet_names[index] if index < len(sheet_names) else name
            out.append(f"## {title}")
            root = ElementTree.fromstring(z.read(name))
            rows = 0
            for row in root.iter():
                if _ns(row.tag) != "row":
                    continue
                cells = {}
                for cell in row:
                    if _ns(cell.tag) != "c":
                        continue
                    kind = cell.attrib.get("t")
                    value = None
                    for child in cell:
                        if _ns(child.tag) == "v":
                            value = child.text
                        elif _ns(child.tag) == "is":
                            value = "".join(n.text or "" for n in child.iter() if _ns(n.tag) == "t")
                    if value is None:
                        continue
                    if kind == "s":
                        value = shared[int(value)] if int(value) < len(shared) else value
                    cells[_col_index(cell.attrib.get("r"))] = value
                if not cells:
                    continue
                width = max(cells) + 1
                out.append("| " + " | ".join(str(cells.get(i, "")).replace("|", "\\|") for i in range(width)) + " |")
                rows += 1
                if rows == 1:
                    out.append("|" + " --- |" * width)
            out.append("")
    return "\n".join(out)


def convert_epub(path):
    text = _try_markitdown(path)
    if text is not None:
        return text
    out = []
    with zipfile.ZipFile(path) as z:
        container = ElementTree.fromstring(z.read("META-INF/container.xml"))
        opf_path = next(n.attrib["full-path"] for n in container.iter() if _ns(n.tag) == "rootfile")
        opf = ElementTree.fromstring(z.read(opf_path))
        base = os.path.dirname(opf_path)
        manifest = {n.attrib.get("id"): n.attrib.get("href") for n in opf.iter() if _ns(n.tag) == "item"}
        for ref in (n for n in opf.iter() if _ns(n.tag) == "itemref"):
            href = manifest.get(ref.attrib.get("idref"))
            if not href:
                continue
            member = os.path.normpath(os.path.join(base, href)).replace("\\", "/")
            try:
                html = z.read(member).decode("utf-8", "replace")
            except KeyError:
                continue
            out.append(_html_text(html))
    return "\n\n".join(t for t in out if t.strip())


def _html_text(html):
    html = re.sub(r"(?is)<(script|style).*?</\1>", "", html)
    html = re.sub(r"(?i)<h([1-6])[^>]*>", lambda m: "\n" + "#" * int(m.group(1)) + " ", html)
    html = re.sub(r"(?i)<(br|/p|/div|/li|/h[1-6])[^>]*>", "\n", html)
    html = re.sub(r"(?i)<li[^>]*>", "- ", html)
    text = re.sub(r"<[^>]+>", "", html)
    import html as html_mod

    text = html_mod.unescape(text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


# ---- PDF ---------------------------------------------------------------

def convert_pdf(path):
    try:
        import pypdf
    except Exception:
        pypdf = None
    if pypdf is not None:
        reader = pypdf.PdfReader(path)
        pages = []
        for index, page in enumerate(reader.pages, 1):
            pages.append(f"## Page {index}\n" + (page.extract_text() or "").strip())
        return "\n\n".join(pages)
    text = _try_markitdown(path)
    if text is not None:
        return text
    pages = _pdf_fallback(path)
    if not any(p.strip() for p in pages):
        raise ConverterMissing(
            "no text could be extracted without a PDF library; install pypdf (pip install pypdf) and read again"
        )
    note = "(extracted without pypdf; layout may be rough. pip install pypdf for better text)\n\n"
    return note + "\n\n".join(f"## Page {i}\n{p.strip()}" for i, p in enumerate(pages, 1))


def _pdf_fallback(path):
    data = open(path, "rb").read()
    streams = []
    for m in re.finditer(rb"<<(.*?)>>\s*stream\r?\n", data, re.S):
        start = m.end()
        end = data.find(b"endstream", start)
        if end < 0:
            continue
        raw = data[start:end].rstrip(b"\r\n")
        if b"FlateDecode" in m.group(1):
            try:
                raw = zlib.decompress(raw)
            except zlib.error:
                try:
                    raw = zlib.decompressobj().decompress(raw)
                except zlib.error:
                    continue
        if b"BT" in raw and (b"Tj" in raw or b"TJ" in raw):
            streams.append(raw)
    return [_pdf_stream_text(s) for s in streams]


def _pdf_string(token):
    out = bytearray()
    i = 1
    while i < len(token) - 1:
        c = token[i]
        if c == 0x5C and i + 1 < len(token) - 1:
            n = token[i + 1]
            mapping = {ord("n"): 10, ord("r"): 13, ord("t"): 9, ord("("): 40, ord(")"): 41, 0x5C: 0x5C}
            if n in mapping:
                out.append(mapping[n])
                i += 2
                continue
            if 48 <= n <= 55:
                digits = token[i + 1 : i + 4]
                octal = re.match(rb"[0-7]{1,3}", digits).group(0)
                out.append(int(octal, 8) & 0xFF)
                i += 1 + len(octal)
                continue
            i += 1
            continue
        out.append(c)
        i += 1
    return out.decode("latin-1")


def _pdf_stream_text(stream):
    lines = []
    current = []
    token_re = re.compile(rb"\((?:\\.|[^\\)])*\)|\[[^\]]*\]\s*TJ|T\*|Td|TD|Tj|'|\"|ET")
    for m in token_re.finditer(stream):
        tok = m.group(0)
        if tok.startswith(b"("):
            current.append(_pdf_string(tok))
        elif tok.endswith(b"TJ"):
            for s in re.findall(rb"\((?:\\.|[^\\)])*\)", tok):
                current.append(_pdf_string(s))
        elif tok in (b"T*", b"Td", b"TD", b"'", b'"', b"ET"):
            if current:
                lines.append("".join(current))
                current = []
    if current:
        lines.append("".join(current))
    return "\n".join(lines)


# ---- SQLite ------------------------------------------------------------

def _sqlite_connect(path):
    import sqlite3
    from urllib.parse import quote

    conn = sqlite3.connect(f"file:{quote(os.path.abspath(path))}?mode=ro", uri=True)
    conn.execute("PRAGMA query_only = 1")
    return conn


def _table(rows, headers):
    def cell(v):
        if v is None:
            return "NULL"
        if isinstance(v, bytes):
            return f"<{len(v)} bytes>"
        s = str(v).replace("\n", "\\n").replace("|", "\\|")
        return s if len(s) <= 120 else s[:120] + "…"

    out = ["| " + " | ".join(headers) + " |", "|" + " --- |" * len(headers)]
    for row in rows:
        out.append("| " + " | ".join(cell(v) for v in row) + " |")
    return "\n".join(out)


def convert_sqlite(path, spec):
    from urllib.parse import unquote

    name = os.path.basename(path)
    query = {}
    if "?" in spec:
        spec, qs = spec.split("?", 1)
        # q= takes the rest of the string as written, so a query may hold & or +.
        if qs.startswith("q="):
            query["q"] = unquote(qs[2:])
            qs = ""
        elif "&q=" in qs:
            qs, q = qs.split("&q=", 1)
            query["q"] = unquote(q)
        for part in filter(None, qs.split("&")):
            key, _, value = part.partition("=")
            query[key] = unquote(value)
    limit = int(query.get("limit", "20") or 20)
    limit = max(1, min(limit, 500))
    conn = _sqlite_connect(path)
    try:
        if "q" in query:
            sql = query["q"].strip().rstrip(";")
            if not re.match(r"(?is)^\s*(select|with|pragma|explain)\b", sql):
                return "Refused: only SELECT, WITH, PRAGMA and EXPLAIN queries run; the database opens read-only."
            cur = conn.execute(sql)
            rows = cur.fetchmany(limit + 1)
            headers = [d[0] for d in cur.description or []]
            more = len(rows) > limit
            text = _table(rows[:limit], headers) if headers else "(no result columns)"
            return f"{name} · query\n{text}" + (f"\n… more rows; raise ?limit= (max 500)" if more else "")
        if not spec:
            tables = conn.execute(
                "SELECT name, type FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name"
            ).fetchall()
            out = [f"SQLite {name} · {len(tables)} table{'' if len(tables) == 1 else 's'}"]
            for table, kind in tables:
                try:
                    count = conn.execute(f'SELECT count(*) FROM "{table}"').fetchone()[0]
                except Exception:
                    count = "?"
                cols = [r[1] for r in conn.execute(f'PRAGMA table_info("{table}")')]
                out.append(f"- {table} ({kind}, {count} rows): {', '.join(cols)}")
            out.append(f"Read a table as {name}:<table>, a row as {name}:<table>:<key>, or a query as {name}?q=SELECT ...")
            return "\n".join(out)
        table, _, key = spec.partition(":")
        exists = conn.execute(
            "SELECT sql FROM sqlite_master WHERE name = ? AND type IN ('table','view')", (table,)
        ).fetchone()
        if not exists:
            names = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'")]
            return f"No table {table} in {name}. Tables: {', '.join(names) or 'none'}"
        info = list(conn.execute(f'PRAGMA table_info("{table}")'))
        headers = [r[1] for r in info]
        if key:
            pk = [r[1] for r in info if r[5]]
            column = pk[0] if len(pk) == 1 else "rowid"
            rows = conn.execute(f'SELECT * FROM "{table}" WHERE "{column}" = ?', (key,)).fetchall()
            if not rows and key.isdigit():
                rows = conn.execute(f'SELECT * FROM "{table}" WHERE "{column}" = ?', (int(key),)).fetchall()
            if not rows:
                return f"No row in {table} where {column} = {key}"
            return "\n".join(f"{h}: {v!r}" for h, v in zip(headers, rows[0]))
        where = query.get("where", "")
        sql = f'SELECT * FROM "{table}"' + (f" WHERE {where}" if where else "") + f" LIMIT {limit + 1}"
        rows = conn.execute(sql).fetchall()
        total = conn.execute(f'SELECT count(*) FROM "{table}"' + (f" WHERE {where}" if where else "")).fetchone()[0]
        out = [f"{name} › {table} · {total} rows", exists[0] or "", _table(rows[:limit], headers)]
        if total > limit:
            out.append(f"… {total - min(total, limit)} more rows; use ?limit=N (max 500) or ?where=")
        return "\n".join(out)
    finally:
        conn.close()


CONVERTERS = {
    "pdf": convert_pdf,
    "docx": convert_docx,
    "pptx": convert_pptx,
    "xlsx": convert_xlsx,
    "epub": convert_epub,
}


def run(kind, path, arg=""):
    try:
        if kind == "sqlite":
            return {"ok": True, "text": convert_sqlite(path, arg)}
        return {"ok": True, "text": CONVERTERS[kind](path)}
    except ConverterMissing as exc:
        return {"ok": False, "error": str(exc)}
    except Exception as exc:
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}


if __name__ == "__main__":
    sys.stdout.write(json.dumps(run(*sys.argv[1:4])))
