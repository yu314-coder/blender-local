# Blender Local — the app

## September 10: simplified workspaces and Monaco

Scripting now contains only the editor, console and showcase, with script file,
Save and Run/Stop controls. The separate Code Help / Look Up panel is removed.
The editor is the actual bundled Monaco engine in a WKWebView. It runs offline
and provides Python highlighting, completion, folding, Find/Replace, operator
signature help and hover descriptions. Blender member names and operator
parameters come from a runtime snapshot; no Python query runs while typing.
Import aliases and simple assignments are inferred locally. This is coding
assistance, not an LLM agent or a complete Python language server.

Native draft notifications are coalesced and disk autosave is debounced by one
second, on a utility task. Monaco owns the editing buffer and undo history;
SwiftUI updates do not replace its model on each edit. Run reads the current
Monaco buffer directly. Draft recovery now prefers the latest unsaved draft.
Enter inserts a new line; Tab accepts a completion.

3D View opens with a full-size viewport and one row: Add, Select, Move, Rotate,
Scale, Scene and More. There is no always-open property column, tool-settings
row or timeline. Scene, object details, animation, rendering and the operator
catalogue are presented on demand. The global bar contains File and the two
workspace choices. Existing backend limitations listed below still apply.

Monaco assets are staged by `scripts/stage-python.sh` from
`MONACO_ROOT` (default `/Volumes/D/OfflinAi/Monaco`), alongside the existing
Python dependency. The build fails if they are missing. Its license ships in
the bundle. Editor HTML, message handling and local completion providers live
in `ScriptEditorView.swift`; the former native editor remains available to
other callers but Scripting uses `MonacoScriptEditor`.

Validation includes a simulator stress test of 200 edits in a 20,000-line Monaco
model, cached Blender completion, keyboard entry followed by Run, visible
console output and cube showcase geometry. Real Blender tests check the
metadata snapshot against RNA. Simulator timings do not establish physical
iPad keyboard or GPU performance; physical iPad verification is still
needed.

## Earlier September 10 upgrade (historical)


The current app keeps two workspaces, **Scripting** and **3D View**. This section
supersedes older feature counts and persistence descriptions below.

### Scripting

- Code Help checks Python syntax without executing the draft and displays
  documentation and operator parameters from the installed Blender build.
- Completion resolves straight-line bpy imports and aliases in an unexecuted
  draft, such as `import bpy as B; obj = B.context.object`, and offers RNA keyword
  arguments inside operator calls. It does not infer arbitrary factory calls or
  run the draft to discover types.
- Live lookups are debounced, disabled while a script is running, and do not
  mirror or log the scene. UIKit Find/Replace is enabled; syntax formatting
  preserves the scroll offset and does not overwrite marked composition text.
- Run switches to console output. Stop requests a cooperative KeyboardInterrupt
  at a Python trace boundary. A native Blender call must return before it can
  stop; this is not a hard cancellation API for a render or simulation.
- Divider dragging now applies incremental deltas, rather than repeatedly
  adding the entire cumulative drag distance.

This is local, runtime-aware coding assistance. There is no configured
language-model service or conversational script-generation agent.

### 3D View

- The toolbar started with Essentials, with Mesh, Sculpt, Paint and All in its
  category menu. That toolbar (`ToolShelf`) was later replaced by the 3D View's
  own bar in `LayoutWorkspace`, and its code was removed on 2026-09-17. The
  inspector width is resizable.
- Tool search discovers every `bpy.ops` namespace, not a fixed subset. Selecting
  a result opens an RNA parameter form, shows its description and current poll
  status, and executes explicit values with EXEC_DEFAULT. CANCELLED and
  RUNNING_MODAL are surfaced as incomplete operations.
- The Blender Data inspector navigates actual scene datablocks, collections and
  pointers, and commits scalar, enum and array values to bpy. Datablock pickers
  can assign existing materials, parents, cameras and other RNA pointers.
  Read-only properties remain read-only. Very large collections show the first
  500 entries; scripts can access the rest.
- Open and Save use `.blend` on the real backend. File import/export covers OBJ,
  glTF/GLB, USD, STL, PLY, FBX and Alembic using the installed operators. Sharing
  the saved file uses the system share sheet. Formats with external texture or
  buffer files still require access to those resources; a single-file picker
  does not grant access to an entire neighboring directory.
- Rendering on the real backend calls Blender's Cycles, Eevee or Workbench and
  loads the PNG result into the image editor. It goes through the scene camera,
  or through the 3D View itself, and saves to Documents/Renders. The simulator
  retains the native preview renderer.
- Timeline frame changes and keyframe insertion/deletion reach real bpy.
- The viewport uses 32-bit indices. Dense meshes are no longer rejected at
  65,535 vertices. A 10-million-vertex per-object memory guard remains.
- Evaluated curves/text can produce visible geometry. Cameras, lights, armatures
  and empties retain origin-only display-cache entries for the outliner and
  transforms. A hidden object keeps the mesh it was last drawn with (one hidden
  since it arrived is its origin alone). The viewport is not Blender's own
  drawing engine.
- Basic Principled material values are copied into the native PBR preview.
  Arbitrary linked shader graphs are evaluated by Blender when rendering, not
  by the native preview shader.

### Authoritative undo and recovery

Real-backend undo uses full `.blend` checkpoints, not Swift display snapshots.
The history keeps at most 12 states, reducing older states when their combined
size exceeds 512 MiB, while retaining at least two. Large scenes can therefore
use more than 512 MiB, and saving them can take noticeable time. Checkpoints live
in the app's Documents/.blender-history directory. Existing history files from
older app launches are not automatically deleted.

A completed checkpoint is copied to `autosave.blend` through an atomic rename;
the app restores that file on launch. Undo/redo reopens complete scene data.
Python variables holding old RNA datablocks must be reacquired afterwards.
Animated properties are reevaluated on reopening, just as for a normal `.blend`
load: unkeyed temporary values on animated channels are not persistent keys.

The simulator's shim continues to use `.bkit` and the in-memory Swift undo stack.
Sculpting uses Blender's own brushes on device (2026-09-22, below); the local
paint interactions are not a substitute for Blender's full brush engine and
still need integration work. Native viewport previews are not proof that those
operations reached real bpy.

### Backend requirements still outstanding

No python-ios-lib files were changed. Device builds use `/Volumes/D/OfflinAi`,
which is the newer checkout of that repository. `/Volumes/D/python-ios-lib` is
an older checkout without the bpy payload.

Full desktop interaction parity needs usable window/area/region context or
non-modal equivalents for tools such as knife, loop cut, texture-paint strokes
and context-dependent node-editor actions (sculpt strokes have one now:
`brush_stroke` by EXEC_DEFAULT through a borrowed 3D View, `_blenderkit_sculpt`). Merely exposing
these operator names does not make them executable from a headless embedding.
`examples/device_check.py` now records module identity, current thread, editor
context and relevant poll results. A false poll in one mode is a context result,
not proof of a missing compiled feature.

The iOS offscreen Metal backend's thread requirements also need device testing.
The app's existing Run Scripts Off the Main Thread setting remains available;
serial access alone does not guarantee that Blender's GPU thread assertions are
satisfied. No new iPad runtime or GPU-render success is claimed by a Mac build.

### Validation

The host suites exercise pure Swift logic. The viewport Blender suite now also
checks safe RNA navigation, alias completion, multiline Unicode quoting, actual
property writes, dense evaluated-mesh extraction and complete undo/redo with
geometry, nodes and animation. Run it with `scripts/run-viewport-blender-check.sh`.

For this upgrade, build products and logs are under `/Volumes/D/build/`.
Simulator UI checks include draft syntax validation, cube creation, and stopping
a bounded Python loop with the visible Stop control. Packaging validation follows
bpy's `.fwork` pointer and checks the actual wrapped module's dylib references.

---

Everything about the iPad app itself: where the files are, how the pieces fit,
how to build it, how to test it without a device, and the mistakes that cost
enough to be worth writing down.

The [README](../README.md) covers *why* the project exists — the finding that
the `bpy` shipping on iOS is a headless build with its window manager intact.
This covers what was built on top of that.

---

## Where everything is

The app lives in one repository, **local only** — it is deliberately not on
GitHub.

```
~/github/blenderkit/
├── BlenderLocal.xcodeproj      generated; do not edit by hand
├── project.yml                 the real project definition (XcodeGen)
├── Sources/
│   ├── BlenderLocalApp/        2 files — the entry point and the root view
│   ├── BlenderLocalBridge/     27 files — everything that is not UIKit
│   │   └── Python/             the embedded interpreter and its C shim
│   └── BlenderLocalUI/         43 files — SwiftUI, Metal, UIKit
├── Resources/
│   ├── python/site/            the Python-level bpy shim + the sync module
│   └── Assets.xcassets/        the app icon
├── Vendor/
│   └── Python.xcframework      124 MB — CPython 3.14, vendored
├── scripts/                    build, staging, test and release scripts
├── tests/                      host test suites, one folder each
├── docs/                       this file and bpy-embedding.md
├── examples/                   sample .py scripts
└── research/                   the probing that produced the README's finding
```

Two things it depends on that are **not** in this repository:

| What | Where | Why |
|---|---|---|
| Blender's real `bpy` | `/Volumes/D/OfflinAi/app_packages/site-packages/bpy` | 428 MB, arm64-iphoneos only. Staged at build time by `scripts/stage-blender.sh`. |
| Release archives | `/Volumes/D/OfflinAi/blenderlocal-release/` | One `.xcarchive` and one export per build number. |

Nothing is downloaded at build time and nothing is downloaded at run time. The
app has no networking code at all.

---

## The one idea worth understanding

**bpy owns the scene.** Not the app.

It did not start that way. The app used to keep its own scene in Swift and
treat `bpy` as a façade over it: a button mutated the Swift model, and the
Python appeared in the Info log afterwards as a *description* of what had
already happened. That meant every operator had to be reimplemented — bevel,
loop cut, boolean, the modifier stack — and each reimplementation was an
approximation.

The direction is inverted now. A button sends Python, Blender performs it, and
the viewport shows what came back. **The Python in the Info log is not a
description of the action; it is the action**, which is why the two can never
disagree.

`BKScene` survives as the *display cache* the Metal viewport reads, filled by
`_blenderkit_sync` from the evaluated depsgraph after every command. Nothing in
the interface should write to it directly any more.

### What that costs you

Two bugs came from forgetting it, and both are the same bug:

- **A drag snapped back on release.** A viewport tap set `scene.selection` —
  the display cache — and *logged* the equivalent Python without running it. So
  Blender's selection never changed, and `bpy.ops.transform.translate`, which
  acts on Blender's selection rather than the app's, moved whatever had been
  selected last. The mirror then put the dragged object back where Blender
  still had it. Worse: a different object silently moved.
- **Every mesh operator reported "not in edit mode".** The app's mode is not
  Blender's mode either. A mesh operator has to put Blender into edit mode
  itself before it runs.

If something you changed does not stick, ask what Blender thinks the state is,
not what the app thinks.

---

## The two backends

| | Device | Simulator |
|---|---|---|
| Backend | Blender's real `bpy`, 428 MB | `Resources/python/site/bpy/`, 2178 lines of Python |
| Owns the scene | bpy, mirrored into `BKScene` | writes `BKScene` directly through a C bridge |
| Mesh operators | all of them | the simple ones; the rest say so |

Both run under the same real CPython 3.14. The shim exists because Blender's
`bpy` has no x86-64 or simulator slice, and it answers to Blender's own names
so that a script written against one runs against the other.

Where the shim cannot do something it raises a message saying which operator
wants the real module — *"spin needs a half-edge mesh; the real bpy on device
has it"* — rather than an `AttributeError` about an object nobody asked about.

`EmbeddedBpyRuntime.usingRealBlender` decides which is in play, and the console
banner says which one you are talking to.

---

## Module map

### `BlenderLocalBridge` — no UIKit, ever

This is the layering rule and it is enforced by the tests: the host suites
compile `Sources/BlenderLocalBridge/*.swift` on their own with `swiftc`. If a
file in here imports UIKit, or names a symbol that only exists inside the app
target, **every suite stops compiling**. That has happened four times.

Note the `*.swift` — non-recursive. `Python/` is excluded, which is where
anything touching the C API belongs.

| File | What it is |
|---|---|
| `SceneModel.swift` | `BKScene`, `BKObject` — the display cache |
| `SceneSnapshot.swift` | undo stack, save/load |
| `Autosave.swift` | keeps the scene on disk as the work happens |
| `BpyRuntime.swift` | `BpySession` — running scripts, the console, the Info log |
| `BpyBridge.swift` | the single way the interface changes anything; `Bpy.*` strings |
| `LastOperator.swift` | Adjust Last Operation — the redo panel's model |
| `MeshBuilder.swift` | primitives, at Blender's own defaults |
| `EditMesh.swift`, `Modifiers.swift`, `SculptBrush.swift`, `UVUnwrap.swift` | the shim's geometry |
| `BoxSelect.swift`, `SelectAction.swift`, `ActiveTool.swift` | viewport interaction, without a viewport |
| `PythonCompletion.swift`, `PythonWords.swift`, `PythonFolding.swift`, `BracketMatch.swift` | the editor's language work |
| `ConsoleStream.swift`, `MainThread.swift` | live output, and the main-thread hop |
| `Python/EmbeddedBpyRuntime.swift` | 47 `@_cdecl` callbacks Python calls into |
| `Python/PythonBootstrap.c` | interpreter startup, the GIL, stdout capture |

### `BlenderLocalUI`

`Viewport/` is the Metal renderer, the camera, the transform gizmo and the redo
panel. `Editors/` is everything with text in it — the script editor, the
console, the outliner, the properties panel, the suggestion list. `Chrome/` is
the top bar and its menus, operator search and the status bar. `Workspaces/` is
the two tabs; the 3D View's toolbar and its Add, Mesh, Sculpt and More menus are
in `LayoutWorkspace.swift`. `Theme/` is Blender's own colour values and the
shared widgets.

Removed on 2026-09-17 because nothing constructed them: `ToolShelf`, and
`ViewportHeader` with the mode menus only it used (`ViewportMenus.swift`,
`ViewportModeMenus.swift`). Before adding a menu, check that the view you are
editing is actually on screen.

### `BlenderLocalApp`

`BlenderLocalApp.swift` and `RootView.swift`. Between them they own the scene,
the session, the undo stack, the autosave, and every DEBUG launch argument.

---

## Building and running

```bash
xcodegen generate                     # after adding or removing any file
./scripts/run-in-simulator.sh -w Scripting examples/bike.py
```

### `ARCHS=arm64` is not optional

The Python xcframework keeps its simulator standard library in per-architecture
folders — `lib-arm64`, `lib-x86_64` — and its installer copies from
`lib-$ARCHS`. A **generic** simulator destination sets `ARCHS` to
`"arm64 x86_64"`, so it looks for a folder called `lib-arm64 x86_64`, finds
nothing, and copies **no standard library at all**.

The build still succeeds. One rsync line among thousands is the only sign. Then
every import fails with `No module named 'math'`, so `import bpy` fails, so
every operator in the interface fails with a `NameError` — which looks exactly
like the app being broken.

`run-in-simulator.sh` passes `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` with a concrete
destination, and refuses to launch unless the staged standard library has more
than a hundred entries.

### DEBUG launch arguments

The simulator cannot tap, drag, or raise a keyboard, so the app can be driven
from the command line instead. All of these are `#if DEBUG` and verified absent
from the shipped binary before every release.

| Argument | Does |
|---|---|
| `-workspace <name>` | opens a tab directly |
| `-eval64 <base64>` | puts a script in the editor and runs it |
| `-stub` | forces the command subset — useful when Python itself is broken |
| `-add <kind>` / `-adjust <k>=<v>` | performs an Add and adjusts it |
| `-mesh <name>` | performs a mesh operator through the same call the menu makes |
| `-caret <offset>` | parks the caret, for the bracket boxes and the suggestion list |
| `-fold <line>` | folds a region |
| `-mirror` | turns the mirroring pass on against the shim |
| `-image3d <path>` | Add ▸ Image to 3D Model on a picture, through the sheet's own prepare and create: Full 3D, or `-image3d-mode relief`; `-image3d-whole` skips the cut-out, `-image3d-detail low\|medium\|high`. The path must be inside the app's container (it is sandboxed); Full 3D needs the converted weights in `Library/Application Support/Models/TripoSG/` there (`cp -Rc` a converted folder; a clone costs no space). Full 3D uses seed 42 here |
| `-panel <name>` | opens a More-menu panel at launch, e.g. `-panel "Image to 3D Model"` |
| `-properties-tab <tab>` | opens the Properties editor on a tab, e.g. `-panel "Object Details" -properties-tab modifiers` |
| `-modifier-dump` / `-modifier-steps <steps>` | prints the active object's modifier rows as the panel holds them, then runs comma-separated steps through what the buttons send: `+kind` (Add Modifier), `Name:viewport\|render\|up\|down\|apply\|remove`, a Multires `Name:subdivide\|unsubdivide\|deleteHigher\|applyBase`, or `Name:key=value;key=value` (an edit by Blender's property names), plus `@mode=<MODE>` (F3's Run on `object.mode_set`) and `@hide=1\|0` (the Object tab's Show in Viewports); prints the banner on a failure; waits for `-eval64` to finish |
| `-opsearch <path>` / `-opsearch-args <json>` | More ▸ All Blender Tools on one operator: reads its form (`BlenderOperatorForm.infoCall`) and presses Run (`BlenderOperatorForm.command` through `bridge.run`), printing what the form showed, the outcome, the banner and the mode after; waits for `-eval64` to finish |
| `-uv-row <UVOperator>` | runs one row of the UV Editor's UV menu as the menu does (`Bpy.uv`), e.g. `-uv-row unwrapConformal`, printing the outcome and the banner |
| `-sculpt-enter` | picks Sculpt from the Sculpt menu once a `-eval64` script has finished: Blender's Sculpt Mode on the active object |
| `-sculpt-stroke` | once the sculpt header has read Blender's state, runs `-sculpt-ops a,b,…` (`dyntopo-on\|off`, `remesh`, `voxel-<size>`, `multires`, `mask-fill\|invert\|clear`, `facesets-loose`, `facesets-from-mask`, `size-<px>`, `strength-<v>`, sent as the header sends them) and `-sculpt-brush <name>`, frames the object (not with `-sculpt-no-frame`), and feeds one stroke across it at 60 points a second through the calls a drag makes (`-sculpt-stroke-points <n>`, `-sculpt-stroke-span <fraction>`). Prints the chunks' costs, what moved in the viewport's mesh, and with `-sculpt-undo` what Undo and Redo leave. `-sculpt-header-only` stops after the header's read. The stroke goes through `sculptDrag`, the state machine a finger's drag runs. `-sculpt-midstroke undo\|mask\|leave\|mode` does that at the stroke's midpoint: the top bar's Undo, the header's Mask ▸ Fill, Leave Sculpt Mode, or the mode leaving Sculpt under the finger. It prints what each left: refused or not, the history, and whether the rest of the drag orbited |
| `-region-select <gestures>` | Box, Circle and Lasso drags through the calls a drag makes (`beginRegion`, `extendRegion`, `finishRegion`): `box:x,y;x,y`, `circle:x,y;…:radius`, `lasso:x,y;x,y;…`, points as fractions of the view or `@x,y,z` in the scene, `+extend` / `+subtract` / `+intersect` for Shift / Ctrl / both, `mode:VERT\|EDGE\|FACE` and `none` between, separated by `\|`. Prints the pass's pick, what Blender holds and what the viewport shows, as vertices, edges and faces, whether a refusal was said, and how many samples of the overlay's shaded path disagree with the region selected from. `-region-mode edit` waits for edit mode, `-region-wait <name>` for an object of that name, `-region-view top` snaps and frames first, `-region-view persp:8` puts the opening perspective view 8 from the origin |
| `-region-action <mode>` | The select tools' Mode (`set`, `extend`, `subtract`, `difference`, `intersect`), as the Select tool menu's Mode rows set it |
| `-xray` | X-Ray on, as View Style ▸ X-Ray does |
| `-select-menu <rows>` | presses Select menu rows through `select`, the call the rows make (`more`, `linked`, `similar:VERT_NORMAL`, `object:child`, `type:MESH`, `objlinked:MATERIAL`, `pattern:Wheel*`, …, see `SelectMenu.Command(token:)`), and `adjust:key=value` moves a redo-panel field through `readjust`; after `-select-menu-delay <s>` (3) and any script |
| `-dump-state` | prints the mirrored tool switches (Auto Merge and Split, Affect Only Parents and Origins) and what the UV Editor draws for the active object, before and after the two above |
| `-object-ops <rows>` | presses Object and Mesh menu rows through the calls the rows make, once a `-eval64` script has finished: `select:A+B` (the last is active), `edit`, `object`, `all`, `none`, `dup-linked`, `join`, `parent`, `parent-keep`, `clear`, `clear-keep`, `clear-inverse`, `convert-mesh`, `convert-curve`, `mesh:<LastOperator.Mesh>`, `shear` (Edit or Object Mode, as the row is), `adjust:key=value` (the redo panel, through `readjust`), `undo`, `redo`, `field:<location|rotation|scale>:<axis>=<value>` (a Transform field of the active object, through `TransformFieldEdit` and `commitTransformField`, printing what the field showed, the Python, what it shows after, Blender's location and world position, and how far the preview was from Blender). After each it prints every object's type, parent and counts read from Blender beside the mirror's and the Outliner's tree, the redo panel and the banner |
| `-groups-ops <steps>` | the Data tab's Vertex Groups and Shape Keys panels and the modifiers' Vertex Group field through the commands their controls send, once a `-eval64` script has finished: `select:Name`, `edit`, `object`, `pick:x<0`, `group:add\|remove\|remove-all\|rename:New\|active:Name\|lock:Name\|assign\|remove-from\|select\|deselect`, `weight:<w>`, `key:add\|mix\|remove\|delete-all\|apply-all\|active:Name\|value:Name:<v>\|set:Name:<setting>:<python>`, `switch:relative\|showonly\|editmode:on\|off`, `+kind`, `mod:Name:group:Group`, `mod:Name:invert`, `drag:z:<amount>` (a gizmo Move), `undo`, `redo`. After each it prints what Blender holds beside what the panels show, and the banner |
| `-points-ops <steps>` | Edit Mode on curves and lattices through the calls the controls make, once a `-eval64` script has finished: `select:Name`, `edit`, `object`, `tap:i[:extend]` (a tap beside cage point i, through `MetalViewportView.pointTap`), `box:x0:y0:x1:y1` (view fractions, `pointRegion`), `drag:translate\|rotate\|scale:0\|1\|2:amount:frames[:what@k]` (a gizmo session, `beginPointDrag`, one Blender preview per frame, the commit; `what@k` after frame k: `undo`, `redo`, `tab`, `done` or `tap` as the controls send them, or `bypass-mode` / `bypass-points`, a change put straight into Blender past the drag's hold), `stale-mesh-tap` (a mesh selection marked pending, as a tap on an emptied curve once marked one), `curve:<row>` and `lattice:<row>` (subdivide, extrude, delete, segments, handle:TYPE, cyclic, switch, regular, flip), `all`, `none`, `delete`, `data:property=value` (a Data tab field), `add-lattice`, `lattice-mod:Mesh:Lattice` (the Modifiers panel's Add and Object field), `cube-top:Name`, `undo`, `redo`. After each it prints the selected points and their positions read from Blender beside what the viewport shows, and for a drag each frame's cost and its last frame against the commit |
| `-standin-dab <n>` | in a 3D View without the bridge (the Scripting tab's), once the scene is in Sculpt Mode with an object: `n` taps through `standInSculptTap` and `n` dabs through `sculptDab`, the calls a tap and a drag make, at the object's centre; prints whether each was refused or installed and the vertices drawn after it |
| `-frames <a,b,…>` / `-frames-wait <text>` | once the console shows the text (printed by a `-eval64` script) and no script runs, each frame through `TimelineDriver.setFrame`, the call a scrub and playback make; prints after each what the timeline and the viewport show beside what Blender holds |

---

## Testing

### Host suites — pure logic, no simulator

```bash
for s in scripts/run-*-tests.sh; do "$s"; done
```

| Suite | Checks | Covers |
|---|---:|---|
| `mesh` | 209 | primitives, modifiers, edit-mesh operators |
| `redo` | 162 | Adjust Last Operation, the operator catalogue, Spin's composed centre, Knife Project's call, the edge tools' calls, groups, refusals and factor fields, Auto Smooth, Smooth by Angle, QuadriFlow and Add ▸ Curve and Text |
| `gizmo` | 115 | transform maths, handle picking, no gizmo in Edit Mode with nothing selected, Frame All leaving hidden objects out |
| `completion` | 56 | what the editor offers, and what it must not |
| `syntax` | 30 | the Python highlighter |
| `bracket` | 27 | matching, and ignoring brackets in strings |
| `folding` | 21 | where a Python block ends |
| `boxselect` | 18 | which objects a dragged rectangle covers |
| `regionselect` | 100 | A vertex projected past Int.max (no trap), a floor reaching behind the eye still hiding what is under it, a mirrored object's faces, a bow-tie lasso, Shift+Ctrl and the tool Mode, the refusal on a mesh a modifier rebuilds, Ungrouped's poll and Ratio's display; Box, Circle and Lasso's regions (the coverage mask against the point test), Blender's `sel_op_result`, what the surface hides on a cube without X-Ray and not with it, no back face winning the outline over 18 views, edges' two passes, a lasso on a grid seen from above and below, what a gesture implies, objects by origin or by any part, the Python sent for objects, the Select menu's calls and refusals, and 80,000 triangles in 16 ms |
| `meshpick` | 41 | what a tap in edit mode picks: the radius in points, what the surface hides, edges by their line, a whole polygon, and empty space |
| `traceback` | 33 | finding the failing line, and an operator's printed warning found for the banner |
| `render` | 68 | the Render panel's requests, which device renders, where the file goes, the camera view, and the Python the camera and light editors write |
| `image3d` | 39 | Image to 3D Model's relief: outline, depth, faces, UVs, the files Blender reads |
| `triposg` | 53 | Full 3D without weights: safetensors and the int8/float16 conversion, position embeddings, the flow's inputs, marching cubes, the coarse-to-fine surface, picture, viewpoint fit, symmetry, UV raster, bake |
| `scriptthread` | 27 | which thread a script runs on (a script that loads a file included, and the list of loading operators held to `_blenderkit_context.FILE_READS`), and which scripts have the GPU module started on the main thread first (the start run in python3 with a `gpu.init()` that raises) |
| `tools` | 119 | snapping, the pivot point and proportional editing: the simulator numbering the edit selection on the cage (taps, the gizmo, box select, Select All and its mesh operators), the mirror's packing (Auto Merge and Target Selection included), the Python each control sends, where the gizmo pivots, Blender's falloff curves and measured numbers, Increment and Grid, Connected Only's distance, the preview committing what it showed, the simulator's operators running the same operation, and hidden vertices left out of it |
| `snap` | 122 | snapping a move to vertices, Affect Only Parents keeping a child as a target and Affect Only Origins snapping onto anything, edges, edge centres, faces and face centres: the 30-point reach, what moves left out (children and dependents too, and everything proportional editing may pull), children carried by the preview, the occlusion plane, X-Ray and Wireframe, Face Center's corners, Blender's edge zones and edge direction, quads rather than triangles, empties, wires, curves by their control points and Display As Bounds, Target Selection, the constraints, Snap With, Auto Merge's welds, the drag committing what it previewed, the marker, and the search's cost at 80,000 and 1.28 million triangles |
| `tools-shim` | 73 | the simulator's `bpy.ops.transform` and tool settings (Auto Merge and Split, Target Selection, Affect Only, a move with Affect Only Origins refused, which Snap To set may empty): what it hands TransformOperation, what it refuses (the edge tools by name), the Snap menu's new actions, Individual Origins with proportional editing, Show/Hide's flags and the Object and Mesh menus' rows it cannot run (Duplicate Linked, Parent, Convert, Shear, Split and the clean-up rows, Inset Individual) |
| `modifier` | 283 | the Modifiers panel: a row for every modifier Blender has (unmodelled kinds as `.other`, by Blender's type and name, an unreadable one as a header), the header every row has (both switches, Apply, the moves and remove), the six new kinds' defaults, sends and record, Multires's buttons in object mode, escaped names, identity kept by type, the Python each row sends and the one change an edit sends, the mirror record parsed back (integers included), old saved files still opening, Wave's Motion against Blender's numbers, Remesh's scaled floor (from the Remesh's input, never its output), Mirror's Bisect, Flip, Clipping and Merge (the simulator's Mirror against Blender's counts, Clipping's rule), the simulator's Screw / Decimate / Remesh and its Faces count, its Apply and Origin to Geometry evaluating the stack once, and a Geometry Nodes row (Smooth by Angle's two settings) |
| `modifier-shim` | 45 | the simulator's modifiers: every line the rows send taken by the shim (Mirror's new rows and the six new kinds included, the keys it takes read from the Swift), object pointers by name, the header's moves, switch and remove, Multires's operators, what it refuses as Blender does |
| `mirror` | 128 | the mirror's Swift half: a frame's names looked up once (3,000 keyed objects' channels in under 5 ms), a pushed object, a mesh with no faces carried by its edges, the merge onto what is on screen (the stack, never run twice — nor by a frame change or a duplicate), a frame change moving a wire, Knife Project's cutters, a wire object picked by its lines where Blender draws it, the two visibility flags the Outliner shows, and the UV map and seams (per-corner UVs, the fast path, diagonals, what is refused) |
| `undo` | 40 | reading Blender's undo state, the recovery file, and the simulator's undo keeping a modified mesh's base (drag, undo, redo keep 24 / 48 under a Mirror) |
| `sculpt` | 39 | Sculpt Mode's Swift half: the Python each control sends (object names escaped, the camera to nine figures), Blender's state and a stroke's answers read back, when a stroke's points go, and the Size field in pixels |
| `shader` | 8 | the line shader compiled from Shaders.metal and drawn on the Mac's GPU, fast and safe math: an edge from a vertex Blender gives the normal (0,0,0) is drawn |
| `objectops` | 95 | Object ▸ Duplicate Linked, Join, Parent, Clear Parent and Convert, the Mesh menu's Split, clean-up, Un-Subdivide, Beautify, Bevel Vertices and Extrude Individual rows, Inset Individual and Shear (Edit and Object Mode): the Python each sends, their fields, the checks before the call reading every edit-mode mesh and the panel's own values, which rows are offered, the Outliner's parent tree, and the object selection a redo-panel re-run hands back |
| `transformfields` | 50 | the Transform fields (Properties ▸ Object, the N panel): the eleven numbers the mirror sends and where they go, every rotation mode's fields, what the fields show when the channels are missing, the one-component Python an edit sends, each mode's turn, and the viewport's preview of an edit (a child of a moved parent, the parent carrying its child, the roll-back) |
| `symmetry` | 53 | mirror editing: the `|mirror=` flag the mirror carries and the merge keeping it Blender's, which vertices follow which (the selection's side, both sides selected, on the plane, X+Y's diagonal, hidden images, proportional editing, followers taking no share of the move), Topology Mirror's pairs on paths and grids, a vertex out of place paired by its edges, X+Y with Topology Mirror cancelling, a drag previewing the image and sending `mirror=True` only while editing with an axis on, pairs on Blender's coordinates under a modifier that moves what is drawn, the toggles' Python and undo steps, the five Mesh-menu transforms that send `mirror=True` on any edited mesh and keep the current flags on a redo, Topology Mirror offered in Edit Mode and Weight Paint only |
| `groups` | 70 | vertex groups and shape keys: the record the mirror carries (escaped names, counts, a head-less record refused), a key's clamp, counts kept across a frame change, `carryGroups` and the merge, every Data-tab control's call and undo name in Object and Edit Mode, and the modifiers' Vertex Group field read, sent alone, outside the simulator's settings and kept by a saved file |
| `points` | 70 | Edit Mode on curves and lattices: the cage the mirror carries (`ControlCage`, its flags and refusals), a tap (a knot takes its handles, a hidden point is never picked, a knot wins a tie with its handle), a box, what is drawn (`ControlCageOverlay`), the Data tab's settings parsed, `carryPoints` and the merge, the modes a curve or a lattice may enter, the gizmo's points drag (its pivot, its followers, a preview that touches no display cache), and the Python each control sends |

### Blender-side checks — the ones that cannot lie

```bash
./scripts/run-redo-blender-check.sh        # 506 calls, Knife Project included, the edge tools measured on grids, then Knife Project after a script-thread render in a fresh Blender
./scripts/run-viewport-blender-check.sh
./scripts/run-context-blender-check.sh     # 54: temp_override off the main thread, and the six file loads refused there and run on the main thread
./scripts/run-image3d-blender-check.sh     # Image to 3D Model's relief and full 3D in Blender
./scripts/run-render-blender-check.sh      # renders, and the 3D View's own framing
./scripts/run-tools-blender-check.sh       # 271: every drag's preview against Blender's commit, Mirror Clipping, Auto Merge, parent chains and Affect Only Parents and Origins included, snaps onto Blender's own meshes, and what moves with what against the depsgraph
./scripts/run-modifier-blender-check.sh    # 238: each modifier row into Blender, its record back, edits made from Blender's record (Smooth by Angle's included), the Remesh row dragged to its floor, every type modifier_add takes on a mesh reaching the panel, the six new rows, every row's header (moves Blender refuses included), Multires's buttons from Edit and Sculpt Mode, a name with the record's separators, and Every Property on a modifier
./scripts/run-mirror-blender-check.sh      # 142: Blender's own sync of wire, empty and oversized objects, and a frame change, replayed through the Swift vertex for vertex
./scripts/run-3dview-blender-check.sh      # 209 in Blender + 151 replayed: Apply's greyed rows held to Blender
./scripts/run-objectmenu-blender-check.sh  # 78 + 73: Show/Hide, Separate, Auto Smooth, QuadriFlow, curves and text, and Blender's mirror of each replayed
./scripts/run-objectops-blender-check.sh   # Join (hair curves and point clouds too), Parent, Convert, the new Mesh rows (two meshes in Edit Mode, Edge Split on a lone vertex, Delete Loose by its switches) and Shear in Edit and Object Mode with the app's undo, redo-panel changes through its rewind, refusals leaving the scene as it was, and Blender's mirror replayed: parents, types, counts and the Outliner's depth
./scripts/run-transformfields-blender-check.sh # 406: the review's parented child and four other rotation and delta cases — the fields show Blender's own channels, each of 74 field edits writes that one field, and the preview is where Blender puts the object and its children
./scripts/run-regionselect-blender-check.sh # 54 gestures of Blender's own select operators (X-Ray on) against the Swift pass, each pick pushed and read back, every Select menu row with its refusals, and why Edit Mode region select refuses under a rebuilding modifier
./scripts/run-uv-blender-check.sh          # every UV menu row from object and Edit Mode (an unwrap that solves nothing refused, rows that need a map), then Blender's UV maps and seams replayed through the Swift, the UV Editor's map held to Blender's UV Editor
./scripts/run-sculpt-blender-check.sh      # Sculpt Mode: the aimed view against ViewportCamera, the refusals, a Draw stroke streamed in chunks against one call, Grab past the silhouette, a Snake Hook cut into pieces, all 64 Essentials brushes on a plain sphere, again with the mesh's X, Y and Z symmetry on, under Dynamic Topology and on Multires with Undo and Redo, the header's operations, and a stroke after a load freed the undo stack
./scripts/run-symmetry-blender-check.sh    # 111: the mirror row's flags into Blender and back through `_kind`, 22 drags' previews against Blender's commit (X, Y, X+Y, X+Y+Z, on the plane, both sides, turn, scale, proportional and Connected Only, a hidden image, Mirror Clipping, Auto Merge, Topology Mirror on Suzanne and on Suzanne pushed out of place), 4 drags over a SimpleDeform Twist paired on Blender's coordinates (and shown to differ when paired on the drawn ones), Topology Mirror's pairs on eight meshes with their +X halves pushed out of place, and the Mesh menu's transforms sending `mirror=True` on any edited mesh and mirroring with the flag on
./scripts/run-points-blender-check.sh      # 260: Edit Curve and Edit Lattice in and out and their refusals, a lattice drawn as its grid, taps and a box held to Blender's flags, drags whose every frame is Blender's own and whose commit is the last frame, Undo and Redo, two curves in Edit Mode at once, a lattice dragging the cube under its modifier, every Curve and Lattice menu row and its refusals, the Data tab, Add ▸ Lattice, and the edge cases that must not take Blender down
./scripts/run-groups-blender-check.sh      # 320: every Vertex Groups and Shape Keys control into Blender with an undo stack, its refusals in words, Undo in Object and Edit Mode, a key's shape edited in Edit Mode, the pass, a tap and a frame change handing the record over, all 13 modifiers' Vertex Group field, and 46 records replayed through the Swift
./scripts/run-opsearch-blender-check.sh    # 34: the operator search's mode rule and refusals, then every operator it lists run through run_operator on three fixtures from four modes: 13,852 runs, no crash
# with TripoSG's weights and a reference (see tests/triposg/make_reference.py):
BK_TRIPOSG_WEIGHTS=… BK_TRIPOSG_REFERENCE=… ./scripts/run-triposg-parity.sh
BK_TRIPOSG_WEIGHTS=… ./scripts/run-triposg-endtoend.sh <cut-out.png> <out dir>
./scripts/run-conformance.sh               # 44 checks
```

These build the catalogue, print **every call the app can emit**, and run those
through desktop Blender 5.2.1 in background mode. What is checked is what the
Swift actually produces, not a hand-written list of what it was supposed to
produce. They have caught, among others:

- `spin` omitting its `axis`, because the RNA reports only the scalar default of
  a vector's components;
- a mesh datablock orphaned once per frame of a slider drag;
- a backup taken *before* `update_from_editmode`, which silently discarded every
  edit made earlier in the same edit session;
- a rotation committed about a different point from the one the drag had just
  previewed. With no View3D, `initTransInfo` falls back to
  `V3D_AROUND_CENTER_BOUNDS`, so `bpy.ops.transform.rotate` turns a selection
  about the centre of its bounds whatever `transform_pivot_point` says, while
  the gizmo previews about the median. Cubes at x = 0, 4 and 10: Blender used
  5.0, the preview 4.667. Every pivot now sends its own `center_override`.
- every integer modifier setting failing to come back from the mirror. The
  record writes `levels=2.0`, and `Int("2.0")` is nil.

They skip rather than fail when Blender is not installed.

---

## Shipping

```bash
./scripts/push-appstore.sh <build-number>
```

Archive → read the build number back out of the built plist → check the staged
bpy → export → scan the Payload → validate → upload. Every step that can fail
quietly is checked, because each failure costs a build number that cannot be
reused.

**Toolchain.**
- **Which Xcode.** The script builds with whichever Xcode `xcode-select -p` names, and stops before archiving if
  that Xcode is a beta: App Store Connect rejects beta-built uploads. A beta's build number has four digits
  starting with 5 after the letter, such as `27A5218g`; a release's has fewer, with or without a trailing
  letter, such as `27A266a` or `17F42`.
- **After installing a new Xcode, once:**
  1. `sudo xcode-select -s /Applications/Xcode.app`
  2. `sudo xcodebuild -license accept` and `xcodebuild -runFirstLaunch`
  3. `xcodebuild -downloadPlatform iOS`
  4. `xcodebuild -downloadComponent MetalToolchain`. The viewport's `.metal` shaders need it, and a fresh Xcode
     fails on them without it.
- **What carries over.**
  - DerivedData is at Xcode's default, `~/Library/Developer/Xcode/DerivedData` (it was on disk D until
    2026-09-15). A new Xcode's first build rebuilds everything.
  - Simulator runtimes live outside Xcode and survive deleting one, until the runtime itself is deleted: the
    iOS 26.5 devices went with their runtime on 2026-09-15. `run-in-simulator.sh` picks its device by name
    (`BK_SIM`, default `iPad Pro 13-inch (M5)`) and `run-conformance.sh` uses whichever simulator is booted, so
    neither names an ID.
- **Don't delete the old Xcode before switching.** Remove it only after `xcode-select` points at the new one;
  otherwise `xcodebuild` and `xcrun` stop resolving.

**The content check runs on every push**, because it is part of the script
rather than a thing to remember: `scripts/scan-app.py`, between the archive and
the export. It reads the built binary with `strings` — a DEBUG launch argument
is absent only if it cannot be found in what ships, not because `#if DEBUG`
guards it in source — and looks for `itms-services`/`itms-apps` anywhere in the
bundle and for `ensurepip`/`test` staged into the standard library. Run it by
hand two ways:

```bash
python3 scripts/scan-app.py <BlenderLocal.app> release   # must print CLEAN
python3 scripts/scan-app.py <BlenderLocal.app> control   # on a DEBUG build: must find hooks
```

The control mode exists because the release mode's answer is "nothing found",
which is also what a broken scan says. For the same reason the scan now stops
if the bundle holds no `BlenderLocal` binary: pointed at a Designed-for-iPad
build, whose outer `.app` is only a wrapper around `Wrapper/BlenderLocal.app`,
it used to read nothing and print CLEAN.

The rest of the standing check has no script: no download-and-execute path
(the only network call is TripoSG's three `.safetensors`, pinned to a revision
and checked against a SHA-256), and the App Store text has to describe what the
app is for.

---

## Landmines

Written down because each of these cost more than it should have.

**`.fwork`.** The build moves every staged `.so` into `Frameworks/` and leaves a
`.fwork` pointer behind. Logic keyed off the `.so` filename silently did the
wrong thing for **nine shipped builds** — the app ran the real module while
reporting the shim, and stopped mirroring Blender's scene into the viewport.
`push-appstore.sh` checks the bundle against the names the runtime actually
looks for.

**The test harness lies.** Five times so far. It has: not framed the scene; not
loaded the script into the editor; run before the first frame; seeded the
editor draft *after* the editor had already read it, so every screenshot showed
the previous run's script; and printed the console synchronously after
`runScript`, which now returns immediately, which looked exactly like a
deadlock. **When a screenshot disagrees with the code, suspect the harness
first.**

**Verifying the Python is not verifying the app.** Every mesh operator was
checked against desktop Blender and none had ever been run through `perform`.
When they finally were, all of them failed on the first line: the backup that
makes an operator adjustable does `mesh.copy()`, and the shim's meshes are
proxies for an object rather than datablocks.

**Scripts run off the main thread**, and that is a setting —
*Options ▸ Run Scripts Off the Main Thread* in the Scripting tab, also in the
Script menu (until build 34 it sat in a Window menu nothing showed). iOS's hang indicator read 631 ms on
a 268-line script; pumping the run loop from inside the interpreter cannot help,
because bpy spends its time inside C where there is no bytecode boundary to run
a pending call at. Consequences: `bk_python_run` takes the GIL, startup calls
`PyEval_SaveThread()`, and all 47 bridge callbacks hop to the main thread.
`bk_console_emit` is deliberately **not** wrapped — doing so deadlocked the
first script that printed.

Blender's own documentation says its Python API should be called from the main
thread. Exactly one thread ever touches it here, which is a different claim —
but Blender's GPU code does assert which thread it is on, so **a script that
renders is the case that may disagree**, and that is what the setting is for.

**`temp_override` off the main thread wiped the main thread's context**
(fixed 2026-09-17). Blender gives out `context.window`, `screen`, `area` and
`region` on the main thread only (`ctx_wm_python_context_get` in context.cc;
the module patch opened the other members to every thread but not these).
`temp_override` reads those same members to learn what to restore. On the
script thread it read None, and at the end of the block it wrote None into the
one context both threads share. After one `temp_override(window=…)` in a
script, the main thread had no window or screen. Every operator that polls for
one failed, and Blender's undo fell back to .blend checkpoints until the app
restarted. Two parts fix it:
- A script or console line whose text mentions `temp_override` runs on the
  main thread (`ScriptThread`). There the override works as in Blender, and
  the console says why.
- Any other call off the main thread has those four members dropped, with a
  warning (`_blenderkit_context.py`, installed by the console prelude).

Checked by `run-scriptthread-tests.sh`, and by `run-context-blender-check.sh`,
which reproduces the loss in desktop Blender as its control. It was also
checked in the real app on this Mac: the control fell back to checkpoints, the
guarded call kept Blender's undo, and a main-thread override snapped the 3D
cursor.

**Loading a file from a script crashed the app** (fixed 2026-09-22). A
script's `bpy.ops.wm.read_homefile()`, run through `-eval64`, took the real
app down: EXC_BAD_ACCESS at 0xf0 in `WM_event_modal_handler_region_replace`,
under `ED_region_exit` ← `ED_area_exit` ← `ED_screen_exit` ←
`wm_file_read_setup_wm_init`, on the `bk.python.script` thread (reports
BlenderLocal-2026-09-22-100656 and -100743). It is the thread, and only the
thread:
- `wm_file_read_setup_wm_init` calls `ED_screen_exit` for every window before
  it looks at `load_ui` (wm_files.cc), so `load_ui=False` does not avoid it.
  `ED_region_exit` asks the context for the window, and
  `ctx_wm_python_context_get` answers NULL off the main thread. The first
  instruction of `WM_event_modal_handler_region_replace` in the shipped object
  is `ldr x8, [x0, #0xf0]`, with `x0` the window: the fault address.
- It is not the app's overrides left pointing at freed memory. No app module
  keeps a window, screen, area or region; Knife Project, sculpting, hiding and
  the undo module look them up each time.
- All six operators that load a file take that path: `read_homefile`,
  `read_factory_settings`, `open_mainfile`, `revert_mainfile`,
  `recover_last_session` and `recover_auto_save`.

File ▸ New never crashed this way. It used `session.submit`, which evaluates on
its caller, the main thread. In desktop Blender 5.2.1 with the app's context
(undo stack, `gpu.init()`, a 3D View override), the old `read_homefile()`, which
loads the startup file's own screen, returned FINISHED on the main thread, and
the undo push and the view override worked after it. It is now
`bridge.run("bpy.ops.wm.read_homefile(load_ui=False)")`.

The fix has the same two parts as `temp_override`'s:
- A script or console line that names one of the six runs on the main thread
  (`ScriptThread.fileReads`), and Run Script says why in the console.
- Any call off the main thread is refused with a RuntimeError that says what to
  do (`_blenderkit_context.guard_file_reads`, installed with the temp_override
  guard). It wraps `bpy.ops._op_create_function`, which makes
  `bpy.ops.wm.read_homefile` on every access, so a call from an imported module
  is caught too.

On the main thread the six are Blender's, with one difference: `read_homefile`
and `open_mainfile` keep the app's screen unless the call passes `load_ui=True`,
as File ▸ New and File ▸ Open already did. Measured in desktop 5.2.1: a file
saved with no 3D View on its screen, opened with its own screen, left Knife
Project, sculpting and hiding no 3D View to borrow; opened without `load_ui`,
the app's 3D View stayed. `read_homefile(load_ui=True)` brings the startup
screen back.

Checked by `run-scriptthread-tests.sh` (the routing, and the Swift list against
`FILE_READS`) and by `run-context-blender-check.sh`. In desktop Blender with the
app's context, the latter refuses each of the six on a worker thread and leaves
the scene and the main thread's context as they were (`load_ui=False`
included). It then runs each on the main thread, with the undo push and the
view override working after. The unguarded call is never made on a thread
there: it would take Blender down. **Run in the real app on 2026-09-22**, with
nothing else using it, through `-eval64`, and each case did what desktop
Blender had predicted, with **no new crash report**:
- the script that crashed the app now runs on the main thread: the console note
  first, `read_homefile()` FINISHED, Camera, Cube and Light after, the window,
  a 3D View and `ed.undo_push.poll()` all still there, and `load_ui=True` on the
  main thread fine too;
- a load whose name is built at run time stays on the script thread and is
  refused in a sentence, with the scene untouched;
- `open_mainfile` of a file saved with no 3D View keeps the app's 3D View, and
  the undo push still polls.

**Never read `update.id.original` in a frame handler** (fixed 2026-10-01). A
user's `frame_change_post` handler that runs before the app's can delete
objects; `depsgraph.updates` still lists them, their evaluated copies are the
depsgraph's own memory, and their `original` is freed. Reading it segfaulted
desktop 5.2.1 in `pyrna_struct_CreatePyObject` two runs of two, or raised
`'ID' object has no attribute 'matrix_world'` once cameras reused the memory.
`_blenderkit_anim` now takes only the name and the flags from an update, and
looks names up in one table a frame built from `scene.objects`; a keyed object
that went asks for a whole mirror. `run-animation-blender-check.sh` runs the
handler in a Blender of its own (`handler_removes.py`, three ways of reusing
the memory). **Run in the real app on 2026-10-01** (`-frames`): the handler
deleted 10 of 20 keyed grids at frame 5, every frame 2 to 7 reached the
timeline, and from frame 5 the viewport drew the 10 Blender held, at Blender's
heights.

**The stand-in brush over Blender's mesh** (fixed 2026-10-01). A 3D View
without the bridge (the Scripting tab's, which keeps Sculpt Mode) fell through
to the simulator's Swift brush, which installed `SculptEngine.stroke(obj.mesh)`
with `setMirroredMesh`: on a device that ran the mirrored modifier stack over
Blender's evaluated mesh on every dab (a cube with a Subdivision, 54 → 150 →
486 → 1,734 → 6,534 vertices over four dabs). `BKObject.sculptStandIn` refuses
Blender's mesh in a sentence and runs the stand-in over the base in the
simulator; the shim's Shade, UV projections and Join take the base the same
way. **Run in the real app on 2026-10-01** (`-standin-dab 4`, Scripting tab, a
cube with a Subdivision in Sculpt Mode): four taps and four drag dabs refused,
26 vertices drawn before and after.

---

## What works, and what does not

Two tabs: **Scripting** and **3D View**.

The editor has syntax highlighting, folding, indent guides, a current-line
band, bracket matching, auto-closing pairs, and a suggestion list at the caret
that asks the live interpreter what an object really has on it rather than
consulting a table. Output streams as the script runs; the scene is saved two
seconds after the edits stop.

The 3D View has Blender's own operators behind it: add, transform, box, circle
and lasso select and Blender's Select menu (2026-09-22, below), bevel, inset, subdivide, loop cut, spin, solidify, wireframe, symmetrize, poke,
merge, smooth, randomize, shrink/fatten, push/pull, to sphere, shear, the clean-up rows, and
Object ▸ Join, Parent and Convert (2026-09-22, below) — each through the
Adjust Last Operation panel, so the parameters can be dialled after seeing the
result.

**Snapping, the pivot point and proportional editing** are Blender's
`scene.tool_settings`, written through `_blenderkit_tools` and mirrored back on
every pass, so each control shows what Blender holds — including after a script
changed it. The header carries the three menus Blender's own header does; More ▸
Snap is Blender's Shift+S menu, and More ▸ Transform Tools holds the fields
(proportional size, the 3D cursor) a menu cannot.

Two of these could not be done the way the desktop does them, both measured in
Blender 5.2.1 under `-b --factory-startup`:

- All four `bpy.ops.view3d.snap_*` fail their poll ("Expected a view3d region"),
  so `_blenderkit_tools.snap` does what they do from the same RNA. This is the
  compromise `_blenderkit_anim.keyframe_insert` already makes.
- `tool_settings` alone changes nothing about a transform run headless: with
  `use_proportional_edit = True`, 1 vertex of 121 moved, the same as with it
  False. The same values passed as operator arguments moved 69, so the gizmo
  appends them per transform. What is written to `tool_settings` is still real
  scene state — it goes into the .blend and means what it says on a desktop.

**Mirror editing** — the mesh's X, Y and Z symmetry and Topology Mirror — is
the mirror row beside them in Edit, Sculpt and the paint modes (2026-10-01,
below). The flags are the mesh's own, written through `bridge.run` and read
back with every object; a drag in Edit Mode previews the mirror images moving
and commits `mirror=True`, which a headless Blender needs before it mirrors.

**Vertex groups and shape keys** are in a mesh's Data tab (2026-10-01,
below), as Blender's panels have them: groups added, renamed, locked, assigned,
removed, selected and deselected by, keys added, valued, related, muted,
weighted by a group and edited in Edit Mode, and the Vertex Group field of the
modifiers that take one — each written through the bridge and shown as the
mirror reads it back.

**Curves and lattices** have Edit Mode too (2026-10-01, below): their control
points and handles drawn, tapped, boxed and moved, each drag previewed by
Blender's own transform frame by frame, Blender's Curve and Lattice menus, their
settings in the Data tab, and Add ▸ Lattice, so a mesh can be deformed by a
lattice end to end.

Snapping *during* a drag is computed by the drag itself, because a headless
Blender does not snap a transform at all: its exec path takes the operator's
`value` as final. The drag snaps its own result — Increment in steps from where
it started, Grid onto the grid, a move onto the vertex, edge, edge centre, face
or face centre under the finger — and sends Blender the snapped value, so what
it shows is what is committed (see 2026-09-21 and 2026-09-22 below). Volume and
Edge Perpendicular are scene settings only, and the Snapping panel says so.

**Image to 3D Model** (Add menu). It turns a photo or drawing of one object
into a textured model. Build 34 only inflated the outline, which the user
rightly called very bad. Build 35 used TripoSR, whose shapes were blobby enough
that the photo did all the work ("it just pastes the texture on"). Build 36
replaced TripoSR with TripoSG, which generates the shape:

- **Full 3D: TripoSG** (VAST AI, MIT). The whole object, sides and back
  included, sharp enough for teeth, spikes, fingers and glasses.
  - The network is written out in MPSGraph (`TripoSGModel.swift`, weights fed
    through `GraphWeights.swift`), not converted, so no copy ships:
    DINOv2-large reads the picture (257 tokens); a 1.44 B transformer (21
    blocks, long skips, q/k RMS-norm) denoises 2048 latents by rectified flow,
    20 Euler steps, guidance 7 against an all-zero picture; a VAE decoder turns
    the latents into logits queried per point.
  - Weights: VAST AI's three safetensors files (7.95 GB, pinned to revision
    `2c1c516d`) download on request from huggingface.co/VAST-AI/TripoSG
    (`TripoSGWeights.swift`), smallest first. Each is checked against the size
    and SHA-256 Hugging Face publishes, then converted on the device and its
    float32 original deleted: large weights to float16, the transformer's
    Linear weights to int8 in blocks of 64 with float16 scales; norms, biases
    and position tables stay float32. 2.6 GB kept, excluded from backup; the
    sheet can remove it. The conversion format and source hash are in each
    file's metadata, so a different format is converted again. Build 35's
    `Models/TripoSR` folder is deleted when the weights object first loads.
  - `Safetensors.swift` reads a header, then each tensor with `pread` straight
    into its Metal buffer. Nothing is memory-mapped: a map of a multi-gigabyte
    file beside the buffers made from it doubles the address space an iPad
    must grant.
  - The steps (`TripoSGPipeline.swift`, times on this Mac's M4 in the app):
    1. `prepare`: the cut-out on white, cropped, padded 10% to a square;
       DINOv2 sees it resized to 256 and centre-cropped to 224. The same
       square at 512² with its coverage is kept for the texture.
    2. DINOv2: 1 s.
    3. The flow: 20 steps, 78–81 s (the first step compiles, about 8 s).
    4. `surface`: logits on a 65³ grid, then only the cells within one of a
       sign change re-queried at 129³ and 257³ (Low stops at 129³), and
       marching cubes: 16–17 s, a quarter of a dense grid's queries, and the
       same mesh (checked).
    5. `prepare_full` in Blender: decimate to Low 20k / Medium 50k / High 100k
       triangles, Smart UV Project.
    6. `fitPose`: TripoSG turns the shape to face +Z whatever the photo's
       viewpoint, so the photo's azimuth and elevation are found by matching
       silhouettes (a 96² grid, 10° then 2–3° steps). A symmetric shape's
       silhouette from azimuth a and 180° − a is the same, so the front half
       wins unless the back fits clearly better. `mirrorSymmetry` compares the
       surface's voxels with their mirror across x = 0.
    7. `bake`: per texel, the photo where that view sees the surface (facing,
       unoccluded by a z-buffer, inside the cut-out), and from the mirrored
       point on the other side for a symmetric shape (over 0.8); everywhere
       else a colour spread over the mesh, breadth first from the painted
       vertices, then smoothed, with the photo blended in at its edges. 0.2 s.
    8. `finish_full` turns TripoSG's Y up / +Z front into Blender's Z up /
       −Y front.
  - 98–102 s end to end in the app; the app's footprint peaks at 2.67 GB and
    drops to 0.73 GB after. Full 3D refuses to start when
    `os_proc_available_memory` is under 2.8 GB.
  - Memory: each stage (DINOv2, flow, decoder) builds its own graph and
    releases it. Every stage runs in its own autorelease pool; without them
    Metal's autoreleased objects kept each stage's weights until the thread's
    pool drained and the stages piled up (4.6 GB). Float16 weights peak at
    3.8 GB; int8 brings it to 2.5 GB.
- **Relief: Depth Anything V2 Small** (Apple's Core ML conversion, Apache 2.0,
  bundled, 48 MB, `Resources/Models/`). It gives the picture's depth in about
  30 ms.
  - `ImageToModel.build(mask:depth:)` shapes the front from it, rounds the last
    few cells to the outline, and gives it a shallow back.
  - The photo is the texture at full resolution. Seen from the side the edges
    show a stretched photo; that is what a relief is.

Checked by:
- `run-triposg-tests.sh`: the safetensors reader and writer, the conversion
  (float16 clamping, int8 scales, the recorded hash), Linear layers from each,
  bicubic position embeddings against torch, sigmas, the timestep embedding,
  seeded noise, closed outward marching cubes, the banded surface against a
  dense grid (with a thin plate), the picture preparation, the viewpoint fit
  on an asymmetric shape, symmetry, the UV raster, and the bake's photo,
  fill and mirror.
- `run-image3d-tests.sh`: the relief.
- `run-image3d-blender-check.sh`: `build`, `prepare_full` and `finish_full` in
  Blender, including that the model's front faces Blender's front view.
- Two checks that need the weights and are skipped without them:
  - `run-triposg-parity.sh` against PyTorch (make the reference with
    `tests/triposg/make_reference.py`). With float16 weights: DINOv2 0.23%
    relative, the guided velocity 0.20%, 0.43% and 0.54% at sigma 1, 0.55 and
    0.05, the decoder's latents 0.44% and logits 0.07%, and a 20-step shape's
    inside overlapping torch's at IoU 0.98. With the app's int8 transformer the
    velocity is 0.35%, 1.4% and 0.83% and the IoU 0.97; the check allows 2% for
    int8. The latents themselves drift 17–23% over 20 steps either way:
    guidance 7 amplifies kernel-level differences, so the shape is what is
    compared.
  - `run-triposg-endtoend.sh` renders a model from four sides.

Traps met on the way:
- The decoder's logits are positive **outside**. Taken as positive inside,
  marching cubes gave the right surface with every triangle facing in, and
  the bake found nothing facing the camera.
- Converting norms and biases to float16 moved the decoder's latents from
  0.44% to 3.4%; only large weights are halved.
- Int8 with one scale per row cost 2.3% velocity error; blocks of 64 halve
  that. No one kind of layer is to blame (each adds 0.1–0.6%).
- TripoSG's repository includes FlashVDM and HunyuanDiT-derived code under
  Tencent's licence; nothing of it is used here, and the decoder's
  coarse-to-fine extraction is written independently.
- In the Designed-for-iPad app, a model made at the 3D cursor sits inside any
  earlier one made there, and the two textures show through each other. It
  looks exactly like a texture bug.

**Circle and Lasso select, and the Select menu** (2026-09-22). The toolbar's
Select Circle and Select Lasso were greyed out with "Needs a screen-space
selection pass"; Blender's Select menu was three rows on the Select button.

- **One pass for Box, Circle and Lasso** (`RegionSelect.swift`). Blender's own
  `view3d.select_circle` / `select_lasso` cannot stand in on the device: without
  a window they select nothing unless the 3D View's X-Ray is on, because they
  read the GPU selection buffer. So the pass is Swift's, over the mesh the
  viewport draws, with Blender's rules element by element: a vertex by its dot,
  an edge wholly inside or — for Box and Lasso when none is — crossing in, every
  edge a Circle touches, a face by its centre with X-Ray and by any of it
  showing without. Without X-Ray the edited mesh is rasterised over the
  region's rectangle (`DepthBuffer`, one sample per point, two-sided as Blender
  draws the edit mesh) and only what shows counts. X-Ray is View Style ▸ X-Ray
  or ⌥Z, and Wireframe selects through as Blender's X-Ray-in-wireframe does.
  A Circle is painted: the region is everything within the radius (Blender's 25
  by default; 10/25/50/100 in the Select button's menu) of where the centre went.
  In Object Mode a box takes an object any of which it covers, a circle or a
  lasso its origin — Blender's rule, measured: a circle or lasso over a cube's
  surface off its origin selected nothing, a box over the same spot selected it,
  X-Ray on or off. Shift extends and Ctrl or ⌘ subtracts; an Intersect over
  nothing deselects, as Blender's `sel_op_result` does. The Pencil draws them too.
- **What the gesture picks is Blender's before it is shown.** Edit mode sends
  the picked elements as `Bpy.pushEditSelection` in one command named after
  Blender's operator ("Box Select", "Circle Select", "Lasso Select", an undo
  step as in Blender), and the viewport then shows the selection the mirror
  reads back. Box select used to leave its elements on the display cache until
  the next command carried them over. The stroke is drawn from the same
  `SelectionRegion` it selects with.
- **The Select menu** (`SelectMenu.swift`, `SelectMenuItems.swift`), in the
  header before Add or Mesh, with 5.2.1's rows in its order. Edit Mode: All /
  None / Invert, the three tools, Select Mirror, Select Random, Checker
  Deselect, More/Less, Select Similar (the select mode's own types, Face
  Regions), Select All by Trait (Non Manifold outside face mode, Loose, Interior
  Faces, Faces by Sides, Poles by Count, Ungrouped), Select Linked (Linked,
  Shortest Path, Linked Flat Faces), Select Loops, Sharp Edges. Each goes
  through `perform`, so Blender's redo panel adjusts it with Blender's own
  fields and defaults. Object Mode: Active Camera, Mirror, Random, More/Less
  with Parent and Child, All by Type, Select Linked, Select Pattern…. Greyed,
  with the reason in a comment: Next/Previous Active and Side of Active (they
  need Blender's selection history, which a pushed selection has none of:
  Side of Active returns CANCELLED), By Attribute (no active attribute), Select
  Grouped (its poll fails without a window even under the 3D View override).
- **Refusals in words, and nothing half done.** Measured in 5.2.1: Shortest Path
  with one element returns CANCELLED silently; object Select Linked by Material
  on an object with none returns CANCELLED having deselected everything, and
  with no active object raises "No active object", again after deselecting;
  Select Hierarchy's poll fails with no active object. Each is refused with a
  sentence, and a CANCELLED or an error in Object Mode puts the selection back.

Measured. `run-regionselect-blender-check.sh` runs Blender's own select
operators with X-Ray on over a grid, a cube and a UV sphere — 54 gestures, box,
circle and lasso in vertex, edge and face mode — and the Swift pass over the
same regions in the same view: every one element-for-element the same. Each
pick pushed as the app pushes it, Blender holds exactly those elements (edges
compared by their ends: a UV sphere added with an undo stack numbers its edges
differently from one added without). On a 7 × 7 grid the menu gives round 2's
numbers: More 1 → 9, Less 9 → 1, Linked 1 → 49, Non Manifold 1 → 25, Shortest
Path 2 → 5, Checker Deselect 49 → 24; all 22 Similar types run. Without X-Ray,
a box over a cube takes 7 vertices, 9 edges and 3 faces; with it 8, 12 and 6.
Face mode first took 4 or 5 faces of the cube at some view sizes: a sample on a
silhouette edge rounded into the back face and out of the front one. Each
edge's inside test is now written from its two vertex numbers in a fixed order,
so both faces answer alike, and front faces are drawn last; over three view
sizes and three distances the pass takes exactly the faces turned to the camera
(`run-regionselect-tests.sh`, 70 checks; 80,000 triangles, the whole view, face
mode: 16 ms).

**Run in the real app on 2026-09-22** (Designed for iPad, real bpy), through the
calls a drag and a menu row make (`-region-select`, `-select-menu`):
a 7 × 7 grid from the top — box 9 vertices, circle 3, lasso 15, Shift-box
adding nothing it missed, a Ctrl-lasso over the lot 0 — each time with Blender
holding exactly the vertices the viewport showed, and the drawn region the one
committed. A cube in perspective: 7 / 9 / 3 in vertex, edge and face mode, 8 /
12 / 6 with `-xray`. Objects from the top: a circle on Body's origin took Body,
one on its surface off the origin nothing, a lasso round Wheel.L's origin
Wheel.L, Shift-box added Body, Ctrl-circle took Wheel.L away, a lasso round
everything took all five, the camera included. The menu: More 1 → 9, Less → 1,
Non Manifold → 25, Shortest Path with nothing selected refused in words, 2 → 5
from two corners, Random 24 and then, through the redo panel's `readjust`,
Ratio 25% → 12, Checker Deselect 49 → 24, Similar Normal → 49, Boundary of
Selected 49 → 24; Active Camera, All by Type, Select Pattern `Wheel*`, Parent,
More, Mirror, Random, Invert and All in Object Mode, Select Linked by Material
and Less refused with the selection unchanged. Viewport and Blender agreed after
every one. A gesture that changes nothing sends nothing and leaves no undo
step, as Blender's CANCELLED does: a Shift-circle over empty space and a box
repeated exactly pushed none, while the lasso and the first box pushed one each.
No crash. Not checked by eye: the stroke overlay is drawn from the region the
check compares, but no screenshot of it was taken.

**Circle and Lasso select, after review** (2026-10-01). An adversarial review of
the entry above found a crash, two ways the pass and the push disagreed with
what the viewport shows, and smaller gaps. Each fix is measured.

- **A far vertex trapped the app.** `DepthBuffer.rasterise` turned a triangle's
  screen bounds into Ints before clamping them, and `Int(_:)` of a value past
  Int.max traps: a 2 × 2 grid with one vertex at X = 1e17, top orthographic,
  any Box, Circle or Lasso with X-Ray off (the default) stopped the process
  (exit 133) in vertex, edge and face mode. Every view-to-index conversion now
  clamps first (`clampedIndex`), an edge's sample count is counted as a float,
  and a vertex whose projection is not finite is off screen. Host suite: a
  vertex at 1e17, 3e38, infinity and NaN, orthographic and perspective, all
  three modes — no trap, and the centre vertex still taken.
- **A floor reaching behind the eye stopped hiding anything.** A triangle with
  a corner behind the eye was left out of the depth buffer, so a floor, a wall
  or terrain hid nothing once the camera came close. It is now clipped at the
  near plane, as Metal clips it (clip z ≥ 0), with each edge's cut computed
  once so neighbouring triangles still meet exactly. A 100 × 100 floor over a
  21 × 21 grid one unit below: hidden grid vertices taken 0 / 321 / 321 / 265 at
  distances 200 / 60 / 20 / 8 before, 0 at every distance after (host suite);
  in the app at perspective distance 8 and 20, 0 without X-Ray and 296 and 441
  with it, Blender holding exactly what the pass picked.
- **Edit Mode under a modifier that rebuilds the mesh wiped the selection.**
  The viewport draws Blender's evaluated mesh, whose vertices the mirror cannot
  name as Blender's, and the only push left (`Bpy.selectVertices`) deselects
  everything and matches by position. Measured in desktop 5.2.1 with the app's
  context: a cube under Subdivision Surface draws 26 vertices over Blender's 8,
  and with all 8 selected the fallback handed all 26 left 0 of 8; under Mirror
  it left 8 of 8, but the viewport showed none selected either way. Box, Circle
  and Lasso now refuse in words there (`BKObject.editRegionRefusal`), naming
  the modifiers that rebuild the mesh and saying to hide them in the viewport
  or apply them — with the modifier hidden both meshes line up at 8 vertices
  and 12 triangles (held by the Blender check). In the app, a Subdivision cube
  with everything selected: Lasso, Box, Circle and a face-mode Shift-Box each
  refused, Blender holding 8 / 12 / 6 after every one; with the modifier
  hidden, Box took 7 / 9 / 3, a Ctrl-Circle took one vertex away (7 → 6), and
  pass, Blender and viewport agreed on vertices, edges and faces. A mesh under
  Mirror loses region select on the device until its Mirror is hidden. Taps
  still go through the position fallback, unchanged.
- **Mirrored objects' back faces won in face mode.** Front- and back-facing
  were read off screen winding alone, which a scale of -1 reverses. They now
  flip with the sign of the object matrix's determinant: the cube at
  scale.x = -1 in the outline sweep's nine views took 6 faces before and 3
  after; in the app 3 without X-Ray and 6 with it. (The renderer's own back-face
  culling of such an object is older and untouched.)
- **A bow-tie lasso selected nothing.** Its lobes' signed areas cancel to 0,
  which `isUsable` read as no area. The area is now what the even-odd rule
  covers (20,000 points for the test's tie); in the app a bow tie over the grid
  took 19 vertices, both lobes.
- **Shift+Ctrl intersects** on Box and Lasso, as 5.2.1's
  `_template_items_tool_select_actions` binds it; Circle's keymap has no
  Shift+Ctrl and keeps Ctrl's subtract. In the app a Shift+Ctrl lasso took 49
  vertices to 3, and a face-mode box 36 faces to 4.
- **A touch-only iPad can extend, subtract and intersect.** The Select tool
  menu has Blender's tool-header modes (Mode: Set, Extend, Subtract,
  Difference, Intersect; Circle has the first three), used when no key is
  held. In the app with Difference picked (`-region-action difference`) a box
  took 35 vertices and a narrower one toggled them to 20; a Circle, which has
  no Difference, set.
- **The Select menu.** Ungrouped Vertices is greyed outside vertex mode and on
  a mesh with no vertex group, where 5.2.1's poll refuses ("Must be in vertex
  selection mode", "No weights/vertex groups on object"; with 2 of 8 weighted
  it selected the other 6). Select Random's Ratio shows as Blender's factor,
  0.500 (subtype FACTOR), not 50%. Select Pattern returns FINISHED whatever
  matched (measured), so its refusal never fired and a pattern matching
  nothing left an undo step that changed nothing; Pattern, All by Type, Mirror
  and Random now refuse when the selection and the active object are as they
  were (a second Random with the same seed: refused, selection unchanged).
  The Blender check's Poles by Count, Boundary of Selected and Loop
  Inner-Region rows accepted any count; they are seeded where they act now: a
  cube's 8 corners, a 3 × 3 block's ring of 8, that ring's 9 inside.
- **The in-app check measures what it claims.** `-region-select` compared the
  stroke the overlay is given with the region committed, both read from the
  same gesture state, and Blender with the viewport by vertices alone. It now
  samples the overlay's shaded path (`SelectionStrokeOverlay.shaded`, the path
  its Canvas fills) against `SelectionRegion.contains` — 0 differing samples of
  1,141 to 20,091 in every gesture run — and compares the pass's pick, Blender
  and the viewport by vertices, edges (by their ends) and faces (as Blender's
  polygons). `+intersect` and `-region-view persp:<distance>` were added. An
  edit-mode Ctrl-Circle that takes something away, which the 2026-09-22 run
  never showed: on the 7 × 7 grid from the top, face mode 36 faces to 32,
  vertex mode 19 vertices to 18, each with pass, Blender and viewport agreeing.

`run-regionselect-tests.sh` 100 checks (70 before), `run-regionselect-blender-check.sh`
204 (194). Still open: the vertex visibility test's neighbourhood allowance lets
a hidden vertex beside another surface's outline count as shown (in the host
harness, 15 of 441 grid vertices under a floor were taken where a small second
grid above the floor met it — older than this round); the object-mode Select
Random and Select Pattern still have no redo panel; the simulator's stand-in
has none of the new menu's operators.

**Sculpting with Blender's own brushes** (2026-09-22). Sculpt Mode, with the
real Blender, is now Blender's Sculpt Mode and Blender's brushes. Picking Sculpt
runs `mode_set(mode='SCULPT')` as an undo step, and a finger's or the Pencil's
stroke goes to `bpy.ops.sculpt.brush_stroke` while it moves
(`_blenderkit_sculpt`, `SculptBpy`, `SculptStrokeInput`). The six Swift brushes
are the simulator's alone, under a Sculpt menu section that calls them an
approximation. The header in Sculpt Mode (`SculptHeader`) has Blender's
Essentials brushes (`brush.asset_activate`), Size and Strength written where
Blender reads them (the unified Size, the brush's Strength) and read back,
Invert (Blender's Ctrl, held by the app), Mask (Clear, Invert, Fill, the Mask
brush), Face Sets (Initialize by six rules, From Masked, the Face Set Paint
brush), and a popover with Dynamic Topology and its detail size, Voxel Remesh
and its voxel size, and Multires Subdivide. The Add and Mesh menus and the
Object operations are refused in Sculpt Mode, in a sentence, as Blender's
Sculpt Mode has none of them. `primitive_cube_add` in Sculpt Mode crashes
Blender. The bpy staged into the app had no `datafiles/assets`, so no brush
at all: Blender 5.2.1's CC0 `essentials_brushes-mesh_sculpt.blend` is now in
`Resources/BlenderAssets` and staged by `stage-blender.sh`. In the app all 64
brushes are listed.

What the design rests on, measured in desktop 5.2.1 with the app's context and
held to it by `run-sculpt-blender-check.sh`:
- The stroke runs through the 3D View Knife Project borrows (`view3d` and
  `require_gpu_context` are now public in `_blenderkit_knife`, not copied). It
  is aimed at the app's camera: rotation, pivot, distance, and a lens that
  makes one region pixel one of the app's points. Blender's perspective focal
  length is lens × max(W, H) / 72 px: 1093.06 px at 50 mm in a 1574 px region.
  Four ViewportCameras, two of them orthographic, one from straight above and
  one from below, put every test point within 0.0001 px of where Blender's
  aimed view draws it.
- Called by EXEC_DEFAULT the operator does no spacing, so `_space` does it
  (spacing % of the diameter, Blender's rule). It also skips the checks
  Blender's `invoke` makes, and five desktop crashes came from that: Erase
  Multires Displacement with no Multires (segfault in do_brush_action), a
  Mask stroke on Multires with no grid mask, and a Paint brush under dynamic
  topology or on Multires (both abort), plus `RegionView3D.update()` called
  before the GPU module (GPU_matrix_frustum_set). Each is now refused in
  Blender's own words, or its layer is made first (a box mask outside the
  view). After that, all 64 brushes on a plain sphere, under dynamic topology
  and on a Multires level, and every header operation on all three, ran or
  were refused. None crashed.
- A stroke cut into separate strokes is not Blender's stroke. A 21-dab Draw
  stroke moved vertices at most 0.225 as one stroke. Sent as strokes of 8, 4
  and 1 dabs it moved them 0.289, 0.391 and 0.413, because Draw raycasts the
  surface as it was when its stroke began. So each chunk undoes the stroke so
  far and replays it whole. The check finds the same result to the bit for
  chunks of 24, 8, 4 and 1 points. A stroke is cut into a new one past 64
  dabs, or once a replay and the rewind before it pass 25 ms (2026-10-01). Grab, Thumb, Pose, Boundary and Elastic Grab
  replay only [first dab, current dab]. Dragged past the silhouette, Grab
  pulled the sphere from x = 1.0 to 1.211.
- Without `undo=True` a Python stroke pushes no step, and the next stroke frees
  the step it began. With it, each chunk pushes one. A stroke's steps are
  counted on Blender's stack. The stack is read with
  `WindowManager.print_undo_steps`, whose printf output is captured from file
  descriptor 1. The count goes to the history as one step that deep
  (`_blenderkit_undo.note_pushed`), and one Undo takes the whole stroke back.
  A zero-strength first dab gives the replays a Sculpt step to rewind onto
  instead of a memfile step: 0.3 ms instead of 5 to 6.
- The evaluated mesh is stale after a stroke, after dynamic topology and
  after an Undo in Sculpt Mode. In the app, a Redo of a stroke first showed
  the mesh from before it (0 of 1,986 vertices moved, where the stroke had
  moved 388). The mirroring pass now refreshes the sculpted object first. The
  desktop check shows the same stale mesh: after a Redo, 76 vertices were
  0.166 off the mesh until it was refreshed. A
  Multires level is not in the evaluated mesh at all: that is the base, 266
  vertices where the level has 4,418. It is read from a temporary object in
  Object Mode, with the level flushed into it. Copying the object instead
  crashed desktop Blender, because the copy keeps the Sculpt Mode flag. The
  level is read when a stroke ends, not per chunk, and is cached by where the
  history stands. On Multires the mask is not drawn: it lives in grids that
  Python cannot read.

**Run in the real app on 2026-09-22** (Designed for iPad on this Mac, real bpy,
the `-sculpt-enter`, `-sculpt-stroke`, `-sculpt-ops`, `-sculpt-brush` and
`-sculpt-undo` hooks, which feed a 60-point stroke at 60 Hz through the calls a
drag makes). No crash report, and no crash in any run:
- A 1,986-vertex sphere, framed, Draw, with the final build: 27 chunks and
  36 dabs. Chunks took 10.5 ms median and 26.7 ms max, of which Blender's
  stroke was 9.1 ms and the mirror 1.0 ms. The viewport showed 233 vertices
  moved, at most 0.2365. Undo showed 0, still in Sculpt Mode, and Redo showed
  233 again. Desktop Blender reading the autosave: 233 of 1,986 moved, at
  most 0.2365.
- The dinosaur's body (a copy of the detailed file, Sphere.002: 482 base
  vertices under Subdivision, 15,872 triangles drawn), framed: chunks 32.7 ms
  median and 44.9 ms max (rewind 10, stroke 11, mirror 10). 2,182 of 7,938
  drawn vertices moved, at most 0.275. Undo and Redo were exact. The autosave
  has 64 of 482 base vertices moved, at most 0.3012.
- A 99,840-triangle sphere: chunks 16.2 ms median, 19.2 ms max. 5,663 of
  49,922 vertices moved, at most 0.2415, and the autosave agrees exactly.
- The chunk policy follows from these numbers. The first point goes at once.
  After that a chunk goes at least 1/30 s after the last one and never sooner
  than the last one's cost: about 15 to 30 Blender results a second, with half
  of the main thread left for touches and drawing (`SculptStreamPolicy`).
- Grab: 38 vertices moved, at most 0.809, in 5.4 ms chunks. Dynamic
  Topology: 1,986 → 1,645 vertices; after Undo the same positions (0.0000
  apart), in another order. The Mask brush: 233 of 1,986 masked in the
  autosave, and the viewport darkened the same 233 (0 after Undo, 233 after
  Redo). Size 60 and Strength 0.8 read back. A switch to Clay Strips
  showed its own Strength, 0.5. Clay Strips at 120 dabs was cut once.
- Voxel Remesh at 0.05 (1,986 → 7,832 vertices), Multires Subdivide (31,322
  drawn) and a stroke on the level: 5,103 moved, at most 0.241, drawn when the
  stroke ended. Undo and Redo are right but slow in the app's build: Undo took
  4.55 s in Blender (0.73 s in desktop 5.2.1) and the mirror took 9.1 s to read
  the level after each. That is still to be done.

Checked by `run-sculpt-tests.sh` (39: the Python each control sends, the
answers read back, the chunk policy, the Size field) and
`run-sculpt-blender-check.sh` (114 checks: the strings the Swift sends, put
through desktop Blender. The ViewportCamera points come from the Swift itself,
and it takes about 75 s). `run-3dview-blender-check.sh` now expects Sculpt Mode
to follow Blender's mode (an Undo out of it leaves it), where it used to
expect the app's own sculpting to outlast Blender's object mode. Painting still
does.

**Sculpting: the defects round 3's review found** (2026-10-01). Each was
reproduced or measured in desktop 5.2.1 with the app's context before it was
fixed, and every fix was then run in the real app (Designed for iPad on this
Mac). No crash in any run.
- *Voxel Remesh's guard did not guard.* It counted world-space bounding-box
  cells, where Blender remeshes in the mesh's own units and its output follows
  the surface. Now the estimate is 2.5 × local surface area / voxel²: output
  over area/voxel² measured 1.02 (a cube) to 1.71 (a small sphere) for closed
  shapes and 2.08 to 2.42 for an open plane, so 2.5 bounds them all. It is
  held to the Multires vertex budget (2,500,000) and to the memory left, at
  800 bytes a vertex (desktop peaked at 450: 395 → 925 MB for 1,178,936). A
  2 m model imported at scale 0.01 at the default 0.1 voxel is refused
  (about 31 million). So is a 2 m plane at the field's 0.0001 minimum
  (about 1 billion). The refusal gives the smallest size that fits. The field
  shows the number Blender holds, with no unit on a scaled object, and a line
  under it with the size in the scene.
- *Multires froze the app.* Its cost follows the base mesh, not the level:
  every re-evaluation of the sculpted object rebuilds the level from the base.
  Desktop, reading the level back: 60 ms at a 482-vertex base, 312 at 1,986,
  1,049 at 4,514 and 9,822 at 18,242. The level barely matters (1,986 at
  levels 1 to 3: 312 to 366 ms). The app's Blender does this about five times
  slower. A Draw stroke's end, its Undo and its Redo in the app: 0.44, 0.71
  and 0.39 s at 482; 1.78, 2.69 and 1.73 s at 1,986; 5.43, 8.11 and 5.48 s at
  4,514. So Multires is sculpted only on a base mesh of up to 2,000 vertices
  (`MULTIRES_BASE_BUDGET`). Above that, Subdivide is refused, entering Sculpt
  Mode is refused, and a level opened in Sculpt Mode from a file is neither
  read back nor sculpted. Each refusal is a sentence that gives the
  measurement. On a level, a stroke is gathered and made as Blender's one
  stroke when it ends. Rewinding each chunk cost a rebuild: 31 ms at 482,
  13.3 s at the review's 49,922. Nothing could be shown per chunk anyway. The
  mask read is skipped on a level, because the mask lives in grids Python
  cannot read. That read only re-evaluated the level, 2.7 of 5.4 s.
- *A replay over budget was never cut when its rewind was dear.* The budget
  now counts the last rewind too. Under Dynamic Topology on 99,840 triangles,
  one 37 ms rewind is paid and every later chunk is cut: 18.8 ms median and
  41 ms max, against 80 to 105 before. In the app (Designed for iPad on this
  Mac, not an iPad) chunks took 59.7 ms median and 104 ms max. Blender's
  stroke was 2 to 15 ms of that, with one 26 ms rewind. The rest is the
  mirror: about 55 ms a chunk to flush the BMesh and push some 45,000
  vertices. No iPad has been measured.
- *A chunk whose replay made nothing lost the stroke.* Found while checking
  the Grab fix: begun at a sphere's silhouette under Subdivision, Blender's
  Grab pushes nothing once dragged past about 270 px (desktop 5.2.1; without
  the modifier it never stops). The next chunk's rewind had already taken the
  last step back, so Blender held the mesh from before the stroke while the
  viewport showed the last chunk. The rewound step is put back now
  (`ed.redo`). In the check, Blender held what the viewport showed after all
  30 chunks, 9 of them put back.
- *Undo, Redo and the header ran under an open stroke*, and the next chunk's
  rewind undid them. While a stroke is open (`BpySession.sculptStrokeOpen`),
  the session refuses Undo, Redo, scripts, console lines and file opens. The
  bridge refuses every command, the top bar and the keyboard grey Undo and
  Redo, and `choose` holds the tool and the mode. The Python refuses too:
  `_blenderkit_undo.step`, every header operation and setting
  (`_refuse_during_stroke`), and a chunk whose undo stack has moved. In the
  app (`-sculpt-midstroke undo|mask|leave`), each was refused at mid-stroke.
  The history stayed 'Sculpt Mode', the stroke was one 2-step 'Sculpt Stroke',
  and Undo/Redo gave back 0 and 233 moved vertices.
- *A mode change mid-stroke left the stroke open.* The drag that touched
  down owns the stroke until it lifts (`sculptDrag`). If Sculpt Mode goes
  under the finger, the stroke ends there, kept, and the rest of the drag
  does nothing. In the app (`-sculpt-midstroke mode`), the stroke ended at 13
  of 27 chunks and was recorded as one step. The camera did not move, and
  every flag was clear after the lift. A stroke whose end never came is
  counted into the next stroke's history step, so one Undo takes both back.
- *Grab on Multires anchored on the base.* The Grab-family brushes now
  start on the surface Blender sculpts. On a Multires level that is the level
  read back, as a BVH. With a generative modifier it is the base mesh with
  its deform modifiers (`BVHTree.FromObject(deform=True, cage=True)`). In the
  app a Grab on a 1,986-vertex base's level moved 155 of 8,066 level
  vertices, and Undo and Redo were exact.
- *Strokes were refused after relaunching in Sculpt Mode.* A file opened in
  Sculpt Mode has no brush tool running in the 3D View's area, and
  `brush_stroke.poll()` is False. `begin` starts it
  (`wm.tool_set_by_id('builtin.brush')`, which pushes no undo step and keeps
  the brush). In the app, the autosave reopened in Sculpt Mode and a stroke
  moved 1,278 of 7,832 vertices. Undo and Redo were exact. Left as found:
  with an object in Sculpt Mode at launch, the history cannot probe Blender's
  undo, so it keeps .blend checkpoints for the session (`probe` is deferred).
- Smaller fixes: the zero-strength anchor dab also zeroes Auto-Smooth (Density
  moved 10 vertices without it). Face Sets are refused under Dynamic
  Topology in words, because Blender's operators cancel there silently, and
  the header greys them. The mask on a Multires level reads as unknown, not
  0. The menus no longer ask SwiftUI for a symbol named "".

**The Modifiers panel shows every modifier Blender has** (2026-09-22). The
sixth instance of the defect this app keeps shipping: `_modifier_record` sent
only the kinds the app modelled and `Modifier.stack(from:)` dropped the rest,
so round 2's reviewer, on a cube with Multires, Weighted Normal, Edge Split,
Laplacian Smooth and Subdivision, saw the Subdivision alone, and a mesh changed
only by one of the others read "No modifiers" with no way to turn it off,
apply it or remove it.

- **Every modifier gets a row, in Blender's order.** A kind with no settings
  rows here is `.other`, carrying Blender's type and its menu name from RNA
  (`SURFACE_DEFORM`, "Surface Deform"). Every row, whatever its kind, has
  Blender's header: Show in Viewport and in Render (`show_viewport`,
  `show_render`, now in every record), a menu with Apply
  (`object.modifier_apply` — it existed as `Bpy.applyModifier` and no row
  called it), Move Up and Move Down, and remove. An `.other` row opens the
  Every Property browser on that modifier (`Bpy.modifierDataPath`), so its
  settings are Blender's RNA one tap away.
- **Six kinds made first-class**, end to end through the model, the record,
  the parser, `Bpy.modifierSettings`, the row and the simulator's stand-in:
  Weighted Normal (weighting, Weight as a whole 1–100, Threshold, Keep Sharp,
  Face Influence), Multires (the three levels, the total, and Subdivide /
  Unsubdivide / Delete Higher / Apply Base through `object.multires_*`), Edge
  Split, Laplacian Smooth (its X/Y/Z are `use_x/y/z`, Wave's Motion names, so
  the record is read per kind; so is `mode`, Remesh's and Weighted Normal's),
  Corrective Smooth (rest source and binding shown, never sent) and Lattice
  (a picker of lattice objects only: Blender leaves a mesh assigned there
  None without a word). Blender's defaults, names and ranges were measured in
  5.2.1 and are the `Modifier(kind:)` defaults. Simple Deform's added name is
  `SimpleDeform`, not `Simple Deform`.
- **The Multires buttons run in object mode** (corrected by round 3's
  review, below). All four pass their poll in Edit and Sculpt Mode. Measured
  again in desktop 5.2.1 with the app's context: Blender's own Apply Base
  segfaults in Edit Mode in `multires_reshape_create_subdiv`, and in Sculpt
  Mode only with no undo stack, in `sculpt_paint::undo::push_begin_ex`;
  Unsubdivide in Edit Mode does not crash, but leaving Edit Mode writes the
  98-vertex edit mesh back over the 26-vertex base it rebuilt. In the app, an
  unguarded `multires_base_apply` from Edit Mode killed it (EXC_BAD_ACCESS in
  `subdiv::new_from_mesh`). The buttons now call `_blenderkit_multires.run`,
  which takes the object to Object Mode, refuses when Blender will not, and
  puts the mode back. Subdivide on a mesh with no faces returns FINISHED
  having made nothing, so the module refuses it. A move Blender cancels
  ("Cannot move above a modifier requiring original data", "Cannot move
  beyond a non-deforming modifier", past either end) is raised in words
  instead of reported done.
- **Names are escaped in the record.** Blender takes `a;b|c=d%e` as a
  modifier's name; unescaped, it split its entry and every edit raised
  KeyError. Values are percent-escaped by `_modifier_value` and decoded in
  `Modifier.fields`. One modifier whose settings cannot be read now arrives
  as an `unread` row with the header only, where it used to drop the stack.

Measured in the real app (Designed for iPad on this Mac, real bpy), driven by
`-modifier-steps`, which sends what the buttons send: on a fresh cube with a
script's Wireframe and Surface Deform, Add Modifier for each of the six, then
edits of each, two Multires Subdivides, a Lattice pointed at a lattice object,
both switches, three moves (the third refused in words) and a remove — every
row showed Blender's value after each step. Restarted with `-modifier-dump`,
the seven rows came back from autosave.blend, and desktop Blender reading the
same file held the same seven with the same values and 96 evaluated vertices,
as the app drew. Apply: a Subdivision at 2 baked (98 vertices), Unsubdivide
twice (26, then 8 and two levels), a third refused, a Lattice with nothing
picked refused with Blender's "Modifier is disabled, skipping apply". Not
tapped: the rows were driven through the hook, not a finger, and the Every
Property link was checked in Blender (`inspect_data` / `set_property` on the
path the Swift builds), not opened on screen. Found on the way, and since
fixed: `bpy.ops.wm.read_homefile()` run from a script on the script thread
segfaulted the app (`WM_event_modal_handler_region_replace` in `ED_screen_exit`);
see "Loading a file from a script crashed the app" under Landmines.

**Round 3's review of the Modifiers panel: Multires's budget and modes**
(2026-10-01). Measured in desktop Blender 5.2.1 with the app's context (an
undo stack from `ed.undo_push` under the startup window and screen,
`gpu.init()`), then in the app (Designed for iPad on this Mac, real bpy),
driven by `-modifier-steps`.

- **Subdivide has a budget.** Each press is four times the mesh, and Blender
  evaluates the new top level at once. On a 2 m cube, over the 286 MB desktop
  Blender starts at: level 8 is 393,218 vertices and 142 MB, level 9
  1,572,866 and 557 MB, level 10 6,291,458 and 1.65 GB in 3.4 s (2.55 GB with
  an undo step per press, the review's figure). In the app, from a 478 MB
  footprint: the cube's level 9 peaked at 1.45 GB resident and settled at a
  908 MB footprint; a 32x16 UV sphere's level 6 (2,031,618) peaked at 2.05 GB
  and settled at 1.32 GB. `_blenderkit_multires` refuses, before anything
  runs, a level past 2,500,000 vertices, or one needing more than
  `os_proc_available_memory` says is left at 800 bytes a vertex (the app
  measured 560 to 730 at the peak) — the second is what holds on an iPhone or
  an older iPad. The count is exact (`level_vertices`, Catmull-Clark from the
  base mesh's vertices, edges, faces and corners): it matched `to_mesh()` at
  every level of a cube, a UV sphere and an open grid. The Sculpt header's
  Subdivide and F3's `object.multires_subdivide` keep the same budget. In the
  app: the cube's tenth press and a 100x100 grid's fourth (2,563,201) were
  refused with the banner "Multires Subdivide: Level 4 would give Grid
  2,563,201 vertices, and this app stops a Multiresolution at 2,500,000…".
- **Object Mode is checked, not assumed.** `BpyModeGuard` swallowed a failed
  `mode_set`, so an object in Sculpt Mode with Disable in Viewports on ("Cannot
  edit hidden object") got the operator in Sculpt Mode, where Apply Base with
  no undo stack segfaults. `_blenderkit_multires.run` refuses on the main
  thread only, on a mesh with that Multires, and only once the object is in
  Object Mode: "Apply Base runs only in Object Mode, and Blender would not take
  Cube out of Sculpt Mode: Cannot edit hidden object." Measured in desktop,
  with and without an undo stack: all four refused and nothing changed.
  Without an undo stack is what `run-modifier-blender-check.sh` has, so the
  old path would have killed it. All four were measured safe on a hidden
  object in Object Mode, either kind of hide. `BpyModeGuard` itself now
  refuses ("This runs in Object Mode, and Blender would not switch to it:
  Cannot edit hidden object") instead of running the operator where Blender
  was: measured on the same hidden Sculpt Mode object, the old guard ran
  `primitive_cube_add` in Sculpt Mode, which with no undo stack segfaulted
  in `sculpt_paint::undo::geometry_begin_ex`. The menus' operators from every
  start mode (`run-modeguard-blender-check.sh`) still run and hand the mode
  back.
- **Sculpt Mode keeps Blender's meaning.** Blender's own Delete Higher and Apply
  Base work from the sculpt level there, and its Subdivide leaves the viewport
  level alone. From viewport 1, sculpt 2, total 3: Blender's Delete Higher
  leaves 1/2/2 and the old guarded call 1/1/1 (the sculpted level gone);
  Subdivide leaves 1/4/4 where the old call gave 4/4/4. The module lends the
  viewport level the sculpt level while the operator runs, and puts it back:
  in the app, 1/2/2 and then 1/3/3, as Blender's own. One case differs and
  cannot match: Blender's Delete Higher from viewport 3, sculpt 2 leaves the
  viewport level at 3 over a total of 2 (drawing level 3), which RNA cannot
  set; here it reads 2. Delete Higher is disabled by the level Blender shows.
- **Disabling a sculpted object leaves Sculpt Mode first** — found by the app
  crashing on the review's own path. A Multires cube put in Sculpt Mode with
  F3, then Show in Viewports off, took the app down on the next mirroring pass
  (`ed.flush_edits` → `multires_flush_sculpt_updates` →
  `subdiv::face_ptex_offset_get`, a null Subdiv): Blender stops evaluating a
  disabled object while its sculpt session still points at the last
  evaluation, and will not take it out of Sculpt Mode. Desktop Blender did not
  reproduce it (no PBVH was ever built there). `Bpy.setDisabledInViewports`
  now leaves Sculpt or a paint mode before disabling the active object, and
  the mirror reads no sculpt session of an object it does not draw. In the
  app: the same steps left Sculpt Mode, Apply Base ran on the hidden object,
  and the app stayed up. Still open: a script or F3 that disables an object
  in Sculpt Mode, then a save, may reach the same stale pointer inside
  Blender's own `ED_editors_flush_edits`; not reproduced, not guarded.
- **Smaller ones.** The Move refusal names both types that need the original
  mesh, Multires and Soft Body (a Subdivision is refused under a Soft Body
  with no Multires). Add Modifier leaves out the six kinds Blender refuses on
  a curve, text or surface (Displace, Boolean, Weighted Normal, Multires,
  Laplacian and Corrective Smooth; measured on all three). The Lattice
  picker has None, which sends `object = None`. An unreadable modifier's row
  now carries its two switches as Blender holds them, and no longer claims a
  modelled kind "has no rows of its own". The simulator keeps Blender's rules:
  a Multires is added above the first modifier that is not a pure deform,
  moves around one are refused, Corrective Smooth's Only Smooth smooths, and
  Apply on a Boolean, Shrinkwrap or Lattice with nothing picked is refused
  with "Modifier is disabled, skipping apply" (host-tested and measured in
  Blender; the simulator itself was not run). Not changed: the simulator's
  Multires still draws at most level 3.

**Round 2's open mediums and lows, and the operator search that could crash
Blender** (2026-09-22). Everything below was measured in desktop Blender 5.2.1
with the app's context (an undo stack from `ed.undo_push` under a window and
screen override, `gpu.init()`), and the in-app runs were made only after the
same call was safe there.

- **More ▸ All Blender Tools no longer crashes Blender.** Its code starts with
  an import, so `BpyModeGuard` never bracketed it, and `run_operator` checked
  the poll alone: `object.multires_base_apply` (Edit and Sculpt Mode) and
  `object.multires_unsubdivide` (Edit Mode) pass it and segfault. The search
  now takes the menus' rule (`operator_mode`: object.* in Object Mode, mesh.*
  and uv.* in Edit Mode, adds in Object Mode), puts the mode back, and leaves
  the five object.* operators with "mode" in their name alone. The 22 object.*
  operators whose poll fails in Object Mode and passes in Edit Mode (hooks,
  vertex groups, skin, vertex parent — measured on three fixtures) run where
  the user is; any other the rule's mode refuses is refused, never tried in
  the user's mode. A new check, `run-opsearch-blender-check.sh`, runs every
  operator the search lists with its defaults through `run_operator` —
  object/mesh/uv on three fixtures (a cube; with a vertex group, Multires and
  Hook; with Skin) and modifier names filled in, the rest on a cube, each from
  Object, Edit, Sculpt and Texture Paint: 13,852 runs, one Blender per fixture
  and mode, restarted after anything that kills it. It found two more that the
  rule could not help: `uv.stitch` segfaults (`stitch_exit`) and
  `uv.select_edge_ring` never returns, from every mode, with no UV Editor.
  Both are refused by name, and the form says why. After the change: 0
  crashed. The old `run_operator` on the same Apply Base from Edit Mode is the
  check's negative control, and still crashes. The form now says which mode an
  operator runs in when that is not the current one, and asks Blender's poll
  there when Run is pressed rather than switching modes to draw itself. In the
  app (`-opsearch`): Apply Base from Edit Mode ran, and Edit Mode came back
  (desktop Blender reading the autosave: the base pulled in from |x| 1.0 to
  0.9444, one level kept); Unsubdivide was refused in Blender's words;
  `uv.stitch` refused with the form's sentence. No crash in any run. The
  search's Shade Auto Smooth now names the missing Essentials library, as the
  3D View's row does.
- **The frame path is linear.** `SceneMirror.carryLocal` and
  `AnimationMirror.applyMesh` look names up through one index per frame
  (`SceneMirror.frameIndex`, dropped by `anim_frame` and at each pass): 0.55 ms
  at 1,000 keyed objects and 1.89 ms at 3,000, where the walk cost 10.3 and 88
  ms. The Python half had the same shape — `scene.objects.get` per changed
  name, 154 of 212 ms at 3,000 (cProfile) — and `push_frame` now takes each
  object from its depsgraph update: 28.8 → 11.2 ms at 1,000 and 200.6 → 36.1
  ms at 3,000 in desktop Blender. In the app a frame change took 36.1 ms at
  1,000 and 231 ms at 3,000 before, 17.9 and 54.7 ms after. A frame change in
  Edit Mode also leaves out hidden faces now, as a pass does (a 10 × 10 Wave
  grid with 50 hidden: 100 triangles sent, 200 in Object Mode).
- **Frame All frames what is drawn**, as View All does (measured through a 3D
  View override: 160.4 with a 2 m cube and a 100 m plane, 3.208 with the
  plane hidden or disabled, and the view left alone with everything hidden).
- **Edit Mode with nothing selected has no gizmo.** The object branch it fell
  into moved the edited cube and pulled its neighbours while Blender answered
  the commit with CANCELLED.
- **Affect Only Parents, Affect Only Origins and Split Edges & Faces are
  mirrored** (bits 4, 8 and 16 of the tool state's eleventh int), shown in
  Transform Tools and written through `bridge.run`. The drag honours the first
  two, measured case by case: an unselected child stays with Affect Only
  Parents (a selected one moves), the geometry stays and children follow the
  origin with Affect Only Origins (a selected child's geometry stays too).
  The tools check's 18 new cases (the family moved, turned and scaled, with
  each and both, one or two selected) put every object's geometry where the
  preview drew it, to 4.9e-7. With Affect Only Parents a child that stays is
  a snap target again; with Affect Only Origins everything is, the
  selection's own geometry included (both read from 5.3's source). Split
  Edges & Faces is shown and honoured only partly: the positions the drag
  shows are Blender's (a vertex dropped 0.0004 off another mesh's edge stays
  there and the edge bends through it: 7 vertices either way), but the split
  edges, and a vertex where a moved edge crosses another (7 → 9), appear only
  with the commit; the panel says so. The simulator's transform refuses Affect
  Only Origins and Split rather than run as something else.
- **The UV Editor draws the map Blender's UV Editor draws**: the object's own
  mesh before its modifiers (`sync_uv_layout`, `BKObject.uvLayout`), sent only
  when it differs from the drawn mesh's map. A cube under a level-1
  Subdivision drew 144 corners and 96 polygon sides; now 36 and 24, as
  Blender's. On a copy of Scene.blend: 11 of 80 meshes sent, 152,808 bytes,
  0.4–0.6 ms of a 6 ms pass. In Edit Mode the edit mesh is read through the
  original object's `to_mesh()`; a scratch datablock written from the BMesh
  made the next pass rebuild the depsgraph's relations, 3.8 ms more a pass,
  and the `to_mesh()` read costs nothing measurable. In the app
  (`-dump-state`): 26 vertices and 144 corners drawn, the editor on 36
  corners and 24 sides.
- **An unwrap that solves no island is refused, and the UVs put back**
  (captured from Blender's stdout warning); one that solves some keeps its
  result, and Blender's "Unwrap failed to solve 1 of 7 island(s)" now reaches
  the banner (`BpyBridge.blenderWarning`, for every command). In the app: a
  seamless cube refused, the map unchanged; a seamed cube with a plain one
  unwrapped with the warning shown. A refused unwrap on a mesh with no map
  used to leave the map it made; it no longer does. Pack Islands, Average
  Islands Scale, Seams from Islands and Follow Active Quads say the mesh has
  no UV map instead of "context is incorrect". The UV check's object-mode rows
  now unwrap a sphere with seams and must see no warning; before, a failed
  island's repack counted as an unwrap.
- **The simulator's edit mode works on the cage**, as Blender's does: taps,
  box select, Select All, the status bar, Frame Selected, the overlay and its
  buffers, and every `bk_scene_mesh_op` (now `BKScene.editMeshOperator`, where
  the host suites run it) number and edit `editCage` and install it once. With
  Mirror and Bisect, 22 of 24 output vertices had moved index; every visible
  cage dot now picks that cage vertex and the gizmo sits on it. Undo keeps the
  base (`SceneSnapshot.evaluatedMeshes`): drag, undo, redo had gone 24/48 →
  48/96, and 24/54 → 54/150 with a Subdivision; the old code still fails the
  new test with exactly those numbers.
- The mode-guard check's three unwrap rows now unwrap a cube with seams:
  on the seamless cube they "passed" because Blender answered FINISHED having
  unwrapped nothing, and with the refusal above they failed from all three
  modes until the fixture had something to unwrap.
- Smaller: the header's magnet lights on `snapsDrag`; Selection to Active and
  Cursor to Active are offered outside Edit Mode only (there is no active
  element there); Increment is kept above zero; the UV Editor's scope counts
  meshes only; stale comments about hidden objects corrected.

Not done: the split preview's topology (above); constraint followers in the
preview; which of two moved vertices a weld keeps; the selection overlay
during a weld; the snapped values' four decimals; QuadriFlow's orphaned
backup on refusal; the simulator's unwrap methods; option dialogs for the UV
rows. Found on the way, not fixed: from a script off the main thread,
`bpy.ops.mesh.select_all` in Edit Mode fails its poll in the app ("context is
incorrect"); the setups here mention `temp_override` to run on the main
thread.

**Join, Parent, Convert and the clean-up rows** (2026-09-22, round 3 group 5).
Operators round 2's reviewer measured working headless but that were reachable
only by name through All Blender Tools. Each was run first in desktop Blender
5.2.1 with the app's context (Blender's undo started through the app's own
`_blenderkit_undo.push`, the startup screen's 3D View for Shear), and in the
app only after that.

- **The Object menu's rows** (`ObjectMenuOps.swift`, shown by
  `ObjectRelationItems` in both the Mac menu bar's Object menu and More, in
  Blender's order after Duplicate): Duplicate Linked (⌥D, Blender's Alt+D),
  Join (⌘J, Blender's Ctrl+J), Parent ▸ Object, Object (Keep Transform),
  Clear Parent, Clear and Keep Transformation, Clear Parent Inverse, and
  Convert ▸ Mesh and Curve. Each is Blender's operator through `perform`, so
  the redo panel shows Keep Transform, the Clear type and Keep Original. The
  rows grey out where Blender would refuse (`ObjectRelationState`, from the
  mirror): not in Edit Mode, Join and Parent need two selected, Clear Parent a
  selected child. Measured, and each refused in words before Blender changes
  anything: `parent_set` with no active object or only the active one selected
  returns FINISHED and parents nothing; `parent_clear` with no parent in the
  selection the same; `join` into a camera, text, metaball, empty or lattice
  fails its poll ("context is incorrect"; mesh, curve, surface, armature and
  grease pencil join); `object.convert` of a camera or a light returns
  FINISHED having converted nothing, and a mesh becomes a curve only from its
  *loose* edges, of the mesh with its modifiers (a cube stayed a mesh and
  FINISHED came back; a circle under Solidify made two 32-point curves), so
  Convert ▸ Curve refuses a mesh whose every edge is in a face. Join's and
  Duplicate Linked's CANCELLED ("No mesh data to join", "Active object is not
  a selected mesh", nothing selected) become sentences. Numbers: a first
  parent never moves the child (Blender sets the inverse); re-parenting a
  child whose old parent had moved shifts it 2.0 m with Keep Transform off and
  0 with it on; Clear Parent Inverse moved a child 2.44 m; three cubes joined
  are one of 24 vertices; a cube under a level-1 Subdivision converted is 26
  vertices with no modifier.
- **Adjustable only through Blender's undo** (`Restoration.throughBlenderUndo`).
  Neither a removal nor a mesh backup can put back a parent or a join, so
  without Blender's undo these run and open no panel.
- **A redo-panel re-run hands back the object selection.** A tap in Object
  Mode (`BpyBridge.select`) is not an undo step, and the rewind restores the
  selection of the step before — so adjusting Keep Transform after tapping B
  and then C re-parented B to whatever was active at that step (measured in
  desktop Blender through `_blenderkit_undo`; the check keeps that as its
  negative control). `perform` now reads the selection from the mirror before
  an object-mode operator runs, and `readjustThroughUndo` puts it back first
  (`Bpy.objectSelection`, `BpyBridge.rerunLead`). This was true of every
  object-mode operator the panel adjusts (Shade Smooth by Angle, QuadriFlow).
- **The Outliner shows the hierarchy.** `BKScene.outlinerRows` nests each child
  under its parent from the mirror's `parentName`, with a guide line; a loop
  or a parent the mirror does not hold never hides an object. Children stay
  listed under a parent whose data rows are folded, where Blender hides them.
- **The Mesh menu** gains Split ▸ Selection, Faces by Edges and Faces & Edges
  by Vertices (a new Split group, Blender's Mesh ▸ Split), Clean Up ▸ Limited
  Dissolve, Delete Loose and Fill Holes, Edge ▸ Un-Subdivide, Fill ▸ Beautify
  Faces, Vertex ▸ Bevel Vertices, and Add Geometry ▸ Extrude Individual Faces
  (`mesh.extrude_faces_move`, whose `Bpy.extrudeIndividual` string no row called, now a row with its Offset), each with 5.2.1's fields and
  defaults, and Deform ▸ Shear. Measured on a 7 × 7 grid (49 vertices): Limited
  Dissolve → 4; Un-Subdivide → 22, and 28 with Iterations 1 from the panel;
  Edge Split → 144 either way; four faces split off → 54. Delete Loose took a
  loose edge and vertex off a cube (11 → 8), Fill Holes closed a missing face
  (not at Sides 3), Beautify Faces turned 18 of 120 edges on a wavy grid
  triangulated the fixed way. Each returns FINISHED having done nothing with an
  empty selection, so each refuses an empty one first, counting every mesh in
  Edit Mode as the operators do. Only an empty selection: one the row has
  nothing to do with (Fill Holes on a closed cube, Limited Dissolve on a cube,
  Beautify Faces on quads, Inset as a region on a whole cube) returns FINISHED
  with nothing changed, as in Blender, and still makes an undo step. Delete
  Loose looks for something its own switches remove, because with nothing to
  remove it still deselects everything. (Corrected by the review fixes below.)
- **Bevel's Affect and Inset's Individual** are panel fields. A cube's corners
  with Affect on Vertices: 56 vertices and 30 faces (Edges: 56 and 54); one
  corner alone 14 and 9, where Edges changed nothing. Bevel with nothing
  selected returns CANCELLED silently, now said in words. Inset Individual on a
  cube: 32 vertices, where the whole cube as a region stays 8.
- **Extrude started inward.** Its Offset defaulted to -0.2, and Shrink/Fatten's
  positive values go out: measured on a cube's top face, -0.2 put it at z =
  0.8, +0.2 at 1.2, through Extrude and Extrude Individual alike. Both start at
  +0.2 now.
- **Shear** (`LastOperator.shear`, Edit Mode) runs through
  `_blenderkit_context.temp_override_view3d`; it needs no GPU module. Its
  Axes field is the six valid pairs of `orient_axis`/`orient_axis_ortho`, so
  it cannot collapse the selection onto a point, and each is labelled by what
  it does ("Along X, by Y"): all six measured moving only that axis by
  tan(angle) × the other. The angle stops at ±80° (tan 90° threw vertices 13
  million metres) and Orientation is Global, so the borrowed view's rotation
  does not enter. In Object Mode the row is Object ▸ Transform ▸ Shear
  (`LastOperator.shearObjects`), which moves the selected objects' origins
  (see the review fixes below); the simulator has no 3D View to borrow.
- The simulator's stand-in refuses Inset Individual rather than inset a region,
  its Extrude Individual takes the offset it is given, and Duplicate Linked,
  Parent, Convert, Shear, Split and the clean-up rows say they need the real
  bpy instead of raising AttributeError (`run-tools-shim-tests.sh`).

Checked by `run-objectops-tests.sh` (91: the Python each row sends, the fields,
which rows are offered, the Outliner tree, the selection a re-run hands back)
and `run-objectops-blender-check.sh` (every string through desktop Blender with
the app's undo, the panel's adjustments through its rewind, refusals holding
the scene unchanged, then Blender's own mirror pushes replayed through the
Swift: every parent, type and count the app shows, and every object's
Outliner depth, as Blender has them). `run-redo-blender-check.sh` now gives
Delete Loose a loose vertex to remove. (The session that wrote these rows
also reported a 1,785-run sweep of every string from Object, Edit and Sculpt
Mode on seven fixtures; that sweep script is not in the tree and was not
re-run.)

**Finished, and run in the real app, on 2026-10-01** (round 3 group 5's second
session; the first ended while building, and the paragraph it had left here
describing an app run was replaced by this one, which was measured). Nothing in
the code needed changing: the tree built, `run-objectops-tests.sh` passed 91,
`run-objectops-blender-check.sh` 336 checks over 97 strings. Before the app
ran anything, the exact sequences below were rehearsed in desktop Blender 5.2.1
with the app's context — Blender's undo through `_blenderkit_undo`, and
`gpu.init()` — with no crash. Then the real iPad build (Designed for iPad,
real bpy), fixtures made by `-eval64`, rows pressed by `-object-ops`; **no
crash in any run**, and at each of 77 steps every object's type, parent,
vertex count and selection in the mirror matched what Blender held. Object
rows, 2–12 ms each: B then A, Parent → Outliner `A >B`; C then B, Parent →
`A >B >>C`; Keep Transform on from the panel (rewind and re-run, 11 ms) kept C
under B; Clear Parent on C → top level, the panel's Type at Clear Parent
Inverse → back under B; Undo, Redo; Duplicate Linked → A.001; C and A.001,
Join → 16 vertices in A.001 and in A (one mesh); Convert ▸ Curve on the
32-edge Circle → a CURVE drawn as 32 edges, on cube A refused in the banner's
words; Convert ▸ Mesh on Text → 177 vertices, Keep Original from the panel →
Text a FONT again beside Text.001, the mesh; Join with A alone refused.
Desktop Blender reading the autosave: B parented to A at x = 3 where it
started, A and A.001 one 16-vertex mesh with 2 users, Circle a CURVE of 32
points, Text a FONT, Text.001 177 vertices. Mesh rows, Edit Mode, a 7 × 7
grid: Limited Dissolve 49 → 4; Un-Subdivide 22, Iterations 1 from the panel
28; Edge Split by edges and by vertices 144; Delete Loose refused (nothing
loose); with nothing selected Split, Fill Holes, both Edge Splits, Beautify,
Extrude Individual, Bevel Vertices, Limited Dissolve, Un-Subdivide, Delete
Loose and Shear each refused in words, the mesh unchanged. A cube with a loose
edge and vertex: Delete Loose 11 → 8. A cube missing its top: Fill Holes 5 → 6
faces, Sides 3 from the panel 5, Sides 0 6. A cube: Bevel Vertices 56 vertices
/ 30 faces, Affect → Edges from the panel 56 / 54; Inset 8 (a closed region
has no border), Individual from the panel 32; Extrude Individual 32, Offset
0.5 from the panel; Shear, Angle 0.5 and Axes Along Y by Z from the panel —
the autosave's cube has y moved by −tan(0.5) × z (0.5463 per unit), x and z
untouched.

The Mac menu bar, pressed in the running app through macOS accessibility
(`app_menu`): Object lists Duplicate Linked, Join, Parent (Object, Object (Keep
Transform), Clear Parent, Clear and Keep Transformation, Clear Parent Inverse)
and Convert (Mesh, Curve). With B and A selected, Object ▸ Parent ▸ Object
opened the Make Parent panel (Keep Transform Off) and the Outliner showed A >
B with its guide line (screenshot); Convert ▸ Curve put the refusal in the
banner; Join merged B into A (Join panel, one undo step); Duplicate Linked
made A.001, and the autosave has A and A.001 sharing one 16-vertex mesh. The
Object menu is empty ("Open the 3D View") while a sheet is up — `keysLive` —
which is how it is meant to be. Not pressed on screen: the 3D View's own More
and Mesh pop-up menus and the redo panel's pickers, which accessibility
cannot open without bringing the app to the front; their rows call the same
functions the hook calls.

The 33 host suites and the Blender checks this touches (objectops, redo,
tools, objectmenu, modeguard, undo, context, 3dview) pass. Two timing checks
failed once while three suites compiled in parallel at a load average near 14
— mirror's 3,000 keyed objects at 5.32 ms against its 5 ms bound, snap's
search inside a 60 Hz frame — and both passed run again (4.07 ms).

**The review's fixes** (2026-10-01, round 3 group 5's repair). An adversarial
review of the rows above measured one high defect and several smaller ones;
each fix below was measured in desktop Blender 5.2.1 with the app's context
(an undo stack through `ed.undo_push` under the window, `gpu.init()`, the
borrowed 3D View where a row needs one) before it ran in the app.

- **The Transform fields showed a child's world transform and wrote its
  local channels.** Properties ▸ Object ▸ Transform and the N panel's Item tab
  read `BKObject.location`/`rotation`/`scale`, a decomposition of
  `matrix_world`, and wrote `location`, `rotation_euler` and `scale`. With B
  parented to A by Object ▸ Parent and A then moved 2 in X and turned 90°
  about Z, the field showed B at (-1, 0, 0) while Blender held (0, 3, 0), and
  a nudge of Z by 0.01 sent B 3.16 m away. Deltas, an Euler order other than
  XYZ and a quaternion parted them the same way without a parent, and a
  quaternion's rotation field wrote `rotation_euler`, which does nothing in
  that mode. Now `_blenderkit_sync.field_channels` sends the channels Blender's
  own fields show — `location`, the rotation mode and that mode's property,
  `scale`, no deltas — through a new entry point, `sync_channels`, onto
  `BKObject.channels`; both panels share `ObjectTransformFields`, which shows
  them (W X Y Z for a quaternion or an axis angle, the mode named), previews a
  drag where Blender will put the object and its children
  (`TransformFieldEdit`: matrix_world · basis⁻¹ · basis′, children carried by
  their parent's change), and on lift writes only the field changed, to its
  exact Float, as one undo step (`BpyBridge.commitTransformField`). The old
  three-component write at four places also rounded the fields not touched (a
  90° X became 90.0002° when Z was edited). An object that arrived without its
  channels shows a sentence instead of fields. The N panel used to write per
  drag sample with no undo step; it is the same view now.
  `run-transformfields-tests.sh` (50) and
  `run-transformfields-blender-check.sh` (406: the review's scene plus a
  quaternion under a turned, scaled holder parented with Keep Transform, deltas
  in ZXY Euler, an axis angle and a mirrored scale; every one of 74 field edits
  wrote that field alone, and the preview was within 5e-7 m of where Blender
  put every object). In the real app (`-object-ops … field:location:2=0.01`):
  the child's field showed (0, 3, 0), the edit sent
  `bpy.data.objects["Child"].location[2] = 0.01`, Blender then held location
  (0, 3, 0.01) and world (-1, 0, 0.01) — 0.01 m, not 3.16 — the preview
  matched Blender to 0.000000 m, Undo put the field back to 0, and a
  quaternion's Y field wrote `rotation_quaternion[2]`.
- **Properties ▸ Object ▸ Relations** said Parent "None" whatever Object ▸
  Parent had done. It shows the mirror's `parentName`, which is now observed.
- **Edge Split ▸ Faces & Edges by Vertices** refused a vertex selection, its
  main use. The check before each Mesh row now reads the panel's own values
  (`@arg:<key>@` in a lead, filled in by `LastOperator`): with Type at
  Vertices it wants a vertex — one inner vertex of a 7 × 7 grid split 49 → 52
  — and at Edges an edge.
- **Delete Loose's check ignored its switches**: a lone face passed with Faces
  off (the default), and Blender then removed nothing and cleared the
  selection. It now looks only for what its Vertices, Edges and Faces switches
  remove; a lone face with Faces off and a lone vertex with Vertices off are
  refused, the selection kept.
- **Several meshes in Edit Mode.** The new rows' checks read only the active
  mesh, while Blender acts on every mesh in Edit Mode: with the selection on
  the other of two grids, Limited Dissolve was refused where Blender takes it
  49 → 4 (also measured: Un-Subdivide 22, Edge Split 144, Extrude Individual
  193). They read `objects_in_mode_unique_data` now; Delete Loose found the
  other mesh's loose vertex (50 → 49).
- **Shear in Object Mode** was withheld on a check that could not fail: it
  sheared Along X by Y two cubes that both had y = 0. Cubes at y = −2 and +2
  move +0.728 and −0.728 in x at 20°, rotation and scale untouched, and
  nothing selected is CANCELLED, now said in words. Mesh ▸ Deform ▸ Shear
  runs `LastOperator.shearObjects` outside Edit Mode.
- **Join** takes hair curves and point clouds, which Blender joins (two point
  clouds of 8 points became one of 16, two hair-curve objects one of 6
  points).
- **The simulator.** Delete Loose's check says the simulator has no bmesh
  rather than "No module named bmesh", and the stand-in's `foreach_get` says it
  needs the real bpy, so Convert ▸ Curve ends in a sentence rather than an
  AttributeError (measured in the stand-in under the tools-shim model). Not
  changed: the stand-in's Join returns FINISHED where Blender cancels (nothing
  joined, or the active object not selected) — that is EmbeddedBpyRuntime's
  Swift, which only the simulator runs, and it was not run.

**Edit Mode on curves and lattices, and Add ▸ Lattice** (2026-10-01, round 3
group 7). Round 2's reviewer measured that Blender edits curves and lattices
headless and that the app built neither: Edit Mesh refused the Bézier and circle
Add ▸ Curve makes, and a lattice reached the viewport as its origin alone, so the
Lattice modifier's Object field had nothing to list.

- **Edit Mode is a mesh's, a curve's and a lattice's** (`Bpy.needsEditable`, for
  Edit Curve / Edit Lattice and Tab). Text, a surface or a light is refused in a
  sentence ("Edit Mode works on meshes, curves and lattices here, and Text is a
  text object."); Sculpt and the paint modes stay a mesh's.
- **The control points are Blender's** (`_blenderkit_points`,
  ControlPoints.swift). In Edit Mode the pass sends the cage through a new entry
  point, `sync_points`: three entries per Bézier point (left handle, knot, right
  handle), one per NURBS, poly or lattice point, a byte of flags each (selected,
  hidden, part, handle type), and the lines Blender draws. In Edit Mode the RNA
  reads the edit data — except a lattice point's `co`, which
  `rna_LatticePoint_co_get` indexes into the object-mode array (measured in
  5.2.1: (-0.5, -0.5, 0.5) for every point of a 3 × 2 × 2 edit lattice), so only
  `co_deform` is read. The 3D View draws the cage over everything in Blender's
  theme colours (`ControlCageOverlay`) and the mesh overlay stands down for it.
- **A tap, a box, Select All.** A tap picks the nearest visible point within 22
  points; a knot takes both its handles, as Blender's click does. Box, Circle and
  Lasso take every point inside, front or back, as Blender's curve and lattice
  box select do. Each goes to Blender at once and what lights up is what came
  back. With two curves in Edit Mode (Blender takes every selected one in), a tap
  deselects the other's points, which the viewport does not draw.
- **A drag previews by Blender's own operator.** A Swift preview could not match
  the commit: `transform.translate` changes handle types by the selection,
  carries an Auto or Aligned knot's handles, then recalculates every Auto handle
  — the neighbour's too (a circle's knot moved by (0, 0, 1) moved the next
  point's left handle from (-0.552, 1, 0) to (-0.614, 1.062, 0.276)) — and a
  lattice point moves the meshes it deforms. So Blender keeps the points at
  touch-down (`begin_drag`), each frame puts them back and runs the call the
  release will commit, mirroring the wire, the points and everything that
  depends on them (`anim_mesh`, no pass), and the release is the same restore and
  call through `bridge.run`: one undo step, the bare operator in the Info log.
  Measured in 5.2.1: frames push no undo step, the restore reads back equal in
  every field, the commit equals the last frame in every field, Undo and Redo
  work, and a turn about the gizmo's pivot (the selected points' median, sent as
  `center_override`) lands within 1e-4.
- **The Curve menu**: Extrude, Subdivide ▸ 1–4 cuts, Delete ▸ Vertices and
  Segments, Set Handle Type (Automatic, Vector, Aligned, Free, Toggle
  Free/Align), Toggle Cyclic, Switch Direction, Show/Hide. **The Lattice menu**:
  Make Regular, Flip U/V/W. Measured: with nothing selected `curve.subdivide`,
  `extrude_move`, `switch_direction` and `handle_type_set` return FINISHED and
  change nothing, `cyclic_toggle` CANCELLED, silently — and Subdivide with one
  point selected is FINISHED and nothing — so each row is held to a selection
  and, where it adds or removes points, to a change, and says why on the banner
  (`PointsBpy.Command.executed`). Delete on a lattice says its points are its
  resolution.
- **The Data tab** shows Blender's settings, read back each pass: a curve's
  Dimensions, Resolution Preview U, Offset, Extrude, Bevel Depth and Resolution,
  Fill Mode from the list Blender takes for its dimensions (3D: Full, Back,
  Front, Half; 2D: None, Back, Front, Both — `rna_Curve_fill_mode_itemf`); a
  lattice's Resolution U, V, W (1–64), Interpolation and Outside. Each field is
  one `bridge.run`. Measured: Fill Mode changes nothing on a 3D curve with no
  depth or extrusion (the panel says so), while a closed 2D circle fills with
  none (48 vertices, 46 faces with Both).
- **Add ▸ Lattice** is `object.add(radius=1, type='LATTICE', location=…)`,
  adjustable like the other adds (its re-run leaves one lattice and no orphan
  data-block). Its resolution is in the Data tab: `object.add` takes none. A
  lattice is drawn as its grid, sent as an edge mesh: `to_mesh()` refuses one
  ("Object does not have geometry data").
- **A mesh deformed by a lattice, end to end**, through the Lattice modifier's
  Object field (an earlier group's row), which now has lattices to list. In
  desktop 5.2.1, a 3 × 2 × 2 lattice scaled 2.5 around the 2 m cube, its top
  layer raised 0.2: the cube's top went from z 1.0000 to 1.1557, and Undo put
  both back.

Crashes: none, in desktop Blender or in the app (no BlenderLocal report in
~/Library/Logs/DiagnosticReports). Every entry point refuses outside a curve's
or a lattice's Edit Mode in a sentence; a stale index from the viewport is
ignored; a curve or lattice changed under a drag (an Undo mid-gesture) refuses
the restore and a cancel never raises. The Blender check's last section runs
every row on a curve with every point deleted, a drag with nothing to move,
lattices of 1 × 1 × 1 and 64 × 2 × 2, and Edit Mode on a curve with no splines.

Checks: `run-points-tests.sh` 70, `run-points-blender-check.sh` 213.
`run-modeguard-tests.sh` and `run-3dview-blender-check.sh` held the old rule and
its sentence and now hold the new one.

**Run in the real app on 2026-10-01** (Designed for iPad, real bpy — a 5.3
build; two runs of the new `-points-ops` hook on a scene `-eval64` made: a 0.8 m
cube, a Bézier circle, a NURBS path and a text object). Edit Mode on the text was
refused on the banner in the sentence above. On the circle: Edit Curve; a tap
beside the second knot picked it and its handles (3, 4, 5), and Blender held
exactly those; a 12-frame move along Z, an 8-frame 30° turn and a 6-frame scale
along X — each frame 0.3–3.3 ms across both runs (medians 0.4–1.1 ms) on this Mac, and each
commit equal to its last frame in every point and in the wire (gap 0.0);
Subdivide, Select All, Set Handle Type ▸ Vector, Switch Direction, Select None;
Extrude with nothing selected refused on the banner ("Extrude needs a selected
point"), then a tap and Extrude added a point on the end, which a drag moved and
Undo and Redo took back and forward; Delete removed it; in Object Mode the Data
tab's Bevel Depth 0.1, Fill Mode Half and Bevel Resolution 2 came back from
Blender. On the path: a tap, a drag, Toggle Cyclic. Then Add ▸ Lattice,
Resolution U 3, Add Modifier ▸ Lattice on the cube with its Object field set to
the lattice (the row read back "Lattice"), Edit Lattice, six taps over its top
layer and a 10-frame drag of 0.446 up: every frame mirrored the cube too, and
the cube's top went from z 0.4000 to 0.7473 in Blender and on screen alike;
Delete refused on the banner; Undo put it back to 0.4000 and Redo to 0.7473.
No crash in either run. Desktop 5.2.1 reading the autosave afterwards: the
circle with 6 points, bevel 0.1, resolution 2, Half; the cube's Lattice modifier
on the lattice and its evaluated top at 0.7473; the lattice 3 × 2 × 2 with its
top layer at 0.946; the path cyclic.

Not done: surfaces and text are refused Edit Mode. Every handle is shown, not
only the selected points' (Blender's default). No Tilt, Shrink/Fatten, NURBS
weight or order. A curve's own points are not snap targets while it is dragged.
A tap is not an undo step, as a mesh tap is not here. The overlay's pixels were
not looked at — this session cannot capture the app's window — so what it draws
is checked as data (`ControlCageOverlay`), not as an image.

**Curves and lattices, after review** (2026-10-01). An adversarial review of
the entry above found two high and several lesser defects, each of the kind
this app keeps shipping: a preview, a message or a history that disagreed with
what Blender held. Each is fixed and measured; none crashed anything.

- **A drag no longer runs on a curve that has left Edit Mode or changed under
  it.** The review measured it in desktop 5.2.1 with the app's own frame
  strings: Edit Curve, a knot tapped, one frame, then Undo, which put Blender in
  Object Mode; every later frame then ran `transform.translate` on the whole
  object (z 0.4, 0.9, 1.5) and the release left it at 2.1, where the gesture
  showed one knot moved 0.6 — `restore` had skipped the curve and the frame ran
  its call anyway. Two fixes. A drag now holds every other command, as a sculpt
  stroke does (`BpySession.pointDragOpen`, read through `gestureHold` by every
  guard the stroke had: commands, taps, Undo, Redo, the console, scripts, Open,
  autosave, the top bar's and the keyboard's Undo, the tool picker), from
  `beginPointDrag` until its commit or cancel; a drag begun over one whose end
  never came cancels it first, and a viewport torn down mid-drag cancels its
  own. And `_blenderkit_points.restore` now refuses — writing nothing, so the
  frame's or the commit's call never runs — when a dragged object is gone, out
  of Edit Mode, or holds points other than the last frame left (`settle`
  records them after each frame's call). Measured with the fix in desktop
  5.2.1, the app's context: the review's sequence leaves the object at z 0,
  every frame and the release refused in a sentence ("BézierCircle left Edit
  Mode during the drag, so the drag moved nothing"); an Undo inside Edit Mode
  between two frames is refused as "…points were changed during the drag", and
  Blender keeps what the Undo left; a Tab that got past the hold writes the
  frame's move into the curve (the knot's z 0.25 in the data) — which is why
  the hold is there; ten clean frames raise nothing and the commit equals the
  last frame. **In the real app** (two runs, below): Undo, Redo, Tab, Done and
  a tap sent after frame 2 or 3 of a drag each left the history revision where
  it was, Tab, Done and the tap with "Points are being moved. Lift the finger
  first." on the banner, Undo and Redo with it in the console, and each drag
  committed exactly its last frame (gap 0.0) with the object still at the
  origin; Undo, Undo, Redo afterwards stepped back through those drags one at
  a time (the knot at z 2.2029, 1.7411, 2.2029). A point moved and a mode
  changed straight into Blender past the hold were each caught by the next
  frame ("Circle's points were changed during the drag…", "Bez left Edit Mode
  during the drag…"), the drag cancelled, the object unmoved.
- **Delete ▸ Segments on a cyclic spline says it was done, and is an undo
  step.** It keeps every point and opens the spline, so the rows' "changed
  nothing" test, which counted points, put "Delete Segments needs two
  neighbouring points selected" over a curve Blender had opened, with no undo
  step. A row is now refused only when Blender holds exactly what it held
  before (`_blenderkit_points.fingerprint`: each spline's kind, length and
  Cyclic, each point's fields), and a CANCELLED likewise. Measured in 5.2.1 on
  the circle Add ▸ Curve ▸ Circle makes: knots 1 and 2, and the closing pair,
  are done and open it; knots 1 and 3 are refused and change nothing; Subdivide
  on one knot is still refused. In the app: Delete ▸ Segments on two
  neighbouring knots of a circle opened it (Cyclic False) with no banner, Undo
  closed it, Redo opened it again.
- **The pivot is Blender's.** Blender measures a handle whose knot is selected
  at its knot (`createTransCurveVerts`), so a tapped knot pivots on the knot
  however long its handles; the mean of the three entries was used, which
  moved a knot with Free handles (-1, 0, 0) and (3, 0, 0) to (1.333, 0, 0) on a
  half turn Blender leaves it still through. And for one point turned or
  scaled Blender turns about that point (`transform_around_single_fallback_ex`
  makes it Individual Origins, a handle's centre its knot), which a
  `center_override` skips, so the commit is given the knot
  (`ControlCage.transformCentres`, `singlePoint`; the gizmo, Bounding Box
  Center and Snap With's sources use them). The Blender check now holds the
  app's turn to Blender's own turn of the same selection, with no centre and a
  VIEW_3D override (a half turn: in the 3D View Blender turns the other way
  about Z, and half a turn either way lands every point alike), on eight
  selections of a two-point curve with unequal Free handles under Median Point
  and Bounding Box Center; with the old formula seven of the eight fail. In the
  app, a tapped knot of that curve turned 180°: `center_override` was the knot,
  the knot stayed at (0, 0, 0) and its handles went to (1, -0.5, 0) and
  (-3, 0, 0).
- **What rides a curve moves with the drag.** A frame now sends each
  follower's matrix (`anim_frame`), not only deformed geometry. Measured in
  5.2.1: an empty on the Bézier curve by Follow Path went from (-1, 3, 0) to
  (-1, 3, 0.5) on a frame and the frame showed it there; in the app the rider
  was drawn at (-1, 3, 0.8075) on the last frame, where Blender had it after
  the commit.
- **A curve emptied in Edit Mode stays a curve.** A tap on one has no points
  to pick and fell into the mesh branch, which marked a mesh selection for the
  next command — Done then failed with "expected 'Mesh' type found 'Curve'
  instead". Taps and boxes now go by the object's type, and the bridge never
  pushes a mesh selection onto a curve or a lattice. In the app: Select All,
  Delete, a pending mesh selection, Done — back in Object Mode, no banner.
- **Checks that could not fail now can**: the Swift's median was held to its
  own formula; "still running after the refusals" was `True`; the matrix check
  passed whenever the point was off screen; and a fixtures.py Traceback was
  piped through `grep … || true`, leaving the last run's cages for the dump.
  The script now deletes the old files first and fails on a fixtures error.
- **Smaller**: the cage is drawn in Wireframe and Material Preview too, which
  returned before it while a tap still picked those points (built; not run in
  those shadings, and no pixels looked at); a lattice with shape keys shows its resolution greyed
  out with a note, as Blender does, rather than the raw read-only error (its
  record carries `points_editable`, measured False with a Basis key); the
  keyboard menu's Tab row says Edit Curve / Edit Lattice. The status bar keeps
  "Points" for a curve: Blender's status bar prints "Verts" with its vertex
  counts, which a curve leaves at nought (measured "BézierCurve | Verts:0/0"),
  and its 3D View statistics call them Points.

Not done: with several curves in Edit Mode, Select All and Invert still select
the points of every one while only the active one's are drawn. In the
simulator a curve still enters an Edit Mode with no points (`_push_points`
sends none off device). Individual Origins with several points still turns
about their median, where Blender turns each about its own knot.

Checks: `run-points-tests.sh` 94 (70 before), `run-points-blender-check.sh` 260
(213 before). Every host suite and Blender check passes; the sculpt suite's
source checks now look for `gestureHold`, which its guards read.

**Mirror editing: X, Y, Z and Topology Mirror** (2026-10-01, round 3 group 6).
Round 2's reviewer measured that with `mesh.use_mirror_x` on, the gizmo's own
translate moved 1 vertex, and with `mirror=True` added moved it and its mirror
image, to (1, 1, 1.5) and (−1, 1, 1.5): the gizmo never sent `mirror`, nothing
on screen set the flags, and `BKObject.symmetry` was written only by
ToolHeader and read only by SidebarN, neither of which anything creates.

- **The flags are Blender's.** `_blenderkit_sync._kind` adds `|mirror=xyzt`
  (one letter per flag on: `use_mirror_x/y/z`, `use_mirror_topology`) to each
  mesh it pushes; `SceneMirror.symmetry` reads it and `merge` carries it onto
  the object on screen, so `BKObject.symmetry` is now the mirror's alone.
  ToolHeader's toggles, which set it locally and logged
  `use_mesh_mirror_x` — a property Blender does not have — are gone.
- **The mirror row** (LayoutWorkspace, after Proportional, in every mode but
  Object for a mesh): X, Y and Z, and Topology Mirror in its menu, each one
  `bridge.run` of `SymmetryBpy.set` (`bpy.data.objects[name].data.use_mirror_x
  = True`, naming the object the row shows), lit from `scene.active.symmetry`.
  No undo step: measured in 5.2.1, edit-mesh undo does not put these flags
  back (X on, Move, Undo: still on; a step pushed for the toggle and undone:
  still on), so a "Mirror X" step would undo nothing.
- **The drag previews what Blender commits** (`SymmetricEdit`, ported from
  `transform_convert_mesh_mirrordata_calc`, `EDBM_verts_mirror_cache_begin_ex`,
  `ED_mesh_mirrtopo_init` and `mesh_transdata_mirror_apply` in the 5.3
  source): the side the selection's coordinate sum is on drives; each of its
  vertices' images within 0.00002 *follows* — not transformed itself, set to
  its source's result negated (a selected vertex on the far side too); X+Y
  adds the diagonal; with proportional editing every visible vertex drives; a
  transformed vertex on a plane stays on it; hidden vertices take no part; the
  Mirror modifier's clipping comes first. The followers take no share of the
  move (`vertexFactors`), Auto Merge welds them as Blender does (it tags them),
  and snapping does not land on them. The commit says `mirror=True`. Measured:
  in desktop 5.2.1 a selected vertex at x = 0 moved by (0.1, 0.2, 0.3) ended at
  (0, 0.2, 0.3); the topology mirror paired Suzanne with one vertex pushed
  0.05 out of place (2 moved, 1 by position).
- **Topology Mirror counts with Blender's own sort.** `mirrtopo_hash_sort`
  compares the elements' *addresses* (`MirrTopoHash_t(intptr_t(l1))`), so the
  "unique values" that decide when the passes stop are counted in whatever
  order libc's `qsort` leaves the array. The port calls the same `qsort` with
  the same comparator; the comparisons depend only on the slots' relative
  addresses, so the permutation, the pass count and the pairs are Blender's
  on Apple's libc (both the Mac and the iPad).
- **X + Y with Topology Mirror cancels.** The table ignores the axis, so
  each pair is found twice and the second pass makes every selected vertex a
  follower of itself; Blender has nothing to transform and returns CANCELLED
  (measured on Suzanne: 0 moved). The preview shows nothing moving.
- **The Mesh menu's transforms send `mirror=True`** with an axis on
  (`LastOperator.Mesh.honoursMeshSymmetry`): measured on an 8 × 8 grid with 9
  vertices on +X, with and without it — Shrink/Fatten 18 and 9, Push/Pull 16
  and 8, To Sphere 16 and 8, Slide Vertices 18 and 9, Edge Slide 18 and 9.
  Not the extrude macros (Blender's own definitions pin their move's `mirror`
  to False), not Offset Edge Slide (its new loops have no image: 18 new
  vertices on +X either way). Smooth Vertices mirrors X by itself, and Shear,
  which runs in the borrowed 3D View, mirrors by itself (12 moved with the
  flag, 6 without).
- **Sculpt and paint.** Blender's sculpt brushes read the flags themselves.
  Before the row shipped, every brush was probed in desktop 5.2.1 through the
  app's own begin/chunk/end with X, Y and Z on: 62 stroked, the two Multires
  brushes refused in words, none crashed, Draw moved 168 vertices of which 84
  on −X; under Dynamic Topology 49 stroked and on a Multires level 51, with the
  same refusals as without symmetry and no crash. That is now a section of
  `run-sculpt-blender-check.sh`. Texture Paint's and Vertex Paint's Swift
  strokes, which already repeat across `BKObject.symmetry`, now repeat across
  the mesh's real flags, as Blender's do.
- The simulator's stand-in keeps no symmetry: its meshes read the four flags
  as False and say so when one is set.

Checks: `run-symmetry-tests.sh` 40, `run-symmetry-blender-check.sh` 95 (22
drags, each preview within 1e-6 of Blender's result and each shown to fail
with the symmetry ignored), and the sculpt check's new section. Unchanged and
passing: gizmo, tools, snap, mirror, redo, meshpick, regionselect, boxselect,
texpaint, the three shim suites, and the tools, mirror and redo Blender checks.
`run-editselection-tests.sh` expected the edit topology without Blender's
edges, which it now carries; that expectation was updated. What a drag pays
at touch-down for the pairs (swiftc -O on this Mac, 102,400 vertices): X 15
ms, X with Topology Mirror 28 ms, X, Y and Z with proportional editing 42 ms —
302 ms before the search was built once rather than per axis.

**Run in the real app on 2026-10-01** (Designed for iPad, real bpy; a grid
made by `-eval64`, rotated 0.2 about X and 0.6 about Z, scaled (1.5, 0.8, 1),
three vertices selected at (0.6, 0.4), (0.2, 0.8) and (0, 0.4); steps by the
new `-symmetry-ops` hook, which presses `toggleSymmetry` and runs a drag
through make, beginSession, resolve, snapping, apply, roll-back and
`bridge.run`, as `endGizmo` does). No crash in any of five runs (the fifth on
the final build, after the search above changed: every gap 7.0e-7 or less). After each
toggle the row showed what Blender held (`'x'`, `'xy'`, `'xyt'`, `'xz'`, `''`).
Drags, preview against Blender's own vertices: X, a Z move — 5 moved in both
(2 followers), largest gap 4.9e-7; X, a 40° turn — 5 and 5, 1.0e-6; X+Y and
X+Y+Topology moves — 5 and 5, 3 and 3; X with proportional size 0.7 — 76 and
76 (55 followers), 6.4e-7, then a 30° turn 52 and 52; X+Topology scale — 3 and
3; X and Z — 5 and 5. Shrink/Fatten with X: `mirror=True` sent, 5 moved, 2 on
−X. With every flag off the drag sent no `mirror` and moved 3. Desktop Blender
reading the autosave: SymGrid with X and Z on, its 5 moved vertices exact
reflections of each other (distance 0.0), the one on the plane at x = 0. The
autosave says it was written by Blender 503.4 — the app's bpy is a 5.3 build;
the in-app comparisons are against that Blender, the checks above against
desktop 5.2.1.

Not done: Mirror Vertex Groups (`use_mirror_vertex_groups`) has no control —
it changes weight painting, which the app's own weight brush does not model.
Two vertices at the same place tie for a mirror by position; the port takes
the lower index, Blender's KD-tree whichever its build reaches first.

**Mirror editing, repaired** (2026-10-01, after the adversarial review).

- **Pairs on Blender's coordinates, not the drawn ones.** The viewport draws
  the evaluated mesh, and a modifier shown in edit mode that keeps the vertex
  count — SimpleDeform and Shrinkwrap have `show_in_editmode` on by default —
  moves what is drawn without renumbering it, so the edit report still lined
  up while the pairs were found on the wrong positions. Measured in desktop
  5.2.1 on a 10 × 10 grid under SimpleDeform's default Twist (45° about X), X
  on, (0.6, 0.4) selected: paired on the drawn positions there was no image
  and the preview moved 1 vertex; `translate(mirror=True)` moved 2 (79 and
  85), the image appearing on release. Now `_blenderkit_sync._edit_coordinates`
  sends the edit mesh's own coordinates with the selection report whenever a
  modifier is on in edit mode (a sixth buffer through `sync_edit_selection`),
  `EditTopology.blenderPositions` keeps them when they differ from what is
  drawn, and `SymmetricEdit` pairs, finds the quadrant and the planes on them;
  `apply` works in Blender's coordinates through a per-vertex offset, so an
  image moves by its source's movement, mirrored. What the modifier then does
  to a moved vertex the preview still cannot know — the same approximation as
  any edit-mode drag over such a modifier. Checked: `run-symmetry-blender-check.sh`
  TWIST_X, TWIST_X_MOVE_Z, TWIST_XY and TWIST_X_ON_PLANE — Blender's moved
  set equals the preview's in each ({79, 85}; {15, 17, 79, 85}; {35, 41, 79,
  85}; {82, 91, 95}), and paired on the drawn positions, as before, each moved
  a different set ({85}; {17, 85}; {85}; {82, 95}). Drawn gap after the
  commit 0.144 on the dragged vertices and 0.172 on their images for
  TWIST_X: the modifier's, not the mirror's. In the app (its Blender is
  5.3.0 Alpha): X, a free move — preview {79, 85}, Blender {79, 85}; X+Y,
  a Z move — {35, 41, 79, 85} both; X+Y with Smooth proportional 0.7 —
  108 and 108, the same vertices.
- **The pair search fits a big mesh.** `MirrorGrid` was a Dictionary of one
  Swift array per cell, built over every vertex at touch-down. Now a hash of
  the cells into a table of one slot per vertex, filled by a counting sort:
  two Int32 arrays. Measured (swiftc -O, this Mac, a flat grid, one vertex
  selected): X alone at 1,000,000 vertices 218 → 14 ms and +214 → +24 MB
  over the positions; at 2,002,225, 510 → 41 ms and +427 → +47 MB. X, Y, Z
  and proportional at 1,000,000: 830 → 365 ms and +222 → +45 MB — every
  vertex is looked up on each axis, as Blender looks them up, and the lookups
  (about 300 ms per axis at 2M, cache misses) are what is left. The new grid
  gave the old one's answer for all of 710,288 lookups on random meshes with
  duplicates, mirror images, hidden, non-finite and huge vertices.
- **Topology Mirror's check can fail now.** On a symmetric mesh a −X vertex
  lands at its start plus the step whether or not it is paired, so the check
  passed whatever the table said. Each mesh's +X half is pushed out of place
  first (the table depends on the edges alone), and the check runs on eight
  meshes: Suzanne 204 pairs, pushed Suzanne 204, Suzanne subdivided twice
  3,381, and cube, grid, UV sphere, cylinder and torus, which are symmetric
  more than two ways and pair nothing on either side. Shown to fail: with one
  of Suzanne's pairs taken out of the table, and with a −X and a +X vertex of
  the cube paired that Blender does not pair.
- **The Mesh menu's transforms send `mirror=True` on any mesh being edited**,
  axis on or not, as Blender's 3D View stores it (`saveTransform`), so the
  redo panel reads the flags as they are when it re-runs. With every axis off
  it mirrors nothing (measured: 0 vertices on −X for each of the five). X
  turned on with the panel open, then adjusted: 9 on −X (was 0).
- **The redo panel keeps the flags as they are.** Adjusting puts the mesh back
  from the copy taken before the operator, flags included; now the current
  flags are carried over. Measured: X on, Shrink/Fatten, X off, adjust —
  `use_mirror_x` False and 0 on −X (was True and 9).
- **An undo step where Blender's undo restores the flag.** Texture, Vertex and
  Weight Paint keep Blender in object mode, where Blender's header pushes one
  for the property and its undo restores it. In the app: Vertex Paint, X — a
  step "X", Undo — the row and Blender both off; Weight Paint, Z, Undo — back
  to Y. In Edit Mode still none (measured: no step).
- **Nothing to transform, nothing sent.** With X, Y and Topology Mirror on
  Suzanne's ear the preview showed nothing moving and the release still sent
  the translate under "Move". Now the release sends nothing and the banner
  says why. In the app: no Move step, Blender moved 0, the sentence on the
  banner.
- **Topology Mirror only where Blender offers it**: Edit Mode and Weight
  Paint (space_view3d_toolbar.py). Sculpt, Vertex and Texture Paint ignore
  ME_EDIT_MIRROR_TOPO.
- **Y, the diagonal and Topology Mirror, in the app.** On Suzanne with her +X
  half pushed out of place (Blender undo, so the flags survive an Undo):
  X — 0 followers, 2 moved in both; X + Topology — 2 followers, {373, 374,
  497, 498} in both; X + Y + Topology — nothing sent, 0 moved.
- **Connected Only matches the app's Blender.** The reviewer's gaps (1.3e-2
  to 1.8e-2 on Suzanne's ear) were against desktop 5.2.1. In the app, whose
  Blender is 5.3.0 Alpha, the same drags — X, Connected, Sharp, size 0.6, a
  50° turn: 90 moved in both; a Z move: 94 and 94; Smooth: 96 and 96;
  symmetry off: 47 and 47 — every vertex within 8.8e-7, which is the
  six-decimal printing the hook reads Blender through. Against 5.2.1 the
  port's distances differ on 164 of Suzanne's 441 reached vertices, always
  shorter; neither Blender's edge, loop and radial orders nor the pre-5.3
  queueing rule changes that, and a Python port of the 5.3 source run on
  5.2.1's own BMesh differs from 5.2.1 the same way, so 5.2.1's code is not
  the 5.3 source the port follows.

Still not done: snapping skips the mirror images, where Blender's edit-mesh
snap skips only selected and hidden elements; whether Blender snaps to an
image that is moving with the drag was not measured. With the checkpoint
history (`_blenderkit_undo` before its probe settles — measured: a file left
in Edit Mode at launch keeps it pending), an Undo restores the whole file,
the mirror flags with it, where Blender's edit-mesh undo leaves them.

**Vertex groups and shape keys** (2026-10-01, round 3 group 8). Round 2's
reviewer found that no bridge or UI code referenced either. The Data tab of a
mesh now has Blender's Vertex Groups and Shape Keys panels, and the modifiers
that take a vertex group have the field.

- **Read back through the mirror.** `_blenderkit_groups.record` writes one
  `kind=head;…|kind=group;…|kind=key;…` record per mesh (names escaped as the
  modifier record escapes them), handed over by a new entry point,
  `_blenderkit.sync_groups` (PythonBootstrap.c → `bk_sync_groups` →
  `SceneMirror.carryGroups` → `BKObject.meshGroups`, carried by `merge`). It
  goes with every mesh in a pass, onto the object on screen after a tap that
  changes the active object (`sync_selection`), and after a frame change for
  a mesh with shape keys, so a keyed Value field follows the playhead.
  Members are counted for the active object only, up to 20,000 vertices:
  counting walks every vertex's groups in Python, 60 ms for 100,489 vertices
  in three groups and 0.74 ms for 2,025 (desktop 5.2.1, this Mac).
- **Vertex Groups:** the list (lock per row, member count), +, −, Delete All,
  rename, and in Edit Mode Assign, Remove, Select, Deselect and the Weight
  field (`tool_settings.vertex_group_weight`, clamped 0…1). Each button
  names its group and makes it active first, since Blender's operators act on
  the active group: a stale index can never act on another group than the one
  shown. Assign sends the weight the field shows.
- **Shape Keys:** the list (a Value field per key, none for the reference key
  of a relative set, as Blender draws none; Mute per row), + (the first is
  Basis), −, New Shape from Mix, Delete All, Apply All, Relative, Shape Key
  Lock, Shape Key Edit Mode, and the active key's Name, Value, Range Min and
  Max, Vertex Group, Relative To and Lock Shape. A Value is a draft while the
  finger is on it and is clamped to the key's range before it is sent, as
  Blender clamps it (measured: 1.5 under a maximum of 1 read back 1).
- **Editing a key's shape** is Edit Mode with that key active, as in Blender:
  measured, the edit mesh *is* the active key at full strength whatever its
  value, a move changes that key and leaves Basis, and changing the active key
  in Edit Mode reloads the edit mesh with it and keeps a tap's selection.
- **Modifiers:** Solidify, Smooth, Cast, Simple Deform, Displace, Wave,
  Shrinkwrap, Weighted Normal, Laplacian Smooth, Corrective Smooth, Lattice,
  Weld and Decimate (Collapse) get Vertex Group and Invert, through `update`
  like Boolean's object. Each was measured to change its result with a group
  and again inverted. Bevel is left out: its group is read only under a Vertex
  Group limit the row does not offer (measured, no change with the default
  Angle limit). The field's lines are `Bpy.modifierVertexGroup`, outside
  `modifierSettings`, because the simulator's stand-in has no groups; its rows
  do not offer the field. Blender clears a name that is not a group (measured,
  'Gone' read back ''), and the row shows that.
- **Refusals in words** (`_blenderkit_groups`): Assign or Remove with nothing
  selected (Blender returns FINISHED and CANCELLED, silently), on a locked
  group (Blender's own poll says "The active vertex group is locked"; the
  refusal names the group), Assign in Object Mode, shape keys added or removed
  in Edit Mode (both fail their poll; the buttons are off there, as Blender's
  are), a group or key that is not there, an empty name. Everything outside
  Object and Edit Mode is refused before Blender is asked and the panels say
  so: Blender allows some of it in Sculpt and the paint modes, and none of
  those paths has been run headless with the app's context.
- **Undo, measured.** In Object Mode one Undo takes back every control. In
  Edit Mode it takes back the group controls and the active key, and nothing
  else: the Weight field is a tool setting no step holds, and the edit-mesh
  step holds none of a key's settings or the object's switches (value, range,
  mute, lock, relative key, vertex group, name, Relative, Shape Key Lock,
  Edit Mode each stayed changed after Undo there). Those push no step, as the
  mirror row does for the symmetry flags.

Checks: `run-groups-tests.sh` 70 (the record, its escapes and
refusals, the clamp, counts kept across a frame change, `carryGroups` and the
merge, every command's call and undo name per mode, the modifiers' field read,
sent alone and kept by a saved file), and `run-groups-blender-check.sh`
320 in desktop 5.2.1 with an undo stack as the app has one: every
control into Blender and its effect on the evaluated mesh, the refusals,
Undo and Redo in both modes, editing Key 1 in Edit Mode, the app's own
`sync()`, `sync_selection()` and a frame change handing the record over, all
13 kinds' Vertex Group, Invert and a stale name, then the 46 records replayed
through the Swift against what Blender held. Unchanged and passing: the
modifier (264), modifier-shim (43), mirror (128), animation-shim (39) and
tools-shim (73) suites, and the modifier (215), mirror (142), animation (99),
sculpt (116) and points (213) Blender checks.

**Run in the real app on 2026-10-01** (Designed for iPad, real bpy; a 5 × 5
grid made by `-eval64`, the Properties editor open on the Data tab with
`-panel "Object Details" -properties-tab data`, steps by the new
`-groups-ops` hook, which sends exactly what each control sends). Three runs,
no crash, no traceback. After every step the panels showed what Blender held,
read back from Blender beside them: two groups added and renamed Left and
Right, Right locked; in Edit Mode the ten vertices at x < 0 assigned to Left
at the Weight field's 0.5 (count 10); Assign on Right refused ("Right is
locked: unlock it to change its weights."); Deselect and Select by Left
(selection 0, then 10); Remove from Left (0) and Undo (10 again); Add Shape
Key in Edit Mode refused; Basis, Key 1 and Key 2 added in Object Mode; Key 1
made active, Edit Mode, a gizmo Move along Z through the drag's own make,
preview and commit (preview against the mirror after: 0.0) — the evaluated
top at 1.577; back in Object Mode Value 0.5 → top 0.788, a drag to 1.5 sent
as 1.0, Range Max 2 then 1.5 → 2.365, Vertex Group Left → 1.182, Key 2 muted,
Shape Key Lock on and off, Key 2 relative to Key 1, New Shape from Mix,
Remove, Undo and Redo; Add Modifier ▸ Displace, its Vertex Group Left (top
1.682 → 1.432), Invert, and a name that is no group, which came back as none.
The second run: a group named `a;b|c=d%e` round-tripped, a Move on Key 2 in
Edit Mode, Key 1 made active there, Shape Key Edit Mode on, a Value in Edit
Mode (no step: Undo went back to the active key, the value stayed, as
measured), Apply All, Delete All, Remove, Delete All Groups, a Weight of 2
sent as 1, and Undo of the group removal. The third, on the final build:
Assign at 0.75, Remove from the locked Right refused in words, Key 1 and then
Key 2 made active in Edit Mode with the ten selected vertices staying
selected (10 and 10), a Move on Key 1 (top 0.943, and 0 with Key 2 active),
Key 2 weighted by Left, a Smooth with Vertex Group Left and Invert, Undo and
Redo of the Invert. Desktop Blender reading the first run's autosave: groups Left (10 vertices at 0.5) and Right (locked, empty);
Basis flat, Key 1 at 1.5 with range 0–2, vertex group Left and its lifted
half at z 1.5766, Key 2 muted and relative to Key 1; the Displace with no
group and Invert on; evaluated top 1.6824, the app's last reading 1.682.

Found on the way, in the hook rather than the app: a selection made with
bmesh that deselects vertices but leaves their faces selected is undone by a
key switch in Edit Mode — the edit mesh is rebuilt and each selected face
selects its corners again (measured: 10 selected, 25 after the switch). The
app's tap (`Bpy.pushEditSelection`) deselects faces and edges first and kept
all ten; the hook's `pick` and the check's `select_where` now do the same.

Not done: weight painting. Read in the source, not changed here: a Weight
Paint dab (`MetalViewportView.vertexPaintDab` → `BKObject.paintVertices`)
writes the app's own `vertexWeights` and sends Blender nothing, so it paints
no vertex group — the same defect this file keeps recording, in a mode these
panels do not reach. Groups and keys cannot be reordered (Blender's
`vertex_group_move` and `shape_key_move`), and the Lock All / Unlock All,
Mirror, Sort and Copy rows of the specials menus are not offered. Absolute
shape keys' Evaluation Time has no field.

**The UV Editor shows Blender's UVs; real unwraps, packing and seams**
(2026-09-21). Found by the round-1 critic. Everything below was measured in
desktop Blender 5.2.1 under `-b --factory-startup`, and
`scripts/run-uv-blender-check.sh` runs every row of the UV menu exactly as the
Swift sends it, then replays Blender's own mirror of the result through the
Swift the device runs.

- **The UV Editor could not show a UV on the real backend.** The mirror sent
  positions, normals and triangles (`bk_sync_push` built
  `MeshData(vertices:indices:)`), so it read "No UVs on this mesh" straight
  after an unwrap, and the Outliner's UVMap row never appeared. A new
  `sync_uvs` follows each mesh: the loop behind every triangle corner and a UV
  per loop — two `foreach_get` reads, no loop in Python — plus the seam edges
  as vertex pairs. `SceneMirror.installUVs` picks out each corner's UV into
  `MeshData.cornerUVs`, one per entry of `indices`, as Blender stores them, so
  a seam gives a vertex two UVs without splitting it. The Outliner and the
  Spreadsheet show the map's real name.
  - **What it costs**, on the app's own `Scene.blend` (car, bike and dinosaur,
    as saved; its dinosaur now evaluates to 23 meshes and 15,860 triangles,
    not the 5,876 of the entry below, since its Subdivision levels went up).
    The dinosaur pushes 385,392 bytes of geometry per pass and 444,400 more of
    UV map, **+115%**; the whole scene 840,336 and 918,176, **+109%**. In
    Python the extra work is about 1 ms a pass for the dinosaur and 2.2 ms for
    the scene on this Mac; gathering the corners in Python instead took 6.6
    and 13.5 ms, which is why the Swift gathers. Installing the maps the first
    time took 1.57 and 3.54 ms (Swift `-O`).
  - **The unchanged-mesh fast path still holds.** An unchanged map is
    compared straight from the buffers — 0.10 ms for the dinosaur, 0.22 ms for
    the scene — and nothing is reinstalled or re-uploaded: the check's
    "nothing changed" pass, and the same replay over `Scene.blend`, found every
    object's mesh version untouched. A map that changed without the geometry
    (an unwrap moves no vertex) reinstalls that one object.
  - Every drawn corner matched Blender's own UV, on the check's scene and on
    all 80 meshes of `Scene.blend`, including a grid with faces hidden in Edit
    Mode (the same triangles the mirror leaves out) and a cube under a
    Subdivision.
- **The editor draws polygons, as Blender's does, not triangles.** A loop
  belongs to one polygon, so two triangles naming the same *pair of loops* are
  halves of one polygon and the edge between them is triangulation's diagonal
  (`UVUnwrap.diagonals`). That is exact for any n-gon, where vertex pairs
  cannot tell a quad's diagonal from a real edge; the check counts one drawn
  side per loop of every drawn polygon (1,984 on a UV sphere).
- **Unwrap is `uv.unwrap`, with its three methods**, under Blender's own menu
  text: Unwrap Angle Based, Conformal, Minimum Stretch — the 5.2.1 identifiers
  `ANGLE_BASED`, `CONFORMAL`, `MINIMUM_STRETCH`, read from the operator's RNA.
  Its default is `CONFORMAL` in 5.2.1, so the method is always spelled out.
  It used to run `smart_project`; Smart UV Project is its own row now.
- **Follow Active Quads, Lightmap Pack and Pack Islands run**, as do Average
  Islands Scale, Seams from Islands and Reset, all now on the menu. Each
  returned FINISHED headless and moved UVs (Seams from Islands marked 110
  seams on a smart-projected sphere).
  - Blender's UV operators work on the selected faces in Edit Mode and fail
    their poll anywhere else ("context is incorrect"; all but Lightmap Pack).
    `_blenderkit_uv.run` runs them in Edit Mode on the selection, as Blender
    does, and from object mode on the whole mesh of every mesh Edit Mode opens,
    putting each one's stored selection back after — checked flag for flag.
    The header says which: "selected faces", "whole mesh", or how many meshes.
  - With no face selected Blender does nothing and says nothing: every unwrap
    FINISHED having moved no UV, Pack Islands CANCELLED. The row now says "no
    faces are selected".
  - Follow Active Quads follows the active face, which a click sets, and the
    app's taps hand Blender a selection with no active element — the bare
    operator answered "No active face" every time. With none, the
    lowest-numbered selected quad is made active. From Edit Mode it moves only
    quads joined to that one through the selection, as in Blender.
- **Seams are shown.** The mirror can carry edge flags, and does: Blender's
  seams arrive with the UV map, drawn in Blender's Edge Seam red in the UV
  Editor (both sides of a seam, since in UV space they are two lines) and over
  the mesh in the 3D View's Edit Mode, under the selection. They survive the
  evaluated mesh: a cube's 4 marked edges came out as 8 through a level-1
  Subdivision, 8 through a Bevel and 8 through a Mirror. Mark Seam (Mesh ▸
  Edge) used to change nothing on screen.
- **A script landmine, measured:** `mesh.uv_layers.remove()` does not tag the
  depsgraph. An already-evaluated depsgraph kept the removed UVMap on the
  evaluated mesh until `mesh.update()`; the UV Maps panel's own
  `mesh.uv_texture_remove` tags it. The mirror shows the evaluated mesh, as
  Blender's renderers use it, so a script that removes a map should call
  `update()`.
- **In the simulator** the stand-in unwraps with its projections as before;
  Follow Active Quads, Lightmap Pack, Pack Islands, Average Islands Scale,
  Seams from Islands and Reset raise `NotImplementedError` naming the real
  backend rather than passing a projection off as them.
- **Checks:** `run-uv-blender-check.sh` (59 in Blender, 45 replayed),
  `run-mirror-tests.sh` (the transport, the fast path, diagonals, seams and
  what is refused), `run-modeguard-blender-check.sh` (every UV row from object,
  Edit and Sculpt mode), `run-mesh-tests.sh`, and `run-mirror-blender-check.sh`,
  `run-texpaint-blender-check.sh` and `run-3dview-blender-check.sh` over the
  changed sync. The app was built. **None of it was seen on screen:** the UV
  Editor's drawing and the viewport's seam overlay were not run in the app,
  in the simulator or on a device.

**Show/Hide, Separate, Auto Smooth, QuadriFlow, and curves and text**
(2026-09-21). Blender's Object menu rows that were missing, and the Add menu's
Curve and Text. Everything below was measured in desktop Blender 5.2.1 under
`-b --factory-startup`, and `scripts/run-objectmenu-blender-check.sh` runs what
the app sends there and replays Blender's own mirror through the Swift.

- **Hide and Show Hidden** (H, Shift+H, Alt+H; Object ▸ Show/Hide on the Mac
  menu bar, More ▸ Show/Hide, and the Mesh menu while editing).
  - `object.hide_view_set` and `hide_view_clear` fail their poll headless:
    both want a 3D View. The startup screen still has one, and under
    `temp_override(window, area, region)` with it both act as on a desktop:
    Hide deselects what it hides and keeps the active object active, Show
    Hidden selects what it brings back, and each returns CANCELLED — raising
    nothing — when there is nothing to do, so those say why.
    `_blenderkit_context.temp_override_view3d` borrows the view; its name has
    `temp_override` in it so a script that uses it runs on the main thread,
    the only one Blender gives an area out on.
  - **The Outliner's eye could not show an object H had hidden.** It showed
    whether the object was drawn and wrote `hide_viewport`. H sets the view
    layer's flag (`hide_get()`), not that, and Show Hidden Objects does not
    clear `hide_viewport` (CANCELLED with only a disabled object in the scene).
    So the eye stayed closed and its tap set a flag that was already off.
    Properties ▸ Relations had the same toggle. The mirror now sends both flags
    (`|layerhidden`, `|disabled`, beside `|hidden` for "not drawn"); the eye
    reads and writes `hide_get()` / `hide_set()` (`hide_set(True)` deselects,
    and a hidden object refuses `select_set`), a monitor appears on a row
    whose object is disabled in viewports and turns it back on, and the
    Properties toggle is Blender's Show In Viewports, `hide_viewport` alone.
    Rows of objects not drawn are dimmed. A hidden object reaches the mirror
    as its origin alone, so the Mesh panel, the Outliner's counts and the N
    panel's vertex and triangle rows say "hidden", and the status bar's and
    the Scene tab's totals count what is drawn, as Blender's statistics do.
  - **H then Alt+H erased the app's own vertex paint and weights.** The merge
    installed that one-vertex placeholder over the mesh on screen, and the
    per-vertex layers, which bpy has no copy of, go whenever the vertex count
    changes. An object that is not drawn now keeps the mesh it was last drawn
    with — what Blender still holds: a cube under a level-1 Subdivision
    evaluated to 26 vertices before H, while hidden and after Alt+H — until a
    pass draws it again. The check replays H, Shift+H and Show in Viewports
    pass after pass onto one screen, as the device mirrors them, and the
    painted counts (26 and 8) survive each; with the old merge they went to 0.
    The N panel's Dimensions are measured from that mesh, so a hidden cube no
    longer reads 0.000 m; one hidden since it arrived reads "hidden". Found on
    the way, not fixed: under a Subdivision Blender's `dimensions` read 2 m
    where its evaluated mesh spans 1.679 m, drawn or not, and the N panel
    shows the second.
  - **Edit mode drew what `mesh.hide` hid.** The evaluated mesh keeps every
    face and marks the hidden ones: 16 of a 4 × 4 grid with 9 hidden, and 64
    of 64 through a Subdivision with 16 of them hidden. While editing, the
    mirror now leaves hidden faces out (`_unhidden_triangles`; a wire's hidden
    edges too), the edit report leaves out their triangles to match, and it
    sends which vertices are hidden. Those get no dot, no tap and no place in
    a box select — with every face hidden the picker's own visibility test let
    every vertex through. Proportional editing leaves them alone, as Blender
    does: one hidden beside the selected corner of a 5 × 5 grid stayed put
    under a LINEAR move of size 3 that lifted all 23 others, Connected Only or
    not; nor are they clipped by a Mirror. `mesh.hide` with nothing selected,
    and Hide Unselected with everything selected, return CANCELLED.
- **Separate** (Mesh ▸ Separate while editing: Selection, By Material, By
  Loose Parts). The new objects arrive in object mode and selected, the edited
  one stays active in edit mode, and the next mirroring pass lists and draws
  them like any other. Selection with nothing selected raises Blender's own
  "Nothing selected"; By Loose Parts on a mesh in one piece and By Material
  with fewer than two materials in use return CANCELLED and now say why.
- **Shade Auto Smooth** adds a Geometry Nodes modifier, "Smooth by Angle",
  in under 0.04 s; run again it sets that modifier's angle rather than adding a
  second. **The bpy staged into the app has no `datafiles/assets`**, where the
  node group comes from, and a desktop Blender with that folder removed (an
  APFS clone of the app) fails with `No asset found at path ""` and adds
  nothing. **So the row is greyed out wherever the library is missing**,
  which is the device: the 3D View asks Blender once
  (`_blenderkit_context.essentials_available`, which reads
  `bpy.utils.system_resource('DATAFILES', path='assets')` — '' in the clone)
  and the row's subtitle says what it needs. Run anyway, from a script, the
  failure says so and names **Shade Smooth by Angle**, Blender's operator (in
  its F3 search, not its menus) that marks sharp edges past the angle and
  smooths every face without a modifier or an asset — a cube's 12 edges, at
  90°, come out sharp. Both are adjustable (Angle in degrees; Keep Sharp
  Edges). The check now runs Auto Smooth a second time in that clone, so what
  it holds is what the device does, not only what the desktop can. Shipping
  the library would take the 697 KB `nodes/geometry_nodes_essentials.blend`;
  the only copy here is desktop 5.2.1's, the device's bpy is 5.3, and nothing
  here can run the device's bpy to see it load, so it is not staged.
  - **Both did nothing, silently, with no mesh selected.** They act on the
    selection, and H leaves the active mesh deselected: Smooth by Angle
    returned CANCELLED, and Auto Smooth FINISHED having added no modifier and
    smoothed no face (also with only a camera selected). Each recorded an
    undo step and opened a redo panel for nothing; each now says no mesh is
    selected.
  - **Smooth by Angle's panel could read a value some objects did not
    hold.** Where a mesh backup keeps the history rather than Blender's undo,
    only the active object's mesh is put back before a re-run, and Keep Sharp
    Edges keeps what the first run marked: two spheres at 5°, then 60° from
    the panel, left the second with 864 sharp edges where a fresh 60° run
    leaves 0. On that path, with another mesh selected, it no longer becomes
    adjustable; with Blender's undo it still does.
  - **The Modifiers panel dropped every Geometry Nodes modifier**, since the
    record carried only the kinds it modelled, and would have shown "No
    modifiers" over a mesh one was changing. It now has a row for any: the
    group's name, "no node group — does nothing" for an empty one, and for
    Smooth by Angle its Angle and Ignore Sharpness, read and written by input
    name. 5.2.1 keeps those at `modifier.properties.inputs.Input_1.value` and
    refuses `modifier["Input_1"]` ("this type doesn't support IDProperties");
    the helper tries both. Setting one re-evaluates nothing until
    `update_tag()`: set from 30° to 100°, a cube kept all 12 sharp edges until
    it was called, then had none. Add Modifier does not offer Geometry Nodes.
  - Found on the way, not fixed: the viewport shades with Blender's vertex
    normals, so Shade Smooth, Flat, Auto Smooth and Smooth by Angle change a
    render and not the Solid view.
- **QuadriFlow Remesh** (More and the Object menu; Blender keeps it under
  Object Data ▸ Remesh), with Number of Faces, the symmetry and preserve
  toggles and Seed in the redo panel. Every face a quad: a UV sphere at the
  default 4000 came out 4091 in 0.97 s, at 1000 1064 in 0.18 s; a cube at 1000
  1014, Suzanne 999, a torus at 2000 1719. Object mode, meshes, the active
  object only. Mode is pinned to FACES: RATIO at 0.5 of a 512-face sphere gave
  the default's 4091. A re-run from the panel remeshes the original mesh, not
  the last result, and costs a whole remesh each time — the panel re-runs a
  drag up to six times a second, so typing the number is the faster way
  to change it.
  - **It could fail and read as done.** On a mesh that is not manifold —
    the app's own Add ▸ Circle, a wire of 32 vertices, or a cube with one face
    flipped — Blender prints a warning and returns CANCELLED, raising
    nothing; the app recorded an undo step and opened a panel whose Number of
    Faces moved nothing. It now says what Blender needs: every edge in one or
    two faces pointing the same way and none of zero length
    (`mesh_is_manifold_consistent`, object_remesh.cc). An open grid is
    accepted and remeshed.
- **Add ▸ Curve (Bézier, Circle) and Add ▸ Text**, at the 3D cursor and
  adjustable by Radius. Blender names them BézierCurve, BézierCircle and Text;
  a re-run clears the old data from `bpy.data.curves`, where a TextCurve lives
  too. Neither curve is filled, so each is a wire — 13 vertices and 12 edges,
  48 and 48 — and **does reach the app** since the wire objects fix: the
  check replays both as wires with Blender's edge counts, and the text by its
  faces (177 vertices, 171 faces). All three can cut with Knife Project. None
  offers Edit Mesh, and Tab on one refuses in words that name it a curve or
  text.
- **The simulator** answers to all of these: Hide and Show Hidden keep the
  two flags, deselect and select as Blender does and answer CANCELLED when
  nothing changed; the rest raise NotImplementedError naming what they need.
  Two places it did not do as Blender does, now measured and fixed
  (`SceneVisibility.swift`, run by `run-mirror-tests.sh`): Show Hidden
  skipped an object both hidden and disabled and answered CANCELLED, where
  Blender clears its hide, leaves it disabled and unselected, and answers
  FINISHED; and the Outliner's eye left what it hid selected, where
  `hide_set(True)` deselects (so does `hide_viewport = True`). Its undo
  restored "not drawn" as hidden, so a disabled object came back with its
  monitor gone and its eye closed; a step now keeps both flags.
  The shim's Python is host-checked (`run-tools-shim-tests.sh`); of its
  Swift half, Hide, Show Hidden and the eye run on the host through
  `SceneVisibility.swift`, and the rest is built into the app and was not run.

Checks: `run-objectmenu-blender-check.sh` (new: 108 in Blender, 199 replayed,
6 in a Blender without the Essentials library). The Bézier curve and circle
Blender's sync pushes are each taken by a tap on their line
(`ObjectOverlayPicking`, which the viewport's hitTest asks before its
triangle ray), and the circle not by one in its empty middle. The replay used to build every
pass onto an empty scene, so the path the device takes on every later pass —
each push meeting the object already on screen, whose unchanged geometry is
reused — never ran, and neither defect it hides could fail a check. The H,
Shift+H and Show in Viewports passes, and a wire circle in edit mode with every
vertex hidden (nothing of it drawn; before the empty edge list was sent, all
32 edges stayed), are now also replayed pass after pass onto one screen; with
the old merge, or with the edge list skipped when empty, 11 of those checks
fail. Also: `run-modifier-blender-check.sh` (the Smooth by Angle row's edits, made from
Blender's own record and run back, evaluated), `run-mirror-tests.sh`,
`run-editselection-tests.sh`, `run-modifier-tests.sh`, `run-redo-tests.sh`,
`run-tools-tests.sh`, `run-tools-shim-tests.sh`; `run-camlight-blender-check.sh`
and `run-3dview-blender-check.sh` expected the old `|hidden` alone for an
object with `hide_viewport` set and now read `|hidden|disabled`, and the
mirror, tools, viewport and texpaint checks were run again over the changed
sync. The app was built; none of this was run on a device, in the running app
or in the simulator.

**Round 3's last review: the open highs** (2026-10-02). The final review left
one new crash path and six highs open after the repairs. Each was measured in
desktop Blender 5.2.1 with the app's context first, then run in the real app on
this Mac (Designed for iPad, the real bpy). `scripts/run-guards-blender-check.sh`
(new) and the sculpt check hold them.

- **Loop cut with no 3D View crashed Blender.** `mesh.loopcut(edge_index=…)`, and
  the `loopcut_slide` line Blender's Info editor logs for every loop cut,
  segfault in `loopcut_init` when the context has a window but no area. That is
  what a script, the console and the operator search have. `_blenderkit_context`
  now refuses both (`NEEDS_VIEW`) outside a 3D View region, in words, through the
  same `_op_create_function` wrapper as the file reads. Inside
  `temp_override_view3d` they cut as before: 8/12/6 became 12/20/10. The check's
  negative control, a second Blender without the guard, exits -11. In the app,
  the script call, the Info line and the search were all refused, with the mesh
  unchanged and no crash report.
- **The vertex budget counts the whole stack.** `_blenderkit_multires.stack_vertices`
  applies each viewport modifier in order: Catmull-Clark levels for Multires and
  Subdivision, and copies for Mirror, a fixed-count Array and Solidify. It matched
  Blender's evaluated count exactly on seven stacks. Before, a Subdivision below a
  Multires was not counted, a 4 to 16 times undercount.
- **Every way to reach the budget now checks it:**
  - Properties' and the Sculpt header's Subdivide;
  - the operator search's `object.subdivision_set`, priced the way Blender's
    operator decides (it had gone 196 times past the budget);
  - the Subdivision row's Levels stepper and an Array's Count, through a check
    line `modifierSettings` sends first (`checkModifierSetting`);
  - Every Property;
  - the search's `object.voxel_remesh` (`refuse_voxel_remesh`, shared with the
    header).

  In the app: Subdivision Set 11, the stepper's level 11 and Every Property's
  level 11 were all refused (25,165,826 vertices), with the level left at 1. A
  Multires over a level-1 Subdivision stopped at level 8 (1,572,866), where the
  9th press would have made Blender evaluate 6.3 million. A 0.0048 voxel was
  refused.
- **Dynamic Topology went off in the middle of a stroke** when the step under
  the stroke was a Global Undo step: the first stroke after a relaunch, or one
  after a labelled change in Sculpt Mode.
  - The stroke's anchor dab now runs under Dynamic Topology too, with the detail
    method at Manual so it remeshes nothing. Measured: 0 of 595 vertices moved
    and the topology unchanged, and the detail method was put back after.
  - Its rewinds now land on a Sculpt step, 0.4 ms instead of 2.8.
  - After a relaunch, the anchor joins the base of the stack the stroke started,
    so Undo and Redo keep Dynamic Topology too. In the app the stroke went from
    1106 to 1171 vertices; Undo moved 0 of 1106 back to the start, and Redo gave
    1171 again.
- **Taps in Edit Mode wiped Blender's selection** on a mesh whose modifier
  rebuilds it: 0 of 8 vertices kept under a Subdivision, 1 under a Mirror. A tap
  now refuses in the same words Box, Circle and Lasso use
  (`editRegionRefusal`, whose last words are now "to select here"). Built, but
  not tapped in the app, because the Mac's screen was locked for this pass.
- **Mirror editing read the Basis with another shape key active.**
  `update_from_editmode` fills the mesh's vertices from the Basis, while the edit
  mesh holds the active key. `_edit_coordinates` now reads the active key's
  block. It matched the edit mesh to 0 on all 121 grid vertices, after an
  Edit-Mode move too.
- **Duplicate in Edit Mode copied the whole object.** More ▸ Duplicate, the
  Object menu's Duplicate and Shift+D now run `mesh.duplicate_move()` while
  editing a mesh, as Blender's Edit Mode Shift+D does. They refuse in words on a
  curve's or a lattice's points. In the app: one face selected went from 8/12/6
  to 12/16/7 vertices, edges and faces, still one object, and Undo gave 8/6
  back. The Object menu's item is enabled in Edit Mode now. DEBUG `-object-ops`
  gained `dup`.

Still open:

- **Undo and Redo over a labelled change in Sculpt Mode lose Dynamic
  Topology.** The Undo goes down onto that change's memfile step, which comes
  back without the dynamic topology mesh, and the Redo then has nothing to replay
  the stroke onto. It was the same before this pass (measured), and the check
  prints it as a NOTE. The anchor cannot be left out of the stroke there as it is
  after a relaunch: the labelled change's own Undo would stop a step short.
- **Voxel Remesh's 2.5 vertices-per-area factor is not an upper bound.** Thin
  shapes measured up to 7 times the estimate.
- **The final review's list of what the toolkit still lacks:**
  - Interactive Knife and Loop Cut.
  - Typed values in Edit Mode.
  - Pick-to-select loops, rings and paths.
  - Transform orientations.
  - Reference images.
  - Poly Build, Rip, the Cursor tool, Collections and constraints.

  These are round 4's.

**The edge tools, and Mirror's other rows** (2026-09-21). Operators the
round-1 critic measured working headless and no menu offered, and the Mirror
settings a symmetric model is built with. Everything below was measured
in desktop Blender 5.2.1 under `-b --factory-startup`, and every call the app
now sends is run there by the checks named at the end.

- **Mesh menu, three new groups in Blender's header order.** *Select Loops*:
  Select Edge Loops / Rings (`mesh.select_edge_loop_multi` /
  `select_edge_ring_multi`; `mesh.loop_multi_select` does not exist in 5.2.1).
  From one edge of a 10 × 10 grid they select its 10-edge loop and the 11 edges
  across from it — in edge select mode; in vertex select mode Blender flushes
  the ring's 22 vertices into a strip, as on a desktop. *Vertex*: Connect
  Vertex Path, Slide Vertices. *Edge*: Edge Slide, Offset Edge Slide, Edge
  Bevel Weight, Edge Crease, Mark / Clear Seam, Mark / Clear Sharp.
- **Edge Slide runs without a window.** `ActiveTool` and this document said it
  returns CANCELLED. Measured: `edge_slide(value=0.5)` moved an 11-vertex loop
  0.1 of its 0.2 spacing, -0.25 moved it 0.05 the other way; with no value it
  returns FINISHED and moves nothing; on a whole cube, which is no loop, it
  returns CANCELLED. The panel has Factor (-1…1, from 0.5), Even and Flipped.
  Even changes the result on a grid whose next row was tilted; Flipped only
  picks which neighbour Even follows, and alone gave exactly the default result
  at +0.5 and -0.5 (re-measured in the review below), so its row is greyed until
  Even is on. The toolbar's Edge Slide *drag tool* stays greyed, and now says where the
  operator is. `loopcut_slide` does return CANCELLED, with or without an edge
  index; that part of the old claim stands.
- **Slide Vertices** has Factor 0…1 (with Blender's default Clamp a negative
  value moved nothing) and a Direction. Without a pointer Blender slides along
  the edge that points most nearly along the hidden world-space `direction`:
  (0, 1, 0) slid +Y, (-1, 0, 0) slid -X, and on a grid turned 90° about Z,
  (0, 1, 0) slid along its local X. Offered as ±X / ±Y / ±Z.
- **Offset Edge Slide** is a macro like Extrude; its factor is
  `TRANSFORM_OT_edge_slide={"value": …}`. 0.5 adds loops at ±0.1 of a 0.2
  spacing (121 → 143 vertices), 1 on the neighbours, and 0 or anything negative
  on the selected loop itself, so it starts at 0.5. Cap Endpoint is not offered.
- **Crease and Bevel Weight add to what the edge had**, held to 0…1: 0.5 then
  0.3 read 0.8, another 0.5 read 1, -0.25 then 0.75. Factor -1…1, from 1. They
  write `crease_edge` / `bevel_weight_edge`, whose data reads as empty while the
  object is in edit mode — read them in object mode.
- **Refusals in words.** Blender says why on a status bar a bpy module has none
  of. With nothing selected, the loop selections, Mark/Clear and Connect Vertex
  Path return FINISHED having done nothing, so a lead refuses first (as Loop
  Cut's does); the slides, Crease and Bevel Weight return CANCELLED, so the call
  runs as `if 'CANCELLED' in bpy.ops…(…): raise RuntimeError(…)`
  (`LastOperator.refusal`, `executedPython`; the Info log keeps the bare call,
  as Blender's does) — without it the app reported success, pushed an
  undo step and opened a panel whose slider moved nothing. Connect Vertex Path
  joins any two vertices whatever their order; any other number needs Blender's
  selection history, which the viewport's selection does not carry, so one
  vertex is refused in the app's words and three or more get Blender's
  "Invalid selection order".
- **Factors read as factors.** A redo field had to be a length ("0.500 m") or a
  count; parameters now carry a `NumberFieldUnit`. (A `unit: .none` argument on
  an optional parameter was Optional's `.none`, and the first test caught the
  field still reading metres.)
- **Mirror: Bisect, Flip, Clipping, Merge and Merge Distance**, each from the
  row through `Bpy.modifierSettings` (the triples as one assignment each,
  `merge_threshold` at six places), back through `_MODIFIER_FIELDS` and
  `Modifier.stack(from:)`, and old saved files open with Blender's defaults (no
  bisect, no clipping, Merge on at 0.001). Measured: a cube spanning x = -0.5…1.5
  mirrored whole spans ±1.5 with 16 vertices, bisected 12, flipped ±0.5; a
  bisect axis that is not mirrored cuts nothing; a cube 0.01 from the plane —
  0.02 from its image — merges at 0.021 and not 0.019; a cube touching it gives
  12 vertices and 11 faces merged, 16 and 12 not. Blender clamps a negative
  distance to 0; the simulator does the same. The distance field shows six
  places (`NumberFieldUnit.fineMeters`), where three showed 0.0005 as 0.001.
- **Clipping changes what a drag commits, so the preview clips.** Every
  edit-mode transform ends in `transform_convert_clip_mirror_modifier_apply`:
  per mirrored axis, in the object's space, a vertex that started within the
  merge distance of the plane, or has crossed it, gets that coordinate set to 0
  — with Merge on or off, for translate, rotate and resize, for every vertex
  when proportional editing is on (one 0.0005 from the plane and out of reach
  was pinned) and only the selection when not, and not for a Mirror turned off
  in the viewport (`show_viewport` is now in Mirror's record for this alone).
  `MirrorClip` holds that rule; the gizmo's preview and the simulator's
  operators both apply it. `run-tools-blender-check.sh` has three clipped drags
  on its transformed grid — a move, a turn, a proportional move — and each
  matches Blender to 7e-7, where the same drag previewed without the modifier
  would have missed by 1.139, 0.055 and 0.283. That holds where the drawn mesh
  is Blender's base mesh, which is what the check installs; with the Mirror
  shown in edit mode, Blender's default, the device draws the mirrored mesh
  (see "Not done" below).
- **The simulator** takes every new line (`_SETTINGS`, `modifier_set`), and its
  Mirror bisects, flips and merges (host-checked against the merged counts and
  the bisected spans above; its bisect cuts triangles, so its counts differ);
  its shim names the new operators it cannot run, and the selection counts
  their leads read, instead of raising AttributeError.

Checks: `run-redo-tests.sh` (149), `run-redo-blender-check.sh` (506 calls; each
edge tool on a grid chosen for it, its measured effect, its refusals),
`run-modifier-tests.sh` (142), `run-modifier-blender-check.sh` (108),
`run-modifier-shim-tests.sh` (22), `run-tools-blender-check.sh` (150),
`run-tools-shim-tests.sh` (31). The app was built; none of this was seen in the
running app or the simulator.

Not done, found on the way: sharp edges, creases and bevel weights are not
drawn — the mirror carries no such flags, so the effect is in Blender and in a
render or a subdivided mesh but not in the viewport's edges. (Seams travel with
the UV mirror, `_seams`, and `ViewportRenderer` draws them in edit mode — read
from the code, not seen on screen.) With a Mirror
shown in edit mode (Blender's default) the viewport draws the mirrored mesh, so
a drag's preview moves the picked vertices but not their images, and the
selection is not reported back by index (read from `_report_edit_selection`
and the gizmo, not seen on screen); the clipping preview is exact where the
drawn mesh is Blender's own, as the check runs it. Mirror Object and Bisect
Distance have no rows; a Mirror with a mirror object would clip in that
object's space, which the preview does not model.

**The edge tools' review** (2026-09-22). An adversarial review of the round
above found one high defect and seven smaller ones. Each fix below was measured
before and after.

- **A simulator drag on a modified mesh multiplied it.** In the simulator
  `obj.mesh` is `ModifierStack`'s output, and the gizmo's preview, its
  roll-back and `BKScene.perform` all moved that output and handed it back
  through `setMirroredMesh`, which ran the stack over it again. On a cube with
  a Mirror X and Clipping, one vertex picked, the preview showed 95 vertices
  over a base of 48, the roll-back left 96, and the commit plus two more
  translates reached 761 over a base of 381, so Clipping ran on the mirrored
  copies too. The three now move `BKObject.editCage`, which is the base when
  the stack is not empty and the mesh is not Blender's evaluated one, and
  install it once. The same drag now keeps the base at 24 and shows 47, since
  Merge welds the clipped corner to its image. The commit lands where the
  preview did, a Subdivision's base moves instead of its output, and a
  selection of vertices only the stack made (a Mirror's image) gets no gizmo
  and moves nothing, since Blender's cage has no such vertex
  (`run-tools-tests.sh`, "the simulator edits the mesh its modifier stack runs
  over"). Device is unchanged: an evaluated mesh is its own cage.
- **The Mesh menu offers Select Edge Loops / Rings, Mark / Clear Seam and
  Sharp, Edge Crease and Bevel Weight in Edit Mode only**
  (`Mesh.editModeOnly`). From Object Mode the bridge's call acts on the
  selection the mesh stored, and the app draws neither that selection nor the
  flags there. Measured with the `performBody` it sends: on a new cube, Mark
  Seam marked 12 of 12 edges and Edge Crease at 0.5 creased all 12.
- **Select Edge Loops / Rings have a Delimit row.** 5.2.1's RNA has
  `delimit_edge_loop` (flags, default {OUTER_CORNERS, NGONS}) and
  `delimit_edge_ring` (default {NGONS}), which the code and its test had as
  "nothing to adjust". The row offers Blender's default plus Seam, Sharp or
  both, keeping the default flags. On a 10 × 10 grid the loop took 10 edges
  past a seam and stopped at 7 with Seam, and a ring took 11 past a sharp rung
  and stopped at 8 with Sharp.
- **Edge Slide's Flipped is greyed until Even is on**
  (`Parameter.activeWhen`). Alone it gave exactly the default result at +0.5
  and -0.5 on a tilted grid, and it changed the result at both once Even was on.
- **The Info log has the bare call again.** The CANCELLED check is in
  `executedPython`, which the bridge runs, first run and re-run alike. The
  leads' `total_edge_sel` refusals (the Loop Cut precedent) are still logged.
- **A test that could not fail** ("every operator is in a group the menu
  draws", true by construction) is now "every group the menu draws has an
  operator in it".

Not done:
- Sharp, crease and bevel weight are still not drawn in Edit Mode.
- No-effect FINISHED results are still reported as success. Measured in
  5.2.1, `edge_slide(value=-0.5)` on a boundary loop moved 0 vertices; factor
  0 changed nothing for edge_slide, vert_slide and edge_crease; and
  `offset_edge_loops_slide` at 0 added 22 coincident vertices (121 → 143).
  Blender itself reports these as success too.
- Slide Vertices' ±Z direction on a flat grid slid along -Y (measured), so the
  row can name an axis the vertex does not move along.
- Mark Sharp's `use_verts` (shown in Blender's panel) is not offered.
- `MirrorClip` ignores `mirror_object`.
- On device the preview does not move a Mirror's images.
- Every other simulator edit operator (`bk_scene_mesh_op`: extrude, inset,
  subdivide, …) still edits `obj.mesh` and re-runs the stack on it. The sculpt
  stroke's `setMirroredMesh(obj.mesh…)` has the same pattern. Neither was
  measured this round.

Checks: all 30 `run-*-tests.sh` suites (`run-tools-tests.sh` 104 checks,
`run-redo-tests.sh` 171), `run-redo-blender-check.sh` (514 calls, 437 checks),
`run-tools-blender-check.sh` (196), and the 3dview, camlight, mirror,
objectmenu, undo and modifier Blender checks. The app was built. None of this
was run in the running app, in the simulator or on a device.

**Apply's rows, read from the channels Apply bakes** (2026-09-21). A review of
the round that added Set Origin and Apply found the menu greying its rows from
the wrong number: a Float32 decomposition of `matrix_world`, where
`transform_apply` bakes the *local* channels. Measured in 5.2.1:

- **Mirrored, (-1,1,1):** the decomposition read scale 1 and a half turn about
  Z, so Apply Scale was greyed — the one whose bake flips the normals (a face
  normal went from -X to +X) — and Apply Rotation was offered for no rotation.
- **Parented:** a cube under an empty scaled 0.01 read 0.01, but Apply Scale
  returned FINISHED, moved no vertex and still pushed an undo step. At scale 100
  under that parent it read 1, greyed, where Blender bakes ×100.
- **Float noise:** a unit cube turned 45° or 10° read 0.99999994, offering
  Apply Scale with a "1 × 1 × 1" subtitle.
- Apply also bakes and resets the deltas (`delta_scale` (2,1,1) doubled X), and
  a QUATERNION or AXIS_ANGLE object keeps `rotation_euler` at zero while Apply
  Rotation turns it. A zero quaternion is a half turn about X, not no turn.

The mirror now sends each object's own channels (`_blenderkit.sync_local`:
location + delta, rotation as a quaternion in whatever mode, scale × delta,
signed), frame changes included, and `ObjectTransformState` reads those with a
1e-5 tolerance. An object that arrives without them has every row offered, not
greyed on a guess.

- **Area lights take Apply Scale** (scale 2 made size 1 into 2; a square one
  scaled (1,2,3) becomes a 1 × 2 rectangle). The rule now reads a light's kind,
  and Apply's menu is open for one. Apply All, Location and Rotation on it —
  and on text — are refused by Blender in its own words, naming the object, and
  a mixed selection is refused whole; the banner shows that sentence rather
  than a row being greyed.
- **The refusal says what it refuses.** "needs geometry. Select a mesh, a curve
  or a text object" was wrong both ways: text fails three of Apply's rows, and
  both operators act on armatures, lattices, metaballs, surfaces, hair curves,
  point clouds and Grease Pencil (each measured FINISHED, the transform moved).
  It now reads e.g. `Apply Transform does nothing to cameras, point, sun and
  spot lights, speakers, light probes or volumes: "Camera"`. Blender does
  print `Info: Set Origin not supported for Camera object(s)` — to a status
  bar a bpy module has none of.
- **Undo is "Apply Object Transform"**, Blender's label for every row
  (`get_rna_type().name`), not "Apply Scale".
- **Tests go through the real call.** The 3D View check sends through
  `BpyBridge.setOrigin` / `applyTransform` and `run(_:undo:setup:)` rather than
  a copy of how it joins `setup:`, confirms each of 19 object types against
  Blender one at a time, and writes 20 scenes' mirror records and what
  Blender's operators then did; the same binary replays those through
  `ObjectTransformState` (moved to the bridge so it compiles on the host). With
  the old world decomposition and type list put back, 18 of its checks fail.
- **The simulator** baked `obj.mesh` — the modifier stack's output — and
  `setMirroredMesh` ran the stack over it again, so Apply or Origin to Geometry
  applied every modifier twice and took the median of evaluated vertices. It
  now bakes the base (`BKScene.bakeSelectedTransforms`, host-tested), leaves a
  camera beside a mesh alone, and refuses an empty or an area light rather than
  answering FINISHED for a bake it does not model. Its `Object.type` was not
  hard-coded to MESH for these, as the review thought: `bpy/_objects.py` wraps
  it, and the camlight shim suite now shows the refusals firing there. On the
  simulator five of Set Origin's six rows raise NotImplementedError; only
  Origin to Geometry about the median is modelled.

**Set Origin and Apply, second review** (2026-09-22). Measured in desktop
Blender 5.2.1 unless said otherwise.

- **A frame change could stop playback.** `push_frame` now pushes each moved
  object's channels (`push_local`), and `bk_sync_local` answered -1 for a name
  not on screen, which `PythonBootstrap.c` raises as ValueError — before
  `anim_frame` was sent. A keyed object the mirror did not hold (HEAD's pass
  skipped a plain curve and an emptied mesh; any object keyed since the last
  pass still qualifies) made `frame_set(10)` raise, no frame reached the
  timeline — not even another keyed cube's — and `TimelineDriver.setFrame`
  stopped a frame behind Blender. Now `SceneMirror.carryLocal` skips that name
  outside a pass, as `AnimationMirror.applyFrame` skips a matrix (0, not -1;
  mirror host suite), and `push_local` catches a refusal either way. The
  animation check's stand-in now has `sync_local`, held to the device's rule,
  and a check with every push refused: with the old `push_local` that one
  raised and sent no frame. Channels Blender holds as NaN (it does, when a
  script sets them) arrive as unknown, not as a refused push. `push_mesh` had
  the same hole from before this round: `anim_mesh` refuses a deformed object
  the screen does not hold (a shape-keyed cube added since the last pass
  raised, and no frame was sent). `push_frame` now asks for the whole mirror
  that brings it in instead, and the stand-in's `anim_mesh` follows that rule.
- **Set Origin moves a collection instance.** `origin_set` on an empty whose
  `instance_type` is COLLECTION *with* a collection set moved it under all six
  rows (to the cursor; to (4, 5.5, 3) for Origin to Geometry); a plain empty,
  COLLECTION with none set, or a collection under NONE stayed put. The menu
  greyed it and the guard refused it. The mirror's empty record now carries
  `instances_collection`, and the reach and the guard both read it.
- **The simulator's Apply Location or Rotation alone moved the object.** It
  baked the chosen channel's own matrix; Blender bakes (RS)⁻¹·loc and S⁻¹·R·S,
  so nothing moves (world vertices 6.83 and 1.09 off, now 0 for all seven
  channel combinations, with Blender's baked corner to 1e-4). A zero scale does
  as Blender: Rotation alone is skipped (CANCELLED), Location still bakes.
- **No active object no longer greys the menus.** A selected cube with
  `view_layer.objects.active = None` had its scale applied and its origin set.
- **The subtitle has the tolerance's digits** (`%.6g`): a scale of 1.0002 read
  "1 × 1 × 1" under `%.3g`.
- **The replay counts only Blender's refusals** for an offered row. It passed
  on any "refused", so the guard turning away what the menu offered passed
  too; with the instance guard removed and the menu left open, it now fails.
  The reach check is 20 rows (19 types, plus the instance) and the replay 23
  scenes.

Not fixed here, found on the way: `run-undo-blender-check.sh` fails at HEAD
5250eed as well — its stand-in module answers `hasattr(_, 'tool_state')`, so
the mirror imports `_blenderkit_tools`, which that check never puts on the path.

**Snapping and proportional editing commit what they preview** (2026-09-21).
An adversarial review of the round that added Pivot, Snap and Proportional
found the defect this codebase keeps shipping, twice: the drag *previewed* one
result and *committed* another.

- **Snapping never reached Blender.** The magnet rounded the preview and the
  release sent the raw drag, so Blender moved off the grid and the mirror
  pulled the object after it. Edit-mode drags, rotations and scales never
  rounded at all. A headless Blender cannot do it for us — measured in 5.2.1,
  `translate(value=(0.3,0,0))` landed on 0.3 with INCREMENT on, and again with
  `snap=True` passed to the operator, because exec takes `value` as final. So
  the drag now snaps its own result (`TransformSnap`) and the release sends
  that value: one vector for the whole selection, as Blender moves it.
  Increment is relative — steps of the increment from where the drag started,
  in the handle's axes; 5° for a turn (`snap_angle_increment_3d`'s factory
  value, measured 0.0872665); 0.1 for a scale. Grid is absolute and moves only:
  the Snap With point (the median for Closest) lands on a grid point, along the
  constraint, or on the ground grid under the pointer for a free drag. Grid
  wins when both are ticked. These rules are read from transform_snap.cc and
  transform_snap_object.cc, since Blender cannot be made to snap headless.
- **Proportional editing previewed nothing in object mode**, and the commit
  pulled the unselected objects in reach (the review measured one jumping
  0.104 in Z on release). Edit-mode rotate and scale previewed nothing either,
  and Connected Only was ignored. `TransformOperation` (TransformEvaluation.swift)
  now holds Blender's formulas — measured: LINEAR at size 3 pulled cubes 1 and
  2 away by 0.6667 and 0.3333 of a move, 60° and 30° of a 90° turn, and scaled
  them 1.6667 and 1.3333 of a doubling — and the preview, the simulator's
  operators and the tests all run it. Distances are in world space (measured:
  a grid scaled ×2 in X reached 11 vertices where the unscaled one reached 21),
  and Connected Only is Blender's own front propagation, ported, walking
  Blender's polygons and edges as the mirror describes them. Root's curve was
  1 − √t here and √(1 − t) in Blender.
- **`use_proportional_edit` in object mode is not a mismatch.** Measured: the
  operator's argument has that name in both modes, it moved the unselected
  cubes in object mode, and it left both tool settings False — an exec never
  writes its arguments back.
- **Individual Origins with proportional editing** ran one operator per object
  with the arguments passed along, so each call pulled the rest of the
  selection as neighbours. With A and B selected 3 apart, C 1 from A and D
  between: C went to x = 1.125 at scale 1.875 and D moved. Desktop Blender,
  given a 3D View through a context override so it reads the pivot, leaves
  both in place at 1.5 and 1.099. `transform_individual` now does that, and
  measured 1.5 and 1.099.
- **The preview spells its numbers as the commit prints them**, four places.
  A scale of 10 about a `center_override` printed 5e-5 off put a vertex 5e-4
  from where the preview had.
- Found on the way: one object scaled about the 3D cursor previewed in place
  and committed moved away from the cursor; an edit-mode preview installed its
  mesh with `setMirroredMesh`, which ran the modifier stack over Blender's
  evaluated mesh again (the double application 5250eed took out of the mirror).
- **The simulator** dropped `center_override` and every proportional argument:
  rotate and resize acted in place, whatever the pivot, with no report. Its
  `bpy.ops.transform.*` now hand their arguments to `TransformOperation` through
  `_bk.transform_operator`, moving vertices in edit mode, and refuse what they
  cannot model (a mirror, snapping, a local turn) rather than doing something
  else. Measured for them: exec does not apply `constraint_axis` to `value`.
- **The Snap menu** is Blender's VIEW3D_MT_snap in 5.2.1's order, with the
  three it lacked: Selection to Active, Cursor to Grid, Cursor to Active —
  done from RNA like the other four, whose operators all fail their poll
  headless (measured, all seven). Grid
  rounds halves upward, as view3d_snap.cc's `floorf(0.5f + v)` does; Python's
  `round()` sent 0.5 to 0.
- **Smaller:** unticking the last snap element sent `set()`, which Blender
  ignores (measured: the value stays) and the simulator stored — the last one
  cannot be unticked now. The Size and 3D Cursor fields write once when a drag
  ends rather than per sample. Two comments stated measured facts wrongly.

Measured: scripts/run-tools-blender-check.sh now drags every case through the
real session and holds Blender's result against the preview — 144 checks:
snapping; a move, a turn and a scale in object mode for every falloff but
Random, about the cursor and with Individual Origins; and proportional
translate, rotate and scale with and without Connected Only on Blender's own
grid, UV sphere and subdivided cube, each moved, turned and scaled unevenly.
Every gap is float noise (at most 1.2e-6) but one: on the cube,
two vertices sit 2e-8 inside the Root falloff's rim, float rounding admits a
different one on each side, and Root's slope there makes it 1.7e-4–4.4e-4.

Not done: Random's weights cannot be previewed (Blender seeds them from the
clock) and the panel says so. A rotation or scale with Grid alone is not
snapped (Blender turns toward a grid point under the pointer). Parenting and
`hide_select` are not mirrored, so the preview can pull a neighbour Blender
leaves alone. None of this was run in the live app or the simulator.

**Snapping: what moves with the drag, Auto Merge, and what Blender offers**
(2026-09-22, second pass). An adversarial review of the snapping round found
two high-severity defects of the kind this codebase keeps shipping — a control
that ran nothing, and a preview that disagreed with the commit — and nine
smaller ones.

- **Auto Merge was a log line.** The toggle wrote a local copy and
  `session.log`'d a `use_mesh_automerge` line that ran nothing, and the edit
  preview welded at the app's own 0.02, so a vertex snapped onto another
  showed a weld Blender never made. Measured in 5.2.1 headless: the
  `transform.translate` the gizmo commits honours the scene's
  `use_mesh_automerge` and `double_threshold` (the 3 × 3 grid's centre moved
  onto its neighbour left 9 vertices off and 8 on; moved to 0.9995 it merged at
  0.001, to 0.9985 it did not). Both are now mirrored with the rest of
  `tool_settings` (eleven ints and five doubles), written through `bridge.run`
  from an Auto Merge panel in More ▸ Transform Tools while editing, and the
  preview welds by Blender's rule (`AutoMerge`, TransformEvaluation.swift): a
  moved vertex goes into the nearest unmoved one within reach, which keeps its
  place (measured: moved to 0.9996, the survivor stood at 1.0); unmoved
  vertices never weld to each other (0.0005 apart, both stayed); moved ones
  left over weld into the lower index. That is `find_doubles` with
  `keep_verts` the unselected vertices (`%Hv`, editmesh_automerge.cc). The
  simulator's translate welds by the same call. ToolHeader's toggle, which
  nothing instantiates, is gone.
- **Children and dependents were targets.** Blender tags every base a move
  reaches through the depsgraph (BA_SNAP_FIX_DEPS_FIASCO,
  transform_convert_object.cc) and `snap_object_is_snappable` turns them away.
  The mirror now sends each object's parent and everything it depends on
  (`_blenderkit_sync._relations`: parent, constraint and modifier Object and
  Collection pointers, one level into their collections, Geometry Nodes
  inputs and node-tree sockets, drivers, a collection instance; 2.8 µs an
  object, 5.6 with two modifiers, a constraint and a parent, over 1000 objects
  in desktop 5.2.1), and an object-mode move leaves out the selection and
  everything that depends on it. Held against Blender's own depsgraph: for all
  28 objects of a fixture tying objects together each of those ways, what the
  Swift works out moves with each one is exactly what `depsgraph_update_post`
  reports updated when it moves. With proportional editing Blender flushes the
  flag from every visible object that is not selected, not a parent and not a
  child of the selection (`count_proportional_objects`), reached by the falloff
  or not, so only the selection's ancestors stay in reach; the round before
  excluded only the neighbours the falloff reached.
- **The preview carries children.** Measured in 5.2.1: translating a parent
  alone moved its unselected child from x = 3 to x = 4. The drag now moves
  everything carried through `parent` — the selection's descendants and the
  proportional neighbours' — by the change in its parent's matrix, on top of
  any share of the move it has of its own, parents first. Measured headless on
  a parent chain at Linear size 3: the selection's parent 1 away stayed put, but
  its child 1 away moved 1.667 on a move of 1 — its parent's 1 and its own
  0.667, whatever `count_proportional_objects` reads as — and a turn of 0.6
  landed every object on (parent after × parent before⁻¹) × (its own share where
  it stood). A selected child of a selected parent only follows (BA_WAS_SEL),
  except through Individual Origins, where `transform_individual` turns each
  one and leaves the selection's children out of the shares (`_in_reach`).
- **Smaller:** a curve with no surface (evaluated geometry with no mesh:
  measured None for a Bezier circle whose `to_mesh()` is a 48-point wire) is
  snapped by its control points alone, as points and through the occlusion
  plane, as `snapCurve` does; the mirror sends them (`_push_knots`). Display As
  Bounds objects are no targets (`snap_obj_fn`). Wireframe shading counts as
  X-Ray (factory `show_xray_wireframe` True, measured). With Face Center and no
  edge element, the corners of the polygon under the pointer are tried first,
  and one found there leaves no snap at all (`retval = elem & snap_to_flag`),
  as in Blender. A constrained Edge snap meets the edge direction Blender
  reports — the local edge carried as a normal, (M·Mᵀ)⁻¹ times the world edge
  — which differs from the drawn edge under a non-uniform scale. Include
  Active and Include Non-edited (`use_snap_self`, `use_snap_nonedit`) are
  mirrored, shown and honoured while editing. Snap To's last element can be
  unticked while Face Project or Face Nearest is on (measured: Blender takes
  the empty base set then). Gathering the targets no longer hashes every
  triangle side or allocates per polygon: 116 ms at 1.28 million triangles
  where it was 460 (host, -O), 6.7 ms at 80,000. Two tests could not fail — 13
  checks compared `snapped()` with the `snapping().result` it is defined as,
  and a roll-back that captured the moved mesh made each later drag start
  somewhere else — and are fixed.

Measured: `run-snap-tests.sh` (116 checks), `run-tools-tests.sh` (113),
`run-tools-shim-tests.sh` (55) and `run-tools-blender-check.sh`
(230): the settings written and mirrored; Auto Merge on, off and a
near miss 0.01 short, each committed in Blender and compared vertex for
vertex with the preview (Blender kept 120, 121 and 121 of 121, the preview the
same, at most 4e-7 apart); the 28-object relations fixture against the
depsgraph; a parent snapped with its child; a parent chain moved, turned and
scaled with proportional editing, and turned with a selected child about the
median and about Individual Origins (every object within 5.4e-7 of the
preview); and the control points sent for a Bezier circle and a NURBS path and
none for a bevelled curve. Five mutations — no followers, a 0.02 threshold,
parents only as dependents, the selection's children given no share, a
selected child moved twice — each failed the Blender check. The app builds;
none of this was run in the live app or the simulator.

Not done: gathering still runs on the main thread when the finger goes down
(116 ms at 1.28 million triangles); `use_mesh_automerge_and_split` is not
mirrored, so its splitting is not previewed; `use_snap_selectable` and
`hide_select`, and both kinds of backface culling, are not mirrored;
`use_snap_edit` is not mirrored and has no effect with one edited object;
Affect Only Origins and Parents (`use_transform_data_origin`,
`use_transform_skip_children`) are not mirrored, and change both what moves
and what Blender leaves out; constraint followers are left out of the targets
but not previewed; a curve in edit mode (the app edits meshes only).

**A move snaps to vertices, edges and faces** (2026-09-22). Measured in 5.2.1
headless: `translate(value=(2.7, 0, 0), snap=True, snap_elements={'VERTEX'})`
left a cube at x = 2.7 with another cube's corner a vertex snap away, as the
round-1 review found with a 3D View override and the GPU started. The search
runs from the pointer in a view region, which an exec has none of. So the app
runs it (`GeometrySnap`, beside `MeshPicker`), over the meshes the mirror holds
and the camera frozen at touch-down, and sends the move it found as `value`.

- **Blender's rules, from the 5.3 source** (transform_snap.cc,
  transform_snap_object.cc, transform_snap_object_mesh.cc,
  transform_constraints.cc): nearest to the pointer within
  `SNAP_MIN_DISTANCE` (30, taken as points); a vertex or an edge beats the
  face the ray hit; edges measured at the point nearest the pointer's ray, a
  Vertex or Edge Center found through its edge by where along it the ray passes
  (with all three chosen, the middle fifth is the centre); the occlusion plane
  of the surface under the pointer unless X-Ray is on, the hit polygon's own
  elements tried first; geometry before Grid, Grid before Increment. Snap With
  Closest is the moving object's bounding-box corner, or the selected vertex,
  nearest the target. An axis meets an edge where it passes nearest and a face
  where it crosses its plane; a plane meets an edge where the edge crosses it;
  everything else is projected. Face Center is the corners' mean, measured:
  `polygon.center` gave (2, 1, 0) for the quad (0,0) (4,0) (4,1) (0,3), whose
  centroid is at x = 1.67.
- **What moves is never a target**: the selection in object mode; while
  editing, the selected vertices and every edge and face touching one, and
  hidden vertices. Proportional editing's neighbours too. (The second pass,
  above, found this short of Blender's rule: children and dependents were
  still targets, and with proportional editing Blender leaves out far more.)
- **Quads, not the viewport's triangles.** The mirror's loops (sent with the UV
  map) mark triangulation's diagonals, so a diagonal is no edge and a quad's
  centre is its own; while editing, `EditTopology` says the same.
- **Committed exactly.** The move is written to six places when a session can
  snap to geometry: rounded to four, a snapped vertex could stop up to 5e-5 per
  axis beside its target. The preview runs the same rounded numbers.
- **Shown while dragging**: Blender's symbol at the target (a square on a
  vertex, a bow tie on an edge, a triangle on its centre, a circle on a face, a
  dotted circle on its centre, a crossed circle on an empty's origin), in its
  active-element colour, as a layer over every 3D View; and "snap Vertex" in the
  readout, since the finger covers the symbol.

Measured: `run-snap-tests.sh` (78 checks, new) and `run-tools-blender-check.sh`
(196, 46 new). The new Blender cases drag cubes onto the subdivided-cube
fixture, installed with its loops as the mirror installs it, and edit-mode
vertices onto the grid, cube and sphere fixtures: every target found lies on
Blender's own geometry (at most 1.8e-6 away; the Edge case aims at a quad's
centre, where both diagonals cross), Blender lands where the preview did (at
most 5e-7), and Blender's own Snap With point is where the constraint rule,
worked out again from Blender's geometry, puts it (at most 1.6e-5, on a move of
13.76). Searching took 0.4 ms and gathering the targets 16–24 ms for a mesh of
80,000 triangles (host, -O). The app builds; none of this was run in the live
app or the simulator.

Not done: rotations and scales do not snap to geometry (Blender turns and
scales toward the target); Volume, Edge Perpendicular and the loose edges of a
mesh that has faces (the mirror carries no such edges) are not searched; a mesh
with no UV map carries no loops, so its diagonals count as edges and its
triangles as faces. Found and left alone: 5.2.1's factory `use_snap_rotate` and
`use_snap_scale` are False (measured), and transform_snap.cc's
`initSnappingMode` then turns the magnet off for a turn or a scale, while the
drag here steps both whenever Increment is on — those settings are not
mirrored.

**Wire objects reach the mirror; modifier rows show Blender's values**
(2026-09-21). The review of the round that added four modifiers, Spin's centre
and Knife Project, after 5250eed fixed its two critical findings.

- **The mirror dropped every mesh with no triangles**, and with them empty
  meshes, curves with no splines, empty text and anything past the vertex
  limit. The app's own Add ▸ Circle is a wire (fill type Nothing: 32 vertices,
  32 edges, no face in 5.2.1), so it never reached the viewport, the Outliner
  or Knife Project's cutters; neither did an unfilled Bézier circle. Measured
  against HEAD with the new check, 8 of 12 objects in its scene were missing and
  Knife Project offered only the one cube in it. Now every
  object is pushed. One with edges and no faces is sent **as edges**
  (`sync_edges`), drawn as lines — black, or the selection oranges — and picked
  by them, with the overlays on or in Wireframe shading (not "on or off": see
  the next entry); a face in front still takes the tap.
  Loose vertices and empty meshes arrive with their bounds and nothing drawn; a
  mesh past `_MAX_VERTS` arrives as its bounding box, twelve lines, and the Mesh
  panel says how many vertices it is not drawing. Edges that change while every
  vertex stays are a change (the unchanged-mesh shortcut compared vertices and
  triangles only).
- **The modifier rows wrote the display cache first** and then sent every
  setting, so a refused change stayed on screen and one refused setting failed
  every later edit: a Shrinkwrap whose target was deleted resent
  `target = bpy.data.objects["…"]` with each Offset change (measured: KeyError;
  Blender itself clears the pointer, and follows a rename). A row now writes
  nothing, sends only the settings that differ from the mirrored modifier
  (`Bpy.modifierEdit`), and shows what comes back. A number is scrubbed as a
  draft and sent once when the finger lifts, where each drag sample was a
  `bridge.run`: for Remesh, a voxel remesh, a mirroring pass and an undo step
  per frame. Rows keep their identity from pass to pass.
- **Wave has no axis.** Blender's Wave rises along Z; `use_x` and `use_y` say
  where the ripple travels — both a ring (the default), one a line of crests,
  neither a flat lift of every vertex (measured on a grid). The row's X/Y/Z sent
  `use_x = axis == 0` and `use_y = axis == 1`, so its "Z" — the default it
  showed on device while Blender held a ring — lifted the mesh flat. It is now
  Motion X / Y, mirrored both ways. The simulator's Wave is Blender's formula at
  frame 1 (0.49479 at x = 0.293 on the measured grid, 0 where the crest has not
  arrived), where it was `sin(4r)` along a chosen axis.
- **Remesh's Voxel Size floor scales with the object**: its largest dimension
  over 256, the octree's own ceiling. Measured: VOXEL gives 6.05 N² vertices on
  a cube N voxels across at any size (396,296 at N = 256 on 2 m and 6 m cubes;
  4.7 N² on a sphere), so the fixed 0.01 let a 6 m cube reach 2.17 million and a
  13 m one pass the mirror's limit. Add Modifier ▸ Remesh on an object whose
  floor is above Blender's default 0.1 sets the floor in the same evaluation, on
  `modifiers.active` (the new one, measured even ahead of a pinned-last
  modifier): a 100 m cube starts at 0.390625 and evaluates to under 450,000.
- **The simulator's rows** now go through the shim for everything they send:
  object pointers by name (`modifier_set_object`, refusing the modifier's own
  object with Blender's TypeError), Mirror as one `use_axis = (…)`, Wave's
  Motion, `modifiers.active`; `deform_axis` on a Wave raises, as in Blender. Its
  Decimate reports the face count its own collapse produced — the Faces row read
  0 there for ever.
- **Knife Project after a render.** Whichever thread starts Blender's GPU module
  keeps its context, and the Render panel renders on the script thread, so an
  Eevee render first would have left Knife Project refusing for the session. The
  session now starts the module on the main thread before any script-thread run
  that may need it (`ScriptThread.mayStartGPU`). In a fresh desktop Blender:
  started on the main thread, the panel's own Eevee render on a worker thread
  and then a cut both work; without the start, desktop Blender aborts on the
  worker (exit 134), so the unfixed order cannot be run there at all. The
  existing check's label claimed "either order"; it ran one. The menu's empty
  state asked for curves and text the Add menu cannot make, and in the
  simulator, where the stand-in cannot cut, the menu now says so.
- **Tests go through the real code.** The merge, and what one `sync_push`
  becomes, moved out of the `bk_sync_*` entry points into `SceneMirror`
  (host-compiled). `run-mirror-blender-check.sh` runs the app's own `sync()` in
  Blender and replays every call through it, two passes: all 12 objects on
  screen at Blender's counts, a Screw added to an object already there drawn at
  Blender's evaluated count with its row, an edge moved between vertices that
  stay. The modifier check now makes edits from Blender's own record through
  the Swift (`main.swift --edit`) and runs them back in Blender.

Not run: none of this was built into a device or seen in the running app or the
simulator — the app was built, and the suites above run. The wire pass and its
picking are checked on the Mac through the code paths, not on screen. The
render-first order on the iPad's Metal backend is inferred from desktop.

**The frame path, stale wires and the Remesh row** (2026-09-22). The review of
the wire-objects round above.

- **A frame change ran the modifier stack over Blender's mesh.** 5250eed took
  that double application out of the mirroring pass; `AnimationMirror.applyMesh`
  still installed `push_mesh`'s evaluated mesh with `setMirroredMesh`. Measured:
  a cube with a Screw of 16 drew 384 vertices after a pass and 6,144 after one
  frame change of the same mesh; in Blender 5.2.1 a Wave reports
  `is_updated_geometry` on every `frame_set`, and a frame change replayed
  through the old code drew a Screw-and-Wave cube at 2,048 vertices for
  Blender's 128, a Wave grid up to 0.50 off Blender's positions and a Wave
  wire 0.14 off. It installs with
  `setEvaluatedMesh` now. So does the simulator's Duplicate of an object whose
  mesh is Blender's (9,216 vertices for 384 before).
- **Wires stood still through playback.** `push_mesh` returned early for a mesh
  with no triangles; it now sends such a mesh with its edges (`anim_mesh`'s
  optional fifth buffer). A wire circle with a Wave was drawn 0.126 from
  Blender's at frame 9.
- **A wire that lost its edges went on drawing them.** `_push_edges` skipped an
  empty list, the vertices came back identical, and the mirror reused the old
  mesh, edges and all. Measured: Add ▸ Circle, then Delete ▸ Only Edges & Faces
  leaves 32 vertices where they were and no edge; 32 edges stayed drawn and
  tappable. The empty list is sent now.
- **An edge touching a vertex at the origin was not drawn.** Blender gives a
  wire or loose vertex there the normal (0,0,0), and `outline_vertex`
  normalized it: NaN, which a zero extrusion keeps. Drawn on this Mac's M4 from
  the app's own Shaders.metal (`run-shader-tests.sh`): 0 pixels before, 25
  after — the same as with a (0,0,1) normal — in fast and in safe math. Every
  wire, Wireframe shading and the edit-mode wire go through that shader.
- **The Remesh row's floor fed on itself.** It was read off the mesh on screen,
  which on device is what the Remesh made: a 2 m cube at Voxel Size 2.0
  evaluates to a 0.667 m cube, the floor fell to 0.0026, and the row committed
  it for 3,548,168 vertices in 4 s where 2/256 gives 396,296 (a 100 m cube at 60
  likewise). The mirror now sends the Remesh's input size (`input_size`: the
  object's own mesh, when nothing enabled in the viewport comes before the
  Remesh and it has no shape keys), and the simulator records its own exactly.
  The Blender check drags the row to its floor from Blender's record and mesh
  and commits it.
- **Wires with the overlays off.** Blender draws loose edges and curve wires in
  its wireframe overlay, which runs only when `is_wireframe_mode ||
  !hide_overlays` (overlay_instance.cc in the 5.3 source; read, not measured —
  a `-b` session has no 3D View), and selects by what it drew. The app drew and
  took them in Solid with the overlays off; now only in Wireframe shading then.
- Smaller: a hovered wire drew in the active object's orange, because the line
  pipeline does not blend and its 0.45 alpha was dropped (the colour is mixed
  now); a scene whose only mesh was past the vertex limit logged both "drawn as
  its bounds" and "none reached the viewport"; the modifier shim suite reads
  the keys `bk_scene_modifier_set` takes out of its `switch` (with `case
  "use_x"` deleted it now fails twice; its hand copy passed); and the GPU start
  is run in python3 with a `gpu.init()` that raises, where its check matched
  text.

`run-undo-blender-check.sh` stopped part-way with ModuleNotFoundError
(`_blenderkit_tools`, which its stand-in never loaded; HEAD's modules fail the
same way); it loads it now and runs to the end.

Each new check was run against the code before its fix and failed there: the
frame replay (6 failures), the wire frame (3), the empty edge list (5), the
shader (6), the Remesh floor (4), the log (1), the duplicate (1).

Not fixed: a mesh of loose vertices only is still not drawn or tappable
(Blender draws its points); a mesh with no vertices still arrives as one
vertex at its origin, so the Mesh panel says "Vertices 1"; the simulator's
Decimate Faces row counts triangles where Blender counts polygons; on device a
Remesh with an enabled modifier above it still takes its floor from its own
output; the hull rim's hover colour has the same dropped alpha. Not run: the
app was built, not launched; nothing here was seen on screen or on a device.

**The toolkit a modelling course teaches** (2026-09-21). Asked to check what
professionals actually model with and make sure it is all here, the answer was
mostly yes with three conspicuous holes and one panel that was decorative.

The consensus toolset, from Blender's own manual and from how hard-surface and
box-modelling courses are taught: **Extrude, Inset, Bevel, Loop Cut and
Knife/Bisect** as the five that carry most of the work; **Subdivision Surface,
Mirror, Solidify, Bevel and Array** as the five modifiers; **Boolean** for
cutting one shape out of another; dissolve, merge, bridge and fill for the
clean-up half of the job; and recalculating normals when the shading goes
wrong.

Against that, what was here and what was not:

| | before | now |
|---|---|---|
| Extrude | a drag tool only, no number | Mesh menu, typed offset, in the edit toolbar |
| Inset, Bevel, Loop Cut, Subdivide, Spin | ✓ | ✓ |
| Knife | modal — Blender refuses it without a window | still not possible |
| **Bisect** | ✗ | ✓, cutting through the object's own origin |
| **Dissolve** verts / edges / faces | ✗ | ✓ |
| **Merge at Center / Collapse** | Merge by Distance only | ✓ |
| **Bridge Edge Loops, Grid Fill, New Face from Edges** | ✗ | ✓ |
| **Recalculate / Flip Normals** | ✗ | ✓ |
| **Triangulate, Tris to Quads** | ✗ | ✓ |
| Subsurf, Mirror, Solidify, Array modifiers | ✓ | ✓ |
| **Bevel modifier** | ✗ | ✓ |
| **Boolean modifier** | ✗ | ✓, with the other object picked in the row |

Extrude is a *macro* operator — an extrude and the move that follows it, one
undo step — and its move's arguments arrive as a dictionary under the
sub-operator's name. That is why the file used to say it could not be adjusted.
A parameter kind that emits `TRANSFORM_OT_shrink_fatten={"value": -0.2}` is all
it needed.

**The Modifiers panel was decorative on the real backend, and had always been.**
Two halves of the same hole:

- `modifier_add` runs inside Blender and the mirror never carried the result
  back, so `obj.modifiers` held only what this app had added through its own
  interpreter — which on device is nothing. A modifier could be added, and the
  mesh would change, and the panel would still say "No modifiers". It could not
  then be adjusted, reordered or removed.
- The settings rows called `session.log("# … updated")`. `Bpy.setModifierProperty`
  existed and **had no callers at all**: a Subdivision stayed at the level
  `modifier_add` gave it however the panel was set. The third instance of this
  exact defect found in one day, after the Transform fields and the Material tab.

Both are fixed. The mirror now pushes each object's stack as a
`kind=…;name=…;key=value` record through a new `sync_modifiers` entry point,
next to the one cameras and lights already used, and every row writes Blender's
own property names. Measured: a Subdivision added on device, then stepped to
level 2 in the panel, reads back `levels=2, render_levels=2` from the saved
file and its evaluated mesh goes to 7,938 vertices.

Blender keeps viewport and render levels apart, and the panel sets both — a
level that a render quietly ignores is a trap worth not laying.

**The integer settings never came back.** Found while adding the four below:
`_record_value` writes every number as `repr(float(v))`, so a Subdivision at
level 2 reaches Swift as `levels=2.0`, and `Int("2.0")` is nil. `levels`,
`count`, `segments` and `iterations` all fell back to their defaults on the
first sync after they were set, so the stepper showed the default while Blender
held the new value. They are now parsed through `Float`, and
`scripts/run-modifier-blender-check.sh` holds the round trip against Blender.

**Shrinkwrap, Screw, Decimate and Remesh** (2026-09-21). Each row goes through
`bridge.run`, and each value comes back through the mirror. Measured in 5.2.1:

- **Shrinkwrap's pointer is `target`, not `object`.** Boolean's line copied
  across raises `AttributeError: 'ShrinkwrapModifier' object has no attribute
  'object'`, and it would take the rest of the batch with it. With no target,
  Blender leaves the mesh untouched and raises nothing, so the row says
  "No target — this modifier does nothing" instead of looking finished.
- **Screw** sends `render_steps` with `steps` (the Subdivision trap again), and
  its `axis` is the string `'X'`/`'Y'`/`'Z'`. A new Screw starts at Blender's
  full turn and 16 steps. It used to show the shared 45° default.
- **Decimate shows Blender's own `face_count`.** A default cube at ratio 0.5
  keeps all 6 faces (8 vertices become 5), so without the count the row looks
  like a dead control on exactly the primitives people reach for first.
  `decimate_type` is pinned to COLLAPSE, because `ratio` is inert in the other
  two types. If a script set another type, the row says so.
- **Remesh's octree depth stops at 8**, where Blender's soft limit is 12. On a
  32×16 UV sphere: depth 4 → 968 vertices, 8 → 248,552 in 0.22 s,
  9 → 994,280 in 0.84 s. That is 4× per level, and it re-runs on every edit.
  At that rate depth 11 passes the mirror's 10,000,000-vertex limit, where the
  object is silently not drawn.
- **Lattice is deliberately absent.** Blender accepts a mesh assigned to
  `LatticeModifier.object` without raising and leaves it `None`. This app can
  neither create a lattice object nor edit its points, and an unedited lattice
  changes nothing anyway. So a row would accept a pick and then do nothing,
  forever.

In the simulator's shim, Shrinkwrap leaves the mesh alone, as Boolean does.
Screw emits unbridged rotated copies (Blender's is one swept surface: a cube at
8 steps gives 96 faces). Decimate and Remesh cluster vertices on a grid, which
reduces and facets the mesh but closes no holes. The shim also could not add a
Bevel or a Boolean at all until now: `ModifierKind(bpyName:)` never listed them.

**Still not here**, and worth knowing rather than discovering: Knife (modal),
snapping, pivot points, proportional editing, Set Origin and Apply Transform,
and the Lattice modifier. (Set Origin and Apply Transform came later the same
day; see below.)

**The tools a detailed model needs** (2026-09-21). Asked for models at the
level a bpy script would produce — and built only through the 3D View — the
blockout from earlier the same day was not close. The gap was not effort. A
spoked wheel is 26 spokes, a chainring is 42 teeth, and placing each as its own
object is about twenty typed fields apiece. Four things were missing, and three
of them were bugs.

- **Spin was a lathe, not a radial array.** Blender's `mesh.spin` copies the
  selection instead of sweeping a surface through it when `dupli` is on, which
  is how wheels get spokes and gears get teeth. This offered Steps and Angle
  only, with `axis=(0,0,1)` and `center=(0,0,0)` nailed down. Spin now has
  **Use Duplicates** and an **Axis**, and its centre is *the edited object's own
  origin*: `mesh.spin` measures `center` in global space, so spinning a wheel
  parked seven metres out swung its geometry around the world origin and left
  the scene. One spoke and one Spin is now a wheel.
  - That needed a parameter kind whose identifier *is* the Python, unquoted —
    `dupli=True`, `axis=(0.0, 1.0, 0.0)`. `choice` quotes, and a boolean written
    as `'True'` is a string that reads as true whatever it says.
- **Shade Smooth and Shade Flat existed in the bridge and in no menu.** Blender
  has them on the Object menu and on right-click. They are the difference
  between a subdivided surface that reads as a shape and one that reads as
  facets, which is most of what makes a model built from primitives look
  unfinished.
- **Set Origin and Apply Transform were in no menu either.** Both are now on
  the Object menu in the Mac menu bar and in More, where Blender has them.
  - `transform_apply`'s `location`, `rotation` and `scale` **all default to
    `True`**, so all three are always written out. Measured in 5.2.1 on a cube
    at (1,2,3), rotation (0.3,0,0), scale (1,2,3): `transform_apply(scale=True)`
    came back (0,0,0) / (0,0,0) / (1,1,1) — the origin dragged to the world
    centre. Spelled out in full it came back (1,2,3) / (0.3,0,0) / (1,1,1).
  - **Apply Scale is the one that earns its place.** A modifier measured in
    metres reads the object's local space, so an unapplied non-uniform scale
    stretches it. Measured: a cube scaled (1,1,4) with a Bevel of width 0.1 had
    an evaluated world-space bevel of 0.1 along X and **0.4** along Z. After
    Apply Scale both read 0.1. The menu shows the active object's scale under
    the row, so the trap is visible before it bites.
  - `GEOMETRY_ORIGIN` and `ORIGIN_GEOMETRY` are one word apart, do opposite
    things, and the first is the RNA default — so `type=` is never omitted.
    `center=` is passed only for those two, because measured on a stray-vertex
    mesh the other three types gave identical results for `MEDIAN` and
    `BOUNDS`.
  - **Neither operator fails on a type it cannot handle.** Measured:
    `origin_set` on an empty, camera, light, speaker, light probe or volume
    returns `{'FINISHED'}` and moves nothing; `transform_apply` on all of those
    but the empty returns `{'CANCELLED'}` — except an area light, which it
    bakes (corrected in "Apply's rows" below). Blender reports that to a status bar
    this app has none of, so `bridge.run` would have called both a success and
    pushed an undo step for nothing. A guard raises a sentence the red banner
    shows instead — and it travels in `run`'s `setup:`, whose first call site
    this is, because concatenating it onto the operator would leave a non
    `bpy.ops.` first line and silently drop the `BpyModeGuard` OBJECT bracket
    both of these need.
  - Not guarded, because Blender does not guard it either: applying a keyed
    channel bakes the geometry and then has the F-curve put the old value back
    on the next frame change, doubling the transform.
- **The Material tab could not colour anything.** It set `object.color` and
  then called `session.log`, which appends Python to the Info log and runs
  nothing — the same defect as the Transform fields, in the same session. And
  `object.color` is a viewport display property that Cycles ignores unless a
  material reads it through an Object Info node, so even had it run, a coloured
  scene would still have rendered grey. It now writes the Principled BSDF's
  Base Color, Metallic and Roughness.
  - **sRGB in, linear out.** The picker hands back sRGB — that is what a hex
    like `4E6B3A` means — and everything Blender shades with is linear. 0x4E is
    0.306 as sRGB and 0.074 as linear: more than a factor of four of green.
  - It applies to the **whole selection**, because the alternative is colouring
    four wheels one at a time. The material stays per object (named after it),
    since one made by `materials.new` is shared the moment a second object gets
    it, and colouring one wheel would colour every object made from the same
    primitive.
- **Object Details is on `N`**, Blender's sidebar key, and in the Mac menu bar.
  It was reachable only through a pop-up menu that extends past the right edge
  of the window, where a missed click lands in another app.

Measured after, across the whole scene: **48 objects and 11,696 triangles
became 80 and 24,264.**

| | before | after |
|---|---|---|
| car | 15 objects | 30 objects, 7,952 triangles |
| bike | 10 objects | 27 objects, 10,436 triangles |
| dinosaur | 23 objects | 23 objects, 5,876 triangles |

The bike gained 26 spokes per wheel from one Spin each, rims, a hub, a
chainring, cranks, two pedals, a cassette, two chain runs, twin fork blades,
bar grips and a seatpost. The car gained a rim and 26 spokes in each of its
four wheels, four windows, two tail lights, a grille and an exhaust. Eleven of
the dinosaur's parts carry a Subdivision modifier and are smooth-shaded — it
gained no parts and 3,000 triangles, which is the point of a modifier — and its
spikes and claws are left flat on purpose.

One thing to know about the redo panel: **invoking Spin twice compounds.**
Changing a value in the panel re-runs the *same* operator from the restored
mesh, which is right; picking Spin from the Mesh menu a second time runs it on
what the first one produced. Thirteen bars became 169 that way, and 10,816
vertices in a wheel that wanted 832.

**Still missing at that point:** Spin turned about the object's origin, so
geometry that must orbit a point it does not sit on — gear teeth, a bolt
circle, tyre tread — was out of reach. It has a centre now; see the next entry.

**Spin's centre, and Knife Project after all** (2026-09-21).

- **Spin has a Center**, three fields under a dim *Center* heading in the redo
  panel, X / Y / Z in the axis colours — the column Blender draws, and the one
  the Add operators' Location already uses. It starts at the edited object's
  origin (Blender's `matrix_world` translation, as mirrored), so a spin nobody
  adjusts emits the same line it always did:
  `bpy.ops.mesh.spin(steps=12, angle=6.2832, dupli=False, axis=(0.0, 0.0, 1.0), center=(0, 0, 0))`.
  - The fields are one argument. `LastOperator.python` wrote one keyword per
    parameter, and a centre is `center=(x, y, z)`: three `center_x=` are not
    arguments `mesh.spin` has, and three `center=` are a TypeError. A new
    parameter kind, `component`, is drawn as a field and *composed* — every
    component of a keyword becomes one tuple, emitted once, at the position of
    the first. Keys stay `center.x` / `.y` / `.z`, because the key is the
    row's identity in the panel; duplicate ids make SwiftUI drop rows without
    a word.
  - Measured in 5.2.1: `center`'s soft range is ±10000 (the fields clamp to
    it), and it is a **world** point — a cube at (5,0,0) spun six times with
    `dupli=True` about (7,0,0) left every copy 2.0 from (7,0,0). So moving the
    object after a spin does not move the centre, which is right.
  - Axis is *not* a composed vector as well, tempting as the symmetry is:
    three scrub fields can reach (0,0,0), and Blender refuses that as
    "Invalid/unset axis".
- **Knife Project works** — in the Mesh menu, Cut and Divide ▸ Knife Project,
  which lists the meshes, curves and text objects it can cut with. The drawn
  knife, `knife_tool`, is still modal and still refuses without a window.
  - `knife_project` fails its poll headless ("Expected a view3d region &
    editmesh"). Under `temp_override(window, area, region)` with the startup
    screen's 3D View it polls True and cuts — along that view's
    `perspective_matrix`. That matrix is read-only and nothing headless
    recomputes it: not setting `view_matrix`, not `view3d.view_axis` or
    `view_all` (both FINISHED, matrix unchanged), not `tag_redraw`. A circle
    at (0,0,3) cut a plane at z = 0 around (−8.69, 3.87), on the ray from the
    startup view's eye at (15.04, −6.70, 8.20): nine and a half metres off.
  - `RegionView3D.update()` recomputes it, and with no GPU context it
    **crashes Blender** (`GPU_matrix_frustum_set` ← `view3d_winmatrix_set`).
    `gpu.init()` is the missing piece: it runs the same `WM_init_gpu` the
    first Eevee render runs, and leaves the context current on the main
    thread. After it `update()` works, before and after an Eevee render. On a
    worker thread there is no context (`GPUFrameBuffer()` raises "No active
    GPU context found" — which is how `_blenderkit_knife` checks, since
    `update()` itself would not raise), and desktop Blender's `gpu.init()`
    there aborted the process. Knife Project refuses off the main thread.
  - The view is aimed orthographically along the **cutter's normal** — the
    thin axis of its own bounds, turned by its rotation — pointing at the mesh.
    Turning the cutter is how the cut is aimed, since there is no view to aim.
    Exact: a 32-sided r = 0.5 circle put every new vertex at 0.5 ± 1e-6 on a
    plane and on each face of a cube along X, Y and Z; tilted by (0.4, 0.25,
    0.3) it cut a cube along its own normal to within 2e-5.
  - **The view has to be tight.** The knife snaps to geometry within a few
    pixels. Over a grid 0.02 apart, a 1 m circle with `view_distance` equal to
    its size found 222 of the 232 crossings; twenty times wider, 4; forty
    times, none, and the operator still said FINISHED. At 0.005 of the
    cutter's size it found 232 of 232 (and 432 of 432 under a 10 m circle on a
    0.1 grid), and circles from 1 mm to 1 km came out exact. What lies outside
    the view is still cut.
  - An outline that misses the mesh is FINISHED to Blender and nothing to a
    bpy module, so a cut that changed no vertex, edge or face count raises
    instead. The view and the selection are put back either way. Blender
    leaves the cutter selected; here it was picked from a menu, and left
    selected it goes into the next edit session with the target — where the
    operator then answers "No other selected objects have wire or boundary
    edges" (a cutter already in edit mode is taken out of it first, for the
    same reason).
  - Cut Through is in the redo panel, Blender's one property for it.
  - **Not verified on a device.** Everything above was measured in desktop
    Blender 5.2.1 under `-b --factory-startup`, and
    `scripts/run-redo-blender-check.sh` runs the exact Python the app sends.
    The iPad's bpy has the Metal GPU backend `gpu.init()` needs
    (device-verified for `GPUOffScreen` and Eevee), but Knife Project itself
    has not been run there.

**Modelling with nothing typed into Scripting** (2026-09-21). The 3D View was
asked to build a car, a bike and a dinosaur through the interface alone — every
part from the Add menu, every position and size typed into Object Details, the
way someone would in Blender. It can: **48 parts** went in that way — a car
of 15, a bike of 10 and a dinosaur of 23, 11,696 triangles together — and the
finished scene saved as a `.blend` and rendered. Two defects had to be fixed
first, and neither was visible from anywhere except inside that exercise.

- **The Transform fields never reached Blender.** `PropertiesView` set the
  display cache and then called `session.log(...)`, which appends the Python it
  *would* have run to the Info log and runs nothing. An object typed to
  (0, 0, 3) moved on screen while Blender still had it at the origin: the next
  mirroring pass put it back, and every operator in between acted on the old
  place. They now go through `bridge.run(..., undo:)`, like every other write
  in the editor.
  - One write per drag *sample* would be a Python round trip and an undo step
    per sample, so the write is handed to `BNumberField`'s `commit` closure,
    which fires when the drag ends. That closure already existed for this.
- **A mesh got the RNA browser and nothing else.** On the real backend the
  Object Details sheet for a mesh opened `BlenderDataBrowser`: every property
  Blender has, and no Transform fields, no modifier stack, no material — so a
  part could be dragged but not placed at a number. The condition was inverted,
  and on exactly the backend where it matters: the *shim* got the Properties
  editor and real Blender got the browser. A mesh now gets `PropertiesView`
  with "Every Property" one tap away, the way the camera and light panel
  already worked.
- **Duplicate did not exist** — not in a menu, not on a key. Building out of
  parts means making the same part over and over (four wheels, two mirrors, a
  row of back spikes), and without it every copy was a fresh primitive and nine
  numbers typed again, which was most of what building the car by hand cost.
  More ▸ Duplicate, Shift+D as in Blender. `duplicate_move` leaves the copy
  exactly on the original and selects it, so the next number typed moves the
  copy and not the original: a bike frame tube went from an Add plus seven
  fields to four.

With both fixed, a part costs one Add or one Duplicate plus one to seven typed
fields. Cycles rendered the scene — 50 objects with the camera and light — in
8.1 s at 1920 × 1080 on the M4 GPU. One thing worth knowing before judging a render: the starting scene's
Point light is 1000 W, which over a scene 16 m across renders nearly black —
the models are correct and the light is simply a room light. Object Details
shows a light's Power, and 80000 W lit this one.

**Import and Export, checked one format at a time** (2026-09-21). A sweep of
every feature found the file formats the least trustworthy part of the app,
because nothing had ever run them end to end.

- **Import Model… worked for one format in seven.** It ran through
  `session.submit`, which puts the line on the script thread, and Blender's own
  importers — `wm.obj_import`, `wm.stl_import`, `wm.ply_import`,
  `wm.usd_import`, `wm.alembic_import` — poll for a window. All five answered
  "context is incorrect" and nothing arrived; only glTF worked, because its
  importer is a Python add-on that does not ask. Import now goes through
  `bridge.run`, where the menus run: the main thread, one undo step, and the
  scene mirrored afterwards. It also says what happened rather than nothing.
- **FBX export wrote nothing.** `wm.fbx_export` does not exist in this build —
  and `bpy.ops` resolves lazily, so `hasattr` says it does and the call fails
  only when made. The exporter is the add-on's `export_scene.fbx`.
- **FBX import died on any file with a light in it.** Blender 5.3 removed
  `CyclesLightSettings.cast_shadow` and its own bundled `io_scene_fbx` still
  assigns to it, so the importer raised `AttributeError` halfway through.
  `stage-blender.sh` guards the line as it stages bpy — upstream's bug, in a
  file this app ships. The patch reads the indentation out of the line it is
  replacing and compiles the result before writing it: a first version assumed
  four spaces where upstream had eight and produced a file Python could not
  parse, which is a worse failure than the one being fixed.
- The exporter and importer tables now live together in the bridge
  (`BpySession.exporters` / `.importers`), and `-export all` exports every
  format and reads each one straight back, so a format that writes but cannot
  be read cannot pass. Measured after the fixes: **glTF, OBJ, USD, STL, PLY,
  FBX and Alembic all round-trip.**

**Edit Mesh on a light showed Blender's enum** (2026-09-19). With a Sun
selected, pressing Edit Mesh put this in the banner:

    Toggle Edit Mode  TypeError: Converting py args to operator properties:
                      enum "EDIT" not found in ('OBJECT')

Only a mesh has an edit, sculpt or paint mode, so `mode_set` was handed a mode
the light's enum does not contain and Blender answered in its own terms — which
says nothing about the Sun in the status bar, or about what to do next.

- **`Bpy.setMode` refuses in a sentence**: "Edit Mode works on meshes, and Sun
  is a light. Select a mesh first." The type is named the way a person would
  say it (a light, a camera, an empty, an armature), and the mode names itself,
  so Sculpt Mode says Sculpt Mode. Object mode is never refused — it is the way
  back. Tab is held to the same rule on the way in and left alone on the way
  out.
- **The button is disabled before Blender is asked**, from
  `BKObject.hasEditMode`. It was disabled only when *nothing* was selected,
  which is why a light got through.
- The wording is checked against a real Blender in
  `scripts/run-3dview-blender-check.sh`, with a sun, a camera, a mesh and
  nothing at all active; the Swift side is in the `modeguard` suite.
- **A Mesh-menu operator with a light active took the other road**, and is
  fixed too. `LastOperator.entryPython` wraps its `mode_set` in
  `except: pass` — right for a mode Blender happens to be in already, wrong for
  one the object does not have at all — so Subdivide stayed in object mode and
  then failed its own poll: "context is incorrect", naming neither the light
  nor the operator. The edit-mode half now refuses the same way, with the
  operator's own name: "Bevel works on meshes, and Sun is a light." Adds are
  left alone, because object mode is a mode everything has.
- **The Mesh and Sculpt menus are disabled too**, on the same test as the
  button. With a light selected the row now offers Select, Move, Rotate, Scale,
  Add and Scene, and greys the three that need a mesh.

**Edit mode picked almost nothing** (2026-09-19). Reported as "the edit mesh is
completely broken", and it was: four separate faults, each of them visible.

- **A tap had to land within 18 points of a vertex, vertically.** The tolerance
  was 0.05 in clip space, and clip space is -1…1 across the view whichever way
  round the view is — on a 1193 × 729 point viewport that is 30 points across
  and 18 up, under half a fingertip and a different size in each direction.
  Worse, a tap that hits nothing is a Set click on empty space, which *clears*
  the selection: aiming at a vertex and missing by a finger's width deselected
  everything. `MeshPicker` measures in points, with a radius of 22, and a tap
  that lands on the model but near no corner takes the nearest corner of the
  face it hit rather than throwing the selection away. Empty space still
  clears, which is the gesture Blender gives that meaning.
- **Edge mode did not pick edges.** It found the nearest *vertex* and then
  returned the first edge in the list that touched it — so tapping the middle
  of an edge picked nothing, and tapping a corner picked whichever of the three
  edges there happened to be stored first. It is now the nearest edge by
  distance to the line.
- **A selected edge was not drawn at all.** The overlay tinted selected faces
  and lit selected vertex dots; edges had no pass. In Edge mode a tap that
  worked and a tap that did nothing looked identical, which is most of why the
  mode read as dead. Selected edges are drawn in Blender's orange with a dot at
  each end — the dots are not Blender's, but a one-pixel line is thin to aim a
  finger at.
- **A face selection was half a face.** The viewport draws triangles and
  Blender edits polygons, so picking a quad lit one of its two triangles. The
  pick now takes every triangle of the polygon, through the `trianglePolygons`
  map the mirror already carried. Box select had the same fault and tested each
  triangle's centre; it now tests the polygon's, which is Blender's face dot.

Two more things follow from the same place:

- **Vertices the surface hides are no longer picked.** Vertex dots are drawn
  with the depth test on, so a dot behind the model is not on screen — but the
  picker was happy to choose one, and on a cube the hidden back corner often
  projects nearest the tap. A vertex counts when at least one triangle meeting
  it faces the camera, which is exact for a solid.
- **Edit mode drew eighteen lines on a cube.** The viewport's edge list is
  built from triangles, so every quad contributes a diagonal Blender has no
  edge for. The mirror now records which of them are Blender's
  (`EditTopology.realEdges`), and edit mode draws and picks only those — and a
  tap can no longer select an edge Blender will silently drop.

With nothing selectable, `TransformGizmo.pivot` had nothing to pivot on and
returned nil, so edit mode showed no gizmo either. That needed no fix beyond
these.

`MeshPicker` is in the bridge rather than the renderer, so the choosing is
arithmetic a host suite can run: `scripts/run-meshpick-tests.sh` puts a real
camera and the eight-corner cube the mirror hands over in front of it and taps
at points on an iPad-sized view. `MeshBuilder`'s own cube splits its corners
per face for flat shading; edit mode never sees that one, which the first
version of the suite found out the hard way.

**Render, cameras and lights** (2026-09-18). Rendering used to refuse with
`RuntimeError: Add a camera and set Scene > Camera before rendering` in the
console while the panel still said "No render yet", and its own text promised
the 3D View while it rendered the camera. A camera or a light had no settings
in the app at all: Object Details went straight to the RNA browser, where a
light's power is a row of JSON.

- **The Render panel** (More ▸ Render, `PaintRenderWorkspaces.swift`, with the
  request itself in `RenderRequest.swift` so Blender can be held to it):
  - **Where the picture is taken from** is a control, not an assumption:
    the scene's camera, or the 3D View. The 3D View makes a camera fitted to
    the view's vertical angle, renders through it and removes it in a
    `finally`, so a failed render leaves nothing behind. `run-render-blender-check.sh`
    asks Blender where world points land in that picture and holds it to the
    app's own projection, to within a pixel of 320.
  - **What is missing is said in the panel, with the button that fixes it**:
    no camera offers Add Camera (aimed at the view, as Blender aims one) or
    rendering the 3D View; no light says the image will come out black in
    Cycles and Eevee, and offers Add Light or Solid. Errors from the render
    itself appear there too rather than only in the console.
  - **Cycles renders on the GPU.** Blender starts with
    `compute_device_type` at NONE and `scene.cycles.device` at CPU, so every
    Cycles render in builds 34–37 was a CPU render. The request now turns
    Metal on, refreshes the device list, enables the Metal devices and sets
    the scene to GPU, falling back to the CPU (and saying so) where there is
    none. Measured in the app on this Mac, 1920 × 1080 at Good: **21 s on the
    CPU, 9.3 s on the GPU**; a heavier scene was 38.3 s against 13.1 s. The
    panel shows what it ran on — "Cycles on Apple M4 (GPU - 10 cores)".
    - **The first Cycles render builds its Metal kernels: 275 s, measured.**
      The cache survives relaunches (3.1 s afterwards, fresh launch), and
      lives in the app's own `Library/Caches`, so it is once per install —
      but iOS may purge a Caches folder under storage pressure. The panel
      warns before that first render and offers Eevee, which needs no wait.
      `bl_cycles_kernels_built` remembers that it has happened.
    - Eevee and Workbench draw with the GPU by their nature; neither needs a
      device set.
  - **Samples are a setting.** Blender's default is 4096 Cycles samples, which
    is minutes on a tablet. Draft/Good/Best are 16/128/1024 for Cycles and
    8/64/256 for Eevee, with adaptive sampling on; Good is the default. The
    engines are the three this build has: `CYCLES`, `BLENDER_EEVEE` and
    `BLENDER_WORKBENCH` (there is no `BLENDER_EEVEE_NEXT` here).
  - **Renders are kept**: `Documents/Renders/Render <date>.png`, named so they
    sort and none is overwritten, and the panel says where it went. It used to
    drop a `render-<uuid>.png` into Documents per press.
  - **Blender's own progress shows while it renders.** A `render_stats`
    handler writes each line to a file the panel reads four times a second:
    "Sample 12 of 128 · 1:50 left", with a bar. The two engines word it
    differently and Cycles leads with a clock —
    `Remaining: 03:15.18 | Mem: 5976M | Sample 1/128` — so reading the first
    two numbers in the line, which is what the first version did, filled the
    bar to a fifth on the first sample. `RenderProgress.swift` reads the
    sample count itself, from strings taken off a running render.
  - The elapsed seconds show while it runs, the time it took afterwards, and
    a **Share** button hands the PNG to the system share sheet.
- **Cameras and lights** (`CameraLightPanel.swift`), in Object Details and in
  Properties ▸ Data, where mesh statistics used to be shown for objects with no
  mesh: a camera's type, focal length (with the angle it sees), clipping range,
  Make This the Scene Camera, Aim at This View and Look Through It; a light's
  type, colour, power (or a sun's strength), radius, a spot's cone and blend,
  and an area light's shape and size. Each edit is one assignment on the
  data-block, so it is one undo step.
  - **Look Through Camera** and **Aim Camera at This View** are also in More
    and on the hardware keyboard (0, and ⌃⌥0), Blender's numpad 0 and its
    Align Active Camera to View. Looking through sets the view's position,
    direction and vertical angle from the camera; a viewport wider than the
    frame shows more to the sides.
  - A number field that writes to Blender commits when the drag ends, not per
    sample: a write per sample is a Python call and an undo step per sample,
    and the value read back lags the finger, which made a drag jump.
- **Number fields take a typed number** (`BNumberField`, so everywhere: the
  light and camera panels, Transform, the modifiers, the redo panel). Blender's
  own fields scrub on a drag and take a number on a click; on a tablet, typing
  is often the only way to get an exact value. The unit's reading and writing
  is `NumberFieldUnit` in the bridge, so it is checked without a screen:
  degrees are typed in degrees, a unit or a comma in the text is accepted, and
  nonsense leaves the value alone rather than reading as zero.
  - The field is also an **accessibility element** — adjustable, with the value
    read out and an action that opens typing. It was a drag-scrub only, which
    VoiceOver cannot use at all.
  - A drag ignores a sample that jumps more than 400 points from the last one.
    A finger cannot cross the screen between two frames, and following such a
    jump set a light's power to zero.
- **The Documents folder is in the Files app** (`UIFileSharingEnabled` and
  `LSSupportsOpeningDocumentsInPlace`), so renders, scripts and saved `.blend`
  files can be taken out. Xcode's `INFOPLIST_KEY_UIFileSharingEnabled` never
  reaches the built plist — checked with `plutil` on the product — so that one
  key comes from `Resources/Info.plist`, which XcodeGen writes and Xcode merges
  the generated keys into. Its version keys are `$(CURRENT_PROJECT_VERSION)`
  and `$(MARKETING_VERSION)`, so the file cannot disagree with a push.
- **The Render sheet opens full height.** A 1920 × 1080 render in half a
  sheet is a thumbnail; the panels that are lists still open half-height, with
  the viewport in view behind them.
- **`top` keeps every CPU-time field.** Under a full load `idl` fell below the
  0.1% the line filtered at and disappeared, which moved the fields beside it —
  and made `run-shell-tests.sh` fail only when the Mac was busy.
- **CodeBench's startup scripts no longer ship.** The bundled bpy carries
  `scripts/startup/codebench_*.py`, which printed CodeBench's render messages
  into this app's console and then failed with "No module named
  'codebench_blend_view'" on every render. `stage-blender.sh` excludes them.

**Loop Cut** (2026-09-17) cuts across the *selected* edges rather than the edge
under the pointer: `select_edge_ring_multi` then `subdivide_edgering`, with
Number of Cuts, Smoothness and Interpolation in the panel. Blender's own Loop
Cut and Slide is modal. Without a window, `loopcut_slide` returns CANCELLED and
`loopcut` **crashes Blender** (5.2.1, measured), so never call either. With no
edge selected it says so instead of doing nothing. The simulator's shim says
Loop Cut needs the real module. Shrink/Fatten, Push/Pull and To Sphere work in
both.

**Not implemented:**

| Tool | Why |
|---|---|
| Edge Slide (the drag tool), Rip | Blender runs them from the pointer position. `rip_move` fails its poll without one; `edge_slide` given a value does run, and is Mesh ▸ Edge ▸ Edge Slide with a Factor (2026-09-21) |
| Knife (drawn) | `knife_tool` is modal and fails its poll without a window. Knife Project, which cuts with another object's outline, works — see *Spin's centre, and Knife Project after all* |
| Poly Build | modal, driven by the pointer |

These are not missing because Blender cannot do them, but because Blender does
them by tracking a pointer inside a window it does not have here. Reaching them
means reimplementing the interaction and calling the non-modal operator
underneath, as Loop Cut now does.
