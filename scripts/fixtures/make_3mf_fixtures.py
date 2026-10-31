"""Writes the hand-made PrusaSlicer 2.9.6-style 3MF test fixtures.

Usage: python3 scripts/fixtures/make_3mf_fixtures.py app/PalmSliceTests/Fixtures

colormix.3mf (ColorMixTests): two 10 mm cubes, 5-tool printer, 0.2 mm layers.
  "blend":    object extruder = 6 (virtual, 1:1 blend of T1/T2).
  "gradient": object extruder = 1, every triangle painted with state 7
              (virtual, auto-range gradient T3 -> T4).

parts.3mf (NativeImportTests): one object, 3-tool printer, two instances
(the second mirrored in X).
  volume 0 "tower":   20 mm cube, printable part
  volume 1 "side":    10 mm cube beside it, printable part, extruder 2
  volume 2 "dense":   modifier over the tower's top half, fill_density 100%
  volume 3 "stripe":  modifier over the tower's bottom 5 mm, extruder 3
"""
import json
import os
import sys
import zipfile

TRIS = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
        (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)]

CONTENT_TYPES = """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/></Types>
"""
RELS = """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/></Relationships>
"""


def box(x0, y0, z0, x1, y1, z1):
    return [(x0, y0, z0), (x1, y0, z0), (x1, y1, z0), (x0, y1, z0),
            (x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)]


def paint(state):
    # Unsplit leaf triangle (TriangleSelector::serialize / get_triangle_as_string).
    if state < 3:
        return "%X" % (state << 2)
    return "%XC" % (state - 3)


def mesh(boxes, painted_state=None):
    """One <mesh> holding several boxes (one volume each, in order)."""
    vs, ts = [], []
    for corners in boxes:
        base = len(vs)
        vs += corners
        ts += [(a + base, b + base, c + base) for a, b, c in TRIS]
    attr = (' slic3rpe:mmu_segmentation="%s"' % paint(painted_state)) if painted_state else ""
    vx = "".join('<vertex x="%g" y="%g" z="%g"/>' % v for v in vs)
    tx = "".join('<triangle v1="%d" v2="%d" v3="%d"%s/>' % (a, b, c, attr) for a, b, c in ts)
    return "<mesh><vertices>%s</vertices><triangles>%s</triangles></mesh>" % (vx, tx)


def model_xml(objects, items):
    res = "".join('<object id="%d" type="model">%s</object>' % (i + 1, m) for i, m in enumerate(objects))
    build = "".join('<item objectid="%d" transform="%s" printable="1"/>' % it for it in items)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02" xmlns:slic3rpe="http://schemas.slic3r.org/3mf/2017/06">
 <metadata name="slic3rpe:Version3mf">1</metadata>
 <metadata name="slic3rpe:MmPaintingVersion">2</metadata>
 <metadata name="Application">PrusaSlicer-2.9.6</metadata>
 <resources>{res}</resources>
 <build>{build}</build>
</model>
"""


def object_config(oid, name, instances, settings, volumes):
    """volumes: (name, type, settings dict); 12 triangles each, in mesh order."""
    out = [f' <object id="{oid}" instances_count="{instances}">',
           f'  <metadata type="object" key="name" value="{name}"/>']
    out += [f'  <metadata type="object" key="{k}" value="{v}"/>' for k, v in settings.items()]
    for i, (vname, vtype, vsettings) in enumerate(volumes):
        out.append(f'  <volume firstid="{i * 12}" lastid="{i * 12 + 11}">')
        out.append(f'   <metadata type="volume" key="name" value="{vname}"/>')
        out.append(f'   <metadata type="volume" key="volume_type" value="{vtype}"/>')
        out.append('   <metadata type="volume" key="matrix" value="1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1"/>')
        out += [f'   <metadata type="volume" key="{k}" value="{v}"/>' for k, v in vsettings.items()]
        out.append('   <mesh edges_fixed="0" degenerate_facets="0" facets_removed="0" facets_reversed="0" backwards_edges="0"/>')
        out.append('  </volume>')
    out.append(' </object>')
    return "\n".join(out)


def project_config(tools, extra):
    colours = ["#FF0000", "#00FF00", "#0000FF", "#FFFF00", "#FFFFFF"][:tools]
    n = lambda v: ",".join([v] * tools)
    cfg = {
        "printer_technology": "FFF",
        "printer_settings_id": "Fixture %dT" % tools,
        "gcode_flavor": "marlin2",
        "bed_shape": "0x0,360x0,360x360,0x360",
        "max_print_height": "360",
        "nozzle_diameter": n("0.4"),
        "extruder_colour": ";".join(colours),
        "filament_colour": ";".join(colours),
        "filament_diameter": n("1.75"),
        "filament_type": ";".join(["PLA"] * tools),
        "temperature": n("215"),
        "first_layer_temperature": n("215"),
        "retract_length": n("0.8"),
        "retract_length_toolchange": n("4"),
        "layer_height": "0.2",
        "first_layer_height": "0.2",
        "perimeters": "2",
        "fill_density": "15%",
        "wipe_tower": "1",
        "wipe_tower_x": "60",
        "wipe_tower_y": "150",
        "skirts": "0",
        "gcode_label_objects": "octoprint",
    }
    cfg.update(extra)
    return "; generated by make_3mf_fixtures.py\n\n" + "".join("; %s = %s\n" % kv for kv in sorted(cfg.items())), colours


def write(path, model, model_config, slic3r_config, full_spectrum=None):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", CONTENT_TYPES)
        z.writestr("_rels/.rels", RELS)
        z.writestr("3D/3dmodel.model", model)
        z.writestr("Metadata/Slic3r_PE.config", slic3r_config)
        z.writestr("Metadata/Slic3r_PE_model.config",
                   '<?xml version="1.0" encoding="UTF-8"?>\n<config>\n' + model_config + "\n</config>\n")
        if full_spectrum:
            z.writestr("Metadata/Prusa_Slicer_full_spectrum.json", json.dumps(full_spectrum, indent=4))


def colormix(path):
    cube = box(-5, -5, -5, 5, 5, 5)
    model = model_xml([mesh([cube]), mesh([cube], painted_state=7)],
                      [(1, "1 0 0 0 1 0 0 0 1 150 180 5"), (2, "1 0 0 0 1 0 0 0 1 200 180 5")])
    part = [("cube", "ModelPart", {})]
    config = (object_config(1, "blend", 1, {"extruder": 6}, part) + "\n"
              + object_config(2, "gradient", 1, {"extruder": 1}, part))
    slic3r, colours = project_config(5, {})
    full_spectrum = {
        "version": 1,
        "physical_extruders": [{"id": i + 1, "color": c} for i, c in enumerate(colours)],
        "virtual_extruders": [
            {"id": 6, "kind": "fullspectrum",
             "components": [{"extruder": 1, "ratio": 0.5}, {"extruder": 2, "ratio": 0.5}]},
            {"id": 7, "kind": "gradient",
             "components": [{"extruder": 3, "position": 0.0}, {"extruder": 4, "position": 1.0}]},
        ],
    }
    write(path, model, config, slic3r, full_spectrum)


def parts(path):
    boxes = [box(-10, -10, 0, 10, 10, 20),     # tower
             box(12, -5, 0, 22, 5, 10),        # side
             box(-11, -11, 10, 11, 11, 21),    # dense (modifier)
             box(-11, -11, -1, 11, 11, 5)]     # stripe (modifier)
    model = model_xml([mesh(boxes)],
                      [(1, "1 0 0 0 1 0 0 0 1 100 100 0"),
                       (1, "-1 0 0 0 1 0 0 0 1 200 100 0")])   # mirrored in X
    config = object_config(1, "assembly", 2, {}, [
        ("tower", "ModelPart", {}),
        ("side", "ModelPart", {"extruder": 2}),
        ("dense", "ParameterModifier", {"fill_density": "100%"}),
        ("stripe", "ParameterModifier", {"extruder": 3}),
    ])
    slic3r, _ = project_config(3, {})
    write(path, model, config, slic3r)


out_dir = sys.argv[1]
colormix(os.path.join(out_dir, "colormix.3mf"))
parts(os.path.join(out_dir, "parts.3mf"))
