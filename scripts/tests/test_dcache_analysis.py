import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dcache_analysis import Cache, evaluate, memory_accesses


class CacheAnalysisTests(unittest.TestCase):
    def test_hit_and_dirty_writeback(self):
        cache = Cache(64)
        self.assertEqual(cache.access(0, True)["line_fills"], 1)
        self.assertEqual(cache.access(4)["primary_misses"], 0)
        self.assertEqual(cache.access(64)["writebacks"], 1)
        self.assertEqual(cache.access(128)["writebacks"], 0)

    def test_victim_swap_preserves_dirty_line(self):
        cache = Cache(64, victims=1)
        cache.access(0, True)
        self.assertEqual(cache.access(64)["writebacks"], 0)
        event = cache.access(0)
        self.assertEqual((event["victim_hits"], event["line_fills"], event["writebacks"]), (1, 0, 0))
        cache.access(128)
        self.assertEqual(cache.access(192)["writebacks"], 1)

    def test_set_lru_is_updated_on_hits(self):
        cache = Cache(64, ways=2)
        for address in (0, 32, 0, 64):
            cache.access(address)
        self.assertEqual(cache.access(0)["line_fills"], 0)
        self.assertEqual(cache.access(32)["line_fills"], 1)

    def test_eight_conflicting_lines_need_more_than_two_victims(self):
        accesses = [(64 * (i % 8), False, True) for i in range(80)]
        self.assertEqual(evaluate(accesses, 64, victims=2)["line_fills"], 80)
        self.assertEqual(evaluate(accesses, 64, victims=8)["line_fills"], 8)
        self.assertEqual(evaluate(accesses, 512)["line_fills"], 8)
        self.assertEqual(evaluate(accesses, 256, ways=2)["line_fills"], 80)

    def test_compulsory_capacity_and_conflict(self):
        conflict = evaluate([(a, False, True) for a in (0, 64, 0, 64)], 64)
        self.assertEqual([conflict[k] for k in ("compulsory", "capacity", "conflict")], [2, 0, 2])
        capacity = evaluate([(16 * (i % 5), False, True) for i in range(20)], 64)
        self.assertGreater(capacity["capacity"], 0)
        self.assertEqual(sum(capacity[k] for k in ("compulsory", "capacity", "conflict")), capacity["line_fills"])

    def test_startup_warms_cache_without_counting_traffic(self):
        counts = evaluate([(0, True, False), (4, False, True), (64, False, True)], 64)
        self.assertEqual(counts["accesses"], 2)
        self.assertEqual(counts["line_fills"], 1)
        self.assertEqual(counts["writebacks"], 1)
        self.assertEqual(counts["transfer_bytes"], 32)

    def test_decode_address_before_destination_writeback(self):
        # Set x1, then lw x1,-4(x1): source must be the pre-instruction x1.
        trace = [(0x1000, 0x00000013, 33, 0x3004),
                 (0x1004, 0xFFC0A083, 33, 0x12345678),
                 (0x1008, 0x00000013, 0, 0)]
        self.assertEqual(memory_accesses(trace, 0x1004, 0x1008), [(0x3000, False, True)])

    def test_reject_invalid_geometry_and_missing_markers(self):
        for geometry in ((64, 0, 0), (15, 1, 0), (64, 3, 0), (64, 1, -1)):
            with self.assertRaises(ValueError):
                Cache(*geometry)
        with self.assertRaises(ValueError):
            memory_accesses([], 0x1000, 0x1100)


if __name__ == "__main__":
    unittest.main()
