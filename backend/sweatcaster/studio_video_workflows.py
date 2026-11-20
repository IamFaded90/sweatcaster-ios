"""Fixed ComfyUI graphs for Creative Studio and Lumi."""

from dataclasses import dataclass


@dataclass(frozen=True)
class VideoMode:
    id: str
    title: str
    photos: int
    models: tuple
    vace: bool = False


LTX = (
    ("CheckpointLoaderSimple", "ckpt_name", "ltx-video-2b-v0.9.5.safetensors"),
    ("CLIPLoader", "clip_name", "t5xxl_fp16.safetensors"),
)
WAN = (
    ("CLIPLoader", "clip_name", "umt5_xxl_fp8_e4m3fn_scaled.safetensors"),
    ("VAELoader", "vae_name", "wan_2.1_vae.safetensors"),
)
CLIP_VISION = ("CLIPVisionLoader", "clip_name", "clip_vision_h.safetensors")
MODES = (
    VideoMode("ltx-text", "Hurtig prøve · LTX", 0, LTX),
    VideoMode("ltx-image", "Hurtig prøve fra billede · LTX", 1, LTX),
    VideoMode("wan-text", "Høj kvalitet · Wan", 0,
              WAN + (("UNETLoader", "unet_name", "wan2.1_t2v_14B_fp8_e4m3fn.safetensors"),)),
    VideoMode("wan-image", "Høj kvalitet fra billede · Wan", 1,
              WAN + (("UNETLoader", "unet_name", "wan2.1_i2v_480p_14B_fp8_e4m3fn.safetensors"), CLIP_VISION)),
    VideoMode("wan-frames", "Fra start til slutbillede · Wan", 2,
              WAN + (("UNETLoader", "unet_name", "wan2.1_flf2v_720p_14B_fp8_e4m3fn.safetensors"), CLIP_VISION)),
    VideoMode("animatediff", "Giv et billede liv · AnimateDiff", 1,
              (("CheckpointLoaderSimple", "ckpt_name", "v1-5-pruned-emaonly.safetensors"),
               ("ADE_AnimateDiffLoaderGen1", "model_name", "mm_sd_v15_v2.ckpt"))),
)
WAN_VACE = WAN + (("UNETLoader", "unet_name", "wan2.1_vace_1.3B_fp16.safetensors"),)
WAN_FALLBACKS = {
    "wan-text": VideoMode("wan-text", "Fra tekst · Wan 1,3B", 0, WAN_VACE, vace=True),
    "wan-image": VideoMode("wan-image", "Fra billede · Wan 1,3B", 1, WAN_VACE, vace=True),
    "wan-frames": VideoMode("wan-frames", "Fra start til slutbillede · Wan 1,3B", 2, WAN_VACE, vace=True),
}

LUMI_VIDEO_FPS = 16
LUMI_VIDEO_FRAMES = 129


def reference_dimensions(width, height):
    scale = 512 / max(width, height)
    return tuple(max(64, round(side * scale / 16) * 16) for side in (width, height))


def _node(graph, key, kind, **inputs):
    graph[key] = {"class_type": kind, "inputs": inputs}
    return [key, 0]


def _wan_vace_control(graph, stills, size):
    if not stills:
        return {}
    dimensions = {axis: size[axis] for axis in ("width", "height")}
    anchors = [
        _node(graph, f"anchor-{index}", "ImageScale", image=image,
              upscale_method="bicubic", crop="center", **dimensions)
        for index, image in enumerate(stills)
    ]
    # VACE's controls use a batch of images and a mask: black holds an anchor,
    # white lets the model generate the frames between anchors.
    held = _node(graph, "held", "EmptyImage", batch_size=1, color=0, **dimensions)
    free = _node(graph, "free", "EmptyImage", batch_size=size["length"] - len(anchors),
                 color=0xFFFFFF, **dimensions)
    unknown = _node(graph, "unknown", "EmptyImage", batch_size=size["length"] - len(anchors),
                    color=0x808080, **dimensions)
    images = _node(graph, "control-frames", "ImageBatch", image1=anchors[0], image2=unknown)
    mask_images = _node(graph, "control-coverage", "ImageBatch", image1=held, image2=free)
    if len(anchors) == 2:
        images = _node(graph, "control-end", "ImageBatch", image1=images, image2=anchors[1])
        mask_images = _node(graph, "control-end-mask", "ImageBatch", image1=mask_images, image2=held)
    masks = _node(graph, "control-mask", "ImageToMask", image=mask_images, channel="red")
    return {"control_video": images, "control_masks": masks, "reference_image": anchors[0]}


def workflow(mode, prompt, photos, job_id, seed, *, frame_count=None, dimensions=None):
    graph = {}
    ltx = mode.id.startswith("ltx-")
    wan = mode.id.startswith("wan-")
    for node, field, filename in mode.models:
        extras = {
            "UNETLoader": {"weight_dtype": "default"},
            "CLIPLoader": {"type": "ltxv" if ltx else "wan", "device": "default"},
            "ADE_AnimateDiffLoaderGen1": {"model": ["CheckpointLoaderSimple", 0], "beta_schedule": "autoselect"},
        }.get(node, {})
        _node(graph, node, node, **{field: filename, **extras})
    clip = ["CLIPLoader", 0] if ltx or wan else ["CheckpointLoaderSimple", 1]
    vae = ["VAELoader", 0] if wan else ["CheckpointLoaderSimple", 2]
    positive = _node(graph, "positive", "CLIPTextEncode", text=prompt, clip=clip)
    negative = _node(graph, "negative", "CLIPTextEncode", text="blurry, jitter, watermark", clip=clip)
    stills = [_node(graph, f"photo-{index}", "LoadImage", image=filename)
              for index, filename in enumerate(photos)]
    size = dict(width=512, height=320, length=25, batch_size=1)
    fps = 12.0
    if ltx:
        fps = 24.0
        if stills:
            _node(graph, "reference", "LTXVImgToVideo", positive=positive, negative=negative,
                  vae=vae, image=stills[0], strength=1.0, **size)
            positive, negative, latent = (["reference", index] for index in range(3))
        else:
            latent = _node(graph, "latent", "EmptyLTXVLatentVideo", **size)
        condition = _node(graph, "frames", "LTXVConditioning", positive=positive, negative=negative, frame_rate=fps)
        sampler = _node(graph, "sampler", "KSamplerSelect", sampler_name="res_multistep")
        sigmas = _node(graph, "sigmas", "LTXVScheduler", steps=20, max_shift=2.05,
                       base_shift=0.95, stretch=True, terminal=0.1, latent=latent)
        sample = _node(graph, "sample", "SamplerCustom", model=["CheckpointLoaderSimple", 0],
                       positive=condition, negative=["frames", 1], latent_image=latent,
                       sampler=sampler, sigmas=sigmas, noise_seed=seed, add_noise=True, cfg=3.0)
    elif wan:
        model = _node(graph, "shift", "ModelSamplingSD3", model=["UNETLoader", 0], shift=8.0)
        if mode.vace:
            width, height = dimensions or (512, 288)
            size = dict(width=width, height=height, length=frame_count or 81, batch_size=1)
            fps = 16.0
            _node(graph, "reference", "WanVaceToVideo", positive=positive, negative=negative,
                  vae=vae, strength=1.0, **size, **_wan_vace_control(graph, stills, size))
            positive, negative, latent = (["reference", index] for index in range(3))
        elif stills:
            vision = [_node(graph, f"clip-vision-{index}", "CLIPVisionEncode",
                            clip_vision=["CLIPVisionLoader", 0], image=image, crop="center")
                      for index, image in enumerate(stills)]
            if len(stills) == 2:
                _node(graph, "reference", "WanFirstLastFrameToVideo", positive=positive, negative=negative,
                      vae=vae, start_image=stills[0], end_image=stills[1],
                      clip_vision_start_image=vision[0], clip_vision_end_image=vision[1], **size)
            else:
                _node(graph, "reference", "WanImageToVideo", positive=positive, negative=negative,
                      vae=vae, start_image=stills[0], clip_vision_output=vision[0], **size)
            positive, negative, latent = (["reference", index] for index in range(3))
        else:
            latent = _node(graph, "latent", "EmptyHunyuanLatentVideo", **size)
        sample = _node(graph, "sample", "KSampler", model=model, positive=positive, negative=negative,
                       latent_image=latent, seed=seed, steps=30 if mode.vace else 24, cfg=6.0, sampler_name="uni_pc",
                       scheduler="simple", denoise=1.0)
    else:
        fps = 8.0
        scaled = _node(graph, "resize", "ImageScale", image=stills[0], width=512, height=320,
                       upscale_method="bicubic", crop="center")
        encoded = _node(graph, "encode", "VAEEncode", pixels=scaled, vae=vae)
        latent = _node(graph, "latent", "RepeatLatentBatch", samples=encoded, amount=16)
        sample = _node(graph, "sample", "KSampler", model=["ADE_AnimateDiffLoaderGen1", 0],
                       positive=positive, negative=negative, latent_image=latent, seed=seed,
                       steps=20, cfg=6.0, sampler_name="euler", scheduler="normal", denoise=0.58)
    if wan:
        if mode.vace and stills:
            sample = _node(graph, "trim", "TrimVideoLatent", samples=sample, trim_amount=["reference", 3])
        # The untiled Wan decode exceeded the available VRAM on the Windows PC.
        frames = _node(graph, "decode", "VAEDecodeTiled", samples=sample, vae=vae,
                       tile_size=192, overlap=32, temporal_size=8, temporal_overlap=4)
    else:
        frames = _node(graph, "decode", "VAEDecode", samples=sample, vae=vae)
    video = _node(graph, "video", "CreateVideo", images=frames, fps=fps)
    _node(graph, "save", "SaveVideo", video=video, filename_prefix=f"FadedAI_Studio/{job_id}",
          **{"format": "mp4", "format.codec": "h264"})
    return graph


def lumi_reference_workflow(prompt, reference_name, output_prefix, seed, *, reference_size=None):
    mode = WAN_FALLBACKS["wan-image"]
    dimensions = reference_dimensions(*reference_size) if reference_size else (512, 288)
    graph = workflow(mode, prompt, [reference_name + " [temp]"], "lumi", seed,
                     frame_count=LUMI_VIDEO_FRAMES, dimensions=dimensions)
    del graph["video"], graph["save"]
    _node(graph, "10", "SaveWEBM", images=["decode", 0], filename_prefix=output_prefix,
          codec="vp9", fps=LUMI_VIDEO_FPS, crf=20)
    return graph, mode.models


def lumi_text_workflow(prompt, output_prefix, seed, model, clip, vae):
    models = (("UNETLoader", "unet_name", model), ("CLIPLoader", "clip_name", clip),
              ("VAELoader", "vae_name", vae))
    graph = {}
    unet = _node(graph, "1", "UNETLoader", unet_name=model, weight_dtype="default")
    shifted = _node(graph, "2", "ModelSamplingSD3", model=unet, shift=8)
    text = _node(graph, "3", "CLIPLoader", clip_name=clip, type="wan", device="default")
    positive = _node(graph, "4", "CLIPTextEncode", text=prompt, clip=text)
    negative = _node(graph, "5", "CLIPTextEncode", text="low quality, blurry, static, watermark", clip=text)
    decode = _node(graph, "6", "VAELoader", vae_name=vae)
    latent = _node(graph, "7", "EmptyHunyuanLatentVideo", width=512, height=288, length=LUMI_VIDEO_FRAMES, batch_size=1)
    sample = _node(graph, "8", "KSampler", seed=seed, steps=30, cfg=6, sampler_name="uni_pc",
                   scheduler="simple", denoise=1, model=shifted, positive=positive, negative=negative,
                   latent_image=latent)
    frames = _node(graph, "9", "VAEDecodeTiled", samples=sample, vae=decode, tile_size=192,
                   overlap=32, temporal_size=8, temporal_overlap=4)
    _node(graph, "10", "SaveWEBM", images=frames, filename_prefix=output_prefix, codec="vp9", fps=LUMI_VIDEO_FPS, crf=20)
    return graph, models
