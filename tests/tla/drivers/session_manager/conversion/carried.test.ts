// The state D56 says the converter carries besides the conversation, each
// checked as the content oracle checks the conversation. The older build (v1)
// makes the state through the real binary; the conversion is observed as in
// runtime.test.ts; then the state is read back from two copies of the profile
// before the conversion, one continued with v1 and one opened with v2. A
// reading that differs marks the v2 copy as matching no v1 version, so TLC
// rejects the run. Each control reads two v1 copies and requires the same
// reading, showing the state.
import { expect } from "bun:test";
import assert from "node:assert/strict";
import { cpSync } from "node:fs";
import { join } from "node:path";
import { observer, openVia, plainReplies, readBack, requireAccepted, scenario } from "./driver";
import { KINDS } from "./recipes";

for (const [kind, { name, make, via, shows }] of Object.entries(KINDS)) {
  scenario(`control: two v1 copies read back the same ${name}`, async f => {
    const made = await make(f);
    const snapshot = join(f.root, "snapshot");
    cpSync(f.home, snapshot, { recursive: true, preserveTimestamps: true });
    const [first, second] = await readBack(f, snapshot, kind, [false, false], made.read);
    expect(first).toMatch(shows);
    expect(second).toBe(first);
  });

  scenario(`the conversion carries the ${name}`, async f => {
    const made = await make(f);
    const o = observer(f, made.id);
    await o.observe("create");
    const snapshot = join(f.root, "snapshot");
    cpSync(f.home, snapshot, { recursive: true, preserveTimestamps: true });
    await o.observe("list");
    plainReplies(f);
    await o.observe("open", await openVia(f, made.id, via));
    await o.observe("list");
    const [v1, v2] = await readBack(f, snapshot, kind, [false, true], made.read);
    assert.match(v1 ?? "", shows, `the v1 read-back of the ${name} shows nothing to compare`);
    o.content.carried[kind] = v1 === v2;
    await requireAccepted(o, kind);
  });
}
