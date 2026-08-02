import unittest

from scripts.load_test import distribute, parse_size, percentile


class LoadTestUnitTests(unittest.TestCase):
    def test_percentile_uses_nearest_rank(self) -> None:
        self.assertEqual(percentile([1, 2, 3, 4, 5], 0.50), 3)
        self.assertEqual(percentile([1, 2, 3, 4, 5], 0.95), 5)

    def test_parse_size_supports_docker_units(self) -> None:
        self.assertEqual(parse_size("1.5GiB"), int(1.5 * 1024**3))
        self.assertEqual(parse_size("250MiB"), 250 * 1024**2)

    def test_distribute_preserves_total(self) -> None:
        counts = distribute(103, 10)
        self.assertEqual(sum(counts), 103)
        self.assertLessEqual(max(counts) - min(counts), 1)


if __name__ == "__main__":
    unittest.main()
