import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import architecture_benchmark as flow


class ProfileTests(unittest.TestCase):
    def profile(self):
        # Ten cycles: six clear, two M-only, one I-only, one M+I overlap.
        counts = [0] * 64
        counts[0], counts[8], counts[16], counts[24] = 6, 2, 1, 1
        head = ("PROFILE cycles=10 retired=7 stalls=4 icache_misses=1 dcache_misses=0 "
                "branch_misses=0 no_retire_no_stall=1 retire_with_stall=2 busy_cycles=0 compute_cycles=0 "
                "data_line_fills=0 data_writebacks=0 victim_hits=0\n")
        return head + "".join(f"MASK {mask} {count}\n" for mask, count in enumerate(counts))

    def test_exclusive_counts_do_not_double_count(self):
        row = flow.parse_profile(self.profile())
        self.assertEqual(row["rv32m_raw"], 3)
        self.assertEqual(row["icache_raw"], 2)
        self.assertEqual(row["rv32m_exclusive"], 3)
        self.assertEqual(row["icache_exclusive"], 1)
        self.assertEqual(row["overlap_cycles"], 1)
        self.assertEqual(sum(row[f"{cause}_exclusive"] for cause in flow.CAUSES), row["stalls"])

    def test_reject_inconsistent_or_incomplete_profiles(self):
        text = self.profile()
        for bad in (text.replace("stalls=4", "stalls=3"), text.replace("retired=7", "retired=8"),
                    text.replace("MASK 63 0\n", ""), text + "MASK 63 0\n", text + text,
                    text.replace("compute_cycles=0", "compute_cycles=1"),
                    text.replace("PROFILE ", "PROFILE cycles=10 "),
                    text.replace("PROFILE ", "PROFILE garbage ")):
            with self.subTest(bad=bad[:60]):
                with self.assertRaises(RuntimeError):
                    flow.parse_profile(bad)

    def test_workload_oracles_are_distinct(self):
        values = [flow.expected_workload(name) for name in flow.WORKLOADS]
        self.assertEqual(len(values), 6)
        self.assertTrue(all(0 <= value <= 0xFFFFFFFF for value in values))
        self.assertGreaterEqual(len(set(values)), 5)

    def comparison(self):
        return [dict(workload="fir", optimization="O2", profile=name, image_sha256="same",
                     **{field: 1 for field in flow.COUNTERS}) for name in flow.ICACHE_PROFILES]

    def test_icache_comparison_requires_same_program_and_complete_matrix(self):
        rows = self.comparison()
        flow.check_icache_comparisons(rows)
        for field in ("image_sha256", "retired", "dcache_misses", "cycles"):
            changed = [dict(row) for row in rows]
            changed[1][field] = "different" if field == "image_sha256" else 2
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                flow.check_icache_comparisons(changed)
        for changed in (rows[:-1], rows + rows[:1]):
            with self.assertRaises(RuntimeError):
                flow.check_icache_comparisons(changed)

    def test_larger_cache_may_change_cycles_and_misses(self):
        rows = self.comparison()
        rows[2]["cycles"] = 2
        rows[2]["icache_misses"] = 2
        flow.check_icache_comparisons(rows)

    def test_dcache_comparison_reconciles_primary_and_backing_misses(self):
        rows = [dict(workload="fir", optimization="O2", profile=name, image_sha256="same",
                     dcache_bytes=flow.DCACHE_PROFILES[name][0], dcache_victim_lines=flow.DCACHE_PROFILES[name][1],
                     retired=100, dcache_misses=10, data_line_fills=10-hits, victim_hits=hits)
                for hits, name in enumerate(flow.DCACHE_PROFILES)]
        flow.check_dcache_comparisons(rows)
        for changed in (rows[:-1], rows + rows[:1]):
            with self.assertRaises(RuntimeError):
                flow.check_dcache_comparisons(changed)
        rows[1]["data_line_fills"] += 1
        with self.assertRaises(RuntimeError):
            flow.check_dcache_comparisons(rows)

    def test_dcache_comparison_rejects_mislabeled_geometry(self):
        rows = [dict(workload="fir", optimization="O2", profile=name, image_sha256="same",
                     retired=100, dcache_misses=10, data_line_fills=10, victim_hits=0,
                     dcache_bytes=geometry[0], dcache_victim_lines=geometry[1])
                for name, geometry in flow.DCACHE_PROFILES.items()]
        rows[1]["dcache_bytes"] = 64
        with self.assertRaisesRegex(RuntimeError, "geometry"):
            flow.check_dcache_comparisons(rows)


if __name__ == "__main__":
    unittest.main()
