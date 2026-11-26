from pathlib import Path
import tempfile
import unittest

from verify_dynamic_packages import verify_dynamic_packages


class DynamicPackageEmbeddingTests(unittest.TestCase):
    def fixture(self, root, *, embedded=True, destination=10, dynamic=True):
        package = Path(root) / "Dependencies/Song"
        package.mkdir(parents=True)
        kind = "dynamic" if dynamic else "static"
        (package / "Package.swift").write_text(
            f'products: [.library(name: "Song", type: .{kind}, targets: ["Song"])]', encoding="utf-8")
        ids = [f"{number:024X}" for number in range(1, 7)]
        package_id, product_id, link_id, copy_id, link_phase, copy_phase = ids
        rows = {
            package_id: 'isa = XCLocalSwiftPackageReference; relativePath = Dependencies/Song;',
            product_id: f'isa = XCSwiftPackageProductDependency; package = {package_id}; productName = Song;',
            link_id: f'isa = PBXBuildFile; productRef = {product_id};',
            copy_id: f'isa = PBXBuildFile; productRef = {product_id};',
            link_phase: f'isa = PBXFrameworksBuildPhase; files = ({link_id});',
            copy_phase: f'isa = PBXCopyFilesBuildPhase; dstSubfolderSpec = {destination}; files = ({copy_id});',
        }
        phases = f"{link_phase}, {copy_phase}" if embedded else link_phase
        target = f'buildPhases = ({phases}); packageProductDependencies = ({product_id});'
        return rows, target

    def test_linking_without_embedding_catches_build101_failure(self):
        with tempfile.TemporaryDirectory() as root:
            rows, target = self.fixture(root, embedded=False)
            with self.assertRaisesRegex(AssertionError, "not embedded.*Song"):
                verify_dynamic_packages(root, rows, target)

    def test_framework_must_be_in_frameworks_not_extensions(self):
        with tempfile.TemporaryDirectory() as root:
            rows, target = self.fixture(root, destination=13)
            with self.assertRaisesRegex(AssertionError, "not embedded"):
                verify_dynamic_packages(root, rows, target)

    def test_embedded_dynamic_library_passes(self):
        with tempfile.TemporaryDirectory() as root:
            rows, target = self.fixture(root)
            self.assertEqual(verify_dynamic_packages(root, rows, target), ["Song"])

    def test_static_library_does_not_require_embedding(self):
        with tempfile.TemporaryDirectory() as root:
            rows, target = self.fixture(root, embedded=False, dynamic=False)
            self.assertEqual(verify_dynamic_packages(root, rows, target), [])


if __name__ == "__main__":
    unittest.main()
