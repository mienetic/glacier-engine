from pathlib import Path
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
ALLOWED_RAW_SYNC_SOURCE = Path("src/core/durable_directory_sync.zig")
RAW_DIRECTORY_SYNC_CALLS = (
    "std.posix.fsync(",
    "std.posix.system.fsync(",
)


class DurableDirectorySyncPolicyTests(unittest.TestCase):
    def test_raw_posix_fsync_is_centralized(self) -> None:
        offenders: list[str] = []

        for source_root in ("src", "examples", "bench"):
            for source_path in (REPOSITORY_ROOT / source_root).rglob("*.zig"):
                relative_path = source_path.relative_to(REPOSITORY_ROOT)
                if relative_path == ALLOWED_RAW_SYNC_SOURCE:
                    continue

                source = source_path.read_text(encoding="utf-8")
                if any(call in source for call in RAW_DIRECTORY_SYNC_CALLS):
                    offenders.append(relative_path.as_posix())

        self.assertEqual(
            [],
            offenders,
            "raw POSIX fsync must remain centralized in "
            f"{ALLOWED_RAW_SYNC_SOURCE.as_posix()}",
        )


if __name__ == "__main__":
    unittest.main()
