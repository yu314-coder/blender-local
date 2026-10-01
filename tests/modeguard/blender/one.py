import bpy, sys, pathlib, importlib.util
sys.dont_write_bytecode = True
# The UV menu's rows call the app's own module, as they do on device. Loaded by
# path: putting the site directory on sys.path would shadow bpy with the shim.
_site = pathlib.Path(__file__).resolve().parents[3] / "Resources/python/site"
_spec = importlib.util.spec_from_file_location("_blenderkit_uv", _site / "_blenderkit_uv.py")
sys.modules["_blenderkit_uv"] = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sys.modules["_blenderkit_uv"])
calls, want = sys.argv[-2], sys.argv[-1]
body = next(b.strip().split("\n", 1)[1] for b in open(calls).read().split("#--")
            if b.strip().startswith("### " + want + "\n"))
for start in ["OBJECT", "EDIT", "SCULPT"]:
    bpy.ops.wm.read_homefile(use_empty=True)
    bpy.ops.mesh.primitive_cube_add(size=2, location=(0, 0, 0))
    bpy.context.object.name = "Cube"
    bpy.ops.object.mode_set(mode='EDIT'); bpy.ops.mesh.select_all(action='SELECT')
    if want.startswith("uv.unwrap"):
        # An unwrap needs seams to open a closed cube along: without them
        # Blender solves no island and the row refuses, UVs put back
        # (_blenderkit_uv). Smart UV Project's island borders are seams enough.
        bpy.ops.uv.smart_project()
        bpy.ops.uv.seams_from_islands()
    bpy.ops.object.mode_set(mode=start)
    try:
        exec(compile(body, "<ui>", "exec"), {"bpy": bpy})
        ran = "ok"
    except Exception as e:
        ran = "FAIL:" + str(e)[:40]
    # An operator that deletes the object takes its mode with it: there is no
    # edit mode to return to on an object that no longer exists.
    exists = bpy.data.objects.get("Cube") is not None
    ob = bpy.context.view_layer.objects.active
    after = getattr(ob, "mode", "OBJECT") if ob else "OBJECT"
    print(f"R|{start}|{ran}|{after}|{exists}", flush=True)
