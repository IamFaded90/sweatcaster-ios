"""Run a local 3D model on the PC and write one mesh."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
from tempfile import TemporaryDirectory


MAX_OUTPUT = 80_000_000
MAX_IMAGE = 12_000_000


def shap_e(text: str, image: Path | None, output: Path) -> None:
    import torch
    from PIL import Image
    from shap_e.diffusion.gaussian_diffusion import diffusion_from_config
    from shap_e.diffusion.sample import sample_latents
    from shap_e.models.download import load_config, load_model

    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    cache = os.environ.get("FADEDAI_SHAPE_CACHE")
    model = load_model("image300M" if image else "text300M", device=device, cache_dir=cache)
    diffusion = diffusion_from_config(load_config("diffusion", cache_dir=cache))
    if image:
        with Image.open(image) as source:
            if source.width * source.height > 16_000_000:
                raise ValueError("Referencebilledet har for mange pixels.")
            conditioning = {"images": [source.convert("RGB")]}
    else:
        conditioning = {"texts": [text]}
    with torch.inference_mode():
        latents = sample_latents(batch_size=1, model=model, diffusion=diffusion,
                                 guidance_scale=3.0 if image else 15.0, model_kwargs=conditioning,
                                 progress=False, clip_denoised=True, use_fp16=device.type == "cuda",
                                 use_karras=True, karras_steps=64, sigma_min=1e-3, sigma_max=160, s_churn=0)
        del model
        transmitter = load_model("transmitter", device=device, cache_dir=cache)
        mesh = shape_mesh(transmitter, latents[0])
    with output.open("w", encoding="ascii", newline="\n") as stream:
        mesh.write_obj(stream)


def shape_mesh(transmitter, latent):
    import torch
    from shap_e.models.nn.camera import DifferentiableCameraBatch, DifferentiableProjectiveCamera
    from shap_e.util.collections import AttrDict

    # A tiny single view is enough to make Shap-E produce the surface mesh.
    forward = torch.tensor([[0.0, 2.0, -1.0]], device=latent.device)
    forward = torch.nn.functional.normalize(forward)
    right = torch.tensor([[1.0, 0.0, 0.0]], device=latent.device)
    camera = DifferentiableProjectiveCamera(
        origin=-4 * forward, x=right, y=torch.linalg.cross(forward, right), z=forward,
        width=2, height=2, x_fov=0.7, y_fov=0.7,
    )
    parameters = transmitter.encoder.bottleneck_to_params(latent.unsqueeze(0))
    result = transmitter.renderer.render_views(
        AttrDict(cameras=DifferentiableCameraBatch(shape=(1, 1), flat_camera=camera)),
        params=parameters, options=AttrDict(rendering_mode="stf", render_with_direction=False),
    )
    return result.raw_meshes[0].tri_mesh()


def validate_mesh(path: Path) -> None:
    if path.is_symlink() or not path.is_file() or not 12 < path.stat().st_size <= MAX_OUTPUT:
        raise ValueError("3D-motoren leverede ingen gyldig modelfil.")
    with path.open("rb") as stream:
        has_vertex = has_face = False
        for line in stream:
            has_vertex |= line.startswith(b"v ")
            has_face |= line.startswith(b"f ")
            if has_vertex and has_face:
                return
    raise ValueError("3D-motoren leverede en fil i et uventet format.")


def run(engine: str, output: Path, *, text: str, image: Path | None) -> None:
    if output.exists():
        raise ValueError("Vælg et nyt filnavn til modellen.")
    if image is not None and (not image.is_file() or not 0 < image.stat().st_size <= MAX_IMAGE):
        raise ValueError("Vælg et eksisterende referencebillede på højst 12 MB.")
    prompt = text.strip()
    if engine != "shape":
        raise ValueError("Ukendt 3D-motor.")
    if output.suffix != ".obj" or bool(image) == bool(prompt) or len(prompt) > 1_000:
        raise ValueError("Shap-E kræver tekst eller ét billede og en .obj-fil som resultat.")
    with TemporaryDirectory(dir=output.parent, prefix=".faded3d-") as temporary:
        mesh = Path(temporary) / ("model" + output.suffix)
        shap_e(prompt, image, mesh)
        validate_mesh(mesh)
        if os.name == "nt":
            mesh.rename(output)  # Windows rename fails if the destination appeared during generation.
        else:
            os.link(mesh, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("engine", choices=("shape",))
    parser.add_argument("output", type=Path)
    parser.add_argument("--text", default="")
    parser.add_argument("--image", type=Path)
    args = parser.parse_args()
    try:
        run(args.engine, args.output.absolute(), text=args.text,
            image=args.image.resolve() if args.image else None)
    except (ValueError, OSError, ImportError, RuntimeError) as exc:
        parser.exit(1, f"{exc}\n")


if __name__ == "__main__":
    main()
