"""Offline art QA using exact C# source geometry. Invoke with Blender 4.2, not system Python.

blender -b --factory-startup -t 8 --python Tools/render_geometry.py -- \
  --scene Review/geometry/scene.json --output Review/offline

This produces geometry/art review frames, not Unity screenshots or device benchmarks.
"""
import argparse
import json
import math
import pathlib
import sys

import bpy
from mathutils import Vector


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scene", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--samples", type=int, default=16)
    parser.add_argument("--only", default="all", choices=["all", "overview", "district"])
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:])
    source = pathlib.Path(args.scene).resolve()
    data = json.loads(source.read_text())
    output = pathlib.Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    materials = {}
    for surface in data["surfaces"]:
        material = bpy.data.materials.new(surface["id"])
        material.use_nodes = True
        nodes = material.node_tree.nodes
        links = material.node_tree.links
        bsdf = nodes.get("Principled BSDF")
        bsdf.inputs["Roughness"].default_value = surface["roughness"]
        bsdf.inputs["Metallic"].default_value = surface["metallic"]
        texture = nodes.new("ShaderNodeTexImage")
        texture.image = bpy.data.images.load(str(source.parent / "textures" / (surface["id"] + ".ppm")), check_existing=True)
        texture.interpolation = "Linear"
        if surface["id"] == "terrain":
            attribute = nodes.new("ShaderNodeVertexColor")
            attribute.layer_name = "BiomeColor"
            mix = nodes.new("ShaderNodeMixRGB")
            mix.blend_type = "MULTIPLY"
            mix.inputs[0].default_value = 1
            links.new(texture.outputs["Color"], mix.inputs[1])
            links.new(attribute.outputs["Color"], mix.inputs[2])
            links.new(mix.outputs["Color"], bsdf.inputs["Base Color"])
        else:
            links.new(texture.outputs["Color"], bsdf.inputs["Base Color"])
        if surface["bump"] > 0:
            bump = nodes.new("ShaderNodeBump")
            bump.inputs["Strength"].default_value = 0.18
            bump.inputs["Distance"].default_value = surface["bump"]
            links.new(texture.outputs["Color"], bump.inputs["Height"])
            links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
        materials[surface["id"]] = material

    def mesh(raw, name):
        result = bpy.data.meshes.new(name)
        vertices = [(v["x"], -v["z"], v["y"]) for v in raw["vertices"]]
        indices = raw["triangles"]
        result.from_pydata(vertices, [], [indices[i:i + 3] for i in range(0, len(indices), 3)])
        result.update()
        uv = result.uv_layers.new(name="UVMap")
        for loop in result.loops:
            v = raw["vertices"][loop.vertex_index]
            uv.data[loop.index].uv = (v["u"], v["v"])
        colors = result.color_attributes.new(name="BiomeColor", type="BYTE_COLOR", domain="POINT")
        for i, v in enumerate(raw["vertices"]):
            # Bytes describe display-space tint; Blender's color_srgb converts to scene-linear.
            colors.data[i].color_srgb = (v["r"] / 255, v["g"] / 255, v["b"] / 255, 1)
        result.materials.append(materials[raw["material"]])
        return result

    templates = {key: [mesh(part, key + "_" + str(i)) for i, part in enumerate(model["parts"])] for key, model in data["models"].items()}
    for placement in data["placements"]:
        for part in templates[placement["asset"]]:
            obj = bpy.data.objects.new(placement["id"], part)
            bpy.context.collection.objects.link(obj)
            obj.location = (placement["x"], -placement["z"], placement["y"])
            obj.rotation_euler[2] = math.radians(placement["yaw"])
            obj.scale = (placement["scale"],) * 3
    for tile in data["terrain"]:
        obj = bpy.data.objects.new(tile["id"], mesh(tile["mesh"], tile["id"]))
        bpy.context.collection.objects.link(obj)
        obj.location = (tile["x"], -tile["z"], 0)
    for category in ["roads", "water"]:
        for i, raw in enumerate(data[category]):
            obj = bpy.data.objects.new(category + str(i), mesh(raw, category + str(i)))
            bpy.context.collection.objects.link(obj)

    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = args.samples
    scene.cycles.use_denoising = True
    scene.render.resolution_x = 1440
    scene.render.resolution_y = 1000
    scene.render.resolution_percentage = 100
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "AgX - Medium High Contrast"
    scene.render.image_settings.file_format = "PNG"
    scene.world.use_nodes = True
    scene.world.node_tree.nodes.get("Background").inputs[0].default_value = (0.55, 0.68, 0.82, 1)
    scene.world.node_tree.nodes.get("Background").inputs[1].default_value = 0.5
    sun_data = bpy.data.lights.new("Sun", "SUN")
    sun_data.energy = 3
    sun_data.angle = math.radians(4)
    sun = bpy.data.objects.new("Sun", sun_data)
    bpy.context.collection.objects.link(sun)
    sun.rotation_euler = (math.radians(38), math.radians(-15), math.radians(-38))
    camera_data = bpy.data.cameras.new("ReviewCamera")
    camera = bpy.data.objects.new("ReviewCamera", camera_data)
    bpy.context.collection.objects.link(camera)
    scene.camera = camera
    camera_data.clip_end = 5000
    camera_data.lens = 44

    def capture(filename, unity_position, unity_target):
        camera.location = (unity_position[0], -unity_position[2], unity_position[1])
        target = Vector((unity_target[0], -unity_target[2], unity_target[1]))
        camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = str(output / filename)
        bpy.ops.render.render(write_still=True)

    if args.only in ["all", "overview"]:
        capture("world-perspective.png", (1000, 1200, -1200), (0, 5, 0))
    if args.only in ["all", "district"]:
        courts = next(p for p in data["landmarks"] if p["id"] == "POI_COURTS")
        x, z = courts["x"], courts["z"]
        capture("courts-perspective.png", (x + 145, 122, z - 160), (x, 13, z))
        ridge = next(p for p in data["landmarks"] if p["id"] == "POI_STATION")
        capture("ridge-perspective.png", (ridge["x"] + 125, 132, ridge["z"] - 145), (ridge["x"], 36, ridge["z"]))
    (output / "source.json").write_text(json.dumps({"sourceSha256": data["sourceSha256"], "revision": data["revision"], "renderer": "Blender 4.2 CPU Cycles", "purpose": data["note"]}, indent=2) + "\n")


if __name__ == "__main__":
    main()
