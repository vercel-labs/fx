#!/usr/bin/env python3
"""Checks the named themes that ship with fx (src/core/shared/themes/).

Each named theme is a pair of files, <name>-dark.json and <name>-light.json,
and fx loads the one that matches the terminal's mode. The JSON files are
the source of truth: change a color there, then run

    python3 scripts/themes/audit.py            # every theme
    python3 scripts/themes/audit.py geist      # one theme
    python3 scripts/themes/audit.py --fit '#BF7AF0' read dark

--fit prints the nearest color, same OKLCH hue and chroma, that meets a
role's target in that mode.

A theme cannot set the terminal's background, so every color is measured on
four common backgrounds per mode and the worst one decides. Targets follow
the APCA levels (Lc 75 for running text, 60 for colored spans, 45 for
secondary text and marks, 20 for rules), with WCAG 2 ratios as a second
check. Below the floor is a failure; between the floor and the target is a
warning.

The design rules the themes follow:
- Structure is gray: text, dim text, the status line, rules, and borders
  carry at most a hint of the theme's hue (OKLCH chroma 0.03). Color goes to
  what means something: the accent, links, headings, code, diffs, warnings.
- The selected row uses the theme's accent, bold, far enough from dim text
  to stand out (CIEDE2000 20).
- Diffs use the green and red every code tool uses, in every theme. The
  +/- signs carry the meaning, so under deuteranopia the pair only needs to
  stay somewhat apart; on dark the green sits lighter than the red for that.
- Agent colors stay apart for normal vision and under deuteranopia, since
  each agent's name is shown with its color.
- geist uses only Geist color tokens (geist_palette.json, read from
  vercel.com/geist/colors).
"""
from __future__ import annotations

import json
import pathlib
import re
import sys
from dataclasses import dataclass

if __package__ in (None, ""):
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
    import color  # type: ignore[no-redef]
else:
    from . import color

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
THEMES_DIR = REPO / "src" / "core" / "shared" / "themes"
THEME_ZIG = REPO / "src" / "core" / "shared" / "theme.zig"
GEIST_PALETTE = HERE / "geist_palette.json"

BACKGROUNDS = {
    "dark": {"black": "#000000", "vscode": "#1E1E1E", "one dark": "#282C34", "dracula": "#282A36"},
    "light": {"white": "#FFFFFF", "apple": "#F5F5F5", "solarized": "#FDF6E3", "gray": "#EEEEEE"},
}

# role: (target Lc, target WCAG ratio, floor Lc)
TARGETS = {
    "body": (75, 7.0, 60),   # running text: command output, notices, prompts
    "row": (75, 4.5, 60),    # text on the selected row's background
    "read": (60, 4.5, 45),   # colored spans: code, links, diffs, labels
    "warm": (52, 4.5, 45),   # red on dark: brighter than this turns salmon
    "quiet": (45, 3.0, 30),  # secondary text: status line, comments, dim rows
    "mark": (45, 3.0, 30),   # glyphs that carry meaning: accent dot, list marks
    "edge": (20, 1.0, 15),   # rules, borders, the quote rail
}

ROLE = {
    "link": "read", "inline_code": "read", "hint": "body", "tag": "read", "subtitle": "read",
    "selected_completion": "read", "system_notice_label": "read", "system_notice_text": "body",
    "warning": "read", "green": "read", "red": "read", "diff_added": "read", "diff_removed": "read",
    "task_completed": "read", "tool_stdout": "body", "tool_stderr": "read", "heading": "read",
    "user_card_accent": "body", "permission_auto": "read",
    "statusline": "quiet", "dim": "quiet",
    "accent": "mark", "list_marker": "mark", "user_card_marker": "mark",
    "diff_added_marker": "mark", "diff_removed_marker": "mark",
    "agent_1": "read", "agent_2": "read", "agent_3": "read", "agent_4": "read", "agent_5": "read", "agent_6": "read",
    "divider": "edge", "rule": "edge", "quote": "edge",
    "s.keyword": "read", "s.string": "read", "s.number": "read", "s.function": "read", "s.variable": "read",
    "s.type": "read", "s.constant": "read", "s.operator": "read",
    "s.comment": "quiet", "s.punctuation": "quiet",
}
RED_SLOTS = ("red", "diff_removed", "diff_removed_marker")
STRUCTURE_CHROMA = {
    "hint": 0.02, "tool_stdout": 0.02, "system_notice_text": 0.02, "user_card_accent": 0.02,
    "dim": 0.03, "statusline": 0.03, "divider": 0.03, "rule": 0.03, "quote": 0.03,
    "s.punctuation": 0.03, "s.comment": 0.04,
}

# geist on dark keeps Geist's own text step for color (900). Step 1000 is a
# near-white tint that would erase the difference between hues, and nothing
# in between exists, so those colors sit below the floor on the lightest
# dark backgrounds (down to Lc 41); they still clear WCAG 2's 4.5:1.
LOWER_FLOOR = {("geist", "dark"): 40}


@dataclass
class Finding:
    level: str  # "fail" or "warn"
    message: str


def load() -> dict[str, dict[str, dict]]:
    themes: dict[str, dict[str, dict]] = {}
    for path in sorted(THEMES_DIR.glob("*-*.json")):
        name, mode = path.stem.rsplit("-", 1)
        themes.setdefault(name, {})[mode] = json.loads(path.read_text())
    return themes


def shipped_names() -> list[str]:
    """Names listed in named_themes in theme.zig."""
    return re.findall(r'shipped\("([a-z0-9-]+)"', THEME_ZIG.read_text())


def slots(theme: dict) -> dict[str, object]:
    out: dict[str, object] = dict(theme.get("colors", {}))
    out.update({"s." + k: v for k, v in theme.get("syntax", {}).items()})
    return out


def fg(value: object) -> str | None:
    return value if isinstance(value, str) else value.get("fg") if isinstance(value, dict) else None


def bg(value: object) -> str | None:
    return value.get("bg") if isinstance(value, dict) else None


def worst_lc(text: str, mode: str) -> float:
    return min(abs(color.apca(text, b)) for b in BACKGROUNDS[mode].values())


def worst_ratio(text: str, mode: str) -> float:
    return min(color.wcag_ratio(text, b) for b in BACKGROUNDS[mode].values())


def separation(background: str, mode: str) -> float:
    return min(color.ciede2000(background, b) for b in BACKGROUNDS[mode].values())


def role_of(key: str, mode: str) -> str | None:
    role = ROLE.get(key)
    if mode == "dark" and key in RED_SLOTS and role == "read":
        return "warm"
    return role


def check(name: str, mode: str, theme: dict) -> list[Finding]:
    out: list[Finding] = []
    s = slots(theme)
    lower_floor = LOWER_FLOOR.get((name, mode))

    def measure(label: str, text: str, role: str, lc: float, ratio: float) -> None:
        target_lc, target_ratio, floor = TARGETS[role]
        if lower_floor is not None and role in ("read", "warm", "mark"):
            floor = min(floor, lower_floor)
            target_ratio = min(target_ratio, 4.5)
        if lc < floor or (role in ("body", "row", "read", "warm") and ratio < 4.5):
            out.append(Finding("fail", f"{label} {text}: Lc {lc:.1f}, {ratio:.1f}:1 (floor Lc {floor}, 4.5:1)"))
        elif lc < target_lc or ratio < target_ratio:
            out.append(Finding("warn", f"{label} {text}: Lc {lc:.1f}, {ratio:.1f}:1 (target Lc {target_lc}, {target_ratio}:1)"))

    for key, value in s.items():
        role, text = role_of(key, mode), fg(value)
        if role is None or text is None or bg(value):
            continue
        measure(key, text, role, worst_lc(text, mode), worst_ratio(text, mode))
        cap = STRUCTURE_CHROMA.get(key)
        if cap is not None and color.to_oklch(text)[1] > cap + 0.005:
            out.append(Finding("warn", f"{key} {text} is colorful for structure (chroma {color.to_oklch(text)[1]:.3f}, keep under {cap})"))

    selection = s.get("approval_button_inactive")
    if isinstance(selection, dict) and selection.get("bg"):
        lc = abs(color.apca(selection["fg"], selection["bg"]))
        measure("selected row text", selection["fg"], "row", lc, color.wcag_ratio(selection["fg"], selection["bg"]))
        if separation(selection["bg"], mode) < 8:
            out.append(Finding("warn", f"selected row background {selection['bg']} barely differs from the terminal"))

    for side, red in (("added", False), ("removed", True)):
        word, text = s.get(f"diff_{side}_word"), fg(s.get(f"diff_{side}"))
        if isinstance(word, dict) and word.get("bg") and text:
            role = "warm" if red and mode == "dark" else "read"
            lc = abs(color.apca(text, word["bg"]))
            measure(f"diff_{side} on its word highlight", text, role, lc, color.wcag_ratio(text, word["bg"]))
            if separation(word["bg"], mode) < 10:
                out.append(Finding("warn", f"diff_{side}_word {word['bg']} barely stands out from the terminal"))

    def pair(a: str, b: str, label: str, normal: float, deut: float) -> None:
        if a in s and b in s:
            n, d = color.distances(fg(s[a]), fg(s[b]))
            if n < normal or d < deut:
                out.append(Finding("warn", f"{label}: CIEDE2000 {n:.1f}, {d:.1f} under deuteranopia (want {normal} and {deut})"))

    pair("diff_added", "diff_removed", "added vs removed", 20, 8)
    pair("green", "red", "success vs error", 20, 8)
    pair("warning", "red", "warning vs error", 10, 10)
    agents = [f"agent_{i}" for i in range(1, 7) if f"agent_{i}" in s]
    for i, a in enumerate(agents):
        for b in agents[i + 1:]:
            pair(a, b, f"{a} vs {b}", 18, 6)

    if "selected_completion" in s and "dim" in s:
        d = color.ciede2000(fg(s["selected_completion"]), fg(s["dim"]))
        if d < 20:
            out.append(Finding("warn", f"selected row sits close to dim text (CIEDE2000 {d:.1f}, want 20)"))
    if worst_lc(fg(s["tool_stdout"]), mode) - worst_lc(fg(s["dim"]), mode) < 20:
        out.append(Finding("warn", "text and dim text are too close in contrast (want a gap of Lc 20)"))
    if worst_lc(fg(s["statusline"]), mode) < worst_lc(fg(s["dim"]), mode):
        out.append(Finding("warn", "the status line is fainter than dim text"))
    if worst_lc(fg(s["rule"]), mode) < worst_lc(fg(s["divider"]), mode):
        out.append(Finding("warn", "markdown rules are fainter than dividers"))

    if name == "geist":
        tokens = {v.upper() for v in json.loads(GEIST_PALETTE.read_text())[mode].values()}
        for key, value in s.items():
            for c in (fg(value), bg(value)):
                if c and c.upper() not in tokens:
                    out.append(Finding("fail", f"{key} {c} is not a Geist color token"))
    return out


def fit(text: str, role: str, mode: str) -> str:
    """The nearest color, same OKLCH hue and chroma, that meets role's target."""
    target_lc, target_ratio, _ = TARGETS[role]
    lightness, chroma, hue = color.to_oklch(text)
    step = -0.005 if mode == "light" else 0.005
    candidate = text
    for _ in range(200):
        if worst_lc(candidate, mode) >= target_lc + 1 and worst_ratio(candidate, mode) >= target_ratio:
            return candidate
        lightness = min(max(lightness + step, 0), 1)
        candidate = color.from_oklch(lightness, chroma, hue)
    return candidate


def main(argv: list[str]) -> int:
    if argv[:1] == ["--fit"]:
        text, role, mode = argv[1:4]
        print(fit(text, role, mode))
        return 0
    themes = load()
    names = argv or sorted(themes)
    failures = 0
    for name in names:
        for mode in ("dark", "light"):
            findings = check(name, mode, themes[name][mode])
            failures += sum(f.level == "fail" for f in findings)
            print(f"{name}-{mode}: " + ("ok" if not findings else f"{len(findings)} finding(s)"))
            for f in findings:
                print(f"  {f.level:4}  {f.message}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
