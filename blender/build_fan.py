import math
from pathlib import Path

import bpy
from mathutils import Vector


ROOT_DIR = Path(__file__).resolve().parents[1]
ASSET_DIR = ROOT_DIR / "Resources" / "assets"
GLB_PATH = ASSET_DIR / "wind-nest-fan.glb"
PREVIEW_PATH = ROOT_DIR / "docs" / "fan-preview.png"


def reset_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (
        bpy.data.meshes,
        bpy.data.curves,
        bpy.data.materials,
        bpy.data.cameras,
        bpy.data.lights,
    ):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)


def material(
    name,
    color,
    metallic=0.0,
    roughness=0.4,
    alpha=1.0,
    emission=None,
    emission_strength=0.0,
):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    mat.diffuse_color = (*color, alpha)
    mat.metallic = metallic
    mat.roughness = roughness
    surface = next(
        (
            node
            for node in mat.node_tree.nodes
            if node.type == "BSDF_PRINCIPLED"
        ),
        None,
    )
    if surface is None:
        surface = mat.node_tree.nodes.new("ShaderNodeBsdfPrincipled")
        output = next(
            (
                node
                for node in mat.node_tree.nodes
                if node.type == "OUTPUT_MATERIAL"
            ),
            None,
        )
        if output is None:
            output = mat.node_tree.nodes.new("ShaderNodeOutputMaterial")
        mat.node_tree.links.new(surface.outputs["BSDF"], output.inputs["Surface"])
    surface.inputs["Base Color"].default_value = (*color, 1.0)
    surface.inputs["Metallic"].default_value = metallic
    surface.inputs["Roughness"].default_value = roughness
    surface.inputs["Alpha"].default_value = alpha
    if emission:
        surface.inputs["Emission Color"].default_value = (*emission, 1.0)
        surface.inputs["Emission Strength"].default_value = emission_strength
    if alpha < 1.0:
        mat.surface_render_method = "DITHERED"
    return mat


def smooth(obj):
    if obj.type == "MESH":
        for polygon in obj.data.polygons:
            polygon.use_smooth = True


def bevel(obj, width=0.04, segments=3):
    modifier = obj.modifiers.new("Precision edge", "BEVEL")
    modifier.width = width
    modifier.segments = segments
    modifier.limit_method = "ANGLE"


def parent_keep_transform(obj, parent):
    obj.parent = parent
    obj.matrix_parent_inverse = parent.matrix_world.inverted()


def add_cylinder(
    name,
    radius,
    depth,
    location,
    material_ref,
    rotation=(0.0, 0.0, 0.0),
    scale=(1.0, 1.0, 1.0),
    parent=None,
    bevel_width=0.0,
    vertices=64,
):
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=vertices,
        radius=radius,
        depth=depth,
        location=location,
        rotation=rotation,
    )
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    obj.data.materials.append(material_ref)
    smooth(obj)
    if bevel_width:
        bevel(obj, bevel_width, 3)
    if parent:
        parent_keep_transform(obj, parent)
    return obj


def add_uv_sphere(
    name,
    radius,
    location,
    material_ref,
    scale=(1.0, 1.0, 1.0),
    parent=None,
):
    bpy.ops.mesh.primitive_uv_sphere_add(
        segments=64,
        ring_count=32,
        radius=radius,
        location=location,
    )
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    obj.data.materials.append(material_ref)
    smooth(obj)
    if parent:
        parent_keep_transform(obj, parent)
    return obj


def add_torus(
    name,
    major_radius,
    minor_radius,
    location,
    material_ref,
    rotation=(math.pi / 2, 0.0, 0.0),
    parent=None,
):
    bpy.ops.mesh.primitive_torus_add(
        align="WORLD",
        major_segments=96,
        minor_segments=10,
        location=location,
        rotation=rotation,
        major_radius=major_radius,
        minor_radius=minor_radius,
    )
    obj = bpy.context.object
    obj.name = name
    obj.data.materials.append(material_ref)
    smooth(obj)
    if parent:
        parent_keep_transform(obj, parent)
    return obj


def add_rod(name, start, end, radius, material_ref, parent=None):
    start_v = Vector(start)
    end_v = Vector(end)
    direction = end_v - start_v
    midpoint = (start_v + end_v) * 0.5
    obj = add_cylinder(
        name,
        radius,
        direction.length,
        midpoint,
        material_ref,
        vertices=20,
    )
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = direction.to_track_quat("Z", "Y")
    if parent:
        parent_keep_transform(obj, parent)
    return obj


def add_blade(name, angle, material_ref, rotor):
    profile = [
        (0.16, -0.05),
        (0.3, -0.2),
        (0.56, -0.31),
        (0.9, -0.22),
        (1.0, 0.0),
        (0.86, 0.22),
        (0.5, 0.31),
        (0.21, 0.14),
    ]
    vertices = []
    for x, z in profile:
        front_y = -0.19 + x * 0.075
        vertices.append((x, front_y, z))
    for x, z in profile:
        back_y = -0.11 + x * 0.045
        vertices.append((x, back_y, z))
    count = len(profile)
    faces = [
        tuple(range(count)),
        tuple(range(count, count * 2)),
    ]
    for index in range(count):
        next_index = (index + 1) % count
        faces.append(
            (
                index,
                next_index,
                count + next_index,
                count + index,
            )
        )

    mesh = bpy.data.meshes.new(f"{name}Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    blade = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(blade)
    blade.data.materials.append(material_ref)
    blade.rotation_euler[1] = angle
    bevel(blade, 0.025, 3)
    smooth(blade)
    parent_keep_transform(blade, rotor)
    return blade


def add_textured_ring_details(parent, material_ref):
    for ring_index, z in enumerate((0.04, 0.075, 0.11)):
        add_torus(
            f"Base trim {ring_index + 1:02d}",
            0.83 - ring_index * 0.08,
            0.009,
            (0.0, 0.0, z),
            material_ref,
            rotation=(0.0, 0.0, 0.0),
            parent=parent,
        )


def build_fan():
    enamel = material(
        "Moon Enamel",
        (0.14, 0.2, 0.185),
        metallic=0.58,
        roughness=0.31,
    )
    enamel_light = material(
        "Edge Enamel",
        (0.5, 0.57, 0.54),
        metallic=0.55,
        roughness=0.24,
    )
    chrome = material(
        "Brushed Chrome",
        (0.43, 0.5, 0.48),
        metallic=0.92,
        roughness=0.2,
    )
    chrome_dark = material(
        "Dark Chrome",
        (0.14, 0.2, 0.19),
        metallic=0.88,
        roughness=0.22,
    )
    motor_material = material(
        "Motor Housing",
        (0.08, 0.12, 0.115),
        metallic=0.66,
        roughness=0.27,
    )
    blade_material = material(
        "Celadon Blades",
        (0.17, 0.38, 0.34),
        metallic=0.42,
        roughness=0.24,
        alpha=0.96,
    )
    rubber = material(
        "Rubber",
        (0.025, 0.04, 0.038),
        metallic=0.0,
        roughness=0.64,
    )
    led_material = material(
        "Status Light",
        (0.25, 0.72, 0.64),
        metallic=0.05,
        roughness=0.28,
        emission=(0.25, 0.9, 0.76),
        emission_strength=3.5,
    )

    root = bpy.data.objects.new("WindNestFan", None)
    bpy.context.collection.objects.link(root)

    add_cylinder(
        "Base",
        1.04,
        0.18,
        (0.0, 0.0, 0.09),
        enamel,
        scale=(1.0, 0.65, 1.0),
        parent=root,
        bevel_width=0.055,
        vertices=96,
    )
    add_cylinder(
        "Base inset",
        0.8,
        0.045,
        (0.0, -0.02, 0.185),
        chrome_dark,
        scale=(1.0, 0.62, 1.0),
        parent=root,
        bevel_width=0.016,
        vertices=96,
    )
    add_textured_ring_details(root, chrome)
    add_cylinder(
        "Stem outer",
        0.115,
        1.06,
        (0.0, 0.0, 0.76),
        chrome,
        parent=root,
        bevel_width=0.018,
        vertices=64,
    )
    add_cylinder(
        "Stem highlight",
        0.038,
        1.0,
        (-0.045, -0.085, 0.76),
        enamel_light,
        scale=(0.34, 0.16, 1.0),
        parent=root,
        vertices=32,
    )
    add_cylinder(
        "Stem collar lower",
        0.18,
        0.12,
        (0.0, 0.0, 0.245),
        enamel,
        parent=root,
        bevel_width=0.035,
    )
    add_cylinder(
        "Stem collar upper",
        0.18,
        0.12,
        (0.0, 0.0, 1.29),
        enamel,
        parent=root,
        bevel_width=0.035,
    )
    add_cylinder(
        "Power recess",
        0.125,
        0.03,
        (0.0, -0.67, 0.17),
        rubber,
        rotation=(math.pi / 2, 0.0, 0.0),
        parent=root,
        vertices=48,
    )
    add_uv_sphere(
        "Power LED",
        0.032,
        (0.0, -0.698, 0.175),
        led_material,
        scale=(1.0, 0.45, 1.0),
        parent=root,
    )

    yaw_pivot = bpy.data.objects.new("YawPivot", None)
    yaw_pivot.location = (0.0, 0.0, 1.35)
    bpy.context.collection.objects.link(yaw_pivot)
    parent_keep_transform(yaw_pivot, root)

    add_cylinder(
        "Yaw bearing",
        0.24,
        0.22,
        (0.0, 0.0, 1.36),
        chrome_dark,
        parent=yaw_pivot,
        bevel_width=0.04,
    )
    add_cylinder(
        "Yaw cap",
        0.19,
        0.1,
        (0.0, 0.0, 1.5),
        enamel_light,
        parent=yaw_pivot,
        bevel_width=0.025,
    )

    # The two arms are deliberately asymmetric in depth to read as real hardware
    # when the head rotates sideways.
    add_rod(
        "Yoke left",
        (-0.16, 0.04, 1.49),
        (-0.94, 0.07, 2.18),
        0.07,
        chrome,
        yaw_pivot,
    )
    add_rod(
        "Yoke right",
        (0.16, 0.04, 1.49),
        (0.94, 0.07, 2.18),
        0.07,
        chrome,
        yaw_pivot,
    )

    tilt_pivot = bpy.data.objects.new("TiltPivot", None)
    tilt_pivot.location = (0.0, 0.0, 2.2)
    bpy.context.collection.objects.link(tilt_pivot)
    parent_keep_transform(tilt_pivot, yaw_pivot)

    for side in (-1, 1):
        add_cylinder(
            f"Tilt bearing {'left' if side < 0 else 'right'}",
            0.14,
            0.11,
            (side * 0.965, 0.03, 2.2),
            enamel_light,
            rotation=(0.0, math.pi / 2, 0.0),
            parent=tilt_pivot,
            bevel_width=0.025,
            vertices=48,
        )
        add_cylinder(
            f"Tilt screw {'left' if side < 0 else 'right'}",
            0.055,
            0.12,
            (side * 1.025, 0.03, 2.2),
            chrome_dark,
            rotation=(0.0, math.pi / 2, 0.0),
            parent=tilt_pivot,
            bevel_width=0.012,
            vertices=32,
        )

    add_cylinder(
        "Rear motor",
        0.49,
        0.83,
        (0.0, 0.35, 2.2),
        motor_material,
        rotation=(math.pi / 2, 0.0, 0.0),
        parent=tilt_pivot,
        bevel_width=0.08,
        vertices=64,
    )
    add_uv_sphere(
        "Rear motor cap",
        0.52,
        (0.0, 0.68, 2.2),
        enamel,
        scale=(1.0, 0.48, 1.0),
        parent=tilt_pivot,
    )
    add_cylinder(
        "Motor trim",
        0.53,
        0.055,
        (0.0, -0.045, 2.2),
        chrome,
        rotation=(math.pi / 2, 0.0, 0.0),
        parent=tilt_pivot,
        vertices=64,
    )

    rotor = bpy.data.objects.new("BladeRotor", None)
    rotor.location = (0.0, 0.0, 2.2)
    bpy.context.collection.objects.link(rotor)
    parent_keep_transform(rotor, tilt_pivot)
    for blade_index in range(4):
        add_blade(
            f"Blade {blade_index + 1:02d}",
            (math.tau * blade_index) / 4.0,
            blade_material,
            rotor,
        )

    add_cylinder(
        "Rotor hub",
        0.245,
        0.31,
        (0.0, -0.17, 2.2),
        chrome,
        rotation=(math.pi / 2, 0.0, 0.0),
        parent=tilt_pivot,
        bevel_width=0.04,
        vertices=64,
    )
    add_uv_sphere(
        "Front badge",
        0.19,
        (0.0, -0.355, 2.2),
        enamel_light,
        scale=(1.0, 0.38, 1.0),
        parent=tilt_pivot,
    )
    add_torus(
        "Front badge trim",
        0.135,
        0.012,
        (0.0, -0.425, 2.2),
        chrome_dark,
        parent=tilt_pivot,
    )

    cage_center = (0.0, -0.28, 2.2)
    for ring_index, radius in enumerate((0.32, 0.58, 0.81, 1.04)):
        add_torus(
            f"Front cage ring {ring_index + 1:02d}",
            radius,
            0.014 if radius < 1.0 else 0.028,
            cage_center,
            chrome,
            parent=tilt_pivot,
        )
    add_torus(
        "Rear cage rim",
        1.03,
        0.024,
        (0.0, 0.12, 2.2),
        chrome_dark,
        parent=tilt_pivot,
    )

    spoke_count = 24
    for spoke_index in range(spoke_count):
        angle = math.tau * spoke_index / spoke_count
        inner_radius = 0.25
        outer_radius = 1.02
        start = (
            math.cos(angle) * inner_radius,
            -0.305,
            2.2 + math.sin(angle) * inner_radius,
        )
        end = (
            math.cos(angle) * outer_radius,
            -0.285,
            2.2 + math.sin(angle) * outer_radius,
        )
        add_rod(
            f"Front spoke {spoke_index + 1:02d}",
            start,
            end,
            0.009,
            chrome,
            tilt_pivot,
        )

    for connector_index in range(12):
        angle = math.tau * connector_index / 12
        x = math.cos(angle) * 1.035
        z = 2.2 + math.sin(angle) * 1.035
        add_rod(
            f"Cage depth connector {connector_index + 1:02d}",
            (x, -0.28, z),
            (x, 0.12, z),
            0.012,
            chrome_dark,
            tilt_pivot,
        )

    # Small rear vents make side views feel manufactured instead of hollow.
    for vent_index in range(7):
        angle = (vent_index - 3) * 0.13
        add_rod(
            f"Rear vent {vent_index + 1:02d}",
            (-0.3, 0.705, 2.2 + angle),
            (0.3, 0.705, 2.2 + angle),
            0.012,
            chrome_dark,
            tilt_pivot,
        )

    return root


def export_model(root):
    ASSET_DIR.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    root.select_set(True)
    for child in root.children_recursive:
        child.select_set(True)
    bpy.context.view_layer.objects.active = root
    bpy.ops.export_scene.gltf(
        filepath=str(GLB_PATH),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_cameras=False,
        export_lights=False,
        export_materials="EXPORT",
        export_yup=True,
    )


def add_preview_environment():
    def area_light(name, location, energy, color, size):
        data = bpy.data.lights.new(name, "AREA")
        data.energy = energy
        data.color = color
        data.shape = "DISK"
        data.size = size
        obj = bpy.data.objects.new(name, data)
        obj.location = location
        bpy.context.collection.objects.link(obj)
        direction = Vector((0.0, 0.0, 1.55)) - obj.location
        obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()

    area_light(
        "Moon key",
        (-3.8, -4.5, 5.2),
        860,
        (0.54, 0.78, 1.0),
        4.0,
    )
    area_light(
        "Warm rim",
        (4.2, 0.8, 3.8),
        620,
        (1.0, 0.52, 0.28),
        3.0,
    )
    area_light(
        "Soft fill",
        (0.0, -3.2, 1.8),
        360,
        (0.56, 0.9, 0.82),
        2.2,
    )

    camera_data = bpy.data.cameras.new("Preview Camera")
    camera = bpy.data.objects.new("Preview Camera", camera_data)
    bpy.context.collection.objects.link(camera)
    camera.location = (4.8, -7.7, 3.35)
    target = Vector((0.0, 0.0, 1.55))
    camera.rotation_euler = (target - camera.location).to_track_quat(
        "-Z", "Y"
    ).to_euler()
    camera_data.lens = 62
    bpy.context.scene.camera = camera


def render_preview():
    PREVIEW_PATH.parent.mkdir(parents=True, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 1000
    scene.render.resolution_y = 1000
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = str(PREVIEW_PATH)
    scene.render.film_transparent = True
    scene.render.image_settings.color_mode = "RGBA"
    scene.view_settings.look = "AgX - Medium High Contrast"
    scene.world.color = (0.005, 0.008, 0.009)
    bpy.ops.wm.save_as_mainfile(filepath=str(ASSET_DIR / "wind-nest-fan.blend"))
    bpy.ops.render.render(write_still=True)


reset_scene()
fan_root = build_fan()
export_model(fan_root)
add_preview_environment()
render_preview()
print(f"GLB: {GLB_PATH}")
print(f"Preview: {PREVIEW_PATH}")
