from __future__ import annotations

import unittest

from scripts.pgso.model import PgsoError
from scripts.pgso.profile_supplement import (
    PROFILE_SUMMARY_CUTOFF_COLD,
    SUPPLEMENT_COLD_THRESHOLD_MULTIPLIER,
    extract_compatible_profile,
    map_production_profile,
    speed_shaped_functions,
    verify_supplement_functions,
)


def profile_text(*records: tuple[str, int, tuple[int, ...]]) -> str:
    blocks = []
    for name, function_hash, counters in records:
        values = "\n".join(str(value) for value in counters)
        blocks.append(
            f"{name}\n"
            "# Func Hash:\n"
            f"{function_hash}\n"
            "# Num Counters:\n"
            f"{len(counters)}\n"
            "# Counter Values:\n"
            f"{values}"
        )
    return "# IR level Instrumentation Flag\n:ir\n" + "\n\n".join(blocks) + "\n"


class ProfileSupplementTests(unittest.TestCase):
    def test_supplements_follow_the_production_cold_cutoff(self) -> None:
        self.assertEqual(600_000, PROFILE_SUMMARY_CUTOFF_COLD)
        self.assertEqual(2, SUPPLEMENT_COLD_THRESHOLD_MULTIPLIER)

    def test_reads_speed_shaped_functions_from_profile_use_ir(self) -> None:
        ir = """
define internal void @core.output.diff.hot() #3 {
  ret void
}
define internal void @core.output.diff.cold() #4 {
  ret void
}
define internal void @mem.helper() #3 {
  ret void
}
attributes #3 = { nounwind }
attributes #4 = { cold minsize nounwind }
"""

        self.assertEqual(
            ("core.output.diff.hot",),
            speed_shaped_functions(ir, ("core.output.diff.",)),
        )

    def test_verifies_production_functions_are_speed_shaped_or_optimized_away(self) -> None:
        ir = """
define internal void @core.output.diff.hot() #3 {
  ret void
}
attributes #3 = { nounwind }
"""

        self.assertEqual(
            {
                "core.output.diff.hot": "speed",
                "core.output.diff.inlined": "optimized_away",
            },
            verify_supplement_functions(
                ir,
                (
                    "fx;core.output.diff.hot",
                    "fx;core.output.diff.inlined",
                ),
                production_module="fx",
            ),
        )

    def test_rejects_a_supplement_function_left_size_shaped(self) -> None:
        ir = """
define internal void @core.output.diff.cold() #4 {
  ret void
}
attributes #4 = { cold minsize nounwind }
"""

        with self.assertRaisesRegex(PgsoError, "remained size-shaped"):
            verify_supplement_functions(
                ir,
                ("fx;core.output.diff.cold",),
                production_module="fx",
            )

    def test_extracts_only_compatible_functions_in_the_workload_family(self) -> None:
        production = profile_text(
            ("fx;core.workspace.file_index.scoreAsciiRange", 41, (1, 0)),
            ("fx;core.workspace.file_index.findWorstSlot", 42, (1,)),
            ("fx;mem.Allocator.alloc", 43, (1,)),
        )
        benchmark = profile_text(
            (
                "file-index-bench;core.workspace.file_index.scoreAsciiRange",
                41,
                (80, 20),
            ),
            (
                "file-index-bench;core.workspace.file_index.findWorstSlot",
                999,
                (100,),
            ),
            ("file-index-bench;mem.Allocator.alloc", 43, (500,)),
        )

        supplement = extract_compatible_profile(
            production,
            benchmark,
            source_module="file-index-bench",
            destination_module="fx",
            allowed_prefixes=("core.workspace.file_index.",),
            speed_functions=("core.workspace.file_index.scoreAsciiRange",),
        )

        self.assertEqual(
            ("fx;core.workspace.file_index.scoreAsciiRange",),
            supplement.function_names,
        )
        self.assertEqual(3, supplement.total_counter_value)
        self.assertIn(
            "fx;core.workspace.file_index.scoreAsciiRange",
            supplement.text,
        )
        self.assertNotIn("findWorstSlot", supplement.text)
        self.assertNotIn("mem.Allocator", supplement.text)

    def test_rejects_a_family_without_a_compatible_nonzero_profile(self) -> None:
        production = profile_text(
            ("fx;core.output.diff.compute", 7, (1,)),
        )
        benchmark = profile_text(
            ("approval-review-bench;core.output.diff.compute", 8, (10,)),
        )

        with self.assertRaisesRegex(PgsoError, "no compatible nonzero functions"):
            extract_compatible_profile(
                production,
                benchmark,
                source_module="approval-review-bench",
                destination_module="fx",
                allowed_prefixes=("core.output.diff.",),
                speed_functions=("core.output.diff.compute",),
            )

        zero_benchmark = profile_text(
            ("approval-review-bench;core.output.diff.compute", 7, (0,)),
        )
        with self.assertRaisesRegex(PgsoError, "no compatible nonzero functions"):
            extract_compatible_profile(
                production,
                zero_benchmark,
                source_module="approval-review-bench",
                destination_module="fx",
                allowed_prefixes=("core.output.diff.",),
                speed_functions=("core.output.diff.compute",),
            )

    def test_normalizes_workload_counts_relative_to_production_cold_cutoff(self) -> None:
        production = profile_text(
            ("fx;core.output.diff.compute", 7, (100, 50, 25, 25)),
        )
        benchmark = profile_text(
            (
                "approval-review-bench;core.output.diff.compute",
                7,
                (1_000_000, 500_000, 0, 250_000),
            ),
        )

        supplement = extract_compatible_profile(
            production,
            benchmark,
            source_module="approval-review-bench",
            destination_module="fx",
            allowed_prefixes=("core.output.diff.",),
            speed_functions=("core.output.diff.compute",),
        )

        self.assertIn("\n100\n50\n0\n25\n", supplement.text)
        self.assertEqual(175, supplement.total_counter_value)

    def test_raises_a_low_workload_count_above_the_production_cold_cutoff(self) -> None:
        production = profile_text(
            ("fx;core.output.diff.compute", 7, (100, 50, 25, 25)),
        )
        benchmark = profile_text(
            ("approval-review-bench;core.output.diff.compute", 7, (10, 5, 0, 1)),
        )

        supplement = extract_compatible_profile(
            production,
            benchmark,
            source_module="approval-review-bench",
            destination_module="fx",
            allowed_prefixes=("core.output.diff.",),
            speed_functions=("core.output.diff.compute",),
        )

        self.assertIn("\n100\n50\n0\n10\n", supplement.text)
        self.assertEqual(160, supplement.total_counter_value)

    def test_rejects_malformed_counter_count(self) -> None:
        production = profile_text(("fx;core.output.diff.compute", 7, (1,)))
        benchmark = profile_text(
            ("approval-review-bench;core.output.diff.compute", 7, (10,))
        ).replace("# Num Counters:\n1", "# Num Counters:\n2")

        with self.assertRaisesRegex(PgsoError, "counter count"):
            extract_compatible_profile(
                production,
                benchmark,
                source_module="approval-review-bench",
                destination_module="fx",
                allowed_prefixes=("core.output.diff.",),
                speed_functions=("core.output.diff.compute",),
            )

    def test_maps_the_complete_production_summary_to_a_benchmark_safely(self) -> None:
        production = profile_text(
            ("fx;core.output.diff.same", 7, (100, 50)),
            ("fx;core.output.diff.changed", 8, (25,)),
            ("fx;core.sessions.unused", 9, (10,)),
        )
        benchmark = profile_text(
            ("approval-review-bench;core.output.diff.same", 7, (1, 1)),
            ("approval-review-bench;core.output.diff.changed", 80, (1,)),
            ("approval-review-bench;benchmark.main", 10, (1,)),
        )

        mapped = map_production_profile(
            production,
            benchmark,
            source_module="fx",
            destination_module="approval-review-bench",
        )

        self.assertEqual(
            ("core.output.diff.same",),
            mapped.compatible_function_names,
        )
        self.assertIn(
            "approval-review-bench;core.output.diff.same",
            mapped.text,
        )
        self.assertNotIn(
            "approval-review-bench;core.output.diff.changed\n",
            mapped.text,
        )
        self.assertEqual(185, mapped.total_counter_value)
