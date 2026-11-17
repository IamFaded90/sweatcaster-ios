"""Generate the two front-facing Village reliefs from the existing expression artwork."""
import io
import json
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter


VILLAGE = Path(__file__).resolve().parents[1] / "App/Assets/Village"
PORTRAITS = {
    "harper": {
        "face": (262, 280), "nose": (268, 305),
        "eyes": (157, 216, 359, 302), "mouth": (192, 326, 329, 407),
        "outline": [(251, 32), (282, 49), (316, 45), (350, 63), (382, 108),
                    (410, 169), (423, 226), (435, 271), (451, 321), (452, 345),
                    (473, 379), (469, 413), (451, 446), (429, 461), (407, 473),
                    (472, 510), (495, 543), (510, 593), (511, 768), (0, 768),
                    (0, 641), (18, 575), (39, 530), (77, 499), (112, 486),
                    (122, 475), (92, 465), (70, 443), (53, 410), (55, 377),
                    (69, 350), (63, 308), (76, 263), (87, 217), (97, 172),
                    (115, 130), (143, 93), (171, 65), (211, 44)],
    },
    "lumi": {
        "face": (263, 270), "nose": (287, 289),
        "eyes": (193, 204, 370, 281), "mouth": (216, 303, 325, 390),
        "outline": [(239, 33), (260, 40), (280, 32), (322, 40), (359, 59),
                    (396, 111), (415, 150), (430, 198), (448, 237), (476, 270),
                    (483, 310), (468, 348), (473, 384), (496, 416), (497, 449),
                    (479, 481), (497, 521), (497, 561), (507, 606), (497, 639),
                    (477, 672), (461, 712), (426, 752), (420, 767), (106, 767),
                    (100, 748), (87, 718), (62, 696), (37, 672), (16, 649),
                    (3, 614), (0, 570), (0, 488), (21, 472), (44, 460),
                    (29, 435), (22, 402), (33, 368), (49, 337), (60, 310),
                    (56, 276), (64, 239), (82, 209), (101, 181), (108, 150),
                    (134, 119), (153, 96), (182, 65), (206, 45)],
    },
}


class PortraitModel:
    def __init__(self, name):
        self.name = name
        self.binary = bytearray()
        self.data = dict(
            asset={"version": "2.0", "generator": "FadedAI Village portraits"},
            scene=0, scenes=[{"nodes": [0]}], nodes=[], meshes=[], materials=[],
            textures=[], images=[], bufferViews=[], accessors=[],
            samplers=[{"wrapS": 33071, "wrapT": 33071}],
            extensionsUsed=["VRMC_vrm", "KHR_materials_unlit"],
        )
        self.bones = {}
        self.preset = {}
        self.custom = {}

    def add(self, collection, item):
        items = self.data[collection]
        items.append(item)
        return len(items) - 1

    def view(self, raw, target=None):
        view = dict(buffer=0, byteOffset=len(self.binary), byteLength=len(raw))
        if target:
            view["target"] = target
        self.binary.extend(raw)
        self.binary.extend(bytes(-len(raw) % 4))
        return self.add("bufferViews", view)

    def accessor(self, data, kind, component=5126, bounds=False):
        target = 34963 if kind == "SCALAR" else 34962
        accessor = dict(bufferView=self.view(data.tobytes(), target),
                        componentType=component, count=len(data), type=kind)
        if bounds:
            accessor.update(min=data.min(axis=0).tolist(), max=data.max(axis=0).tolist())
        return self.add("accessors", accessor)

    def node(self, name, parent=None, offset=(0, 0, 0), **properties):
        node = self.add("nodes", dict(name=name, translation=list(offset), **properties))
        if parent is not None:
            self.data["nodes"][parent].setdefault("children", []).append(node)
        return node

    def bone(self, name, parent, offset):
        node = self.node(name, parent, offset)
        self.bones[name] = {"node": node}
        return node

    def define_bones(self, root):
        hips = self.bone("hips", root, (0, .64, 0))
        spine = self.bone("spine", hips, (0, .3, 0))
        self.bone("head", spine, (0, .58, 0))
        for side, sign in (("left", 1), ("right", -1)):
            upper = self.bone(side + "UpperArm", spine, (.18 * sign, .26, 0))
            fore = self.bone(side + "LowerArm", upper, (.26 * sign, 0, 0))
            self.bone(side + "Hand", fore, (.23 * sign, 0, 0))
            thigh = self.bone(side + "UpperLeg", hips, (.10 * sign, 0, 0))
            shin = self.bone(side + "LowerLeg", thigh, (0, -.3, 0))
            self.bone(side + "Foot", shin, (0, -.29, .04))

    def material(self, texture):
        stream = io.BytesIO()
        texture.save(stream, format="PNG", optimize=True)
        image = self.add("images", dict(bufferView=self.view(stream.getvalue()), mimeType="image/png"))
        texture = self.add("textures", {"source": image, "sampler": 0})
        return self.add("materials", {
            "extensions": {"KHR_materials_unlit": {}},
            "alphaMode": "MASK", "alphaCutoff": .45,
            "pbrMetallicRoughness": {"baseColorTexture": {"index": texture}},
        })

    def mesh(self, root, name, points, uv, indices, texture, morphs):
        primitive = dict(
            attributes={"POSITION": self.accessor(points, "VEC3", bounds=True),
                        "TEXCOORD_0": self.accessor(uv, "VEC2")},
            indices=self.accessor(indices, "SCALAR", 5123), material=self.material(texture),
            targets=[{"POSITION": self.accessor(delta, "VEC3", bounds=True)} for delta in morphs.values()],
        )
        mesh = self.add("meshes", dict(primitives=[primitive], weights=[0] * len(morphs),
                                      extras={"targetNames": list(morphs)}))
        node = self.node(name, root, mesh=mesh)
        for index, expression in enumerate(morphs):
            group = self.custom if expression == "breath" else self.preset
            group.setdefault(expression, {"morphTargetBinds": []})["morphTargetBinds"].append(
                {"node": node, "index": index, "weight": 1}
            )

    def write(self):
        self.data["buffers"] = [{"byteLength": len(self.binary)}]
        self.data["extensions"] = {"VRMC_vrm": {
            "specVersion": "1.0", "humanoid": {"humanBones": self.bones},
            "meta": {"name": self.name.title(), "version": "1.0", "authors": ["FadedAI"],
                     "licenseUrl": "https://vrm.dev/licenses/1.0/", "avatarPermission": "onlyAuthor",
                     "commercialUsage": "personalNonProfit", "allowRedistribution": False,
                     "modification": "prohibited", "creditNotation": "required"},
            "expressions": {"preset": self.preset, "custom": self.custom},
        }}
        manifest = json.dumps(self.data, separators=(",", ":")).encode()
        manifest += b" " * (-len(manifest) % 4)
        header = struct.pack("<IIIII", 0x46546C67, 2, 28 + len(manifest) + len(self.binary),
                             len(manifest), 0x4E4F534A)
        (VILLAGE / "vrm" / (self.name + ".vrm")).write_bytes(
            header + manifest + struct.pack("<II", len(self.binary), 0x004E4942) + self.binary
        )


def gaussian(x, y, center, spread):
    return np.exp(-(((x - center[0]) / spread[0]) ** 2 + ((y - center[1]) / spread[1]) ** 2))


def surface(rect, layout, lift, divisions):
    left, top, right, bottom = rect
    column, row = np.meshgrid(np.linspace(left, right, divisions[0] + 1),
                              np.linspace(top, bottom, divisions[1] + 1))
    head = gaussian(column, row, layout["face"], (122, 182))
    nose = gaussian(column, row, layout["nose"], (24, 36))
    torso = gaussian(column, row, (260, 641), (188, 155))
    hair = gaussian(column, row, (255, 220), (194, 230))
    depth = .033 * hair + .126 * head + .041 * nose + .115 * torso
    positions = np.stack(((column - 256) / 570, 1.84 - row / 570, depth + lift), axis=-1)
    uv = np.stack(((column - left) / (right - left), (row - top) / (bottom - top)), axis=-1)
    indices = []
    for y in range(divisions[1]):
        for x in range(divisions[0]):
            a = y * (divisions[0] + 1) + x
            c = a + divisions[0] + 1
            indices.extend((a, c, a + 1, a + 1, c, c + 1))
    breath = np.stack(((column - 256) / 19000 * torso, .006 * torso, .015 * torso), axis=-1)
    return (
        positions.reshape(-1, 3).astype("<f4"), uv.reshape(-1, 2).astype("<f4"),
        np.array(indices, dtype="<u2"), breath.reshape(-1, 3).astype("<f4"),
    )


def edge_mask(size, points):
    mask = Image.new("L", size)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask.filter(ImageFilter.GaussianBlur(2.3))


def build(name, layout):
    model = PortraitModel(name)
    root = model.node(name.title())
    model.define_bones(root)
    sheet = Image.open(VILLAGE / "final" / f"expressions-{name}.png").convert("RGBA")
    w, h = sheet.width // 2, sheet.height // 2
    if (w, h) != (512, 768):
        raise ValueError(f"Unexpected expression sheet dimensions for {name}")
    neutral = sheet.crop((0, 0, w, h))
    neutral.putalpha(edge_mask(neutral.size, layout["outline"]))
    points, uv, indices, breath = surface((0, 0, w, h), layout, 0, (88, 128))
    model.mesh(root, "Portrait surface", points, uv, indices, neutral, {"breath": breath})
    for feature, cell, expression in (("eyes", (w, 0), "blink"), ("mouth", (0, h), "ih"), ("mouth", (w, h), "aa")):
        rect = layout[feature]
        patch = sheet.crop(tuple(v + cell[i % 2] for i, v in enumerate(rect)))
        width, height = patch.size
        patch.putalpha(edge_mask(patch.size, [(5, 5), (width-6, 5), (width-6, height-6), (5, height-6)]))
        points, uv, indices, breath = surface(rect, layout, -.019, (50, 30))
        delta = np.zeros_like(points)
        delta[:, 2] = .021
        model.mesh(root, feature, points, uv, indices, patch, {expression: delta, "breath": breath})
    model.write()


if __name__ == "__main__":
    for name, layout in PORTRAITS.items():
        build(name, layout)
