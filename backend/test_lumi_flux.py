import pytest
import requests
from pathlib import Path

from sweatcaster import lumi_flux


def catalog_item(field, choices):
    return {"input": {"required": {field: [choices]}}}


class CatalogClient:
    def __init__(self, catalog):
        self.catalog = catalog
        self.calls = []

    def get(self, url, **kwargs):
        self.calls.append((url, kwargs))
        if isinstance(self.catalog, Exception):
            raise self.catalog
        return self

    def raise_for_status(self):
        pass

    def json(self):
        return self.catalog


def test_catalog_checks_both_models_in_one_request_even_if_flux_is_malformed():
    client = CatalogClient({"UNETLoader": {"input": None},
                            "CheckpointLoaderSimple": catalog_item("ckpt_name", ["pony.safetensors"])})
    assert lumi_flux.availability(client, "http://localhost:8188", "pony.safetensors") == {
        "flux2": False, "flux2Adult": False, "pony": True}
    assert len(client.calls) == 1
    assert client.calls[0][1]["timeout"] == (3, 8)


def test_catalog_reports_flux_without_adult_lora_and_pony_independently():
    info = {"UNETLoader": catalog_item("unet_name", [lumi_flux.MODEL]),
            "CLIPLoader": catalog_item("clip_name", [lumi_flux.TEXT_ENCODER]),
            "VAELoader": catalog_item("vae_name", [lumi_flux.VAE]),
            "Flux2Scheduler": {}, "EmptyFlux2LatentImage": {}, "ReferenceLatent": {}}
    client = CatalogClient(info)
    assert lumi_flux.availability(client, "http://localhost:8188", "pony.safetensors") == {
        "flux2": True, "flux2Adult": False, "pony": False}
    info["LoraLoaderModelOnly"] = catalog_item("lora_name", [lumi_flux.ADULT_LORA])
    assert lumi_flux.availability(client, "http://localhost:8188", "pony.safetensors")["flux2Adult"] is True


def test_catalog_connection_failure_marks_all_unavailable():
    client = CatalogClient(requests.ConnectionError("offline"))
    assert lumi_flux.availability(client, "http://localhost:8188", "pony.safetensors") == {
        "flux2": False, "flux2Adult": False, "pony": False}


def test_pc_update_stages_voice_worker_with_voice_module():
    from install_module_tabs import collect_modules
    source = Path(__file__).parent / "sweatcaster" / "module_tabs.py"
    modules = collect_modules(source)
    assert modules["roest_worker.py"] == (source.parent / "roest_worker.py").read_text(encoding="utf-8")
    assert "roest_worker.py" in modules["microsoft_voice.py"]


def test_flux_edit_uses_reference_and_mask_composite():
    workflow = lumi_flux.graph("change the shirt to blue", 42, 512, 768, "photo.png", "mask.png")
    assert workflow["4"]["inputs"]["text"] == "change the shirt to blue"
    assert workflow["22"]["inputs"]["latent"] == ["21", 0]
    assert workflow["25"]["inputs"]["destination"] == ["20", 0]
    assert workflow["25"]["inputs"]["mask"] == ["24", 0]
    assert workflow["7"]["inputs"]["images"] == ["25", 0]
    assert workflow["11"]["inputs"]["width"] == 512
    assert workflow["11"]["inputs"]["height"] == 768


def test_flux_generation_does_not_include_reference():
    workflow = lumi_flux.graph("a blue flower", 13, 512, 512)
    assert workflow["7"]["inputs"]["images"] == ["6", 0]
    assert "20" not in workflow


def test_flux_rejects_mask_without_reference():
    with pytest.raises(ValueError):
        lumi_flux.graph("edit", 1, 512, 512, mask_name="mask.png")


def test_adult_option_loads_only_its_specific_lora():
    adult = lumi_flux.graph("adult portrait", 42, 512, 512, adult=True)
    assert adult["26"]["inputs"]["lora_name"] == lumi_flux.ADULT_LORA
    assert adult["10"]["inputs"]["model"] == ["26", 0]
    ordinary = lumi_flux.graph("portrait", 42, 512, 512)
    assert "26" not in ordinary
    assert ordinary["10"]["inputs"]["model"] == ["1", 0]


def test_lumi_installer_includes_flux_module(tmp_path):
    from install_lumi_pc import install
    package = tmp_path / "sweatcaster"
    package.mkdir()
    (package / "api.py").write_text("", encoding="utf-8")
    (package / "module_tabs.py").write_text(
        "def register(app, settings, authorize):\n"
        "    from sweatcaster.bot_computer_routes import register_bot_computers\n"
        "    computers = register_bot_computers(app, settings, authorize)\n", encoding="utf-8")
    assert package / "lumi_flux.py" in install(tmp_path)
    install(tmp_path, apply=True)
    assert (package / "lumi_flux.py").read_text(encoding="utf-8").startswith('"""FLUX.2')
    assert install(tmp_path) == []
