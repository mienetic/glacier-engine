from pathlib import Path
import re
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
ALLOWED_RAW_SYNC_SOURCE = Path("src/core/durable_directory_sync.zig")
RAW_DIRECTORY_SYNC_REFERENCE = re.compile(
    r"\bstd\s*\.\s*posix\s*\.\s*(?:system\s*\.\s*)?fsync\b"
)
POSIX_ALIAS_DECLARATION = re.compile(
    r"\b(?:const|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
    r"std\s*\.\s*posix(?:\s*\.\s*system)?\s*;"
)
LEGACY_ONE_SHOT_SYNC_CALL = re.compile(
    r"\bdurable_directory_sync\s*\.\s*sync\s*\("
)
LEGACY_COMPATIBILITY_EXPORT = re.compile(
    r"\bpub\s+(?:(?:inline|noinline|export|extern)\s+)*"
    r"(?:fn|const)\s+sync\b"
)


def zig_sources() -> list[Path]:
    return sorted(
        source_path
        for source_root in ("src", "examples", "bench")
        for source_path in (REPOSITORY_ROOT / source_root).rglob("*.zig")
    )


class DurableDirectorySyncPolicyTests(unittest.TestCase):
    def test_raw_posix_fsync_is_centralized(self) -> None:
        offenders: list[str] = []

        for source_path in zig_sources():
            relative_path = source_path.relative_to(REPOSITORY_ROOT)
            if relative_path == ALLOWED_RAW_SYNC_SOURCE:
                continue

            source = source_path.read_text(encoding="utf-8")
            raw_sync_found = bool(
                RAW_DIRECTORY_SYNC_REFERENCE.search(source)
            )
            for alias in POSIX_ALIAS_DECLARATION.findall(source):
                alias_sync = re.compile(
                    rf"\b{re.escape(alias)}\s*\.\s*"
                    r"(?:system\s*\.\s*)?fsync\b"
                )
                raw_sync_found = raw_sync_found or bool(
                    alias_sync.search(source)
                )
            if raw_sync_found:
                offenders.append(relative_path.as_posix())

        self.assertEqual(
            [],
            offenders,
            "raw POSIX fsync must remain centralized in "
            f"{ALLOWED_RAW_SYNC_SOURCE.as_posix()}",
        )

    def test_one_shot_directory_sync_api_is_removed(self) -> None:
        call_offenders: list[str] = []
        for source_path in zig_sources():
            source = source_path.read_text(encoding="utf-8")
            if LEGACY_ONE_SHOT_SYNC_CALL.search(source):
                call_offenders.append(
                    source_path.relative_to(REPOSITORY_ROOT).as_posix()
                )

        authority_source = (
            REPOSITORY_ROOT / ALLOWED_RAW_SYNC_SOURCE
        ).read_text(encoding="utf-8")
        compatibility_exported = bool(
            LEGACY_COMPATIBILITY_EXPORT.search(authority_source)
        )

        self.assertEqual(
            [],
            call_offenders,
            "legacy one-shot directory-sync call sites must remain absent",
        )
        self.assertFalse(
            compatibility_exported,
            "the legacy public one-shot sync wrapper must not be retained",
        )

    def test_policy_patterns_cover_spacing_aliases_and_inline_exports(
        self,
    ) -> None:
        self.assertIsNotNone(
            RAW_DIRECTORY_SYNC_REFERENCE.search(
                "std.posix.system.fsync \n (descriptor)"
            )
        )
        alias_source = "const p = std.posix;\np.system.fsync(fd);"
        alias = POSIX_ALIAS_DECLARATION.search(alias_source)
        self.assertIsNotNone(alias)
        assert alias is not None
        self.assertIsNotNone(
            re.search(
                rf"\b{re.escape(alias.group(1))}\s*\.\s*"
                r"(?:system\s*\.\s*)?fsync\b",
                alias_source,
            )
        )
        self.assertIsNotNone(
            LEGACY_COMPATIBILITY_EXPORT.search(
                "pub inline fn sync(directory: Dir) !void {}"
            )
        )


if __name__ == "__main__":
    unittest.main()
