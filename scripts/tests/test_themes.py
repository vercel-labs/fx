from __future__ import annotations

import unittest

from scripts.themes import audit


class NamedThemesTest(unittest.TestCase):
    def test_every_named_theme_has_a_dark_and_a_light_file(self) -> None:
        themes = audit.load()
        self.assertEqual(sorted(audit.shipped_names()), sorted(themes))
        for name, modes in themes.items():
            self.assertEqual(sorted(modes), ["dark", "light"], name)
            for mode, theme in modes.items():
                self.assertEqual(theme["type"], mode, f"{name}-{mode}.json")

    def test_no_theme_falls_below_a_floor(self) -> None:
        for name, modes in audit.load().items():
            for mode, theme in modes.items():
                failures = [f.message for f in audit.check(name, mode, theme) if f.level == "fail"]
                self.assertEqual(failures, [], f"{name}-{mode}")

    def test_fit_reaches_the_target(self) -> None:
        fitted = audit.fit("#5B5F7A", "quiet", "dark")
        self.assertGreaterEqual(audit.worst_lc(fitted, "dark"), audit.TARGETS["quiet"][0])


if __name__ == "__main__":
    unittest.main()
