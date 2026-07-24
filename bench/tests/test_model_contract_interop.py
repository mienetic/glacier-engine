from __future__ import annotations

import unittest
from pathlib import Path

from bench import model_contract as contract
from bench.tests.test_model_contract import fixture, token_ids_fixture


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

    def test_token_ids_roots_match_the_cross_language_golden(self) -> None:
        artifact, plan, result, _ = token_ids_fixture()
        self.assertEqual(
            artifact["artifact_sha256"].hex(),
            "e850bc468da43295e4345122eb5389ba"
            "e2df8e4bb003b518b0ae9b6bcbcf7843",
        )
        self.assertEqual(
            plan["plan_sha256"].hex(),
            "9c572db5caaa229a20f4fc58bccb7dde"
            "43d3a92289bb1c43f1536904dfdb7276",
        )
        self.assertEqual(
            result["result_sha256"].hex(),
            "e87cf08d3c42efe196db681392ce3899"
            "6276c0a31bb5b3aae28b2a3ec54ff8ad",
        )


if __name__ == "__main__":
    unittest.main()
