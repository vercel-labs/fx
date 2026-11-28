#!/usr/bin/env node
// Reports how many code bytes each Zig namespace takes in a libfx artifact that
// keeps function names: fx-core.wasm (its name section), or the Node-API addon
// built with -Dlibfx-symbols=true (its ELF .symtab). CI's SDK package guards job
// prints this report as information only; it never fails on the sizes.
//
//   node sdk/scripts/report-namespace-sizes.mjs <file>...
//
// The Markdown goes to stdout, and is also appended to $GITHUB_STEP_SUMMARY
// when that variable is set.
import { appendFileSync, readFileSync } from "node:fs";
import { basename } from "node:path";

const TOP_GROUP_COUNT = 30;
const NEVER_RUN_NAMESPACES = [
  "core.mcp_host",
  "mcp",
  "core.mcp",
  "core.terminal",
  "core.subagent",
  "core.skills",
  "core.shell_command",
  "core.indexer",
  "core.execution",
  "core.workspace",
  "http",
  "crypto",
];
const TWO_SEGMENT_NAMESPACE_ROOTS = new Set(["core", "tools", "acp"]);
const UNNAMED_NAMESPACE = "<unnamed>";
const USAGE = "usage: node sdk/scripts/report-namespace-sizes.mjs <file>...";
const PERCENT = 100;
const TABLE_HEADER = "| Namespace | Bytes | Share | Functions |";
const TABLE_RULE = "| --- | ---: | ---: | ---: |";

const WASM_MAGIC = [0x00, 0x61, 0x73, 0x6d];
const WASM_VERSION = 1;
const WASM_HEADER_BYTES = 8;
const WASM_IMPORT_SECTION = 2;
const WASM_CODE_SECTION = 10;
const WASM_CUSTOM_SECTION = 0;
const WASM_NAME_SECTION_NAME = "name";
const WASM_FUNCTION_NAMES_SUBSECTION = 1;
const WASM_KIND_FUNCTION = 0;
const WASM_KIND_TABLE = 1;
const WASM_KIND_MEMORY = 2;
const WASM_KIND_GLOBAL = 3;
const WASM_KIND_TAG = 4;
const WASM_LIMITS_HAS_MAX = 0x01;
const WASM_REFTYPE_BYTES = 1;
const WASM_GLOBAL_TYPE_BYTES = 2;
const WASM_TAG_ATTRIBUTE_BYTES = 1;

const ELF_MAGIC = [0x7f, 0x45, 0x4c, 0x46];
const ELF64_HEADER_BYTES = 64;
const ELF_CLASS_OFFSET = 4;
const ELF_CLASS_64 = 2;
const ELF_DATA_OFFSET = 5;
const ELF_DATA_LITTLE_ENDIAN = 1;
const ELF_SECTION_TABLE_OFFSET_AT = 0x28;
const ELF_SECTION_ENTRY_BYTES_AT = 0x3a;
const ELF_SECTION_COUNT_AT = 0x3c;
const ELF_SECTION_TYPE_SYMTAB = 2;
const ELF64_SYMBOL_BYTES = 24;
const ELF_SYMBOL_TYPE_FUNC = 2;
const ELF_SYMBOL_TYPE_MASK = 0x0f;

class ByteCursor {
  constructor(bytes, offset, end) {
    this.bytes = bytes;
    this.offset = offset;
    this.end = end;
  }

  isAtEnd() {
    return this.offset >= this.end;
  }

  requireBytes(count) {
    if (this.offset + count > this.end) {
      throw new Error(`unexpected end of data at byte ${this.offset}`);
    }
  }

  skip(count) {
    this.requireBytes(count);
    this.offset += count;
  }

  readByte() {
    this.requireBytes(1);
    const value = this.bytes[this.offset];
    this.offset += 1;
    return value;
  }

  readUleb128() {
    let value = 0;
    let scale = 1;
    let byte;
    do {
      byte = this.readByte();
      value += (byte & 0x7f) * scale;
      scale *= 128;
    } while (byte & 0x80);
    return value;
  }

  readName() {
    const length = this.readUleb128();
    this.requireBytes(length);
    const text = this.bytes.toString("utf8", this.offset, this.offset + length);
    this.offset += length;
    return text;
  }

  skipName() {
    this.skip(this.readUleb128());
  }

  slice(count) {
    this.requireBytes(count);
    const part = new ByteCursor(this.bytes, this.offset, this.offset + count);
    this.offset += count;
    return part;
  }
}

function hasMagic(bytes, magic) {
  return magic.every((byte, index) => bytes[index] === byte);
}

function detectFormat(bytes) {
  if (hasMagic(bytes, WASM_MAGIC)) return "wasm";
  if (!hasMagic(bytes, ELF_MAGIC)) throw new Error("is neither a wasm module nor an ELF file");
  if (bytes.length < ELF64_HEADER_BYTES) throw new Error("is too short for an ELF64 header");
  if (bytes[ELF_CLASS_OFFSET] !== ELF_CLASS_64 || bytes[ELF_DATA_OFFSET] !== ELF_DATA_LITTLE_ENDIAN) {
    throw new Error("is not an ELF64 little-endian file");
  }
  return "elf";
}

function findSection(sections, id) {
  return sections.find((section) => section.id === id)?.payload ?? null;
}

function readWasmSections(bytes) {
  if (bytes.length < WASM_HEADER_BYTES || bytes.readUInt32LE(4) !== WASM_VERSION) {
    throw new Error("is a wasm file of an unsupported version");
  }
  const cursor = new ByteCursor(bytes, WASM_HEADER_BYTES, bytes.length);
  const sections = [];
  while (!cursor.isAtEnd()) {
    const id = cursor.readByte();
    const size = cursor.readUleb128();
    sections.push({ id, payload: cursor.slice(size) });
  }
  return sections;
}

function skipLimits(cursor) {
  const flags = cursor.readByte();
  cursor.readUleb128();
  if (flags & WASM_LIMITS_HAS_MAX) cursor.readUleb128();
}

function skipImportDescriptor(cursor, kind) {
  switch (kind) {
    case WASM_KIND_FUNCTION:
      cursor.readUleb128();
      return;
    case WASM_KIND_TABLE:
      cursor.skip(WASM_REFTYPE_BYTES);
      skipLimits(cursor);
      return;
    case WASM_KIND_MEMORY:
      skipLimits(cursor);
      return;
    case WASM_KIND_GLOBAL:
      cursor.skip(WASM_GLOBAL_TYPE_BYTES);
      return;
    case WASM_KIND_TAG:
      cursor.skip(WASM_TAG_ATTRIBUTE_BYTES);
      cursor.readUleb128();
      return;
    default:
      throw new Error(`unknown import kind ${kind}`);
  }
}

function readImportKind(cursor) {
  cursor.skipName();
  cursor.skipName();
  const kind = cursor.readByte();
  skipImportDescriptor(cursor, kind);
  return kind;
}

function countFunctionImports(sections) {
  const imports = findSection(sections, WASM_IMPORT_SECTION);
  if (!imports) return 0;
  const importCount = imports.readUleb128();
  let functionImports = 0;
  for (let index = 0; index < importCount; index++) {
    if (readImportKind(imports) === WASM_KIND_FUNCTION) functionImports += 1;
  }
  return functionImports;
}

function addFunctionNameMap(cursor, names) {
  const count = cursor.readUleb128();
  for (let index = 0; index < count; index++) {
    const functionIndex = cursor.readUleb128();
    names.set(functionIndex, cursor.readName());
  }
}

function addNamesFromCustomSection(payload, names) {
  if (payload.readName() !== WASM_NAME_SECTION_NAME) return;
  while (!payload.isAtEnd()) {
    const subsectionId = payload.readByte();
    const subsection = payload.slice(payload.readUleb128());
    if (subsectionId === WASM_FUNCTION_NAMES_SUBSECTION) addFunctionNameMap(subsection, names);
  }
}

function readFunctionNames(sections) {
  const names = new Map();
  for (const section of sections) {
    if (section.id === WASM_CUSTOM_SECTION) addNamesFromCustomSection(section.payload, names);
  }
  return names;
}

function readCodeBodySizes(sections) {
  const code = findSection(sections, WASM_CODE_SECTION);
  if (!code) return [];
  const bodyCount = code.readUleb128();
  const sizes = [];
  for (let index = 0; index < bodyCount; index++) {
    const start = code.offset;
    code.skip(code.readUleb128());
    sizes.push(code.offset - start);
  }
  if (!code.isAtEnd()) throw new Error("the code section has bytes after its last body");
  return sizes;
}

function parseWasmFunctions(bytes) {
  const sections = readWasmSections(bytes);
  const importCount = countFunctionImports(sections);
  const names = readFunctionNames(sections);
  return readCodeBodySizes(sections).map((size, index) => ({
    name: names.get(importCount + index) || null,
    bytes: size,
  }));
}

function readElfSection(bytes, at) {
  return {
    type: bytes.readUInt32LE(at + 4),
    offset: Number(bytes.readBigUInt64LE(at + 24)),
    size: Number(bytes.readBigUInt64LE(at + 32)),
    link: bytes.readUInt32LE(at + 40),
  };
}

function readElfSections(bytes) {
  const tableOffset = Number(bytes.readBigUInt64LE(ELF_SECTION_TABLE_OFFSET_AT));
  const entryBytes = bytes.readUInt16LE(ELF_SECTION_ENTRY_BYTES_AT);
  const count = bytes.readUInt16LE(ELF_SECTION_COUNT_AT);
  if (tableOffset + count * entryBytes > bytes.length) {
    throw new Error("the section header table runs past the end of the file");
  }
  const sections = [];
  for (let index = 0; index < count; index++) {
    sections.push(readElfSection(bytes, tableOffset + index * entryBytes));
  }
  return sections;
}

function requireSectionInFile(bytes, section, label) {
  if (section.offset + section.size > bytes.length) {
    throw new Error(`${label} runs past the end of the file`);
  }
}

function readElfSymbol(bytes, at) {
  return {
    nameOffset: bytes.readUInt32LE(at),
    type: bytes[at + 4] & ELF_SYMBOL_TYPE_MASK,
    address: bytes.readBigUInt64LE(at + 8),
    size: Number(bytes.readBigUInt64LE(at + 16)),
  };
}

function readStringTableName(bytes, strtab, nameOffset) {
  const start = strtab.offset + nameOffset;
  const end = bytes.indexOf(0, start);
  if (end === -1 || end > strtab.offset + strtab.size) {
    throw new Error("a symbol name runs past its string table");
  }
  return bytes.toString("utf8", start, end);
}

function readSizedFunctionSymbols(bytes, symtab, strtab) {
  const functions = [];
  const seenAddressSizes = new Set();
  const symbolCount = Math.floor(symtab.size / ELF64_SYMBOL_BYTES);
  for (let index = 0; index < symbolCount; index++) {
    const symbol = readElfSymbol(bytes, symtab.offset + index * ELF64_SYMBOL_BYTES);
    if (symbol.type !== ELF_SYMBOL_TYPE_FUNC || symbol.size === 0) continue;
    const addressSize = `${symbol.address}:${symbol.size}`;
    if (seenAddressSizes.has(addressSize)) continue;
    seenAddressSizes.add(addressSize);
    functions.push({
      name: readStringTableName(bytes, strtab, symbol.nameOffset) || null,
      bytes: symbol.size,
    });
  }
  return functions;
}

function parseElfFunctions(bytes) {
  const sections = readElfSections(bytes);
  const symtab = sections.find((section) => section.type === ELF_SECTION_TYPE_SYMTAB);
  if (!symtab) throw new Error("has no .symtab section (build with -Dlibfx-symbols=true)");
  const strtab = sections[symtab.link];
  if (!strtab) throw new Error("its .symtab has no linked string table");
  requireSectionInFile(bytes, symtab, ".symtab");
  requireSectionInFile(bytes, strtab, "its string table");
  return readSizedFunctionSymbols(bytes, symtab, strtab);
}

const PARSERS = { wasm: parseWasmFunctions, elf: parseElfFunctions };

function splitSegments(name) {
  const segments = [];
  let depth = 0;
  let segmentStart = 0;
  for (let index = 0; index < name.length; index++) {
    const char = name[index];
    if (char === "(") depth += 1;
    else if (char === ")" && depth > 0) depth -= 1;
    else if (char === "." && depth === 0) {
      segments.push(name.slice(segmentStart, index));
      segmentStart = index + 1;
    }
  }
  segments.push(name.slice(segmentStart));
  return segments;
}

function namespaceOf(name) {
  if (name === null) return UNNAMED_NAMESPACE;
  const segments = splitSegments(name);
  if (segments.length >= 2 && TWO_SEGMENT_NAMESPACE_ROOTS.has(segments[0])) {
    return `${segments[0]}.${segments[1]}`;
  }
  return segments[0];
}

function emptyGroup(namespace) {
  return { namespace, bytes: 0, functions: 0 };
}

function compareGroups(first, second) {
  return second.bytes - first.bytes
    || second.functions - first.functions
    || (first.namespace < second.namespace ? -1 : 1);
}

function groupByNamespace(functions) {
  const groups = new Map();
  for (const fn of functions) {
    const namespace = namespaceOf(fn.name);
    const group = groups.get(namespace) ?? emptyGroup(namespace);
    group.bytes += fn.bytes;
    group.functions += 1;
    groups.set(namespace, group);
  }
  return [...groups.values()].sort(compareGroups);
}

function sumBytes(items) {
  return items.reduce((sum, item) => sum + item.bytes, 0);
}

function requireNamedFunctions(functions) {
  if (!functions.some((fn) => fn.name !== null)) {
    throw new Error("has no function names (build it with function names kept)");
  }
}

function analyzeFile(path) {
  const bytes = readFileSync(path);
  const functions = PARSERS[detectFormat(bytes)](bytes);
  requireNamedFunctions(functions);
  const groups = groupByNamespace(functions);
  const totalBytes = sumBytes(functions);
  const groupedBytes = sumBytes(groups);
  if (groupedBytes !== totalBytes) {
    throw new Error(`namespace bytes ${groupedBytes} differ from the total ${totalBytes} (parser bug)`);
  }
  return {
    path,
    fileBytes: bytes.length,
    totalBytes,
    functionCount: functions.length,
    groups,
  };
}

function formatCount(value) {
  return String(value).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function formatShare(bytes, totalBytes) {
  return `${((bytes / totalBytes) * PERCENT).toFixed(1)}%`;
}

function codeSpan(text) {
  return "`" + text + "`";
}

function renderTable(groups, totalBytes) {
  const rows = groups.map((group) => (
    `| ${codeSpan(group.namespace)} | ${formatCount(group.bytes)} | ${formatShare(group.bytes, totalBytes)} | ${formatCount(group.functions)} |`
  ));
  return [TABLE_HEADER, TABLE_RULE, ...rows].join("\n");
}

function neverRunGroups(groups) {
  return NEVER_RUN_NAMESPACES.map((namespace) => (
    groups.find((group) => group.namespace === namespace) ?? emptyGroup(namespace)
  ));
}

function renderFileReport(report) {
  return [
    `## ${basename(report.path)} (${formatCount(report.fileBytes)} bytes)`,
    "",
    `Total code: ${formatCount(report.totalBytes)} bytes in ${formatCount(report.functionCount)} functions.`,
    "",
    "### Largest namespaces",
    "",
    renderTable(report.groups.slice(0, TOP_GROUP_COUNT), report.totalBytes),
    "",
    "### Areas libfx never runs",
    "",
    renderTable(neverRunGroups(report.groups), report.totalBytes),
    "",
  ].join("\n");
}

function reportFile(path) {
  try {
    return renderFileReport(analyzeFile(path));
  } catch (error) {
    throw new Error(`${path}: ${error.message}`);
  }
}

function appendStepSummary(markdown) {
  const summaryPath = process.env.GITHUB_STEP_SUMMARY;
  if (summaryPath) appendFileSync(summaryPath, markdown);
}

function main(paths) {
  if (paths.length === 0) throw new Error(USAGE);
  const markdown = paths.map(reportFile).join("\n");
  process.stdout.write(markdown);
  appendStepSummary(markdown);
}

try {
  main(process.argv.slice(2));
} catch (error) {
  console.error(`report-namespace-sizes: ${error.message}`);
  process.exitCode = 1;
}
