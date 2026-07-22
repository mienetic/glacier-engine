from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FORBIDDEN = "lla" + "ma"


def public_markdown_files() -> list[Path]:
    files = list(ROOT.glob("*.md"))
    files.append(ROOT / "bench" / "results" / "README.md")
    files.extend((ROOT / "docs").rglob("*.md"))
    files.extend((ROOT / ".github").rglob("*.md"))
    return sorted({path for path in files if path.is_file()})


class PublicMarkdownPolicyTests(unittest.TestCase):
    def test_public_markdown_is_glacier_first(self) -> None:
        violations: list[str] = []
        for path in public_markdown_files():
            relative = path.relative_to(ROOT)
            if FORBIDDEN in str(relative).lower():
                violations.append(f"forbidden filename: {relative}")
            for line_number, line in enumerate(
                path.read_text(encoding="utf-8").splitlines(),
                1,
            ):
                if FORBIDDEN in line.lower():
                    violations.append(f"{relative}:{line_number}: {line.strip()}")
        self.assertEqual([], violations)


if __name__ == "__main__":
    unittest.main()
