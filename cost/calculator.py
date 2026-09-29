#!/usr/bin/env python3
"""Calculate Codex task costs from a CSV file using caller-supplied rates."""

from __future__ import annotations

import argparse
import csv
import sys
from collections import defaultdict
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Iterable


MILLION = Decimal("1000000")
MONEY_PLACES = Decimal("0.0001")
REQUIRED_COLUMNS = {
    "task_id",
    "task_type",
    "billing_path",
    "input_tokens",
    "cached_input_tokens",
    "output_tokens",
    "input_usd_per_million",
    "cached_input_usd_per_million",
    "output_usd_per_million",
    "accepted",
}


class InputError(ValueError):
    """Raised when the input CSV cannot be safely calculated."""


@dataclass(frozen=True)
class Task:
    task_id: str
    task_type: str
    billing_path: str
    input_tokens: int
    cached_input_tokens: int
    output_tokens: int
    input_rate: Decimal
    cached_input_rate: Decimal
    output_rate: Decimal
    accepted: bool

    @property
    def cost(self) -> Decimal:
        return (
            Decimal(self.input_tokens) * self.input_rate
            + Decimal(self.cached_input_tokens) * self.cached_input_rate
            + Decimal(self.output_tokens) * self.output_rate
        ) / MILLION


def parse_nonnegative_int(value: str, field: str, row_number: int) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise InputError(f"row {row_number}: {field} must be an integer") from exc
    if parsed < 0:
        raise InputError(f"row {row_number}: {field} must be non-negative")
    return parsed


def parse_nonnegative_decimal(value: str, field: str, row_number: int) -> Decimal:
    try:
        parsed = Decimal(value)
    except (InvalidOperation, TypeError) as exc:
        raise InputError(f"row {row_number}: {field} must be a decimal number") from exc
    if not parsed.is_finite() or parsed < 0:
        raise InputError(f"row {row_number}: {field} must be finite and non-negative")
    return parsed


def parse_bool(value: str, row_number: int) -> bool:
    normalized = value.strip().lower()
    if normalized in {"true", "yes", "1"}:
        return True
    if normalized in {"false", "no", "0"}:
        return False
    raise InputError(f"row {row_number}: accepted must be true/false, yes/no, or 1/0")


def require_text(row: dict[str, str], field: str, row_number: int) -> str:
    value = (row.get(field) or "").strip()
    if not value:
        raise InputError(f"row {row_number}: {field} cannot be empty")
    return value


def load_tasks(path: Path) -> list[Task]:
    if not path.is_file():
        raise InputError(f"input file not found: {path}")

    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise InputError("CSV has no header row")
        missing = sorted(REQUIRED_COLUMNS - set(reader.fieldnames))
        if missing:
            raise InputError("missing required columns: " + ", ".join(missing))

        tasks: list[Task] = []
        task_ids: set[str] = set()
        for row_number, row in enumerate(reader, start=2):
            task_id = require_text(row, "task_id", row_number)
            if task_id in task_ids:
                raise InputError(f"row {row_number}: duplicate task_id {task_id!r}")
            task_ids.add(task_id)
            tasks.append(
                Task(
                    task_id=task_id,
                    task_type=require_text(row, "task_type", row_number),
                    billing_path=require_text(row, "billing_path", row_number),
                    input_tokens=parse_nonnegative_int(row["input_tokens"], "input_tokens", row_number),
                    cached_input_tokens=parse_nonnegative_int(
                        row["cached_input_tokens"], "cached_input_tokens", row_number
                    ),
                    output_tokens=parse_nonnegative_int(row["output_tokens"], "output_tokens", row_number),
                    input_rate=parse_nonnegative_decimal(
                        row["input_usd_per_million"], "input_usd_per_million", row_number
                    ),
                    cached_input_rate=parse_nonnegative_decimal(
                        row["cached_input_usd_per_million"],
                        "cached_input_usd_per_million",
                        row_number,
                    ),
                    output_rate=parse_nonnegative_decimal(
                        row["output_usd_per_million"], "output_usd_per_million", row_number
                    ),
                    accepted=parse_bool(row["accepted"], row_number),
                )
            )

    if not tasks:
        raise InputError("CSV contains no task rows")
    return tasks


def money(value: Decimal) -> str:
    return f"${value.quantize(MONEY_PLACES):,.4f}"


def grouped_costs(tasks: Iterable[Task], attribute: str) -> dict[str, Decimal]:
    totals: dict[str, Decimal] = defaultdict(Decimal)
    for task in tasks:
        totals[getattr(task, attribute)] += task.cost
    return dict(sorted(totals.items()))


def print_group(title: str, totals: dict[str, Decimal]) -> None:
    print(f"\n{title}")
    print("-" * 50)
    for name, total in totals.items():
        print(f"{name:<34} {money(total):>15}")


def print_report(tasks: list[Task], source: Path) -> None:
    print(f"Source: {source.resolve()}")
    print("\nPer-task costs")
    print("-" * 94)
    print(f"{'task_id':<28} {'task_type':<22} {'billing_path':<18} {'accepted':<10} {'cost_usd':>12}")
    print("-" * 94)
    for task in tasks:
        print(
            f"{task.task_id:<28} {task.task_type:<22} {task.billing_path:<18} "
            f"{('yes' if task.accepted else 'no'):<10} {money(task.cost):>12}"
        )

    total = sum((task.cost for task in tasks), Decimal(0))
    accepted_count = sum(task.accepted for task in tasks)
    print_group("By task type", grouped_costs(tasks, "task_type"))
    print_group("By billing path", grouped_costs(tasks, "billing_path"))
    print(f"\nGrand total: {money(total)}")
    print(f"Accepted tasks: {accepted_count}/{len(tasks)}")
    if accepted_count:
        print(f"Average cost per accepted task: {money(total / accepted_count)}")
    else:
        print("Average cost per accepted task: n/a")


def parse_args() -> argparse.Namespace:
    default_csv = Path(__file__).resolve().with_name("sample_tasks.csv")
    parser = argparse.ArgumentParser(
        description="Calculate total and grouped Codex task costs from caller-supplied token rates."
    )
    parser.add_argument(
        "csv_file",
        nargs="?",
        type=Path,
        default=default_csv,
        help=f"input CSV path (default: {default_csv.name})",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        tasks = load_tasks(args.csv_file)
        print_report(tasks, args.csv_file)
    except (InputError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

