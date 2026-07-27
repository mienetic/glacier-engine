from __future__ import annotations

from dataclasses import fields, replace
import unittest

from bench import device_allocation_lease as allocation
from bench import device_allocation_lease_tree as tree


class DeviceAllocationLeaseTreeOracleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.campaign = tree.make_campaign()
        self.dispatch = tree.make_dispatch_campaign()

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

    def test_dispatch_literal_goldens_cover_private_and_public_layers(
        self,
    ) -> None:
        campaign = self.dispatch
        actual = {
            "owner_key": f"{campaign.owner_key:016x}",
            "node_set_digest": (
                f"{campaign.permit.node_set_digest:016x}"
            ),
            "pin_slot_integrity": (
                f"{campaign.pin_slot.integrity:016x}"
            ),
            "permit_integrity": (
                f"{campaign.permit.integrity:016x}"
            ),
            "permit_sha256": tree.lease_pin_permit_sha256_v1(
                campaign.permit
            ).hex(),
            "pinned_state_digest": (
                f"{campaign.pinned_tree.state_digest:016x}"
            ),
            "pinned_tree_integrity": (
                f"{campaign.pinned_tree.integrity:016x}"
            ),
            "pinned_tree_sha256": tree.lease_tree_sha256_v1(
                campaign.pinned_tree
            ).hex(),
            "dispatch_publication": (
                campaign.pin.publication_binding_sha256.hex()
            ),
            "pin_sha256": campaign.pin.pin_sha256.hex(),
            "terminal_sha256": campaign.terminal.terminal_sha256.hex(),
            "completed_state_digest": (
                f"{campaign.completed_tree.state_digest:016x}"
            ),
            "completed_tree_integrity": (
                f"{campaign.completed_tree.integrity:016x}"
            ),
            "completed_tree_sha256": tree.lease_tree_sha256_v1(
                campaign.completed_tree
            ).hex(),
            "bank_completion_integrity": (
                f"{campaign.bank_completion.integrity:016x}"
            ),
            "bank_completion_sha256": (
                tree.lease_pin_completion_sha256_v1(
                    campaign.bank_completion
                ).hex()
            ),
            "completion_publication": (
                campaign.completion
                .completion_publication_binding_sha256.hex()
            ),
            "completion_sha256": (
                campaign.completion.completion_sha256.hex()
            ),
        }
        expected = {
            "owner_key": "1c07aa9dc5188257",
            "node_set_digest": "02b67c2b909cd08a",
            "pin_slot_integrity": "9ceb6915a74db67d",
            "permit_integrity": "596b83b5db4cac13",
            "permit_sha256": (
                "c5564e2a5c384045114415840ebd066f"
                "5f02722832a2cd913a76e09c47bf6ffd"
            ),
            "pinned_state_digest": "26641bdd59211036",
            "pinned_tree_integrity": "534f1bde6edcc150",
            "pinned_tree_sha256": (
                "1c1eaf56f228ba78a22fc63efd4c0d90"
                "7341f6956c53ca2a0a848e73b2752412"
            ),
            "dispatch_publication": (
                "1248e6c72b4450976473bff890f6e3eb"
                "4a0a5f4ffa42474e84b0d03072080b3f"
            ),
            "pin_sha256": (
                "2d9b5c285f548afcc5d94c74c2cd8bb8"
                "20ef9735a1b3023ac0f43b896ea93dcc"
            ),
            "terminal_sha256": (
                "d2beeff27770569cd4d3b95cae39431a"
                "d092f7a99ba35f75ab5ed7c2073f9e2a"
            ),
            "completed_state_digest": "758b1f6f12e2814b",
            "completed_tree_integrity": "37e1404800691921",
            "completed_tree_sha256": (
                "cbfe82c46465013a683fd0306e592cb0"
                "21fc75bad5c1a4c0849824f37b6a58af"
            ),
            "bank_completion_integrity": "85bedbfca0b4309b",
            "bank_completion_sha256": (
                "c8db4b240da276a4574d5e1086a81742"
                "86a74510f7d60e07f8cb12a3f07f0cae"
            ),
            "completion_publication": (
                "1248e6c72b4450976473bff890f6e3eb"
                "4a0a5f4ffa42474e84b0d03072080b3f"
            ),
            "completion_sha256": (
                "66c2c7cf87a0a05ec6fd7605179ffc06"
                "95b479880340e73381cdb1f048f2205d"
            ),
        }
        self.assertEqual(expected, actual)

    def test_rejected_before_submit_goldens_release_exact_pin(
        self,
    ) -> None:
        campaign = (
            tree.make_rejected_before_submit_dispatch_campaign()
        )
        actual = {
            "pin_sha256": campaign.pin.pin_sha256.hex(),
            "terminal_sha256": campaign.terminal.terminal_sha256.hex(),
            "bank_completion_sha256": (
                tree.lease_pin_completion_sha256_v1(
                    campaign.bank_completion
                ).hex()
            ),
            "completed_tree_sha256": tree.lease_tree_sha256_v1(
                campaign.completed_tree
            ).hex(),
            "completion_sha256": (
                campaign.completion.completion_sha256.hex()
            ),
        }
        expected = {
            "pin_sha256": (
                "2d9b5c285f548afcc5d94c74c2cd8bb8"
                "20ef9735a1b3023ac0f43b896ea93dcc"
            ),
            "terminal_sha256": (
                "da4a5b8a14278caa357a85ebadd79766"
                "cca848f60b94924e857321a4a984612a"
            ),
            "bank_completion_sha256": (
                "c8db4b240da276a4574d5e1086a81742"
                "86a74510f7d60e07f8cb12a3f07f0cae"
            ),
            "completed_tree_sha256": (
                "cbfe82c46465013a683fd0306e592cb0"
                "21fc75bad5c1a4c0849824f37b6a58af"
            ),
            "completion_sha256": (
                "30426046c9fc16eb063430173119def8"
                "933e3d2a6c3cf43b58e5e237717d25de"
            ),
        }
        self.assertEqual(expected, actual)
        self.assertEqual(
            tree.DISPATCH_REJECTED_BEFORE_SUBMIT,
            campaign.terminal.outcome,
        )
        self.assertEqual(
            (
                tree.ZERO_DIGEST,
                tree.ZERO_DIGEST,
                tree.ZERO_DIGEST,
            ),
            (
                campaign.terminal.submission_sha256,
                campaign.terminal.backend_completion_sha256,
                campaign.terminal.output_sha256,
            ),
        )
        tree.validate_rejected_before_submit_terminal_for_pin_v1(
            campaign.terminal,
            campaign.pin,
        )
        tree.validate_dispatch_completion_for_bank_v1(
            campaign.completion,
            campaign.pin,
            campaign.terminal,
            campaign.permit,
            campaign.bank_completion,
        )
        self.assertEqual(self.dispatch.pin, campaign.pin)
        self.assertEqual(
            self.dispatch.bank_completion,
            campaign.bank_completion,
        )
        self.assertEqual(
            self.dispatch.completed_tree,
            campaign.completed_tree,
        )
        self.assertTrue(campaign.pin_slot.active)
        self.assertEqual(
            campaign.pinned_tree.current,
            campaign.completed_tree.current,
        )
        self.assertEqual(
            campaign.pinned_tree.active_nodes,
            campaign.completed_tree.active_nodes,
        )
        self.assertNotEqual(
            campaign.pinned_tree.state_digest,
            campaign.completed_tree.state_digest,
        )

    def test_metal_pre_submit_evidence_has_fixed_independent_goldens(
        self,
    ) -> None:
        campaign = (
            tree.make_metal_matvec_pre_submit_rejection_campaign()
        )
        actual = {
            "attempt_sha256": campaign.attempt.attempt_sha256.hex(),
            "request_sha256": campaign.request.request_sha256.hex(),
            "intent_sha256": campaign.intent.intent_sha256.hex(),
            "pin_sha256": campaign.pin.pin_sha256.hex(),
            "terminal_sha256": campaign.terminal.terminal_sha256.hex(),
            "rejection_sha256": (
                campaign.rejection.rejection_sha256.hex()
            ),
        }
        expected = {
            "attempt_sha256": (
                "b79371a76c12ca08d58980f5913fe33d"
                "da2aaca41e801d8a473b941a5b04e2cb"
            ),
            "request_sha256": (
                "f89175ddd5b07db24854c8432a650449"
                "a023c9445cedbc86a75459305b2e4486"
            ),
            "intent_sha256": (
                "0dcf9b07e0e30fbabf97b5efa7cb9975"
                "bba2198e7fdaf82e128d47c7fe93ebaa"
            ),
            "pin_sha256": (
                "d8a9faa9bced09e52d1867afee4e2f26"
                "98d38d9dce277bd11aab403a9289f93c"
            ),
            "terminal_sha256": (
                "a646ea614bd10b279e1f921440517633b"
                "200e959536f7d685f97310f6f099a6d"
            ),
            "rejection_sha256": (
                "64b4f359d932f74f3dc6e6cd3819b7e"
                "7d6d6fbc784f4a6ddef128268372b0f5c"
            ),
        }
        self.assertEqual(expected, actual)
        self.assertEqual(
            tree.METAL_INVALID_ROLE_MAPPING,
            campaign.rejection.reason,
        )
        self.assertEqual(
            campaign.attempt,
            campaign.request.attempt,
        )
        self.assertEqual(
            campaign.request.request_sha256,
            campaign.pin.dispatch_request_sha256,
        )
        self.assertEqual(
            campaign.request.request_sha256,
            campaign.intent.dispatch_request_sha256,
        )
        self.assertEqual(
            (
                tree.ZERO_DIGEST,
                tree.ZERO_DIGEST,
                tree.ZERO_DIGEST,
            ),
            (
                campaign.terminal.submission_sha256,
                campaign.terminal.backend_completion_sha256,
                campaign.terminal.output_sha256,
            ),
        )
        tree.validate_metal_matvec_pre_submit_attempt_v1(
            campaign.attempt
        )
        tree.validate_metal_matvec_dispatch_request_v1(
            campaign.request
        )
        tree.validate_dispatch_pin_for_intent_v1(
            campaign.pin,
            campaign.intent,
        )
        tree.validate_metal_matvec_pre_submit_rejection_for_pin_v1(
            campaign.rejection,
            campaign.pin,
            campaign.terminal,
        )

    def test_metal_async_evidence_has_fixed_independent_goldens(
        self,
    ) -> None:
        campaign = tree.make_metal_async_dispatch_evidence_campaign()
        actual = {
            "ticket_sha256": campaign.ticket.ticket_sha256.hex(),
            **{
                "quarantine_%d_sha256" % value.reason: (
                    value.quarantine_sha256.hex()
                )
                for value in campaign.quarantines
            },
        }
        expected = {
            "ticket_sha256": (
                "50eafb3b20fd1ce75b3b8be385a41300"
                "1e3d297a929bfda3ba115b99621eabc7"
            ),
            "quarantine_1_sha256": (
                "20612cc2fc1f4111353d2abbe2a565be"
                "8c03e3c33ec7dc6b5d368e4857501aa7"
            ),
            "quarantine_2_sha256": (
                "bc08b31107c056f768da3eb8f5807df2"
                "faf230ae907175ead2de62fc685626d9"
            ),
            "quarantine_3_sha256": (
                "ee46ee2bc57ad0bba2542f33bff363a9"
                "18eaa6214da5291432bf5ff3d8458cf9"
            ),
            "quarantine_4_sha256": (
                "ec05a4ea41d93a96ae763f85c217344d"
                "e3abeab261a4e7dbd169809a64d72ae9"
            ),
        }
        self.assertEqual(expected, actual)
        self.assertEqual(
            (
                tree.METAL_ASYNC_SUBMISSION_AMBIGUOUS,
                tree.METAL_ASYNC_COMPLETION_UNKNOWN,
                tree.METAL_ASYNC_INVALID_COMPLETION,
                tree.METAL_ASYNC_TERMINAL_COMMAND_ERROR,
            ),
            tuple(value.reason for value in campaign.quarantines),
        )
        tree.validate_metal_async_dispatch_ticket_for_dispatch_v1(
            campaign.ticket,
            21,
            campaign.request,
            campaign.pin,
            campaign.submission_sha256,
        )
        for value in campaign.quarantines:
            tree.validate_metal_async_dispatch_quarantine_for_ticket_v1(
                value,
                campaign.ticket,
                campaign.device_sha256,
                campaign.placement_sha256,
            )
            tree.validate_metal_async_dispatch_quarantine_replay_v1(
                value,
                value,
            )
        self.assertNotIn(
            "terminal_sha256",
            tree.MetalAsyncDispatchQuarantineV1.__dataclass_fields__,
        )
        self.assertNotIn(
            "output_sha256",
            tree.MetalAsyncDispatchQuarantineV1.__dataclass_fields__,
        )

    def test_metal_async_schema_field_order_is_explicit(
        self,
    ) -> None:
        self.assertEqual(
            (
                "abi_version",
                "ticket_generation",
                "queue_slot",
                "dispatch_generation",
                "dispatch_authority_sha256",
                "queue_authority_sha256",
                "request",
                "pin_sha256",
                "submission_sha256",
                "ticket_sha256",
            ),
            tuple(
                field.name
                for field in fields(tree.MetalAsyncDispatchTicketV1)
            ),
        )
        self.assertEqual(
            (
                "abi_version",
                "reason",
                "ticket",
                "device_sha256",
                "placement_sha256",
                "native_disposition",
                "native_command_status",
                "native_completion_observed",
                "error_domain_kind",
                "error_code_bits",
                "quarantine_sha256",
            ),
            tuple(
                field.name
                for field in fields(
                    tree.MetalAsyncDispatchQuarantineV1
                )
            ),
        )

    def test_metal_async_ticket_mutation_reseal_and_aba_fail_closed(
        self,
    ) -> None:
        campaign = tree.make_metal_async_dispatch_evidence_campaign()
        ticket = campaign.ticket
        foreign = allocation.digest_v1(
            b"foreign Metal async ticket field"
        )
        second_request = tree.make_metal_matvec_dispatch_request_v1(
            campaign.request.request_generation + 1,
            campaign.request.dispatch_authority_sha256,
            campaign.request.queue_authority_sha256,
            campaign.request.attempt,
        )
        second_ticket = tree.make_metal_async_dispatch_ticket_v1(
            ticket.ticket_generation + 1,
            campaign.request,
            campaign.pin,
            campaign.submission_sha256,
        )
        unsealed_tampers = {
            "abi_version": ticket.abi_version + 1,
            "ticket_generation": ticket.ticket_generation + 1,
            "queue_slot": 1,
            "dispatch_generation": ticket.dispatch_generation + 1,
            "dispatch_authority_sha256": foreign,
            "queue_authority_sha256": foreign,
            "request": second_request,
            "pin_sha256": foreign,
            "submission_sha256": foreign,
            "ticket_sha256": foreign,
        }
        self.assertEqual(
            set(ticket.__dataclass_fields__),
            set(unsealed_tampers),
        )
        for field, value in unsealed_tampers.items():
            with self.subTest(metal_async_ticket_field=field):
                with self.assertRaises(tree.ContractError):
                    tree.validate_metal_async_dispatch_ticket_v1(
                        replace(ticket, **{field: value})
                    )

        def reseal_ticket(**changes):
            draft = replace(
                ticket,
                **changes,
                ticket_sha256=tree.ZERO_DIGEST,
            )
            return replace(
                draft,
                ticket_sha256=(
                    tree.metal_async_dispatch_ticket_root_v1(draft)
                ),
            )

        coherent_generation = reseal_ticket(
            ticket_generation=ticket.ticket_generation + 1
        )
        self.assertEqual(second_ticket, coherent_generation)
        tree.validate_metal_async_dispatch_ticket_v1(
            coherent_generation
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_metal_async_dispatch_ticket_for_dispatch_v1(
                ticket,
                coherent_generation.ticket_generation,
                campaign.request,
                campaign.pin,
                campaign.submission_sha256,
            )

        coherent_submission = reseal_ticket(
            submission_sha256=foreign
        )
        tree.validate_metal_async_dispatch_ticket_v1(
            coherent_submission
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_metal_async_dispatch_ticket_for_dispatch_v1(
                coherent_submission,
                ticket.ticket_generation,
                campaign.request,
                campaign.pin,
                campaign.submission_sha256,
            )

        coherent_pin = reseal_ticket(pin_sha256=foreign)
        tree.validate_metal_async_dispatch_ticket_v1(coherent_pin)
        with self.assertRaises(tree.ContractError):
            tree.validate_metal_async_dispatch_ticket_for_dispatch_v1(
                coherent_pin,
                ticket.ticket_generation,
                campaign.request,
                campaign.pin,
                campaign.submission_sha256,
            )

        foreign_pin_draft = replace(
            campaign.pin,
            dispatch_request_sha256=second_request.request_sha256,
            pin_sha256=tree.ZERO_DIGEST,
        )
        foreign_pin = replace(
            foreign_pin_draft,
            pin_sha256=tree.dispatch_pin_root_v1(
                foreign_pin_draft
            ),
        )
        tree.validate_dispatch_pin_v1(foreign_pin)
        mismatched_request_pin = reseal_ticket(
            pin_sha256=foreign_pin.pin_sha256
        )
        tree.validate_metal_async_dispatch_ticket_v1(
            mismatched_request_pin
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_metal_async_dispatch_ticket_for_dispatch_v1(
                mismatched_request_pin,
                ticket.ticket_generation,
                campaign.request,
                foreign_pin,
                campaign.submission_sha256,
            )

        coherent_request = reseal_ticket(request=second_request)
        tree.validate_metal_async_dispatch_ticket_v1(coherent_request)
        with self.assertRaises(tree.ContractError):
            tree.validate_metal_async_dispatch_ticket_for_dispatch_v1(
                coherent_request,
                ticket.ticket_generation,
                campaign.request,
                campaign.pin,
                campaign.submission_sha256,
            )

        with self.assertRaises(tree.ContractError):
            tree.validate_metal_async_dispatch_ticket_v1(
                reseal_ticket(queue_slot=1)
            )
        for invalid_generation in (0, tree.U64_MAX):
            with self.subTest(
                invalid_ticket_generation=invalid_generation
            ):
                with self.assertRaises(tree.ContractError):
                    tree.make_metal_async_dispatch_ticket_v1(
                        invalid_generation,
                        campaign.request,
                        campaign.pin,
                        campaign.submission_sha256,
                    )
        with self.assertRaises(tree.ContractError):
            tree.metal_async_dispatch_ticket_root_v1(
                replace(
                    ticket,
                    ticket_generation=tree.U64_MAX + 1,
                )
            )

    def test_metal_async_quarantine_reason_shapes_are_exact(
        self,
    ) -> None:
        campaign = tree.make_metal_async_dispatch_evidence_campaign()
        expected_shapes = (
            (
                tree.METAL_ASYNC_SUBMISSION_AMBIGUOUS,
                tree.METAL_ASYNC_COMMIT_STARTED,
                tree.METAL_ASYNC_COMMAND_STATUS_UNOBSERVED,
                0,
                tree.METAL_ASYNC_ERROR_NATIVE_BRIDGE,
                tree.METAL_ASYNC_SUBMISSION_AMBIGUOUS_ADAPTER_CODE,
            ),
            (
                tree.METAL_ASYNC_COMPLETION_UNKNOWN,
                tree.METAL_ASYNC_SUBMITTED,
                77,
                1,
                tree.METAL_ASYNC_ERROR_NATIVE_BRIDGE,
                0x777,
            ),
            (
                tree.METAL_ASYNC_INVALID_COMPLETION,
                tree.METAL_ASYNC_TERMINAL_STATUS_OBSERVED,
                tree.METAL_ASYNC_COMMAND_STATUS_COMPLETED,
                1,
                tree.METAL_ASYNC_ERROR_COMPLETION_VALIDATION,
                0x202,
            ),
            (
                tree.METAL_ASYNC_TERMINAL_COMMAND_ERROR,
                tree.METAL_ASYNC_TERMINAL_STATUS_OBSERVED,
                tree.METAL_ASYNC_COMMAND_STATUS_ERROR,
                1,
                tree.METAL_ASYNC_ERROR_COMMAND_BUFFER,
                0x303,
            ),
        )
        self.assertEqual(
            expected_shapes,
            tuple(
                (
                    value.reason,
                    value.native_disposition,
                    value.native_command_status,
                    value.native_completion_observed,
                    value.error_domain_kind,
                    value.error_code_bits,
                )
                for value in campaign.quarantines
            ),
        )

        def reseal(value, **changes):
            draft = replace(
                value,
                **changes,
                quarantine_sha256=tree.ZERO_DIGEST,
            )
            return replace(
                draft,
                quarantine_sha256=(
                    tree.metal_async_dispatch_quarantine_root_v1(
                        draft
                    )
                ),
            )

        for value in campaign.quarantines:
            wrong_disposition = (
                tree.METAL_ASYNC_SUBMITTED
                if value.native_disposition
                != tree.METAL_ASYNC_SUBMITTED
                else tree.METAL_ASYNC_COMMIT_STARTED
            )
            invalid = (
                reseal(value, reason=99),
                reseal(
                    value,
                    native_disposition=wrong_disposition,
                ),
                reseal(value, native_completion_observed=2),
                reseal(
                    value,
                    error_domain_kind=tree.METAL_ASYNC_ERROR_NONE,
                ),
                reseal(value, error_code_bits=0),
            )
            for candidate in invalid:
                with self.subTest(
                    invalid_quarantine_shape=(
                        value.reason,
                        candidate,
                    )
                ):
                    with self.assertRaises(tree.ContractError):
                        tree.validate_metal_async_dispatch_quarantine_v1(
                            candidate
                        )
            if (
                value.reason
                == tree.METAL_ASYNC_COMPLETION_UNKNOWN
            ):
                raw_pending = reseal(
                    value,
                    native_command_status=(
                        tree.METAL_ASYNC_COMMAND_STATUS_UNOBSERVED
                    ),
                    native_completion_observed=0,
                )
                tree.validate_metal_async_dispatch_quarantine_v1(
                    raw_pending
                )
            else:
                with self.assertRaises(tree.ContractError):
                    tree.validate_metal_async_dispatch_quarantine_v1(
                        reseal(
                            value,
                            native_command_status=77,
                        )
                    )

    def test_metal_async_quarantine_reseal_replay_and_foreign_binding(
        self,
    ) -> None:
        campaign = tree.make_metal_async_dispatch_evidence_campaign()
        retained = campaign.quarantines[1]
        foreign = allocation.digest_v1(
            b"foreign Metal async quarantine field"
        )
        second_ticket = tree.make_metal_async_dispatch_ticket_v1(
            campaign.ticket.ticket_generation + 1,
            campaign.request,
            campaign.pin,
            campaign.submission_sha256,
        )
        unsealed_tampers = {
            "abi_version": retained.abi_version + 1,
            "reason": tree.METAL_ASYNC_TERMINAL_COMMAND_ERROR,
            "ticket": second_ticket,
            "device_sha256": foreign,
            "placement_sha256": foreign,
            "native_disposition": tree.METAL_ASYNC_COMMIT_STARTED,
            "native_command_status": (
                retained.native_command_status + 1
            ),
            "native_completion_observed": 0,
            "error_domain_kind": (
                tree.METAL_ASYNC_ERROR_COMPLETION_VALIDATION
            ),
            "error_code_bits": retained.error_code_bits + 1,
            "quarantine_sha256": foreign,
        }
        self.assertEqual(
            set(retained.__dataclass_fields__),
            set(unsealed_tampers),
        )
        for field, value in unsealed_tampers.items():
            with self.subTest(metal_async_quarantine_field=field):
                with self.assertRaises(tree.ContractError):
                    tree.validate_metal_async_dispatch_quarantine_v1(
                        replace(retained, **{field: value})
                    )

        def reseal(**changes):
            draft = replace(
                retained,
                **changes,
                quarantine_sha256=tree.ZERO_DIGEST,
            )
            return replace(
                draft,
                quarantine_sha256=(
                    tree.metal_async_dispatch_quarantine_root_v1(
                        draft
                    )
                ),
            )

        coherent_error = reseal(
            error_code_bits=retained.error_code_bits + 1
        )
        tree.validate_metal_async_dispatch_quarantine_v1(
            coherent_error
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_metal_async_dispatch_quarantine_replay_v1(
                coherent_error,
                retained,
            )

        coherent_device = reseal(device_sha256=foreign)
        tree.validate_metal_async_dispatch_quarantine_for_ticket_v1(
            coherent_device,
            campaign.ticket,
            foreign,
            campaign.placement_sha256,
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_metal_async_dispatch_quarantine_for_ticket_v1(
                coherent_device,
                campaign.ticket,
                campaign.device_sha256,
                campaign.placement_sha256,
            )

        coherent_ticket = reseal(ticket=second_ticket)
        tree.validate_metal_async_dispatch_quarantine_for_ticket_v1(
            coherent_ticket,
            second_ticket,
            campaign.device_sha256,
            campaign.placement_sha256,
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_metal_async_dispatch_quarantine_for_ticket_v1(
                coherent_ticket,
                campaign.ticket,
                campaign.device_sha256,
                campaign.placement_sha256,
            )

        with self.assertRaises(tree.ContractError):
            tree.validate_metal_async_dispatch_quarantine_v1(
                reseal(device_sha256=tree.ZERO_DIGEST)
            )
        with self.assertRaises(tree.ContractError):
            tree.validate_metal_async_dispatch_quarantine_v1(
                reseal(
                    placement_sha256=campaign.device_sha256
                )
            )
        with self.assertRaises(tree.ContractError):
            tree.metal_async_dispatch_quarantine_root_v1(
                replace(
                    retained,
                    error_code_bits=tree.U64_MAX + 1,
                )
            )

    def test_metal_pre_submit_schema_field_order_is_explicit(
        self,
    ) -> None:
        self.assertEqual(
            (
                "abi_version",
                "coordinator_epoch",
                "allocation_generation",
                "dispatch_generation",
                "allocation_count",
                "pinned_device_bytes",
                "authority_sha256",
                "dispatch_authority_sha256",
                "queue_authority_sha256",
                "request_sha256",
                "admission_sha256",
                "lease_sha256",
                "parent_receipt_sha256",
                "allocation_leaf_set_sha256",
                "backend_object_set_sha256",
                "scope_sha256",
                "dispatch_request_sha256",
                "publication_binding_sha256",
                "intent_sha256",
            ),
            tuple(
                field.name
                for field in fields(tree.DispatchPinIntentV1)
            ),
        )
        self.assertEqual(
            (
                "abi_version",
                "group_size",
                "in_features",
                "out_features",
                "reserved",
                "packed_weights_bytes",
                "scales_count",
                "input_count",
                "output_count",
                "bindings",
                "attempt_sha256",
            ),
            tuple(
                field.name
                for field in fields(
                    tree.MetalMatvecPreSubmitAttemptV1
                )
            ),
        )
        self.assertEqual(
            (
                "abi_version",
                "request_generation",
                "dispatch_authority_sha256",
                "queue_authority_sha256",
                "attempt",
                "request_sha256",
            ),
            tuple(
                field.name
                for field in fields(
                    tree.MetalMatvecDispatchRequestV1
                )
            ),
        )
        self.assertEqual(
            (
                "abi_version",
                "reason",
                "dispatch_generation",
                "allocation_count",
                "materialized_bytes",
                "pin_sha256",
                "backend_object_set_sha256",
                "request",
                "terminal_sha256",
                "rejection_sha256",
            ),
            tuple(
                field.name
                for field in fields(
                    tree.MetalMatvecPreSubmitRejectionV1
                )
            ),
        )

    def test_dispatch_pin_intent_tamper_and_substitution_fail_closed(
        self,
    ) -> None:
        campaign = (
            tree.make_metal_matvec_pre_submit_rejection_campaign()
        )
        intent = campaign.intent
        foreign = allocation.digest_v1(
            b"dispatch pin intent substitution"
        )
        unsealed_tampers = {
            "abi_version": intent.abi_version + 1,
            "coordinator_epoch": intent.coordinator_epoch + 1,
            "allocation_generation": (
                intent.allocation_generation + 1
            ),
            "dispatch_generation": intent.dispatch_generation + 1,
            "allocation_count": intent.allocation_count + 1,
            "pinned_device_bytes": intent.pinned_device_bytes + 1,
            **{
                field: foreign
                for field in (
                    "authority_sha256",
                    "dispatch_authority_sha256",
                    "queue_authority_sha256",
                    "request_sha256",
                    "admission_sha256",
                    "lease_sha256",
                    "parent_receipt_sha256",
                    "allocation_leaf_set_sha256",
                    "backend_object_set_sha256",
                    "scope_sha256",
                    "dispatch_request_sha256",
                    "publication_binding_sha256",
                    "intent_sha256",
                )
            },
        }
        self.assertEqual(
            set(intent.__dataclass_fields__),
            set(unsealed_tampers),
        )
        for field, value in unsealed_tampers.items():
            with self.subTest(dispatch_pin_intent_field=field):
                with self.assertRaises(tree.ContractError):
                    tree.validate_dispatch_pin_intent_v1(
                        replace(intent, **{field: value})
                    )

        with self.assertRaises(tree.ContractError):
            tree.dispatch_pin_intent_root_v1(
                replace(
                    intent,
                    pinned_device_bytes=tree.U64_MAX + 1,
                )
            )

        def reseal_intent(**changes):
            draft = replace(
                intent,
                **changes,
                intent_sha256=tree.ZERO_DIGEST,
            )
            return replace(
                draft,
                intent_sha256=tree.dispatch_pin_intent_root_v1(
                    draft
                ),
            )

        substitutions = (
            reseal_intent(
                coordinator_epoch=intent.coordinator_epoch + 1
            ),
            reseal_intent(
                allocation_generation=(
                    intent.allocation_generation + 1
                )
            ),
            reseal_intent(
                dispatch_generation=intent.dispatch_generation + 1
            ),
            reseal_intent(
                allocation_count=intent.allocation_count + 1
            ),
            reseal_intent(
                pinned_device_bytes=intent.pinned_device_bytes + 1
            ),
            reseal_intent(authority_sha256=foreign),
            reseal_intent(dispatch_authority_sha256=foreign),
            reseal_intent(queue_authority_sha256=foreign),
            reseal_intent(request_sha256=foreign),
            reseal_intent(admission_sha256=foreign),
            reseal_intent(lease_sha256=foreign),
            reseal_intent(parent_receipt_sha256=foreign),
            reseal_intent(allocation_leaf_set_sha256=foreign),
            reseal_intent(backend_object_set_sha256=foreign),
            reseal_intent(scope_sha256=foreign),
            reseal_intent(dispatch_request_sha256=foreign),
            reseal_intent(publication_binding_sha256=foreign),
        )
        for candidate in substitutions:
            tree.validate_dispatch_pin_intent_v1(candidate)
            with self.subTest(dispatch_pin_intent=candidate):
                with self.assertRaises(tree.ContractError):
                    tree.validate_dispatch_pin_for_intent_v1(
                        campaign.pin,
                        candidate,
                    )

        pin_draft = replace(
            campaign.pin,
            dispatch_request_sha256=foreign,
            pin_sha256=tree.ZERO_DIGEST,
        )
        substituted_pin = replace(
            pin_draft,
            pin_sha256=tree.dispatch_pin_root_v1(pin_draft),
        )
        tree.validate_dispatch_pin_v1(substituted_pin)
        with self.assertRaises(tree.ContractError):
            tree.validate_dispatch_pin_for_intent_v1(
                substituted_pin,
                intent,
            )

    def test_metal_pre_submit_attempt_mirrors_widths_and_reason_order(
        self,
    ) -> None:
        campaign = (
            tree.make_metal_matvec_pre_submit_rejection_campaign()
        )
        attempt = campaign.attempt
        foreign = allocation.digest_v1(
            b"Metal attempt field substitution"
        )
        mutations = (
            replace(attempt, abi_version=attempt.abi_version + 1),
            replace(attempt, group_size=attempt.group_size + 1),
            replace(attempt, in_features=attempt.in_features + 1),
            replace(attempt, out_features=attempt.out_features + 1),
            replace(attempt, reserved=1),
            replace(
                attempt,
                packed_weights_bytes=attempt.packed_weights_bytes + 1,
            ),
            replace(attempt, scales_count=attempt.scales_count + 1),
            replace(attempt, input_count=attempt.input_count + 1),
            replace(attempt, output_count=attempt.output_count + 1),
            replace(
                attempt,
                bindings=replace(
                    attempt.bindings,
                    packed_weights_sha256=foreign,
                ),
            ),
            replace(
                attempt,
                bindings=replace(
                    attempt.bindings,
                    scales_sha256=foreign,
                ),
            ),
            replace(
                attempt,
                bindings=replace(
                    attempt.bindings,
                    input_sha256=foreign,
                ),
            ),
            replace(
                attempt,
                bindings=replace(
                    attempt.bindings,
                    output_sha256=foreign,
                ),
            ),
        )
        for candidate in mutations:
            with self.subTest(metal_attempt_field=candidate):
                self.assertNotEqual(
                    attempt.attempt_sha256,
                    tree.metal_matvec_pre_submit_attempt_root_v1(
                        candidate
                    ),
                )
                with self.assertRaises(tree.ContractError):
                    tree.validate_metal_matvec_pre_submit_attempt_v1(
                        candidate
                    )

        with self.assertRaises(tree.ContractError):
            tree.metal_matvec_pre_submit_attempt_root_v1(
                replace(attempt, group_size=tree.U32_MAX + 1)
            )
        with self.assertRaises(tree.ContractError):
            tree.metal_matvec_pre_submit_attempt_root_v1(
                replace(
                    attempt,
                    packed_weights_bytes=tree.U64_MAX + 1,
                )
            )

        invalid_geometry = (
            tree.make_metal_matvec_pre_submit_attempt_v1(
                attempt.bindings,
                attempt.packed_weights_bytes,
                attempt.scales_count,
                attempt.input_count,
                attempt.output_count,
                0,
                attempt.in_features,
                attempt.out_features,
            )
        )
        invalid_lengths = (
            tree.make_metal_matvec_pre_submit_attempt_v1(
                attempt.bindings,
                attempt.packed_weights_bytes + 1,
                attempt.scales_count,
                attempt.input_count,
                attempt.output_count,
                attempt.group_size,
                attempt.in_features,
                attempt.out_features,
            )
        )
        duplicate_bindings = replace(
            attempt.bindings,
            output_sha256=attempt.bindings.input_sha256,
        )
        invalid_bindings = (
            tree.make_metal_matvec_pre_submit_attempt_v1(
                duplicate_bindings,
                attempt.packed_weights_bytes,
                attempt.scales_count,
                attempt.input_count,
                attempt.output_count,
                attempt.group_size,
                attempt.in_features,
                attempt.out_features,
            )
        )
        self.assertEqual(
            tree.METAL_INVALID_GEOMETRY,
            tree.classify_metal_matvec_pre_submit_rejection_v1(
                invalid_geometry
            ),
        )
        self.assertEqual(
            tree.METAL_INVALID_HOST_LENGTHS,
            tree.classify_metal_matvec_pre_submit_rejection_v1(
                invalid_lengths
            ),
        )
        self.assertEqual(
            tree.METAL_INVALID_ROLE_BINDINGS,
            tree.classify_metal_matvec_pre_submit_rejection_v1(
                invalid_bindings
            ),
        )
        self.assertIsNone(
            tree.classify_metal_matvec_pre_submit_rejection_v1(
                attempt
            )
        )

    def test_metal_dispatch_request_rejects_nested_substitution(
        self,
    ) -> None:
        campaign = (
            tree.make_metal_matvec_pre_submit_rejection_campaign()
        )
        request = campaign.request
        foreign = allocation.digest_v1(
            b"Metal request authority substitution"
        )
        attempt_draft = replace(
            campaign.attempt,
            bindings=replace(
                campaign.attempt.bindings,
                output_sha256=foreign,
            ),
            attempt_sha256=tree.ZERO_DIGEST,
        )
        different_attempt = replace(
            attempt_draft,
            attempt_sha256=(
                tree.metal_matvec_pre_submit_attempt_root_v1(
                    attempt_draft
                )
            ),
        )
        tree.validate_metal_matvec_pre_submit_attempt_v1(
            different_attempt
        )
        request_mutations = (
            replace(
                request,
                request_generation=request.request_generation + 1,
            ),
            replace(request, dispatch_authority_sha256=foreign),
            replace(request, queue_authority_sha256=foreign),
            replace(request, attempt=different_attempt),
            replace(request, request_sha256=foreign),
        )
        for candidate in request_mutations:
            with self.subTest(metal_request_field=candidate):
                with self.assertRaises(tree.ContractError):
                    tree.validate_metal_matvec_dispatch_request_v1(
                        candidate
                    )

        equal_authority_draft = replace(
            request,
            queue_authority_sha256=(
                request.dispatch_authority_sha256
            ),
            request_sha256=tree.ZERO_DIGEST,
        )
        equal_authority = replace(
            equal_authority_draft,
            request_sha256=(
                tree.metal_matvec_dispatch_request_root_v1(
                    equal_authority_draft
                )
            ),
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_metal_matvec_dispatch_request_v1(
                equal_authority
            )
        with self.assertRaises(tree.ContractError):
            tree.metal_matvec_dispatch_request_root_v1(
                replace(
                    request,
                    request_generation=tree.U64_MAX + 1,
                )
            )

        coherent_request_drafts = (
            replace(
                request,
                attempt=different_attempt,
                request_sha256=tree.ZERO_DIGEST,
            ),
            replace(
                request,
                request_generation=request.request_generation + 1,
                request_sha256=tree.ZERO_DIGEST,
            ),
        )
        for request_draft in coherent_request_drafts:
            substituted_request = replace(
                request_draft,
                request_sha256=(
                    tree.metal_matvec_dispatch_request_root_v1(
                        request_draft
                    )
                ),
            )
            tree.validate_metal_matvec_dispatch_request_v1(
                substituted_request
            )
            rejection_draft = replace(
                campaign.rejection,
                request=substituted_request,
                rejection_sha256=tree.ZERO_DIGEST,
            )
            substituted_rejection = replace(
                rejection_draft,
                rejection_sha256=(
                    tree.metal_matvec_pre_submit_rejection_root_v1(
                        rejection_draft
                    )
                ),
            )
            tree.validate_metal_matvec_pre_submit_rejection_v1(
                substituted_rejection
            )
            with self.subTest(
                coherent_request_substitution=substituted_request
            ):
                with self.assertRaises(tree.ContractError):
                    tree.validate_metal_matvec_pre_submit_rejection_for_pin_v1(
                        substituted_rejection,
                        campaign.pin,
                        campaign.terminal,
                    )

    def test_metal_pre_submit_rejection_rejects_coherent_tamper(
        self,
    ) -> None:
        campaign = (
            tree.make_metal_matvec_pre_submit_rejection_campaign()
        )
        rejection = campaign.rejection
        foreign = allocation.digest_v1(
            b"Metal rejection evidence substitution"
        )
        drafts = (
            replace(
                rejection,
                dispatch_generation=rejection.dispatch_generation + 1,
                rejection_sha256=tree.ZERO_DIGEST,
            ),
            replace(
                rejection,
                materialized_bytes=rejection.materialized_bytes + 1,
                rejection_sha256=tree.ZERO_DIGEST,
            ),
            replace(
                rejection,
                pin_sha256=foreign,
                rejection_sha256=tree.ZERO_DIGEST,
            ),
            replace(
                rejection,
                backend_object_set_sha256=foreign,
                rejection_sha256=tree.ZERO_DIGEST,
            ),
            replace(
                rejection,
                terminal_sha256=foreign,
                rejection_sha256=tree.ZERO_DIGEST,
            ),
        )
        for draft in drafts:
            candidate = replace(
                draft,
                rejection_sha256=(
                    tree.metal_matvec_pre_submit_rejection_root_v1(
                        draft
                    )
                ),
            )
            with self.subTest(metal_rejection_field=draft):
                tree.validate_metal_matvec_pre_submit_rejection_v1(
                    candidate
                )
                with self.assertRaises(tree.ContractError):
                    tree.validate_metal_matvec_pre_submit_rejection_for_pin_v1(
                        candidate,
                        campaign.pin,
                        campaign.terminal,
                    )

        invalid_count_draft = replace(
            rejection,
            allocation_count=3,
            rejection_sha256=tree.ZERO_DIGEST,
        )
        invalid_count = replace(
            invalid_count_draft,
            rejection_sha256=(
                tree.metal_matvec_pre_submit_rejection_root_v1(
                    invalid_count_draft
                )
            ),
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_metal_matvec_pre_submit_rejection_v1(
                invalid_count
            )

        invalid_reason_draft = replace(
            rejection,
            reason=tree.METAL_INVALID_GEOMETRY,
            rejection_sha256=tree.ZERO_DIGEST,
        )
        invalid_reason = replace(
            invalid_reason_draft,
            rejection_sha256=(
                tree.metal_matvec_pre_submit_rejection_root_v1(
                    invalid_reason_draft
                )
            ),
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_metal_matvec_pre_submit_rejection_v1(
                invalid_reason
            )
        with self.assertRaises(tree.ContractError):
            tree.metal_matvec_pre_submit_rejection_root_v1(
                replace(
                    rejection,
                    materialized_bytes=tree.U64_MAX + 1,
                )
            )

        cancelled_terminal = tree.make_dispatch_terminal_v1(
            campaign.pin,
            tree.DISPATCH_CANCELLED_BEFORE_SUBMIT,
            tree.ZERO_DIGEST,
            tree.ZERO_DIGEST,
            tree.ZERO_DIGEST,
        )
        terminal_draft = replace(
            rejection,
            terminal_sha256=cancelled_terminal.terminal_sha256,
            rejection_sha256=tree.ZERO_DIGEST,
        )
        terminal_substitution = replace(
            terminal_draft,
            rejection_sha256=(
                tree.metal_matvec_pre_submit_rejection_root_v1(
                    terminal_draft
                )
            ),
        )
        tree.validate_metal_matvec_pre_submit_rejection_v1(
            terminal_substitution
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_metal_matvec_pre_submit_rejection_for_pin_v1(
                terminal_substitution,
                campaign.pin,
                cancelled_terminal,
            )

    def test_dispatch_campaign_validates_and_preserves_legacy_roots(
        self,
    ) -> None:
        campaign = self.dispatch
        self.assertEqual(
            self.campaign,
            campaign.allocation_campaign,
        )
        tree.validate_lease_pin_slot(
            campaign.permit.parent,
            campaign.permit.pin_slot_index,
            campaign.pin_slot,
        )
        tree.validate_lease_pin_slot_for_permit_v1(
            campaign.pin_slot,
            campaign.permit,
        )
        tree.validate_lease_pin_permit(campaign.permit)
        tree.validate_dispatch_pin_v1(campaign.pin)
        tree.validate_dispatch_pin_for_lease_v1(
            campaign.pin,
            campaign.allocation_campaign.admission_2,
            campaign.allocation_campaign.lease_2,
            campaign.permit,
        )
        tree.validate_dispatch_terminal_for_pin_v1(
            campaign.terminal,
            campaign.pin,
        )
        tree.validate_lease_pin_completion(
            campaign.bank_completion
        )
        tree.validate_dispatch_completion_for_bank_v1(
            campaign.completion,
            campaign.pin,
            campaign.terminal,
            campaign.permit,
            campaign.bank_completion,
        )
        self.assertNotEqual(
            campaign.allocation_campaign.materialized_tree_2.state_digest,
            campaign.pinned_tree.state_digest,
        )
        self.assertNotEqual(
            campaign.permit.node_set_digest,
            tree.lease_pin_node_set_digest_v1(
                campaign.pinned_tree.tree_key,
                campaign.pinned_tree.identity_generation,
                campaign.pin.scope.node_index,
                campaign.pin.scope.generation,
                tuple(reversed(campaign.members)),
            ),
        )

    def test_dispatch_unsealed_field_tampers_fail_closed(self) -> None:
        campaign = self.dispatch
        parent = campaign.permit.parent
        self.assertIsNotNone(parent)
        assert parent is not None

        slot_tampers = {
            name: value
            for name, value in (
                ("active", False),
                (
                    "receipt_slot_index",
                    campaign.pin_slot.receipt_slot_index + 1,
                ),
                ("tree_key", campaign.pin_slot.tree_key + 1),
                (
                    "tree_identity_generation",
                    campaign.pin_slot.tree_identity_generation + 1,
                ),
                (
                    "tree_generation",
                    campaign.pin_slot.tree_generation + 1,
                ),
                (
                    "structural_revision",
                    campaign.pin_slot.structural_revision + 1,
                ),
                ("generation", campaign.pin_slot.generation + 1),
                (
                    "completion_generation",
                    campaign.pin_slot.completion_generation + 1,
                ),
                (
                    "request_epoch",
                    campaign.pin_slot.request_epoch + 1,
                ),
                ("session_id", campaign.pin_slot.session_id + 1),
                ("sequence", campaign.pin_slot.sequence + 1),
                ("owner_key", campaign.pin_slot.owner_key + 1),
                ("scope_index", campaign.pin_slot.scope_index + 1),
                (
                    "scope_generation",
                    campaign.pin_slot.scope_generation + 1,
                ),
                ("node_count", campaign.pin_slot.node_count + 1),
                (
                    "claim",
                    replace(
                        campaign.pin_slot.claim,
                        device_bytes=(
                            campaign.pin_slot.claim.device_bytes + 1
                        ),
                    ),
                ),
                (
                    "node_set_digest",
                    campaign.pin_slot.node_set_digest ^ 1,
                ),
                ("integrity", campaign.pin_slot.integrity ^ 1),
                ("members", tuple(reversed(campaign.members))),
            )
        }
        self.assertEqual(
            set(campaign.pin_slot.__dataclass_fields__),
            set(slot_tampers),
        )
        for field, value in slot_tampers.items():
            with self.subTest(pin_slot_field=field):
                candidate = replace(
                    campaign.pin_slot,
                    **{field: value},
                )
                with self.assertRaises(tree.ContractError):
                    tree.validate_lease_pin_slot(
                        parent,
                        campaign.permit.pin_slot_index,
                        candidate,
                    )
        member = campaign.members[0]
        member_tampers = {
            "node_index": member.node_index + 1,
            "reserved": member.reserved + 1,
            "node_generation": member.node_generation + 1,
            "node_integrity": member.node_integrity ^ 1,
        }
        self.assertEqual(
            set(member.__dataclass_fields__),
            set(member_tampers),
        )
        for field, value in member_tampers.items():
            with self.subTest(pin_member_field=field):
                candidate_member = replace(
                    member,
                    **{field: value},
                )
                candidate = replace(
                    campaign.pin_slot,
                    members=(
                        candidate_member,
                        *campaign.members[1:],
                    ),
                )
                with self.assertRaises(tree.ContractError):
                    tree.validate_lease_pin_slot(
                        parent,
                        campaign.permit.pin_slot_index,
                        candidate,
                    )

        permit_tampers = {
            "abi_version": campaign.permit.abi_version + 1,
            "parent": replace(parent, integrity=parent.integrity ^ 1),
            "tree_key": campaign.permit.tree_key + 1,
            "tree_identity_generation": (
                campaign.permit.tree_identity_generation + 1
            ),
            "tree_generation": campaign.permit.tree_generation + 1,
            "structural_revision": (
                campaign.permit.structural_revision + 1
            ),
            "pin_slot_index": campaign.permit.pin_slot_index + 1,
            "reserved": campaign.permit.reserved + 1,
            "generation": campaign.permit.generation + 1,
            "completion_generation": (
                campaign.permit.completion_generation + 1
            ),
            "request_epoch": campaign.permit.request_epoch + 1,
            "session_id": campaign.permit.session_id + 1,
            "sequence": campaign.permit.sequence + 1,
            "owner_key": campaign.permit.owner_key + 1,
            "scope_index": campaign.permit.scope_index + 1,
            "scope_generation": (
                campaign.permit.scope_generation + 1
            ),
            "node_count": campaign.permit.node_count + 1,
            "claim": replace(
                campaign.permit.claim,
                device_bytes=campaign.permit.claim.device_bytes + 1,
            ),
            "node_set_digest": campaign.permit.node_set_digest ^ 1,
            "integrity": campaign.permit.integrity ^ 1,
        }
        self.assertEqual(
            set(campaign.permit.__dataclass_fields__),
            set(permit_tampers),
        )
        for field, value in permit_tampers.items():
            with self.subTest(permit_field=field):
                with self.assertRaises(tree.ContractError):
                    tree.validate_lease_pin_permit(
                        replace(
                            campaign.permit,
                            **{field: value},
                        )
                    )

        bank_completion_tampers = {
            "abi_version": campaign.bank_completion.abi_version + 1,
            "parent": replace(parent, integrity=parent.integrity ^ 1),
            "tree_key": campaign.bank_completion.tree_key + 1,
            "tree_identity_generation": (
                campaign.bank_completion.tree_identity_generation + 1
            ),
            "pin_slot_index": (
                campaign.bank_completion.pin_slot_index + 1
            ),
            "reserved": campaign.bank_completion.reserved + 1,
            "permit_generation": (
                campaign.bank_completion.permit_generation + 1
            ),
            "completion_generation": (
                campaign.bank_completion.completion_generation + 1
            ),
            "request_epoch": (
                campaign.bank_completion.request_epoch + 1
            ),
            "session_id": campaign.bank_completion.session_id + 1,
            "sequence": campaign.bank_completion.sequence + 1,
            "owner_key": campaign.bank_completion.owner_key + 1,
            "scope_index": campaign.bank_completion.scope_index + 1,
            "scope_generation": (
                campaign.bank_completion.scope_generation + 1
            ),
            "node_count": campaign.bank_completion.node_count + 1,
            "claim": replace(
                campaign.bank_completion.claim,
                device_bytes=(
                    campaign.bank_completion.claim.device_bytes + 1
                ),
            ),
            "node_set_digest": (
                campaign.bank_completion.node_set_digest ^ 1
            ),
            "permit_integrity": (
                campaign.bank_completion.permit_integrity ^ 1
            ),
            "completion_tree_generation": (
                campaign.bank_completion.completion_tree_generation
                + 1
            ),
            "completion_structural_revision": (
                campaign.bank_completion
                .completion_structural_revision
                + 1
            ),
            "completion_state_digest": (
                campaign.bank_completion.completion_state_digest ^ 1
            ),
            "completion_tree_integrity": (
                campaign.bank_completion.completion_tree_integrity ^ 1
            ),
            "integrity": campaign.bank_completion.integrity ^ 1,
        }
        self.assertEqual(
            set(campaign.bank_completion.__dataclass_fields__),
            set(bank_completion_tampers),
        )
        for field, value in bank_completion_tampers.items():
            with self.subTest(bank_completion_field=field):
                with self.assertRaises(tree.ContractError):
                    tree.validate_lease_pin_completion(
                        replace(
                            campaign.bank_completion,
                            **{field: value},
                        )
                    )

        foreign = allocation.digest_v1(b"dispatch field tamper")
        pin_tampers = {
            "abi_version": campaign.pin.abi_version + 1,
            "coordinator_epoch": campaign.pin.coordinator_epoch + 1,
            "allocation_generation": (
                campaign.pin.allocation_generation + 1
            ),
            "dispatch_generation": (
                campaign.pin.dispatch_generation + 1
            ),
            **{
                field: foreign
                for field in (
                    "authority_sha256",
                    "dispatch_authority_sha256",
                    "queue_authority_sha256",
                    "request_sha256",
                    "admission_sha256",
                    "lease_sha256",
                    "parent_receipt_sha256",
                    "allocation_leaf_set_sha256",
                    "backend_object_set_sha256",
                    "dispatch_request_sha256",
                    "publication_binding_sha256",
                    "bank_pin_sha256",
                    "pin_sha256",
                )
            },
            "pinned_tree": replace(
                campaign.pinned_tree,
                generation=campaign.pinned_tree.generation + 1,
            ),
            "scope": replace(
                campaign.pin.scope,
                generation=campaign.pin.scope.generation + 1,
            ),
            "allocation_count": campaign.pin.allocation_count + 1,
            "pinned_device_bytes": (
                campaign.pin.pinned_device_bytes + 1
            ),
        }
        self.assertEqual(
            set(campaign.pin.__dataclass_fields__),
            set(pin_tampers),
        )
        for field, value in pin_tampers.items():
            with self.subTest(dispatch_pin_field=field):
                with self.assertRaises(tree.ContractError):
                    tree.validate_dispatch_pin_v1(
                        replace(campaign.pin, **{field: value})
                    )

        terminal_tampers = {
            "abi_version": campaign.terminal.abi_version + 1,
            "outcome": campaign.terminal.outcome + 1,
            "dispatch_generation": (
                campaign.terminal.dispatch_generation + 1
            ),
            **{
                field: foreign
                for field in (
                    "dispatch_authority_sha256",
                    "queue_authority_sha256",
                    "pin_sha256",
                    "dispatch_request_sha256",
                    "submission_sha256",
                    "backend_completion_sha256",
                    "output_sha256",
                    "terminal_sha256",
                )
            },
        }
        self.assertEqual(
            set(campaign.terminal.__dataclass_fields__),
            set(terminal_tampers),
        )
        for field, value in terminal_tampers.items():
            with self.subTest(dispatch_terminal_field=field):
                with self.assertRaises(tree.ContractError):
                    tree.validate_dispatch_terminal_v1(
                        replace(
                            campaign.terminal,
                            **{field: value},
                        )
                    )

        completion_tampers = {
            "abi_version": campaign.completion.abi_version + 1,
            "outcome": campaign.completion.outcome + 1,
            "coordinator_epoch": (
                campaign.completion.coordinator_epoch + 1
            ),
            "allocation_generation": (
                campaign.completion.allocation_generation + 1
            ),
            "dispatch_generation": (
                campaign.completion.dispatch_generation + 1
            ),
            **{
                field: foreign
                for field in (
                    "pin_sha256",
                    "dispatch_terminal_sha256",
                    "submission_sha256",
                    "backend_completion_sha256",
                    "output_sha256",
                    "bank_completion_sha256",
                    "completion_publication_binding_sha256",
                    "completion_sha256",
                )
            },
            "completed_tree": replace(
                campaign.completed_tree,
                generation=campaign.completed_tree.generation + 1,
            ),
            "scope": replace(
                campaign.completion.scope,
                generation=campaign.completion.scope.generation + 1,
            ),
        }
        self.assertEqual(
            set(campaign.completion.__dataclass_fields__),
            set(completion_tampers),
        )
        for field, value in completion_tampers.items():
            with self.subTest(dispatch_completion_field=field):
                with self.assertRaises(tree.ContractError):
                    tree.validate_dispatch_completion_v1(
                        replace(
                            campaign.completion,
                            **{field: value},
                        )
                    )

    def test_dispatch_resealed_substitutions_fail_composition(
        self,
    ) -> None:
        campaign = self.dispatch
        allocation_campaign = campaign.allocation_campaign
        foreign = allocation.digest_v1(
            b"resealed dispatch substitution"
        )

        def reseal_pin(**changes):
            draft = replace(
                campaign.pin,
                **changes,
                pin_sha256=tree.ZERO_DIGEST,
            )
            return replace(
                draft,
                pin_sha256=tree.dispatch_pin_root_v1(draft),
            )

        pin_substitutions = (
            reseal_pin(admission_sha256=foreign),
            reseal_pin(dispatch_request_sha256=foreign),
            reseal_pin(bank_pin_sha256=foreign),
            reseal_pin(allocation_count=2),
        )
        foreign_pinned_tree = tree.seal_lease_tree(
            replace(
                campaign.pinned_tree,
                authority_key=(
                    campaign.pinned_tree.authority_key + 1
                ),
                integrity=0,
            )
        )
        pin_substitutions += (
            reseal_pin(pinned_tree=foreign_pinned_tree),
        )
        short_scope = tree.seal_lease_node(
            replace(
                campaign.pin.scope,
                ceiling=tree.ClaimV1(device_bytes=8_191),
                integrity=0,
            )
        )
        pin_substitutions += (
            reseal_pin(
                scope=short_scope,
                pinned_device_bytes=8_191,
            ),
        )
        for candidate in pin_substitutions:
            tree.validate_dispatch_pin_v1(candidate)
            with self.assertRaises(tree.ContractError):
                tree.validate_dispatch_pin_for_lease_v1(
                    candidate,
                    allocation_campaign.admission_2,
                    allocation_campaign.lease_2,
                    campaign.permit,
                )

        foreign_permit = tree.seal_lease_pin_permit(
            replace(
                campaign.permit,
                owner_key=campaign.permit.owner_key + 1,
                integrity=0,
            )
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_dispatch_pin_for_lease_v1(
                campaign.pin,
                allocation_campaign.admission_2,
                allocation_campaign.lease_2,
                foreign_permit,
            )

        foreign_terminal_draft = replace(
            campaign.terminal,
            pin_sha256=foreign,
            terminal_sha256=tree.ZERO_DIGEST,
        )
        foreign_terminal = replace(
            foreign_terminal_draft,
            terminal_sha256=tree.dispatch_terminal_root_v1(
                foreign_terminal_draft
            ),
        )
        tree.validate_dispatch_terminal_v1(foreign_terminal)
        with self.assertRaises(tree.ContractError):
            tree.validate_dispatch_terminal_for_pin_v1(
                foreign_terminal,
                campaign.pin,
            )

        def reseal_completion(**changes):
            draft = replace(
                campaign.completion,
                **changes,
                completion_sha256=tree.ZERO_DIGEST,
            )
            return replace(
                draft,
                completion_sha256=(
                    tree.dispatch_completion_root_v1(draft)
                ),
            )

        foreign_terminal_completion = reseal_completion(
            dispatch_terminal_sha256=foreign
        )
        tree.validate_dispatch_completion_v1(
            foreign_terminal_completion
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_dispatch_completion_for_pin_v1(
                foreign_terminal_completion,
                campaign.pin,
                campaign.terminal,
            )

        foreign_bank_completion = reseal_completion(
            bank_completion_sha256=foreign
        )
        tree.validate_dispatch_completion_for_pin_v1(
            foreign_bank_completion,
            campaign.pin,
            campaign.terminal,
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_dispatch_completion_for_bank_v1(
                foreign_bank_completion,
                campaign.pin,
                campaign.terminal,
                campaign.permit,
                campaign.bank_completion,
            )

        foreign_completed_tree = tree.seal_lease_tree(
            replace(
                campaign.completed_tree,
                authority_key=(
                    campaign.completed_tree.authority_key + 1
                ),
                integrity=0,
            )
        )
        foreign_tree_completion = reseal_completion(
            completed_tree=foreign_completed_tree
        )
        tree.validate_dispatch_completion_v1(
            foreign_tree_completion
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_dispatch_completion_for_pin_v1(
                foreign_tree_completion,
                campaign.pin,
                campaign.terminal,
            )

        public_completion_tampers = (
            reseal_completion(
                completion_publication_binding_sha256=foreign
            ),
            reseal_completion(
                completed_tree=tree.seal_lease_tree(
                    replace(
                        campaign.completed_tree,
                        ceiling=tree.ClaimV1(
                            capsule_bytes=1,
                            device_bytes=8_192,
                        ),
                        integrity=0,
                    )
                )
            ),
            reseal_completion(
                completed_tree=tree.seal_lease_tree(
                    replace(
                        campaign.completed_tree,
                        generation=campaign.pinned_tree.generation,
                        integrity=0,
                    )
                )
            ),
            reseal_completion(
                completed_tree=tree.seal_lease_tree(
                    replace(
                        campaign.completed_tree,
                        structural_revision=(
                            campaign.pinned_tree
                            .structural_revision
                        ),
                        integrity=0,
                    )
                )
            ),
            reseal_completion(
                completed_tree=tree.seal_lease_tree(
                    replace(
                        campaign.completed_tree,
                        active_nodes=campaign.pin.allocation_count,
                        integrity=0,
                    )
                )
            ),
        )
        for candidate in public_completion_tampers:
            tree.validate_dispatch_completion_v1(candidate)
            with self.assertRaises(tree.ContractError):
                tree.validate_dispatch_completion_for_pin_v1(
                    candidate,
                    campaign.pin,
                    campaign.terminal,
                )

        mismatched_outcome = reseal_completion(
            outcome=tree.DISPATCH_TERMINAL_FAILURE,
            output_sha256=tree.ZERO_DIGEST,
        )
        tree.validate_dispatch_completion_v1(mismatched_outcome)
        with self.assertRaises(tree.ContractError):
            tree.validate_dispatch_completion_for_pin_v1(
                mismatched_outcome,
                campaign.pin,
                campaign.terminal,
            )

        foreign_evidence = tree.seal_lease_pin_completion(
            replace(
                campaign.bank_completion,
                owner_key=campaign.bank_completion.owner_key + 1,
                integrity=0,
            )
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_dispatch_completion_for_bank_v1(
                campaign.completion,
                campaign.pin,
                campaign.terminal,
                campaign.permit,
                foreign_evidence,
            )

    def test_resealed_pin_generation_constraints_fail_closed(
        self,
    ) -> None:
        campaign = self.dispatch
        permit_tampers = (
            {
                "tree_generation": (
                    campaign.permit.tree_generation + 1
                ),
            },
            {
                "completion_generation": (
                    campaign.permit.completion_generation + 1
                ),
            },
            {
                "generation": tree.U64_MAX - 1,
                "tree_generation": tree.U64_MAX,
                "completion_generation": tree.U64_MAX,
            },
        )
        for changes in permit_tampers:
            with self.subTest(permit_generation_tamper=changes):
                with self.assertRaises(tree.ContractError):
                    tree.seal_lease_pin_permit(
                        replace(
                            campaign.permit,
                            **changes,
                            integrity=0,
                        )
                    )

        completion_tampers = (
            {
                "completion_generation": (
                    campaign.bank_completion
                    .completion_generation
                    + 1
                ),
            },
            {
                "completion_tree_generation": (
                    campaign.bank_completion
                    .completion_generation
                ),
            },
            {
                "permit_generation": tree.U64_MAX - 1,
                "completion_generation": tree.U64_MAX,
                "completion_tree_generation": tree.U64_MAX,
            },
        )
        for changes in completion_tampers:
            with self.subTest(completion_generation_tamper=changes):
                with self.assertRaises(tree.ContractError):
                    tree.seal_lease_pin_completion(
                        replace(
                            campaign.bank_completion,
                            **changes,
                            integrity=0,
                        )
                    )

    def test_dispatch_completion_allows_sibling_state_changes(
        self,
    ) -> None:
        campaign = self.dispatch
        wide_ceiling = tree.ClaimV1(
            capsule_bytes=128,
            device_bytes=8_192,
        )
        wide_pinned_tree = tree.seal_lease_tree(
            replace(
                campaign.pinned_tree,
                ceiling=wide_ceiling,
                integrity=0,
            )
        )
        wide_pin_draft = replace(
            campaign.pin,
            pinned_tree=wide_pinned_tree,
            pin_sha256=tree.ZERO_DIGEST,
        )
        wide_pin = replace(
            wide_pin_draft,
            pin_sha256=tree.dispatch_pin_root_v1(
                wide_pin_draft
            ),
        )
        tree.validate_dispatch_pin_v1(wide_pin)
        terminal = tree.make_dispatch_terminal_v1(
            wide_pin,
            tree.DISPATCH_SUCCEEDED,
            campaign.submission_sha256,
            campaign.backend_completion_sha256,
            campaign.output_sha256,
        )
        sibling_tree = tree.seal_lease_tree(
            replace(
                campaign.completed_tree,
                ceiling=wide_ceiling,
                current=tree.ClaimV1(
                    capsule_bytes=64,
                    device_bytes=8_192,
                ),
                active_nodes=campaign.completed_tree.active_nodes + 1,
                state_digest=(
                    campaign.completed_tree.state_digest ^ 0x5151
                ),
                integrity=0,
            )
        )
        sibling_bank_completion = tree.seal_lease_pin_completion(
            replace(
                campaign.bank_completion,
                completion_state_digest=sibling_tree.state_digest,
                completion_tree_integrity=sibling_tree.integrity,
                integrity=0,
            )
        )
        completion = tree.make_dispatch_completion_v1(
            wide_pin,
            terminal,
            sibling_tree,
            campaign.permit,
            sibling_bank_completion,
        )
        tree.validate_dispatch_completion_for_bank_v1(
            completion,
            wide_pin,
            terminal,
            campaign.permit,
            sibling_bank_completion,
        )
        self.assertNotEqual(
            wide_pin.pinned_tree.current,
            completion.completed_tree.current,
        )
        self.assertNotEqual(
            wide_pin.pinned_tree.active_nodes,
            completion.completed_tree.active_nodes,
        )

    def test_overlapping_pins_complete_in_reverse_order(self) -> None:
        base = self.dispatch.allocation_campaign
        parent = allocation.seal_resource_receipt(
            bank_epoch=43,
            slot_index=1,
            generation=1,
            owner_key=9_002,
            claim=tree.ClaimV1(
                capsule_bytes=64,
                queue_slots=2,
            ),
        )
        scope = tree.seal_lease_node(
            replace(
                base.scope,
                parent=parent,
                integrity=0,
            )
        )
        leaves = tuple(
            tree.seal_lease_node(
                replace(
                    leaf,
                    parent=parent,
                    integrity=0,
                )
            )
            for leaf in base.leaves_2
        )
        claim = tree.ClaimV1(device_bytes=8_192)
        members = tuple(
            tree.LeasePinMemberV1(
                node_index=leaf.node_index,
                node_generation=leaf.generation,
                node_integrity=leaf.integrity,
            )
            for leaf in leaves
        )
        node_set_digest = tree.lease_pin_node_set_digest_v1(
            base.materialized_tree_2.tree_key,
            base.materialized_tree_2.identity_generation,
            scope.node_index,
            scope.generation,
            members,
        )
        coordinator_epoch = base.coordinator_epoch
        allocation_generation = base.lease_2.generation
        request_epoch = base.allocation_fixture.request.request_epoch
        session_id = base.session_id
        sequence = base.publication_sequence
        dispatch_authority = allocation.digest_v1(
            b"overlap dispatch authority"
        )
        queue_authority = allocation.digest_v1(
            b"overlap queue authority"
        )

        def runtimes(pin_count):
            return (
                tree._RuntimeNode(
                    node=scope,
                    state=tree.NODE_STATE_LIVE,
                    pending_generation=0,
                    subtree_claim=claim,
                ),
            ) + tuple(
                tree._RuntimeNode(
                    node=leaf,
                    state=tree.NODE_STATE_LIVE,
                    pending_generation=0,
                    subtree_claim=leaf.claim,
                    pin_count=pin_count,
                )
                for leaf in leaves
            )

        def make_slot(
            pin_slot_index,
            permit_generation,
            tree_generation,
            structural_revision,
            completion_generation,
            owner_key,
        ):
            return tree.seal_lease_pin_slot(
                parent,
                pin_slot_index,
                tree.LeasePinSlotV1(
                    active=True,
                    receipt_slot_index=parent.slot_index,
                    tree_key=base.materialized_tree_2.tree_key,
                    tree_identity_generation=(
                        base.materialized_tree_2
                        .identity_generation
                    ),
                    tree_generation=tree_generation,
                    structural_revision=structural_revision,
                    generation=permit_generation,
                    completion_generation=completion_generation,
                    request_epoch=request_epoch,
                    session_id=session_id,
                    sequence=sequence,
                    owner_key=owner_key,
                    scope_index=scope.node_index,
                    scope_generation=scope.generation,
                    node_count=len(members),
                    claim=claim,
                    node_set_digest=node_set_digest,
                    members=members,
                ),
            )

        def make_permit(slot_index, slot):
            return tree.seal_lease_pin_permit(
                tree.LeasePinPermitV1(
                    parent=parent,
                    tree_key=slot.tree_key,
                    tree_identity_generation=(
                        slot.tree_identity_generation
                    ),
                    tree_generation=slot.tree_generation,
                    structural_revision=slot.structural_revision,
                    pin_slot_index=slot_index,
                    generation=slot.generation,
                    completion_generation=(
                        slot.completion_generation
                    ),
                    request_epoch=slot.request_epoch,
                    session_id=slot.session_id,
                    sequence=slot.sequence,
                    owner_key=slot.owner_key,
                    scope_index=slot.scope_index,
                    scope_generation=slot.scope_generation,
                    node_count=slot.node_count,
                    claim=slot.claim,
                    node_set_digest=slot.node_set_digest,
                )
            )

        fixed_roots = {
            name: allocation.digest_v1(
                ("overlap " + name).encode()
            )
            for name in (
                "authority",
                "request",
                "admission",
                "lease",
                "backend object set",
            )
        }
        leaf_set = tree.allocation_leaf_set_sha256_v1(leaves)
        parent_root = allocation.resource_receipt_root(parent)

        def make_public_pin(
            dispatch_generation,
            dispatch_request,
            pinned_tree,
            permit,
        ):
            draft = tree.LeaseTreeDispatchPinV1(
                coordinator_epoch=coordinator_epoch,
                allocation_generation=allocation_generation,
                dispatch_generation=dispatch_generation,
                authority_sha256=fixed_roots["authority"],
                dispatch_authority_sha256=dispatch_authority,
                queue_authority_sha256=queue_authority,
                request_sha256=fixed_roots["request"],
                admission_sha256=fixed_roots["admission"],
                lease_sha256=fixed_roots["lease"],
                parent_receipt_sha256=parent_root,
                allocation_leaf_set_sha256=leaf_set,
                backend_object_set_sha256=(
                    fixed_roots["backend object set"]
                ),
                dispatch_request_sha256=dispatch_request,
                publication_binding_sha256=(
                    tree.dispatch_publication_binding_sha256_v1(
                        parent,
                        request_epoch,
                        session_id,
                        sequence,
                    )
                ),
                bank_pin_sha256=(
                    tree.lease_pin_permit_sha256_v1(permit)
                ),
                pinned_tree=pinned_tree,
                scope=scope,
                allocation_count=len(leaves),
                pinned_device_bytes=claim.device_bytes,
            )
            result = replace(
                draft,
                pin_sha256=tree.dispatch_pin_root_v1(draft),
            )
            tree.validate_dispatch_pin_v1(result)
            return result

        request_a = allocation.digest_v1(b"overlap request a")
        owner_a = tree.dispatch_owner_key_v1(
            coordinator_epoch,
            allocation_generation,
            1,
            request_a,
        )
        slot_a = make_slot(0, 17, 18, 7, 19, owner_a)
        pinned_tree_a = tree._make_tree_state(
            parent,
            base.materialized_tree_2.tree_key,
            base.materialized_tree_2.authority_key,
            base.materialized_tree_2.identity_generation,
            18,
            7,
            claim,
            claim,
            tree.PENDING_NONE,
            0,
            0,
            0,
            0,
            tree.NO_LEASE_NODE,
            0,
            tree.ClaimV1(),
            0,
            runtimes(1),
            ((0, slot_a),),
        )
        permit_a = make_permit(0, slot_a)
        pin_a = make_public_pin(
            1,
            request_a,
            pinned_tree_a,
            permit_a,
        )

        request_b = allocation.digest_v1(b"overlap request b")
        owner_b = tree.dispatch_owner_key_v1(
            coordinator_epoch,
            allocation_generation,
            2,
            request_b,
        )
        slot_b = make_slot(1, 20, 21, 8, 22, owner_b)
        pinned_tree_b = tree._make_tree_state(
            parent,
            base.materialized_tree_2.tree_key,
            base.materialized_tree_2.authority_key,
            base.materialized_tree_2.identity_generation,
            21,
            8,
            claim,
            claim,
            tree.PENDING_NONE,
            0,
            0,
            0,
            0,
            tree.NO_LEASE_NODE,
            0,
            tree.ClaimV1(),
            0,
            runtimes(2),
            ((0, slot_a), (1, slot_b)),
        )
        permit_b = make_permit(1, slot_b)
        pin_b = make_public_pin(
            2,
            request_b,
            pinned_tree_b,
            permit_b,
        )

        after_b_tree = tree._make_tree_state(
            parent,
            base.materialized_tree_2.tree_key,
            base.materialized_tree_2.authority_key,
            base.materialized_tree_2.identity_generation,
            23,
            9,
            claim,
            claim,
            tree.PENDING_NONE,
            0,
            0,
            0,
            0,
            tree.NO_LEASE_NODE,
            0,
            tree.ClaimV1(),
            0,
            runtimes(1),
            ((0, slot_a),),
        )

        def make_bank_completion(permit, completed_tree):
            return tree.seal_lease_pin_completion(
                tree.LeasePinCompletionV1(
                    parent=parent,
                    tree_key=permit.tree_key,
                    tree_identity_generation=(
                        permit.tree_identity_generation
                    ),
                    pin_slot_index=permit.pin_slot_index,
                    permit_generation=permit.generation,
                    completion_generation=(
                        permit.completion_generation
                    ),
                    request_epoch=permit.request_epoch,
                    session_id=permit.session_id,
                    sequence=permit.sequence,
                    owner_key=permit.owner_key,
                    scope_index=permit.scope_index,
                    scope_generation=permit.scope_generation,
                    node_count=permit.node_count,
                    claim=permit.claim,
                    node_set_digest=permit.node_set_digest,
                    permit_integrity=permit.integrity,
                    completion_tree_generation=(
                        completed_tree.generation
                    ),
                    completion_structural_revision=(
                        completed_tree.structural_revision
                    ),
                    completion_state_digest=(
                        completed_tree.state_digest
                    ),
                    completion_tree_integrity=(
                        completed_tree.integrity
                    ),
                )
            )

        terminal_b = tree.make_dispatch_terminal_v1(
            pin_b,
            tree.DISPATCH_SUCCEEDED,
            allocation.digest_v1(b"overlap submit b"),
            allocation.digest_v1(b"overlap complete b"),
            allocation.digest_v1(b"overlap output b"),
        )
        bank_completion_b = make_bank_completion(
            permit_b,
            after_b_tree,
        )
        completion_b = tree.make_dispatch_completion_v1(
            pin_b,
            terminal_b,
            after_b_tree,
            permit_b,
            bank_completion_b,
        )

        after_a_tree = tree._make_tree_state(
            parent,
            base.materialized_tree_2.tree_key,
            base.materialized_tree_2.authority_key,
            base.materialized_tree_2.identity_generation,
            24,
            10,
            claim,
            claim,
            tree.PENDING_NONE,
            0,
            0,
            0,
            0,
            tree.NO_LEASE_NODE,
            0,
            tree.ClaimV1(),
            0,
            runtimes(0),
        )
        terminal_a = tree.make_dispatch_terminal_v1(
            pin_a,
            tree.DISPATCH_SUCCEEDED,
            allocation.digest_v1(b"overlap submit a"),
            allocation.digest_v1(b"overlap complete a"),
            allocation.digest_v1(b"overlap output a"),
        )
        bank_completion_a = make_bank_completion(
            permit_a,
            after_a_tree,
        )
        completion_a = tree.make_dispatch_completion_v1(
            pin_a,
            terminal_a,
            after_a_tree,
            permit_a,
            bank_completion_a,
        )
        tree.validate_dispatch_completion_for_bank_v1(
            completion_b,
            pin_b,
            terminal_b,
            permit_b,
            bank_completion_b,
        )
        tree.validate_dispatch_completion_for_bank_v1(
            completion_a,
            pin_a,
            terminal_a,
            permit_a,
            bank_completion_a,
        )

        rejected_terminal_b = (
            tree.make_rejected_before_submit_terminal_v1(pin_b)
        )
        rejected_completion_b = tree.make_dispatch_completion_v1(
            pin_b,
            rejected_terminal_b,
            after_b_tree,
            permit_b,
            bank_completion_b,
        )
        rejected_terminal_a = (
            tree.make_rejected_before_submit_terminal_v1(pin_a)
        )
        rejected_completion_a = tree.make_dispatch_completion_v1(
            pin_a,
            rejected_terminal_a,
            after_a_tree,
            permit_a,
            bank_completion_a,
        )
        tree.validate_dispatch_completion_for_bank_v1(
            rejected_completion_b,
            pin_b,
            rejected_terminal_b,
            permit_b,
            bank_completion_b,
        )
        tree.validate_dispatch_completion_for_bank_v1(
            rejected_completion_a,
            pin_a,
            rejected_terminal_a,
            permit_a,
            bank_completion_a,
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_dispatch_completion_for_bank_v1(
                rejected_completion_b,
                pin_b,
                rejected_terminal_b,
                permit_b,
                bank_completion_a,
            )
        with self.assertRaises(tree.ContractError):
            tree.validate_dispatch_completion_for_bank_v1(
                rejected_completion_a,
                pin_a,
                rejected_terminal_a,
                permit_a,
                bank_completion_b,
            )
        with self.assertRaises(tree.ContractError):
            tree.validate_dispatch_completion_for_bank_v1(
                rejected_completion_b,
                pin_a,
                rejected_terminal_a,
                permit_a,
                bank_completion_a,
            )
        self.assertEqual(2, parent.claim.queue_slots)
        self.assertGreater(
            completion_a.completed_tree.structural_revision,
            pin_a.pinned_tree.structural_revision + 1,
        )
        self.assertGreater(
            completion_a.completed_tree.generation,
            permit_a.completion_generation,
        )
        self.assertNotEqual(
            completion_b.completed_tree.state_digest,
            completion_a.completed_tree.state_digest,
        )

    def test_rejected_before_submit_requires_zero_native_roots(
        self,
    ) -> None:
        campaign = (
            tree.make_rejected_before_submit_dispatch_campaign()
        )
        nonzero = allocation.digest_v1(
            b"rejected dispatch native root substitution"
        )
        root_fields = (
            "submission_sha256",
            "backend_completion_sha256",
            "output_sha256",
        )
        for field in root_fields:
            with self.subTest(rejected_terminal_root=field):
                roots = {
                    candidate: tree.ZERO_DIGEST
                    for candidate in root_fields
                }
                roots[field] = nonzero
                with self.assertRaises(tree.ContractError):
                    tree.make_dispatch_terminal_v1(
                        campaign.pin,
                        tree.DISPATCH_REJECTED_BEFORE_SUBMIT,
                        roots["submission_sha256"],
                        roots["backend_completion_sha256"],
                        roots["output_sha256"],
                    )

                completion_draft = replace(
                    campaign.completion,
                    **{field: nonzero},
                    completion_sha256=tree.ZERO_DIGEST,
                )
                completion = replace(
                    completion_draft,
                    completion_sha256=(
                        tree.dispatch_completion_root_v1(
                            completion_draft
                        )
                    ),
                )
                with self.assertRaises(tree.ContractError):
                    tree.validate_dispatch_completion_v1(completion)

    def test_rejected_before_submit_semantic_binding_rejects_substitution(
        self,
    ) -> None:
        campaign = (
            tree.make_rejected_before_submit_dispatch_campaign()
        )
        cancelled = tree.make_dispatch_terminal_v1(
            campaign.pin,
            tree.DISPATCH_CANCELLED_BEFORE_SUBMIT,
            tree.ZERO_DIGEST,
            tree.ZERO_DIGEST,
            tree.ZERO_DIGEST,
        )
        tree.validate_dispatch_terminal_for_pin_v1(
            cancelled,
            campaign.pin,
        )
        with self.assertRaises(tree.ContractError):
            tree.validate_rejected_before_submit_terminal_for_pin_v1(
                cancelled,
                campaign.pin,
            )

        foreign = allocation.digest_v1(
            b"rejected dispatch terminal substitution"
        )
        terminal_substitutions = (
            {"dispatch_generation": campaign.pin.dispatch_generation + 1},
            {"dispatch_authority_sha256": foreign},
            {"queue_authority_sha256": foreign},
            {"pin_sha256": foreign},
            {"dispatch_request_sha256": foreign},
        )
        for changes in terminal_substitutions:
            with self.subTest(rejected_terminal_substitution=changes):
                draft = replace(
                    campaign.terminal,
                    **changes,
                    terminal_sha256=tree.ZERO_DIGEST,
                )
                candidate = replace(
                    draft,
                    terminal_sha256=(
                        tree.dispatch_terminal_root_v1(draft)
                    ),
                )
                tree.validate_dispatch_terminal_v1(candidate)
                with self.assertRaises(tree.ContractError):
                    tree.validate_rejected_before_submit_terminal_for_pin_v1(
                        candidate,
                        campaign.pin,
                    )

        foreign_pin_draft = replace(
            campaign.pin,
            dispatch_request_sha256=foreign,
            pin_sha256=tree.ZERO_DIGEST,
        )
        foreign_pin = replace(
            foreign_pin_draft,
            pin_sha256=tree.dispatch_pin_root_v1(
                foreign_pin_draft
            ),
        )
        tree.validate_dispatch_pin_v1(foreign_pin)
        with self.assertRaises(tree.ContractError):
            tree.validate_rejected_before_submit_terminal_for_pin_v1(
                campaign.terminal,
                foreign_pin,
            )

    def test_dispatch_outcome_root_pairs_cover_all_terminal_paths(
        self,
    ) -> None:
        campaign = self.dispatch
        nonzero = allocation.digest_v1(b"dispatch outcome nonzero")
        pairs = (
            (
                tree.DISPATCH_SUCCEEDED,
                nonzero,
                nonzero,
                nonzero,
            ),
            (
                tree.DISPATCH_TERMINAL_FAILURE,
                nonzero,
                nonzero,
                tree.ZERO_DIGEST,
            ),
            (
                tree.DISPATCH_CANCELLED_BEFORE_SUBMIT,
                tree.ZERO_DIGEST,
                tree.ZERO_DIGEST,
                tree.ZERO_DIGEST,
            ),
            (
                tree.DISPATCH_CANCELLED_AFTER_SUBMIT,
                nonzero,
                nonzero,
                tree.ZERO_DIGEST,
            ),
            (
                tree.DISPATCH_REJECTED_BEFORE_SUBMIT,
                tree.ZERO_DIGEST,
                tree.ZERO_DIGEST,
                tree.ZERO_DIGEST,
            ),
        )
        for outcome, submission, backend, output in pairs:
            with self.subTest(dispatch_outcome=outcome):
                outcome_campaign = tree.make_dispatch_campaign(
                    outcome
                )
                self.assertEqual(
                    outcome,
                    outcome_campaign.terminal.outcome,
                )
                self.assertEqual(
                    submission == tree.ZERO_DIGEST,
                    outcome_campaign.terminal.submission_sha256
                    == tree.ZERO_DIGEST,
                )
                self.assertEqual(
                    backend == tree.ZERO_DIGEST,
                    outcome_campaign.terminal.backend_completion_sha256
                    == tree.ZERO_DIGEST,
                )
                self.assertEqual(
                    output == tree.ZERO_DIGEST,
                    outcome_campaign.terminal.output_sha256
                    == tree.ZERO_DIGEST,
                )
                tree.validate_dispatch_completion_for_bank_v1(
                    outcome_campaign.completion,
                    outcome_campaign.pin,
                    outcome_campaign.terminal,
                    outcome_campaign.permit,
                    outcome_campaign.bank_completion,
                )
                terminal = tree.make_dispatch_terminal_v1(
                    campaign.pin,
                    outcome,
                    submission,
                    backend,
                    output,
                )
                completion = tree.make_dispatch_completion_v1(
                    campaign.pin,
                    terminal,
                    campaign.completed_tree,
                    campaign.permit,
                    campaign.bank_completion,
                )
                tree.validate_dispatch_completion_for_bank_v1(
                    completion,
                    campaign.pin,
                    terminal,
                    campaign.permit,
                    campaign.bank_completion,
                )

        invalid_pairs = (
            (
                tree.DISPATCH_SUCCEEDED,
                nonzero,
                nonzero,
                tree.ZERO_DIGEST,
            ),
            (
                tree.DISPATCH_TERMINAL_FAILURE,
                nonzero,
                nonzero,
                nonzero,
            ),
            (
                tree.DISPATCH_CANCELLED_BEFORE_SUBMIT,
                nonzero,
                tree.ZERO_DIGEST,
                tree.ZERO_DIGEST,
            ),
        )
        for outcome, submission, backend, output in invalid_pairs:
            with self.subTest(invalid_dispatch_outcome=outcome):
                with self.assertRaises(tree.ContractError):
                    tree.make_dispatch_terminal_v1(
                        campaign.pin,
                        outcome,
                        submission,
                        backend,
                        output,
                    )
        with self.assertRaises(tree.ContractError):
            tree.make_dispatch_campaign(0)


if __name__ == "__main__":
    unittest.main()
