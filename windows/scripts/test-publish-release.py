import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("publish", Path(__file__).with_name("publish-release.py"))
publish = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publish)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.commit = "a" * 40
        for architecture in ("x64", "ARM64"):
            source = self.root / f"SSMV-windows-{architecture}-setup.exe"
            source.write_bytes(b"MZ fixture " + architecture.encode())
            source.with_suffix(".exe.json").write_text(json.dumps({
                "commit": self.commit, "architecture": architecture, "release_tag": "v0.5.1",
                "version": "0.5.1", "file": source.name, "sha256": publish.sha256(source)}))
        self.before = {"id": 1, "tag_name": "v0.5.1", "body": "macOS notes", "draft": False,
                       "assets": [{"name": "SSMV-0.5.1.zip", "id": 2, "digest": "sha256:mac", "size": 42}]}

    def assets(self):
        return publish.prepare_assets(self.root, "v0.5.1", self.commit)

    def test_append_preserves_macos_and_idempotent_retry(self):
        files = self.assets()
        self.assertEqual(len(publish.upload_plan(self.before, files)), 6)
        after = copy.deepcopy(self.before)
        after["assets"] += [{"name": p.name, "digest": "sha256:" + publish.sha256(p)} for p in files]
        publish.verify_release(self.before, after, files)
        self.assertEqual(publish.upload_plan(after, files), [])
        after["assets"][0]["id"] = 99
        with self.assertRaisesRegex(ValueError, "Existing asset changed"):
            publish.verify_release(self.before, after, files)

    def test_collision_never_overwrites(self):
        files = self.assets()
        self.before["assets"].append({"name": files[-1].name, "digest": "sha256:other"})
        with self.assertRaisesRegex(ValueError, "Refusing to replace"):
            publish.upload_plan(self.before, files)

    def test_tampered_payload_and_wrong_commit_rejected(self):
        with self.assertRaisesRegex(ValueError, "provenance"):
            publish.prepare_assets(self.root, "v0.5.1", "b" * 40)
        (self.root / "SSMV-windows-ARM64-setup.exe").write_bytes(b"MZ tampered")
        with self.assertRaisesRegex(ValueError, "integrity"):
            self.assets()

    def test_wrong_version_and_tag_rejected(self):
        with self.assertRaises(ValueError):
            publish.prepare_assets(self.root, "../invalid", self.commit)
        with self.assertRaisesRegex(ValueError, "provenance"):
            publish.prepare_assets(self.root, "v0.5.2", self.commit)


if __name__ == "__main__":
    unittest.main()
