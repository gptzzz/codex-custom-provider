from __future__ import annotations

import tempfile
import unittest
from decimal import Decimal
from pathlib import Path

from calculator import InputError, load_tasks


ROOT = Path(__file__).resolve().parent
HEADER = (
    "task_id,task_type,billing_path,input_tokens,cached_input_tokens,output_tokens,"
    "input_usd_per_million,cached_input_usd_per_million,output_usd_per_million,accepted\n"
)


class CalculatorTests(unittest.TestCase):
    def test_sample_total(self) -> None:
        tasks = load_tasks(ROOT / "sample_tasks.csv")
        total = sum((task.cost for task in tasks), Decimal(0))
        self.assertEqual(len(tasks), 4)
        self.assertEqual(total, Decimal("0.71005"))
        self.assertEqual(sum(task.accepted for task in tasks), 3)

    def test_rejects_negative_tokens(self) -> None:
        row = "bad,bugfix,api-key,-1,0,1,1,0.1,5,true\n"
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "bad.csv"
            path.write_text(HEADER + row, encoding="utf-8")
            with self.assertRaisesRegex(InputError, "must be non-negative"):
                load_tasks(path)

    def test_rejects_duplicate_task_ids(self) -> None:
        row = "same,bugfix,api-key,1,0,1,1,0.1,5,true\n"
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "duplicate.csv"
            path.write_text(HEADER + row + row, encoding="utf-8")
            with self.assertRaisesRegex(InputError, "duplicate task_id"):
                load_tasks(path)


if __name__ == "__main__":
    unittest.main()
