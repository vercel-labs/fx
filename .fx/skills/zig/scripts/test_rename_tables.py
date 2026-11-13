"""The two scripts share one rename table, and the checker must report every
old name that migrate.py rewrites, and none of the new names.

Run: python3 -m unittest discover -s scripts
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_deprecated  # noqa: E402
import migrate  # noqa: E402
from zig_source import ASCII_RENAMES, MEM_RENAMES, STD_RENAMES  # noqa: E402


def renames():
    yield from ((f"std.mem.{old}", f"std.mem.{new}") for old, new in MEM_RENAMES.items())
    yield from ((f"std.ascii.{old}", f"std.ascii.{new}") for old, new in ASCII_RENAMES.items())
    yield from STD_RENAMES.items()


def use(name):
    return f'const std = @import("std");\nconst x = {name}(y);\n'


class RenameTablesAgree(unittest.TestCase):
    def test_checker_reports_each_old_name_and_none_of_the_new(self):
        for old, new in renames():
            with self.subTest(old=old):
                self.assertTrue(check_deprecated.findings(use(old)), f"{old} is not reported")
                self.assertEqual(check_deprecated.findings(use(new)), [], f"{new} is reported")

    def test_migrate_rewrites_each_old_name_to_the_new(self):
        for old, new in renames():
            with self.subTest(old=old):
                out, _counts, _notes = migrate.migrate("t.zig", use(old))
                self.assertEqual(out, use(new))


if __name__ == "__main__":
    unittest.main()
