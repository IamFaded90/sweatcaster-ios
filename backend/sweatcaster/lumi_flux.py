"""FLUX.2 Klein PC workflow, adapted from ComfyUI's 4B image edit template."""

import requests

MODEL = "flux-2-klein-4b-fp8.safetensors"
TEXT_ENCODER = "qwen_3_4b_fp4_flux2.safetensors"
VAE = "flux2-vae.safetensors"
ADULT_LORA = "party_time_v2.1_klein4b.safetensors"


def availability(client, base_url, pony_model):
    """Inspect one Comfy catalog snapshot; failures in one model do not hide others."""
    unavailable = {"flux2": False, "flux2Adult": False, "pony": False}
    try:
        response = client.get(base_url + "/object_info", timeout=(3, 8), allow_redirects=False)
        response.raise_for_status()
        info = response.json()
        if not isinstance(info, dict):
            return unavailable
    except (requests.RequestException, ValueError, TypeError):
        return unavailable

    def contains(node, field, filename):
        try:
            choices = info[node]["input"]["required"][field][0]
            return isinstance(choices, list) and filename in choices
        except (KeyError, IndexError, TypeError):
            return False

    flux = (contains("UNETLoader", "unet_name", MODEL)
            and contains("CLIPLoader", "clip_name", TEXT_ENCODER)
            and contains("VAELoader", "vae_name", VAE)
            and all(name in info for name in ("Flux2Scheduler", "EmptyFlux2LatentImage", "ReferenceLatent")))
    return {"flux2": flux,
            "flux2Adult": flux and contains("LoraLoaderModelOnly", "lora_name", ADULT_LORA),
            "pony": contains("CheckpointLoaderSimple", "ckpt_name", pony_model)}


def graph(prompt, seed, width, height, reference_name=None, mask_name=None, adult=False):
    """Build an instruction-guided image edit or generation graph.

    A supplied mask controls only the final composite. The reference latent
    conditions the whole edit, so the surrounding subject remains visible to the model.
    """
    if mask_name and not reference_name:
        raise ValueError("A mask requires a reference image")
    graph = {
        "1": {"class_type": "UNETLoader", "inputs": {"unet_name": MODEL, "weight_dtype": "default"}},
        "2": {"class_type": "CLIPLoader", "inputs": {"clip_name": TEXT_ENCODER, "type": "flux2", "device": "default"}},
        "3": {"class_type": "VAELoader", "inputs": {"vae_name": VAE}},
        "4": {"class_type": "CLIPTextEncode", "inputs": {"text": prompt, "clip": ["2", 0]}},
        "5": {"class_type": "ConditioningZeroOut", "inputs": {"conditioning": ["4", 0]}},
        "6": {"class_type": "VAEDecode", "inputs": {"samples": ["15", 0], "vae": ["3", 0]}},
        "7": {"class_type": "PreviewImage", "inputs": {"images": ["6", 0]}},
        "10": {"class_type": "CFGGuider", "inputs": {"model": ["1", 0], "positive": ["4", 0], "negative": ["5", 0], "cfg": 1.0}},
        "11": {"class_type": "EmptyFlux2LatentImage", "inputs": {"width": width, "height": height, "batch_size": 1}},
        "12": {"class_type": "RandomNoise", "inputs": {"noise_seed": seed}},
        "13": {"class_type": "KSamplerSelect", "inputs": {"sampler_name": "euler"}},
        "14": {"class_type": "Flux2Scheduler", "inputs": {"steps": 4, "width": width, "height": height}},
        "15": {"class_type": "SamplerCustomAdvanced", "inputs": {"noise": ["12", 0], "guider": ["10", 0], "sampler": ["13", 0], "sigmas": ["14", 0], "latent_image": ["11", 0]}},
    }
    if adult:
        graph["26"] = {"class_type": "LoraLoaderModelOnly", "inputs": {
            "model": ["1", 0], "lora_name": ADULT_LORA, "strength_model": 1.0}}
        graph["10"]["inputs"]["model"] = ["26", 0]
    if reference_name:
        graph["20"] = {"class_type": "LoadImage", "inputs": {"image": reference_name + " [temp]"}}
        graph["21"] = {"class_type": "VAEEncode", "inputs": {"pixels": ["20", 0], "vae": ["3", 0]}}
        graph["22"] = {"class_type": "ReferenceLatent", "inputs": {"conditioning": ["4", 0], "latent": ["21", 0]}}
        graph["23"] = {"class_type": "ReferenceLatent", "inputs": {"conditioning": ["5", 0], "latent": ["21", 0]}}
        graph["10"]["inputs"].update(positive=["22", 0], negative=["23", 0])
    if mask_name:
        graph["24"] = {"class_type": "LoadImageMask", "inputs": {"image": mask_name + " [temp]", "channel": "red"}}
        graph["25"] = {"class_type": "ImageCompositeMasked", "inputs": {
            "destination": ["20", 0], "source": ["6", 0], "mask": ["24", 0],
            "x": 0, "y": 0, "resize_source": True}}
        graph["7"]["inputs"]["images"] = ["25", 0]
    return graph
