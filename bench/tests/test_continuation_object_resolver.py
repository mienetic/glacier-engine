from __future__ import annotations

import unittest
from typing import Optional

from bench import continuation_capsule as capsule
from bench import continuation_object_resolver as object_resolver


class ContinuationObjectResolverTests(unittest.TestCase):
    def setUp(self) -> None:
        demo = object_resolver.build_demo()
        self.bundle = demo["bundle"]
        self.grant = demo["grant"]
        self.catalog = demo["catalog"]

    def resolver(
        self,
        *,
        grant: Optional[dict[str, object]] = None,
        catalog: Optional[list[dict[str, object]]] = None,
        authority_epoch: Optional[int] = None,
    ) -> object_resolver.Resolver:
        selected_grant = self.grant if grant is None else grant
        selected_catalog = self.catalog if catalog is None else catalog
        selected_epoch = (
            selected_grant["authority_epoch"]
            if authority_epoch is None
            else authority_epoch
        )
        assert isinstance(selected_epoch, int)
        return object_resolver.Resolver(
            selected_grant,
            selected_epoch,
            self.bundle["encoded"],
            selected_catalog,
        )

    def test_cross_language_grant_golden_and_full_resolution(self) -> None:
        self.assertEqual(
            object_resolver.grant_root(self.grant).hex(),
            "d3609c14ddc29235c74f5b1163fff3f4"
            "694dd9d0607d30610e5d87bbccc0d2d8",
        )
        resolver = self.resolver()
        for name in capsule.OBJECT_NAMES:
            self.assertEqual(
                resolver.resolve(name),
                self.bundle["objects"][name][1],
            )
        objects = resolver.finish_full()
        self.assertEqual(objects, self.bundle["objects"])
        self.assertEqual(
            resolver.resolved_bytes,
            self.grant["max_total_bytes"],
        )
        self.assertEqual(resolver.resolution_count, len(capsule.OBJECT_NAMES))
        with self.assertRaises(object_resolver.ResolverError):
            resolver.finish_full()

    def test_stale_denied_repeated_and_incomplete_authority_reject(self) -> None:
        with self.assertRaises(object_resolver.ResolverError):
            self.resolver(authority_epoch=self.grant["authority_epoch"] + 1)

        grant = dict(self.grant)
        grant["allowed_kind_mask"] = 1
        grant["max_resolutions"] = 1
        resolver = self.resolver(grant=grant)
        with self.assertRaises(object_resolver.ResolverError):
            resolver.resolve("tokenizer")
        resolver.resolve("model")
        with self.assertRaises(object_resolver.ResolverError):
            resolver.resolve("model")
        with self.assertRaises(object_resolver.ResolverError):
            resolver.finish_full()

    def test_tenant_corruption_and_ambiguity_reject_without_accounting(self) -> None:
        foreign = [dict(entry) for entry in self.catalog]
        for entry in foreign:
            entry["tenant_scope_sha256"] = bytes((0x91,)) * 32
        resolver = self.resolver(catalog=foreign)
        with self.assertRaises(object_resolver.ResolverError):
            resolver.resolve("model")
        self.assertEqual(resolver.resolved_bytes, 0)
        self.assertEqual(resolver.resolution_count, 0)

        corrupt = [dict(entry) for entry in self.catalog]
        corrupt[0]["payload"] = b"model-v1:sha256:demo-glru"
        resolver = self.resolver(catalog=corrupt)
        with self.assertRaises(object_resolver.ResolverError):
            resolver.resolve("model")
        self.assertEqual(resolver.resolved_bytes, 0)

        duplicate = [*self.catalog, dict(self.catalog[0])]
        resolver = self.resolver(catalog=duplicate)
        with self.assertRaises(object_resolver.ResolverError):
            resolver.resolve("model")

    def test_object_and_total_budget_reject_before_accounting(self) -> None:
        grant = dict(self.grant)
        grant["max_catalog_entries"] = len(self.catalog) - 1
        with self.assertRaises(object_resolver.ResolverError):
            self.resolver(grant=grant)

        grant = dict(self.grant)
        grant["max_object_bytes"] = 1
        resolver = self.resolver(grant=grant)
        with self.assertRaises(object_resolver.ResolverError):
            resolver.resolve("model")
        self.assertEqual(resolver.resolved_bytes, 0)

        grant = dict(self.grant)
        grant["max_total_bytes"] = len(self.bundle["objects"]["model"][1])
        resolver = self.resolver(grant=grant)
        resolver.resolve("model")
        before = (resolver.resolved_bytes, resolver.resolution_count)
        with self.assertRaises(object_resolver.ResolverError):
            resolver.resolve("tokenizer")
        self.assertEqual(
            (resolver.resolved_bytes, resolver.resolution_count),
            before,
        )

    def test_capsule_and_changed_resolved_object_reject(self) -> None:
        grant = dict(self.grant)
        grant["capsule_sha256"] = bytes((0x11,)) * 32
        with self.assertRaises(object_resolver.ResolverError):
            self.resolver(grant=grant)

        resolver = self.resolver()
        for name in capsule.OBJECT_NAMES:
            resolver.resolve(name)
        abi, payload = resolver.resolved["kv_state"]
        resolver.resolved["kv_state"] = (abi, payload[:-1] + b"x")
        with self.assertRaises(object_resolver.ResolverError):
            resolver.finish_full()
        self.assertTrue(resolver.finalized)


if __name__ == "__main__":
    unittest.main()
