from __future__ import annotations

from dataclasses import replace
import unittest

from bench import device_allocation_lease as allocation
from bench import device_allocation_lease_tree as tree


class DeviceAllocationLeaseTreeOracleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.campaign = tree.make_campaign()

    def test_literal_golden_roots_cover_complete_tree_composition(
        self,
    ) -> None:
        campaign = self.campaign
        actual = {
            "parent": allocation.resource_receipt_root(
                campaign.allocation_fixture.parent
            ).hex(),
            "scope": tree.lease_node_sha256_v1(campaign.scope).hex(),
            "reservation_tree_1": tree.lease_tree_sha256_v1(
                campaign.reservation_tree_1
            ).hex(),
            "batch_1": tree.lease_allocation_batch_sha256_v1(
                campaign.batch_1
            ).hex(),
            "leaf_set_1": tree.allocation_leaf_set_sha256_v1(
                campaign.leaves_1
            ).hex(),
            "publication_1": tree.publication_binding_sha256_v1(
                campaign.batch_1
            ).hex(),
            "admission_1": campaign.admission_1.admission_sha256.hex(),
            "terminal_cancel_1": (
                campaign.terminal_cancel_1.terminal_sha256.hex()
            ),
            "reservation_tree_2": tree.lease_tree_sha256_v1(
                campaign.reservation_tree_2
            ).hex(),
            "batch_2": tree.lease_allocation_batch_sha256_v1(
                campaign.batch_2
            ).hex(),
            "leaf_set_2": tree.allocation_leaf_set_sha256_v1(
                campaign.leaves_2
            ).hex(),
            "publication_2": tree.publication_binding_sha256_v1(
                campaign.batch_2
            ).hex(),
            "admission_2": campaign.admission_2.admission_sha256.hex(),
            "materialized_tree_2": tree.lease_tree_sha256_v1(
                campaign.materialized_tree_2
            ).hex(),
            "object_set_2": campaign.object_set_2.object_set_sha256.hex(),
            "lease_2": campaign.lease_2.lease_sha256.hex(),
            "authorized_tree_2": tree.lease_tree_sha256_v1(
                campaign.authorized_tree_2
            ).hex(),
            "permit_2": tree.lease_free_permit_sha256_v1(
                campaign.permit_2
            ).hex(),
            "outstanding_2": (
                campaign.recovery_free_2.outstanding_set_sha256.hex()
            ),
            "recovery_free_2": (
                campaign.recovery_free_2.recovery_sha256.hex()
            ),
            "recovery_settlement_2": (
                campaign.recovery_settlement_2.recovery_sha256.hex()
            ),
            "terminal_tree_2": tree.lease_tree_sha256_v1(
                campaign.terminal_release_2.terminal_tree
            ).hex(),
            "terminal_release_2": (
                campaign.terminal_release_2.terminal_sha256.hex()
            ),
        }
        for ordinal, leaf in enumerate(campaign.leaves_1):
            actual["leaf_1_%d" % ordinal] = (
                tree.lease_node_sha256_v1(leaf).hex()
            )
        for ordinal, leaf in enumerate(campaign.leaves_2):
            actual["leaf_2_%d" % ordinal] = (
                tree.lease_node_sha256_v1(leaf).hex()
            )
        for ordinal, call in enumerate(campaign.calls_2):
            actual["call_2_%d" % ordinal] = call.call_sha256.hex()
        for ordinal, item in enumerate(campaign.objects_2):
            actual["object_2_%d" % ordinal] = item.object_sha256.hex()

        expected = {
            "parent": (
                "2bb3c84cccbab6fd65e803e2dd645b3b"
                "825e8f433562ed8767c29dd7f8dd73b0"
            ),
            "scope": (
                "50430f53e717d1c2412b27d10c27142c"
                "7599627a5d1837a7d0c9bb5335a470e8"
            ),
            "reservation_tree_1": (
                "c9d4ed4a0df86cffb3720d97dc8ac444"
                "104fa19838fd051495724d4a7343adc3"
            ),
            "batch_1": (
                "22042c0ea52d80a9de60978521da5570"
                "093a82b7a0b1e4b9b64ee8ac5a397082"
            ),
            "leaf_set_1": (
                "6df1d9c657b7c43e96541dceb37781d4"
                "d6ace79d20590f43e7e8c9580d90a9de"
            ),
            "publication_1": (
                "85f572413e82b885446905d87862a37e"
                "27e2120aa583126ee47656823ee1817e"
            ),
            "admission_1": (
                "160dda1c947f61ddd20fe490ef8fffb3"
                "8374544da987da01c0736a8235f5dcf2"
            ),
            "terminal_cancel_1": (
                "679596cf0de6804890bc0f3b0cc11f10"
                "ef7fb461d6999f7e35bb3acd521509e9"
            ),
            "reservation_tree_2": (
                "5013d70445c815468589bf7babf26f37"
                "8118ce2aa7e0670dd59fbac394c0d9d5"
            ),
            "batch_2": (
                "76d743677341f7b0a1b1948810a664af"
                "28ac248abf13869ca4dc1f28b85af202"
            ),
            "leaf_set_2": (
                "c8716b822035b0fa4c0716719b930c91"
                "9018b5b72a526fc6f06c75184ddc42d4"
            ),
            "publication_2": (
                "85f572413e82b885446905d87862a37e"
                "27e2120aa583126ee47656823ee1817e"
            ),
            "admission_2": (
                "c12e7846d353e09d42af842ed923b216"
                "c468d56eebe8ea0965caca50b45d7414"
            ),
            "materialized_tree_2": (
                "822a2ae5dcfed078045741293fa2024b"
                "73b7f181f9fd1948aaa9f1eb05c03bb0"
            ),
            "object_set_2": (
                "6c658fa780e2e01102b38508bd2aa4b6"
                "f9218450eb6c9f5317a0a58a9ffe7418"
            ),
            "lease_2": (
                "3e2f35f71ccda404a2f6d9ebd18a1c7f"
                "fa0e88c2deccbcabd0e7557711b2211b"
            ),
            "authorized_tree_2": (
                "2f285718598af11581da3bdf835bbcf9"
                "eb1b11bbfbcafa13a42f92cfee2f24a8"
            ),
            "permit_2": (
                "c3aa16c01d6650e8e433635b9f14f929"
                "06d1d08c7303b0adba11ca18e8be742a"
            ),
            "outstanding_2": (
                "5463ee1c5ac81d555dfd917c88962fac"
                "ef6dd7b75a9031ff139a0989b2a511f3"
            ),
            "recovery_free_2": (
                "af1656c374960e32807cb33db889f7c4"
                "44dd35249ae948bb840efaa8f62e998f"
            ),
            "recovery_settlement_2": (
                "1f390c48781dc37b62dabb70ab7816f0"
                "07d6aa0a5648c2a857d855b344cd25b0"
            ),
            "terminal_tree_2": (
                "2a7d86767966b6f0e16dfd7ea2c219a"
                "33156554448748162f125ec213cb9a991"
            ),
            "terminal_release_2": (
                "252693d4a9477fe5b693443595919619"
                "367ac88c6c2039bfa4c698ea4472abe1"
            ),
            "leaf_1_0": (
                "57a8a3fca1ab68213592da10e95dd5ac"
                "54fe2c4f9f20aa584a624fac51dd4f92"
            ),
            "leaf_1_1": (
                "cda1726195497e4bea50fd906b4a077d"
                "899693f78971acd20bed125dad881a86"
            ),
            "leaf_1_2": (
                "b75a45620e8efa1f7065c68ee0331713"
                "5d59fa624c2b3e25151de4f3fbce1e15"
            ),
            "leaf_2_0": (
                "78455ad07db46835e62d07e60872dd30"
                "2a20c32265964d9760239947004bc899"
            ),
            "leaf_2_1": (
                "5ab5c820b5f3a0633445edf6828457c3"
                "e083490f9a8b68cf79c62168a446f4d3"
            ),
            "leaf_2_2": (
                "4fc6185bf7dcf3a324d4099e022b6e57"
                "8a5c960efd551e1f6d6b29b22079954e"
            ),
            "call_2_0": (
                "0c838794dd2ec3409414de2b77364d0e"
                "3e31be159948282c60256da5067c8a36"
            ),
            "call_2_1": (
                "17939f71ddc85d2c1203df2f7ef059ba"
                "2a4ebb4fe0ba9253b9e75be5eec10287"
            ),
            "call_2_2": (
                "28e291e8febb10c0e4bda56cd8dee2d6"
                "de5d8a92c749ce83b0416470c559792d"
            ),
            "object_2_0": (
                "185e2d0c5b6dde43d9a214399acaf3b3"
                "e0094fa9e670d6af705f36d0715ab03b"
            ),
            "object_2_1": (
                "5cf3af189dc2b2fd7ebb3d9d76a67626"
                "adef09251a9188a4144961570e018431"
            ),
            "object_2_2": (
                "15d3dddc78c94b60603e95d0598969bd"
                "3711d0a27f8c99e92f7a029125d6773c"
            ),
        }
        self.assertEqual(expected, actual)

    def test_fixed_session_and_resourcebank_checksum_literals(
        self,
    ) -> None:
        campaign = self.campaign
        self.assertEqual(0x4754_5345, campaign.session_id)
        self.assertEqual(0, campaign.publication_sequence)
        self.assertEqual(0x8E2A_324B_2CD0_638B, campaign.scope.integrity)
        self.assertEqual(
            (
                0xD9C3_F1AE_6A73_1F1E,
                0x5BA5_C120_9139_D2F1,
            ),
            (
                campaign.reservation_tree_1.state_digest,
                campaign.reservation_tree_1.integrity,
            ),
        )
        self.assertEqual(
            (
                0x12DB_0F73_8A21_093B,
                0xBD63_E8F5_00C5_35FD,
            ),
            (
                campaign.reservation_tree_2.state_digest,
                campaign.reservation_tree_2.integrity,
            ),
        )
        self.assertEqual(
            (
                0x7590_6EF8_123B_9345,
                0x5F65_D79D_B0F9_EBD9,
            ),
            (
                campaign.materialized_tree_2.state_digest,
                campaign.materialized_tree_2.integrity,
            ),
        )
        self.assertEqual(
            (
                0x6989_E441_1DE8_D524,
                0x088A_6B89_C88A_32FE,
            ),
            (
                campaign.authorized_tree_2.state_digest,
                campaign.authorized_tree_2.integrity,
            ),
        )
        self.assertEqual(
            (0xF9DC_5009_BD77_9BE0, 0x7FA3_5987_4194_25E5),
            (
                campaign.batch_1.node_set_digest,
                campaign.batch_1.integrity,
            ),
        )
        self.assertEqual(
            (0x957B_29BD_C605_68D9, 0x1D05_993E_99BB_8B93),
            (
                campaign.batch_2.node_set_digest,
                campaign.batch_2.integrity,
            ),
        )
        self.assertEqual(
            (0x7048_252C_6695_4C13, 0x51D4_D887_C203_1BC9),
            (
                campaign.permit_2.node_set_digest,
                campaign.permit_2.integrity,
            ),
        )

    def test_public_validators_reject_resealed_cross_bindings(
        self,
    ) -> None:
        campaign = self.campaign

        def resealed_admission(
            *,
            scope=campaign.scope,
            reservation_tree=campaign.reservation_tree_2,
        ):
            draft = replace(
                campaign.admission_2,
                scope=scope,
                reservation_tree=reservation_tree,
                admission_sha256=tree.ZERO_DIGEST,
            )
            return replace(
                draft,
                admission_sha256=tree.admission_root_v1(draft),
            )

        def assert_scope_tamper_rejected(**changes) -> None:
            candidate_scope = tree.seal_lease_node(
                replace(
                    campaign.scope,
                    **changes,
                    integrity=0,
                )
            )
            with self.assertRaises(tree.ContractError):
                tree.validate_admission_v1(
                    resealed_admission(scope=candidate_scope)
                )

        foreign_scope = tree.seal_lease_node(
            replace(
                campaign.scope,
                tree_key=campaign.scope.tree_key + 1,
                integrity=0,
            )
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_admission_v1(
                resealed_admission(scope=foreign_scope)
            )

        short_scope = tree.seal_lease_node(
            replace(
                campaign.scope,
                ceiling=tree.ClaimV1(device_bytes=4096),
                integrity=0,
            )
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_admission_v1(
                resealed_admission(scope=short_scope)
            )

        scope_tampers = (
            (
                "parent_index",
                {"parent_index": campaign.scope.node_index},
            ),
            (
                "parent_generation",
                {
                    "parent_generation": (
                        campaign.reservation_tree_2.identity_generation
                        + 1
                    )
                },
            ),
            ("node_key", {"node_key": 0}),
            ("tenant_key", {"tenant_key": 0}),
            ("generation", {"generation": 0}),
            ("max_node_index", {"node_index": tree.U32_MAX}),
        )
        for label, changes in scope_tampers:
            with self.subTest(scope_tamper=label):
                assert_scope_tamper_rejected(**changes)

        undercharged_tree = tree.seal_lease_tree(
            replace(
                campaign.reservation_tree_2,
                current=tree.ClaimV1(device_bytes=4096),
                integrity=0,
            )
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_admission_v1(
                resealed_admission(
                    reservation_tree=undercharged_tree
                )
            )

    def test_resealed_tree_topology_tampers_fail_closed(self) -> None:
        campaign = self.campaign
        original_tree = campaign.reservation_tree_2

        def assert_tree_tamper_rejected(
            tree_changes,
            scope_changes=None,
        ) -> None:
            candidate_tree = tree.seal_lease_tree(
                replace(original_tree, **tree_changes, integrity=0)
            )
            candidate_scope = campaign.scope
            if scope_changes is not None:
                candidate_scope = tree.seal_lease_node(
                    replace(
                        candidate_scope,
                        **scope_changes,
                        integrity=0,
                    )
                )
            draft = replace(
                campaign.admission_2,
                reservation_tree=candidate_tree,
                scope=candidate_scope,
                admission_sha256=tree.ZERO_DIGEST,
            )
            candidate = replace(
                draft,
                admission_sha256=tree.admission_root_v1(draft),
            )
            with self.assertRaises(tree.ContractError):
                tree.validate_admission_v1(candidate)

        topology_tampers = (
            (
                "tree_key",
                {"tree_key": 0},
                {"tree_key": 0},
            ),
            ("authority_key", {"authority_key": 0}, None),
            (
                "identity_generation",
                {"identity_generation": 0},
                {
                    "tree_identity_generation": 0,
                    "parent_generation": 0,
                },
            ),
            (
                "tree_generation",
                {
                    "generation": (
                        original_tree.identity_generation
                    )
                },
                None,
            ),
            (
                "structural_revision",
                {"structural_revision": 0},
                None,
            ),
            ("active_nodes", {"active_nodes": 0}, None),
            (
                "current_exceeds_ceiling",
                {
                    "current": tree.ClaimV1(
                        device_bytes=(
                            original_tree.ceiling.device_bytes + 1
                        )
                    )
                },
                None,
            ),
        )
        for label, tree_changes, scope_changes in topology_tampers:
            with self.subTest(tree_tamper=label):
                assert_tree_tamper_rejected(
                    tree_changes,
                    scope_changes,
                )

    def test_public_volume_and_active_node_bounds_fail_closed(
        self,
    ) -> None:
        campaign = self.campaign

        def reseal_admission(**changes):
            draft = replace(
                campaign.admission_2,
                **changes,
                admission_sha256=tree.ZERO_DIGEST,
            )
            return replace(
                draft,
                admission_sha256=tree.admission_root_v1(draft),
            )

        def reseal_lease(**changes):
            draft = replace(
                campaign.lease_2,
                **changes,
                lease_sha256=tree.ZERO_DIGEST,
            )
            return replace(
                draft,
                lease_sha256=tree.lease_root_v1(draft),
            )

        def reseal_recovery(source, **changes):
            draft = replace(
                source,
                **changes,
                recovery_sha256=tree.ZERO_DIGEST,
            )
            return replace(
                draft,
                recovery_sha256=tree.recovery_root_v1(draft),
            )

        def reseal_terminal(**changes):
            draft = replace(
                campaign.terminal_release_2,
                **changes,
                terminal_sha256=tree.ZERO_DIGEST,
            )
            return replace(
                draft,
                terminal_sha256=tree.terminal_root_v1(draft),
            )

        two_byte_scope = tree.seal_lease_node(
            replace(
                campaign.scope,
                ceiling=tree.ClaimV1(device_bytes=2),
                integrity=0,
            )
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_admission_v1(
                reseal_admission(
                    scope=two_byte_scope,
                    total_device_bytes=2,
                )
            )

        sparse_reservation_tree = tree.seal_lease_tree(
            replace(
                campaign.reservation_tree_2,
                active_nodes=campaign.admission_2.allocation_count,
                integrity=0,
            )
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_admission_v1(
                reseal_admission(
                    reservation_tree=sparse_reservation_tree,
                )
            )

        with self.assertRaises(tree.ContractError):
            tree.validate_lease_v1(
                reseal_lease(
                    scope=two_byte_scope,
                    materialized_bytes=2,
                )
            )

        sparse_materialized_tree = tree.seal_lease_tree(
            replace(
                campaign.materialized_tree_2,
                active_nodes=campaign.lease_2.allocation_count,
                integrity=0,
            )
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_lease_v1(
                reseal_lease(
                    materialized_tree=sparse_materialized_tree,
                )
            )

        with self.assertRaises(tree.ContractError):
            tree.validate_recovery_v1(
                reseal_recovery(
                    campaign.recovery_free_2,
                    outstanding_object_count=2,
                    outstanding_bytes=1,
                )
            )

        one_node_pending_tree = tree.seal_lease_tree(
            replace(
                campaign.authorized_tree_2,
                active_nodes=1,
                integrity=0,
            )
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_recovery_v1(
                reseal_recovery(
                    campaign.recovery_settlement_2,
                    pending_tree=one_node_pending_tree,
                )
            )

        unrestored_terminal_tree = tree.seal_lease_tree(
            replace(
                campaign.terminal_release_2.terminal_tree,
                current=tree.ClaimV1(device_bytes=1),
                active_nodes=3,
                integrity=0,
            )
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_terminal_v1(
                reseal_terminal(
                    terminal_tree=unrestored_terminal_tree,
                )
            )

        partially_restored_scope = tree.seal_lease_node(
            replace(
                campaign.scope,
                ceiling=tree.ClaimV1(device_bytes=8_191),
                integrity=0,
            )
        )
        underspecified_terminal_tree = tree.seal_lease_tree(
            replace(
                campaign.terminal_release_2.terminal_tree,
                current=tree.ClaimV1(device_bytes=1),
                active_nodes=2,
                integrity=0,
            )
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_terminal_v1(
                reseal_terminal(
                    returned_device_bytes=8_191,
                    terminal_tree=underspecified_terminal_tree,
                    scope=partially_restored_scope,
                )
            )

    def test_ordering_and_generic_admission_root_seams_fail_closed(
        self,
    ) -> None:
        campaign = self.campaign
        self.assertNotEqual(
            tree.allocation_leaf_set_sha256_v1(campaign.leaves_2),
            tree.allocation_leaf_set_sha256_v1(
                tuple(reversed(campaign.leaves_2))
            ),
        )
        with self.assertRaises(tree.ContractError):
            tree.outstanding_set_sha256_v1(
                campaign.coordinator_epoch,
                campaign.admission_2.generation,
                (
                    (1, campaign.objects_2[1]),
                    (0, campaign.objects_2[0]),
                ),
            )

        call = campaign.calls_2[0]
        foreign_call = replace(
            call,
            admission_sha256=allocation.digest_v1(
                b"foreign LeaseTree admission"
            ),
            call_sha256=allocation.ZERO_DIGEST,
        )
        foreign_call = replace(
            foreign_call,
            call_sha256=allocation.allocation_call_root(foreign_call),
        )
        foreign_object = allocation.make_backend_object(
            foreign_call,
            campaign.objects_2[0].backend_object_sha256,
            campaign.objects_2[0].backend_object_generation,
        )
        calls = (foreign_call,) + campaign.calls_2[1:]
        objects = (foreign_object,) + campaign.objects_2[1:]
        with self.assertRaises(allocation.ContractError):
            allocation.make_object_set_for_admission_root(
                campaign.admission_2.admission_sha256,
                campaign.admission_2.authority_sha256,
                campaign.admission_2.allocation_count,
                campaign.admission_2.total_device_bytes,
                calls,
                objects,
            )

    def test_recovery_phase_pairs_and_dual_object_binding(
        self,
    ) -> None:
        campaign = self.campaign
        wrong_phase = replace(
            campaign.recovery_free_2,
            phase=tree.PHASE_SETTLEMENT_REQUIRED,
            recovery_sha256=tree.ZERO_DIGEST,
        )
        wrong_phase = replace(
            wrong_phase,
            recovery_sha256=tree.recovery_root_v1(wrong_phase),
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_recovery_v1(wrong_phase)

        rollback_release = replace(
            campaign.recovery_free_2,
            phase=tree.PHASE_ROLLBACK_RESERVED,
            recovery_sha256=tree.ZERO_DIGEST,
        )
        rollback_release = replace(
            rollback_release,
            recovery_sha256=tree.recovery_root_v1(
                rollback_release
            ),
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_recovery_v1(rollback_release)

        original = campaign.objects_2[1]
        malformed_stored_root = replace(
            original,
            object_sha256=allocation.digest_v1(
                b"malformed stored object root"
            ),
        )
        original_root = tree.outstanding_set_sha256_v1(
            campaign.coordinator_epoch,
            campaign.admission_2.generation,
            ((1, original),),
        )
        malformed_root = tree.outstanding_set_sha256_v1(
            campaign.coordinator_epoch,
            campaign.admission_2.generation,
            ((1, malformed_stored_root),),
        )
        self.assertNotEqual(original_root, malformed_root)
        self.assertEqual(
            allocation.backend_object_root(original),
            allocation.backend_object_root(malformed_stored_root),
        )
        self.assertEqual(
            tree.ZERO_DIGEST,
            tree.outstanding_set_sha256_v1(
                campaign.coordinator_epoch,
                campaign.admission_2.generation,
                (),
            ),
        )

    def test_all_public_campaign_evidence_validates(self) -> None:
        campaign = self.campaign
        for candidate in (
            campaign.reservation_tree_1,
            campaign.reservation_tree_2,
            campaign.materialized_tree_2,
            campaign.authorized_tree_2,
            campaign.terminal_cancel_1.terminal_tree,
            campaign.terminal_release_2.terminal_tree,
        ):
            tree.validate_lease_tree(candidate)
        for candidate in (
            campaign.scope,
            *campaign.leaves_1,
            *campaign.leaves_2,
        ):
            tree.validate_lease_node(candidate)
        tree.validate_lease_allocation_batch(campaign.batch_1)
        tree.validate_lease_allocation_batch(campaign.batch_2)
        tree.validate_lease_free_permit(campaign.permit_2)
        tree.validate_admission_v1(campaign.admission_1)
        tree.validate_admission_v1(campaign.admission_2)
        tree.validate_lease_v1(campaign.lease_2)
        tree.validate_recovery_v1(campaign.recovery_free_2)
        tree.validate_recovery_v1(campaign.recovery_settlement_2)
        tree.validate_terminal_v1(campaign.terminal_cancel_1)
        tree.validate_terminal_v1(campaign.terminal_release_2)


if __name__ == "__main__":
    unittest.main()
