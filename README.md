# Blender Local

**Current implementation:** see the [September 10 upgrade notes](docs/blender-local.md#september-10-upgrade) for the two-tab UI, live Blender-aware assistance, RNA controls, real `.blend` persistence and remaining backend limitations. Several historical feature descriptions below predate this integration.

Bringing Blender's interface to iPad / iOS, on top of the `bpy` build already
cross-compiled in [python-ios-lib](https://github.com/yu314-coder/python-ios-lib).

> Status: **Route B implemented as a running app**, with real CPython 3.14
> embedded. Builds and runs on iPad; both workspaces verified in the simulator.
> Fully offline — see [What works today](#what-works-today).

**[docs/blender-local.md](docs/blender-local.md)** is the reference for the app
itself: where the files are, how the pieces fit, how to build and test it
without a device, and the landmines worth knowing before touching any of it.

---

## The finding that shapes this project

The `bpy` currently shipping on iOS is a **headless build**. Probing the
222 MB binary in the CodeBench bundle:

| Symbol group | Hits | Meaning |
|---|---:|---|
| `GHOST_` | 38 | windowing abstraction present |
| `wm_event` | 37 | event plumbing present |
| `WM_operator` | 11 | operator system present |
| `ED_screen` / `ED_space` | 2 / 4 | screen/space stubs only |
| **`UI_block`** | **0** | **interface layer absent** |
| **`UI_but`** | **0** | **widgets absent** |
| **`screen_draw`** | **0** | **UI drawing absent** |

Blender draws its own interface — every button, panel and header is rendered by
`source/blender/editors/interface` on top of the GPU module. Those symbols are
not in this build, so **Blender's real UI cannot simply be switched on.** That
rules out the cheapest version of "same UI" and forces an explicit choice.

What *does* already work on iOS (device-verified, see
`docs/bpy_ios_metal_gpu_backend` notes in python-ios-lib):

- the `gpu` module — `gpu.init()`, `GPUOffScreen`, GLSL→MSL translation
- **Eevee rendering** through the Metal backend
- Cycles (Metal) after `refresh_devices()`
- USD import/export, MaterialX, audio, glTF with Draco/MeshOptimizer

So the *engine* is there. Only the *interface* is missing.

---

## Two routes

### Route A — compile Blender's real UI (literal "same UI")

Build Blender with `editors/interface` + the window manager, add a **windowed**
GHOST backend for iOS (today only an offscreen Metal factory exists), and
translate touch into Blender events.

- ✅ Pixel-accurate Blender, all editors, add-ons work unchanged
- ❌ Very large: GHOST windowing, event loop, WM lifecycle, a build far bigger
  than the current 222 MB, and an interface designed for a 3-button mouse +
  keyboard on a device that has neither
- ❌ Blender is **GPL** — shipping its UI means the app is GPL, which conflicts
  with App Store distribution terms in the well-known way. **This needs a
  licensing answer before any code is written.**

### Route B — native iOS interface driving headless `bpy` (recommended)

Rebuild Blender's *look and interaction model* in Swift (Metal viewport +
SwiftUI/UIKit chrome), calling the existing headless `bpy` for scene state,
modifiers, and rendering.

- ✅ Works with the bpy that already ships — no Blender rebuild
- ✅ Touch-native: gestures instead of mouse+numpad
- ✅ Only *our* code is distributed; `bpy` stays a Python module the user drives
- ❌ Every panel is hand-built; add-ons with UI won't render
- ❌ "Similar", never identical

**Route B is what is built.** See below.

---

## What works today

A native SwiftUI + Metal app with the two workspaces Blender itself uses for
this split — the tabs are Blender workspace tabs in the topbar, not iOS tabs.

**Layout (tools)** — 3D viewport with **Solid, Wireframe and Material Preview**
shading, the floor
grid with red X and green Y axis lines, and an orange silhouette outline on the
active object. Toolbar on the left, Outliner over Properties on the right,
status bar beneath. Add / Select / Object menus create, select and delete
objects; the Properties and sidebar transform fields drag like Blender's number
fields. **Move, Rotate and Scale work**: pick one in the toolbar and a drag
transforms the selection instead of orbiting, exactly as Blender's tools do.
Properties carries a **modifier stack** (Subdivision Surface, Array, Mirror)
and a viewport-display colour.

**Apple Pencil** — input is split by what is touching the screen rather than by
a mode: **finger navigates, Pencil acts**. A finger orbits, pans and pinches;
the Pencil runs the active tool, and **pressure scales the transform** so light
contact is precise and firm contact is fast. Hovering highlights the object
under the tip before committing, and a barrel double-tap cycles the toolbar
(respecting the system Pencil setting). Both hands work at once — orbit with a
finger while the Pencil stays on the model.

**Undo and persistence** — Edit > Undo/Redo, one step per operator exactly as
Blender records them, 64 deep. The scene autosaves when the app leaves the
foreground and restores on launch, and File > Save / Open Recent keep named
scenes as `.bkit` JSON documents.

**Scripting (bpy)** — the same live scene in a compact viewport, the Info log,
a Python console, and a text editor with a line-number gutter and Run Script.
The console is **real CPython 3.14**, embedded in the app: loops, the stdlib,
f-strings, tracebacks. Scripts drive the Metal viewport through a `bpy`-shaped
module.

Both tabs act on one scene, so switching never loses work. Every action taken
with the tools is logged as the Python that performs it, exactly as Blender's
Info editor does — which is how the two tabs stay tied together.

Navigation maps Blender's verbs onto touch: one finger orbits, two fingers pan,
pinch dollies, tap selects. The camera is a Z-up turntable with Blender's
default 50 mm lens (39.6° vertical FOV).

### The theme is extracted, not eyeballed

Every colour comes from Blender's own
`release/datafiles/userdef/userdef_default_theme.c` — viewport `#3D3D3D`,
topbar `#181818`, outliner `#282828`, widgets `#545454`, selection orange
`#ED5700`, active `#FFA028`. Re-extract rather than hand-tune.

### Everything runs offline

The interpreter is staged into the app bundle at build time — stdlib, all 67
extension modules, and the `bpy` shim. `PYTHONHOME` never leaves the bundle,
and there is no networking code anywhere in `Sources/`. About 28 MB of a 35 MB
app. See [docs/bpy-embedding.md](docs/bpy-embedding.md).

### What is not real yet

- **The `bpy` module is BlenderKit's own, not Blender's.** It covers what
  scripts actually reach for — `bpy.ops.mesh.primitive_*_add`,
  `bpy.ops.transform.*`, `bpy.data.objects[…]` (including `remove`, rename and
  the `.001` suffix rule), `.location` / `.rotation_euler` / `.scale` /
  `.dimensions` / `.matrix_world` / `.hide_viewport`, `select_get` /
  `select_set`, `bpy.context.object` and `selected_objects`, `bpy.app.version`
  — plus a real **`mathutils`** (Vector, Euler, Quaternion, Matrix). Modifiers,
  node trees, add-ons and animation are not there, and those corners raise
  rather than quietly returning something wrong. Swapping in the real 432 MB
  `bpy` is documented.
- **No edit mode, modifiers, materials or animation.** Wireframe, Material Preview and Rendered are shown
  disabled rather than wired to nothing.
- **Object mode only**, and no timeline (a timeline with no animation system
  behind it would be a dead control). Rendered shading stays disabled in the
  header for the same reason — it needs a render engine.
- **Three modifiers, not Blender's fifty.** Subdivision approximates
  Catmull-Clark with a 1-to-4 split plus Laplacian smoothing, since the meshes
  are triangulated; it rounds a cube the way Blender's does, but it is not the
  same algorithm.

### The eleven workspaces

Blender's workspaces are not layouts — each is a different engine. Their editor
arrangements came from Blender itself (`bpy.data.workspaces`), and so did the
honest assessment of what each needs:

| Workspace | Needs | Here |
|---|---|---|
| Layout | object mode | ✅ |
| Scripting | a Python interpreter | ✅ |
| **Modeling** | edit mode, mesh operators | ✅ vertex/edge/face select, extrude, inset, subdivide, delete |
| **UV Editing** | unwrapping + a UV editor | ✅ cube/sphere/cylinder projection, UV editor with stretch readout |
| **Animation** | keyframes, F-curves, dope sheet | ✅ transform keys, constant/linear/bezier, dope sheet |
| **Shading** | shader node graph + PBR | ✅ Principled BSDF → Material Output, Cook-Torrance GGX viewport |
| **Sculpting** | brush engine, dynamic topology | ✅ six brushes; no topology added — subdivide first |
| **Texture Paint** | image buffers + UVs | ✅ paint into a 1024² texture, sampled in the viewport |
| **Rendering** | a render engine | ✅ offscreen PBR render to an image editor — rasterised, no ray tracing |
| **Compositing** | image node evaluation | ✅ chain of Bright/Contrast, Hue/Sat, Blur, Glare, Invert, Mix over the render |
| **Geometry Nodes** | geometry node evaluation | ✅ chain of Subdivide, Transform, Set Position, Extrude, Scale + spreadsheet |

All eleven now do something real. What they are *not* is Blender's depth: the
compositor runs a linear chain over one RGBA8 buffer rather than a tiled float
evaluator over render passes; geometry nodes evaluate a chain of mesh
operations rather than a field graph with attributes and instancing; the
renderer rasterises rather than ray-traces. Each entry above says where its
limit is.

### About "all of Blender"

Blender is ~2.5M lines of C/C++ built over 30 years. Reimplementing sculpting,
geometry nodes, Cycles, grease pencil, physics and compositing in Swift is not
a scope question — it is not achievable, and this README will not pretend
otherwise.

The real route to all of it is **Route A applied to the engine only**: link the
`bpy` already cross-compiled in python-ios-lib, which has the Metal backend,
Eevee and Cycles-Metal device-verified. That is genuinely every Blender feature,
with no reimplementation. What it costs — 432 MB, the scene-mirroring work, and
the GPL question — is set out in
[docs/bpy-embedding.md](docs/bpy-embedding.md).

### Conformance

`tests/bpy_conformance.py` exercises the shim the way Blender scripts use
`bpy`. Run it against a booted simulator with:

```
./scripts/run-conformance.sh
```

It currently reports **19 pass, 1 fail** — the failure being `keyframe_insert`,
which raises on purpose.

## Build

```
./scripts/vendor-python.sh /path/to/python-ios-lib
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig   # set your team
xcodegen generate
open BlenderLocal.xcodeproj
```

Requires iOS 17. The Python xcframework is ~124 MB, so it is staged into
`Vendor/` rather than committed; the project file is generated from
`project.yml` and is likewise not checked in.

Your own account details stay out of the repository. Each lives in a file git
ignores, with a committed `.example` beside it:

- `Config/Signing.local.xcconfig`: your development team.
- `ExportOptions.plist`: the team again, for App Store exports.
- `scripts/local.env`: your App Store Connect key and issuer IDs, for
  `push-appstore.sh`, and a device, signing identity and profile, for
  `deploy-device.sh`.

The device build bundles Blender's real `bpy` from
[python-ios-lib](https://github.com/yu314-coder/python-ios-lib)
(`scripts/stage-blender.sh`). Blender is GPL-2.0-or-later. This repository's own
code is MIT (`LICENSE`); `NOTICE.md` says what that covers.

---

## Layout

```
Sources/BlenderKitBridge/   Swift <-> bpy: scene graph, ops, render calls
Sources/BlenderKitUI/       Metal viewport + Blender-style chrome
Resources/                  icons, theme (Blender dark theme values)
docs/                       design notes, UI reference captures
research/                   probes, symbol dumps, feasibility experiments
```

## Open questions (still unanswered)

1. **Licensing.** Blender is GPL. Route A almost certainly cannot ship on the
   App Store. Route B needs a clear line: `bpy` as a user-invoked interpreter
   module vs. linked application code. This is the single biggest risk.
2. **Relationship to CodeBench.** A second app sharing the same ~432 MB Blender
   payload invites Guideline 4.3(a) ("multiple similar apps") — an issue this
   account has already been cited for. Sequence this *after* CodeBench's review
   status resolves.
3. **Scope of v1.** Built: viewport navigation + object transform. Next:
   material preview + Eevee render. Not: node editors, sculpting, simulation.
