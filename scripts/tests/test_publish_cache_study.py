import copy
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from publish_cache_study import DCACHE_PROFILES, check_files, digest, validate_measurements
from publication import publish_directory


class CachePublicationTests(unittest.TestCase):
    def rows(self):
        return [{"workload": "fir", "optimization": "O2", "profile": name,
                 "extra_wait": delay, "dcache_bytes": size, "dcache_victim_lines": victims,
                 "image_sha256": "same", "retired": 20, "cycles": 100 + delay * 5,
                 "data_line_fills": 3, "data_writebacks": 2, "victim_hits": 1}
                for delay in (0, 4, 12) for name, (size, victims) in DCACHE_PROFILES.items()]

    def test_complete_same_binary_matrix(self):
        validate_measurements(self.rows())

    def test_reject_changed_binary_geometry_or_latency_accounting(self):
        for field, value in (("image_sha256", "different"), ("retired", 21),
                             ("dcache_bytes", 256), ("cycles", 999), ("data_line_fills", 5)):
            rows = copy.deepcopy(self.rows())
            rows[-1][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_measurements(rows)

    def test_reject_missing_or_duplicate_profile(self):
        for rows in (self.rows()[:-1], self.rows() + self.rows()[:1]):
            with self.assertRaises(ValueError):
                validate_measurements(rows)

    def test_file_hashes_and_directory_boundary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "result.txt"
            path.write_text("measured")
            expected = digest(path)
            check_files(root, {"result.txt": expected})
            path.write_text("changed")
            with self.assertRaises(ValueError):
                check_files(root, {"result.txt": expected})
            with self.assertRaises(ValueError):
                check_files(root, {"../outside.txt": expected})

    def test_publication_replaces_only_after_validation_and_rolls_back(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage, destination = root / "stage", root / "published"
            stage.mkdir()
            destination.mkdir()
            (stage / "data").write_text("new")
            (destination / "data").write_text("old")

            def validate(path):
                self.assertEqual({p.name for p in path.iterdir()}, {"data"})

            with patch("publication.Path.rename", side_effect=OSError("rename failed")):
                with self.assertRaises(OSError):
                    publish_directory(stage, destination, root, validate)
            self.assertEqual((destination / "data").read_text(), "old")
            rename = Path.rename

            def fail_install(path, target):
                if path == stage:
                    raise OSError("install failed")
                return rename(path, target)

            with patch("publication.Path.rename", new=fail_install):
                with self.assertRaises(OSError):
                    publish_directory(stage, destination, root, validate)
            self.assertEqual((destination / "data").read_text(), "old")
            self.assertEqual((stage / "data").read_text(), "new")
            (stage / "unexpected").write_text("invalid")
            with self.assertRaises(AssertionError):
                publish_directory(stage, destination, root, validate)
            self.assertEqual((destination / "data").read_text(), "old")
            (stage / "unexpected").unlink()
            publish_directory(stage, destination, root, validate)
            self.assertEqual((destination / "data").read_text(), "new")
            self.assertFalse(stage.exists())
            self.assertFalse((root / "stage-previous").exists())

    def test_publication_rejects_outside_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(ValueError, "escapes"):
                publish_directory(root / "stage", root.parent / "outside", root, lambda path: None)
            for stage, destination in ((root / "stage", root / "stage/child"),
                                       (root / "published/stage", root / "published")):
                with self.assertRaisesRegex(ValueError, "separate staging"):
                    publish_directory(stage, destination, root, lambda path: None)


if __name__ == "__main__":
    unittest.main()
