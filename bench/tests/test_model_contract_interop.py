from __future__ import annotations

import unittest
from pathlib import Path

from bench import model_contract as contract
from bench.tests.test_model_contract import fixture


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIRECTORY = REPOSITORY_ROOT / "examples" / "interop" / "fixtures"


class ModelContractInteropFixtureTests(unittest.TestCase):
    def test_text_fixtures_match_the_independent_oracle(self) -> None:
        artifact, plan, result, _, _ = fixture()
        expected = {
            "artifact_manifest_v1.hex": contract.encode_artifact(artifact),
            "execution_plan_v1.hex": contract.encode_plan(plan),
            "result_envelope_v1.hex": contract.encode_result(result),
        }

        for name, encoded in expected.items():
            with self.subTest(name=name):
                fixture_path = FIXTURE_DIRECTORY / name
                retained = bytes.fromhex(
                    fixture_path.read_text(encoding="ascii")
                )
                self.assertEqual(retained, encoded)

        self.assertEqual(
            expected["result_envelope_v1.hex"][-32:].hex(),
            "b522a4ed75ba657638a8fc162833ed87"
            "749647b3ba6cfdd73661de41041bd6c9",
        )


if __name__ == "__main__":
    unittest.main()
