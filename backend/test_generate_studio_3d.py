import pytest

import generate_studio_3d as studio


def test_shape_writes_one_mesh_and_preserves_existing_files(tmp_path, monkeypatch):
    path = tmp_path / "object.obj"

    def shape(prompt, image, temporary):
        assert (prompt, image) == ("a blue lamp", None)
        temporary.write_text("v 0 0 0\nv 0 1 0\nv 1 0 0\nf 1 2 3\n")

    monkeypatch.setattr(studio, "shap_e", shape)
    studio.run("shape", path, text=" a blue lamp ", image=None)
    with pytest.raises(ValueError, match="nyt filnavn"):
        studio.run("shape", path, text="other", image=None)
    assert path.read_text().endswith("f 1 2 3\n")
    assert list(tmp_path.iterdir()) == [path]


def test_incomplete_shap_e_mesh_leaves_no_export_or_temp_directory(tmp_path, monkeypatch):
    image = tmp_path / "reference.png"
    image.write_bytes(b"mock")
    path = tmp_path / "object.obj"
    monkeypatch.setattr(studio, "shap_e", lambda _text, _image, mesh:
                        mesh.write_text("v 0 0 0\nv 0 1 0\nv 1 0 0\n"))
    with pytest.raises(ValueError, match="uventet format"):
        studio.run("shape", path, text="", image=image)
    assert list(tmp_path.iterdir()) == [image]
