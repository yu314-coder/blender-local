# Blender Local — the app

## November 3, later: right-click and Blender's keys

The user's report: "missing the right key feature and lots of hot keys".
A right-click in the 3D View did nothing — no recogniser asked for the
pointer's second button — and the keys that open a menu in Blender (Shift+A,
Ctrl+A, M, X, Ctrl+E and the pies) had no way in, because a SwiftUI menu
opens only when its button is tapped and no key can tap one.

- **Blender's menus at the pointer** (`PopupMenu.swift`, `ViewportMenus.swift`).
  Drawn by the app in Blender's style — the menu's title, each row's key on
  the right, a submenu opening beside its row when the pointer reaches it,
  Up/Down/Return/Left/Right and Escape — over the window, where the
  right-click was or where the pointer last hovered (the view's middle
  without one). Every row runs an action the app already had, under
  Blender's name for that menu (space_view3d.py, 5.2.1); a row Blender has
  and the app cannot run is left out. A pie is drawn as the list of its
  items.
- **Right-click** opens the mode's context menu: Object
  (`VIEW3D_MT_object_context_menu` — shading, Join, Convert, Set Origin,
  Copy/Paste Objects, the duplicates, Rename Active Object…, Mirror, Snap,
  Parent, Move to Collection, Insert Keyframe, Delete; a camera's Set Active
  Camera first), Edit Mode's Vertex, Edge or Face column
  (`VIEW3D_MT_edit_mesh_context_menu`, rows past a selection count as
  Blender draws them), a curve's and a lattice's, and in Sculpt Mode,
  Vertex Paint and Weight Paint Blender's brush panel (Radius, Strength,
  Weight). UIKit gives a right-click to a context-menu interaction whatever
  the app's pointer settings — a tap recogniser's `.secondary` mask saw
  nothing on this Mac, as the app does not opt in to
  `UIApplicationSupportsIndirectInputEvents` — so the interaction takes it
  and opens Blender's menu in place of the system's. Only the right button
  opens it, as in Blender: the interaction also fires on a long press, so
  `TouchKindWatcher` counts every touch that is not a right-button click —
  a finger, a Pencil, a mouse's or trackpad's left button (a pointer touch
  without `.secondary` in its event's button mask) — and the menu stays
  shut under any of them. Checked on this Mac with real input: the left
  button held 1.5 s over the view opened nothing; a right-click opened the
  Object menu.
- **Blender's keys** (`ViewportKeymap.swift`, one table; blender_default.py's
  3D View, Object Mode and Mesh keymaps): Shift+A Add, Ctrl+A Apply, X
  (asks first) and Delete, Ctrl+P / Alt+P Parent, Ctrl+L Link/Transfer Data,
  M / Shift+M collections, Alt+G/R/S Clear Location/Rotation/Scale,
  Ctrl+C / Ctrl+V Copy/Paste Objects, Shift+S Snap, Z Shading, ` View,
  Ctrl+Tab Mode, Comma Orientation, Shift+Tab Snapping, O Proportional
  Editing, T Toolbar, Ctrl+Space Toggle Maximize Area, Shift+C, Shift+R
  Repeat Last, Shift+G / Shift+L Select Grouped / Linked (Select Similar
  while editing), F2 Rename, F3 Search, F9 Adjust Last Operation, the number
  row's 4/6/8/2/9 orbit and Ctrl+4/6/8/2 pan (Blender's Emulate Numpad,
  15° steps, directions measured in 5.2.1). While editing: E, Alt+E, F, M,
  Alt+M, P, Y, J, X and Delete (the Delete menu), Ctrl+V/E/F, Alt+N,
  Shift+Ctrl+B, Ctrl+T, Alt+J, Shift+N, Shift+Ctrl+N, Alt+S, Shift+Alt+S,
  Shift+Ctrl+Alt+S, Shift+V, Shift+E, Shift+Ctrl+R, Ctrl+X. The menu bar
  draws a row for each key that applies in the mode; the 3D View carries
  the F keys itself, and Blender's macOS ⌘ twin of every Ctrl key
  (`keyconfig_data_oskey_from_ctrl_for_macos`, its exceptions kept, the
  number row left to ⌘1/⌘2's tabs).
- **New operators**, measured in desktop 5.2.1 with the app's context
  (`ViewportMenuOps.swift`): the seven Snap operators fail their poll
  without a 3D View and run under the borrowed one; Clear
  Location/Rotation/Scale, Copy and Paste Objects need none; Set Active
  Object as Camera and Subdivision Set need it. Shift+R repeats the last
  operator with its last arguments (`BpyBridge.repeatable`), which unlike
  the redo panel's outlives the selection changing.
- **Checked in the app**, with the new DEBUG hook `-menu-ops` (open a menu,
  press a chord, run a row, print Blender's state) and `-menu-dump`: every
  menu above prints Blender's rows; Shift+A ▸ Mesh ▸ Cube added a cube;
  Snap ▸ Selection to Cursor moved it to the cursor's (2, 0, 0), Cursor to
  World Origin and Cursor to Selected moved the cursor; Alt+G cleared its
  location; Ctrl+C, Ctrl+V pasted Cube.001; Shift+R added another cube; in
  Edit Mode E took a cube from 8 to 16 vertices and Delete ▸ Faces removed
  the selected faces. With real input on this Mac: a right-click opened the
  Object menu at the pointer and its Duplicate Objects row duplicated the
  Ball; Shift+A opened Add with Mesh's submenu beside it. Host suites names,
  featuretest, objectops and transformops pass; the names scanner allows
  "New Face from Edges" in the context menu's Edge column, Blender's own
  label there.
- **Not yet:** F12 (Render Image needs the Rendering tab to start a render
  on arrival), Shift+right-click's 3D cursor and Ctrl+right-click's Extrude
  to Cursor (the interaction gives no modifier keys), Blender's modal G/R/S
  with the pointer and typed values, the sculpt brush keys, the
  `wm.context_modal_mouse` rows (Adjust Focal Length, Adjust Light Power),
  and Ctrl+0–5 Subdivision Set (the number row is Blender's emulated numpad
  here, as the views were).

## November 3: the timeline without the editors, Eevee's shadow pool, the Scripting tab

Measured on this Mac (Mac16,10) with the iPad build, optimized
(`-configuration Debug SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule`),
the editors' dock shown. Other sessions loaded the Mac through the morning
(load averages 8 to 13, a remote-desktop session and four simulators): the
same build swung from 96 to 68 Smooth between runs, so every change below
was measured A/B in one sitting, and the final runs at load 4.

- **A frame change redrew the 3D View's whole screen and the Properties
  editor.** `LayoutWorkspace` built its orientation key, and
  `PropertiesView` and the Sidebar their Dimensions keys, in their own
  bodies with the frame in them, so every frame of playback or a scrub ran
  those bodies and their `.task`s — the orientation one a call into Blender
  each frame. The frame change itself costs 1 ms (median of 96, worst 6 ms;
  DEBUG `-frame-timing` prints each), and the main thread was busy 283 ms of
  8 s in a time profile; the views were the rest. Now each key is read in a
  view of its own behind the editor (`KeyedRefresh`), and holds the frame
  only when the answer can change with it: the orientation in Local, Normal,
  Gimbal and Parent (`TransformOrientation.followsObject`), the Dimensions
  on the Data tab, the Item tab's numbers on the Item tab. Same sitting,
  `-feature-test-only` (new DEBUG hook) of the timeline's features: the
  scrub 21–25 frames in its second, median 50–67 ms → 43–46 frames, median
  16.7; Play 41–58 → 54–76 frames in two seconds — what the dock-hidden runs
  had, so the editors cost nothing per frame now. Still right: the
  `-transform-ops frame:` check of October's review, a cube keyed from
  rotation Z 0 to 1.2 between frames 1 and 20 in Local, reads Blender's
  axes at 20, 10 and 1 ((0.3624, 0.9320, 0), (0.8511, 0.5250, 0), the
  identity) and the Sidebar the same Dimensions ((4, 2, 2), (2.9211, 2, 2),
  (2, 2, 2)).
- **An Eevee render's memory was mostly its shadow pool.** Blender
  allocates `scene.eevee.shadow_pool_size` up front, 512 MB by default: an
  Eevee render of the startup cube at 480 × 270 took the app from 275 MB
  to a 1,475 MB peak. Peak against pool, in the app: 512 → 1,475 MB, 256 →
  1,221, 128 → 1,094, 64 → 1,015, 32 → 932; desktop 5.2.1 rendering a copy
  of an 82-object scene at 960 × 540: 1,531, 1,280, 1,079, 1,017 MB — every
  picture identical to the 512 one, pixel for pixel. The Render panel now
  holds the pool to its quality for the render (`Quality.eeveeShadowPool`:
  Draft 64, Good 128, Best 256 MB), keeps a smaller one a scene asks for,
  and puts the scene's own back after, in the `finally` that already put
  the camera back. Test All Features' Eevee render (Draft): 1,467 → 1,020
  MB peak. `run-render-blender-check.sh` has five new checks.
- **The Scripting tab read every operator each time it opened.**
  `editor_metadata` walked all 2,498 of `bpy.ops` and read each one's RNA:
  46 ms in desktop 5.2.1, 82 ms of the tab's first frame in the app. The
  operators are kept for the session now and read again only when Blender's
  version or the Python operators' idnames change (a registered operator is
  listed at once); a second read is 1.8 ms. The first read waits for the
  tab's first frame (50 ms on). The tab's longest stall: 336–551 ms →
  177–300 ms; the rest is the web view and the console being made.
- **Full Test All Features, final build, load 4:** 94 and 97 Smooth of 111
  (November 1, a quiet Mac: 96); Eevee's render peak 1,180–1,248 MB (1,655).

Not yet done:
- The scrub in the full run is still 23–26 frames in its second: by then
  the scene holds the earlier features' objects, and the views that still
  follow every frame there were not found (the targeted runs have the
  sphere alone).
- Vertex and Weight Paint strokes on the 64,226-vertex sphere keep their
  p95 of 50–67 ms: each chunk takes the stroke back and replays all of it
  (Blender's one undo step and its own spacing), up to 51 ms a chunk.
- The Scripting tab's web view and console are made on its first visit.
- After an Eevee render about 270 MB stays (Blender's GPU module and
  shaders).

Testing note: an `-eval64` script edits the app's working scene, which it
autosaves into `Documents/autosave.blend` and reopens at launch. One such
script replaced it this morning; it came back from a Time Machine local
snapshot. Scene-changing launches now go through a wrapper that copies
autosave.blend aside first and back after.

## November 1: Blender's layout — the toolbar, one mode menu, and the editors beside the view

The user said the app's real problem might be that it is hard to use, so the
interface was walked at an iPad's own sizes for the first time. Every round
before held each button to Blender's result; none asked whether a finger could
find it. The walk ran in an iPad Air 11-inch simulator (820 × 1180 points, the
smallest common iPad held upright), with a new DEBUG hook, `-ui-audit <tag>`,
that prints every labelled element's frame 7 s after launch and marks it OFF
(any of it outside the window) or SMALL (a side under Apple's 44 points). In a
simulator SwiftUI builds no accessibility tree until something asks for one,
so the hook turns on automation mode (`_AXSSetAutomationEnabled`) first.
Screenshots and every audit are in
`/Volumes/D/OfflinAi/blenderlocal-release/ui-walk-2026-11-01/`.

What it found, before the change:

- **The 3D View's tool row did not fit any iPad.** It was 1,774 points wide in
  Object Mode and 2,507 in Edit Mode. Upright, nine controls lay past the edge
  — Snap, Proportional Editing, Select, Add, Mesh, the mode menu (titled
  Sculpt), the Outliner, Edit Mode and More — and in Edit Mode eighteen,
  among them Extrude, Bevel, Inset, Subdivide, Loop Cut, Knife and the Mesh
  menu. The row scrolled, but nothing on screen said so: no indicator, no fade.
  Because it was wider than any iPad, Edit Mode and More were off screen at
  launch on a 13-inch iPad in landscape too.
- **The Outliner and Properties were sheets inside More.** Opened, a sheet
  dimmed the 3D View, blocked it, and covered the object (upright, the half
  sheet sat over the model), so a value could not be watched while it changed.
- **Targets under a finger's size**: the File menu's title (20 × 14, the only
  way to Save and Open), Undo and Redo (36 × 32), Vertex, Edge and Face
  (30 × 28), the Outliner's rows (about 20 tall).
- **Snap's icon drew nothing**: "magnet" is not an SF Symbol. Tool Settings'
  Snap actions had the same blank icon.
- Fine as they were: the gestures (one finger orbits, two pan, pinch zooms, a
  tap selects) and the Scripting tab.

The user chose Blender's own layout over a row that wraps:

- **The toolbar** (`toolShelf`) runs down the left edge, as Blender's does:
  Blender's four select tools under one button, Cursor, Move, Rotate, Scale
  and Measure, and in a mesh's Edit Mode Extrude, Inset Faces, Bevel,
  Subdivide, Loop Cut and Knife. Each is an icon with its name under it, 56
  points square. It runs the full height, beside the editors too when they are
  underneath, because an upright iPad's view alone is too short for Edit
  Mode's twelve buttons; it scrolls on a window shorter still.
- **The header** (`headerRow`) is Blender's: the mode menu first, then Select,
  Add and Mesh (in Edit Mode, Vertex, Edge and Face, now 44 × 40, then Select
  and Mesh; Sculpt Mode and the paint modes keep their brush headers), then at
  the far end the Orientation, the Pivot Point, Snap and Proportional Editing
  as icons, as Blender's header draws them, the mirror row in the modes that
  have it, the editors' button and More (44 × 44). Below 1,100 points the
  menus' titles drop their icons, Orientation shows its icon alone and the
  mirror row folds into one Mirror menu. The mode menu, the editors' button
  and More are pinned at the two ends; only what lies between scrolls, and
  when it runs past the edge a fade and a chevron say so until it is scrolled
  to its end (iOS 18 and later can tell; iOS 17 keeps the fade while the
  content is wider). In Sculpt Mode and the paint modes the Orientation, Pivot
  Point, Snap and Proportional Editing go, as they go from Blender's header
  there: Blender's own Sculpt Mode header (the real module, its brush
  settings, Mask, Face Sets and Remesh) pushed Snap, Proportional Editing, the
  mirror row, the editors' button and More past the edge of the Mac's
  1,194-point iPad window.
- **One mode menu** (`modeMenu`): Object Mode, Edit Mode, Sculpt Mode, Vertex
  Paint and Weight Paint (Blender's module only) and Texture Paint, the
  current one ticked, under the current mode's name. Before, Edit Mode was a
  button at the row's far end, Sculpt Mode and the paint modes were rows of a
  menu titled Sculpt, and leaving Edit Mode was a button in a chip. The names
  are `InteractionMode`'s, Blender's.
- **The editors' dock** (`editorsDock`): the Outliner over the Properties
  editor beside the 3D View when the window is wider than tall (at most 360
  points, the Outliner a third of the column, up to 260), side by side under it
  when it is taller (42% of the height, the Outliner 300 wide). Open by default
  and remembered (`bl_editors_shown`); the header's button (Outliner and
  Properties) shows and hides it, and More ▸ Properties, the keyboard's
  Outliner and Properties keys and `-panel Outliner|Properties` show it. The
  Properties editor's content is the sheet's as it was (`propertiesEditor`),
  the Data API one push below it. Render, Tool Settings, the Timeline panel and
  Image to 3D Model stay sheets: they are tasks, not editors.
- Snap's icon is `dot.squareshape.split.2x2`, here and in Tool Settings.

After, measured the same way (the simulator, the stand-in module): upright
iPad Air 11-inch, Object, Edit and Sculpt Mode, the header's right edge at
816 of 820 points and nothing of the header or toolbar off screen (the only
OFF elements are the Properties editor's rows below its fold, which scroll);
Edit Mode at the iPad mini's width (744, through a new DEBUG hook,
`-ui-frame <w>x<h>`, which lays the interface out in a frame of that size: the
simulator here cannot be rotated from the command line) 740 of 744; Edit Mode
in a landscape frame (820 × 600) nothing off screen. `tests/names/scan.py` and
`run-names-tests.sh` pass; `-ui-audit` and `-ui-frame` are in the release
scan's hooks.

Not yet done: the real module's Sculpt Mode, Vertex Paint and Weight Paint
headers (Blender's own, absent in the simulator) and the dock's cost while a
stroke mirrors every frame were not measured — both need the app on this Mac
or the iPad. The Properties editor's own rows and the Outliner's are still
under 44 points.

The top bar, after the merge with the gear (next section): File's title is a
44-point target (it was its text's own 20 × 14, `Menu(label:)` in
`FileMenu`), and Undo, Redo and the gear are 44 × 44 (36 × 32). Measured in
the simulator: upright, the gear ends at 808 of 820 points; at the iPad mini's
744, at 732. The gear's frame timing (`addPresentedHandler`) is left out of
simulator builds, whose drawables have no presented handler; it broke them.

## November 1: Preferences in the top bar, and Test All Features

The user's word was that the app is hard to use, and the ask a test run they
can press on their own iPad that tries every feature and says which are smooth
and which are not. So there is a gear at the trailing end of the top bar now
(`gearshape`, its accessibility label "Preferences"), the last thing on the
bar with its size fixed and a layout priority above the rest, so a bar too
narrow for everything squeezes the menus and the run pill before it; File ▸
Preferences… still opens the same sheet (the top bar presents it, and the
File menu's row sets the top bar's flag). Preferences has a Testing section
with two buttons, each with one line of what it does: **Test All Features**
(new, below) and **Self-Test** (the October 30 checks, until now behind seven
taps on the Version row, which is a plain row again). Both are app-only
features and keep their own names; "Preferences" is Blender's. The gear is
the whole change to the top bar: its layout is being reviewed separately.

### What Test All Features does

Every feature in the inventory below, one after another, through the Swift
its control calls — `bridge.perform(LastOperator…)` for the Add and Mesh
rows and the redo panel, `bridge.run(…)` with the undo name the row uses,
the row's own function where it lives in the 3D View's private state
(`choose`, `enterPaintMode`, Viewport Shading and X-Ray, handed over by
`LayoutWorkspace.featureTestDoor` while the Layout tab is on screen), and the
3D View's gesture handler for taps, drags and strokes
(`MetalViewportView.Coordinator`: `tap(at:modifiers:)`, which `handleTap`
now calls too; the gizmo's own `beginGizmo`/`updateGizmo`/`endGizmo`;
`sculptDrag` for Sculpt, Vertex Paint and Weight Paint; the Texture Paint
stroke's begin/move/end; `loopCutTap`, `knifeTap` and the Knife's Confirm;
`cursorTap`; the ruler's drag; `beginRegion`/`extendRegion`/`finishRegion`).
Nothing is a second Python version of a feature: what is measured is what a
tap costs, the mirror into the 3D View and the next drawn frame included.

Each feature is measured three ways:

- **Time**: from the call to the first frame the 3D View began after it
  returned (`FrameClock`, fed by `ViewportRenderer.draw(in:)`), or to the end
  of a long job.
- **Stall**: the longest the main thread went without answering. A
  background thread posts to the main queue every 16 ms and keeps the longest
  wait (`MainThreadWatchdog`, Release-safe, asleep when no test runs); a
  synchronous call's own length counts too, since it holds the main thread
  from start to end and the watchdog can miss one under 16 ms.
- **Frames**, for the continuous interactions (orbit, pan, zoom, the three
  gizmo drags, the ruler, Select Box, the four strokes, Play and a scrub):
  the input synthesized over 1 to 2 s at 60 Hz, paced by the clock as a
  finger's coalesced touches are, and the gaps between the frames drawn
  meanwhile — the drawables' presented times where the system reported most
  of them, else when each frame began (the report says which) — as median,
  95th percentile and worst. The detail adds the longest single call and
  what a frame's encoding cost the main thread.

Peak memory is the footprint's highest while each feature ran (sampled on
the watchdog's thread, `proc_pid_rusage` as the Self-Test reads it), and the
header has the app's lifetime peak, before and after.

The rating (`FeatureTest.rate`, held to by tests/featuretest):

| Rating | Stall | Continuous: 95th percentile frame |
|---|---|---|
| Smooth | under 100 ms | 17 ms or less (60 per second) |
| OK | under 250 ms | 33 ms or less (two 60 Hz frames, read as up to 33.4 ms) |
| Slow | 250 ms to 1 s (Apple's hang) | past 33 ms |
| Freeze | past 1 s | — |
| Failed | an error, a refusal or a banner where none was expected | — |

A continuous interaction takes the worse of its two. A long job (Run Script,
the render, Image to 3D, save, export, import, open, the recovery write) is
held to its stall, not its time, which is reported; one of a second or more
that showed no progress meanwhile is OK at best.

The drags and strokes work on a realistic mesh: Add ▸ UV Sphere adjusted in
its redo panel to 288 segments and 224 rings, 64,226 vertices.

**The user's work** is kept as the Self-Test keeps it, by the Self-Test's own
machinery (`_blenderkit_featuretest.begin`/`end`, which call
`_blenderkit_selftest`'s `fingerprint` and scratch scene `_Run`, now named per
run): the recovery file is written first, the scene saved to its own copy
and fingerprinted, Blender's startup file opened as File ▸ New opens it, and
after the last feature the copy opened again and compared — the result is a
note in the report's header and a line on the sheet. Unlike the Self-Test's,
the scratch scene is mirrored into the 3D View, since that is what is being
measured. The recovery file is not written while the test runs
(`BpySession.featureTestOpen`), so a run that takes the app down leaves the
next launch the scene as it was. Before the scene is opened again the
history is cut back to the run's own step (`_blenderkit_undo.back_to`, new),
so no feature's scene stays in it: measured on the Mac, after the run the
history is one step, the user's scene. With painted pixels unsaved, or a
script or stroke running, the run refuses in one line and touches nothing;
the sheet says before Run that Undo history ends there. Files the test makes
go to the temporary folder (`exportModel` takes a folder now; the menu's is
still Documents) and are removed; the copies Add ▸ Image ▸ Reference keeps of
its picture are removed at the end.

**The sheet** (`FeatureTestSheet`): before Run, what it does and how long
(about a minute on the Mac; "about three minutes" is said, for an iPad),
the undo notice, and an **Include Cycles** switch, off by default — Cycles'
first GPU render builds its Metal kernels for minutes. During the run,
"Feature n of N: name" and each result as it ends; at the end the summary,
the scene's line, then Slow, Freeze and Failed first, then OK, then Smooth,
the not-tested list with reasons, Copy Report and Share. The report is
`Documents/Self-Test/feature-test-<date-time>.txt`: the Self-Test's header
(device, iOS, RAM, the app's version and build, Blender, start, total,
counts, memory, notes, the thresholds), one line per feature (rating, stall,
time, frames as median/p95/worst, peak, name, detail), not tested, summary.
It is written as the features go, the one running as `RUNNING …`, so a run
that takes the app down leaves it as the last line and the sheet names it
the next time it opens (`SelfTest.latestReport`, which now takes a prefix).

DEBUG builds take `-feature-test` (Preferences opened at launch, Test All
Features pressed, Run pressed; each result printed as `[bk-featuretest] …`
and `[bk-featuretest] ended: <summary> · <scene> · <report path>`), and
`-feature-test-cycles` to switch Cycles on. Both are in `scripts/scan-app.py`'s
hooks: the release scan stays clean and the control scan sees them.

Files: `Sources/BlenderLocalBridge/FeatureTest.swift` (inventory, rating,
report), `FeatureTiming.swift` (watchdog, frame clock, footprint),
`Sources/BlenderLocalUI/Chrome/FeatureTestRunner.swift` (the features),
`FeatureTestSheet.swift`, `Resources/python/site/_blenderkit_featuretest.py`
(new); `PreferencesSheet.swift`, `TopBar.swift`, `TopBarMenus.swift`,
`SelfTestSheet.swift`, `SelfTest.swift`, `BpyRuntime.swift`,
`SceneSnapshot.swift`, `ViewportRenderer.swift`, `MetalViewportView.swift`,
`TexturePaintInput.swift`, `LayoutWorkspace.swift` (one `.task` line and an
extension at the end, nothing in the tool row or the panel sheet),
`_blenderkit_selftest.py`, `_blenderkit_undo.py`, `scripts/scan-app.py`,
`scripts/run-featuretest-tests.sh` and `tests/featuretest/main.swift` (new).

### The inventory

`FeatureTest.inventory`, in the order the run takes it: 122 entries, 112
run by default (Shade Auto Smooth among them, listed as not tested at run time
where Blender has no Essentials library), Cycles on its switch, and 9 not
tested. tests/featuretest fails if an entry
neither runs nor says why, or if the runner has no case for one that runs.

| Area | Features | Through |
|---|---|---|
| Workspaces | Scripting tab, Layout tab | the top bar's tab binding |
| File | File ▸ New ▸ General | `bridge.run(Bpy.newScene)` |
| Add | Mesh ▸ Plane … Monkey (ten rows), Curve ▸ Bézier, Text, Empty ▸ Plain Axes, Light ▸ Point, Camera, Lattice, Image ▸ Reference (a picture drawn in code) | `bridge.perform(LastOperator.add…)`, `bridge.add(…)`, `bridge.addReferenceImage` |
| Select / Object | Select ▸ All (Object Mode), Object ▸ Delete | `SelectMenu.Command.action`, `Bpy.deleteSelection` |
| Adjust Last Operation | Add UV Sphere's Segments and Rings (makes the 64,226-vertex sphere) | `bridge.readjust` |
| View | Frame All; Orbit, Pan, Zoom (one finger, two fingers, a pinch, as their handlers change the camera); Viewport Shading ▸ Wireframe, Material Preview, Solid; Toggle X-Ray; Perspective/Orthographic | the camera's own methods, the menu rows' state |
| Select / Tools | Tweak: a tap on an object; Move, Rotate, Scale (gizmo drags); Cursor (a tap); Measure (a drag) | the gesture handler |
| Undo | Undo, Redo | `session.performUndo` / `performRedo` |
| Properties | Object ▸ Location X; Material ▸ Base Color; Modifiers ▸ Add Modifier ▸ Subdivision Surface, Levels Viewport, Apply; Constraints ▸ Copy Location; Camera ▸ Focal Length; Light ▸ Power | `TransformFieldDrag`, `Bpy.setMaterial`, `Bpy.addModifierRow`, `Bpy.modifierEdit`, `ModifierRowAction.apply`, `ConstraintsBpy.add`, `Bpy.setObjectData` |
| Object | Shade Smooth, Shade Flat, Shade Auto Smooth, Duplicate Objects, Set Origin ▸ Origin to Geometry, Apply ▸ Scale, Show/Hide ▸ Hide Selected and Show Hidden Objects, Snap ▸ Cursor to Selected, Parent ▸ Object, Clear Parent, Join, Convert ▸ Mesh, Collection ▸ Move to Collection ▸ New Collection; View ▸ Local View ▸ Toggle Local View | the rows' bridge calls |
| Outliner | a tap on a row, Hide in Viewport, Rename | `bridge.select`, `Bpy.setHidden`, `Bpy.rename` |
| Edit Mode | Edit Mode and back on the large sphere; Mesh Select Mode ▸ Edge, Face, Vertex; Select ▸ All, None, Invert, More, Linked; Tweak: a tap on a vertex; Select Box | `Bpy.setMode`, `Bpy.setSelectMode`, the Select rows, the gesture handler |
| Mesh | Subdivide, Extrude Region and Shrink/Fatten, Inset Faces, Bevel, Merge by Distance, Delete ▸ Vertices; Loop Cut (two taps); Knife (two taps and Confirm) | `LastOperator.mesh`, `loopCutTap`, `knifeTap`, `CutToolActions.knifeDone` |
| Paint | Vertex Paint and a stroke, Weight Paint and a stroke, Texture Paint (adds UVs and an image) and a stroke | `enterPaintMode`, `choose(.paintDraw)` and the 3D View's setup, `sculptDrag`, the Texture Paint stroke |
| Sculpt | Sculpt Mode, a Draw stroke, Mask ▸ Fill Mask, Voxel Remesh, Object Mode back | `choose(.sculptDraw)`, `sculptDrag`, `SculptBpy` |
| Timeline | Insert Keyframe, Play (2 s), a scrub | a `TimelineDriver` bound as the dock binds its own, the dock's `PlaybackTicker` |
| Scripting | Text Editor: Run Script (adds 20 cubes on the script thread), Python Console: a line, Console: a shell command (`ls`), Operator Search: Run | `session.runScript`, `session.runConsole`, `OperatorCatalogue.runCommand` |
| Render | Render ▸ Render Image (EEVEE, Draft, 480 × 270, the scene camera); Cycles on its switch (160 × 90) | the Render panel's `RenderRequest` through `session.runScript` |
| Image to 3D | Add ▸ Image to 3D Model (Relief), on a picture drawn in code | `ImageToModelImport.prepare` and `createRelief` |
| File | External Data ▸ Pack Resources; the recovery file (to a file of the test's); Save; Export ▸ glTF 2.0; Import ▸ glTF 2.0 (the export read back); Open… | `session.submit`, `BackendHistoryPython.autosave`, `saveDocument`, `exportModel`, `importPython`, `openDocument` |

Not tested, each with why (the report and the sheet list them):

- Viewport Shading ▸ Rendered: greyed out in this build.
- Render Image with Cycles, unless switched on: its first GPU render builds
  the Metal kernels for minutes.
- Add ▸ Image to 3D Model (Full 3D): TripoSG's 7.95 GB download and minutes
  per model; Relief is tested instead.
- Object ▸ Shade Auto Smooth, at run time when Blender has no Essentials
  library (the bundled bpy has none, so on this Mac and the iPad it is
  greyed out and listed).
- File ▸ Open Recent and Revert: they open the user's own files; Open is
  tested on the test's own copy.
- File ▸ Share Saved File… and the Files app: system sheets.
- The Outliner, Properties, Tool Settings and Render panels opening: each is
  a sheet, and none can open over the test's own sheet; the commands their
  controls send are tested.
- Shader Editor, UV Editor, Compositor and Geometry Nodes editor: not
  reachable in this build (the top bar has only the Scripting and Layout
  tabs).
- Edit Mode on curves and lattices (control points): their point drags are
  their own gesture, not timed in this version.
- Apple Pencil pressure, hover and the barrel double-tap: code cannot make a
  Pencil's touches.
- Keyboard shortcuts: each runs the function of the row tested.

### Measured on this Mac

In the app, Designed for iPad (Mac16,10, 24 GB; Debug build, the bundled bpy,
which reports itself as 5.3.0 Alpha; the container's own recovery file, one
object in Vertex Paint), through `-feature-test`, five runs. The last, with
the code as it is here: 111 run in 57.4 s — 42 Smooth, 48 OK, 19 Slow, 2
Freeze, no Failed — and 11 not tested; the scene came back ("1 object, 1,106
vertices, as before the test"); footprint 277 MB before, 832 MB after, peak
1,667 MB (EEVEE and Image to 3D; `footprint -p` read the same peak). The
frame times of that run are as drawn (the system reported few presented
times); the run before it had presented times for every drag, and the same
ratings except Rotate and Scale (OK there, p95 33.3 ms) and the scrub (Slow
there): those three sit on the 33 ms line. Worst first:

| Rating | Stall | Time | Frames (median/p95/worst) | Feature |
|---|---:|---:|---|---|
| Freeze | 3067 ms | 3.07 s |  | Adjust Last Operation: Add UV Sphere's Segments and Rings |
| Freeze | 2082 ms | 3.59 s |  | Texture Paint: a Brush stroke |
| Slow | 809 ms | 0.84 s |  | Measure (a drag makes a ruler) |
| Slow | 375 ms | 0.41 s |  | Vertex Paint |
| Slow | 344 ms | 0.37 s |  | Object ▸ Duplicate Objects |
| Slow | 344 ms | 0.37 s |  | Mask ▸ Fill Mask |
| Slow | 334 ms | 0.35 s |  | Sculpt Mode |
| Slow | 326 ms | 0.39 s |  | Scripting tab |
| Slow | 309 ms | 0.61 s |  | Edit Mode, on the large sphere |
| Slow | 293 ms | 0.35 s |  | Weight Paint |
| Slow | 268 ms | 1.03 s | 24.8/49.8/280.2 ms (33) | Select Box (a drag) |
| Slow | 255 ms | 0.27 s |  | Object ▸ Apply ▸ Scale |
| Slow | 208 ms | 1.74 s | 16.7/200.1/244.0 ms (43) | Sculpt: a Draw stroke |
| Slow | 128 ms | 1.17 s | 24.8/47.0/176.6 ms (40) | Scale (a drag of the gizmo) |
| Slow | 122 ms | 1.13 s | 20.0/43.7/129.8 ms (50) | Rotate (a drag of the gizmo) |
| Slow | 80 ms | 1.63 s | 16.7/50.1/111.2 ms (68) | Weight Paint: a Brush stroke |
| Slow | 75 ms | 1.58 s | 16.7/66.7/112.4 ms (64) | Vertex Paint: a Brush stroke |
| Slow | 37 ms | 1.51 s | 36.8/67.8/84.7 ms (39) | Zoom (a pinch) |
| Slow | 29 ms | 1.56 s | 31.7/75.3/84.4 ms (43) | Pan (a two-finger drag) |
| Slow | 28 ms | 1.51 s | 32.4/67.8/77.6 ms (42) | Orbit (a one-finger drag) |
| Slow | 25 ms | 1.03 s | 21.1/33.4/51.7 ms (51) | Timeline: a scrub of the playhead |
| OK | 244 ms | 0.27 s |  | Object ▸ Set Origin ▸ Origin to Geometry |
| OK | 243 ms | 0.27 s |  | File ▸ Import ▸ glTF 2.0 (.glb/.gltf) |
| OK | 236 ms | 0.26 s |  | Voxel Remesh |
| OK | 207 ms | 0.22 s |  | File ▸ Export ▸ glTF 2.0 (.glb/.gltf) |
| OK | 190 ms | 0.21 s |  | Cursor (a tap places the 3D cursor) |
| OK | 175 ms | 0.23 s |  | Texture Paint (adds UVs and an image to paint) |
| OK | 161 ms | 0.16 s |  | Mesh Select Mode ▸ Edge |
| OK | 145 ms | 0.18 s |  | Knife (two taps, then Confirm) |
| OK | 144 ms | 0.17 s |  | View ▸ Local View ▸ Toggle Local View |
| OK | 139 ms | 0.16 s |  | Object Mode from Edit Mode, on the large sphere |
| OK | 134 ms | 0.15 s |  | Properties ▸ Object ▸ Location X |
| OK | 134 ms | 0.16 s |  | Loop Cut (a tap shows the ring, a tap cuts) |
| OK | 131 ms | 0.15 s |  | Properties ▸ Modifiers ▸ Add Modifier ▸ Subdivision Surface |
| OK | 128 ms | 0.15 s |  | Object ▸ Parent ▸ Clear Parent |
| OK | 128 ms | 0.15 s |  | Object ▸ Collection ▸ Move to Collection ▸ New Collection |
| OK | 128 ms | 0.15 s |  | Mesh ▸ Merge by Distance |
| OK | 127 ms | 0.14 s |  | Object ▸ Convert ▸ Mesh |
| OK | 127 ms | 0.13 s |  | Mesh ▸ Subdivide |
| OK | 127 ms | 0.15 s |  | Select ▸ More/Less ▸ More |
| OK | 124 ms | 0.13 s |  | Redo |
| OK | 124 ms | 0.14 s |  | Modifiers: Levels Viewport |
| OK | 124 ms | 0.14 s |  | Properties ▸ Light ▸ Power |
| OK | 124 ms | 0.15 s |  | Mesh ▸ Bevel |
| OK | 124 ms | 0.15 s |  | Mesh ▸ Delete ▸ Vertices |
| OK | 123 ms | 0.14 s |  | Object ▸ Join |
| OK | 122 ms | 0.14 s |  | Properties ▸ Camera ▸ Focal Length |
| OK | 122 ms | 0.16 s |  | Mesh ▸ Inset Faces |
| OK | 122 ms | 0.13 s |  | Select ▸ Select Linked ▸ Linked |
| OK | 121 ms | 0.14 s |  | Properties ▸ Material ▸ Base Color |
| OK | 119 ms | 0.13 s |  | Undo |
| OK | 119 ms | 0.14 s |  | Object ▸ Snap ▸ Cursor to Selected |
| OK | 119 ms | 0.12 s |  | Object ▸ Parent ▸ Object |
| OK | 119 ms | 0.13 s |  | Mesh ▸ Extrude Region and Shrink/Fatten |
| OK | 118 ms | 0.14 s |  | Modifiers: Apply |
| OK | 118 ms | 0.14 s |  | Select ▸ None |
| OK | 118 ms | 0.14 s |  | Select ▸ Invert |
| OK | 117 ms | 1.15 s | 21.4/33.3/144.7 ms (57) | Move (a drag of the gizmo) |
| OK | 117 ms | 0.14 s |  | Properties ▸ Constraints ▸ Add Object Constraint ▸ Copy Location |
| OK | 117 ms | 0.14 s |  | Mesh Select Mode ▸ Vertex |
| OK | 117 ms | 0.14 s |  | Select ▸ All (Edit Mode) |
| OK | 115 ms | 0.15 s |  | Outliner: Rename |
| OK | 115 ms | 0.14 s |  | Mesh Select Mode ▸ Face |
| OK | 114 ms | 0.12 s |  | Add ▸ Mesh ▸ Plane |
| OK | 114 ms | 0.11 s |  | Object ▸ Show/Hide ▸ Show Hidden Objects |
| OK | 113 ms | 0.14 s |  | Outliner: Hide in Viewport |
| OK | 106 ms | 0.13 s |  | Object ▸ Shade Flat |
| OK | 102 ms | 6.99 s |  | Add ▸ Image to 3D Model (Relief) |
| OK | 19 ms | 2.00 s | 16.7/29.9/36.9 ms (114) | Timeline: Play |
| Smooth | 97 ms | 0.12 s |  | Object ▸ Shade Smooth |
| Smooth | 93 ms | 0.12 s |  | File ▸ Open… |
| Smooth | 46 ms | 0.15 s |  | Console: a shell command |
| Smooth | 42 ms | 0.18 s |  | Python Console: a line |
| Smooth | 42 ms | 0.45 s |  | Render ▸ Render Image (EEVEE) |
| Smooth | 40 ms | 0.06 s |  | File ▸ External Data ▸ Pack Resources |
| Smooth | 39 ms | 0.19 s |  | Text Editor: Run Script |
| Smooth | 38 ms | 0.06 s |  | Timeline: Insert Keyframe |
| Smooth | 29 ms | 0.03 s |  | Layout tab |
| Smooth | 29 ms | 0.06 s |  | Object Mode from Sculpt Mode |
| Smooth | 23 ms | 0.04 s |  | Operator Search: Run |
| Smooth | 22 ms | 0.03 s |  | Add ▸ Image ▸ Reference |
| Smooth | 22 ms | 0.05 s |  | Tweak: a tap on an object |
| Smooth | 19 ms | 0.04 s |  | Add ▸ Mesh ▸ UV Sphere |
| Smooth | 19 ms | 0.05 s |  | Add ▸ Mesh ▸ Torus |
| Smooth | 18 ms | 0.04 s |  | Add ▸ Curve ▸ Bézier |
| Smooth | 17 ms | 0.04 s |  | Add ▸ Text |
| Smooth | 16 ms | 0.05 s |  | Add ▸ Camera |
| Smooth | 12 ms | 0.02 s |  | Add ▸ Light ▸ Point |
| Smooth | 11 ms | 0.02 s |  | Add ▸ Mesh ▸ Cone |
| Smooth | 11 ms | 0.05 s |  | Add ▸ Mesh ▸ Monkey |
| Smooth | 11 ms | 0.04 s |  | Add ▸ Lattice |
| Smooth | 11 ms | 0.03 s |  | Select ▸ All (Object Mode) |
| Smooth | 11 ms | 0.02 s |  | View ▸ Frame All |
| Smooth | 10 ms | 0.02 s |  | Add ▸ Empty ▸ Plain Axes |
| Smooth | 9 ms | 0.02 s |  | File ▸ New ▸ General |
| Smooth | 9 ms | 0.02 s |  | Add ▸ Mesh ▸ Grid |
| Smooth | 8 ms | 0.01 s |  | Add ▸ Mesh ▸ Cube |
| Smooth | 8 ms | 0.03 s |  | Object ▸ Show/Hide ▸ Hide Selected |
| Smooth | 8 ms | 0.02 s |  | File ▸ Save |
| Smooth | 7 ms | 0.02 s |  | Add ▸ Mesh ▸ Ico Sphere |
| Smooth | 7 ms | 0.02 s |  | Add ▸ Mesh ▸ Cylinder |
| Smooth | 6 ms | 0.02 s |  | View ▸ Perspective/Orthographic |
| Smooth | 5 ms | 0.02 s |  | Add ▸ Mesh ▸ Circle |
| Smooth | 3 ms | 0.02 s |  | Object ▸ Delete |
| Smooth | 3 ms | 0.02 s |  | The recovery file (autosave), as the app writes it |
| Smooth | 1 ms | 0.02 s |  | Toggle X-Ray |
| Smooth | 1 ms | 0.02 s |  | Outliner: a tap on a row |
| Smooth | 0 ms | 0.02 s |  | Viewport Shading ▸ Wireframe |
| Smooth | 0 ms | 0.02 s |  | Viewport Shading ▸ Material Preview |
| Smooth | 0 ms | 0.02 s |  | Viewport Shading ▸ Solid |
| Smooth | 0 ms | 0.02 s |  | Tweak: a tap on a vertex |

What the numbers say about why the app feels hard to use:

- **Every command pays for re-reading the heaviest mesh in the scene.** With
  the 64,226-vertex sphere visible, Select ▸ None on an 8-vertex cube in Edit
  Mode stalls 118 ms, and the report's detail puts 110 to 130 ms of almost
  every such command in the mirror pass (Blender's scene read back into the
  3D View's); the undo push after it is 1 to 2 ms (the `[bk-undo]` lines).
  Before the sphere existed the same kinds of command took 5 to 20 ms; with
  it hidden (Hide Selected) 8 ms; after Voxel Remesh took it to 2,466
  vertices, Insert Keyframe took 38 ms. So most of the 48 OK ratings are OK
  rather than Smooth only because of a mesh the command never touched, and
  on an iPad the pass is slower still.
- **Orbit, pan and zoom drop to about 20 to 30 frames a second** on that
  sphere (median 32 to 50 ms over the runs, p95 68 to 75 ms), while the main
  thread answers within 30 ms, the calls take no time and a frame's encoding
  is 0.1 ms; a gizmo drag on the same sphere draws at a median of 17 to 21
  ms. The camera is the root view's state, so each step of an orbit
  re-evaluates the views under it; that is the likely cost, not the drawing
  (not yet proved).
- **Texture Paint's stroke froze** on the sphere: one call of it took 2.1 s
  and the 3D View drew no frame in the stroke's 3.6 s. Which call is not yet
  split out; the stroke's setup (the surface and the seams of every
  triangle) and its write into Blender at the lift are the candidates.
- **Measure froze the view for 0.8 s** in one call of a 0.75 s drag, most
  likely its start, where the ruler's snapping targets are built from every
  vertex, edge and face.
- **Adjust Last Operation making the sphere took 3.1 s**, 230 ms of it the
  mirror; Edit Mode, Sculpt Mode, Vertex and Weight Paint each 290 to 375 ms
  on it; a Draw stroke's chunks 183 ms each at the median (frames p95 200
  ms); Duplicate Objects 344 ms.

Two smaller things the runs showed: File ▸ Open records its undo step as
"Run Script" (`openDocument` goes through `submit`, which names a step by
whether the source has a newline, and the app's load has several lines);
and the console's `ls` printed nothing at all, neither to the console's
record nor to the terminal.

Also measured: `-self-test` through its new way in (Preferences, the
Self-Test button) ran 40 of 40 in 8.9 s. The Release build for Designed for
iPad builds, launches and opens the recovery file (280 MB); the release
content scan is clean and the control scan sees both new hooks. The
container's three saved scenes kept their checksums; `autosave.blend` was
rewritten by each run's first write and holds the same fingerprint as before
(read in sandboxed desktop Blender); the reports were moved to the Trash.
The app's own history clean-up (`_blenderkit_undo.configure`, at a launch's
first step) removed the two October 21 checkpoints in
`Documents/.blender-history`, as any launch does.

Checks: `scripts/run-featuretest-tests.sh` (new: the rating at each
threshold, frame times, the report's lines read back, a stopped run named,
the Python sent and its answer, the inventory and the runner's cases),
`run-selftest-tests.sh`, `run-selftest-blender-check.sh` (40 of 40, and the
control), `run-budget-tests.sh`, `run-names-tests.sh`, all passing.

Not covered: a real tap on the gear and the buttons, and a Release run of the
test itself (this Mac's screen is not to be clicked; the iPad from TestFlight
is where it belongs), the iPad's own numbers, and what the not-tested list
above names.

Blender checks. **To open it: Preferences (the top bar's gear, or File ▸
Preferences…) ▸ Testing ▸ Self-Test.** Until November 1 it was hidden behind
seven taps on the Version row; it is a visible button now, beside Test All
Features (see that entry). An app-only feature, so it keeps its own name.
Before Run it says what it does to the

### With the layout, the camera drag, and an optimized build (November 1, later)

After the walkthrough's layout (the section above) was merged with this, in
the app on this Mac, `-feature-test`, the container's recovery file:

- **The editors' dock costs little.** Debug build, dock shown against hidden
  (`-bl_editors_shown YES|NO`, the `@AppStorage` key in the argument domain):
  stalls summed over the run 17.8 s against 16.6 s, the median command 126
  against 120 ms, and the run 61.6 against 52.7 s; drags drew the same. The
  dock redraws once a command's mirror has changed what it shows, as Blender's
  editors do.
- **Orbit, pan and zoom were held back by SwiftUI, not by drawing.** Every
  step wrote the camera to the root view's state (`parent.camera`, a
  `Binding`), so every step re-ran the 3D View's whole body — the header, the
  toolbar, the dock — and only then did `updateUIView` hand the renderer the
  new camera; the readout the step set re-ran it again. A camera drag now
  keeps its camera in the viewport's coordinator (`liveCamera`, drawn from
  the next frame, `moveCamera`/`endCameraMove`) and hands it to the view when
  the drag ends; `updateUIView` draws the drag's camera while one is under
  way; the rulers and Edit Mode's measurements, the one SwiftUI overlay that
  follows the view, read it through `ViewportCameraFeed`; and the readout
  lives in a view of its own (`ViewportInfoRow`), so a step redraws that row
  alone. The trackpad's scroll, the finger's orbit, the Pencil's orbit, the
  two-finger pan and the pinch all go through it, and so do Test All
  Features' orbit, pan and zoom (they had copied the handlers' arithmetic onto
  the binding, which would have measured the old path). On the 64,226-vertex
  sphere, dock shown, Debug: Orbit 66.7/83.3/83.3 ms → 16.7/16.8/81.8 ms,
  Pan 50.0/100.0/116.7 → 16.7/16.8/60.5, Zoom 50.0/83.3/100.0 →
  16.7/16.7/17.1 (median/p95/worst): Slow to Smooth, 60 frames a second.
- **A Debug build measures Swift at a fraction of its speed.** Built Debug
  with `SWIFT_OPTIMIZATION_LEVEL=-O` and whole-module compilation (the hooks
  stay; the TestFlight build is optimized the same way), dock shown: 111 run
  in 49.4 s — 94 Smooth, 8 OK, 8 Slow, 1 Freeze — where the Debug build gave
  42/48/19/2. The mirror pass that took 160 to 330 ms of every command on the
  sphere in Debug takes 6 to 45 ms; the Texture Paint stroke (Freeze, 2.1 s)
  and Measure's drag (Slow, 0.8 s) are Smooth. Dock hidden, the same build:
  93/8/9/1.
- **What is left, optimized:**
  - Adjust Last Operation making the large sphere (Segments 288, Rings 224):
    3.4 to 4.4 s. Blender's own: desktop Blender 5.2.1 takes 5.9 s for
    `primitive_uv_sphere_add(segments=288, ring_count=224)` on this Mac,
    sandboxed, `-b --factory-startup` (`ed.undo` 4 ms, the push under 1 ms,
    the mirror 45 ms of the app's). Not the app's to make faster.
  - The Scripting tab's first frame, 0.4 to 0.5 s (Monaco's web view).
  - Voxel Remesh 0.38 to 0.42 s and glTF export 0.25 to 0.28 s: one command
    each, mostly Blender's.
  - Brush strokes on the sphere (Sculpt Draw, Vertex and Weight Paint): a
    median frame of 16.7 ms, a p95 of 50 to 83 ms — a hitch where a chunk's
    call to Blender (35 ms median for Sculpt's, 84 ms worst for Vertex
    Paint's) lands on the main thread.
  - Timeline Play was rated Slow at 50 ms frames, which is the scene's 24 fps
    on a 60 Hz screen: it played frames 1 to 48 in 2.0 s. The rating now
    holds playback to its own pace (`FeatureTest.rate`'s `pace`: a frame of
    the scene's rate rounded up to the next refresh is Smooth, one refresh
    more OK; a pace as fast as the screen's keeps a drag's thresholds;
    `run-featuretest-tests.sh` has three checks for it).

## October 30: the Self-Test

A one-tap check of a build on the device it is installed on, in Release as
in Debug, so a TestFlight build can be held on the iPad to the desktop
Blender checks. **To open it: File ▸ Preferences…, then tap the Version row
seven times.** The Self-Test sheet opens; it shows nowhere else (an app-only
feature, so it keeps its own name). Before Run it says what it does to the
open scene; Run starts it, the sheet shows "Check n of N" and each check's
PASS or FAIL as it ends, then Copy Report and Share. Every report is also
saved to `Documents/Self-Test/self-test-<date-time>.txt` (Files ▸ Blender
Local ▸ Self-Test). Preferences is new: the app showed its version nowhere
visible (the status bar that has it is hidden), so it is one plain Version
row; Blender keeps Preferences… in its Edit menu, which this top bar does not
have, so it is the File menu's last row.

What it runs (`Resources/python/site/_blenderkit_selftest.py`, on the main
thread by `BpySession.runSelfTest`), only guarded paths, none of the desktop
checks' deliberately unguarded controls, in this order (least likely to take
the app down first, so a crash leaves the most on the report):

- **Ordinary edits**, allowed and timed (a FAIL past 3 s): Move, Extrude,
  Subdivide, Add Modifier, a legal Array. **The mirror's pass** after a
  script.
- **One vertex-budget refusal per family** of parts 12, 12i and 12j: Array
  Count (a key, 12.3), Time Stretching (12i.1), an F-curve modifier (12i.2), a
  legacy texture (12i.7), Geometry Nodes instances (12i.3), Shift+D into a
  collection a Collection Info realizes (12j.2), a driver (12.2) and a
  Boolean's Fast threshold (12j.6), each refused with Blender's own count
  unchanged.
- **Operators the guards refuse**, from `tests/unsafe/blender/verify.py`: New
  Scene's Full Copy and Linked Copy inside `temp_override(scene=…,
  view_layer=…)`, the window given another scene inside one and then
  `evaluated_depsgraph_get()`, the window's own scene removed, the guards'
  sealed closures.
- **The crash paths fix round 3 guarded**, from `tests/budget/blender/freed.py`:
  every case that crashed Blender on 6d31b90 (leaving Edit Mode under
  Geometry Nodes and a Bevel after Extrude, by `editmode_toggle`, after eight
  operators, straight to Sculpt and the paint modes, Undo and Redo across the
  leave, a script's bmesh edits and `bmesh_modifiers`, Edit Mode round trips,
  Bevel Weights by a line and by bmesh, an image and a font removed under
  Blender's copies), the Subdivision, Remesh and Array leaves, the bmesh
  leave's price and the two window's-scene cases; three rounds each (Extrude
  doubles the grid every round: six took the footprint to 1 GB on the Mac).
- **A 64 × 64 EEVEE render** through the Render panel's own script
  (`RenderRequest`, Draft, 8 samples) on the Metal GPU. Cycles is left out:
  its first Metal kernel build takes minutes. EEVEE is most of the peak
  memory (about 1.2 GB on the Mac, kept for the session, as after any EEVEE
  render in the app).

The user's work: the scene goes to `autosave.blend` first (the app's own
recovery write, so a run that takes the app down leaves the next launch the
scene as it was), and the run saves its own copy the same way
(`_blenderkit_undo.autosave`, to the temporary folder). Every check starts
from Blender's startup file opened as File ▸ New opens it; after the last,
the copy is opened as the launch opens the recovery file. A fingerprint of
everything a save keeps — scenes, the window's scene, selection and modes,
objects and their transforms, modifiers and collections, mesh vertex hashes,
curves and the other data-blocks — taken before and after is the report's
last line. Opening a file ends Blender's undo history, and the sheet says so
before Run: afterwards Undo goes back to the scene as it was and never to a
check's scene (the run's own history steps take each other's place). With
painted pixels not yet saved the run refuses in one line and touches nothing.
The checks mirror into a scene nobody draws; the user's is mirrored into the
viewport after.

The report: a header (device, iOS, RAM, the app's version and build,
Blender, Python, the total time, peak memory from `proc_pid_rusage`), one
line per check (PASS or FAIL, its time, its name, what was measured), and a
summary. It is written as the checks go: a run that takes the app down leaves
the check it was running as the report's last line, and the sheet names it
the next time it opens.

Measured on this Mac:

- Sandboxed desktop Blender 5.2.1 with the app's context, MallocScribble:
  40 of 40 in 3.0 to 4.7 s (load average about 20), the user's scene in Edit
  Mode or Vertex Paint put back, the history as above. On 6d31b90's modules
  the run passes the ordinary edits and two refusals (Array Count and the
  driver, closed in fix round 2), FAILs six, and Blender crashes in New Scene,
  Full Copy (exit 139); each check alone there, 16 crash Blender, 11 FAIL and
  12 pass (those, the mirror, the render and three leaves that never
  crashed).
- In the app, Designed for iPad (Debug build, the bundled bpy, the
  container's own recovery file: one object in Vertex Paint): 40 of 40 in
  13.7 s, the EEVEE render 6.0 s of it; footprint peak 1,426 MB, 460 MB
  after. The report was written to `Documents/Self-Test/`; the app's
  autosave afterwards held what the one before held (the fingerprint,
  read in desktop Blender); the container's files were put back and their
  checksums matched. That run went in by `-self-test` (below): this Mac's
  screen was locked, and a locked screen refuses synthetic clicks, so a
  real tap (then the Version row's seven, now the Self-Test button) and a
  Release run through it are still to be done on an unlocked screen or on
  the iPad. Debug and Release built for
  Designed for iPad; the Release build launched and opened the recovery
  file; the release content scan stays clean (`-self-test` added to its
  hooks).

DEBUG builds take `-self-test`: Preferences opened at launch, its Self-Test
button pressed through its own action (until November 1, the Version row's
seven taps through their handler), and Run pressed; `[bk-selftest] ended: …`
is printed with the report's path. It exists for a
Mac whose screen cannot be clicked (a locked screen refuses synthetic
clicks).

Checks: `scripts/run-selftest-tests.sh` (the Swift: the Python sent, the
progress lines read, the report's name), `scripts/run-selftest-blender-check.sh`
(the run in sandboxed desktop Blender under MallocScribble, the user's scene
in Edit Mode and again in Vertex Paint, held to its report, the scene put
back and the history; with painted pixels unsaved; then 6d31b90's modules,
which have to crash or fail).

## October 29, fix round 3: the review of "the budget gaps a script reaches, and the gate's own holes" answered

The adversarial review of "the budget gaps a script reaches, and the gate's
own holes" (below) measured six defects in work that entry called closed:
three critical (route 2 for a callable with no code of its own, route 1
through a module a script makes, the app's own loads of a file a script
wrote), one high (route 3 with both lists cleared, which it called held),
and two medium (`sys.monitoring` switched off by the handler itself, and the
return checkpoint running inside Blender's evaluation). Each was reproduced
first in sandboxed desktop 5.2.1 with the app's context (its undo push,
`gpu.init()`, the gate), the budget lowered to 100,000 and every probe killed
past 3 GB resident, on a copy of the reviewed site, where each reproduced
as the review said (the reviewed tree's numbers are in the controls
below). That entry's "route 1 … no longer a mark a script can copy" and
"route 3 … held" did not hold; both are corrected here and in the still-open
entry. Files: `_blenderkit_gate.py`, `_blenderkit_sync.py`,
`_blenderkit_undo.py`, `_blenderkit_budget.py` and `_blenderkit_anim.py`
(their handlers named to the gate), `BpyBridge.swift` (`Bpy.pricedLoad`,
`Bpy.newScene`, `Bpy.changedRecovery`), `RecoveryRecord.swift` (new),
`BpyRuntime.swift`, `RootView.swift`, `TopBarMenus.swift`. Tests: part 12t,
`tests/budget/blender/review3s.py` (new; at the end of the budget check, or
alone with `BUDGET_PARTS=12t`), the load strings in
`tests/budget/blender/main.swift`, the recovery record in
`tests/undo/main.swift`, part 12s's controls (now with nothing held at the
mirror's pass either) and the budget check's `gate_off` (what a control
built with the gate off is taken as allowed at the next pass).

### What closes each item

- **Route 2, a callable with no code of its own** (critical). Reproduced: a
  `functools.partial` and an instance with `__call__`, each taking out the
  checkpoint after it and setting Count 20,000, built 160,000; so did an
  instance handing out another function's `__code__` attribute (the gate
  watched the borrowed code) and a bound method whose function is such an
  instance. Such a callable is now wrapped where it stands in its list
  (`_Guarded`): the wrapper calls it, then the checkpoint, in the gate's own
  code, which nothing done to the list skips. Blender keeps only a plain
  function, or a method of one, across a file load
  (`BPY_app_handlers_reset`), so a wrapper changes nothing there, and it
  compares equal to what it wraps, so a script's `in`, `index` and `remove`
  still find its callable. A plain function keeps its identity and is
  watched, its code read by type (`_handler_code`), never from an attribute.
  Each refused at 160,000, Blender at 16.
- **Route 1, a handler taken as the gate's own** (critical). Reproduced: a
  `types.ModuleType('_blenderkit_zz_fake')` with `__file__` beside the
  app's modules, the handler compiled under that path into its dict; the
  same compiled into `_blenderkit_tools.__dict__`; and a fake module under
  Blender's scripts folder: 160,000 built, each. A module, a file name and a
  function's globals are all a script's to make, so `_own_by_file` is gone:
  the gate trusts only identity — its own functions, every callable in
  every handler list at its first `install` (which the app makes as it
  starts, before any script: Blender's `_on_blendfile_load_post` twice and
  `do_versions`, and the app's), and what the app's modules name to it as
  they add a handler (`trust`: the frame plan's, the undo's, the timeline's
  collectors, which are made per frame and `distrust`ed after). Each
  refused at 160,000, Blender at 16; Blender's and the app's own still have
  no checkpoint after them.
- **The app's own loads of a file a script wrote** (critical). Reproduced in
  checkpoint mode: a Run line wrote S9 (X under an Array of 20,000) with
  `bpy.data.libraries.write` and copied it over every `.blend` in the
  history folder; the next push and `undo.step(-1)` opened it as the app's
  own, X at 160,000. Now the app vouches for each file it writes itself —
  an undo step, the history's checkpoints, the recovery file — by device,
  inode, size, modification time and status-change time, the last of which
  only the system sets (`vouch`; a write, a rename over it or `os.utime`
  each moves it), and writes it with a script's save handlers out of their
  lists (`saving`: a save_post handler runs after Blender's write). The
  history's and the undo's own open stands aside only while the file is as
  written (`opening(path)`); otherwise it is priced as a script's load, and
  said in the mirror's pass after ("Undo's step file …, which changed after
  this app wrote it, would give X 160,000 vertices …"), the step itself
  completing so the history stays where Blender is. File ▸ New's startup
  file is one the app never writes, so it is priced always
  (`Bpy.newScene`); the recovery file at launch is opened as saved only
  while it is as the app last wrote it, which the app keeps in the keychain,
  where a Python script cannot write without ctypes (`RecoveryRecord`;
  with no record yet, the first launch of this build, it opens as before).
  Refused at 160,000 in words, X at 8: the undo step's file, the history's
  checkpoint, File ▸ New on a heavy startup file and the changed recovery
  file, as the Swift sends them. The Open sheet's own open of the same file
  is still Blender's to evaluate as saved (160,000, the control), and the
  app's own unchanged file opens as saved.
- **Route 3 with both lists cleared** (high). Reproduced: clearing
  depsgraph_update_post as well as _pre, then the base type's `update`,
  built 160,000 with no refusal, and a later move passed at 160,000;
  putting the lists back in the same line left no trace. Nothing in Python
  stands between that call and Blender's evaluation, so it is still not
  refused before. What it builds is held now at every mirror's pass, which
  no script can take out of the app's run (`hold_unseen`): an object
  Blender holds past the budget and past the most it was let hold (what it
  held at the end of the app's last load of its file as saved, taken there
  before anything else in the run can build, else the budget; no price lets
  an object grow past the budget) has the modifiers that make more
  hidden, or is taken out of the scene where its own data is heavy or its
  kind cannot be told without evaluating it, and is said in words. Every
  depsgraph Blender has made is read, and any other view layer held is
  evaluated again, so the never-evaluated view layer's route (S2's X at
  160,000) is held the same way. Held: Blender at 8 after the pass, the
  later move at 8; both lists put back by the line, held all the same; S2
  at 8. Measured cost on the final code: 1.2 to 2.2 ms a pass (median
  1.35) on 4,100 objects (3,000 empties, 1,000 cubes, 100 bevelled curves),
  against the pass's own 582 ms, load average about 3.
- **`sys.monitoring` switched off by the handler** (medium). Reproduced:
  `set_local_events(tool, own code, 0)`, then the checkpoint taken out and
  Count 20,000: 160,000. Python's own hooks (`sys.monitoring`,
  `sys.settrace`, `sys.setprofile`) are now named in the gate's limits, with
  the app's own modules, beside `sys.modules['_blenderkit_gate']`. Every
  guard pass sets the tool, its callbacks and its events back
  (`_watch_again`; a callback of a script's on the tool restarts events),
  and what such a handler builds is held at the mirror's pass: Blender at 8,
  said in words (not refused before).
- **The return checkpoint inside Blender's evaluation** (medium). Measured
  first: a function that was a depsgraph_update_post handler and an Object
  property's getter a driver read ran the gate's checkpoint 4 times in 3
  evaluations inside Blender's evaluation; as a Scene property's getter
  under an Exact Boolean, it ran there on Blender's worker threads (the
  getter ran on worker threads and the main one). The arguments are now
  read as the call begins (PY_START), not at its return, where the handler
  could have written over them, and a return counts only when the call
  began as Blender calls a handler: the scene and the depsgraph, or the
  scene alone for a function of one argument, on a thread with Python
  under it (Blender calls these lists on the thread that asked for the
  evaluation, which in the app always runs the bridge's Python). The Object
  getter: 0 inside evaluation (4 with every return taken as a handler's);
  the Scene getter under the Boolean: 0 on worker threads (4 before). Left:
  a function of one argument that is also a Scene property's getter, read
  on the main thread, is called exactly as Blender calls it as a handler,
  and still runs the checkpoint there (once in each round of three
  evaluations, on the main thread). Under MallocScribble and
  MallocGuardEdges, 3 to 4 rounds each with that getter writing nothing, a
  Count, 160,000 vertices and a Boolean's solver, nothing crashed; but where
  the getter wrote, its write was refused at the dispatch's checkpoint, not
  inside the evaluation, so a refusal made there that takes an object out
  of the scene is still not reached (still open, below).

### Crashes hit

One, in desktop Blender, none in the app. The freed-memory check
(`run-freed-blender-check.sh`, under MallocScribble and MallocGuardEdges)
exited -11 in its window_scene_set case with `hold_unseen`'s first form,
which read `copy.original` over `dg.ids`: a depsgraph Blender has not
rebuilt since an object was freed still lists the copy, and its original
was freed memory (`pyrna_prop_to_py`). `hold_unseen` now goes from the live
originals to their copies (`evaluated_get`), as `_held_count` does; the
check's 26 cases, 6 rounds each, then passed with no crash.

### Checks and their controls

Part 12t (`tests/budget/blender/review3s.py`), each case through a script
line and the mirror's pass, the history's own calls, or the Swift's strings,
Blender's own count read after, beside a control that puts the reviewed
tree's code back (and, where the gap builds, nothing held at the mirror's
pass) and has to let it through:

| Case | Now | Control |
|---|---|---|
| partial / instance / method of one, unhooking | refused at 160,000, Blender 16 | 160,000 built |
| instance with a borrowed `__code__` | refused, 16 | 160,000 built |
| fake module / real module's globals / Blender's folder | refused, 16 | 160,000 built |
| both lists cleared, base type's `update` | held at the pass, 8; move at 8 | 160,000; move at 160,000 |
| the same, lists put back by the line | held, 8 | — |
| never-evaluated view layer | held, S2 at 8 | S2 at 160,000 |
| `sys.monitoring` off in the handler | held, 8 | 160,000 built |
| load_post handler unhooking its checkpoint | held, 8 | 160,000 built |
| handler that is an Object getter | 0 checkpoints in evaluation | 4 |
| undo step's file written over | refused at 160,000, X 8 | 160,000 built |
| history checkpoints written over | refused, X 8 | 160,000 built |
| File ▸ New / changed recovery, Swift's strings | refused, X 8 | Open sheet: 160,000 as saved |

and what passes: a wrapper still found by `in` and `remove`, Blender's and
the app's own handlers with no checkpoint after them, the app's own undo
file opened as saved (24 vertices), File ▸ New on Blender's startup file.
The recovery record (host suite `undo`): a file as written is as written;
written over in place with the same bytes and its modification time set
back with `utimensat` (device, inode, size and modification time all as
kept), it changed — and with the status-change time left out of the record
(the control, a scratch copy) that check fails, the file taken as written;
replaced by a rename over it, changed; no record, unknown.

What ran (desktop 5.2.1, sandboxed; loads as said). The whole budget check
once on this work's first form, beside other checks at load averages of 10
to 28: its part 10 sweep (20,526 runs of 15 states, 161 s) and its control
(110 runs found growing, 473 s) passed; sixteen controls of 12i and 12j
failed because the mirror's pass now holds what their gap builds, so their
`put` helpers turn that hold off too, as 12s's controls do (`nohold_s3`);
and 12t stopped on `undo`, which part 13 had made a function of verify.py's
globals (it reads the modules from `sys.modules` now). Then parts 1 to 13
with 12s and 12t: 646 passed, 0 failed; and, on the final code (the
allowance taken at the end of the app's load, the live-originals loop),
12s and 12t again (181 passed, 0 failed with the parts that always run),
the undo check (103 PASS), the freed-memory check (26 cases, 6 rounds each
under MallocScribble and MallocGuardEdges, 0 failed, twice), and the
context (68), unsafe (188), render (44), texpaint (78), mirror (144),
viewport (35) and guards (87) checks, exit 0 each; host suites budget
(with its section 7 in desktop Blender), undo, sandbox, scriptthread and
modkinds, ALL PASS. The sculpt check failed once on timing alone ("no chunk
passes 80 ms", 106.3) while the budget check ran beside it at a load of 20
to 28; run alone at 2.7 to 4.7 it passed (182 PASS, the slowest chunk
56.5 ms). The timing lines the review could not check, run alone at a load
average of 3.3 to 3.6 (WindowServer and a few light processes the only
other work): the animation Blender check ALL PASS, a frame change
1.09 ms against a quarter of 60 Hz (4.17 ms), the mirror's share of a frame
with 3,000 keyed empties 31.2 ms (46.4 less Blender's own 15.2) against 100,
the frame's price 0.0035 ms; the mirror host suite's 3,000 keyed channels
2.09 ms against 5. `_keep_live_as_files` on a large scene is in the
still-open entry.

### In the app

The real Debug build on this Mac as Designed for iPad, one instance at a
time, from the user's own autosave (it, the history folder and the draft
backed up first and put back after; checksums match). Lines went through
`-object-ops`'s `py:` tokens (the console's `bridge.run`, a Run Script step
each) and its `undo` (the top bar's `session.performUndo`):

- The history in checkpoint files (`-undo-checkpoints`), the budget lowered
  to 100,000 by the first line: the partial that takes out its checkpoint,
  refused ("Array count 20000 would give A 160,000 vertices …"), A at 16;
  the handler from a module the line made beside the app's, refused, A at
  16; both lists cleared and the base type's `update`, held at the mirror's
  pass, A at 8, said in words; a line writing a heavy S9 over every .blend in
  the history folder, then Undo: step 3 of 4, Blender at X.001 8, and
  "Undo's step file …, which changed after this app wrote it, would give
  X.001 160,000 vertices …" said (the first build tried left those words in
  the console only, and the history's labels where they were; the step now
  takes the state Python sends back and puts the words where the top bar
  shows what the last run did, `stepBackendHistory`).
- A line wrote Y under an Array of 400,000 over autosave.blend, and the app
  was killed before its own autosave two seconds later. The next launch
  found the file changed since the keychain's record and priced it: "The
  recovery file, which changed after this app wrote it, would give Y
  3,200,000 vertices, and this app stops at 2,500,000 …", Y at 8, the app
  at 257 to 310 MB resident.
- After a change, the app's own autosave wrote the file and its record; the
  next launch opened it as saved, nothing said.

File ▸ New was not driven in the app (no hook reaches the menu); its string
is run in desktop as the Swift sends it (part 12t). No crash in the app (no
new report). The app now keeps one keychain item, the recovery file's
record: after the user's autosave was put back, that record no longer
matches it, so the next launch prices that file once (it is light, so
nothing is said) until the app writes it again.

## October 29, fix round 3: the review of "the budget gaps a user reaches from the interface" answered

The adversarial review of "the budget gaps a user reaches from the
interface" (below) found six critical gaps in work that entry called done:
a move in a bare orientation, priced Object Mode operators other than the
moves (Duplicate), Single Property drivers that read derived values, the
colours of a texture's colour ramp, empties that instance a collection, and
Blender's own time on a Fast Boolean's Overlap Threshold (a freeze). It also
found three medium items: the completeness checks could not find these, the
docs overclaimed, and an ordinary edit under Self Intersection was slow and
not measured fairly. All nine are closed here; the two low items are listed
(below). Each was measured first in sandboxed desktop 5.2.1 with the app's
context (its undo push, `gpu.init()`, the gate), through the path the
interface sends, beside a control that puts the gap back. Every case was the
same on 6d31b90 in the review's measurements, and each control here puts
6d31b90's behaviour back: none is a regression of that entry. Its "None open
from this list" was wrong, and is corrected in it and in the still-open
entry.
Files: `_blenderkit_budget.py`, `_blenderkit_gate.py`,
`_blenderkit_nodecount.py`. Tests: part 12j,
`tests/budget/blender/interface4.py` (new; at the end of part 12, or alone
with `BUDGET_PARTS=12j`), four more settings in part 12.17's sweep
(`sweep2.py`), and 12i's Fast fixtures made with the gate off
(`interface3.py`).

### What closes each item

- **A move with a bare orientation** (critical). The price took any
  orientation given without a matrix as Global. Measured (O, the offset of
  A's Array fitted to 40, at (1, 0, 0) turned 90° about Z): a Scale in Local
  as the gizmo commits it, `transform.resize(value=(1, 0.0001, 1),
  orient_type='LOCAL', constraint_axis=(False, True, False),
  center_override=(0, 0, 0))`, and the redo row's `transform.translate(
  value=(0, 0.9999, 0), orient_type='LOCAL')` each built A 328 → 3,199,472.
  Two changes:
  - `_orientation` now chooses as `initTransInfo` does (transform_generics.cc):
    no type and no matrix is the scene's Orientation in a 3D View's region
    and Global without one; a matrix is used only with no type or with an
    `orient_matrix_type` equal to it, and otherwise Blender works the type
    out again (`_axes_of`, through `_blenderkit_orient.matrix`, the
    line-for-line port, and the region's view for View). With it, the pivot
    is the scene's Pivot Point in a 3D View (`_pivot`), and an unconstrained
    Rotate there turns about the axis turned over
    (`transform_mode_rotation_axis_get`; measured: 0.5 about Z took (1, 0, 0)
    to (0.8776, −0.4794, 0) under the view, (0.8776, 0.4794, 0) without).
    Found doing it: a matrix given as nested rows was read as a Matrix's
    rows, where Blender takes each row as an axis (measured: rows (0, 1, 0),
    (−1, 0, 0), (0, 0, 1) with value (1, 2, 3) moved an empty by (−2, 1, 3);
    the same numbers as a mathutils Matrix, by (2, −1, 3)), so a turned
    matrix was priced the other way (`_given_axes`).
  - The move's update is held to what its price priced: each moved object's
    world matrix (`priced_places`, recorded by `price_object_moves`), against
    the one Blender will evaluate from the channels written (`_place_after`),
    within `PLACE_TOLERANCE` (2e-6 of the matrix's size; the largest
    difference measured over Moves, Rotates and Resizes of a turned, scaled
    empty in all seven orientations was 2.4e-7). Anywhere Blender put an
    object otherwise, or a constraint or a non-object parent decides it, the
    update is priced whole (`_within_move`). This alone refuses the review's
    case with the price made wrong again (12j.1).
  Refused at 3,200,008 and 3,199,480, Blender at 328.
- **Priced Object Mode operators other than the moves** (critical). Their
  update was compared for Edit Mode's values only, so Shift+D, Duplicate
  Linked and `object.duplicate` of a 1000 × 1000 grid in a collection a
  Geometry Nodes Collection Info realizes took G 1,002,001 → 2,004,002 →
  3,006,003. In Object Mode such an update is now compared whole and priced
  as the state it leaves (`_in_handler`, `_object_mode`), as a script
  line's is; Add ▸ Grid into that collection was the same gap and is closed
  the same way. Except the modifier operators, whose own price judges every
  object that reads theirs (`_PRICED_WITH_READERS`): compared whole, Add
  Modifier ▸ Weld on a legal 399,254-vertex Boolean took 2.25 to 2.33 s
  against 1.39 to 1.51 s (Blender's own 0.48 to 0.56 s); 12j.2 holds that
  their price reaches a reader. Found with it: Collection Info was counted as
  one instance per object, each holding every object, so the first, legal
  copy was refused at 4,008,004 where Blender makes 2,004,002. It is counted
  now as Blender makes it (node_geo_collection_info.cc): one instance of the
  whole collection, or with Separate Children one per child holding at most
  the largest. At the real budget the first Shift+D passes at 2,004,002 and
  the second is refused at 3,006,003, G's modifier hidden.
- **Single Property drivers reading derived values** (critical). A
  variable reading `matrix_world`, Dimensions, a bound box or a pose's head
  and tail was read from the original, which holds what Blender last
  evaluated. Measured: A's Count driven by x × 40,000 + 2, x = E's
  `matrix_world[3][0]`: the Data API row's Location (10, 0, 0), a script
  line and a Move of 10 each built 16 → 3,200,016; Count = x × 20,000, x =
  T's `dimensions[0]`: the row's Scale (10, 1, 1), a line and a Resize each
  320,000 → 3,200,000. Such a variable is now one only Blender can work out
  (`_derived_path`, `_variable_value`): the row's write is not approved, and
  the gate prices it from Blender's own evaluation with every modifier that
  makes more hidden (`probe_values`). Each of the six refused at 3,200,016
  or 3,200,000, Blender as it was; the row's Location 0.0001 (Count 6)
  passes.
- **A texture's colour ramp** (critical). `color` was in the gate's `_NEVER`,
  so a colour ramp stop's colour was never compared: a cube under a
  Displace reading a Blend texture at Contrast 0 through a colour ramp held
  at grey 0.5, then an Array fitted to 40, went 168 → 3,199,472 from a
  script line setting both stops to grey 0.25. `color` is compared now. A
  stop added to the ramp (a change of how many items, which no value puts
  back) reached no object, and built 3,199,472 too: what reads the texture
  is now priced as it is, and on a refusal its modifiers stay hidden
  (`_item_readers` in `price_state`). An object's own display Color, which
  the app's material picker writes with every colour (`BpyBridge
  .setMaterial`) and no model reads, is priced only where a driver reads it
  (`_display_colour`): priced, a pick on the 80,000-vertex Self Intersection
  Boolean below would cost a second evaluation of it.
- **Empties that instance a collection** (critical). They counted nothing
  in Geometry Nodes' Object Info and Collection Info: one script line making
  Collection Info of C → Realize Instances, C holding three empties each
  instancing D (a 1000 × 1000 grid), built 3,000,000. Blender gives such an
  empty its collection as an instance whatever its Instancing is set to
  (`object_get_evaluated_geometry_set`; measured: 30,000 with Instancing
  None, three grids of 10,000), and so does the count now, at every level
  (`_collection_instance`). What reads the instanced collection's objects is
  found through the empties (`_with_instanced` in `_references`), and the
  gate's dependencies follow any instanced collection, not only one whose
  Instancing is Collection (`_dependencies`: the depsgraph builds it either
  way, `build_object_instance_collection`). Refused at 3,000,000, G at 8;
  D's grid given a Subdivision of 2 (157,609) with G reading it through the
  empties is refused at 472,827.
- **Fast's Overlap Threshold froze Blender** (critical). Blender's own Fast
  time was never priced, and fix round 3's near-contact work asked Blender
  for one more Fast evaluation on every price. Measured: Fast's time follows
  the pairs of triangles whose boxes come within 40 × its threshold of each
  other (`eps_margin`, 20 × the threshold, on each BVH): two N × N grids,
  N 20 to 80, thresholds 0.001 to 0.2, 10,192 to 97,170,920 pairs, 0.01 to
  72.6 s, 0.31 to 1.29 µs a pair (0.31 to 0.80 past 500,000 pairs). The
  price now works that time out before anything asks Blender through the
  Boolean (`_fast_seconds`: every corner pair at most, and where that could
  pass `FAST_SECONDS` the faces' boxes, exactly up to 4,000,000 face pairs
  and from a fixed sample of 1,024 faces past it, at `FAST_PAIR_SECONDS` =
  1 µs a pair), and refuses a change that takes it past `FAST_SECONDS`
  (5 s, Subdivision's own) and slower than now. Nothing is evaluated
  through such a Boolean: the walk does not refine through it, a later
  modifier's measurement through it is refused in words, and `_final`
  keeps the light walk's bound (which reads where things are). The Data API row's Overlap Threshold 0.05 on two 40 × 40
  grids (Blender 18.3 to 27.3 s) is refused in 0.24 to 0.32 s, 0.01 (3.9 to
  5.6 s) in 0.20 to 0.26 s, 0.05 on 80 × 80 (248.7 s) in 0.76 to 0.87 s,
  nothing evaluated; 0.05 on 20 × 20 grids (Blender 1.1 to 1.9 s) passes in
  2.28 to 2.57 s.
- **The completeness checks** (medium). Part 12j holds each item with its
  control, and sweeps every orientation: a Move of O toward A and a Scale
  to 0.00001 along each of the orientation's own axes (measured by a bare
  Move along each), O parented and turned and the cursor turned, 28 moves —
  with 6d31b90's orientation and update put back, 18 of them pass with
  Blender past the budget (Local, Normal, Gimbal, Parent, Cursor). Part
  12.17's sweep steps four more settings: a colour ramp stop's colour (a
  colour ladder of greys; `ladders` steps arrays of two and three only), an
  empty's Location and a cube's Scale that Single Property drivers read
  through `matrix_world` and Dimensions, and an Array's Count on a grid in a
  collection four empties instance; its control with the gate off has to
  find them, and 12j.8 sweeps them with the gate on and this work's fixes
  taken out, and has to find all four.
- **The docs' overclaim** (medium). The entry below and the still-open
  entry no longer say every item is closed. Its open item "a driver or a key
  on Map Old or Map New" cannot happen: measured, `driver_add` and
  `keyframe_insert` raise "not animatable" for both, and RNA marks both not
  animatable. Removed.
- **An ordinary edit under Self Intersection** (medium). Measured with only
  this work's one Blender running, at load averages of 9 to 16 from other
  sessions: an Exact Union with Self Intersection on an 80,000-vertex
  solidified 200 × 200 grid, the Data API row's Location of the far operand
  — this code: Blender's own evaluation 12.6 to 15.4 s, the row 24.9 to
  25.7 s, the price alone 12.0 to 14.1 s; 6d31b90 (`git archive`): 10.4 to
  13.5 s, 20.9 to 24.1 s and 10.7 to 13.5 s. A profile of the price: 13.0
  of 14.1 s is its exact evaluation of the Boolean on a copy (the walk is
  not sure under Self Intersection), `_coplanar_self` 0.82 s, the crossings
  1.1 s. So the row is about twice Blender's own on both, and
  `_coplanar_self` is not what makes it slow. 12j.7 holds the row to 3 ×
  Blender's own (21.38 to 21.97 s against 9.79 to 9.97 s in the part 12j
  runs).

### Checks and their controls

Other work on this Mac while these ran, not this work's: other sessions'
Blender checks and apps, at load averages of 9 to 635.

- The whole budget check (`run-budget-blender-check.sh`) on the code before
  this work's last three repairs: 605 passed, 5 failed, in 1 h 24 min at
  load averages of 9 to 635. Part 10's operator sweep (20,526 runs of 15
  states) passed, and its control found 110 runs growing Blender. The
  five: 12.17's control and 12j.8, because the sweep never stepped the
  colour ramp stop's `color` (part 9's STATE_SKIP leaves `color` out; a
  setting a fixture names is stepped now); two of 12i.4's controls, which
  put 6d31b90's move update back through `_move_scope` alone, and this
  work's whole comparison in Object Mode refused the move anyway (they put
  `_object_mode` back too now); and 12i.5's row Location at a budget of
  17,201, which passed — Blender's slow Fast not being asked, `_final` kept
  the first count, which reads no place, so 'now' and the change counted
  the same. It keeps the light walk's bound now. The script's last line
  then exited 127 ("er: command not found"): its header comment had been
  edited while it ran (bash reads a script as it goes); it passes `bash -n`.
- Part 12 again on the final code (`BUDGET_PARTS=12`: parts 1 and 3 to 7,
  12 with its 12.17 sweep, 12i, 12j and 12s): 333 passed, 0 failed, 25 min
  38 s. 12.17: 2,537 steps, no bypass; its control, the gate off, found 19
  of its 19 settings and 5 of the 5 other ways. 12i: 54 passed. 12j: every
  check above and its control; 12j.8 found 4 of 4 with the fixes taken
  out; the Fast rows refused in 0.21 to 0.94 s, their control 8.20 s; 12j.7
  31.68 s against Blender's 16.47 s; the material pick 0 judgements, its
  control 1. 12s: 48 passed. Parts 9, 11 and 13 passed in the whole run
  above; `_final`'s last repair changes only a Fast Boolean slower than
  FAST_SECONDS, which none of them has.
- Part 12j alone (`BUDGET_PARTS=12j`), three earlier runs, found its own
  test errors and fixed them: a float32 threshold compared with `==`,
  collections of earlier cases left under the same names (`reset_j` now
  removes every collection), and a timing check of the material pick under
  a build (now a count of `_judge` calls).
- Other desktop checks on the final gate (before `_final`'s last repair):
  objectops 373, transformops 1,635, relations 2,808, objectmenu 318, redo
  749, opsearch 80, groups 447, transformfields 406, modifier 240, undo 102,
  unsafe 187, modkinds 982 passed, none failed. `run-budget-tests.sh`: ALL
  PASS, section 7 included (3 min 6 s).

### Crashes hit

None. No Blender or app crash report while this work ran (the newest
`Blender-*.ips` is from 12:43 today, before it; the newest
`BlenderLocal-*.ips` is October 22's). Every path the app ran below was run
first in sandboxed desktop 5.2.1 with the app's context.

### In the app

Debug build, Designed for iPad on this Mac (`xcodebuild`: BUILD SUCCEEDED,
44.5 s, and again on the final code, 4 min 35 s at a load average of about
100; all 32 bundled `_blenderkit_*.py` byte for byte the tree's). Each
case below ran on the first build, and all but the stops at grey 0.45 again
on the final build, with the same outcome. Each
launch started from the user's autosave, backed up first; an `-eval64`
script made its fixture, then the hooks ran the shipped paths:

- `-transform-ops`, the gizmo's drag and commit and its redo panel. RO, the
  offset of RA's Array fitted to 40, 1 m from RA and turned 90°, the cursor
  and the Pivot Point at RA. A Move of 0.9999 along Global Y passed; the
  redo panel's Orientation row set to Local re-ran it as
  `transform.translate(value=(0, 0.9999, 0), orient_type='LOCAL', …)`:
  REFUSED, the banner "Move would give RA 3,199,480 vertices…", RO where it
  was. After Undo, a Scale along Local Y (0.5, about the cursor), committed
  with `orient_type='LOCAL'` and no matrix, passed; the redo panel's Scale Y
  0.0001: REFUSED, "Resize would give RA 3,199,480 vertices…", RO where it
  was. (The first two launches drew the fixture off screen and dragged too
  little; nothing was refused or built in them.)
- `-object-ops dup` twice (Shift+D as the 3D View sends it): DM, a
  1000 × 1000 grid in DC, which DG's Collection Info realizes. The first
  copy passed, DG 2,004,002; the second was refused, "Duplicate Objects
  would give DG 3,006,003 vertices…", DG at 8 with its modifier hidden, the
  copy kept.
- `-data-api`, the Data API row's field as it sends its edit: XE's Location
  (10, −40, 0), read by XA's Count driver through `matrix_world[3][0]`,
  refused at 3,200,016; YT's Scale (10, 1, 1), read through
  `dimensions[0]`, refused at 3,200,000; the first colour ramp stop of ZT's
  texture black, refused at 3,199,480; FA's Boolean Overlap Threshold 0.05
  on two 40 × 40 grids, refused for its time ("about 45 s"); XE's Location
  0.0001, passed. Each with the banner.
- `-object-ops py:`, Run Script lines, with `cap:` reading Blender after
  each: both stops grey 0.25, refused, WT at 168 and the stops back at 0.5;
  both at 0.45, passed, WT at 200; a stop of 0.25 added, refused, WT at 8
  with its modifiers hidden; Collection Info of IC (three empties
  instancing ID, a 1000 × 1000 grid) → Realize Instances on IG, refused at
  3,000,000, IG at 8, the new modifier hidden. (The stops' line written as
  a `for` statement was a SyntaxError on that path; it ran as one
  expression.)

After each launch the app was killed. `autosave.blend` (grown to 387 MB by
the fixtures), `.blend1`, `.partial1`, `Scripts/.draft.py`,
`.blender-history` and the app's preferences were put back, and their
checksums and the three scenes' matched the backup.

### Found, and left open

Listed in "Found after fix round 2's repairs, still open (October 22)"
below, under "The budget, reachable from the interface": Fast's time model
(an upper bound by pairs, 1 µs each; the sampled estimate past 4,000,000
face pairs; a Fast Boolean already slower than FAST_SECONDS priced from its
unproven near-contact bound), Blender's own Exact Self Intersection time
(not priced), each priced Object Mode operator's update priced a second
time, and the review's low items.

## October 29, fix round 3: the review of the freed-memory entry answered

The adversarial review of "the gate's reads of freed memory, `scene.new` in
an override, the window's own scene, and the guards' closures" (below) found
one medium item and three low ones. The medium one is closed: `_derived` had
no test that could fail. Writing that test found a defect of `_derived`
itself, also closed: a refused line that had also turned Auto Texture Space
on left the text's Texture Space at the automatic place. Of the low ones, a
guard a script makes around the sealed holder is closed; the cost of
`_updates` is measured and listed; `_held_to_scene`'s boundary stays listed.
Files: `_blenderkit_gate.py`, `_blenderkit_context.py`. Tests: three checks
in `tests/budget/blender/smoke.py` (section 7 of `run-budget-tests.sh`), one
check and one "still open" line in `tests/unsafe/blender/verify.py`.

### What closes each item

- **`_derived` had no test that could fail** (medium). The case is a script
  line turning Auto Texture Space back on, on a text whose Texture Space
  Location was moved to (5, 5, 5), each step evaluated. RNA's update for Auto
  Texture Space works the place out on the original at once
  (`rna_Curve_texspace_set` → `BKE_curve_texspace_calc`); the copy keeps
  (5, 5, 5) until Blender evaluates. With `_derived` taken out of a copy of
  the modules, sandboxed desktop 5.2.1 with the app's context: the line is
  refused with "The vertex budget could not price this change (bpy_struct:
  attribute "texspace_location" from "TextCurve" is read-only), so it was put
  back." The price laid the place on its copy of the text after Auto Texture
  Space, where it is read-only. The earlier attempt at a small case wrote Auto
  Texture Space off and the place in one line; the gate loses that place (see
  the still-open entry), so nothing differed. `smoke.py` now checks:
  - that line passes, and Blender evaluates the automatic place
    (0.4835, 0.341, 0);
  - with an Array's Count 400,000 in the same line, on a text under an Array
    of 2: refused in the budget's own words, Blender at 128, Auto Texture
    Space back off and the place back at (5, 5, 5) on the original and the
    copy;
  - what `_derived` can let go at all: every setting whose RNA definition is
    writable and which reads read-only now, on a fixture of every object type
    the app adds, every modifier and constraint type on a cube (a Cloth under
    Linear bending among them) and a lattice with a shape key. It finds 23:
    the Texture Space of meshes, curves, texts, surfaces and metaballs, a
    lattice's resolution once it has a shape key, a Cloth's internal springs
    under Linear bending, and Mirror Y and Z of an object that is not a mesh.
    None makes a vertex. That is the list Blender 5.2.1's source gives too:
    a setting turns read-only at run time only through an editable
    function. Of its 36 (`RNA_def_property_editable_func`), these are the
    ones on settings `_derived` is asked of; the others are on ID pointers
    (which it is not asked of), names, the sequencer, color management,
    asset data, the file browser, the preferences and the interface. Its 8
    per-element ones (`RNA_def_property_editable_array_func`) are the
    transform locks of objects and bones, which leave the whole setting
    writable as Python asks it (measured: `is_property_readonly('location')`,
    `'scale'` and `'rotation_euler'` read False with every lock on). A new
    one fails the check by name.
- **The put-back after a refusal** (found by the second check). `_derived`
  dropped the difference, so a refusal could not put the place back: Auto
  Texture Space went back off, the place stayed at the automatic (0.4835,
  0.341, 0), and Blender evaluated that. Such a difference is now kept apart
  (`Pending.derived`), not judged and not priced; `_judge` puts it back after
  the changes, once Auto Texture Space is off again and the place writable,
  and writes it again after a pass, where Blender refuses it as read-only
  and works it out itself.
- **A guard a script makes around the holder** (low). `_Guarded.__init__`
  now refuses a caller outside `_blenderkit_context` with a TypeError in
  words, read from the caller's frame as `_module_only` reads it. Measured
  before: all 9 guard classes could be made by a script around the
  `_Sealed` holder of `_bpy.ops.create_function`'s closure, and
  `type(bpy.ops.scene.new)(holder, 'scene.new')('object', 'select_all')`
  handed back Blender's raw BPyOpFunction (only the function object was
  asked for). Now all 9 refuse. Still open, of the same kind as frames:
  code run by `exec` in the module's own globals calls the holder (measured:
  BPyOpFunction), and so do the module's own functions that call what they
  are given.
- **The cost of `_updates`** (low). Measured again with a scene grown to more
  data-blocks, an image removed and an object moved before each pass:
  6,006 data-blocks 6.7 ms median (11.0 at most), 30,006 25.9 ms, 60,006
  85.7 ms, at load averages of 190 to 240 with other work running. Only
  while a data-block of a kind Blender does not copy may have been freed
  since the depsgraph last evaluated. Listed.
- **`_held_to_scene` does not see the assignment itself** (low). Unchanged
  and still listed: no assignment-only path was found to crash.

### Checks and their controls

Other work on this Mac while these ran, not this work's: iOS Simulator
apps, another app's renderer processes and Python processes, at load
averages of 20 to 600.

- `run-budget-tests.sh`: ALL PASS, sections 1 to 7 (6 min 32 s at a load
  average of about 560). Its section 7 (`smoke.py`) with `BK_SITE` at a copy
  of the modules whose `_derived` answers False: 3 fail (the two Texture
  Space checks, each "could not price", and the list, which finds nothing).
  At a copy that drops the difference as this round's first `_derived` did:
  1 fails, the put-back, the place at (0.4835, 0.341, 0).
- `run-freed-blender-check.sh`: 26 cases, 6 rounds each under
  MallocScribble and MallocGuardEdges, 0 failed (70 s).
- `run-unsafe-blender-check.sh`: ALL PASS, 187 checks (5 min 6 s). With
  `BK_SITE` at a copy without `_Guarded.__init__`'s refusal, exactly the new
  check fails (186 passed, 1 failed): all 9 guard classes made,
  `_SceneSwitch` handing out BPyOpFunction.
- `run-budget-blender-check.sh`, the whole check on the final code (the
  gate's `_judge` changed): 563 passed, 0 failed over parts 1 to 9 and 11
  to 13; the operator sweep (20,526 runs of 15 states) PASS, and its control
  (the gate off) finds 110 runs growing Blender, PASS. 58 min 53 s, at load
  averages from about 600 at the start down to 5.
- After the change to `_blenderkit_context.py`: `run-context-blender-check.sh`,
  `run-guards-blender-check.sh`, `run-modeguard-blender-check.sh`,
  `run-objectops-blender-check.sh` and `run-opsearch-blender-check.sh` ALL
  PASS; `run-sandbox-tests.sh` ALL PASS (39 scripts, 55 launches).
- The in-app scripts below, first in sandboxed desktop 5.2.1 with the app's
  context under MallocScribble, three rounds: the same results each round,
  no crash.

### Crashes hit

None. Nothing in this work crashed Blender, in desktop Blender or in the
app.

### In the app

Debug build, Designed for iPad on this Mac (`xcodebuild`: BUILD SUCCEEDED,
6 min 18 s at a load average of about 400; the bundled `_blenderkit_gate.py`
and `_blenderkit_context.py` byte for byte the tree's). One launch, through
the shipped Run path (`-object-ops py:`, each line a Run Script with its own
undo step, and `cap:` to read Blender's numbers). The autosave opened in
Vertex Paint, so the first line goes to Object Mode (the first launch,
without it, could not add a text there: `text_add.poll()` failed; nothing
else ran). Then a text with Auto Texture Space off, its Texture Space moved
to (5, 5, 5), and Auto Texture Space back on: each ran with nothing on the
banner, and Blender read the automatic place (0.4835, 0.341, 0) on the
original and the copy, 64 vertices. A text under an Array of 2, the same
two steps, then Auto Texture Space on and Count 400,000 in one line: "Array
count 400000 would give FR3U 25,600,000 vertices once its modifiers are
counted, and this app stops at 2,500,000…", and Blender held Auto Texture
Space off, the place at (5, 5, 5) on both, Count 2, 128 vertices. A guard
made around the holder: the TypeError in words. No crash report from the app
(the newest `BlenderLocal-*.ips` is October 22's). The app was killed after
each launch; `autosave.blend`, `.blend1`, `.partial1`, `Scripts/.draft.py`,
`.blender-history` and the app's preferences were put back, and their
checksums and the three scenes' matched the backup.

## October 29, fix round 3: the budget gaps a script reaches, and the gate's own holes

(Corrected by "the review of 'the budget gaps a script reaches, and the
gate's own holes' answered", at the top: route 2 stayed open for a callable
with no code of its own, route 1 for a handler from a module a script makes
or compiles into an app module's globals, the app's own loads of a file a
script wrote were measured building past the budget, route 3 with both lists
cleared was not held, `sys.monitoring` switched off by the handler went
round the return checkpoint, and that checkpoint ran inside Blender's
evaluation. Each is closed or held there; what is left is in the still-open
entry.)

This entry closes "The budget, reachable from a script only" of "Found after
fix round 2's repairs, still open (October 22)" below, and Redo stopping at a
step kept in a file, except two routes that only Python's own base type
reaches (still open, below). Each item was measured first in sandboxed
desktop 5.2.1 with the app's context (its undo push, `gpu.init()`, the gate),
the budget lowered to 100,000 so a bypass costs little, every probe killed
past 2.5 to 4 GB resident; then closed through the gate's design — price the
state Blender will evaluate, whoever wrote it — and held by a case beside a
control that puts the gap back and lets it through. Files:
`_blenderkit_gate.py`, `_blenderkit_budget.py`, `_blenderkit_context.py`
(PRICED_OPERATORS), `_blenderkit_sync.py` and `_blenderkit_undo.py` (the
app's own loads, the history), `BpyBridge.swift` (`Bpy.appLoad`),
`BpyRuntime.swift`, `RootView.swift`, `TopBarMenus.swift`. Tests: part 12s,
`tests/budget/blender/script3.py` (new; run after part 12, or alone with
`BUDGET_PARTS=12s`), and the undo check's deferred-probe case.

### What closes each item

- **What a refusal leaves stays in the scene.** A script line's
  `vertices.add(160000)` and `update()` on a cube was refused in words, the
  cube stayed at 160,008 and a later move passed (an object already past the
  budget may be changed in ways that do not make it heavier); a metaball
  family refused for its polygonizing time alone stayed the same way. A
  refusal now prices what it leaves, as Blender will evaluate it next
  (`_left_over`): each object whose own state could not be put back, with its
  modifiers hidden as they then are, against what Blender held. One still
  past the budget, or too slow, is taken out of the scene, as a curve over
  the budget already was. Refused at 160,008, the cube out of the scene,
  Blender holding nothing for it, and the later move evaluates nothing; the
  family taken out too. The mirror's pass priced the same grown data again
  after the cube was out (the depsgraph lists it until it rebuilds) and said
  the refusal without "taken out"; only objects Blender will evaluate are
  seeded now (`users_of`).
- **What a scene reads beside its view layer.** `scene.background_set = S2`,
  S2 holding X under an Array of 20,000, built X at 160,000, and so did
  `rigidbody.world_add()` then `rigidbody_world.collection = C`: the Scene
  branch of `_diff` compared the Simplify settings, Time Stretching and the
  frame only, and X, in no view layer, was looked for nowhere. The Background
  Scene and the Rigid Body World's collections and switch are compared now
  (`_diff_scene_pointer`) and put back refused; what they bring in, a set's
  objects on down and a world's collections (`_scene_reads`), is priced as
  new, on a scene change and on a never-evaluated view layer (`_fresh`).
  Refused at 160,000, the pointer put back, X not built.
- **Renders of other scenes, bakes, exports at render settings.**
  `render.render(scene='S2')` priced the context's scene whatever the call
  named: S2's X at 196,612 vertices by its Render levels rendered in Cycles.
  `object.bake(type='NORMAL')` was priced nowhere, and neither were the
  exporters set to Render. `price_render(scene)` now walks the scene the call
  names and every scene it renders too (its Background Scene, its
  compositor's Render Layers' scenes, its Sequencer's Scene strips,
  `_rendered_scenes`), with their dependencies; a bake and
  `wm.obj_export` / `wm.stl_export` / `wm.usd_export` / `wm.alembic_export` /
  `export_scene.fbx` set to Render are priced the same way before they run
  (`_RENDER_EVALUATIONS`, in PRICED_OPERATORS). Each refused in words at
  196,612; the export wrote nothing.
- **An image a Displace reads.** Writing an image's pixels tags nothing
  (`rna_Image_pixels_set` marks the image dirty and sends a notifier), and
  Blender does not copy images for its evaluation, so there is nothing to
  compare. An icosphere under a Displace of a 64 × 64 image and a Remesh at
  0.02 (47,052): `image.pixels = <noise up to 3>` passed, and the sphere's next
  evaluation built 163,358. The gate now keeps the images a script or an
  operator may have changed (`_images_touched`: every Image's `__setattr__`,
  its members that write pixels when read — the pixel array, Scale, Reload,
  Pack and the rest, which the app's own Texture Paint writes through — and
  every image a modifier reads after a Texture Paint operator, an `image.`
  operator or a bake), and prices each object reading one as it is
  (`_image_structs`, a struct `image`). Refused in words (counted
  300,240, the Remesh's bound), the sphere's modifiers held, its next
  evaluation 642.
- **Grease Pencil Line Art.** 'LINEART' had no entry in `_GROWTH` and kept
  what it was given (the empty drawing it writes into): a Line Art of 3,321
  points under a Grease Pencil Array of 40 built 132,840 points. Line Art is
  now counted at two points an edge of every source object, and two a
  triangle with Intersection on (`_g_gp_lineart`), from each source's own
  count; a scene source reads every object (`_references`). Measured with
  Crease at 180° (every edge a feature line): 0.45 points an edge on one
  icosphere, 0.31 to 0.33 on two crossing; every edge of a 100 × 100 grid
  marked, behind a comb of 0, 20 and 60 thin bars that cut its edges, 1.01
  to 1.02; 0.01 to 0.11 s. Refused at
  1,024,000 counted; an Array of 2 passes (6,642 drawn, 51,200 counted). The
  walk no longer asks Blender for a mesh of a Grease Pencil's or hair
  curves' points (it raised "Object does not have geometry data").
- **Hair curves.** Curves objects were counted nowhere: `add_curves([1000] *
  200)` linked to the scene, or on one already there, made 200,000 points.
  They are counted by their points (COUNTED_TYPES, `_base`, `_held_count`,
  their Geometry Nodes given points), and the gate compares a Curves' points
  and curves (`_COLLECTIONS`, a `grown` struct). Refused at 200,000 and
  200,040, the new one taken out of the scene.
- **A long custom-property array a driver reads.** Arrays longer than 64
  were skipped: a Count driven by `E["arr"][0]` of a 70-element array, then
  `E['arr'] = [20000] + [2] * 69` and `E.update_tag()`, built 160,000. Every
  array is compared now, a long one whole (`_diff_custom`); the banner shows
  its first values and its length. Refused at 160,000, the array put back.
- **A file a script writes and loads.** `bpy.data.libraries.write` of a scene
  holding X under an Array of 20,000, then `wm.open_mainfile` on it, built X
  at 160,000: loads are not priced (`_LOADS`), and Blender evaluates the new
  file inside the load, right after load_post (`wm_file_read_post` →
  `wm_event_do_depsgraph`), on a depsgraph it builds fresh with no handler.
  A load a script makes is priced whole in load_post now (`_price_script_load`,
  `_fresh`), refused at its line, what makes more held. What the app opens
  itself — the Open sheet, the recovery file at launch, File ▸ New, the
  history's and the undo's own checkpoints — is still Blender's to evaluate
  as saved (`_blenderkit_gate.opening`, sent by `Bpy.appLoad` and used by
  `_blenderkit_sync.history_step` and `_blenderkit_undo._load`). Refused at
  160,000, X held at 8; the app's own open of the same file not priced.
- **A script's handlers.** (1) A depsgraph_update_post handler given
  `fn._blenderkit_gate = True` was taken as the gate's own, with no
  checkpoint after it: its Count of 20,000 built 160,000. The gate's own are
  known by identity now (`_gate_own`), a module's by the module Python
  loaded the function's file as (`_own_by_file`: its globals are that
  module's), not by a file name `compile` takes from a script. (2) A handler
  that took the checkpoint after it out of its list, then set the Count,
  built 160,000; (3) a frame_change_post handler doing the same while adding
  an Array let frame 30 through at 160,008, the frame plan never hearing of
  it. The checkpoint now also runs at the handler's own return, where no list
  operation reaches it (`_monitor`: `sys.monitoring`'s PY_RETURN local to the
  handler's code object, and PY_UNWIND, filtered to those code objects).
  Refused at 160,000, frame 30 refused, Blender at 16. Measured cost: an
  exception through a frame 0.155 µs before and 0.193 µs with PY_UNWIND on; a
  watched handler called outside an evaluation 69 µs (it prices what waits).
- **Drivers that read each other.** Count = n × 2 + x × 0 and n = Count: with
  x an empty's Transform Channel X under a keyed parent, or its X location
  with its rotation keyed, the plan listed the cycle and refused nothing,
  frames 2 to 13 doubling the Count to 131,072 (Blender re-evaluates a driver
  whenever what it reads is evaluated); with x a Distance, which only Blender
  works out, the cycle was not found at all and the probe's own frame stepped
  it twice more. Cycles are found among every driver now, those only Blender
  works out included, and refused on every frame where anything they read,
  or their owners, moves in time (`_in_time`: an action, an NLA track, a
  driver reading the frame or something that moves, a parent or a
  constraint's target that does). Frame 2 refused in words each time,
  Blender at 32.
- **A frame's probe built other objects' growth.** The probe evaluates the
  whole frame and hid the growth only on what the probed blocks reach: X's
  Count keyed 2 → 20,000 beside a cube Y with an NLA strip (or a driver
  dividing by zero at frame 10), frame 10 was refused after the probe had
  built X at 160,000 (at 1,000,000, peak memory 751 MB against about 300).
  The probe now hides the growth on what the plan's worked-out values reach
  too (`probe_values(extra=…)`, in the frame's and in the gate's refresh).
  Refused, X built at most at 16 during the probe (270 and 292 MB peak).
- **Redo past a step kept in a file.** After an autosave opened in a paint
  mode the steps before the probe settles are files, and an Undo across them
  loads one, which frees Blender's stack; `_trim` then dropped the steps only
  that stack held. Before such a load the history now writes every step of
  the live segment that has no file (`_keep_live_as_files`: the current one,
  then Undo down and Redo up through Blender's own steps, saving each; the
  load after puts the scene where it goes). In desktop, Original and Run as
  files then three moves: Redo comes back to the third move (4.0), where
  6d31b90's stopped at the first. In the app, below.

### Checks and their controls

Part 12s (`tests/budget/blender/script3.py`), each case through a script
line and the mirror's pass, the app's timeline or the history, Blender's own
count read after, beside a control that puts the gap back (the function or
table as on 6d31b90) and has to let it through:

| Case | Refused at | Control |
|---|---|---|
| grown mesh | 160,008, out of the scene | stays, move passes, 160,008 |
| metaball, time alone | out of the scene | stays |
| Background Scene / Rigid Body | 160,000, pointer put back | 160,000 built, each |
| hair curves new / grown | 200,000 / 200,040 | 200,000 built |
| 70-element array | 160,000, put back | 160,000 built |
| handler marked as the gate's | 160,000 | 160,000 built |
| handler removing its checkpoint | 160,000 | 160,000 built |
| frame plan after such a handler | frame 30 | 160,008 built |
| list cleared, `view_layer.update()` | 160,000 | — |
| list cleared, base type's entry | held at once, 8 after | 160,000 held |
| probe beside an NLA / a failing driver | X at most 16 in the probe | 160,000 built in it |
| cycle: parent / rotation / Distance | frame 2, Blender at 32 | 131,072, each control |
| render of S2, bake, OBJ export | 196,612 | rendered, baked |
| image pixels | 300,240 counted, next evaluation 642 | 163,358 built |
| Line Art under an Array of 40 | 1,024,000 counted | 132,840 built |
| a script's crafted load | 160,000, X at 8 | 160,000 built |

and what passes: a Background Scene of 160, hair curves of 1,000 points, a
small image change, a handler setting Count 3, the render of a light S2, Line
Art under an Array of 2, the app's own open of a heavy file. The undo check's
deferred probe now redoes to the Move, beside the control with no file
written before the load (Redo stops at Object Mode, as on 6d31b90).

What ran, on the final tree unless said: the whole budget check
(`run-budget-blender-check.sh`, parts 1 to 13 and 12s: 563 passed, 0 failed,
then part 10's operator sweep and its control: exit 0, 3,168 s), part 12s
alone again on the last edits (145 passed); the undo (102 PASS), render (43),
texpaint (77), context (67), freed (37), mirror (142) and unsafe (186)
Blender checks, exit 0 each; host suites budget, sandbox, scriptthread,
modkinds, undo and animation, ALL PASS. Failed, on timing only, with other
work on this Mac at load averages of 20 to 78 (another session's Python job,
simulators, this round's other checks): the animation Blender check's "a
quarter of a 60 Hz refresh" (4.96 and 5.20 ms against 4.17) and, once, "the
mirror's share of a frame" (157 ms against 100); the mirror host suite's
3,000 keyed channels (5.29 and 12.74 ms against 5), Swift this work did not
touch. An interleaved A/B of `anim.frame_set` with 3,000 keyed empties in
desktop 5.2.1, the site before this work against after, three rounds each at
a load average of about 20: medians 73.9, 77.4, 71.8 ms before and 62.6,
95.5, 65.6 after, minimums 55 to 62 and 55 to 61 — no cost this work adds
shows past the load.

### In the app

The real Debug build on this Mac as Designed for iPad, five launches, one
at a time, each from the user's own autosave (opened in Vertex Paint), the
budget lowered to 100,000 by `-eval64` (the first Run again on the final
build, the same results):

- A Run of script lines, each followed by `view_layer.update()`: the grown
  mesh refused at 160,008 and out of the scene; the Background Scene and the
  Rigid Body World refused at 160,000, put back, X not built; hair curves
  refused at 200,000 and out; the 70-element array refused, put back, Blender
  at 16; the marked handler and the one taking out its checkpoint refused,
  Blender at 16; the image refused (300,240), the sphere's next evaluation
  642; Line Art under an Array of 40 refused (1,024,000 counted; this
  scene's camera saw none of it, 0 drawn); `render.render(scene='S9')`
  refused at 196,612; the cleared list and the base type's entry held at
  once (8 after, refusal in words); the crafted file's load refused at its
  line, X at 8.
- `-frames 2,3,4,5` through `TimelineDriver.setFrame`, a cycle reading an
  empty under a keyed parent: every frame NOT SENT, the timeline at 1.
- `-frames 10,5`, X keyed to 20,000 beside Y's NLA strip: frame 10 NOT SENT
  ("Frame 10 would give K_X 160,000"), X never built past 16 during the probe
  (a post handler of the gate's own reading it), frame 5 sent at 71,120.
- The history: the autosave in Vertex Paint, a Run adding a cube, two
  Duplicates, three Undos to Original ("file 25.35 ms, kept 18.06 ms"), three
  Redos: every Duplicate back, through files, step 4 of 4.

No crash, in the app or in desktop Blender (no new report). Autosave files,
the draft, the history and the preferences were backed up and put back, and
their checksums match.

### Found, and left open

- **Python's own base type reaches Blender's evaluation past the gate.**
  `bpy.types.bpy_struct.__getattribute__(view_layer, 'update')()` (or
  `super()`), after `depsgraph_update_pre.clear()`: Blender evaluates with no
  Python of the gate's between (328 → 3,200,008 at the full fitted Array).
  The gate's post handler now holds it at once (`_unpriced`: a post with no
  pre before it), so Blender builds it once and the mirror never carries it
  — not refused before. On a view layer never evaluated, the same call
  builds with no handler at all (S2's X at 160,000), and nothing holds it.
  Closing either needs a callback Blender calls from C before it evaluates.
- **The app's own loads of a file a script can write.** The recovery file at
  launch, File ▸ New's startup file and the history's checkpoints are opened
  unpriced, and a script can write any of them (`bpy.data.libraries.write`
  to the path). Not measured.
- **An image sequence or a movie** whose frame follows the scene's is not
  priced on a frame change.
- **Line Art's bound** is not proven: an edge cut into pieces by what stands
  in front of it can make more than two points (a comb of 60 bars in front of
  a grid with every edge marked made 1.01 an edge; nothing measured past
  two). It
  over-refuses where few edges are feature lines (25,600 counted against
  3,321 drawn).
- **A cycle of drivers is refused on every frame** where anything it reads
  moves in time, a bound: an action that sets nothing counted still counts,
  and so does a script's `frame_set` in such a scene (the app test's first
  try refused its own `frame_set(1)`).
- **Keeping the live steps as files** costs a save a step at the first Undo
  across a file (18 ms for two in the app); not measured on a large scene.

## October 29, fix round 3: the budget gaps a user reaches from the interface

(Corrected by "the review of 'the budget gaps a user reaches from the
interface' answered", at the top: this entry did not close all of it. A
move in a bare orientation, Duplicate and the other priced Object Mode
operators besides the moves, Single Property drivers reading `matrix_world`
or Dimensions, a colour ramp's colours, empties that instance a collection,
and Blender's own time on Fast's Overlap Threshold were open, each the same
on 6d31b90. They are closed there.)

This entry closes "The budget, reachable from the interface" of "Found
after fix round 2's repairs, still open (October 22)" below: animation on
three paths, the Geometry Nodes counter, a priced Object Mode move that
moves more than it priced, the three Boolean items, the Data API row and
the drivers that read what it sets, and legacy textures. Each was measured
in sandboxed desktop 5.2.1 with the app's context (its undo push,
`gpu.init()`, the gate), through the path the interface sends, beside a
control that puts that gap back and lets it through (or takes the old
time). Files: `_blenderkit_gate.py`, `_blenderkit_budget.py`,
`_blenderkit_nodecount.py`, `_blenderkit_sync.py`. Tests: part 12i,
`tests/budget/blender/interface3.py` (new; run at the end of part 12, or
alone with `BUDGET_PARTS=12i`), and five more fixtures in part 12.17's
sweep (`sweep2.py`), which part 12i also sweeps with the gaps put back.
The work found, and closes, four more of the same kinds: a matrix setting
the gate could not put back (a child's Parent Inverse), the geometry inside
instances that Geometry Nodes nodes run on, a move of an object a driver
reads, and a price that failed and let its change through.

### What closes each item

- **Animation, three paths.**
  - *Time Stretching.* The gate's Scene branch compared the Simplify
    settings and the frame only. Blender evaluates a frame's animation at
    frame × Map Old / Map New, so `scene.render.frame_map_new = 10` at frame
    1, under an Array's Count keyed 2 at frame 1 and 400,000 at frame 10,
    built 16 → 3,200,000 with no refusal (a script line and the Data API
    row). Map Old and Map New are now compared (`_TIME_STRETCH`), and a new
    map makes the gate price the frame Blender holds at its new time
    (`Pending.stretched`, read by `_animation`). The Data API row prices it
    before the write (`_price_stretch`, the map laid over `_when` by
    `_stretched`). Refused at 3,200,000 both ways, Blender at 16.
  - *Keyed node-socket values in a node group's own action.* Already
    closed by fix round 2's repair of the frame plan (node groups among the
    plan's blocks), which ran beside the re-check that measured it. Measured
    again: the re-check's Grid (Vertices X keyed 10 → 1,900) is refused at
    3,610,000 on the app's timeline and a script's `frame_set(10)`, Blender
    at 19,000; so are, on those and the Data API row's `frame_current`, the
    same socket in a group nested in the modifier's group and a Geometry
    Nodes modifier's input keyed on the object; and so is the group's key
    moved by a script line and by the Data API row. Part 13's node-group
    case holds it, with its control.
  - *F-curve modifiers.* `('FCurve', 'modifiers')` was in `_NOT_ITEMS`, so a
    Generator of (400,000, 0) added by a script line to the keyed Count was
    refused in words while the same mirror pass built 3,200,000: nothing was
    put back or muted. `_diff_action` now compares each F-curve's modifiers:
    one added or removed is held as the keys are (the curve muted for the
    price and kept muted refused), a setting of one put back by value.
    Refused at 3,200,000, the curve muted, Blender at 16, and the next pass
    too.
- **The Geometry Nodes counter.**
  - *Nested realizing.* `Geo.realized` realized one level. Points (100) →
    Instance on Points of [Instance on Points (Points 100, Grid 20 × 20)] →
    Realize Instances, from a script line, built 4,000,000 with no refusal.
    It now realizes every level, as Realize Instances does with Realize
    All. Refused at 4,000,000, Blender at 8.
  - *A curve object's own curves.* The re-check also found the input of a
    curve object handed to the counter as a mesh, whose curve points read 0:
    a Bézier curve at Resolution U 1,024 under Group Input → Curve to Mesh (a
    Curve Circle of Resolution 3,000) built 3,075,000 from a script line,
    and the Data API row's Circle Resolution 30 → 3,000 built 30,750 →
    3,075,000. A curve's or a text's first modifiers, and what follows an
    earlier Geometry Nodes modifier, are now given points too: the mesh's
    vertices, and for a curve its control points times its resolutions
    (`_curve_points`); an Object Info of a curve or a text, the same.
    Refused both ways (counted 6,150,000), Blender at 13 and at 30,750.
  - *What instances hold.* Found by this work's own checking: Blender runs
    a node on the geometry inside instances too
    (`GeometrySet::modify_geometry_sets`), and the counter ran it on the top
    geometry alone. Measured on 6d31b90's counter: Points (10) → Instance on
    Points (a Grid 3 × 3) → Instance on Points (a Cube) → Realize Instances
    made 720 vertices, counted 0 (the second Instance on Points instances on
    each grid instance's points); the same then Subdivide Mesh (1), 2,340
    counted 0; Points (10) → Instance on Points (a Grid 3 × 3) → Subdivide
    Mesh (2) → Realize, 810 counted 90. The nodes that make a geometry from
    one geometry (`_EACH`: Subdivide, Triangulate, Extrude, Mesh to Points,
    Curve to Mesh and the rest) and Instance on Points now run on every
    nested geometry (`_Group._each`), and two instanced geometries are
    compared by what they hold made real (`Geo.size`). Counted 2,160 and
    7,560 (the Cube node's count is a bound); a script line's Points (1,000)
    → Instance on Points (Grid 20 × 20) → Instance on Points (Cube), and
    Points (100) → Instance on Points (Grid 100 × 100) → Subdivide Mesh (1),
    each realized, refused, where on 6d31b90's counter Blender built
    3,200,000 and 3,960,100.
- **A priced Object Mode move moving more than it priced.** In a priced
  operator's update the gate compared Edit Mode's points alone. With the
  Options popover's Affect Only Parents, A translated 0.9999 with its child
  O (A's Array offset, fitted to 40) left in place built 328 → 3,199,472;
  with Affect Only Origins, a 90° Rotate of a thin cube under an Array
  fitted to 40 by its size built 168 → 3,197,208. Three changes:
  - A move made with Affect Only Parents, Origins or Locations is priced
    whole in its update, as one with Proportional Editing was
    (`_AFFECT_ONLY` in `_proportional`).
  - Every other Object Mode move (`_MOVES` and Rotate) compares everything
    in its update, and prices it whole when anything changed beyond the
    channels of the objects it was priced for (`_move_scope`,
    `_within_move`). This alone refuses the Affect Only Parents case.
  - A matrix setting the gate finds changed (a child's Parent Inverse,
    which Affect Only Parents writes, a Hook's or a Child Of's inverse) is
    held as a Matrix. Flattened, as it was compared, it would not go back
    and was priced as stuck, from the matrices Blender held: the Parent
    Inverse case passed that way even priced whole. As nested tuples (this
    round's first try) RNA took each row as a column, and the gate's own
    put-back turned the inverse over (measured: a translation of 0.5
    written back read 0).
  Refused at 3,199,480 and 3,197,216, Blender at 328 and 168. The parent's
  own move, priced and evaluated in the operator's first update, stays:
  what is refused is the child's Parent Inverse, so O follows A.
- **Booleans.**
  - *Fast's Overlap Threshold.* Fast takes what lies within its threshold
    as touching, tilted or not, and the coplanar search matched normals in
    0.001 cells. Reproduced: two 40 × 40 grids under a Solidify, B half a
    cell over in X and Y, tilted 0.002 rad about X and lowered onto A's
    plane, Union, Fast at 0.01: the light count 7,774, taken as sure, against
    Blender's 26,628 (and at 0.001, 25,824; at 0.0001, 11,063; at Blender's
    default 1e-6, 3,878, no gap). Every face with a corner within 20 × the
    threshold of the other mesh's surface (Fast pairs every two triangles
    within that, `eps2x * 10` in bmesh_intersect.cc) is now a candidate
    (`_near_faces`), its fins as tall, and what they count taken twice;
    the walk is then not sure and Blender is asked for the exact count
    wherever the walk can ask it. The bound was at least 1.59 × Blender's
    count in 72 cases (B at four offsets, tilted 0.0005 to 0.01 rad, Union
    and Difference, thresholds 0.0001 to 0.01; once taken once, it was
    under by 1.11 ×), at most 7.3 ×. The row's Location is refused at a
    budget of 17,201, and so is its Overlap Threshold 1e-6 → 0.01 with B on
    A's plane.
  - *Self Intersection.* A mesh's own faces in one plane were never counted:
    the BVH's self overlap misses them, and when the walk cannot ask Blender
    (a Geometry Nodes, Mesh Deform or another `_SLOW` modifier before the
    Boolean) the light bound stood. A 40 × 40 grid under a Solidify and an
    Array offset half a cell in X and Y, Exact Union with Self Intersection
    against a far cube, Count 1 → 2: 8,244 counted against Blender's
    15,556, and the row passed at 11,900. Fins of the mesh against itself
    now count them (`_coplanar_self`: a fin is not counted on its own face
    or on one that shares a vertex with its edge). Counted 34,160, refused
    at 11,900 after a Geometry Nodes modifier and after a Mesh Deform.
  - *Collection operands.* Crossed pair by pair: 400 unit cubes in one
    plane under a Union with a collection operand, one moved 0.1 through
    the row's price, took 22.16 s (Manifold) and 22.86 s (Exact) on
    6d31b90's code against Blender's own 0.01 and 0.14 s. The operands are
    now one mesh in the world with each face's operand (`_Joined`): one BVH
    against the Boolean's mesh, one self overlap and one coplanar search
    across operands, so the work grows with their faces. 0.08 s and 0.24 s.
- **The Data API row and the drivers that read what it sets.** The row's
  price judged the value alone and then let the write through approved, so
  the gate did not work the drivers out. An Array's Relative Offset Y read
  by its own Count driver (x × 2,000 + 1) and an empty's Location read by a
  cube's Count driver each built 160,008 at a budget of 100,000; a Wave's
  Narrowness read by a shape key's Value under a fitted Array, 159,976.
  `price_all` now works out the drivers that read its changes with the new
  values laid over what they read (`_readers_of`, `animation_pairs`'
  `laid`) and judges what they set with them. Where a driver only Blender
  can work out reads them (a World Space Transform Channel, Python), the
  write is not approved, and the row evaluates through the gate
  (`set_property` calls `settle`), which prices the state written and
  raises its refusal at the row. Each refused at the row, Blender as it was.
  Found by this work's own checking, the same through a move: a Move of 10
  of an empty whose X a Count driver reads (x × 40,000 + 2) passed and
  Blender built 3,200,016 — the move's price laid a matrix, which no driver
  reads, and its update was not read for drivers. So were a parent moved
  under a child read in World Space, and an empty read by a Distance
  variable. `_readers_of` now lays a matrix or Dimensions as the channels
  they set; a move's update is priced whole when a driver reads what moved
  or what follows it (`read_by_drivers`, in `_within_move`); the gate's
  drivers' inputs take in an object's children (`_inputs_of`); and a
  Distance or Rotational Difference variable reads its objects
  (`_driver_inputs`). Each refused at 3,200,016, Blender at 16, the empty
  where it was; moves of 0.0001 pass.
- **Legacy textures.** Texture data-blocks were in no list: a cube under a
  Displace (a Blend texture, Strength 20) and a Remesh at 0.5, budget
  20,000: Brightness 1 → 2 passed through the Data API row, a script line
  and a key at frame 10 on the app's timeline, Blender at 20,692 from
  1,564. The gate now compares every Texture type (`_texture_kinds`), the
  model lays a texture's changes on a copy its stand-in's modifiers read
  (`Prices.texture_like`, `_texture_props`: a Displace's, Warp's and
  Wave's Texture, the Vertex Weight modifiers' Mask Texture), `affected`
  and the frame plan reach the objects whose modifiers read one, and
  textures are among the animated data-blocks. Refused at 42,874 all three
  ways, Blender at 1,564.
- **A price that fails, found by this work's sweep.** Part 12.17 with the
  texture fixture keyed the texture's Brightness for the first time and
  called `frame_set(2)`: the price raised inside the gate ('NoneType' object
  has no attribute 'action': the new action is a change of the texture's
  AnimData, laid on a copy whose animation the price clears), and the gate
  wrote the change again and raised. In a frame's handler nothing can raise,
  so Blender evaluated it: 4,000,001 and 3,199,472 vertices under the words
  "so it was put back". `_apply` now leaves an AnimData's change off the
  copies (what an animation sets is priced as its own change), and the
  gate's judgement refuses what it could not price as it stands (the values
  as Blender evaluated them, a new modifier hidden, a new constraint off,
  the animation held off muted), as its words said. Part 12i.10: a script's
  `depsgraph_update_post` handler writing Count 400,000, priced at the
  gate's checkpoint after it with the price made to raise, is refused in
  words, the Count back at 2, Blender at 16; with the change written again
  and the error raised, as on 6d31b90, Blender's second pass built
  3,200,000.

### Checks and their controls

Part 12i (`interface3.py`), in the last run of parts 9, 11, 12 and 13 on
the final code (below): its 54 checks passed, each item's case refused as
above, and its control — the gap put back in the running modules — let it
through, or took the old time. Earlier runs of it alone
(`BUDGET_PARTS=12i`, which also runs parts 1 and 3 to 7) gave the same, at
load averages of 5 to 12 from other sessions:

- Time Stretching: with the Scene's map compared nowhere, the script line
  passed and Blender built 3,200,000. The row's Frame Map New 10, and at
  frame 2 its Frame Map Old 900 (time 18), refused; Frame Map New 50 (time
  2, the Count still 2) passed.
- F-curve modifier: with `_diff_action` as 6d31b90 had it, refused in words
  and built 3,200,000 anyway, the curve not muted.
- Nested realizing: realized one level, the line passed and Blender built
  4,000,000. Curve to Mesh: with the curve given as a mesh, the row passed
  and Blender built 3,075,000. What instances hold: with each node run on
  the top geometry alone, the lines passed and Blender built 3,200,000
  (Instance on Points on instances) and 3,960,100 (Subdivide Mesh inside
  them).
- Affect Only: with the update read for Edit Mode's points alone, Parents
  passed at 3,199,472 and Origins at 3,197,208. With only the switches
  unread, `_move_scope` refused Parents alone. A move of A 0.5 away from O
  with Affect Only Parents passed (216, the offset 1.5 m), and one with O
  following passed at 328.
- Fast: with `_near_faces` empty, the row passed at 17,201 (the light count
  7,774, sure). Two grids that cross (B 0.05 m up, turned 0.3 rad) at
  Blender's default threshold keep a sure light count; at 0.01 the same
  move is made exact by Blender and passes (4.06 s, nearly all of it
  Blender's own Fast at 0.01: 4.0 s for the same evaluation, the price's
  own work 0.07 s).
- Self Intersection: with `_coplanar_self` counting nothing, both rows
  passed at 11,900.
- Collection operands, 400 unit cubes, one moved 0.1 through the row's
  price: Manifold 0.08 and 0.09 s, Exact 0.24 s (two runs), each under 3 s
  and under a quarter of the control; crossed pair by pair (the control),
  22.16 / 21.06 s and 22.86 / 21.30 s. Blender's own evaluation 0.01 s and
  0.14 s.
- Drivers and the row: with `_readers_of` answering nothing, the row's
  Relative Offset passed and Blender built 160,008. The World Space case
  and the Wave's Narrowness refused at the row; a driver that stays small
  (x × 2 + 2) passed at 176. The Move of the empty a Count driver reads,
  refused; with the move laying nothing and its update not read for
  drivers, it passed and Blender built 3,200,016. The row's Location of a
  parent whose child is read in World Space, refused; with `_readers_of`
  answering nothing, built 3,200,016.
- A price that fails: a post handler's Count refused, Blender at 16; with
  the change written again and the error raised (12i.10's control),
  Blender built 3,200,000.
- Textures: with the texture types out of the gate's list and no texture
  read by the model, the row passed and Blender built 20,692. Brightness
  1 → 1.1 passed (2,376).

Part 12.17's sweep (`sweep2.py`) steps five more fixtures: the scene's Map
Old and Map New (FA's offset keyed 1 → 0.00001 at frame 2: time 2.24 at Map
Old 224), a cube under a Displace along its normals reading a Blend texture
at Contrast 0 (its value Brightness − 0.5 everywhere, measured not clamped)
under an Array fitted to its size (Brightness 0.25: 3,199,472), a Generator
of (0.00001, 0) on an offset's keyed X at Influence 0 (Influence 1:
4,000,001), nested instances realized (the outer Points' Count) and a
curve's Curve to Mesh profile (the Circle's Resolution). Its control with
the gate off now has to find these five as well as its ten, and 12i.9 sweeps
the five with the gate on and this round's fixes taken out, and has to find
all five. In the last run: 12.17 passed (2,471 steps in 99 s, no bypass),
its control found 15 of its 15 settings and 5 of the 5 other ways, and
12i.9 found 5 of 5.

The full budget check (`scripts/run-budget-blender-check.sh`, 51 min 12 s,
at load averages of 10 to 367 from other sessions): 506 passed, 3 failed,
and part 10's sweep (20,526 runs of 15 states) and its control passed. The
three were 12.17 (the sweep's texture keyed and `frame_set(2)`: the failing
price above), its control and 12i.9 (the Generator's coefficients, an array
the ladders do not step; the fixture now steps its Influence). With those
fixed, and with the moves read for drivers, parts 9, 11, 12 and 13 again
on the final code (with parts 1 and 3 to 7, which always run): 432 passed,
0 failed, 13 min 11 s, at load averages of 10 to 20. Ordinary edits stayed
inside their bounds: 11.1, a frame's price with 3,000 keyed empties,
0.0053 and 0.0061 ms; 11.5, Weld, Location, Thickness and a Move's commit
on a legal 399,254-vertex Boolean, 0.45 to 0.98 s against Blender's own
0.37 to 0.70 s (each under its 3 × bound); 12i.5's 400 operands, 0.11 s
(Manifold) and 0.24 to 0.30 s (Exact).

Also run, each in a sandboxed desktop 5.2.1 (two at a time beside the
budget check, at load averages of 17 to 367): objectops 371, transformops
1,635, relations 2,806, modifier 240, modkinds 982, unsafe 186, undo 101,
groups 447, opsearch 80, transformfields 406, mirror 142, freed 37 (26
cases), tools 271, points 261, undostack 27, context 67, redo 749,
objectmenu 315, meshmenu 197 passed, none failed — on the code before the
last two changes (a failing price refused; a move's update read for
drivers). Of them transformops, objectops and relations, which run Object
Mode moves, were run again on the final code: 1,635, 371 and 2,806 passed.
Host suites: run-budget-tests.sh (section 7 included) and
run-sandbox-tests.sh (39 scripts, 55 Blender launches) ALL PASS on the
final code, run-animation-tests.sh, run-animation-shim-tests.sh and
run-mirror-tests.sh ALL PASS. The animation check alone on the final code,
three times in a row with nothing else of this work running (load averages
of 7 to 10 from other sessions): ALL PASS each time; with 3,000 keyed
empties a frame took 52.0, 50.3 and 55.6 ms, of which Blender's own
`frame_set` 18.7, 17.3 and 26.4 ms (the mirror's share 33.3, 33.0 and 29.2
ms against its bound of 100), and the budget's price of the frame 0.0038,
0.0031 and 0.0033 ms.

The textures were also run for freed memory: an image texture's image
removed while Blender's copy points at it, a texture removed while two
modifiers read it, one changed and removed in a line, one's type changed,
and an Edit Mode extrude under it — 4 rounds each, 3 runs, under
MallocScribble and MallocGuardEdges in sandboxed desktop 5.2.1: no crash.

### Found, and left open

What this work left is listed in "Found after fix round 2's repairs, still
open (October 22)" below, under "The budget, reachable from the interface":
Fast's near contacts counted from a measured bound, Self Intersection's
bound, a refused Affect Only Parents move leaving the parent moved, the
cost of reading a move's update whole and of `_readers_of`, a driver that
reads an object a constraint places, a driver or key on Time Stretching,
and a keyed value written by a line.

### Crashes hit

None of this work's code. No app crash report (the newest
`BlenderLocal-*.ips` is October 22's). Of today's desktop Blender reports
while this work ran: the one at 14:25 (a Blender started by another
Blender) and the two at 14:31 (a Python parent) are other groups' controls,
and the three at 15:54 to 15:55 are the unsafe check's own unguarded
controls, run by this work (its child Blenders, exit −11 in
`append_sorted_object_parent_hierarchy` and
`BKE_object_eval_eval_base_flags`, each a PASS line of that check). Every
path below was run in sandboxed desktop 5.2.1 with the app's context
before the app ran it.

### In the app

The Debug build, Designed for iPad on this Mac (`xcodebuild`: BUILD
SUCCEEDED; its 32 bundled `_blenderkit_*.py` byte for byte the tree's). Each
launch below was run on the final build, and all but the nested instances
and the gizmo with a driver on earlier builds of this work, with the same
outcome. Each started from the user's own autosave, put back before it: the
app writes its autosave as it runs, and a first series of launches picked up
the last one's names (a texture `TDT` already in the file, so the row edited
an unused one). An `-eval64` script made the fixtures, then the hooks:

- `-data-api`, the Data API row's field as it sends its edit: Frame Map
  New 10 under the keyed Count, refused at 3,200,000, Blender at 16; E's
  Relative Offset (1, 10, 0) read by its Count driver (x × 40,000 + 1),
  refused at 3,200,008, Blender at 8; TD's texture Brightness 0.25, refused
  at 3,199,480, Blender at 168; the Circle's Resolution 30 → 3,000 under a
  curve's Curve to Mesh, refused, Blender at 30,750; the re-check's texture
  case at a budget of 20,000, Brightness 1 → 2, refused at 42,874, Blender
  at 1,564; at a budget of 11,900, Fast's Overlap Threshold 1e-6 → 0.01
  with B tilted on A's plane, refused (counted 113,624), Blender at 3,878,
  and Count 1 → 2 under Self Intersection after a Geometry Nodes modifier,
  refused (33,488), Blender at 3,370. Each with the banner.
- `-transform-ops`, the gizmo's drag and commit, with Affect Only Parents
  and Origins on (`_blenderkit_tools.set_tools`, as the Options popover
  sends them): A's Move 0.9999 with its child O left in place, refused in
  the banner ("Move would give A 3,199,480 vertices…"), nothing sent; a
  Move of −0.5 then, passed. `-opsearch transform.rotate` (value 1.5708,
  Z), the thin cube with Affect Only Origins, refused at 2,983,968.
- `-object-ops py:`, Run Script, each line followed by a capture of what
  Blender holds: `scene.render.frame_map_new = 10`, refused, A at 16 and Map
  New back at 100; a Generator of (400,000, 0) on the keyed Count, refused,
  A at 16, the curve muted; the nested Realize Instances, refused at
  4,000,000, NR at 8 with its modifier hidden; TD's texture Brightness
  0.25, refused, TD at 168.
- `-object-ops py:` again, instances' own geometry: Points (1,000) →
  Instance on Points (Grid 20 × 20) → Instance on Points (Cube) → Realize,
  refused (counted 9,600,000), NI1 at 8 with its modifier hidden; Points
  (100) → Instance on Points (Grid 100 × 100) → Subdivide Mesh (1) →
  Realize, refused at 3,960,100, NI2 at 8; the same as the first at Points
  10 and Grid 3 × 3, passed, Blender at 720.
- `-transform-ops` again, the gizmo's Move of 10 of an empty whose X a
  Count driver reads (x × 40,000 + 2): refused in the banner ("Move would
  give A 3,200,016 vertices…"); a Move of 0.0001, passed.
- `-frames 10`, the timeline (`TimelineDriver.setFrame`), the texture's
  Brightness keyed 1 → 2 at frame 10 at a budget of 20,000: NOT SENT, the
  timeline at frame 1.
- Run Script lines calling the row's `set_property` on one of 400
  collection operands: 326 to 604 ms each over four launches (the line, its
  undo step and the mirror's pass of 401 objects; the higher ones with the
  budget check running beside), against Blender's own evaluation of the
  move, 60 to 91 ms.

After each launch the app was killed. `autosave.blend`, `.blend1`,
`.partial1`, `Scripts/.draft.py`, `.blender-history` and the app's
preferences were put back, and their checksums and the three scenes'
matched the backup.

## October 29, fix round 3: the gate's reads of freed memory, `scene.new` in an override, the window's own scene, and the guards' closures

This entry closes the crash list of "Found after fix round 2's repairs,
still open (October 22)" below: the gate reading freed memory (critical),
`bpy.ops.scene.new(type='FULL_COPY')` and `'LINK_COPY'` inside a
`temp_override` that sets a view layer (critical), `_original_pointer`
(high), the internal error when the window's own scene is removed, and the
raw functions in the guards' closures (low). Each was measured in sandboxed
desktop 5.2.1 with the app's context, under MallocScribble where the bug is
a read of freed memory, beside a control that crashes or fails on
6d31b90's code. The work also found, and closes, more crashes of the same
kinds: an image or a font removed while Blender's copies point at them, New
Sequencer Scene and Delete in such an override, and the window given another
scene inside one. It also closes three budget bypasses it found. Files:
`_blenderkit_gate.py`, `_blenderkit_context.py`. Tests:
`tests/budget/blender/freed.py` with its driver `freed_drive.py` and
`scripts/run-freed-blender-check.sh` (new); new cases in
`tests/unsafe/blender/verify.py`; one control in
`tests/budget/blender/gate.py` (9.5g), which now leaves Edit Mode with the
gate off; `tests/budget/main.swift`, which holds the new wrapper to the
gate; and `tests/sandbox/check.py`, which now counts a driver that sandboxes
each Blender itself.

Three attempts at this work were cut off by a usage limit before any
reported. A fourth pass verified what they left on the final code (every
figure under "Checks and their controls" and "In the app" is its own), and
corrected what did not hold. It found and closed one more crash of the
window's-scene kind: the window given another scene inside such an
override, then `context.evaluated_depsgraph_get()` or
`context.view_layer.update()`, which no operator guard sees
(`_held_to_scene`). It found the budget check's whole run stopping on an
internal error at part 11, on 6d31b90's code as on this round's: a text's
Texture Space, which Blender works out itself, read as a write
(`_derived`). It added `bmesh_modifiers` to `freed.py`.

### What closes each item

- **The gate read freed memory** (critical, ordinary use). Blender does not
  copy a mesh, curve, lattice, metaball or armature again while it is in
  Edit Mode. It points the evaluated copy at the original's edit data
  (`update_edit_mode_pointers` in deg_eval_copy_on_write.cc). Leaving Edit
  Mode frees that data, a mesh's BMesh among it. The copy keeps pointing at
  it until the evaluation that comes after depsgraph_update_pre, where the
  gate runs. RNA reads a mesh's `attributes` through that pointer whenever
  it is set (rna_attribute.cc), and that was the crash. The gate now reads
  nothing of a copy whose `is_editmode` is set (`_holds_edit_data`). That
  read looks only at whether the pointer is set, and so do the lengths of a
  mesh's elements. Such a mesh is compared with what the gate last priced
  of its Edit Mode instead (`_diff_left_edit`, against `_edit_mesh_states`).
  That state is now also taken as the mesh enters Edit Mode (`_post`,
  `_entry_state`, through `Object.to_mesh`, so nothing is added to
  `bpy.data` in the middle of an update). Curves, lattices and metaballs were
  already compared that way (`_edit_snaps`).
  - The variants, each a case of `freed.py` (6 rounds, MallocScribble and
    MallocGuardEdges, a Blender of its own each): Geometry Nodes, a Bevel
    limited by Weight, a Remesh, an Array fitted to a length and a
    Subdivision, each with Extrude; Subdivide, Delete, Add Cube, Bevel,
    Merge by Distance, Resize and Deselect under Geometry Nodes; the toggle
    instead of `mode_set`; Undo and Redo across the leave; Edit Mode
    straight to Sculpt, Vertex, Weight and Texture Paint; a script's bmesh
    edit, told and untold, under Geometry Nodes and (the fourth pass's
    `bmesh_modifiers`) under a Subdivision, a Remesh, a Bevel and an Array;
    curves, lattices, metaballs, text and armatures; the edited object and
    mesh removed in Edit Mode. On 6d31b90's code 8 of these crashed, and so
    did three cases described below (the Bevel
    Weights by a script line and by bmesh, and leaving with nothing
    changed), all in `Mesh_attributes_begin` under `_diff_attributes`. Now
    none does.
  - The guarantee the attribute read gave is kept: Bevel Weights of 1
    written by a script line on a 120 × 120 grid under a Bevel limited by
    Weight at 14 segments are refused in words, after six Edit Mode round
    trips, and Blender stays at 14,641.
  - Two bypasses through the leave are closed. On 6d31b90's code the leave's
    update skipped the vertices of a mesh just out of Edit Mode
    (`_edit_meshes_then`). A script line's bmesh edit that told Blender
    nothing, followed by `mode_set(mode='OBJECT')` in the same line, built
    1,600,008 vertices at a budget of 100,000: a cube under an Array fitted
    to 40, scaled to a ten-thousandth. That line is refused in words now, and
    Blender stays at 8. Bevel Weights set the same way built 3,193,369 with
    the leave's comparison taken out. On 6d31b90's code that case crashed
    instead. It is refused in words now.
  - Leaving Edit Mode with nothing changed prices nothing: 0 prices in 6
    round trips. With the entry state taken out (the control), it priced
    every leave.
- **Data-blocks Blender does not copy, freed while a copy points at them**
  (new: two crashes found by the variants, plus the item's own). Images,
  fonts, brushes, palettes, screens, workspaces, window managers, libraries
  and paint curves have no evaluated copy (`ID_TYPE_USE_COPY_ON_EVAL`).
  Blender's copies point at the originals themselves, and removing one
  remaps only the originals' pointers. Two cases segfaulted the gate's next
  read of a copy on 6d31b90's code: an image removed from an image empty, a
  custom property and a driver; and a text's font removed. Both crashed in
  `pyrna_prop_to_py` under `_diff_struct`. With that fixed, the image case
  segfaulted one step earlier, in `update.id`. The depsgraph still lists
  the freed image's node, whose "copy" is the freed image, until it
  rebuilds after depsgraph_update_pre. Freeing a data-block tags its type
  on every depsgraph until that depsgraph evaluates (`DEG_id_type_tag` in
  `id_free`), and the remap tags each user for a new copy then. So:
  - such a pointer of a copy is read only while
    `Depsgraph.id_type_updated` says no data-block of its kind changed since
    that depsgraph last evaluated (`_pointer_readable`). Otherwise it counts
    as changed, with nothing to put back, and is priced as it is. An empty's
    image is not compared at all, since it makes no vertex;
  - the copy's custom properties are not read in that window
    (`_diff_custom`): Python cannot ask a property's type without converting
    it, and converting reads the data-block. They count as set with nothing
    before them, so the drivers that read them are worked out;
  - while one may be freed, `pending` wraps only the listed addresses that
    are copies of live originals the gate reads (`_updates`). This costs
    2.8 to 3.8 ms for 6,006 data-blocks, and only in that window: an image's
    pixels written, or `image.update()`, do not open it (measured).
    Blender's own iterator still reads the freed block's update flags (four
    bytes) as it goes. The gate cannot keep it from that.
- **`bpy.ops.scene.new(type='FULL_COPY')` or `'LINK_COPY'` in an override**
  (critical). The precondition is a `view_layer` in the override in force
  when an operator gives the window another scene. `scene.new` copies the
  window's scene, whatever the override's scene is, and makes the copy the
  window's (`ED_scene_add`). Setting the window's scene clears the
  override's `scene` (`CTX_data_scene_set`) and keeps its `view_layer`.
  Blender's own update after the call then evaluates the new scene with
  another scene's view layer. Swept in bare 5.2.1 under MallocScribble, each
  call in a Blender of its own: 19 `scene.` operators (Full Copy, Linked
  Copy, New and Copy Settings of `scene.new` among them) and 5 `workspace.`
  ones, each inside `temp_override(scene=<a new scene>, view_layer=<its
  own>)` and `temp_override(scene=<the window's>, view_layer=<its own>)`,
  and the crashing ones also with `scene` alone and with `view_layer` alone.
  These crashed:
  - Full Copy and Linked Copy with a new scene and its view layer, in
    `deg_update_eval_copy_datablock`;
  - New and Copy Settings with the window's scene and its own view layer,
    in `BKE_object_eval_eval_base_flags`;
  - New Sequencer Scene, in the same frame;
  - Delete of the override's scene, in the depsgraph's build from its freed
    view layer.

  With `scene` alone in the override nothing crashed. The other 21
  operators crashed in neither shape. Not swept: the rest of the Freestyle
  operators (four were), `scene.freestyle_module_open`, the two preset adds,
  `scene.gltf2_action_filter_refresh`, `workspace.add` and
  `workspace.append_activate`, which read or write files or open a menu.

  `scene.new`, `scene.new_sequencer_scene`, `scene.delete` and
  `scene.drop_scene_asset` (`SCENE_SWITCHES`) are now refused in words while
  an override in force sets `view_layer` (`_SceneSwitch`). Elsewhere they
  are Blender's. With the app's context, 10 of the swept operators (these
  four among them) in 4 shapes each (40 runs, MallocScribble) gave the
  refusal or Blender's own result, and none crashed. One more crash of the
  same kind was found and closed: inside
  `temp_override(scene=<the window's>, view_layer=<its own>)`, a script
  line giving the window another scene, then any operator. It crashed
  6d31b90's guarded Blender in `BKE_object_eval_eval_base_flags`, because an
  override in force held its view layer to the override's own scene. It is
  now held to the scene Blender's context reads (`_first_refusal`), and
  refused in words. The verification of this entry found the same line
  followed by a call that is not an operator crashing past that guard,
  which only operators ask: `bpy.context.evaluated_depsgraph_get()` and
  `bpy.context.view_layer.update()` each exited 139 in
  `BKE_object_eval_eval_base_flags` (desktop 5.2.1 with the app's context,
  MallocScribble). An override in force that sets `view_layer` is now also
  watched for that (`_held_to_scene`, beside `_held_by`): before every call
  and context read, its view layer is held to the scene Blender's context
  reads. When the window was given another scene, the override is left and
  the call refused in words, as for a member the block freed. Probed after
  it, each in a Blender of its own under MallocScribble:
  `evaluated_depsgraph_get()`, `view_layer.update()`, `frame_set`, Add Cube,
  `select_set` and `visible_get` after the line are refused, and the line
  alone ends with the window on the other scene and nothing said. A Python
  call inside such an override costs 1.4 to 1.5 µs with this, against 1.0
  without it (load average about 30).
- **`_original_pointer`** (high). It is gone. The animation signature reads
  the copy's own pointers (an action's copy is the depsgraph's, alive until
  its next rebuild), and maps the original's through the depsgraph
  (`_block_key`, `_address`). A driver target of a kind Blender does not
  copy is not read from the copy while one may be freed (`_Unknown`, which
  counts the driver as changed). Measured by counting, under MallocScribble,
  in 30 rounds of a script line removing an assigned action and the mirror's
  pass: 6d31b90's code read the `original` of 90 copies whose originals
  were freed. This code reads none, because no `original` is read anywhere
  in the gate. Part 13.7 of the budget check, the frame plan kept when a
  handler writes on every frame (the reason the function was added),
  passes.
- **Removing the window's own scene** showed "The vertex budget could not
  price this change ('ID' object has no attribute 'frame_current')". Blender
  gives the window another scene and starts its frame
  (`ED_scene_change_update` → `ED_update_for_newframe`) on a depsgraph built
  that moment. Its copies are not made yet: each is an empty block that RNA
  types as a bare ID. The gate read the frame of one. A depsgraph whose
  scene copy is such a block now counts as never evaluated
  (`_never_evaluated`, `_shell`), and everything it is about to evaluate is
  priced as new (`_fresh`). It works as Blender does: the window shows the
  other scene, with nothing said. That fixed two bypasses with it. On
  6d31b90's code, the other scene holding a cube under an Array of 400,000
  was built at 3,200,000 with the internal error. Giving the window a
  scene whose depsgraph was evaluated, with such a cube linked to it since,
  built 3,200,000 with nothing said. A copy not made yet is now new to the
  gate (`_unevaluated`). Both are refused in words, and Blender stays at 8.
- **The raw functions in the guards' closures** (low). The closures of
  `bpy.ops._op_create_function` (also `_bpy.ops.create_function`),
  `_bpy.ops.macro_define` and `Context.temp_override` held Blender's own
  functions. They now hold a `_Sealed` instead. It calls the function only
  for `_blenderkit_context`, read from the caller's globals as
  `_module_only` reads them, and its slot is that module's only. Called
  from a script it raises a TypeError in words, and `._inner` raises an
  AttributeError. The unsafe check holds this. On 6d31b90's code all 4
  cells held `builtin_function_or_method` or `method_descriptor`. Still
  open, as before: `gc.get_referents` of the holder, the slot's descriptor
  in `_module_only`'s closure, frames, and ctypes.

### Checks and their controls

Three earlier attempts at this entry were cut off before they reported. A
fourth pass checked what they left, ran every check below again, and
corrected what did not hold (the figures here are its own; each says which
code it ran on where that is not the final code). Other work on this Mac while it ran: three renderer processes of
another app at about 100% CPU each and an iOS Simulator app that were not
this work's, so load averages were 10 to 40.

- `scripts/run-freed-blender-check.sh` (new; `tests/budget/blender/freed.py`
  and `freed_drive.py`): 26 cases, each in a Blender of its own under
  MallocScribble=1 and MallocGuardEdges=1, 6 rounds each. Run four times:
  the 25 cases as the attempts left them, the 26 twice over after
  `_held_to_scene`, and the 26 on the final code (103 Blenders): 0 failed,
  13 to 29 s a run. The review's own `uaf.py` (6 rounds,
  MallocScribble and MallocGuardEdges, on the attempts' code) survived all
  6 leaves, Blender at 3,721 → 238,144. Control, the same with `BK_SITE` at 6d31b90's modules:
  16 of 26 fail. 13 crash (11 in `Mesh_attributes_begin` under
  `_diff_attributes`, 2 in `pyrna_prop_to_py` under `_diff_struct`), and 3
  fail their price: the untold bmesh edit left in the same line (Blender at
  1,600,008), the window's scene removed (the internal error, and
  3,200,000), and the window given a scene with a new heavy object
  (3,200,000). The 26th case, `bmesh_modifiers`, is the fourth pass's: an
  untold and a told bmesh edit, then the leave, under a Subdivision, a
  Remesh, a Bevel, an Array and Geometry Nodes, which sends the budget's
  `_held_count` to Blender's evaluated object while it holds the freed edit
  mesh's wrapper. It passes, and crashes on 6d31b90's code. Two more
  controls each take one repair out of a copy of this round's modules: the
  leave comparing nothing fails the bmesh case (1,600,008) and the Bevel
  Weights case (3,193,369); no state taken as Edit Mode is entered fails
  "leaving with nothing changed prices nothing" (6 prices).
- `scripts/run-unsafe-blender-check.sh`: ALL PASS (186 checks). New: six
  cases, each guarded and unguarded in a Blender of its own. They are Full
  Copy, New and Delete inside an override that sets `view_layer`, and the
  window given another scene inside one, then Select All,
  `context.evaluated_depsgraph_get()` or `context.view_layer.update()` (the
  last two are the fourth pass's). Each is refused in words guarded.
  Unguarded under MallocScribble, each crashes in its frame
  (`deg_update_eval_copy_datablock`, `BKE_object_eval_eval_base_flags`,
  `build_view_layer`, and `BKE_object_eval_eval_base_flags` for the three
  others). Also new: `scene.new` and `scene.delete` get `_SceneSwitch`
  however their module is spelled, and "no wrapper's closure holds the
  function it wraps" (4 cells, each refused called and opened). Controls:
  with `BK_SITE` at 6d31b90's modules the check fails 8: the spelling
  check, the closure check (all 4 cells holding Blender's functions), and
  the six new cases guarded, five of them exit -11 (Delete ran). With
  `_held_to_scene` taken out of a copy of the final modules, it fails
  exactly the last two, guarded, each exit -11.
- The scene sweep again, with the app's context under MallocScribble, each
  call in a Blender of its own: Full Copy, Linked Copy, New and Copy
  Settings of `scene.new`, New Sequencer Scene, Delete, Add and Remove View
  Layer, Duplicate Workspace and Pin Scene, each inside
  `temp_override(scene=<another>, view_layer=<its own>)`,
  `(scene=<the window's>, view_layer=<its own>)`, `(scene=<another>)` and
  `(view_layer=<the window's>)` (40 runs): no crash. The four switches are
  refused wherever `view_layer` is set, and run as Blender's with `scene`
  alone.
- `scripts/run-budget-blender-check.sh` parts 9, 12 and 13 (on the
  attempts' code): 339 passed, 0 failed. One control of part 9 (9.5g) now leaves Edit Mode with the gate
  off. Its gate-off bmesh edit had been left for the gate to find, and
  since this round the leave prices it, refused in words. Part 13.7, the
  frame plan kept when a handler writes on every frame (`_block_key`),
  passes. Before `_derived`: parts 8 and 11 together, 219 passed, 0
  failed, and the same on 6d31b90's tree; part 11 alone, 136 passed, 0
  failed (its timing bounds held at load averages of 11 to 24). The whole check (all
  13 parts and the sweep) on the final code: 461 passed, 0 failed, the sweep
  and its control PASS (35 min 51 s, load average 5 to 27). Before
  `_derived`, parts 1 to 8 then 11 stopped at part 11's first mirror pass
  on the internal error about a text's Texture Space, and so did 6d31b90's
  tree, run beside it.
- The operator sweep (part 10, `opdrive.py`) under MallocScribble=1 and
  MallocGuardEdges=1, on the attempts' code: 20,526 runs on 15 states in 62
  s, PASS: none grew
  Blender past the budget, crashed, hung or ran past its time. Its control
  (the gate off), also under scribbling, found 110 runs growing Blender,
  PASS.
- `_original_pointer`, counted again (30 rounds of a script line removing an
  assigned action, then the mirror's pass, under MallocScribble): 6d31b90's
  code read the `original` of 90 copies, all 90 freed; the final code reads
  none.
- Edit Mode costs nothing more: on a 90,601-vertex grid in Edit Mode, the
  attempts' code interleaved with 6d31b90's modules (2 runs of 5 each, load average 15 to
  19), a Move and its evaluation took 56 to 62 ms against 57 to 71 under a
  Subdivision and an Array of 2, and 30 to 36 against 32 to 54 under
  Geometry Nodes; Merge by Distance 164 to 174 against 163 to 184, and 108
  to 118 against 110 to 120.
- `scripts/run-context-blender-check.sh`, `run-guards-blender-check.sh` and
  `run-modeguard-blender-check.sh`: ALL PASS, run again after the last
  change to `_blenderkit_context.py`. Also ALL PASS:
  the undo, undostack, redo, objectops, relations and points checks (on the
  code before `_derived`), and texpaint, vwpaint, mirror and animation (on
  the final code); the host suites cuttools, meshmenu, redo, objectops,
  scriptthread and selectpick (before `_derived`). The sculpt check, 10 runs
  on the final code: 6 passed. 3, run three at a time beside one on
  6d31b90's tree (load average about 33), failed only its 80 ms bound on a
  stroke's chunk (83 to 300 ms; 6d31b90's run beside them, 88.8). 1, run
  beside the budget check (load average 8 to 11), failed "Undo: the level
  back" and "Redo: the Grab again" of a Multires Grab, which no other run
  repeated (still open, below).
- `scripts/run-sandbox-tests.sh`: ALL PASS, 39 scripts, 55 launches. The checker now
  counts a Python driver that gives each Blender a HOME and resources of its
  own as a sandboxed launch. Before, a script whose only launch was such a
  driver read "no launch found". Its own control: a driver that does not is
  still caught.
- `tests/budget/main.swift`: `_SceneSwitch` is held as `_Unsafe` is: it
  calls `_UndoInArea`, which calls inside the gate's `_calling`.
  `run-budget-tests.sh`: ALL PASS (1 min 27 s on the final code).
- Probed and not crashing, so no guard: a user's `frame_change_post`
  handler removing an image that a `frame_change_pre` handler had written,
  before the app's own `collect` reads `update.id` there (4 frames, under
  MallocScribble). Blender does not list images in a frame's updates.

### Crashes hit

No app crash. Every crash below was in sandboxed desktop 5.2.1, each in a
Blender of its own, before the code it led to was run in the app:

- Found by the variants, on 6d31b90's code: an image or a font removed
  while Blender's copies point at it, then the mirror's pass, exit 139 in
  `pyrna_prop_to_py` under `_diff_struct`. Guard: `_pointer_readable`, and
  `_diff_custom` in that window.
- Found after that guard: the same image case exit 139 in `update.id` under
  `pending`. Guard: `_updates`.
- Found by the scene sweep, in bare Blender: `scene.new` (all four types),
  `scene.new_sequencer_scene` and `scene.delete` inside an override that sets
  `view_layer` (the frames above). Guard: `_SceneSwitch`.
- Found next to it: the window given another scene by a script line inside
  `temp_override(scene=…, view_layer=…)`, then Select All, exit 139 in
  `BKE_object_eval_eval_base_flags`, in bare Blender and with 6d31b90's
  guards. Guard: the view layer held to the context's scene as it is now
  (`_first_refusal`).
- Found by the fourth pass, with the first three attempts' guards: the same
  line, then `bpy.context.evaluated_depsgraph_get()` or
  `bpy.context.view_layer.update()`, exit 139 in
  `BKE_object_eval_eval_base_flags` (MallocScribble). Guard:
  `_held_to_scene`, asked before every call and context read while the
  override is in force.
- The controls, on purpose: `freed_drive.py` on 6d31b90's modules (13 of its
  cases crash there), the unsafe check's unguarded runs of its six new
  cases, and its guarded runs with 6d31b90's modules and without
  `_held_to_scene`.

### In the app

The fourth pass's Debug build, Designed for iPad on this Mac (`xcodebuild`:
BUILD SUCCEEDED, 41 s for the last build; the bundled `_blenderkit_gate.py`,
`_blenderkit_context.py` and `_blenderkit_budget.py` byte for byte the
tree's). Each script was run in sandboxed desktop 5.2.1 with the app's
context first, under MallocScribble (the grid's path once, the script lines
three times). Two launches, through the
shipped Swift paths, each run on the build with `_held_to_scene` and again
on the final build (with `_derived`), the same both times:

- **The review's use-after-free**: `-eval64` made the 61 × 61 grid under a
  one-node Geometry Nodes group, then `-object-ops` pressed Edit Mesh,
  Select All, Mesh ▸ Extrude (the row's `extrude_region_shrink_fatten`)
  and Done three times, then Undo and Redo across the last leave, Edit and
  Done with nothing changed, and Edit, Select All, Extrude, Undo, Done.
  Blender held 3,721 → 7,442 → 14,884 → 29,768 vertices, evaluated the
  same, the Geometry Nodes modifier there; 29,768 after the Undo and Redo
  and after the last round. No banner, no crash.
- **Script lines** (`-eval64`, one Run Script of 67 lines): Full Copy and
  Linked Copy inside `temp_override(scene=<another>, view_layer=<its own>)`
  refused in words ("bpy.ops.scene.new was not run: it gives the window
  another scene…"); inside `temp_override(scene=<the window's>,
  view_layer=<its own>)`, the window given another scene, then Select All,
  and again then `context.evaluated_depsgraph_get()`, each refused in
  words; `_op_create_function.__closure__[0].cell_contents('uv', 'stitch')`
  a TypeError in words and the macro holder's `._inner` an
  AttributeError; an image, a font and an assigned action removed while
  Blender's copies point at them, each then evaluated; the window's own
  scene removed, the window then showing the other, and a cube added
  there. Then a second line (`-object-ops py:`) made a scene holding a
  cube under an Array of 400,000 and removed the window's scene: refused in
  words on the banner ("Run Script: Adding H to the scene would give H
  3,200,000 vertices, and this app stops at 2,500,000…"), the window
  showing that scene, Blender at 8. No internal error, no crash.

No crash report from the app (the newest `BlenderLocal-*.ips` is October
22's). After each launch the app was killed. `autosave.blend`, `.blend1`,
`.partial1`, `Scripts/.draft.py`, `.blender-history` and the app's
preferences were put back, and their checksums and the three scenes'
matched the backup.

## October 21, fix round 2: the review of frame changes and Boolean pricing answered

The review of "frame changes and a legal Boolean, priced in proportion to
what changes" (below) measured eleven critical defects, a high and a
medium, in sandboxed desktop 5.2.1 with the app's context. Each is closed
here and measured again with the review's own case, through the path it
named, beside a control that builds the review's count or puts the old
code back. Four more defects were found on the way, and they are closed too.
One app crash happened; it is described under "In the app". Files:
`_blenderkit_budget.py` and two small changes to `_blenderkit_gate.py`.
Tests: `tests/budget/blender/review13.py` (part 13 of
`run-budget-blender-check.sh`, `BUDGET_PARTS=13` alone), and part 11's
"plan kept" control now also keeps the gate from telling the plan.

### What closes each finding

- **A Boolean's faces in one plane** (critical). The light count took a
  Boolean's crossings from a BVH, and Blender's triangle test takes
  coplanar triangles as not meeting. `_crossings` now looks for faces of the
  mesh and an operand that lie in one plane (`_coplanar_faces`: offsets
  within 1e-5 of the scene's size by a sorted chain, which misses no pair,
  and normals in one 0.001 cell of four shifted grids), and stands a thin
  quad on each of their edges (`_fins`). A fin that meets a face of the
  other mesh counts one vertex (half the face's sides for a face that is
  not convex), both ways round. Where any meets, the walk is `unsure` and
  `_final` makes the count exactly as before the reviewed change. The fins'
  count is then the bound Blender is asked inside of. More than 400,000
  candidate faces are refused in words.
- **Self Intersection** (critical). With Exact and Self Intersection on,
  each mesh's own crossing pairs are added (`BVHTree.overlap` with itself,
  which leaves out faces sharing an edge), and the walk is `unsure`.
- **A frame_change_post handler's change** (critical). Whenever the gate
  finds a change waiting (`_blenderkit_gate._run`), it tells the plan
  (`note_pending`). The plan is made again unless every change is a number
  it reads nothing of (`_plan_neutral`). Excluded from that are pointers,
  animation, the scene's settings, switches and kinds, and anything a
  static bound was made from (`plan.static`). A post handler's write is
  found by the gate's checkpoint after it, in the frame's second pass, where
  no `depsgraph_update_post` fires.
- **A script line the gate refuses** (critical) is found the same way. In
  this tree the gate also mutes the new F-curve when it refuses, so the
  review's 160,000 was not reached before this either. The plan was kept
  all the same, and that is now measured.
- **The scene's frame in a driver** (critical). A Single Property or
  Context Property variable reading the scene's `frame_current`,
  `frame_subframe`, `frame_float` or `frame_current_final` reads the frame
  being priced (`_frame_value`).
- **A value read through another path** (critical). F-curves, drivers and
  driver variables are keyed by where the value is: the data-block that
  holds it and its path from there (`_target_key`). So `parent.location[0]`
  is the parent's `location` at 0, and `modifiers[0].count` is
  `modifiers["Array"].count`. A variable whose value an NLA strip or a
  blended action sets is read from Blender (`probed`).
- **Drivers that read each other** (critical). The plan finds such cycles
  (`_cyclic`, Tarjan's walk) and takes them, and every driver that reads
  one, out of what it works out (`plan.cycles`). A frame where Blender would
  evaluate them is refused in words when one of them reaches a priced value.
  That is when one reads the frame or an animated value. Blender does not
  break the cycle: measured, Count = n × 2 and n = Count doubled the Count
  on every frame.
- **NLA and blending** (critical). The NLA strips were already read from
  Blender's own evaluation (`probe_values`, "the gate's review answered").
  This change adds the active action blended over its NLA (not Replace, or
  an influence under 1). The plan's own value is now dropped on every probed
  path, whatever the probe found. Both of the review's cases are refused.
- **Time Stretching** (critical). F-curves, drivers' `frame` and the static
  bounds use the scene's time, `t × Map Old / Map New` (`_when`). Measured:
  at Map Old 100, Map New 1, frame 5, a driver's `frame` read 500. The
  gate's `animation_pairs` uses it too.
- **Keyed Geometry Nodes** (critical). A modifier's keyed input
  (`modifiers["GeometryNodes"].properties.inputs.Socket_2.value`) was
  already counted, since the gate's review counts Geometry Nodes
  (`_blenderkit_nodecount`). The node groups an object's modifiers run, and
  the groups inside them, are now among the plan's blocks
  (`_modifier_trees`), so a group's own keyed socket is priced.
- **A collection's operand moved** (critical). A copy's modifier reading a
  collection whose objects a change reaches now reads a collection of
  their stand-ins (`_collection_stand_in`), kept out of every scene. A
  collection's operands are also crossed with each other, as Blender joins
  them.
- **Rigs** (high). A bone's channels are left out of the plan unless
  something the armature reaches reads where vertices are
  (`_reaches_shapes`), or a static bound says they could take a vertex past
  `STATIC_REACH` (`_pose_reach`: down each bone's chain, scales multiplied,
  locations and rest places added). A priced F-curve is found where the plan
  found it in its bag (`_Entry.slot`, checked by path and index), not by
  `fcurves.find`. The F-curve itself is still never kept between frames.
- **A keyed value Blender clamps** (medium). A keyed number is compared as
  Blender stores it, clamped to RNA's hard range (`_within`).
- **Found while measuring: the gate saw animation change on every frame.**
  The gate's `_animation_signature` compared an evaluated copy's action
  pointer, and that action is a copy too. So every animated object a frame
  updated read as "animation changed". Measured: a keyed empty's copy held
  an action at another address. It now compares the originals'
  (`_original_pointer`). Without this, the plan was made again on 31 of
  32 frames with a post handler writing a cube's place.
- **Found while measuring: a driver failing mid-frame.** A priced driver
  that could not be worked out on a frame (a division by zero, a target
  gone), and every driver reading it, was left out. It is now read from
  Blender's own evaluation of the frame (`plan.failed`, probed).
- **Found while measuring: the price's copies kept their animation.** A
  copy of an object, a mesh or its shape keys kept the original's action
  and drivers, and Blender worked them out again at the frame it was on,
  over the values the price laid. Measured (part 13.5): a shape key's Value
  driven by an empty's keyed X, under an Array fitted to 2 m, priced at
  frame 10, was evaluated at frame 1's value on the copy. The frame passed
  and Blender built 159,976 against a budget of 100,000. Each copy's
  animation is now cleared (`_still`). What the animation sets is laid as a
  change of its own (`price_frame`, the gate's `animation_pairs`).
- **Found while measuring: normals went to the world the wrong way.** A
  face's normal was taken through the matrix's inverse transposed, as
  columns, where rows need the inverse itself. A turned object's sideways
  faces then had wrong planes. They are now taken through the matrix's
  cofactors, with no LAPACK call. Measured (part 13.1): two grids standing
  and turned 30°, B half a cell along A's plane. The light count was 11,748
  that way against Blender's 12,846, and is 42,695 now.
- **Found while writing the tests: a shadowed name.** The plan's key cache
  was called `keys`, the name the plan also uses for a mesh's shape keys.
  With a shape key and a driver in the scene, a frame's plan raised a
  TypeError. Part 13.5's driven shape key case finds it (the revert below).

### Measured

All in sandboxed desktop 5.2.1 with the app's context. The review's cases
were measured before the change on this tree (all passed as the review
said; the NLA cases were already refused), and again after.

- **The review's cases, before** (this tree when the work started, the
  review's figures in brackets where they differ):
  - Faces in one plane, N = 40, B half a cell over and lowered onto A's
    plane: light count 6,724 against Blender's 12,846 (Manifold), 6,724
    (Exact, which makes nothing new there) and 11,421 (Fast). With B turned
    30°: 7,780 against 14,883 (Manifold) and 20,012 (Exact). N = 150,
    Manifold: 91,204 against 180,156 (the review's grids: 92,328 against
    208,628). Every one passed a budget set between the two.
  - Self Intersection, a comb of 10 plates under an Array turned 90°, Count
    1 → 2: 4,008 against 8,272. A collection's comb lowered through
    another: light and exact both 4,008, against 8,272 (Exact) and 8,000
    (Manifold).
  - Frames, budget 100,000: a post handler's Array passed frame 30 (Blender
    160,008). A frame-reading driver passed frame 10 (160,000), through a
    Context Property too. `parent.location[0]` passed (160,000), and
    `modifiers[0].count` too (163,840). The cycle passed every frame from 2
    to 15 (64 to 524,288 vertices; stopped there). Time Stretching passed
    frame 5 (160,000). A group's keyed Grid passed (1,000,000). The NLA
    cases and the modifier's keyed Geometry Nodes input were already
    refused (the gate's review). After a refused script line the plan was
    kept, and the gate had muted the new F-curve.
  - A cube under an Armature of 300 keyed bones: 12.95 ms a frame, against
    10.90 for every F-curve as before the plan; at 600 bones, 40.65 against
    21.96. Blender's own frame took 1.23 and 3.32 ms. A Count keyed to 0
    after a 200 × 200 Boolean: 8 of 8 frames priced, median 124 ms.
- **After** (part 13 run alone before its turned-grid check and the last
  two changes below, 70 passed, at a load average of about 20 from other
  work on the Mac; on the final code 71 passed, with the same counts):
  - Faces in one plane, N = 40: light counts 26,823 (Manifold, Exact) and
    26,604 (Fast), each at least Blender's; turned 30°, 34,051. N = 150:
    264,032 against 180,156. The Data API row's Location is refused at a
    budget between the old light count and Blender's (the review's own
    budget of 150,478 included), and passes at 1.6 times Blender's count,
    where the count is made exact. A Boolean of crossing grids with no face
    in another's plane stays light (11.5 holds its time, below).
  - Self Intersection: 19,048 against 8,272, refused at 6,140. The
    collection: light 14,852, exact 8,272 (Exact) and 8,000 (Manifold),
    refused at 6,140 and 6,004.
  - Every frame case is refused before Blender evaluates it, the frame left
    where it was, each beside Blender's own count past the budget. The cycle
    is refused at frame 2 in words, and Blender's own frames double the
    Count past the budget by frame 13.
  - The rig: the plan leaves its 3,000 channels out, and a frame's price is
    0.075 ms. Under a Remesh they are priced, and a frame's look at them
    took 7.25 ms where searching the bag took 16.51. The clamped Count: 0 of
    8 frames priced. With 3,000 keyed empties and a post handler writing a
    cube's place every frame, 32 real frames through `anim.frame_set` made
    the plan 0 times.

### Checks

- **Part 13 of `run-budget-blender-check.sh`** (`review13.py`,
  `BUDGET_PARTS=13` alone): 71 checks (one is the turned-grid check added
  after the run above). Each case is the review's own, beside its control:
  Blender's own count past the budget, or the old code put back in the
  check (the crossing pairs alone, the operands where they were, the plan
  not told, the frame being left, a variable keyed by its own path, Time
  Stretching ignored, node groups out of the plan, the bones priced, every
  F-curve priced, unclamped values, every change making the plan again).
- **Negative controls by reverting each fix in a scratch copy** of the
  site folder, part 13 run on each (sandboxed desktop 5.2.1, three at a
  time, load averages of 20 to 50 from other work). Every copy fails its
  own checks:
  - faces in one plane: 12 failed;
  - Self Intersection: 3;
  - collection stand-ins: 5;
  - the gate telling the plan: 4;
  - the frame variables: 3;
  - keys by where the value is: 3;
  - cycles: 3;
  - failing drivers: 2;
  - Time Stretching: 2;
  - node groups: 2;
  - bones left out: 2;
  - slots: 2 (16.73 against 18.55 ms under load);
  - clamping: 2;
  - the gate's signature: 2 (the plan made on 31 of 32 frames);
  - the copies' animation: 1;
  - the turned-normals fix: 1;
  - the shadowed name: the part stopped with a TypeError at the first plan
    holding a shape key and a driver.

  The first 14 copies were made before the copies' animation was cleared,
  so each also failed the driven shape key check. That copy was then made
  again, and it fails only that check.
- **Part 11** still passes. Its "plan kept" control now also keeps the gate
  from telling the plan (`note_pending`), which caught the change
  otherwise.
- **The whole budget check**, on the code before its last two changes
  (normals through the cofactors, a square root for `linalg.norm`):
  `run-budget-blender-check.sh` exits 0 in 44 min 51 s, at load averages of
  30 to 54 from other work on the Mac. Parts 1 to 9 and 11 to 13: 461
  passed, 0 failed. Part 10: no operator grew Blender past the budget
  unpriced, and its control found 110 runs.
- **Parts 11 and 13 on the final code** (load average 15 to 25): 207
  passed, 0 failed. 11.1's price was 0.0050 ms. 11.5's Boolean prices
  (two 400 × 400 grids, 399,254 vertices, from 2 of Blender's evaluations
  each) took 0.44 s for Weld against Blender's own 0.48 s, 0.45 against
  0.30 for Location, 0.46 against 0.31 for Thickness, and 0.47 against 0.32
  for a Move. The reviewed change's entry measured Weld at 0.40 to 0.43 s
  at a load average of 13. The light count was 649,782 against 397,862.
- **Other checks** on the final code, each in sandboxed desktop 5.2.1:
  animation 132 checks, ALL PASS (its 3,000-key frame's price 0.0031 ms);
  mirror 142, unsafe 173, modifier 240, modkinds 982 and undo 101, all
  passed. Host suites budget (section 7 runs the gate in desktop Blender),
  sandbox, animation, animation-shim and mirror: ALL PASS.

### In the app

The Debug build, Designed for iPad on this Mac (`xcodebuild`: BUILD
SUCCEEDED; the bundled modules byte for byte the tree's). Each scene was
made by `-eval64` with the budget lowered to 100,000. Each frame went
through `TimelineDriver.setFrame` (`-frames`), as a scrub and playback call
it. The script also logged `price_frame`'s time and its refusal:

- A Count driver of the scene's `frame_current` × 2000: frames 2 and 3
  sent, and frame 10 NOT SENT ("Frame 10 would give Counted 160,000
  vertices"). The timeline stayed at 3.
- Time Stretching (Map Old 100, Map New 1): frame 2 sent, and frame 5 NOT
  SENT (160,000).
- The two drivers reading each other: frame 3 NOT SENT, "Frame 3:
  Counted's driver on modifiers["Array"].count reads a driver that reads
  it back, …".
- A frame_change_post handler adding the Array at frame 3: frames 2 and 3
  sent, the handler ran, and frame 30 NOT SENT (160,008).
- The driven shape key: frame 10 NOT SENT (159,976).
- 300 keyed bones under an Armature: 16 frames sent. Each frame was priced
  in 0.015 to 0.059 ms; the first frame made the plan, in 27.6 ms.
- The Data API row (`-data-api`) lowering B onto A's plane, two 150 × 150
  grids, Manifold, at a budget of 150,478: FAILED, with the banner "Location
  … would give A 264,032 vertices". Five runs on the final build gave the
  same.

**One crash.** In one of three earlier runs of that last scene, the app
crashed in the mirror's pass after the script. The crash was
`_PyObject_Malloc` under a NumPy `tolist` (EXC_BAD_ACCESS, Python's own
allocator) on the script's queue. No other thread was running Python. The
other two runs did not crash. The new code that ran there was the
Boolean's search for faces in one plane. Its one new native call was
`numpy.linalg.inv` (Accelerate's LAPACK), which nothing else in the app had
called. The cause is not proven. That call is gone (cofactors, which also
fixed the turned normals above), and so is the one `linalg.norm` this work
added. The scene then ran five times on the rebuilt app without a crash.
After every launch the app was killed. The autosave files,
`Scripts/.draft.py`, `.blender-history` and the preferences were put back,
and their checksums and the three scenes' matched the backup.

## October 21, fix round 2: the gate's review answered — handlers, other evaluations, animation, node groups and what the fingerprint did not hold

The review of "one gate for every write" (below) measured seventeen ways
past the gate, a crash and a freeze, in sandboxed desktop 5.2.1 with the
app's context. Each is closed here and re-measured with the review's own
case, through the path it named, beside a control that has to build the
review's count. Re-measuring found two more, also closed: a custom property
a driver reads, and a crash in the gate's own put-back. Files:
`_blenderkit_gate.py`, `_blenderkit_budget.py`, `_blenderkit_nodecount.py`
(new: Geometry Nodes counted), `_blenderkit_context.py`,
`_blenderkit_loopcut.py`, `_blenderkit_item.py`, `_blenderkit_sync.py`.
Tests: `tests/budget/blender/bypass.py` and `sweep2.py` (part 12), `smoke.py`
(section 7 of `run-budget-tests.sh`), `opsweep.py` and `opdrive.py`, and the
unsafe, sculpt and modifier checks.

### What closes each finding

- **A script's handlers** (critical). After each of a script's callables in
  `depsgraph_update_pre/post` and `frame_change_pre/post`, the gate puts a
  checkpoint of its own. It prices what that callable wrote before Blender
  evaluates it. In a post list that is before the second pass, which runs no
  callback. Blender reads each list one item at a time, so a checkpoint the
  gate inserts further down is called in the same evaluation. The script's
  callable stays where the script put it (`remove` and `in` still find it).
  `install` puts the gate's own handlers back whenever the gate runs, so a
  `.clear()` lasts only until the next evaluation. While the gate prices, a
  script's handlers are out of the lists. A script's `load_post`,
  `version_update`, `undo_post` and `redo_post` callables are priced against
  a fingerprint the gate takes first in the same list, because the load's own
  update builds the new file's depsgraph fresh and runs no handler. Blender's
  bundled handlers (Cycles, the pose library) are not a script's.
- **Evaluations of other view layers and scenes** (critical).
  `bpy.context.evaluated_depsgraph_get`, `ViewLayer.update`,
  `Depsgraph.update` and `Scene.frame_set` ask the gate first, for the view
  layer they evaluate. They are reached through `__getattribute__`, because
  Blender finds an RNA function before anything set on its type. A view
  layer Blender has never evaluated is priced whole, from its scene's
  collections (a new scene's view layer lists no object until synced). The
  context's own view layer after a load, an undo or the app's start is not.
- **Dependencies outside every view layer** (critical). A pointer to an
  object, an instanced collection, a new modifier or constraint, or a
  structural change makes the gate walk what Blender will evaluate as a
  dependency (`_dependencies`), and price what it has not evaluated as new.
- **`wm.append` and `wm.link`** (critical) are no longer loads. What they
  bring in is priced as new.
- **Animation on every path** (critical). The scene's frame is in the
  fingerprint. `frame_change_pre` compares the frame Blender is about to
  evaluate with the one its copy holds, and a refused frame is put back
  there (Blender reads the frame after that list). When the frame changes,
  when an action's keys change (`_diff_action`), when a data-block's
  drivers, NLA or action change, or when something a driver reads is
  written, the gate prices what the animation would set
  (`animation_pairs`). F-curves and Blender's simple driver expressions are
  worked out ahead. An NLA, and a driver only Blender can work out (Python,
  distances, rotations), are read from Blender's own evaluation with every
  modifier that makes more hidden on what they reach (`probe_values`). A
  driver added, which no value puts back, is held off while the price
  evaluates and stays muted when refused.
- **Geometry Nodes** (critical). `_blenderkit_nodecount` reads a group from
  its Group Output back, the way Blender runs it, for an upper bound of its
  mesh, points and instances. It covers the primitives, Subdivide, Extrude,
  Duplicate Elements, Instance on Points, Realize Instances, Curve to Mesh
  and the rest, with constants through Value, Integer, Math, Integer Math
  and the Switches. A count that hangs on a field, a zone, a volume, Mesh
  Boolean or Distribute Points is refused in words. The gate compares a
  group's nodes, links and socket values, and a modifier's inputs
  (`properties.inputs`, Blender 5's).
- **Collection items** (critical). A constraint's targets, and the other
  small collections a struct owns, are compared item by item and put back by
  value.
- **Mesh attributes** (critical). The attributes a count reads (Bevel
  Weights under a Bevel limited by Weight; every attribute under Geometry
  Nodes) are compared in Object Mode and in Edit Mode.
  `mesh.attribute_set` and the Item tab's Vertex and Edge Data run as the
  Edit Mode transaction. In Edit Mode they are read from a mesh copy, because
  RNA hands an edit mesh's layers over only element by element.
- **Proportional Editing in Object Mode** (critical). A move with it on, by
  the call or by the scene's switch, is priced whole in its update.
- **Weight, Vertex and Texture Paint, and Sculpt Mode** (critical). Their
  vertices are the mesh's own and are compared. Edit Mode and Dynamic
  Topology are still held as before.
- **Bulk writes inside an operator's call** (critical) are read in its
  update. The exception is a mesh Blender last evaluated in Edit Mode, whose
  copy's elements can be the edit mesh just freed.
- **A text's Edit Mode** (critical). A font operator that can change the
  characters runs as a transaction (`_FontGuard`): the buffer is read by
  leaving and entering Edit Mode, the new body is priced by the text model,
  and the old one is written back when refused.
- **Grease Pencil modifiers and hair** (critical). A Grease Pencil is
  counted at each layer's heaviest drawing, through its Array, Multiply,
  Mirror, Subdivide, Envelope, Dash, Outline, Simplify and Length. A
  particle system's points are counted beside its object's mesh.
- **Loop Cut's time** (critical) is refused past `LOOPCUT_SECONDS` (2 s),
  from a model of the ring's edges times the cuts squared, for a script's
  `loopcut_slide` and for the app's Loop Cut.
- **The crash** (critical). `bpy.data.libraries.write` of a scene whose view
  layers Blender has not synced segfaulted in `BKE_view_layer_copy_data`.
  The write is now preceded by the gate and a `view_layer.update()`, which
  syncs every view layer of every scene.
- **`run-budget-tests.sh`** (high) gains section 7, which runs the gate
  itself in sandboxed desktop Blender: a write, an Edit Mode Resize, a
  driver, a handler and a frame. Without desktop Blender it fails.
- **The sweeps** (high). The operator sweep's oracle now counts Grease
  Pencil, Curves and particle points, and it sweeps `screen`'s frame
  operators. Its traps gain a keyed and a driven Count, a grid under a Bevel
  by Weight, a Grease Pencil and hair, with calls that write a Bevel Weight,
  move with Proportional Editing and change the frame. Part 12's sweep
  (`sweep2.py`) steps what the state sweep never wrote: a constraint's
  target, node sockets, a key, the frame, a Grease Pencil modifier and hair.
  It writes each numeric setting's first step past the budget again through
  five other ways: a driver, a custom property a driver reads, a post
  handler, a key with `frame_set`, and a registered operator. It sets every
  Object and Collection pointer to an object no view layer holds, and moves
  vertices and writes Bevel Weights in Object Mode and every paint and
  sculpt mode.
- **The Edit Mode transaction's cost** (medium). A move is now held only for
  modifiers whose count follows where the vertices are (`_reads_places`: an
  Array fitted to a length, a Bevel by Angle, an Edge Split by angle, a
  Remesh, a Boolean, Geometry Nodes, volumes, Fluid). With one mesh in
  Edit Mode, the "now" a judgement needs is worked out only when it needs it
  (`_Lazy`). Measured interleaved, 4 repetitions, load average about 5, on
  a 90,601-vertex grid under a Subdivision and an Array of 2, the operator
  and the evaluation after it: a Move 53 to 55 ms with the gate and 53 to
  57 without; Remove Doubles 165 to 171 ms against 84 to 85 (still about
  twice, see the still-open entry).
- **The docs** (medium). The still-open entry below is corrected.
- **Found re-measuring, closed: a custom property a driver reads.** A write
  like `E["n"] = 400000` tags nothing and no setting the gate compared held
  it. Measured: a cube's Array Count driven by an empty's `["n"]`, the line,
  then `E.update_tag()` and the mirror's pass, built 3,200,000 vertices with
  no refusal. The gate now compares custom properties (`_diff_custom`), on
  data-blocks and pose bones. A value Blender's copy never held is not put
  back, because its value before is unknown; the drivers that read it are
  held for the price and stay muted when refused.
- **Found re-measuring, closed: a crash in the gate's put-back.** In the
  budget check's Fluid sweep, putting back a domain's Combined Export made
  Blender remove and remake its secondary particle systems. The gate then
  set the removed Foam system's `settings` again, and desktop 5.2.1 crashed
  in `psys_changed_type` (exit 139, twice in a row). Each change now keeps
  the path to its struct, found again on its data-block before every write
  (`_live`). A struct that is gone is not written, and its change goes with
  it.
- **Found by the full budget check, closed: two of this round's own
  regressions.** Working out the Edit Mode transaction's "now" late let a
  linked duplicate through: by then the shared mesh read as the run left it,
  so "now" was "after", and B, under an Array fitted to 100, passed the
  cube's Resize 0.001 and built 400,008 vertices (check 9.5f). "Now" is now
  worked out late only from a stand-in holding the one edited mesh's copy,
  and before the run for everything else. And the gate's frame handler put
  back and set again a frame the timeline had just priced, which tagged the
  scene, so the app's `frame_set` made the frame plan again on every frame
  (check 11.1). An approved frame is no longer judged again.

### Measured

All in sandboxed desktop 5.2.1 with the app's context unless the app is
named. Each has its control, which has to fail or build the review's count.

- **Part 12 of the budget check** (`bypass.py`, then `sweep2.py`): 87
  passed, 0 failed, in the whole check's run. Each case is the review's
  own, through the path it named, refused at the review's count, beside a
  control with the gate off that builds that count: the handlers,
  `.clear()` and a `load_post` handler on a file saved in Sculpt Mode
  (refused at 4,820,000); a driver, one
  reading an empty's X and one reading its custom property; a key, the Data
  API row's and a script line's frame, `screen.frame_offset`, `frame_jump`
  and `keyframe_jump`, a script's `frame_set`, an NLA strip on the
  timeline and in `frame_set`; a node group's Grid of 1,900 × 1,900
  (3,610,000) from a script line and from the Data API row; a constraint
  target's weight (3,199,480); Bevel Weights from a script line, the Item
  tab and `mesh.attribute_set`; a Proportional Editing move; a script line in
  Weight, Vertex and Texture Paint and Sculpt Mode (3,200,008); a registered
  operator and `text.run_script`; a new scene and a second view layer; X
  as a Collection instance, a Shrinkwrap target and a Data Transfer source;
  `wm.append`; `font.text_insert` (3,122,124); a Grease Pencil Array of
  4,111 (4,998,976); hair children (1,000,000 strands); `loopcut_slide` of
  32,000 cuts refused in under a millisecond, where 4,000 unpriced take
  1.1 s. Ordinary edits beside them pass.
- **The new sweep:** 2,140 steps in 42 s, and nothing past the budget
  unpriced. With the gate off, the same sweep finds all 10 settings it is
  told to and all 5 ways.
- **Each fix taken out**, one at a time on a scratch copy of the site
  folder (17 copies): every copy fails its own checks. The Loop Cut copy
  spent 188 s on the 32,000 cuts. On the copy without custom properties
  compared, the sweep found the bypass itself, through a custom property a
  driver reads (O's constraint target's weight, GPG's Array Count, N's
  Grid).
- **The operator sweep** (part 10): 20,526 runs on 15 states in 93 s, none
  past the budget unpriced. With the gate off it finds 110 runs, the new
  traps among them (the frame operators, a Proportional Editing Move, Edge
  Bevel Weight, `mesh.attribute_set`, the Grease Pencil and hair operators).
- **The whole budget check** (parts 1 to 12):
  `run-budget-blender-check.sh` exits 0 in 2,279 s. Parts 1 to 9, 11 and
  12: 390 passed, 0 failed; part 10 as above. Its first run on this tree
  failed 10: the two regressions named above (9.5f, 11.1), and seven of
  part 12's checks, whose cubes were added at the 3D cursor an earlier part
  had moved (`bypass.py` now puts the cursor back at the origin).
- **`run-budget-tests.sh`:** all pass, section 7 included. On a scratch
  copy where `_judge` answers None and the transaction refuses nothing,
  section 7 fails 4 of its 5 checks; the frame is still refused by its own
  price. All 51 host suites pass.
- **The other Blender checks:** all 37 of the other `run-*-blender-check.sh`
  exit 0 on the final tree, with no FAIL line in 12,282 checks.
- **In the app** (Blender 5.3.0 Alpha, the Designed-for-iPad build on this
  Mac; the autosave, draft and history were backed up, put back after and
  compared by checksum): each of these was refused in words, Blender left
  where it was. A post handler (3,200,000); a driver (muted); the frame by
  `frame_set`, the Data API row and the timeline; the timeline's frame with
  the key in an NLA strip; a node group (3,610,000); Edge Bevel Weight from
  the Item tab, through the app's own Sidebar path (3,335,306, with the
  banner); a Proportional Editing Move from the gizmo and the redo panel
  (3,199,480, with the banner); Weight Paint vertices (3,200,008); a new
  scene (3,200,000); `font.text_insert` (3,122,124); a Grease Pencil Array
  (4,998,976); hair children; a custom property a driver reads, put back to
  2; a Loop Cut of 32,000 cuts (in 4 ms); and a cube's Edit Mode Resize
  0.001 whose linked duplicate is under an Array fitted to 700 (2,800,040).
  `bpy.data.libraries.write` of a new scene with a second view layer wrote
  148,965 bytes and did not crash.
  A Fluid domain's Combined Export stepped through its values passed
  without a crash. An ordinary Suzanne under Subdivision level 2 passed
  (7,958 vertices): the mirror's pass took 140 to 161 ms, and the gate with
  nothing waiting 0.03 ms. Twenty frames of the timeline over 300 keyed
  empties and a keyed Count passed, the plan made once, 12.1 ms a frame
  (median).

### Crashes hit

- Desktop 5.2.1, on purpose: the raw `bpy.data.libraries.write` controls
  (a new scene, a new scene given a second view layer, a compositor group
  naming a new scene) segfaulted in `BKE_view_layer_copy_data`, four runs.
  They are the controls the unsafe check keeps in a child Blender.
- Desktop 5.2.1, by surprise, twice in a row: the budget check's part 2
  segfaulted in `psys_changed_type`, the gate setting a Fluid domain's
  removed Foam system's settings again. Fixed (`_live`, above).
- None in the app.

## October 21, fix round 2: temp_override in the app, what a block frees, and Undo after a Run's Mask Fill

The parallel entry below ("temp_override and the context members") was
measured in desktop Blender only. This work built it, ran it in the app,
closed what re-measuring it found, and closed the undo history's fallback
after a Run that enters Sculpt Mode and fills a mask. Files:
`_blenderkit_context.py`, `_blenderkit_undo.py`, `_blenderkit_sculpt.py`
(`counted`), `_blenderkit_sync.py` (the top of `sync`), three Blender checks,
and ten check scripts' working folder.

### Undo after a Run that enters Sculpt Mode and fills a mask

**Why.** A sculpt operator begins its undo step as it starts
(`push_begin_ex`, `BKE_undosys_step_push_init_with_type`) and leaves the push
to the operator's finish. Called from Python without the undo argument, the
finish pushes nothing (`WM_operator_call_py` raises `op_undo_depth`, so
`push_end_ex` skips it), and the step stays pending. The next `ed.undo_push`,
in any mode and under any name, finishes that step: `BKE_undosys_step_push`
takes `step_init`'s type and keeps its name (undo_system.cc). So the
history's own push became ('Sculpt', 'Mask Flood Fill') with no memfile step:

- With the probe deferred (the app's autosave opens with Ball in Vertex
  Paint), the probe's first push was taken that way. Its Undo then decoded
  the memfile step above and the Sculpt step, which leaves a Text in place:
  "undo ran but did not restore the scene (undone False, redone True)", and
  the history fell back to .blend checkpoints. Measured in desktop 5.2.1
  with the app's context, 6 runs of 6: autosaves in Sculpt Mode and in
  Vertex Paint, and Runs that end in Sculpt Mode or in Object Mode.
- With Blender's undo already working, it was wrong instead of slow. A Run
  of Sculpt Mode, Mask Fill, Object Mode and Add Cube, then a Move: Undo of
  the Move left the cube moved, and Redo of the Run lost the cube it added.

**The fix** (`_blenderkit_undo._push_own`). After its push the history reads
Blender's active step. When the name is not its own, Blender gave the push to
a pending step, which is the action's, and it pushes once more. The step is
then two of Blender's deep. The Sculpt header's one-shot operators (Mask,
Face Sets, Voxel Remesh, Dynamic Topology) are that operator alone, and
`counted` says so (`note_pending_alone`). For them the pending step is
finished as the push, as before: their Undo and Redo were exact, and the
extra push would be a memfile step of the sculpted mesh. On a 1,002,001-vertex
grid in Sculpt Mode that took 97 to 221 ms against 0.3 (load average about
270). With the flag the push takes 0.1 to 0.2 ms. The extra read of the stack
costs 0.7 to 1.1 ms a push.

**Measured in desktop 5.2.1** with the app's context, a Blender each, before
and after:

| case | before | after |
|---|---|---|
| Vertex Paint autosave, Run ends in Sculpt Mode, then Object Mode | checkpoints, the probe's error | Blender's undo, every Undo exact |
| Sculpt Mode autosave, the same | checkpoints, the probe's error | Blender's undo, every Undo exact |
| Sculpt Mode autosave, Run ends in Object Mode | checkpoints, the probe's error | Blender's undo, every Undo exact |
| Object Mode autosave, Run ends in Object Mode, then a Move | Undo of the Move and Redo of the Run wrong | all four exact |
| Object Mode autosave, Run ends in Sculpt Mode, then a Move | Undo of the Move wrong | all four exact |
| the header's Mask | exact | exact, one step, 0.1 to 0.3 ms |

**In the app** (Debug, Designed for iPad, the container's autosave with Ball
in Vertex Paint, the Run through `-eval64`, then `-object-ops` with
`select:Ball`, two Transform fields `field:location:0=1.5` and `=2.5`, three
Undos and three Redos, and Blender's numbers after each):

- The build from before this work (09:18, the parallel module and HEAD's
  undo): "[bk-undo] undo history: .blend checkpoints (RuntimeError: undo ran
  but did not restore the scene (undone False, redone True))". The moves'
  pushes took 3.5 to 3.7 ms, and each Undo and Redo loaded a file in 9.5 to
  13.7 ms. After
  the failed probe, `select:Ball` put Ball into Sculpt Mode.
- This build: "[bk-undo] undo history: Blender's undo system (push 1.6 ms,
  undo and redo 2.9 ms)". The two moves pushed in 1.2 and 1.9 ms and undid
  through Blender in 5.1 and 5.4 ms. Ball went 2.5, 1.5, 0.0 with the mask
  (1,106) and the cube kept, then Original from its file (Vertex Paint, no
  mask, no cube). Redo brought the Run back from its file. Ball stayed in
  Object Mode.
- Redo then stopped at the Run. The moves were Blender's alone, and the Undo
  that loaded Original's file freed Blender's stack. That is the history's
  design for any segment (still open below). The checkpoint fallback had kept
  them, as files.

### What a block frees from under its own override

Re-measuring the parallel guard found more crashes. Each was measured in
desktop 5.2.1 with the app's context and the parallel guards, in a Blender
of its own, exit 139:

- `with temp_override(view_layer=<a second view layer>)`, then inside it
  `scene.view_layers.remove(it)`, then:
  - `cube.select_set(True)`, in `rna_Object_select_set`;
  - `cube.visible_get()`;
  - `bpy.context.evaluated_depsgraph_get()`, in `BKE_scene_ensure_depsgraph`.
- `temp_override(scene=<another>, view_layer=<its own>)`, then
  `bpy.data.scenes.remove(it)` and `evaluated_depsgraph_get()`, in
  `CTX_data_ensure_evaluated_depsgraph`. Without MallocScribble one
  unguarded run of three read the freed view layer and went on.
- `temp_override(layer_collection=<a collection's>)`, then
  `bpy.data.collections.remove(it)` and `bpy.context.layer_collection.name`,
  in `LayerCollection_name_length`.
- An override a script entered with no `with` (`override.__enter__()`),
  whose scene it then removed. The run ended with it in force, and the app's
  own mirror after the run went down, in `_blenderkit_collections._walk` or
  `CTX_data_ensure_evaluated_depsgraph`.
- One with only IDs, left the same way, did not crash. It kept refusing the
  app's own undo push: the history fell back to checkpoints, then could not
  write one.

None of these calls is an operator, so `refuse_stale_members` never saw
them. Python marks a freed ID's object removed (it reads as None, measured
safe), but not a view layer, layer collection or bone freed with its owner.
`ViewLayers.remove` sets the one it is given to null, as
`view_layer=None` would.

**The guard** (`_blenderkit_context.py`, the section after `_Override`):

- **What is watched.** An override that holds such a struct is watched while
  it is in force: a ViewLayer, LayerCollection, ToolSettings, EditBone, Bone
  or PoseBone, alone or in a list. Window, screen, area and region are
  Blender's to restore, and IDs read as None. Each is looked for, by address,
  where its owner holds it now (`_watchers`), from the owner it had when it
  was entered.
- **When it is checked.** Before every call from Python code, through
  `sys.monitoring`'s CALL event (3.12 and later; the app is 3.14, desktop
  3.13), which is on only while an override is watched. And on every read of
  `bpy.context` (`Context.__getattribute__`).
- **What it does.** When the struct is gone:
  - the override is left at once, through Blender's own exit, newer ones
    first;
  - that call is refused in words, for example "Object.select_set was not
    run: in the temp_override around it, view_layer holds a ViewLayer, and
    was given a ViewLayer that has been removed, since the override was
    made. …";
  - so is every call after it in that block (`_broken`). A raise in a CALL
    callback stops the call, measured, on the same line too.
- **Calls that are not refused.**
  - The app's own code inside the block, the gate's depsgraph handlers in a
    script's operator call: the override is left, and nothing is refused
    there. Before this, the gate's handler raised when an EditBone was freed
    by Object Mode inside its override.
  - Blender's `bpy.ops` lookup (bpy/ops.py): the operator the script then
    calls is refused, by its name.
  - Code outside the block: the mirror after a run, or another thread.
- **What a run leaves in force.** `_blenderkit_sync.sync` first calls
  `leave_overrides`, which leaves every override still in force and says so
  in the console. A temp_override now lasts for its block, or until the run
  or console line that entered it ends.
- **Cost.** Measured in desktop 5.2.1 at a load average of 40:
  - With nothing watched, a read of `bpy.context.scene` took 413 ns against
    378 with no guard, and CALL events are off.
  - Inside an override holding a view layer, each call took about 4 µs more
    (`select_get` 4.7 µs against 0.7), and a context read 5.1 µs against
    0.3.
  - With a layer collection among 32, `select_get` took 7.7 µs against 1.1.
  - The app's own overrides (`temp_override_view3d`: window, area and
    region) are not watched.

**In the app**, where Blender is 5.3.0 Alpha, through `-eval64` Runs:

- On the main thread (a script that names `temp_override`), each refused in
  words:
  - `scene=None` and `active_object=<a Mesh>`, as the override was made;
  - Delete then Shade Smooth inside one block;
  - a view layer removed inside its block, then `select_set`;
  - a collection removed inside its block, then `layer_collection.name`.

  Valid overrides worked: window, area and region with a list and an
  object, and the borrowed 3D View. The override left entered by the Run was
  left by the mirror after it, which said so. Then Undo, Redo and Shear under
  the borrowed 3D View ran through Blender's undo.
- On the script thread ("thread main: False", the script reaching
  `temp_override` through `getattr`): `scene=None`, another scene's view
  layer and the view layer removed inside its block were each refused, and
  the CALL event sees that thread too.
- Under the borrowed 3D View:
  - Hide (`Bpy.showHide`, through `bridge.run`) hid Ball, and Undo and Redo
    of it were exact.
  - Loop Cut through `-cut-ops` previewed 23 vertices and Blender made 23,
    worst 6.68e-07 m, and was undone and redone.
- A brush pick (Clay Strips, through the header's call), its stroke (138 of
  1,106 vertices moved), Undo (0 moved) and Redo (138) worked.
- The wrapper's own slot: `bpy.ops.uv.stitch._operator` and
  `bpy.ops.UV.stitch._operator` were refused in words, and
  `.poll.__self__` is not there; Stitch still polled (False) and named
  itself `UV_OT_stitch`.
- No crash: no new BlenderLocal report.

### Check scripts start Blender in their work folder

The context, unsafe, guards, opsearch, undo, sculpt, cuttools, objectops,
animation and mirror checks started Blender in the repo root. Mantaflow
writes a 25 MB tile into the working folder. Each now starts it in its own
temporary folder, with the script's absolute path, as the budget check does.
`run-sandbox-tests.sh` still passes: 38 scripts, 49 launches.

### Tests and their controls

- **`tests/undo/blender/verify.py`**, "a Run that enters Sculpt Mode and
  fills the mask is a step of its own". It runs the Swift's own push, undo
  and redo strings:
  - The Run's push is ('Global Undo', 'Run Script') on top of ('Sculpt',
    'Mask Flood Fill'), depth 2, and every Undo and Redo is exact.
  - With the probe deferred by a Vertex Paint autosave, the probe settles on
    Blender's undo after the Run, and every Undo is exact. Past the steps
    kept in files, the Move is not offered for Redo.
  - Two in-check controls replace `_push_own` with the plain push: Undo of
    the Move leaves the cube moved, and the probe falls back to checkpoints.
  - HEAD's `_blenderkit_undo.py` in a scratch copy fails the four checks of
    the fix, and its controls still pass.
- **`tests/unsafe/blender/verify.py`**, 5 more `CONTEXT_CASES`. Each runs in
  a Blender of its own, guarded and raw, with MallocScribble for the raw
  runs that read freed memory:
  - the view layer removed inside its block, then `select_set`;
  - the same, then `evaluated_depsgraph_get`;
  - another scene removed inside its block;
  - the collection removed inside its block;
  - the override entered with no `with`, then the mirror.

  The parallel's "view layer removed, then Select All" is now written
  without a lambda between the removal and the call: the first call after
  the free is the one refused. On the parallel module (rebuilt in a scratch
  copy, 621 lines from HEAD, as it was) the five guarded cases fail: four
  crash (exit -11) and one read freed memory and ran. The rest pass (162).
- **`tests/context/blender/verify.py`**, "What a block frees from under its
  own override", 6 checks:
  - the tool and when its CALL event is on;
  - what is watched;
  - a removal as the block's last line is not refused;
  - a read after the removal is refused, then every call in the block, and
    all runs after it;
  - `leave_overrides` leaves an override entered with no `with`, says so,
    and the undo push works after it.

  On the parallel module 5 fail in words and the check runs on.

### What ran

The final code, this Mac, load averages 9 to 80 with other sessions' work:

- **Blender checks**, one after another: sculpt 178, cuttools 132 (and its
  preview), objectops 371, guards 86, undostack 27, undo 101, context 67,
  unsafe 167 and opsearch 80, each ALL PASS. The operator sweep made 10,668,
  13,342 and 7,134 runs with 0 crashed. Every operator goes through the
  changed wrappers there. Then mirror 142, and budget 305 in 31 minutes at
  load averages of 60 to 320 (part 10's sweep: 12,267 runs, nothing grown
  past the budget or crashed; its control found 72), each ALL PASS.
- **Host suites**: budget 25, scriptthread 57, tools-shim 74, camlight 172,
  cuttools 77, meshmenu 115, modifier 300, objectops 95, redo 177, sculpt
  65, selectpick 91, transformops 87, undo 40, sandbox 51 (38 scripts, 49
  launches) and names 426, each ALL PASS.
- **The animation check**, alone: 132, ALL PASS. The typical scene's frame
  change took 1.29 ms. The 3,000-key frame took 80.1 ms, of which Blender's
  `frame_set` was 26.0, so the mirror's share was about 54 ms (bound 100). A
  remote-desktop helper was using a full core then (load average 14). That
  check does not install the context guards, and the frame path does not call
  `sync`, so nothing of this work runs there per frame.
- **`xcodebuild`**: BUILD SUCCEEDED, before the app tests and again at the
  end. All 31 bundled `_blenderkit_*.py` match the tree byte for byte.
- **The app**, launched 10 times: the control build twice and this build
  eight times. After each launch the app was killed and the autosave files,
  `Scripts/.draft.py`, `.blender-history` and the preferences were put back.
  Their checksums and the three scenes' matched the backup each time.

### Crashes hit

All were in sandboxed desktop Blender 5.2.1. None was in the app.

- 6 probes of mine aborted (exit 134 and 138, "BLI_mmap: Unhandled SIGBUS"),
  in the cost probe's memory read. It called Blender's
  `MEM_get_memory_in_use`, which is a function pointer, as a function, the
  first time after loading the Blender executable as a library. The probe
  now reads the pointer.
- 6 probes crashed under the parallel guards, which found the routes above
  (exit 139): the view layer then depsgraph, select_set and visible_get; the
  scene then depsgraph; the layer collection read; the mirror after an
  override left in force. Then 11 unguarded runs for their backtraces. The
  guard for each is the section above.
- The checks' deliberate controls:
  - each unsafe run crashes its 23 unguarded context cases and its older
    controls;
  - the negative-control run on the parallel module crashed 4 guarded cases;
  - undostack, guards and opsearch crash their own controls.

  macOS kept 8 Blender-*.ips reports from today; it does not keep one per
  crash.

## October 21, fix round 2: frame changes and a legal Boolean, priced in proportion to what changes

Two regressions of round 4's first fix round, both in the vertex budget
(`Resources/python/site/_blenderkit_budget.py`), both closed:

- `price_frame` priced every F-curve of every object on every frame of the
  app's timeline. With 3,000 keyed empties it took 53–54 ms a frame and put
  the animation check over its bounds, although nothing counted reads an
  empty.
- Pricing a legal Boolean took 4 to 9 of Blender's evaluations, and each
  of them made Blender evaluate the real object's Boolean once more.

### A frame: a plan, made once, of what can change a count

`frame_plan()` reads the scene once and keeps the result until something
other than a frame changes it:

- **What feeds something counted.** Starting from every counted object, it
  walks back through what each object reads: its parent, its constraints'
  targets (its bones' too), its modifiers' objects and collections, and its
  curve's bevel, taper and path. This is the same graph the model's
  `affected` walks, from the other end. Animation on an object outside it is
  left out without being read, and so is its data's.
- **What is priced each frame.** Every F-curve and driver of the objects,
  data, shape keys and particle settings in that set, and of the scene,
  except two kinds:
  - An object's own place channels (location, rotation, scale and their
    deltas), when its place is read by nothing priced. A place is read when
    a modifier or a curve of another object reads the object, when the
    object's own stack reads where it is (any kind outside `_PLACE_FREE`,
    or one of those with an object to read: an Array's offset object, caps
    or curve, a Mirror's object, a Screw's axis), when it is a metaball or
    has particles, and when the object places one of those (parent,
    constraint target). Such channels can only move how far the vertices
    get. They are priced each frame only when the most their F-curves reach
    (keys and Bézier handles, linear extrapolation to frame 1,048,574; a
    modifier or an overshooting easing counts as unbounded) could take a
    vertex of what they move past `STATIC_REACH` (1e15 m, a thousandth of
    `REACH`), when they are driven, or when what they move is priced on
    that frame anyway.
  - Settings the model never reads (an object's Color, its empty's display).
- **A frame** evaluates only those F-curves, works out those drivers, and
  compares each value with what Blender holds now, as Blender stores it
  (single precision, an integer F-curve rounded). Nothing that changed means
  nothing is priced. What did change is judged on the counted objects the
  plan says it reaches, not by walking every object in the file.
- **Drivers** are worked out ahead when Blender's own arithmetic for them is
  plain: Average, Sum, Min, Max, and Scripted expressions within Blender's
  simple expressions (numbers, the variables, `frame`, operators,
  comparisons, `if`/`else`, math functions). This is evaluated from a parsed
  tree, never `eval`. The variables must be Single Property, Context
  Property, or a Transform Channel's location or scale in Transform Space.
  Each driver's F-curve maps its value, as Blender does (`driver_add` gives
  it keys at (0, 0) and (1, 1)), and an integer property takes the value cut
  toward zero (measured: 3.75 set Count 3, 7.6 set 7). Whatever such a
  driver reads is evaluated with it, and so is a driver it reads. Any other
  driver feeding a priced input is listed in `plan.unpriced` and stays
  unpriced on frames (see the still-open entry). (Corrected by "the review
  of frame changes and Boolean pricing answered", at the top: a variable
  reading the scene's frame read the frame being left; one reading a keyed
  value through another path, `parent.location[0]`, read it as Blender held
  it; and two drivers reading each other were listed here as priced and
  never priced. All three were measured passing past the budget, and all
  three are closed there.)
- **Kept current.** Every write tags the depsgraph. Measured in 5.2.1:
  adding a modifier, setting an offset object, a parent, a constraint and
  its target, `driver_add`, muting an F-curve, moving a key (by RNA or
  `keyframe_points.foreach_set`), a data path, an action or a new object
  each listed something in `view_layer.depsgraph.updates`. A frame change
  itself fires no `depsgraph_update_post`. So the plan is dropped:
  - on `depsgraph_update_post` outside the gate's own evaluations;
  - when anything is waiting at the frame's price or after a price's
    `settle`;
  - after the last `frame_change_pre` handler of each app frame
    (`anim.frame_set` appends one), which catches a `frame_change_pre`
    handler that changes the scene during a frame. A `frame_change_post`
    handler's change and a script line the gate refuses were not caught,
    and the plan was kept. Both are caught since "the review of frame
    changes and Boolean pricing answered", at the top: when the gate finds a
    change waiting (`note_pending`);
  - on load, undo and redo.

  The plan holds data-blocks, never F-curves. Each frame finds its F-curves
  again (since the review, at the top: where it found them in their bag,
  checked by path and index), so a removed one is a stale plan made again, not freed
  memory read. Two stale plans in a row fall back to pricing every F-curve
  (`_animated_all`).
- **Newly priced on frames.** A shape key's keyed Value (the Key's own
  action, which the fix round's walk never read), drivers as above, enum
  settings, and an F-curve or driver whose path goes through a pointer into
  something counted (`parent.location`).
- The price's own copies leave the scene told of their removal. The frame
  evaluates that inside the price, so the next frame does not take it for a
  change and make the plan again. In the app, before this was done, a keyed
  Count among 3,000 empties made the plan again on every frame it changed.

`_blenderkit_sync._is_real_blender` now remembers a true answer. A frame
asked it once for each object it moved, through `bpy.ops` and the app's
operator wrappers: 232 ms of 8 frames at 3,000 keyed empties under cProfile.

### A Boolean: one evaluation where there were nine

Two 400 × 400 grids, each under a Solidify, A a Boolean Union of B,
Manifold: 399,254 vertices. Before this change, with a counter on
`_evaluate`, Add Modifier ▸ Weld evaluated A's Solidify on a copy twice, B
once, A's Boolean on a copy and A with the Weld on a copy, and then four of
them again for `_judge`'s own count.

- **Copies have data of their own** (`_materialize`). Linking a copy that
  shares A's mesh made Blender evaluate A's Boolean again, because a new
  user of a mesh is a geometry update of it. Measured: 0.70 s with the
  shared mesh, 0.019 s with a copy of it (0.017 ms to copy, its arrays
  shared until written).
- **Each stack is evaluated once a pricing**, and each walk is made once
  (`Prices._evals`, `Prices._walks`, keyed by a version every change bumps).
  The count after one modifier is what the next one is given, the same
  evaluation.
- **Blender's own evaluation is read** where nothing the changes make
  reaches the stack Blender shows (`_clean_through`): a new modifier after
  it, a hidden one's setting. Before, a modifier to be added made the whole
  object read as changed.
- **A light count** (`_walk(refine='light')`, `_final(light=True)` from
  `_judge`). The bounds are made from what Blender is asked for: a Boolean's
  crossings from a BVH, a Bevel's angles, what a Remesh or a fitted Array is
  given. No bound is then replaced by an exact count. What passes the budget
  that way passes it exactly too (not where faces lie in one plane or under
  Self Intersection, which the BVH's crossings miss: the review measured
  2.26 times the light count built. Those counts are made exactly since "the
  review of frame changes and Boolean pricing answered", at the top), and
  the exact count would ask Blender for
  the Boolean once more on a copy, which is what the change's own
  evaluation costs afterwards. Where the light count is past the budget or
  the memory left (or a metaball's time), `_judge` makes the count exactly as
  before, and every refusal and 'now' is as before. Not through a Skin,
  whose loops are read from what it is given.
- **Mesh reads through attributes** (`Measures`, `_bulk`). They were
  measured on that grid under a Solidify at a load average of 160: corners'
  vertices 0.16 ms against 74 through `loops`, positions 0.25 against 6.8,
  face normals 0.26 against 22.7 (`polygon_normals`), the triangles' faces
  0.05 against 35.7. Each face's size is read from its triangles (n − 2
  each). The BVH takes each face size's rows as one array: 0.55 s against
  1.17.

### Measured

Desktop 5.2.1 with the app's context (modules, gate installed, undo push,
gpu.init), one sandboxed Blender each, before and after back to back at a
load average of about 13. "Before" is this tree as it was when this work
started, the gate group's work included.

| Boolean, 399,254 vertices | before | after | Blender's own evaluation |
|---|---|---|---|
| Add Modifier ▸ Weld | 9.74–10.24 s, 9 evaluations | 0.40–0.43 s, 2 | 0.49–0.51 s |
| Data API Location | 2.44–2.68 s, 4 | 0.41–0.42 s, 2 | 0.29–0.32 s (a move) |
| Solidify Thickness | 2.67–2.80 s, 4 | 0.38–0.40 s, 2 | 0.31–0.34 s |
| a gizmo Move's commit | 2.85–3.21 s, 4 | 0.40–0.41 s, 2 | 0.29–0.32 s |

The two evaluations left are A's Solidify on a copy (for the crossings)
and B's, read from Blender's own evaluation.

Frames:

- 3,000 keyed empties, `price_frame` alone: 49.6–51.8 ms a frame before
  (a probe of 8 frames; the fix round's final check measured 53–54). After,
  0.0023–0.0092 ms (median of 32 frames), in every run from a load average
  of 12 to one of 545.
- The same with one cube among them whose Array Count is keyed: 0.0093 ms
  on frames where the Count holds its value, and 0.10 ms where it changes.
  Walking every object for what it reaches (`affected`), as the price of a
  change elsewhere does, took 8.15 ms there.
- 3,000 keyed cubes: the plan takes 0.34 s to make (load average about 200;
  0.62 s before reading each property's type once and short curves point by
  point). It is made after each edit, not on a frame (an edit includes a
  selection change, and the cost lands on the next frame: the still-open
  entry), and prices nothing per
  frame.
- The animation check's typical scene (20 keyed cubes, a keyed shape key, a
  posed armature's skin): 0.20 ms median a frame of a 1.38 ms frame change.
  The plan evaluates the Key's Value and the bone's three rotation channels.

### Checks

- **Part 11 of `scripts/run-budget-blender-check.sh`**
  (`tests/budget/blender/frames.py`, wired into `verify.py`'s parts, so
  `BUDGET_PARTS=11` runs it alone). Each check has a control that fails
  it:
  - 11.1: the frame's price on 3,000 keyed empties is under 0.5 ms, and the
    plan is made once. Control: every F-curve priced, 61–83 ms.
  - 11.2: one keyed Count among the empties is all the plan evaluates; on
    frames where it changes, the price is under 2 ms (0.10 ms; control:
    `affected`'s walk, 8.15 to 8.18 ms). Each of these is refused past a budget lowered to
    100,000, with the bare frame as its control: an Array's Count, a
    Subdivision's Levels (1 → 8: 393,218), a shape key's Value under an Array
    fitted to 2 m (159,976), a driver of a Count from a keyed property, an
    offset object keyed to 0.0001 m, and that offset object's keyed parent.
  - 11.3: a modifier added by a script line after the plan was made, or by a
    frame handler during a frame, is priced on the next frame. Control: with
    the plan kept, Blender makes 160,008.
  - 11.4: the attribute reads equal the element-by-element reads on five
    meshes. Face normals agree to 4.5e-6 between Blender's two reads.
  - 11.5: the Boolean's four prices each take at most 3× Blender's own
    evaluation of the change, from at most 2 evaluations. The light count
    is at least Blender's (649,782 against 397,862). A budget between the two
    is judged on the exact walk, as before. A keyed Location's frame is
    priced in at most 3× Blender's evaluation, and the next frame does not
    make the plan again. Control: exact counts with the stack not reused, 4
    evaluations.
- **Negative controls by reverting the fix in a scratch copy** of the
  modules, part 11 run on each:
  - `_frame_changes` back to every F-curve: 11.1 failed at 60.5 ms a frame.
    The shape key's frame and the driver's frame then passed unpriced: the
    fix round's walk never priced them.
  - Shared data, no caches, no reuse of Blender's evaluation, no light
    count: every 11.5 check failed. Weld took 5.24 s against Blender's 1.06,
    from 5 evaluations; Location 2.57 against 0.51, from 4.
  - The price's own tags left for the next frame: "the plan is not made
    again" failed (made 2 times in 2 frames).
- **The animation check** gained "the vertex budget's price of the frame is
  under 0.5 ms". Its control is the starting modules: 50.03 and 50.16 ms,
  failed (load average 11 to 15).
- **Runs.**
  - Part 11 alone, from the final code: 136 passed. The full budget check
    on the final code: parts 1 to 9 passed 264, part 10 both its checks.
    Part 11 failed 7 there, all fixtures whose cube Add put at the 3D
    cursor, which part 9 leaves away from the origin: the offset object's
    and the plan-follows checks, whose Blender count stayed at 8, controls
    included. Its cubes are now added at the origin. Parts 9 and 11
    together: 220 passed. Then the whole check again: 303 passed, 0
    failed, part 10 both, in 32 min 43 s at load averages of 39 to 67 (the
    Boolean's prices there 0.49 to 0.72 s against Blender's 0.41 to 0.75).
  - The animation check, 5 runs in a row at load averages of 6 to 13: ALL
    PASS each time (132 checks). The 3,000-key frame's mirror share was
    31.2, 25.1, 28.6, 28.1 and 24.6 ms (bound 100). The typical scene's
    frame change was 1.00, 1.38, 0.99, 0.99 and 1.13 ms (bound 4.17). The
    price was 0.0023 to 0.0025 ms. The starting modules at load 11 to 15:
    shares of 71.8 and 80.3 ms, frame changes of 2.19 and 2.20 ms.
  - An earlier series of 5, at load averages of 12 to 69 with other work
    on the Mac, passed 4. Run 4 missed the 3,000-key share (100.2 ms) and
    the 60 Hz line (4.57 ms), with the price at 0.0055 ms.
  - The other 36 Blender checks, three at a time: 34 passed. image3d failed
    to compile (`no such module 'ImageIO'`), and measure's View3D probe did
    not find its flag. Each passed when run alone (46 and 49).
  - Host suites: budget 25, animation 108, animation-shim 39, mirror 128,
    sandbox 51 (38 scripts, 49 Blender launches), ALL PASS.

### In the app

The Debug build, Designed for iPad on this Mac (`xcodebuild`: BUILD
SUCCEEDED; the bundled modules byte for byte the tree's), each run through
DEBUG hooks:

- **Frames**, `-eval64` with a script that made 3,000 keyed empties, a
  keyed probe empty and a cube whose Array Count is keyed 2 at frames 1 and
  10 and 400,000 at 40. The script also timed `price_frame` and
  `anim.frame_set` into a log in the app's own tmp. Then `-frames
  2,…,15,20,40,16` went through `TimelineDriver.setFrame`, as a scrub and
  playback call it.
  - The plan was made once, in 19.7 ms on the first frame, and not again.
  - Frames 3 to 10 were priced in 0.049 to 0.115 ms, of whole frame changes
    of 81 to 110 ms.
  - Frame 40 was refused in 0.38 ms ("Frame 40 would give Counted
    3,200,000 vertices, …"). Its row said NOT SENT, and the timeline stayed
    at 20.
  - The frames where the Count changes (13,335 to 133,335 copies) took 197
    to 271 ms each. That is the finite-position check's copy, `_finite_after`
    (still open).
  - Before the price's own tags were evaluated inside it, the plan was made
    again on each of those frames (12 to 14 ms there).
- **The Boolean**, `-eval64` with a script that made the two 400 × 400 grids
  and timed Blender's own evaluation and each price. Then
  `-data-api '[["bpy.data.objects[\"A\"]", "location", "[0.01, 0, 0]"]]'`
  and `-modifier-steps "@select=A,+weld,Solidify:thickness=0.21"` ran: the
  Data API row, Add Modifier's Weld row and the Solidify row's field, each
  as the Swift sends it.
  - Blender's own evaluation of a move, the Solidify edit and an added Weld
    took 3.67, 3.66 and 3.76 s in the app.
  - The prices took 0.46 to 0.48 s: `price_all` for the two rows, and
    `price_add` twice for the Weld.
  - All three succeeded. After the Data API row: "the budget counts
    398361, Blender evaluates 398361".
- No crash. After each launch the app was killed, and the autosave files,
  `Scripts/.draft.py`, `.blender-history` and the preferences were put back.
  Their checksums and the three scenes' matched the backup.

## October 21: temp_override and the context members (done in parallel)

This closes the critical crash in the "still open" entry below: a context
member overridden with None or the wrong type made the next operator crash
Blender, with or without the guards. It also closes the lower item about the
wrapper's own slot (`bpy.ops.uv.stitch._operator`). It was done in a separate
worktree while fix round 2 went on in the main tree. It changes only
`_blenderkit_context.py`, two Blender checks and this file.

### What crashed

`temp_override` keeps window, screen, area and region for itself, and it
checks those itself. An Object, a RenderSettings or a list for any of them is
Blender's own TypeError (measured). Every other member is handed to Blender
as it is, and Blender's context reads each one back without asking what it
is (`BPY_context_member_get`, bpy_interface.cc):

- None reads as no pointer.
- Any bpy_struct reads as a pointer of the member's own C type, so
  `CTX_data_scene` takes an Object as a Scene.
- Any other sequence, a str among them, reads as a list with no pointer in it.
- An ID that Python marked removed reads as no pointer.

This was measured in desktop 5.2.1 with the app's context: its modules,
gpu.init() and its undo push. Each case was a script line
`with bpy.context.temp_override(<member>=<value>): bpy.ops.<operator>(...)`
in a Blender of its own, restarted after each crash. 174 member and value
pairs were tried against 7 to 14 common operators, plus 13 scenarios. Every
crash was exit -11:

- **scene**: None, an Object, a removed Scene, a RenderSettings, `'Cube'` or
  `[scene]`. Every operator tried crashed (Select All, Move, Set Mode, Add
  Cube, Undo Push, Delete), in `CTX_data_view_layer` or past it. Another
  live scene with the window's own view layer crashed Select All too
  (`BKE_object_eval_eval_base_flags`).
- **view_layer**: None, a removed one or `[view_layer]` crashed Select All,
  Move, Set Mode, Add Cube and Undo Push. An Object crashed Move and Add
  Cube, and a RenderSettings every operator tried. Another scene's own view
  layer crashed 13 operators of 14: the type is right, but the scene is not.
- **blend_data** None crashed every operator, and the override's own exit.
  An Object or a RenderSettings crashed Duplicate, Apply, Add Cube and Delete.
- **layer_collection** None or `[it]` crashed the script's own read of
  `context.layer_collection`. **tool_settings** None crashed Move.
- **active_object** a Mesh or a RenderSettings crashed Move and Apply, and
  the RenderSettings also crashed Set Mode's poll.
  **collection** a RenderSettings crashed the read of `context.collection`.
- **edit_object** an object not in Edit Mode crashed Add Cube, which adds
  into an edited mesh that is not there. This held for the factory cube, an
  object in no scene, and an evaluated copy.
- **selected_editable_objects** `[a Mesh]`, `[cube, a Mesh]`,
  `[a removed Object]` or `[a RenderSettings]` crashed Shade Smooth,
  Duplicate or Apply. **selected_objects** `[a removed Object]` crashed
  Delete.
- **What a block takes away from under its own override.** This is the
  likeliest one in a real script:
  `with temp_override(selected_objects=[cube, other], selected_editable_objects=[cube, other]): bpy.ops.object.delete(); bpy.ops.object.shade_smooth()`
  crashed in `shade_smooth_exec`. So did the same after
  `bpy.data.objects.remove`, after `read_homefile`, and with the override
  made before the remove and entered after it. A view layer removed inside
  its own override crashed the next Select All. An `edit_object` taken back
  to Object Mode inside its override crashed the next Add Cube.

With the guards as they were (HEAD's module installed), 24 of the 25 values
tried again crashed the same way or earlier, in a guard's own read of
`bpy.context.view_layer`. The 25th, `selected_editable_objects=[a Mesh]`,
was stopped by an AttributeError from the gate's read of the list before
Blender read it. Every scenario crashed with those guards as without them.
Under the borrowed 3D View (`temp_override_view3d`), the six values tried
there crashed the same operators. Blender 5.2.1 refuses the old way of
passing a context, a dict as an operator's first argument ("1-2 args
execution context is supported"), so `temp_override` is the only way a
script gives operators a context.

Reading a member back in Python after its ID was removed gave None, with no
crash.

These crashed nothing that was measured: the members Blender type-checks
itself (`object`, `material`: `CTX_data_pointer_get_type`), an int anywhere
(Blender ignores it), None for window, screen, area or region, another live
scene on its own, a collection in no scene, and an evaluated `active_object`.

### The guard

All of it is in `Resources/python/site/_blenderkit_context.py`.

- **`refuse_members`**, called first in the app's `temp_override`. Each
  member is held to Blender's own type for it. The table is Blender's own
  `context_type_map` (doc/python_api/sphinx_doc_gen.py, from the 5.3 source
  of the bundled bpy), and the members `bpy.types.Context` defines in RNA are
  read from RNA. The two differ once: `collection` is a Collection in RNA and
  in `CTX_data_collection`, but a LayerCollection in the table, and RNA wins.
  Window, screen, area and region stay Blender's to check. A member the
  table does not name passes as it is, since a script's own operator may
  read one. The rules:
  - A single member must hold one struct of its type, and a list member a
    sequence of them.
  - An ID must not be marked removed. Measured: Python marks a freed ID's
    object removed after `bpy.data.objects.remove`, `object.delete` and a
    load.
  - A view layer, layer collection, tool settings or bone is looked for by
    address where Blender holds it now. Those are not marked when their owner
    is freed (measured). A view layer must belong to the scene the override
    gives, or the context's scene.
  - The value must be an original, not the depsgraph's evaluated copy.
  - `edit_object`, `sculpt_object` and the other mode members must hold an
    object in that mode. `edit_object` was measured; the others follow
    Blender's own definition in screen_context.cc.
  - None is refused where Blender's context always holds a value
    (blend_data, scene, view_layer, layer_collection, collection,
    tool_settings, window_manager, preferences, workspace), unless the
    context reads None there already. That exception is for `workspace` on
    the script thread, so `temp_override(**bpy.context.copy())` there still
    passes.
  - What the context holds already passes the type check, as Blender's own
    `copy()` does, and is still asked whether it belongs.
  - Some values are refused although nothing measured crashed on them,
    because Blender's own context never holds them there: an int, None for
    collection, window_manager, preferences or workspace on the main thread,
    an evaluated copy outside `edit_object`, the other mode members, and
    another scene's layer collection or tool settings. The refusal
    names the member, what it holds and what it was given, for example:
    "temp_override was not entered: scene was given None, where Blender's
    context always holds a Scene; leave scene out to keep the one it has."
- **`_Override`**. The override `temp_override` returns asks again as it is
  entered, and it is listed in `_in_force` while it is in force. `__enter__`
  hands out the wrapper, not Blender's object.
- **`refuse_stale_members`**. Every operator `bpy.ops` hands out asks the
  overrides in force again as it is called (`_Guarded.__init_subclass__`
  wraps each wrapper's `__call__`). This runs before any other guard or the
  gate reads the context. It catches an ID removed, a view layer gone, or an
  edited object out of Edit Mode since the override was made, and the
  refusal says
  "bpy.ops.object.shade_smooth was not run: in the temp_override around it,
  selected_objects holds a list of Objects, and item 0 of it is an Object
  that has been removed, since the override was made." With nothing in force,
  it costs one look at an empty list.
- **The slot** (`_module_only`, `_unbound`). Each wrapper's `_operator`, and
  an override's `_inner`, is read and written from this module only. From a
  script it raises AttributeError in words. The operator's methods are passed
  on as plain functions, because `bpy.ops.uv.stitch.poll.__self__` handed out
  the same raw operator. Inside the module nothing changed: the wrappers
  still call `self._operator(`, which `run-budget-tests.sh` scans for.

These still work, measured in the context check: the app's
`temp_override_view3d`; a script's own window, area and region; the
search's `area=None, region=None`; `selected_objects=[cube]` with Shade
Smooth; `selected_editable_objects=scene.objects`;
`temp_override(**bpy.context.copy())` on either thread; `active_object=None`;
the scene, view layer, master collection and a layer collection; another
scene with its own view layer; `selected_objects=None`; `edit_object` in Edit
Mode; nested overrides with `as` and `logging_set`.

### Tests and their controls

- **`tests/context/blender/verify.py`**, "What a context member may hold":
  - 22 values are refused in words as the override is made, without
    entering it. With the guard removed, each check fails in words instead of
    crashing that Blender.
  - The 12 valid overrides above work.
  - The slot and its methods' `__self__` are refused, while the operator
    still polls, names and describes itself as Blender's.
- **`tests/unsafe/blender/verify.py`**, `CONTEXT_CASES`: 18 cases, each in a
  Blender of its own, run four at a time. The guarded run must be told the
  refusal, survive, run Undo Push after it, and leave nothing in force. The
  unguarded run must crash in the measured frame (for `scene=<an Object>`,
  anywhere inside the operator's call; see What ran). The cases cover scene None,
  an Object and `'Cube'`; view_layer None, another scene's, and another scene
  with the window's view layer; blend_data, tool_settings and
  layer_collection None; active_object a Mesh; edit_object in Object Mode;
  `[a removed Object]` and `[a Mesh]`; Delete inside its own override; made,
  removed, then entered; a view layer removed inside; Edit Mode left inside;
  and scene None under the borrowed 3D View. Beside them are the slot's 8
  routes (refused in words) and the slot route itself: the guarded
  `bpy.ops.uv.stitch._operator._operator()` is refused, and its control (the
  same object read the way the guards read it, then called) crashes in
  `stitch_exit`.
- **Negative controls.** A scratch copy put HEAD's `_blenderkit_context.py`
  back (the guard removed) and kept this round's tests:
  - The context check failed 5 checks (exit 1) and did not crash. Each of the
    22 overrides was made, so the refusals and their words failed. The slot
    and `__self__` routes handed out `_UndoInArea` and `BPyOpFunction`, and
    `hasattr(op, '_operator')` was True. One valid override failed as well,
    because its `as` value was Blender's own object rather than the wrapper.
  - The unsafe check failed 20 checks (exit 1). The slot check failed. Of
    the 18 guarded `CONTEXT_CASES`, 16 crashed their Blender (exit -11).
    `view_layer=<another scene's>` ran Select All to FINISHED under HEAD's
    guards in that run (the probes had crashed it under them). `[a Mesh]`
    was stopped by the gate's AttributeError instead of a refusal. The
    guarded slot call crashed its Blender. Every unguarded control passed in
    that run too, and so did the rest of the check (137 checks).

### What ran

All of it ran on this Mac with TMPDIR set to this work's scratch folder,
while other sessions' builds kept the load average between about 40 and 580.
These are the final code's runs:

- `run-context-blender-check.sh`: ALL PASS, 61 checks.
- `run-unsafe-blender-check.sh`: ALL PASS, 157 checks, with the 18
  `CONTEXT_CASES` guarded and unguarded and the slot route. The run before
  it failed one control: the unguarded `scene=<an Object>` crashed outside
  `BKE_view_layer_find`, its backtrace not kept. That frame held in 6 runs
  of 7, so the control now takes any crash inside the operator's call for
  that case.
- `run-guards-blender-check.sh`: ALL PASS, 86 checks.
- `run-opsearch-blender-check.sh`: ALL PASS. Its verify passed, and the
  sweep made 10,647, 13,342 and 7,131 runs with 0 crashed. Every operator
  goes through the changed wrappers there (their `__getattr__`, `_unbound`,
  and the stale check before each call), so this is the measure that the
  slot's closing did not break `bpy.ops`.
- Host suites that read or import `_blenderkit_context`:
  `run-budget-tests.sh` ALL PASS (25; its scans of `self._operator(` inside
  `_calling` still hold), `run-scriptthread-tests.sh` ALL PASS (57) and
  `run-tools-shim-tests.sh` ALL PASS (74, the simulator's stand-in importing
  the module). The suites that only check the Swift's strings naming it
  passed too: cuttools (77), meshmenu (115), objectops (95), redo (177),
  selectpick (91) and tools (128), each ALL PASS.
- `scripts/run-sandbox-tests.sh`: ALL PASS, 38 scripts and 49 launches.
- The negative controls above.

### Crashes hit

Every crash in this work was in sandboxed desktop Blender 5.2.1, on purpose,
each in a Blender of its own. The probes gave each Blender its own HOME,
BLENDER_USER_RESOURCES, TMPDIR and working folder under the scratch folder.
The checks sandbox their Blenders themselves.

- The probes, 283 crashes in all (exit -11). They are the matrix under
  "What crashed": 63 and 56 in the two unguarded sweeps of member and value
  pairs, 122 and 30 in the reruns under HEAD's guards and under the borrowed
  3D View, and 12 in the scenarios (the 13 run unguarded, and 9 of them
  again under HEAD's guards). The cause of each is the member value it
  names, read by Blender as its own C type. The guard for each is
  `refuse_members` or `refuse_stale_members`.
- The new checks' controls, which crash on purpose: the 18 unguarded
  `CONTEXT_CASES` and the slot's control (`stitch_exit`), in each run of the
  unsafe check. The negative-control run also crashed 17 guarded Blenders,
  with the guard removed.

No guarded run of the final code crashed. macOS kept 22 Blender-*.ips
reports from today in ~/Library/Logs/DiagnosticReports. It does not keep one
per crash, and some may be from other sessions.

### What is left

- **For the in-app test, which this worktree could not run** (no
  `xcodebuild`, no app launch): check that the app's bpy 5.3 gives the same
  refusals. The table is 5.3's own; the crashes were measured on 5.2.1. Also
  to check in the app: a script line with `temp_override(scene=None)` and
  the Delete-then-Shade-Smooth block, on the main thread and as Run on the
  script thread; the Operator Search and the Swift commands that run under
  `temp_override_view3d`, such as Shear, Loop Cut and Hide; the brush picks,
  whose tool-making passes `active_object` and `object`; and Undo after a
  refused override.
- **Not closed, and not closable from Python.** Python's introspection still
  reaches every object the guards hold: `gc.get_referents(op)` (measured: it
  lists `_UndoInArea`, then `BPyOpFunction`), a closure's `__closure__`
  cells (the slot's own descriptor, and the originals of
  `_bpy.ops.create_function` and `temp_override`), code run with the
  module's own globals (`eval(..., vars(_blenderkit_context))`), frames, and
  ctypes.
- A non-ID struct of a kind other than those six (a MaterialSlot, a
  modifier, a Node, an FCurve, a Strip) is checked for its type and Python's
  removal mark only. One whose owner Blender freed without marking it is not
  caught. No such case was measured.
- A member Blender's table does not name passes as it is.

## October 21, fix round 2: one gate for every write, priced as the state it leaves

(Corrected by "the gate's review answered" at the top. As first written,
this gate did not reach every write: its review measured seventeen classes
past it, a crash and a freeze. They are closed there.)

Every budget review in round 4 found another bypass, because each repair
priced only the paths a reviewer had named. These were the Shape Keys panel's
Value and Solo, the Constraints tab, the Transform fields' constrained
preview, Object Mode's Shear and Parent, and `transform.transform` from the
search. The paths differ, but each one writes a property and then Blender
evaluates the scene. A write evaluates nothing by itself. Blender tags what
changed and evaluates when something asks for the evaluated depsgraph: the
mirror after a run, an operator called from Python (`bpy_op_fn_call` updates
the view layer before and after every call), or a script's own
`evaluated_depsgraph_get`, `view_layer.update` or `frame_set`.

`Resources/python/site/_blenderkit_gate.py` (new) sits at that point. It
prices the scene state, not the path that produced it:

- **What changed.** `view_layer.depsgraph.updates` lists every data-block
  tagged since the last evaluation. Blender's evaluated copy of each one still
  holds the values it last evaluated. Measured in desktop 5.2.1: a location
  written 1 → 0.5 read 1.0 there, and a pose bone's scale 1 → 3 read 1. The
  gate compares the original with that copy. It compares every writable
  setting of an object, its modifiers, constraints, particle systems and pose
  bones, and its data: a curve's splines, a metaball's elements, a lattice's
  points, and a mesh's vertices outside Edit and Sculpt Mode. Shape keys are
  compared too. At rest the two agree, except for four values a simulation
  writes into its copy. That was measured over all 55 modifier types and 31
  constraint types. In Edit Mode a curve's, a lattice's and a metaball's
  points are compared with what Blender last evaluated of them, kept by the
  gate, and an edited mesh is read as described below.
- **What it reaches.** The one model in `_blenderkit_budget` counts it
  (`price_state`, the same judgement every other price uses). The count
  covers every user of the changed data and everything that reads it:
  parents, constraint targets, modifier pointers, bevels and shape keys.
  Constrained, vertex-parented and bone-parented world matrices are taken
  from Blender itself, by evaluating empty stand-ins (`_world_by_blender`).
- **Put back first, then priced.** The changed values are written back as
  Blender last evaluated them, and the change is priced laid over them. They
  are written again only if it passes. So none of the price's own
  evaluations can be the change itself. A refused change stays put back, and
  the refusal is said in words.
- **What a value cannot put back** is priced as it is, with the modifiers of
  what it reaches hidden while the price is made. This covers a linked
  object, a mesh or curve given more elements, and new modifiers or
  constraints. If refused, those modifiers stay hidden or the constraints
  disabled, and an object that is over the budget alone is unlinked. The
  words say which.
- **Passes are reused only for the identical state** (`_same_state`). An
  earlier version reused a pass for any later state with the same tags.
  Setting a Copy Location's Target at Influence 0, then the Influence back to
  the 1.0 Blender had evaluated, built 3,200,008 vertices that way. The test
  for this is 9.2.

The gate runs before every operator `bpy.ops` hands out
(`_blenderkit_context._calling`). It also runs at the start of every
mirroring pass (`_blenderkit_sync.sync`), in the constrained preview's frame,
and in the points mirror. For every other way an evaluation is asked for, it
runs in `depsgraph_update_pre` and `frame_change_pre` (persistent handlers).
Nothing can be raised there, so the change is put back and the mirror
reports the refusal at the end of the run. The same handler runs during an
operator's own update after its run, so Shear, Parent, `transform.transform`
and the constraint operators are held without a list of them. Edit Mode
operators (`mesh.*`), the app's own bmesh code (`gate.editing`: Extrude to
Cursor or Add, the Median field, Snap), and executed moves of an edited
mesh's vertices (`EDIT_MOVES`: `transform.*` and the snaps, but not the
Cursor's own drag or a modal call) run as a transaction (`_EditGuard`).
The mesh is copied, the modifiers that make more are hidden (but a Mirror
with Clipping, which Edit Mode's own operators read), and the result is
priced afterwards with them counted. If it is refused, the mesh is restored
from the copy. Operators that evaluate inside themselves are priced
before they run, from the list the operator sweep below found:
`PRICED_ADDS` gains Plane, Cube and Monkey, and `PRICED_OPERATORS` gains
metaball and curve Duplicate and the curve and surface primitives.

### Each listed path, measured

Desktop Blender 5.2.1 with the app's context, from
`tests/budget/blender/gate.py` (part 9 of `run-budget-blender-check.sh`).
Most tests have a control with the gate off that has to build the count.
The metaball and curve Duplicates do not; their counts come from the
operator sweep's control:

- Shape Keys Value 1 on a key Thin under an Array fitted to 40 is refused at
  3,199,480, and Blender stays at 168. With the gate off, Blender makes
  3,199,472. Solo is refused at 3,200,008. The Data API row's key Value under
  a Remesh is refused too.
- Shape Keys Mute off on a key at Value 1 is refused at 3,199,480 (found in
  this round's last pass, see below).
- The Constraints tab's Copy Location to a target 0.0001 m away is refused at
  3,200,008, and so are its Influence, the Data API row's Influence, the
  Transform fields' constrained preview frame, and Copy Constraints to
  Selected Objects. Blender stays at 328.
- Object ▸ Transform ▸ Shear sliding an Array's offset object to 0.0002 m is
  refused at 3,260,688. With the gate off, Blender makes 3,260,680, because
  the price and Blender round the slid offset one copy apart. Parent with
  Keep Transform off is refused at 3,200,008, and the search's
  `transform.transform` at 3,199,480.
- A curve Join that takes the active curve's bevel (`_joined_curve`) is
  refused at 2,962,560, which is the count Blender makes bare.
- Edit Mode Add ▸ Monkey into a cube under Subdivision 6: the first press
  passes (2,041,156) and the next two are refused at 4,057,734. Three bare
  presses make 6,074,312, the review's count.
- The limit-surface time through Edit Mode is refused, with the faces put
  back. This covers Dissolve Faces leaving a 252-gon, Fill on a 250-vertex
  ring, and an N-Gon Circle of 250 added under Subdivision 1. With the gate
  off, Fill and the Subdivision build take 9.0 to 12.3 s (two runs).
  Multires Subdivide on a 250-gon is refused for its time (`MULTIRES_TIME` is
  0.5 of Subdivision's model, measured on spheres of 128 and 256 segments).
- A pose bone's Scale 40 under an Armature and a Remesh is refused, with
  Blender at 2,648. With the gate off, Blender makes 3,849,608. A vertex
  parent's vertex moved through the Data API row is refused at 3,200,008.
- A metaball's Edit Mode Duplicate from the search is refused at 5 presses
  (32 elements), and the family's polygonization is held to
  `METABALL_SECONDS`.
- Extrude to Cursor or Add on Suzanne under Subdivision 5 is refused once
  past the budget, with Blender at 2,101,256. Three bare presses make
  4,202,512.
- A curve's Edit Mode Duplicate from the search under two Arrays of 64 is
  refused once past the budget, with Blender at 1,277,952.
- An Array at Count 1000 with an Offset of 1e14 passes because it stays
  finite and inside `REACH` (1e18). A Simple Deform Taper of 1e14 on it is
  refused for its reach (`OVERFLOW_CHECK`, 1e12). With the gate off, three
  Tapers leave coordinates that are not finite. A scale of 1e14 on vertices
  at 2e14 is refused.
- A Dynamic Topology chunk on an icosphere of 10,242 vertices under
  Subdivision 4 is priced through the stack. With the Subdivision hidden, the
  same chunk passes.
- A Liquid domain at Resolution 64 with Blender's default Mesh Upres 2 now
  passes. It is counted at 1,179,648, and the measured peaks were 123,880 to
  404,750 (`FLUID_MESH_VERTICES_PER_SURFACE_CELL` = 12). Resolution 160 is
  refused.
- Ordinary edits pass, timed with the mirror: Subdivision level 2 (25 ms),
  a 3 m move (2 ms), a shape key at 0.5 (7 ms), Copy Location (3 ms) and a
  Mirror (19 ms) in the first pass's final run. Other runs under heavier
  load measured 73, 10, 21, 10 and 32 ms, and 55, 6, 9, 6 and 15 ms in the
  last pass. The gate with nothing waiting costs 0.004 to 0.010 ms a call.
  The same edits were not timed on HEAD. Edit Mode's costs on large meshes
  are in the still-open entry below.

### Completeness

- **The state sweep (9.13)** writes every writable bool, int, float and enum
  setting bare, stepped up and down, then runs a mirror pass. It covers the
  objects, the constraints, the pose bones, the shape keys, and a curve's,
  spline's, metaball's and element's settings. Blender may never be past the
  budget unpriced. It ran 3,734 steps. Its control, with the gate off, has
  to find Location, Influence, a key's Value, a key's Mute and a pose bone's
  Scale growing Blender past the budget. It found all 5. No setting is
  allowed by name (`STATE_ALLOWED` is empty).
- **The operator sweep (part 10, `opsweep.py` and `opdrive.py`)** runs every
  operator the Operator Search lists, as the search runs it, with its default
  properties. It runs in 9 states on a scene of traps where any growth passes
  a budget lowered to 5,000: an Array fitted to an empty at the cursor, a
  Subdivision plane, a 64-wire circle, a curve Array and a fine metaball. It
  uses 4 Blenders, each with its own HOME, BLENDER_USER_RESOURCES and TMPDIR,
  and restarts after a crash. With the gate, nothing grew Blender past the
  budget, left a face or vertex past 48 sides under a Subdivision, crashed,
  hung or ran past its time (12,267 runs in 74 s). With the gate off and
  nothing priced, the control found 72 such runs. That list is what
  `PRICED_ADDS` and `PRICED_OPERATORS` gained.
- **The host suite (`run-budget-tests.sh`, section 6)** checks three things.
  Every operator wrapper must call inside `_calling`. The mirror must ask the
  gate before it asks for the evaluated scene. Every bmesh edit of an edited
  mesh in the app's Python must be inside `gate.editing` or listed with a
  reason. With HEAD's modules (the paths open again), it fails 6 checks, and
  it passes with the gate.

**Edit Mode, found in the last passes.** What Edit Mode holds apart from
the data had no copy to compare with, and each of these passed the gate,
measured in desktop 5.2.1 with the budget lowered to 100,000 (so that the
controls stay small):

- An edited mesh's vertices moved. A cube under an Array fitted to 40, all
  selected, Resize 0.0001 on X: 1,599,736. Executed moves (`EDIT_MOVES`:
  `transform.*` and the snaps, not the Cursor's own drag or a modal call) now
  run in the transaction too, hiding only the modifiers that read where the
  vertices are (`_PLACE_SENSITIVE`). The gizmo's Resize commit of 0.0001
  under an Array fitted to 100 is refused, and its 0.5 passes (9.5b).
- What reads an edited mesh. Its linked duplicate under an Array fitted to
  100, Resize 0.001 on X: 400,008. The transaction now holds the objects
  that share or read the edited meshes, priced together
  (`edit_price_after_all`) (9.5f).
- A script's bmesh edit of an edited mesh (`bmesh.update_edit_mesh`): 400,000.
  The mirror's gate now reads each edited mesh whose stack could grow from it
  (`update_from_editmode`) and prices it as it is (`edited`) (9.5g).
- A curve's and a lattice's points. Blender's copy shares them with the
  original in Edit Mode, so the gate keeps what Blender evaluated last
  (`_EditSnap`, taken after each evaluation). A Bézier curve under an Array
  fitted to 100, its points resized to a thousandth by the drag or a script
  line: 650,013. A lattice's points the same over a cube under its Lattice
  and the Array: 399,944, and the budget's model now lays the change on a
  copy of the lattice for what it deforms (9.5c, 9.5d).
- A metaball's elements. Its copy keeps elements of its own, which only a
  write through RNA copies again: an operator's edit in Edit Mode tags the
  geometry only, and Blender evaluates the original's elements. Measured:
  after the search's Resize of 30, an element read 36 in the original and
  1.2 in the copy, after `view_layer.update` too. Compared with that copy,
  a refusal put the element back to the size it had before Resizes that had
  passed, and leaving Edit Mode after the check's control was refused. The
  metaball's elements are now kept like a curve's (9.5e).
- A size past RNA's range. The price clamped every value to RNA's range, but
  an operator writes past it: Resize 100 took a metaball element from 1.2 to
  120 (RNA stops Size X at 20), and the gate counted 23,240 and passed while
  Blender made 246,000. The gate's values are now priced as Blender holds
  them (`Prices.exact`) (9.5e).
- What Edit Mode's own operators read. The transaction hid every modifier
  that makes more while the operator ran, and Blender's Extrude reads a
  Mirror's Clipping to keep the plane's edges off
  (`edbm_extrude_edge_exclude_mirror`). On the +X half of a 4 × 4 grid under
  a Mirror with Clipping, every edge selected, Blender's own Extrude Region
  made 30/56/28 vertices, edges and faces with the gate and 30/53/24 bare.
  The meshmenu check found it through Extrude to Cursor or Add, which reads
  the same flag. A Mirror with Clipping now stays shown (`_read_in_edit_mode`;
  at most eight times the mesh for the run's own update) (9.5h).

Two more, found while running every check on this code:

- **An approval of what is gone.** A setting that passed is approved until
  Blender evaluates it. The modifier check made Geometry Nodes modifiers and
  reloaded the file between them, and the mirror's next pass read an
  approved Node Group removed since: "StructRNA of type GeometryNodeTree has
  been removed", and the whole pass was lost. An approval whose value is
  gone is now no approval (9.14).
- **The mirror with a linked duplicate of an edited mesh** (not the
  budget's, found by 9.5f). The mesh's own arrays read empty while it is
  edited, its loops not: a cube subdivided in Edit Mode read 96 loops and 0
  UVs. The mirror read its linked duplicate's map before the modifiers from
  them, and every pass failed with "foreach_get(..) sequence length mismatch"
  while the duplicate had a modifier shown. It now reads a mesh in Edit Mode
  through `to_mesh()` (96 and 96), and a read that does not fit costs the UV
  Editor that object, not the pass. The UV check has a pass for it (a cube
  in Edit Mode and its linked duplicate Twin under a Subdivision), whose
  control, with the old read, fails.

One cost was cut on the way. Inside an operator's update the gate read an
edited object's evaluated `data`, which Blender builds out of the edit mesh
first: 144 ms of a Move on a 90,601-vertex grid under a Subdivision and an
Array, so a Move took 650 to 735 ms with the gate and 120 to 144 ms without.
In Edit Mode Blender keeps an object's data whatever is written, so it is no
longer read there (256 to 340 ms with the gate after).

**Shape key Mute, found in the last pass.** The gate skipped every `mute`,
because a constraint's Mute is its Enabled inverted. A shape key's Mute is
its own setting, though. Unmuting a key at Value 1 under an Array fitted to 3
passed, and Blender built 6,000,000 vertices (desktop 5.2.1). Now `mute` is
skipped only where an `enabled` alias exists. The Mute path is in 9.1, and
the sweep's fixture has a muted key at Value 1, so the sweep would also find
it.

### In the app

The real iPad build ran on this Mac (Designed for iPad, bundled bpy 5.3.0
Alpha, budget 2,500,000), driven through the DEBUG hooks (`-eval64` with
`-workspace Layout`, `-object-ops`, `-opsearch`, `-data-api`). The autosave,
its `.blend1` and `.partial1`, and the draft were backed up first and put
back after each launch. The checksums of those and of the three scenes
matched, and there was no crash report.

- **Script calls** of the panels' own functions. `groups.set_key` Value 1 was
  refused at 3,199,480. Solo was refused at 3,200,008. Mute off was refused
  at 3,199,480, with the key still muted. The Constraints tab's add and
  target, its Influence 1 and the constrained preview frame were each refused
  at 3,200,008, with A at 328. A
  pose bone's Scale 40 was refused at 9,350,442, with C at 2,648. A vertex
  parent's vertex was refused at 3,200,008. Join was refused at 2,962,560.
  Edit Mode Add Monkey: the first press passed at 2,041,156 and the next two
  were refused at 4,057,734. Fill on a 250-ring was refused for about 18 s of
  limit surface, with 0 faces left. A metaball Duplicate from the search was
  refused at 32 elements (4,915,207). Extrude to Cursor or Add was refused on
  the third press at 4,202,512. A curve Duplicate was refused at 2,555,904. A
  Taper of 1e14 was refused as non-finite. A Liquid at Resolution 64 passed.
  Subdivision, a move, a shape key, a Mirror and an Edit Mode extrude all
  passed. The gate costs 0.006 ms a call when nothing is waiting.
- **`bridge.perform`** (`-object-ops`). Shear was refused with the banner
  "Shear would give A 3,967,280 vertices", and A stayed at 1,760. Make Parent
  was refused at 3,200,008, and O stayed under P. Dissolve Faces was refused
  for about 19 s of limit surface, and the grid was unchanged. Extrude to
  Cursor or Add's third press was refused at 4,202,512.
- **The Data API row and the search** (`-data-api`, `-opsearch`). Key Value
  was refused at 3,199,480, Influence at 3,200,008, and a pose bone's Scale
  at 9,350,442. `transform.transform` was refused at 3,199,480.
- **Sculpt.** A Dynamic Topology chunk of 200 dabs on 2,562 vertices under
  Subdivision 4 was refused at 68,003,330 through the stack.
- **An Edit Mode move** (`-opsearch transform.resize`). A cube under an
  Array fitted to 100, all selected, with Resize 0.0001 on X was refused at
  3,999,344, and the cube stayed drawn at 408 vertices (run again on the
  final build). The `-transform-ops` gizmo could not be used for this: the
  app had not mirrored the script's Edit Mode selection, so it drew no gizmo.
- **The Edit Mode paths above, on the final build** (`-eval64`, the budget
  lowered to 100,000 for the run and put back after, as in the check). A
  curve's points written to a thousandth were refused at 650,013, and its
  Resize 0.5 passed (1,313). A lattice's points were refused at 399,944. A
  metaball's Resize 30 was refused at 433,207, a script line's sizes at
  145,207, and a Resize 1.5 passed. After a Resize 1.5 that passed, a Resize
  30 was refused and the element stayed at 1.8, and Edit Mode was left. A
  Resize 100 at Resolution 1 was refused at 714,440. A linked duplicate's
  Array was held at 400,008. A bmesh edit 1.5 times wider passed, and a
  thousandth was refused at 266,672 with the Array hidden. A Resize 0.5 of a
  cube under an Array fitted to 100 passed (808), and 0.0001 was refused at
  7,998,688. A Liquid at Resolution 64 passed, counted at 1,179,648. A run
  ending with a cube in Edit Mode and its linked duplicate under a
  Subdivision mirrored with no error. The gate cost 0.020 ms a call with
  nothing waiting.
- **`bridge.perform` again on the last pass's build** (`-object-ops`, the
  same steps). Shear was refused at 3,967,280, Make Parent at 3,200,008, and
  Dissolve Faces for about 19 s of limit surface. Extrude to Cursor or Add's
  third press was refused at 4,202,512, and an Edit Mode Extrude passed.
- **The Mesh menu's Extrude under a Mirror with Clipping** (`-object-ops`,
  the half grid of 9.5h under its Mirror and a Subdivision, Select All, the
  menu's Extrude), on the final build: 30/53/24 vertices, edges and faces in
  Edit Mode, as Blender makes bare, every vertex at x ≥ 0.
- **The final build, this pass's fixes** (`-eval64`, the budget lowered to
  100,000 for the run): after a metaball's Resize 1.5 passed, its Resize 30
  was refused at 940,808 with the element kept at 1.8, and Edit Mode was
  left. At Resolution 1 a Resize 100 was refused at 714,440 and the element
  stayed at 1.2. A run left a cube subdivided in Edit Mode with its linked
  duplicate under a Subdivision, and the app's mirror ran it with no
  error.

### Crashes

One crash, in desktop Blender, caused by this change and found by the
measure check. `object.mode_set(mode='OBJECT')` from a mesh's Edit Mode
segfaulted. In the update after it, the gate read the mesh's evaluated copy
with `foreach_get` (`_diff_bulk`), and that copy's elements can be the edit
mesh Blender has just freed (faulthandler traceback). Now bulk reads are
skipped inside an operator's own update and from copies evaluated in Edit
Mode, where those elements are the `_EditGuard`'s and the priced operators'
to price. The measure check ran clean afterwards (49 passed). No crash
happened in the app.

The three other desktop Blender crash reports of the first pass are the
unsafe check's negative controls, which take a Blender of their own down on
purpose: a macro of Stitch (`stitch_exit`), Mask Fill with no undo stack
(`push_begin_ex`), and a load inside a `load_post` handler
(`wm_file_read_post`). Each matches the control's line in that check's log
("takes Blender down (exit -11, in ...)").

The last pass hit no crash it did not mean to, in desktop Blender or in the
app. The unsafe and guards checks' negative controls take Blenders of their
own down on purpose and left their reports (`stitch_exit`,
`push_begin_ex`, `loopcut_init`, each matching a control's line in that
check's log). One of the last pass's own controls, the Edit Mode points not
compared (below), was stopped by hand after 22 minutes: with nothing
priced, it was polygonizing a metaball element resized to about 900 times
its size, which is what that control shows. Other Blender crash reports from
the same hours have a Python driver as their parent, or came from Blenders
this group did not start (the parallel `temp_override` work at the top);
none was the app.

### What ran

Everything below ran on this Mac while other sessions' builds and checks
kept the load average between 60 and 600. So the timing checks here are
weak, and this round re-fitted no time model under that load.

**The first pass's runs**, on its code then (before the Edit Mode work
of the last passes):

- `scripts/run-budget-blender-check.sh`, all ten parts: exit 0, 240 checks
  passed, 3,270 s. Part 10 ran 12,267 runs with the gate and 12,266 for its
  control.
- The same checks with the open paths put back: a copy of the tree with
  HEAD's `Resources/python/site` and this round's tests, the gate's module
  loaded for the tests' helpers and never installed. `run-budget-tests.sh`
  failed 6 checks (the `_calling` scan, the mirror asking first, the bmesh
  scan, and their controls). Part 9 failed 25 checks, the 22 refusals of 9.1
  to 9.7 among them, and stopped at 9.7 on a helper HEAD does not have
  (`meta_seconds`). Part 10 failed 24 runs: 23 grew a trap past the budget
  or left a face past 48 sides (`object.transform_apply` on the Array's
  offset at 3,200,008, the Edit Mode curve primitives, Duplicate, the
  metaball Duplicate), and the 24th ended Blender inside
  `object.duplicate_move_linked` with exit 0 (`opdrive.py` now passes
  `--python-exit-code 1` and names that case apart from a crash).
- 18 host suites and every Blender check, all passing in the end (context,
  cuttools, guards, measure and unsafe after fixes and a second run), but for
  animation's two frame-time checks, which HEAD's modules failed the same
  way side by side.

**The last pass's runs**, on the final code unless said:

- `scripts/run-budget-blender-check.sh`, all ten parts, at a load average
  of 8 to 40 (`run-budget-tests.sh` built and ran during part 2): exit 0,
  264 checks passed, 0 failed, 31 minutes. Part 10 ran 12,267 runs with the
  gate in 51 s and none failed; its control ran 12,267 in 64 s and found
  72. An earlier full run on the code before the last two fixes: exit 0,
  263 passed.
- Part 9 alone, first on the tree as the second takeover left it: it stopped
  at 9.5e, leaving Edit Mode refused after the check's control (the
  metaball's stale copy above). After the fixes: 179 passed, 0 failed.
- **Controls in scratch copies**: the site modules and the budget tests
  copied, one fix taken out, part 9 trimmed to its Edit Mode section (9.5b
  to 9.5h, or 9.14), in a sandboxed Blender. Each failed what it holds:
  executed moves not held and bmesh edits not read (9.5b, 9.5f, 9.5g:
  7 failed); the Edit Mode points not compared (9.5c, 9.5d's drag, 9.5e:
  stopped by hand, see Crashes); the lattice's points not laid on a copy
  (9.5d: 3 failed); the metaball compared with its copy (leaving Edit Mode
  refused); values clamped to RNA's range (the Resize of 100 passed); a
  Mirror with Clipping hidden (9.5h: 30/56/28); an approval read as it was
  (9.14: the ReferenceError). The trimmed sections with nothing taken out
  passed (122 and 99 checks).
- `run-budget-tests.sh` ALL PASS; `run-sandbox-tests.sh` ALL PASS, 38
  scripts and 49 launches.
- Every other Blender check (36) and the host suites that read the changed
  Python (meshmenu, modifier, scriptthread, names, and the five shim suites):
  all passing on the final code's Edit Mode handling but sculpt's chunk
  times (below), three at a time under a load of 20 to 600. The meshmenu
  check failed 13 (Extrude to Cursor or Add on the half grid, the Mirror's
  Clipping above), and the modifier check stopped on the stale approval
  (above). Both pass after their fixes (198 and 242), and points and
  transformops were run again with them (261 and 1,639). The UV check
  passes with its new pass (181), and its control fails 1. The checks that
  ran before the last fix, the stale approval, ran without its `try`, which
  changes only what raised before. The checks up to symmetry also ran
  before the parallel `temp_override` work reached this tree (20:04); the
  context, unsafe, guards and modeguard checks were run again after it, on
  the final tree: ALL PASS (62, 158, 87 and modeguard's one).
- **Sculpt**: the chunk-time checks failed under that load ("no chunk passes
  80 ms": 81.9 and 95.5, and a Draw chunk of 138.7 ms). At a load of about
  20, the gate on and then made inert, twice each, the check passed all four
  times: Draw 5.8 and 7.2 ms median with the gate, 7.1 and 7.1 without;
  Dynamic Topology 23.3 and 23.9 with, 24.6 and 25.0 without (maxima 57.5 to
  66.6 against 46.5 to 50.0, under 80).
- **Animation**, alone at a load of about 9: a frame change 3.27 ms (under
  its 4.2 ms bound) and the 3,000-key frame's mirror share 105.5 ms against
  100, failed; side by side with the gate inert, see the still-open entry.
- The app build: `xcodebuild` Debug, Designed for iPad, BUILD SUCCEEDED,
  rebuilt after each change to the Python. The app runs are in "In the app"
  above, the last two on the final build. The app was quit after each run,
  and the autosave files, the draft and `.blender-history` were put back
  (their checksums and the three scenes' matched after every launch). No
  BlenderLocal crash report.

## October 21: still open after round 4's fix round 2

(Updated by "temp_override in the app, what a block frees, and Undo after a
Run's Mask Fill" at the top: the critical crash and the Mask Fill fallback
are closed, and what that work found is added below. Updated again by "the
gate's review answered" at the top: what the review of the gate found is
closed, the claims it showed wrong are corrected, and what that work left
open is added under the gate's limits. Updated again by "the review of
frame changes and Boolean pricing answered" at the top: the review's eleven
critical findings, its high and its medium are closed there, and what that
work left open is added under the frame plan's and the Boolean's limits
below.)

### Found after fix round 2's repairs, still open (October 22)

The re-checks of the two repairs and the round's final check measured these.
Measurements are in run `wf_639f0fef-870`'s journal. (Updated October 29 by
fix round 3, at the top: its five crash items are closed there — the gate
reading freed memory, `scene.new` in an override that sets a view layer,
`_original_pointer`, removing the window's own scene, and the raw functions
in the guards' closures — and what it left open is added here. Updated
again by "fix round 3: the budget gaps a user reaches from the interface",
at the top: every item of the budget reachable from the interface is closed
there, legacy textures on every path, and what that work left is listed
under that heading. Updated again by "the budget gaps a script reaches, and
the gate's own holes", at the top: the script-only items and Redo past a
step kept in a file are closed there, and what that work left replaces the
script-only list below. Updated again by "the review of the freed-memory
entry answered", at the top: `_derived` is tested and puts back what it
lets go, a guard a script makes is refused, and the gate's limits below
gain the Texture Space lost in one line and the cost of `_updates`.
Corrected by "the review of 'the budget gaps a user reaches from the
interface' answered", at the top: six items of the budget reachable from
the interface were not closed by that entry; they are closed there, and
what that work left is added under that heading. Corrected again by "the
review of 'the budget gaps a script reaches, and the gate's own holes'
answered", at the top: three critical, one high and two medium items that
entry called closed or held were not; they are closed there, route 3 held
at the mirror's pass rather than refused before, and what that work left
replaces the script-only list below.)

**Crashes.** None open from this list (fix round 3). What fix round 3 left:
- Blender's own iterator of `Depsgraph.updates` reads four bytes (a node's
  update flags) of a freed image, font, brush, palette, screen, workspace,
  window manager, library or paint curve until the depsgraph rebuilds after
  depsgraph_update_pre. The gate wraps no such address (`_updates`), but it
  cannot keep the iterator from that read. It did not crash under
  MallocScribble and MallocGuardEdges (the blocks stay mapped).
- The gate reads a copy's pointer to a data-block of a kind Blender copies
  as safe, because the copy then points at the depsgraph's own copy. A
  pointer to one the depsgraph did not build would hold the original, which
  can be freed. No such pointer is known: the depsgraph builds what custom
  properties, drivers, modifiers and constraints name.
- `SCENE_SWITCHES` was found by sweeping every `scene.` and `workspace.`
  operator and by reading scene_edit.cc. Other ways to give the window
  another scene inside an override that sets `view_layer` were not swept:
  the Outliner's scene operators (they need an Outliner area), the
  Sequencer's scene strips, and a workspace with a pinned scene set by a
  script line. A script line that sets `window.scene` there, then an
  operator, is refused (fix round 3), and so is any call or context read
  after it (`_held_to_scene`, fix round 3's verification). An operator that
  does it itself would crash in its own update, before any guard can look.
- The view layer is held to the context's scene only while an override
  that sets `view_layer` is watched (`sys.monitoring`'s calls and
  `bpy.context` reads). Blender's own C reading the context between the
  window's change and the next Python call is not seen. The line alone, and
  what Blender updates inside it, were measured not to crash.

**The budget, reachable from the interface.** Closed by "the budget gaps a
user reaches from the interface" and by "the review of 'the budget gaps a
user reaches from the interface' answered" (fix round 3, at the top; the
first said none stayed open, and six did, closed by the second). What
those two left:
- Fast's near contacts (within 20 × a raised Overlap Threshold) are counted
  from fins, taken twice: at least 1.59 × Blender's count in 72 measured
  cases, not proven. Where the walk cannot ask Blender (a `_SLOW` modifier
  before the Boolean) that bound stands, and it was up to 7.3 × Blender's
  (the review measured 4.8 to 6.4 × in 10 more cases, 106,294 to 110,664
  against 17,155 to 23,053): legal changes in between are refused. Faces
  tilted past the normal cells that cross inside a shared plane with no
  corner within reach are not looked for. Such a Boolean is made exact by
  Blender on every price where Blender's Fast takes it under FAST_SECONDS
  (one more evaluation of it, at most that long). A collection's operands
  under Fast with a raised threshold are looked at corner by corner in
  Python (`_near_faces_apart`): 400 unit cubes 0.002 m apart at 0.01, the
  light walk 0.10 s against Blender's own 0.37 s; not measured with
  operands of many more corners.
- Fast's own time is priced from a bound (`_fast_seconds`): 1 µs for each
  pair of triangles whose faces' boxes come within 40 × the threshold, above
  every case measured past 500,000 pairs (0.31 to 0.80 µs), so it refuses
  evaluations Blender takes 2 to 5 s on (two 40 × 40 grids at 0.01: about
  7 s worked out, 3.9 to 5.6 s measured). Past 4,000,000 face pairs the
  pairs are worked out from a fixed sample of 1,024 faces, an estimate, not
  a bound. A collection's operands are counted against everything before
  them, the cuts' own new faces not. A Fast Boolean already slower than
  FAST_SECONDS (a file opened that way) is never evaluated by a price: a
  change there that is not slower is priced from the unproven near-contact
  bound, and one a later modifier needs measured through it is refused.
- Blender's own time on an Exact Boolean with Self Intersection is not
  priced: on an 80,000-vertex solidified grid it is 9.8 to 16.5 s, and an
  edit there costs the price's own exact evaluation besides (the Data API
  row 21.4 to 31.7 s; 20.9 to 24.1 s on 6d31b90).
- An Object Mode move whose place Blender works out otherwise than its
  price did — through a constraint, a parent that is not an object, a
  Resize that would shear, or an orientation not worked out here (a custom
  orientation other than the scene's slot's, a Rotate on all three axes) —
  is priced a second time, whole, in its update.
- A Single Property or Context Property driver reading a matrix,
  Dimensions, a bound box or a pose's head and tail is worked out only by
  Blender's own evaluation (`probe_values`): a write it reads is priced by
  the row and again by the gate.
- In Object Mode a priced operator's update, other than a move's and the
  modifier operators', is priced whole by the gate after its own price. For
  Duplicate and the adds that is the only price of what they add (Shift+D of
  a 1000 × 1000 grid into a realized collection: 0.11 s in desktop 5.2.1);
  for Join, Apply, QuadriFlow, Voxel Remesh, Subdivision Set and Multires
  Subdivide it is a second price. Their cost was not measured.
- Collection Info with Separate Children is counted as one instance per
  child, each holding as much as the largest child: over Blender's when the
  children differ in size.
- Self Intersection's own faces in one plane are counted up to 2.2 ×
  Blender's (34,160 against 15,556): where the walk cannot ask Blender, a
  legal change in between is refused.
- A move with Affect Only Parents that is refused leaves the parent where
  the operator's first update put it, priced and evaluated before the
  child's Parent Inverse, which is what is put back: the move is done as
  without Affect Only, and refused in words.
- An Object Mode move's update is read whole (`_move_scope`): about 70 µs
  for each object moved (1,000 cubes moved at once: 1.11 to 1.39 s, against
  1.04 to 1.07 s without it and 1.01 s with the gate off; load average about
  5).
- Every `price_all` works out the drivers that read its changes
  (`_readers_of`), and every Object Mode move's update looks for drivers
  that read what moved (`read_by_drivers`): each a walk over the animated
  data-blocks. Where only Blender can work a driver out, the write is
  priced a second time, by the gate. A driver reading an object that a
  constraint (not a parent) places is not found as a reader of the
  constraint's target.
- (Low, over-refusing.) A script line that writes a keyed value is priced at
  what it writes, though Blender then puts the key's value back.
- (Low, the review of fix round 3.) Part 12i's own run of 150 checks may
  have loaded modules another group was rewriting at that moment; part 12i
  and 12j were run again on the final code (the entry at the top).

**The budget, reachable from a script only.** Closed by "the budget gaps a
script reaches, and the gate's own holes" and by "the review of 'the budget
gaps a script reaches, and the gate's own holes' answered" (fix round 3, at
the top; the first called route 1 closed and route 3 held, and neither
was). What those two left:
- Python's own base type reaches Blender's evaluation past the gate:
  `bpy.types.bpy_struct.__getattribute__(view_layer, 'update')()` (or
  `super()`) with the gate's handlers taken out of their lists, or on a view
  layer never evaluated. Blender builds it once (328 → 3,200,008 at the full
  fitted Array); it is held after, not refused before: at once by the post
  handler where only depsgraph_update_pre was cleared (`_unpriced`),
  otherwise at the mirror's pass at the end of the run (`hold_unseen`), the
  modifiers that make more hidden or the object taken out of the scene. The
  rest of the same run reads what was built. Closing it needs a callback
  Blender calls from C before it evaluates.
- A handler that switches off Python's own hooks for itself
  (`sys.monitoring`'s events or callbacks, `sys.settrace` jumping past a
  wrapper's checkpoint) before taking its checkpoint out of its list: held
  at the mirror's pass (Blender at 8 after), not refused before.
- A function of one argument that is both a depsgraph handler and a Scene
  property's getter a driver reads is called, on the main thread, exactly
  as Blender calls it as a handler, and its return still runs the gate's
  checkpoint inside Blender's evaluation (once in each round of three
  evaluations). No crash under MallocScribble and MallocGuardEdges (3 to 4
  rounds each, the getter writing nothing, a Count, 160,000 vertices, a
  Boolean's solver); a refusal made there that takes an object out of the
  scene was not reached.
- A handler in a load's lists (load_post and the rest) that takes the
  checkpoint after it out of its list: the load list is not watched at the
  handler's return, so what it writes is held at the mirror's pass (Blender
  at 8), not refused before.
- The app's own files are taken as the app wrote them by their status-change
  time: a script's own thread writing one in the instant between the app's
  write and its vouching would be vouched for. Not measured. The recovery
  file's record is in the keychain; with none yet (the first launch of a
  build that keeps one) the recovery file opens as saved, as before.
- `hold_unseen` reads every object Blender holds at each mirror's pass (1.2
  to 2.2 ms on 4,100 objects; a curve, a text or a metaball through
  `to_mesh`, which the mirror then does again). Volumes are not read. An
  object in another mode is never taken out of the scene by it, only its
  modifiers hidden.
- An image sequence or a movie whose frame follows the scene's is not priced
  on a frame change.
- Line Art is counted at two points an edge (and two a triangle with
  Intersection): not proven where what stands in front cuts an edge into
  pieces; over-refuses where few edges are feature lines (25,600 against
  3,321).
- A cycle of drivers is refused on every frame where anything it reads moves
  in time (`_in_time`, a bound), a script's `frame_set` there too.
- Keeping the live undo steps as files (`_keep_live_as_files`) writes one
  file a live step at the first Undo across a file. Measured on the review's
  answer (desktop 5.2.1, the app's context, load average about 3): a
  1,002,001-vertex grid, 8 live steps, 346 ms and 869 MB written (96.5 MB a
  file); 32 live steps (Blender's step limit), 1,292 ms and 3,185 MB; a
  251,001-vertex grid, 32 steps, 266 ms and 809 MB. The time is small; the
  disk is not, and nothing holds those files to the 512 MB the checkpoint
  history keeps to.

The final check also measured what is closed. All 20 items this entry listed
at `82d5c4d` are closed, except two lower items that are only partly closed:
the raw function in the closure, and Redo stopping at a step kept in a file.
All 89 suites pass, and the animation check passed alone 3 times in 3 (the
mirror's share 28 ms against its 100 ms bound; a frame's price 0.003 ms).

Fix round 2 (above) closed every item then on the budget's critical list,
the high list except the Boolean slowness, and the medium list. That was
not the whole budget: the review of its gate measured seventeen classes of
write still reaching Blender unpriced (a script's handlers, drivers,
animation on every path but the app's timeline, Geometry Nodes, collection
items, mesh attributes, Proportional Editing in Object Mode, the paint and
sculpt modes, bulk writes inside an operator, other view layers and
scenes, dependencies outside the view layer, `wm.append` and `wm.link`, a
text's Edit Mode, Grease Pencil modifiers, particles), a crash and a
freeze. Those are closed by "the gate's review answered", at the top. The
Boolean slowness and the slower frame changes were closed after fix round 2
("frame changes and a legal Boolean", at the top). Each closed item was
re-measured in desktop 5.2.1 with the app's context, and the paths the
Swift sends were also run in the app:

- Shape Keys Value and Solo.
- The Constraints tab and the constrained preview.
- Shear, Parent and `transform.transform`.
- The curve Join's bevel.
- Edit Mode Add ▸ Monkey, Cube and Plane.
- Subdivision's limit-surface time through Edit Mode and Multires.
- Pose bones and other objects' data under the Data API row.
- Metaball Edit Mode Duplicate.
- Extrude to Cursor or Add.
- A curve's Edit Mode Duplicate from the search.
- `run-budget-tests.sh` passing with the paths open. This one was not
  closed then: the suite only scanned the wiring, and passed with the
  gate's price taken out (the review). Its section 7, which runs the gate in
  desktop Blender, closes it (the entry at the top).
- Values under 1e15 reaching non-finite coordinates.
- Dynamic Topology ignoring the modifiers.
- The Liquid domain refused at the default Mesh Upres.

The round's last passes also closed what they found: Edit Mode moves of an
edited mesh, what reads an edited mesh, a script's bmesh edits, a curve's,
a lattice's and a metaball's Edit Mode points, a metaball's stale copy, sizes
an operator writes past RNA's range, a Mirror's Clipping hidden from Edit
Mode's own operators, an approval of a removed data-block that lost the
mirror's pass, and the mirror's failure with a linked duplicate of an edited
mesh (the fix round 2 entry above).

Still open:

- **The frame plan's own limits** (new, from the entry at the top):
  - Drivers that cannot be worked out ahead (rotations and World or Local
    Space in a Transform Channel, Distance and Rotational Difference,
    `self`, Python beyond Blender's simple expressions, an F-curve modifier
    on a driver without keys, a variable whose value an NLA strip or a
    blended action sets, a driver that fails on a frame), NLA strips and
    the active action blended over them are priced from Blender's own
    evaluation of the frame, with every modifier that makes more hidden on
    what they reach (`probe_values`). That costs such a frame one more
    evaluation of what they reach. Not measured on an iPad.
  - Drivers that read each other are refused, in words, on every frame
    where Blender would evaluate them (one reads the frame or an animated
    value), when one of them reaches a priced value. That includes a cycle
    whose values would settle. A cycle that reaches no priced value, or that
    nothing re-evaluates on a frame, is not refused. A cycle with a driver
    only Blender can work out in it is read from Blender (`probe_values`).
    The probe's own evaluation steps such a cycle once more.
  - A bone's channels are left out under an Armature that only deforms, on a
    static bound made when the plan is (`_pose_reach`: chains of scales
    multiplied, locations and rest places added). With a Remesh, a Boolean
    or another modifier whose count follows where vertices are after the
    Armature, every bone's channels are priced. Measured in desktop 5.2.1:
    3,000 such F-curves took 6.9 ms of a frame's look, where searching the
    bag for each took 12.1. Blender's own frame there was 1.4 ms.
  - When the gate finds a change waiting (`note_pending`), the plan is made
    again before the next frame, unless every change is a number the plan
    reads nothing of. So a `frame_change_post` handler that writes anything
    else on every frame (a pointer, a switch, animation) makes the plan on
    every frame. A handler writing a place every frame did not (part 13.7,
    0 plans in 32 frames).
  - (Low, from the review, not done.) A selection change, or making an
    object active, is an evaluation outside the gate and makes the plan
    again on the next frame. The review measured 93 to 113 ms with 3,000
    keyed cubes at a load average of about 45. In
    `depsgraph_update_post` a selection lists only the Scene, with no flag
    set, which a pointer change lists too. That was not told apart safely.
  - The place channels of an object nothing priced reads are left out on a
    static bound, the most their F-curves reach (keys, handles, linear
    extrapolation to frame 1,048,574). That bound is read when the plan is
    made, from each object's extent and parents' inverse matrices then.
    Every write that changes them tags the depsgraph (measured, a key moved
    by `foreach_set` included) and makes the plan again.
  - Making the plan costs time after an edit, once: 0.34 s with 3,000 keyed
    cubes (load average about 200), 19.7 ms with 3,000 keyed empties in the
    app.
  - A keyed Count past `OVERFLOW_CHECK` (a number times the reach squared)
    evaluates a copy of its object for finite positions on every frame it
    changes (`_finite_after`), as any change of that size does. In the app,
    13,335 to 133,335 copies of a cube: 197 to 271 ms of each such frame.
- **A Boolean's count, after "the review of frame changes and Boolean
  pricing answered"** (at the top):
  - Where faces of the mesh and an operand lie in one plane and meet, or
    under Self Intersection, the count is made exactly, with Blender asked
    for the Boolean on a copy (one more evaluation, as before the light
    count). Blender is asked only inside the bound the fins make
    (`_coplanar`). Between Blender's own count and that bound, a legal
    change is refused. Measured in desktop 5.2.1: two coplanar 150 × 150
    grids, Manifold, bound 264,032 against Blender's 180,156 (refused at a
    budget of 150,478, passed at 288,249). Self Intersection: a comb's
    Array turned 90°, bound 19,048 against 8,272. A collection's two combs:
    14,852 against 8,272 (Exact) and 8,000 (Manifold).
  - More than 400,000 faces that may share a plane with the other mesh are
    refused in words, not looked at.
  - The search for faces in one plane compares offsets by a sorted chain,
    which misses no pair, and normals in cells of 0.001, four times over
    with the cells shifted. A pair whose three normal components and offset
    each sit at a cell's edge, in all four grids, would be missed. Making
    that takes a normal chosen for it. No measurement found one.
  - Under Self Intersection, a mesh's own faces in one plane are not looked
    for: Blender is asked when the crossing pairs are inside the budget, so
    the price's own evaluation could exceed it for a moment. The judgement
    is then Blender's count.
  - The fins' bound per face assumes a segment meets a convex outline at
    most twice. It was measured above Blender's count on every review case
    (Manifold, Exact, Fast, a turned grid, N = 40 and 150), not proven for
    each solver.
  - One app crash, not explained: in one of three runs of two coplanar
    150 × 150 grids made by `-eval64`, the app crashed in the mirror's pass
    after the script, in Python's allocator under a NumPy `tolist`
    (described in that entry). The one new native call there,
    `numpy.linalg.inv`, is gone, and five runs after gave no crash. Heap
    damage from elsewhere is not ruled out.
- **The gate's own limits.** These are new. Each was found by reading the
  code or by measuring, and neither sweep found a bypass through any of them.
  - (Fix round 3's verification; updated by the review's answer at the top.)
    A setting that is read-only when the gate looks (`_derived`: a text's
    Texture Space with Auto Texture Space on) is not judged or priced, only
    put back with the rest (`Pending.derived`). One written while it could
    be, then made read-only by a later write before Blender evaluates, is
    priced only as the state that later write leaves. `smoke.py` finds 23
    such settings on a fixture of every kind, none of which makes a vertex,
    and fails on any new one.
  - (Found by the review's answer, at the top.) A script line that turns
    Auto Texture Space off and moves the Texture Space in one go loses the
    place, with nothing said: desktop 5.2.1 with the app's context, a text,
    `use_auto_texspace = False` then `texspace_location = (5, 5, 5)`, and
    after the mirror's pass the place read the automatic (0.4835, 0.341, 0);
    the same with `_derived` in or out. The put-back writes Auto Texture
    Space on first, whose update works the place out over (5, 5, 5), and
    the place's own put-back is then refused as read-only, so nothing
    writes (5, 5, 5) again. Settings of one rank are put back in the order
    RNA lists them; the opposite order (and writing them again forward)
    looks as if it would keep the place, read from the code and not
    measured, but it changes the order of every put-back. Nothing grows:
    Texture Space makes no vertex.
  - While a data-block of a kind Blender does not copy may have been freed
    (`_updates`), each pass maps the copy of every data-block the gate
    reads: 6.7 ms median at 6,006 data-blocks, 25.9 at 30,006 and 85.7 at
    60,006 (desktop 5.2.1, an image removed and an object moved before each
    pass, load averages of 190 to 240 with other work running). A scene
    that removes an image or a font on every frame pays it every frame.
  - A refusal puts back every change made since Blender last evaluated, not
    only the one that went over. If a script line writes ten settings and
    one is past the budget, all ten are put back.
  - What a value cannot put back is held, not undone. A refused new modifier
    stays hidden and a refused new constraint stays disabled. A linked
    object that is over the budget alone is unlinked from the scene but
    stays in `bpy.data`.
  - A refusal found when a script calls `evaluated_depsgraph_get`,
    `view_layer.update` or `Depsgraph.update` itself is reported when the
    run ends, not at the line, and the lines after it run with the change
    put back. A script's `frame_set` of the context's scene is refused at
    the line.
  - A move invoked to run modal is not held (the app executes its moves).
    Snapping in an Edit Mode move runs with the moved mesh's place-reading
    modifiers hidden. It snaps to the edit cage, which those modifiers do not
    draw on by default.
  - The Edit Mode transaction costs time on large meshes when it holds:
    the mesh is copied (the way back), read from its edit mesh twice and
    priced twice. A move now holds only under modifiers whose count follows
    where the vertices are. Measured in desktop 5.2.1, interleaved, 4
    repetitions, load average about 5, on a 90,601-vertex grid under a
    Subdivision and an Array of 2, the operator and the evaluation after it:
    a Move 53 to 55 ms with the gate and 53 to 57 without; Remove Doubles
    165 to 171 ms against 84 to 85. Remove Doubles is still about twice: the
    stack is hidden for the run, and Blender then evaluates the edit mesh
    twice, once bare and once with it. Not measured on an iPad.
  - A curve's, a lattice's and a metaball's Edit Mode points are held by
    value (what Blender last evaluated, kept by the gate), not as a
    transaction: a change of their shape there, a point or element more, is
    priced as it is with the modifiers of what it reaches hidden, as any
    other change no value puts back.
  - The operator sweep runs each operator with its default properties,
    except a few calls with properties set (a Move with Proportional
    Editing, a Bevel Weight, the frame operators). The state sweeps step
    each setting alone, from fixed fixtures.
  - The Liquid bound (12 vertices a surface cell) is measured on three
    liquids, not proven. A liquid broken into one-cell droplets everywhere
    could exceed it.
  - The time models (Subdivision's limit surface, `MULTIRES_TIME`,
    `METABALL_SECONDS`) were fitted on a desktop Mac, partly under load. An
    iPad's times have not been measured.
- **The gate's limits left by "the gate's review answered"** (at the top).
  Each was found by reading the code or measuring; no sweep found a bypass
  through one.
  - The gate is Python in the script's own interpreter. A script that
    reaches into it (`sys.modules['_blenderkit_gate']._busy = 1`, its
    functions replaced, `trust` or `opening` called as the app calls them),
    into the app's own modules (`_blenderkit_*`: their functions or globals
    replaced, or called as the app calls them — `_blenderkit_undo.step`
    opens a file the app vouched for), or into Python's own hooks
    (`sys.monitoring`'s tool, events or callbacks, `sys.settrace` and
    `sys.setprofile`, `gc`, frames, ctypes) can switch it off or step past
    it. Only its handler lists and entry points are guarded, and Python's own
    base type reaches past the entries. What such a script builds past the
    budget is held at the next mirror's pass (`hold_unseen`, the review of
    fix round 3's script work, at the top), not refused before; the gate
    trusts handlers by identity only, never by a mark, a module, a file
    name or a function's globals.
  - A refusal in a load's handlers (`load_post` and the rest) cannot put
    back what the file brought: the modifiers that make more on what was
    written stay hidden, and the refusal says so.
  - A custom property Blender's copy never held (set with no tag since the
    data-block was last evaluated) has no value to put back. Refused, it is
    left as written and the drivers that read it are muted. Custom
    properties are compared on data-blocks and pose bones only (arrays of
    any length since fix round 3, at the top).
  - A change whose struct a put-back freed is dropped: changing a Fluid
    domain's Combined Export and a secondary particle system's Settings in
    one evaluation leaves the remade system with Blender's own settings.
  - Geometry Nodes are counted only where the count follows from the
    nodes' own values. A group whose count hangs on a field, a zone (Repeat,
    Simulation, For Each), a volume, Mesh Boolean or Distribute Points is
    refused in words, legal or not.
  - A Grease Pencil is counted at each layer's heaviest drawing, and
    emitter particles as points beside the mesh: upper bounds.
  - Only the attributes some count reads are compared (Bevel Weights under a
    Bevel limited by Weight, every attribute under Geometry Nodes).
  - Drivers and keys on places and shape keys are priced only where
    something they reach reads places (`_reads_places`); a rig's correctives
    under deforms are not worked out on every pose.
  - A text's Edit Mode transaction compares the body only (a style change
    alone is not priced), and costs four mode switches per font operator.
  - Loop Cut is the one cut tool whose time is modeled. Other operators'
    times are bounded only where an earlier round modeled them.
  - Reading a Scene's or a ViewLayer's attribute goes through the gate's
    `__getattribute__`: 134 and 169 ns against 41 and 64 ns without
    (desktop 5.2.1, load average about 15).
  - Instancing is not priced (the review's low item): a 200 × 200 grid with
    `instance_type='VERTS'` and Suzanne as its child, or 40,000 particles
    rendered as Suzanne, gave 20,280,000 instanced vertices with no refusal.
    The mirror does not draw instances and Blender shares the instanced
    mesh; a render or `object.duplicates_make_real` would make it real.
  - The sculpt check's 80 ms bound on a stroke's chunk failed under a load
    average of about 38, and passed alone.
- **Frame changes: the mirror's own share.** `price_frame` no longer costs
  a frame anything that can be measured (0.0023 to 0.0092 ms with 3,000
  keyed empties, the entry at the top). What is left of the animation
  check's "mirror's share" of a 3,000-key frame is `push_frame` handing each
  moved object's channels over. It measured 24.6 to 31.2 ms over 5 runs in
  a row at load averages of 6 to 13, against the check's bound of 100. In
  an earlier series at load averages of 12 to 69 it measured 20 to 100.2
  ms, and failed once.
- **Crash, critical (Blender's own behaviour): closed.** Overriding a context
  data member with None or the wrong type (`temp_override(scene=None)`) is
  refused in words since the parallel entry. What a block frees from under
  its own override is refused before the next call or context read, since
  "temp_override in the app" at the top. Both were measured in the app. Left
  of it:
  - A struct of a kind the guard cannot look for, freed inside its block, is
    still read: a MaterialSlot, a modifier, a Node, an FCurve, a Strip. Only
    a view layer, layer collection, tool settings and bones are looked for.
    No crash through one was measured.
  - A free and a read inside one C call, with no Python call between, is not
    seen. None is known.
  - While a watched override is in force, every Python call costs about 4 µs
    (7.7 µs with 32 layer collections), measured in desktop 5.2.1. Fix round
    3's verification measured 1.0 µs inside `temp_override(scene=…,
    view_layer=…)` before `_held_to_scene`, and 1.4 to 1.5 µs with it (load
    average about 30).
  - Python drivers that run while one is watched would be checked on
    Blender's evaluation thread. Not measured.
  - Python's introspection is still open: `gc.get_referents`, the slot's
    descriptor in `_module_only`'s closure, frames, ctypes, and code run by
    `exec` in `_blenderkit_context`'s own globals or through its functions
    that call what they are given (measured: the holder called so hands back
    the raw BPyOpFunction). (The guards' own closures hold no raw function
    since fix round 3, and since the review's answer at the top a script
    cannot make a guard around one.)
- **Undo, found by the Mask Fill work** (measured in desktop 5.2.1 before
  and after, each the same both times):
  - A Sculpt header operation (its step is Blender's Sculpt step), then a
    change that is not sculpting while still in Sculpt Mode (a location set
    from Python, as a script line or the Data API row sends it), then Undo:
    the change stays. Blender decodes the
    memfile step above and lands on the Sculpt step, and no memfile step
    holds the scene between the two. Pushing one after each header operation
    would cost 97 to 221 ms on a 1,002,001-vertex mesh.
  - (Closed by fix round 3, at the top: before such a load the history
    writes the live steps to files, `_keep_live_as_files`; in the app, a Run
    and two Duplicates after a Vertex Paint autosave, Undo to Original, then
    Redo came back to both Duplicates.) Redo past a step kept in a file was
    gone. After an autosave opened in a paint or sculpt mode, the steps
    before the probe settles are files; an Undo back across them loads one,
    which frees Blender's stack and the steps above. Measured in the app:
    after the Run and two moves, Undo to Original, then Redo stopped at the
    Run.
  - (Fix round 3's verification, not explained.) In 1 of 10 runs of the
    sculpt check on fix round 3's code, the Undo of a Grab on a 2-level
    Multires cube left the level where the Grab put it ("Undo: the level
    back" and "Redo: the Grab again" failed), run beside the budget check at
    a load average of 8 to 11. The other 9 runs, and 3 on 6d31b90's tree,
    did not repeat it, so it is not known whether that tree has it too.
- **Lower.**
  - The wrapper's own slot (`bpy.ops.uv.stitch._operator`) is refused in
    words since the parallel entry at the top, and so is `.poll.__self__`.
    Since fix round 3 the guards' closures hold no raw function either, and
    a guard a script makes is refused. Python's introspection
    (`gc.get_referents`, the slot's descriptor in `_module_only`'s closure,
    frames, `exec` in the guards' module's globals) and ctypes still reach
    the raw operator. What such an operator only sets is now priced by
    the gate's handler during its update, but what it evaluates inside itself
    is not.
  - The Operator Search refuses Object ▸ Hide (`object.hide_view_set`):
    "available false … needs a different selection or Blender editor
    context". Its poll runs with no 3D View. Measured in the app on the build
    from before this work and on this one. The Object menu's Hide works,
    under the borrowed 3D View.
  - In the app, picking a sculpt brush made Blender try to create an asset
    index folder in a cache folder outside the app's container, which the
    sandbox refused ("Index not created: couldn't create folder"). Nothing
    was written there. Not investigated.
  - The mirror host suite's 3,000-key bound (5 ms) failed once under load.

Details, with file:line and measurements, are in the fix round's journal
(run `wf_caaa35b8-9d1`), this round's entry above, and
`/Volumes/D/OfflinAi/blenderlocal-release/round4-inputs/`.

## October 21: every check's desktop Blender has a HOME of its own

Fifteen Blender checks started desktop Blender with the user's HOME: 3dview,
camlight, context, image3d, mirror, modeguard (its `drive.py` starts one Blender
per operator), modifier, objectmenu (and its no-assets clone), redo, render,
texpaint, tools, undo, uv and viewport. So did the animation check's main
verify run; its handler runs were already sandboxed. Measured in 5.2.1: even a
bare `-b --factory-startup --python-expr "import bpy"` writes `~/.thumbnails`
into HOME (4 entries in an empty one), and an operator can write the settings
in `~/Library/Application Support/Blender`. `--version` writes nothing.

Each of those launches now gets `HOME="$home" BLENDER_USER_RESOURCES="$home/res"`,
inline as names and sculpt already did. `$home` is inside the check's own
build folder, or `blenderlocal-context-home` for context, which has no build
folder. `exec` launches use `exec env`.

`scripts/run-sandbox-tests.sh` (tests/sandbox/check.py) reads every
`run-*-blender-check.sh`, joins continuation lines and fails on a Blender
started without both variables, unless an earlier `export` set them. A Python
driver that starts Blender itself counts as a launch. `--version` does not. Its
first 12 checks are made-up snippets showing it catches a bare launch, exec,
pipe, `if !`, a clone, HOME alone, and a driver, and passes the sandboxed forms.
On the tree before this change it failed exactly these 16 scripts; now it
passes all 38 (49 launches).

Run after the change, three at a time with the fix round's agents also running
(load average 28):
- 15 of the 16 checks passed: 3dview 394, camlight 150, context 54, image3d 46,
  mirror 142, modeguard ALL PASS, modifier 240, objectmenu 315, redo 749,
  render 43, texpaint 77, tools 271, undo 94, uv 167, viewport 34.
- animation failed two frame-time checks, then one when run alone. Run twice
  each, under the same load: the script as it was before failed one timing
  check both times, and the new one failed two and then passed everything.
  The misses are the load, not the sandbox.

The real `~/.thumbnails` (268 files) and the Blender settings folder were
unchanged across all these runs.

## October 20: What a script line reaches, one table, and the draft left alone (round 4's fix round)

### The review of this fix round, answered (October 21)

The review found the guards keyed on how a script spells an operator, a
macro's steps that the macro guard let through, a brush pick that read the
mode from the wrong place, and two crashes inside a file load. Each is closed
below. "Desktop" is Blender 5.2.1 with the app's context (its modules,
`_blenderkit_context.install`, `gpu.init()`, its undo push), every probe a
sandboxed Blender of its own (own HOME, BLENDER_USER_RESOURCES and TMPDIR);
"in the app" is the real iPad build on this Mac (Designed for iPad, through
`-eval64` and `-console64`; the autosave, the draft and the console history
put back after each launch — in the four launches looked at before that, only
the autosave, which the app writes, had changed — the three scenes'
checksums unchanged, no crash report).

**The module as typed** (critical). Blender upper-cases the module part of a
name in ASCII and takes the name part as written (`pyop_create_function`,
`WM_operator_bl_idname`), so `bpy.ops.UV.stitch` is UV_OT_stitch, and
`uv.STITCH` is no operator (measured). Every guard was keyed on the module as
typed: the review measured `bpy.ops.UV.stitch()`, `WM.call_menu(...)` and
`BRUSH.asset_activate(...)` exiting 139, `UV.select_edge_ring()` never
returning, `MESH.primitive_grid_add(1700 × 1700)` making 2,893,401 vertices
past the 2,500,000 budget, `WM.read_homefile()` on a thread exiting 139, each
refused in lower case in the same run. Now `_op_create_function` folds the
module as Blender does (`_ascii_lower`, ASCII only) before any lookup, and
`operator_path` reads every spelling Blender takes ('uv.stitch', 'UV.stitch',
'Uv.stitch', 'UV_OT_stitch'), which `refusal`, `ask` and the macro guard use.
In desktop every guarded operator gets its own wrapper under 4 spellings
each (52), every table entry is refused as `MODULE.name` and `Module.name`
and through `create_function('MODULE', ...)`; in the app (a script that names
`temp_override`, so the main thread) `bpy.ops.UV.stitch()`,
`_bpy.ops.create_function('Uv', 'stitch')()`, `UV.select_edge_ring()`, Stitch
under the borrowed view, `WM.call_menu(...)` and the 1,700 × 1,700 grid were
each refused in words, and `OBJECT.mode_set`, `WM.read_homefile`,
`MESH.loopcut` and `BRUSH.asset_activate` read as `_SculptEntry`, `_FileRead`,
`_NeedsView` and `_Unsafe`.

**A macro's steps** (critical, high). The macro guard asked only the table and
the prices. Measured by the review: a step of Loop Cut with its edge set
(`edge_index` 4) exited 139 in `loopcut_init` from `wm_macro_exec` (the
October 20 measurement used the default edge, -1, which is CANCELLED); a
macro of Open (a file saved in Sculpt Mode) then Mask Fill, from Sculpt Mode,
exited 139 in Sculpt Mode's undo `push_begin_ex` (the step's load skips
`_FileRead`, which makes Blender's undo again); a step of `read_homefile` on a
script thread exited 139 from `ED_screen_exit`. Now a step of Loop Cut (both
operators), of any of the six loads, of Sculpt Mode's way in
(`object.mode_set`, `object.mode_set_with_submode`, `sculpt.sculptmode_toggle`)
and of a priced move (`transform.rotate` with the rest) is refused at
`Macro.define`, in words saying what to call instead (`_MACRO_STEP_REFUSALS`):
a step's settings are set after it is defined, where nothing reads them. In
the app seven steps, `UV.stitch` and `Uv_OT_stitch` among them, were refused.
A script's own **BLOCKING macro** went past the undo-in-area guard, which lets
unregistered BLOCKING operators through: the review's macro of
`OBJECT_OT_mode_set` (Edit), called `('EXEC_DEFAULT', True)` under the
borrowed view, exited 139 in `ED_area_type_hud_ensure`. `refuse_undo_in_area`
now refuses anything with 'MACRO' in its bl_options; none of Blender's own 58
macros is BLOCKING without REGISTER (measured), so nothing it let through
before changes but a script's macro. In the app a BLOCKING macro of Toggle
Edit Mode with its undo under the borrowed view was refused.

**The brush pick's mode** (critical). `give_brush_tool` read
`bpy.context.mode`, which follows an overridden `active_object`; Blender's
pick reads the view layer's active object (`WM_toolsystem_mode_from_spacetype`,
`BKE_paint_get_active_from_context`). The review: a file saved in Vertex
Paint, opened as the app opens it, and the pick under
`temp_override(active_object=<an object in Object Mode>)` — exit 139. Now the
mode and the paint settings come from `context.view_layer.objects.active`
(`_BRUSH_MODE_KEYS`), and the tool is made for that object (measured: a
script's `active_object` override stays in force inside the borrowed view, so
it is overridden again there). Desktop and the app (a copy of the autosave,
Vertex Paint, tool None, an empty as the override): FINISHED, tool
`builtin.brush`, Paint Hard, still Vertex Paint. Probing beside it found
three more crashes of the same pick, each exit 139 in
`WM_toolsystem_activate_brush_and_tool`: a Texture Paint brush picked in
Object Mode (the factory scene, and a file opened as the app opens it) and in
Edit Mode, where Blender gives the brush to Texture Paint's settings and a
tool the mode does not have, and the same brush under an Image Editor (an
area of the startup screen turned into one) in Vertex Paint, where Blender
looks for that editor's tool. A Vertex Paint or Sculpt brush in Object Mode
was FINISHED and changed nothing ("wrong object mode"). So the pick is
refused in words outside a brush mode and in an editor with tools of its own
other than the 3D View (in the app: Object and Edit Mode refused), and Toggle
is refused when the mode's settings hold no brush, which
`brush_asset_activate_exec` dereferences unasked (read from the source; no
measured file held none). The Object Mode line of the check, which ran before,
is refused now.

**Inside a file load** (high). Blender runs Python inside a load (texts
registered as modules, version_update, load_post, the depsgraph's handlers)
after the file has replaced the scene and before it sets up the modes the
file's objects were saved in (`ED_editors_init`). The review: a persistent
load_post handler running Mask Fill, then any load of a file saved in Sculpt
Mode — exit 139 in `sculpt_update_object`, the handler first or last. Every
load the app or a script makes (`_FileRead`) now notes the address of
Blender's database as it begins; while one is in progress and the address
has changed (measured: load_pre reads the old one, version_update and
load_post the new one) every guarded operator is refused in words while any
object is in a mode other than Object Mode (`refuse_mid_load`). And a load
inside a load is refused outright: the outer load goes on with the database
the inner one freed (`wm_file_read_post` holds `bmain` across load_post), a
use after free — `open_mainfile` from a load_post handler exited 139 in
`wm_file_read_post` in 2 runs of 12 with an undo push after it (which
`_FileRead` itself made after every load, so with October 20's guards the
load alone crashed once), 0 of 6 without, and every time with macOS filling
freed memory (`MallocScribble=1`: the load alone 7 of 7, the handler first or
last, and with the push 6 of 6). In the app: the handler's Mask Fill and its load
were refused in words, the load returned FINISHED, the object was in Sculpt
Mode and Mask Fill after the load ran (FINISHED).

**Low ones fixed.** `_op_create_function`, `macro_define` and `temp_override`
carry a mark (`_blenderkit_guard`) instead of the function they wrap
(`._blenderkit_original` handed a script the unguarded one; the original
`temp_override` on the script thread empties the main thread's context);
in the app all three read False. A str subclass whose `partition` or `lower`
lies cannot choose the key (`_exact`, `str.partition`, `str.translate`: what
C reads). The DEBUG `-console64` hook no longer writes the console history
(`ConsoleTerminalView`, `launchKeysRequested`): in the app the typed line ran
(`bk-console 42`) and the user's 8 entries on disk were unchanged; with the
fix reverted in a rebuilt app the same launch appended the line (put back
from the backup with `defaults write`, identical after).

Tests: `run-unsafe-blender-check.sh` (118, from 78): the spellings, every entry
as `MODULE.name`, the macro steps every way Blender names them (and a lying
str: 96 and 84 names), and 17 scenarios in a Blender of their own each, guarded and not — the
review's routes and this round's, each unguarded control crashing in its
frame (`stitch_exit`, `popup_menu_create_impl`, `loopcut_init`,
`push_begin_ex`, `ED_screen_exit`, `ED_area_type_hud_ensure`,
`WM_toolsystem_activate_brush_and_tool`, `sculpt_update_object`,
`wm_file_read_post` under MallocScribble) or, for the grid, making 2,893,401
vertices. Negative controls, each a scratch copy of the site folder with one
group of fixes reverted, the check run against it (`BK_SITE`): the module not
folded — 22 FAILED (the guarded children exit 139, Edge Ring Select killed at
60 s, the grid made); the step refusals, the 'MACRO' rule and the mid-load
check taken out — 6 FAILED; the mode read from `context.mode` and the editor
check taken out — 5 FAILED; nested loads allowed, `operator_path` calling the
str's own methods, the original exposed — 4 FAILED. `run-context-blender-check.sh`
reads the new mark. Every Blender check, 38 of 38, ALL PASS (budget, opsearch,
guards, sculpt and context among them); every host suite, 50 of 50, ALL PASS
(terminal and scriptthread again on the final tree); the Debug build for
Designed for iPad builds.

Crashes: none in the app. In desktop, all in sandboxed probes or the check's
controls: the Texture Paint pick in Object Mode (twice, and once with
Toggle), in Edit Mode and under an Image Editor (exit 139 each); the load
inside load_post (exit 139 in 1 probe with October 20's guards, 2 of 12 raw
with an undo push, 13 of 13 under MallocScribble); and, on purpose, every
unguarded control and the guarded children of the negative copies.

Not done: the four draft checks in `tests/scriptthread` still read the
sources, not the app's behaviour (low; T8-style launches measure it); whether
Undo brings the scene back after the starter example's Run was not measured;
the wrapper's `_operator` slot and ctypes still reach Blender unguarded;
handlers outside a load (undo_post, frame_change, depsgraph updates while
painting) were not examined; with an interface (not the app's bpy) the
generic operators are not wrapped, so `refuse_mid_load` asks only the
guarded ones there. Seen again, not investigated: after a Run that enters
Sculpt Mode the history's deferred probe chose .blend checkpoints ("undo ran
but did not restore the scene"), one launch of five here. The first runner
of this round started 28 Blender checks with the scripts' own environment
(several with the user's HOME, as noted below) and the context check once by
hand; the other ten ran with a HOME of their own, and
`~/Library/Application Support/Blender` was not written (newest file October 4).

Round 4's final review re-measured two crash paths a script line reached past
the guards: `bpy.ops.uv.stitch()` in Edit Mode on a mesh with UVs and a
selection segfaulted Blender (no area: in `stitch_exit`; under the borrowed
3D View: in `ED_region_draw_cb_activate`), `bpy.ops.uv.select_edge_ring()`
never returned, and a brush pick (`brush.asset_activate`) by the Operator
Search or a script line in a file opened in a paint mode with no tool
crashed in `WM_toolsystem_activate_brush_and_tool`. The search refused the
first two by a list of its own; nothing guarded a script line. Desktop is
Blender 5.2.1 with the app's context (its modules, `_blenderkit_context.install`,
`gpu.init()`, its undo push, the borrowed 3D View where the app uses one),
every probe a sandboxed process of its own; "in the app" is the real iPad
build on this Mac, Designed for iPad, through the DEBUG hooks.

**One table** (`_blenderkit_context.UNSAFE_OPERATORS`). Each entry (`Unsafe`)
holds the sentence the banner shows, what was measured, and either no
`prepare` (every call refused in words) or one that gives the call what it
needs. Stitch and Edge Ring Select are refused; Blender's interface
operators (`INTERFACE_ONLY`, refused in a Blender with no interface) are in
the same table; `brush.asset_activate` gets the 3D View's tool first. The
search's `_UNSAFE_OPERATORS` is gone: `_refusal` and `run_operator` read the
table (`refusal`, `ask`). Every entry is wrapped as `bpy.ops` hands it out
(`_Unsafe`, from `_op_create_function`, which `_bpy.ops.create_function` now
names too, so a reload of `bpy.ops` and a direct `create_function` call get
the wrapper) and asked as it is called, so one looked up outside an override
and called inside it is asked as well.

**A macro went round all of it** (found this round). A script's own
`bpy.types.Macro` runs its steps inside Blender (`macro_exec`), past every
`bpy.ops` wrapper: in desktop, a macro of `UV_OT_stitch` exited 139 in
`stitch_exit` from `macro_exec` with every guard installed, also under the
borrowed view; one of `UV_OT_select_edge_ring` had not returned at 25 s; and
a UV Sphere of 1,600 × 1,600 (2,558,402 vertices), refused by its price when
called, ran as a macro's step with no count: still in
`add_primitive_uvsphere_exec` after 5 minutes at 100% CPU, killed. Guard:
`_bpy.ops.macro_define` (what `Macro.define` calls, looked up on every call
in 5.2.1's `_bpy_types.py` and the bundled 5.3's alike) refuses a step that
is in the table or priced (`macro_refusal`), as it is named — `UV_OT_stitch`
or `uv.stitch` (corrected October 21: `UV.stitch` and `Uv.stitch` got
through until then; see the review answered above). Loop Cut as a step was
measured CANCELLED with its default edge (-1) only and was left to Blender;
with an edge set it crashed, and it is refused as a step since October 21. A
macro of Add Cube is defined and runs.

**The brush pick** (`give_brush_tool`, one implementation; the Brush menu's
`_blenderkit_sculpt.ensure_view_tool` calls it). On the main thread, in a
brush mode whose 3D View has no tool, it makes one (`wm.tool_set_by_id`,
`builtin.brush`, under the borrowed view) before the pick. Off the main
thread it refuses in words: Blender gives out no workspace there, its
context reads Object Mode whatever the mode, and the pick exited 139 even
with the tool made. A script or console line that names `asset_activate`
runs on the main thread (`ScriptThread.brushPicks`, with its own note;
run-scriptthread-tests.sh holds it to `BRUSH_PICKS`). Measured on a copy of
the app's own autosave (Vertex Paint, 3D View tool None): unguarded, the
script line exited 139 in `WM_toolsystem_activate_brush_and_tool`; guarded,
the script line, the search, under the borrowed view, `create_function` and
the Brush menu each ran (FINISHED, Paint Hard, tool `builtin.brush`); on the
script thread refused, and the same call on the main thread after it ran.

**Mask Fill with no undo stack** (`paint.mask_flood_fill` →
`push_begin_ex` → `ED_undosys_stack_memfile_id_changed_tag`). No call
reaches it (corrected October 21: a script's own macro of Open then Mask Fill
did, and a sculpt operator in a load_post handler crashed in
`sculpt_update_object`; both are refused since, above): a file opened with no undo push at all, then Sculpt Mode — the
unguarded script line exited 139 in `push_begin_ex` from
`mask_flood_fill_exec`; with the guards the Sculpt header's Mask, the search
and a script line each made Blender's undo first (`require_undo_stack`) and
ran, and the script thread was refused in words. In the app a Run found one
Blender undo step before it entered Sculpt Mode (the history's first push
after the load; `_FileRead` makes the stack again after a script's own
load).

**The DEBUG `-eval64` hook no longer touches the draft.** It wrote its script
into `Scripts/.draft.py` before any view existed, so the editor would show
it; the container's draft was a test fixture that deleted every object. Now
`ScriptDocument.restored` shows the hook's script in memory
(`isLaunchScript`) and `saveDraft` writes nothing for it; `launchSource` and
the flag are DEBUG only. The container's draft is now the starter example
(corrected October 21: that example itself selects and deletes every object
when Run is pressed, `ScriptExample.starterSource`, as a fresh install's does;
whether Undo brings the scene back was not measured), what a
fresh install's Scripting tab shows (`ScriptExample.starterSource`, the
editor's fallback with no draft on disk).

**The modkinds memory control** read resident memory, which other jobs hold
down (the review: +65 MB under load against +144 MB alone). It reads
Blender's allocator now (`MEM_get_memory_in_use`, through ctypes): +144.0 MB
for the 6,000 × 6,000 picture's decode (6,000 × 6,000 × 4 bytes) and +0.0 MB
for the record, at a load average of 23 with the release build and a second
copy of the check running.

In the app (Vertex Paint autosave, tool None; the autosave put back after
each launch, the draft's and the three scenes' checksums unchanged, no crash
report): Run on the main thread (a script that mentions `temp_override`) —
Stitch, Edge Ring Select, Stitch with `EXEC_DEFAULT`, under the borrowed
view, looked up before it, `_bpy.ops.create_function` and four macro steps
each refused in words, Blender alive; Run off the main thread — the same
three lines and three macro steps refused; the Operator Search's
`brush.asset_activate` (succeeded, no banner, still Vertex Paint) and its
Stitch and Edge Ring Select (form greyed out, Run refused in the table's
words); a script that opens a copy of the autosave (tool None) and picks Paint
Hard — FINISHED, tool `builtin.brush`; the console — the tool read None, a
pick spelled so it stays on the script thread refused in words, the named
pick FINISHED with Paint Hard and `builtin.brush`; a Run that enters Sculpt
Mode and fills the mask — FINISHED, one Blender undo step; `-eval64` with
the Scripting tab — the editor's first line the hook's, the draft's checksum
unchanged, and the next launch without it showed the draft (`import bpy`).

Tests: `run-unsafe-blender-check.sh` (new, 78: every entry by every route,
the macro's steps, the brush pick on files saved in Vertex Paint, Weight
Paint and Sculpt Mode, the controls that crash or hang a Blender of their own
without the guard, Mask Fill by four routes); the opsearch check reads the
table; `run-scriptthread-tests.sh` 57 (the brush routing, and five on the
draft from the sources: one write of `.draft.py`, `saveDraft`'s early return,
`restored`'s order, `-eval64` in DEBUG only). Negative controls, each a
scratch copy with one fix reverted: without the macro guard 2 FAILED; without
the script-line wrapper and without the off-main-thread refusal the check's
own Blender segfaults (exit 139) at the first unguarded call; HEAD's
`BlenderLocalApp.swift` and `ScriptingWorkspace.swift` fail the draft checks
(3 FAILED); the image record asking Blender its size fails both memory
lines. `scan-app.py`: the Release build CLEAN (0 of 78 hook flags), the
Debug build's control sees all 78.

Crashes: none in the app. In desktop, all in sandboxed probes or the checks'
own controls: the macro of Stitch unguarded, under the borrowed view, and
with every other guard before the macro guard existed (exit 139 each; now
the check's own control), the unguarded brush pick on the autosave copy
(139), the two negative copies above (139); hangs killed: the macro of Edge
Ring Select (25 s) and of the 1,600 × 1,600 sphere (5 minutes before the
macro guard existed, 60 s with only it taken out).

Not done: the wrapper's own slot (`bpy.ops.uv.stitch._operator`) and ctypes
still reach Blender's operator unguarded; a script that names neither
`asset_activate` nor `temp_override` and picks a brush through an imported
module is refused on the script thread rather than moved. Seen, not
investigated: after a Run that enters Sculpt Mode and fills a mask, the undo
history's deferred probe chooses .blend checkpoints ("undo ran but did not
restore the scene", three launches of three). Fifteen Blender checks
(context, redo, tools, texpaint and eleven others) start desktop Blender with
the user's own HOME. This round's runner gave redo, tools and texpaint a HOME
and BLENDER_USER_RESOURCES of their own (context had run once before it did,
`-b --factory-startup`, 2 s), `~/Library/Application Support/Blender` was not
written (its newest file is from October 4), and the scripts themselves are
unchanged.

## October 20: The vertex budget, one price for every path (round 4's fix round)

### The review of this fix round, answered (October 21)

The review re-measured the budget with the app's own strings and found
seventeen ways round it; each is closed below, measured in desktop 5.2.1 with
the app's context (its modules, `_blenderkit_context.install`, `gpu.init()`,
its undo push), every probe a sandboxed Blender of its own, and the paths the
Swift sends also in the real iPad build on this Mac (Designed for iPad,
through the DEBUG hooks; the autosave and the draft put back after, the three
scenes' and the draft's checksums unchanged, no crash report).

**The Subdivision row** sends Levels Viewport and Render together, and the
whole change was priced as a render whose "now" already had a new
Subdivision's Render level 2. `price_all` now always judges the viewport and
judges a render's settings apart (`_pricing`, `counted_all`). A 400 × 400
grid under Subdivision 1 (641,601): the row's 1 → 2 refused at 2,563,201 in
desktop and in the app (`-modifier-steps`); bare, Blender makes 2,563,201.
Two Arrays (64, 32) with the camera off, then the row's 1 → 4: refused at
3,149,824 (a render counts 98).

**Operators** that give an object another's data or modifiers, rebuild its
base, or move it are priced as `bpy.ops` hands them out
(`_blenderkit_context.PRICED_OPERATORS` → `_blenderkit_budget.price_operator`),
so the Object menu, the Edit Mode panels, the search and a script line meet
the same price: Join (the meshes joined in numpy under the active one's
stack), Link/Transfer Data (Object Data, Modifiers, Fonts), Copy Modifiers to
Selected Objects (appended ahead of a pinned one, measured), Apply (the data
moved by what is applied, children kept in place), Edit Mode's Subdivide and
the curve's Subdivide and Extrude (bounds from the selection), QuadriFlow
(1.012 vertices per face asked, measured 500 to 20,000), Voxel Remesh through
the stack (`refuse_voxel_remesh` now ends with `price_voxel_remesh`), Detail
Flood Fill, Subdivision Set's time, a render (`price_render`: every object
at its render settings — a new Subdivision's Render level is 2), a
metaball's Duplicate, every Edit Mode operator that adds to the mesh
(`_EDIT_GROWTH`: Bevel's Segments, Spin's Steps, Bridge's Cuts, Extrude,
Duplicate, Inset, Poke, Solidify, Wireframe, Symmetrize, Fill Grid, Bisect,
Rip, Split, Intersect by a BVH of the mesh against itself, ...) and Object
Mode's moves (`_MOVES`: Move, Rotate, Scale and Mirror from what they are
called with, the snaps, the clears, Clear Parent, Set Origin). The moves are
priced before they run because they evaluate the scene inside the operator:
right after `transform.translate` of an Array's offset object to 0.0001 m the
Array's evaluated mesh already had 3,199,472 vertices. Measured, a cube under
Subdivision 4 with a 120 × 120 grid: Join refused at 3,691,779, Copy
Modifiers to Selected Objects, Copy Modifiers and Link Object Data at
3,690,241 — in desktop and in the app (`-object-ops join`, `-relations-ops
modcopy,links:MODIFIERS,links:OBDATA`); with the operator handed out bare,
Blender makes those counts. Edit Mode Subdivide at 10 cuts on a cube under
Subdivision 6 refused (counted 3,235,586; bare 2,973,698), in the app through
the redo panel's Number of Cuts. The curve under two Arrays of 64: 4 cuts
pass once (1,998,848) and the second press is refused at 10,051,584, in
desktop and the app (`-points-ops`). Apply ▸ Scale of an Array fitted to
100 m at a scale of 0.0001 refused at 4,000,008, desktop and app
(`-relations-ops apply:scale`, new); bare 4,000,008. QuadriFlow at 40,000
faces under Subdivision 3 refused before it runs; Voxel Remesh at 0.02 under
Subdivision 3 refused through the stack (the base alone passes it). The
gizmo's Move of the offset object by -0.9999 refused at 3,199,480 in the app
(`-transform-ops gizmo:`), -0.5 passed; Scale about the origin, Snap to the
3D cursor and Clear Location refused in desktop. A render of a 300 × 300 grid
at Render level 3 refused at 5,764,801 in the app (`-opsearch render.render`).
Edit Mode on a cube under Subdivision 5: Bevel at 100 Segments and Spin at
1,000 Steps refused, Extrude Region and Duplicate passed (12,292, counted at
or above it); Subdivision Set on an Ico Sphere at 7 refused for its time;
Detail Flood Fill at a Constant Resolution of 10,000 refused (priced, not
run).

**The Transform fields** (the N panel's and Properties ▸ Object's,
`TransformChannels.python(writing:)`) send the price first, each changed
field laid over the vector Blender holds (`price_channels`), so the line,
like the assignments, depends only on the fields written (the transform
fields' Blender check holds the string to the one Blender ran); Blender's
preview of a constrained edit runs the bare assignments
(`assignments(writing:)`), the commit prices once. The Item
tab's Dimensions price the scale they set (`_blenderkit_item.set_dimension`).
The three unpriced whole-vector writers in `Bpy` and `BpyCommands` were used
by nothing and are gone. Measured: the field's X 0.0001 for an Array's offset
object 1 m away refused at 3,200,008 in desktop and the app (`-object-ops
field:`); X 0.9 passed (360); the field's assignment bare makes 3,200,008.

**Through other objects.** `affected` follows every object, whatever its
type, through parents, constraint targets and modifier pointers; `_matrix`
recomputes a place from its channels and deltas, Dimensions (as the scale
they set) and a matrix (as the channels it sets), under a moved parent or
constraint target (a constraint's own arithmetic is kept as it is now and the
target's move carried over); the copy the budget evaluates reads a stand-in
for every object the change reaches (`_stand_in`: its data, modifiers and
place as they would be; a Hook's inverse kept, which its object setter would
reset — measured, it undid the move), and a mesh changed in its elements is
a copy (`data_of`). Measured: the parent of the offset object moved through
the Data API row refused at 3,994,584 (bare 3,994,576), in the app too
(15,978,320 at Fit Length 40, `-data-api`); a Hook's empty scaled 36, a Remesh
at 0.1 after it, refused (bare 3,119,048); a vertex moved to (2400, 2400,
2400) under a Remesh at 0.1 refused, to (5, 5, 5) passed; a Fit Curve's
curve's Delta Scale × 5e5 and its Dimensions × 1,000,000 refused. And a count
made only of close kinds (`_TIGHT`) that says an object is past the budget
while Blender holds it inside is a change Blender has not evaluated: the
curve's Delta Scale set bare (Blender keeps 16, MOD_array.cc adds no transform
relation), the next edit of the Array is refused.

**Caps of caps** are counted in full and once per pricing (a memo; past 64
levels, or a cycle, refused in words): the review's chain of 19 is refused
where it passes the budget (X00's End Cap X01), X00 counted exactly at
2,097,160; bare, Blender makes 4,194,312.

**New counts.** *Metaballs* (`_meta_base`; GEOMETRY_TYPES has META): a
family's basis polygonizes every member, bounded by twice the surface of a
box around each element's field over the resolution squared — measured at
most 0.80 of it over Ball, Capsule, Plane, Ellipsoid and Cube elements, radius
2 and 4, resolution 0.4 to 0.05, threshold 0.01 to 1.9; time follows the count
(1,000,000 in 2.8 s, the review's 4,000,000 in 112 s). Radius 8 at Viewport
Size 0.05 counted 1,228,807 against Blender's 159,528; 0.01 refused at
30,720,008 in desktop and the app; Add ▸ Metaball of Radius 300 into the
family refused in the app; a Duplicate at 0.04 refused. *Fluid* (`_g_fluid`,
`fluid_bytes`): a Liquid domain with Mesh is at most three vertices a cell of
the mesh's grid (Resolution Divisions × Mesh Upres, in the domain's
proportions), at every frame; the grids are priced for memory (measured
about 700 bytes a cell for a Liquid, 350 for a Gas, 107 and 67 a noise cell,
45 a mesh-grid cell — Mesh Upres 8 at Resolution 64 took 6 GB): Resolution
32 counted 786,432 against 3,424, Add Subdivision on it refused, Resolution
200 refused, a Gas at 300 refused for its grids. That bound refuses a
Liquid's Mesh at Upres 2 past Resolution 44; Upres 1 allows 94 — a trade-off,
measured, not a guess at splashes. *Volumes* (`_volume_grid`,
`volume_voxels`, `_g_volume_to_mesh`; COUNTED_TYPES has VOLUME): Mesh to
Volume's voxels from its source's surface and band (a 2 m cube at 512: 229 MB,
0.53 s), refused past 250,000,000; Volume to Mesh at 2.5 vertices per
voxel-sized square of the source's area (measured at most 1.13, an open
sheet); a volume read from a file cannot be counted and is refused. At 256:
counted 983,104 against 126,152; 1,200 refused. *Boolean* crossings
(`_crossings`): two vertices per pair of faces that meet, by a BVH, with
Boolean refined through Blender: two combs of 50 plates counted 20,800, as
Blender makes (800 before). *Solidify Complex*: up to two vertices a corner
(50 quads on an edge: 502 against 300; before 204). *Remesh* is refined
(OpenVDB is quick: 359,294 vertices in 0.09 s): a cube under a Remesh at 0.015
with Subdivision 2 passes at 1,698,146, exact (refused at 4,713,824 before).

**Time.** Subdivision Surface's limit surface: 0.1 ms per vertex and face
that is not regular, and 0.154 s × (k / 64)^3.5 for k > 8 edges or sides,
times Quality (`_limit_seconds`, fitted on N-Gons, fans, quad fans, cylinder
caps and UV spheres of 16 to 256, icospheres, grids of triangles; level does
not matter and Blender keeps what it built). Past 5 s, and heavier than now,
refused (`SUBDIVISION_SECONDS`). Add Subdivision on a Circle of 250 as an
N-Gon (estimated 18 s, measured 8.7 by the review), a Triangle Fan, a UV
sphere of 250 segments, an Ico Sphere at 7 (12.2 s measured) and the combs'
Boolean (909 s estimated; not done in 300 s, the review) refused, in desktop
and the app for the N-Gon; Suzanne, a 64 × 32 sphere and a cylinder of 128
(3.3 s) pass; with Use Limit Surface off it passes. Suzanne under a Remesh at
0.01 is refused for its time (8.8 s estimated, 6.2 s measured), no longer for
a count. *Dynamic Topology* strokes: each chunk is refused when what the mesh
has and what its dabs can add at the detail size (four times the triangles
of that edge the dab's circle holds, per mirror image) would pass the budget
(Constant 10,000 refused; Relative 12 px with a 50 px brush, 872 a dab).

**A frame change** (`_blenderkit_anim.frame_set`: the timeline, playback, a
scrub) is priced first from what each active action's F-curves set at that
frame (`price_frame`, `_animated`; an int keyed value taken at its ceiling):
a cube whose Array Count is keyed 2 → 400,000 over frames 1 to 100, frame 100
refused before Blender evaluates it (the frame stays 1), frame 10 passes
(290,920); Blender's own frame change makes 3,200,000.

**Non-finite.** A change with a number past 1e15 is evaluated before it
passes (`_finite_after`): an Array's Constant Offset of (1e38, 0, 0) refused
(bare: vertices not finite); a Displace at 3.4e38 on a cube is finite in
Blender (its vertices at 5,775) and passes. The mirror makes any coordinate
that is not finite 0 and says so once (`_finite_or_zero`): in the app, a
script's own 1e38 Array printed "A has 8 vertex coordinates that are not
finite numbers in Blender; they are drawn at 0", and nothing crashed.

**Tests that fail for these classes.** `run-budget-tests.sh` (host): every
`bpy.ops` call in a Swift string is priced by the factory or listed with why
it makes no more geometry (control: with Subdivide and Join off the list, the
scan names their calls), and no Swift string moves an object bare (control:
the builder's line off its list). The transform fields' suite holds the new
price line. `run-budget-blender-check.sh`: the sweep steps each viewport
setting with its render twin as the rows send it (a modifier hidden from
renders in front; control: priced as a render, it fails on Subdivision's
Levels), steps the place of the empty every Object pointer is set to, and a
Fluid domain's own settings, Gas and Liquid; part 8 holds each class above
through the app's strings with its control (90 checks). Shown failing in a scratch copy
of the tree with the fixes put back: the render-only price, `affected`
skipping non-geometry, the cut-off at depth 3, no priced operators, no
stand-ins, Fluid and Volume to Mesh keeping their mesh, metaballs uncounted,
Solidify as two shells, `HUGE` infinite, the operator for renders bare and the
Transform field's price taken out of the Swift — every corresponding check of
part 8 failed (the Remesh pass check was masked by the render-only revert in
the same tree; its own control shows the old 4,713,824).

Tests: `run-budget-tests.sh` 17 (sections 4 and 5 new); `run-budget-blender-check.sh`
180 in Blender, the sweep 286,249 row steps in 336 s and 134,529 data steps in
473 s (part 8 run again, 90, after the fields' line became `price_channels`);
the transform fields' host suite and Blender check hold the new line (the
check now loads the budget the app has on its path); the modkinds check's
control sets `COUNTED_TYPES` with `GEOMETRY_TYPES`. All 50 host suites pass
(the traceback suite again after a source changed under its build), and all
38 Blender checks pass (the animation check again after the frame price, the
region select check after the same concurrent build).

Crashes and freezes: none in the app and none in desktop outside the negative
controls. In the first control run the reverted metaball check let Viewport
Size 0.01 through, and Blender was polygonizing it (`BKE_mball_polygonize`)
when the run's alarm ended it at 25 minutes — the freeze the check exists to
stop; the second run took the rest of part 8. The same run's Subdivide, let
through twice, made 359,817,218 vertices in Blender; the control now starts
from a fresh cube.

Not done: Edit Mode's vertex moves (the gizmo and the Median field in Edit
Mode) are not priced, though moving vertices changes what a Remesh after them
is given; Align Objects and Randomize Transform move objects unpriced (listed
in the host scan); a constraint's own arithmetic is approximated; a frame
change prices the active actions' F-curves but not NLA strips, drivers or
keyed enums (a Fluid domain's bound holds at every frame); Geometry Nodes, Mesh Sequence Cache and
Volume Displace stay unmodelled; Triangulate in Edit Mode under a Subdivision
is not priced for the limit surface's time; QuadriFlow's own time (14 s at
40,000 faces, the review) is not capped; the time model was fitted on this
Mac, and an iPad may be slower; a script's own property assignments stay the
user's Python.


Round 4's reviews found a new way round the vertex budget after every repair,
each time the same kind of hole: a path that set a value with no price, or a
model that did not know what a value did. The final review re-measured seven
still open: an existing Bevel counted as making nothing (12 segments counted
512 against Blender's 65,024, and a Subdivision Surface at level 2 then
passed); a curve's or surface's base grown after its modifiers were priced
(the curve Data tab's lines went bare, and `set_property` priced only texts);
Remesh on a text grown without limit through its Size; an Array fitted to a
length through the Data API row (8 against 8,008); the text Offset row; the
Mirror row's axes going round Skin's loop cap; and non-finite geometry from
the ±FLT_MAX text ranges. Desktop is Blender 5.2.1 with the app's context
(its modules, `_blenderkit_context.install`, its undo push, `gpu.init()`), in
its own sandbox; "in the app" is the real iPad build with its bundled bpy on
this Mac, Designed for iPad, through the DEBUG hooks, every sequence run in
desktop first (the autosave and the draft backed up and put back, the user's
three scenes checked unchanged).

**One price** (`_blenderkit_budget.py`, new). The old price listed what it
priced (`_LEVEL_KEYS`, `PRICED`, `_ADDED`) and counted through `_through`,
which knew a handful of kinds; anything off a list went through. Now every
path says only what would change — a `Prices`, the values laid over
Blender's own (`Prices.get`), modifiers that would be added (`Virtual`, at
Blender's defaults read from RNA), a new order — and hands it to one
judgement (`_judge`), which counts every object the change reaches
(`affected`: an object, each that uses changed data, each that reads one of
those — a Bevel Object, an Array's caps, curve and offset object, a Boolean's
operands, a Particle Instance's emitter) through one model of the whole
stack. Nothing chooses which settings matter: a setting the model reads is
priced on every path, and one it does not read cannot change its count. The
paths: every modifier row's edit carries the price of every setting it sends
(`Bpy.modifierEdit` → `priceModifierEdit` → `price_modifier`; the old
per-row `checkModifierSetting` is gone), Add Modifier (`price_add`), the
curve Data tab (`PointsBpy.set` → `price`), the text Data tab and Body Text
(`_blenderkit_text` → `price_all`), the Data API row on any struct
(`set_property` → `price`), and the Operator Search's modifier operators —
Add, Copy, Copy to Selected, Move Up and Down, Move to Index
(`run_operator` → `_price_modifier_operator`). `_blenderkit_multires`'s budget
names delegate to it.

**The model** (`_GROWTH`) has an entry for every one of Blender's 57
non-Grease Pencil modifier types: Bevel (an upper bound from what corners and
edges become, measured over six meshes, every miter and vertex mesh method, 1
to 64 segments; with an angle or weight limit, the edges it bevels read from
Blender's mesh of what it is given), Remesh (the Sculpt header's Voxel Remesh
estimate from the area, curvature and pieces of what it is given — one numpy
implementation now, shared — with a 1.3 margin the completeness check found
needed: a ribbon a voxel thick made 7% over the estimate; Blocks, Smooth and
Sharp at the octree's cell), Array (Blender's own Fit Length and Fit Curve
arithmetic from MOD_array.cc, with its 2^26 limit; exact at 0.5 to 2,000 m),
Mirror (2, 4 or 8 copies by the axes), Screw, Ocean, Skin, Wireframe,
Solidify, Edge Split (each corner a vertex, plus the vertices no face uses,
read from the mesh: exact at Split Angle 0 again, where V + C had counted an
800 × 800 grid at 3,201,601 against 2,560,000), Boolean, Triangulate,
Decimate, Particle Instance (its emitter's particles), Explode, the pure
deforms and attribute writers as keeping what they are given, and Mask,
Build and Weld as only removing. Five are not counted, each with why
(`_UNMODELLED`): Geometry Nodes (a node group can build anything; the app's
rows edit Smooth by Angle's two inputs and Add Modifier adds an empty group),
Mesh Sequence Cache, Volume to Mesh, Mesh to Volume and Volume Displace (a
file or a volume the app never makes). A count that is a bound and passes is
enough; one past the budget is made exact where Blender can be asked within
it (`_final`): the stack up to the last bound inside the budget is evaluated
on a copy, never through a kind Blender is slow on. So Bevel's bound, loose on
a smooth mesh, refuses nothing an exact count would pass. Curve, surface and
text bases are Blender's own build of their data with the change made, built
only once a bound says it fits. A change that would put a curve's or text's
vertices at infinite or undefined positions is refused in words (the text
Data tab's Offset and Depth at ±3.4e38).

**Add ▸ Mesh's primitives** were not priced at all: RNA takes a UV Sphere's
Segments and Rings to 100,000 (10^10 vertices), a grid's subdivisions and a
circle's, cylinder's and cone's Vertices to 10,000,000, an Ico Sphere's
Subdivisions to 10 (2,621,442). Adjust Last Operation holds them to its
sliders (a grid's typed 100,000 is 1,000), but the Operator Search and a
script line do not. `_blenderkit_context` now hands out each one whose
settings change its count priced (`_PricedAdd` → `price_primitive`: the
count from its own settings and RNA defaults, exact against Blender for the
ten kinds measured, a cone to a point over-counted; in Edit Mode, where
Blender adds it into the edited mesh, through that mesh's stack — a 300 ×
300 grid into a cube under a level-4 Subdivision refused, with no modifier
added). Plane, Cube and Monkey make 4, 8 and 507 whatever they are given and
are left as they were. Its first test froze this round's own check: a
cylinder of 1,000,000 vertices is 2,000,000, inside the budget, and Blender's
N-Gon cap fill had not finished after 30 minutes. Measured in a sandboxed Blender with a timeout: an N-Gon fill grows
far faster than its sides (a circle's 2,000 0.08 s, 4,000 0.33 s, 8,000
1.8 s, 16,000 4.6 s; a cylinder's two caps 0.25 s at 2,000, 4.5 s at 4,000)
while Triangle Fan and Nothing stay linear (1,000,000 with no caps in
0.95 s). Guard: an N-Gon fill past 2,000 sides is refused in words
(`NGON_SIDES`).

Each bypass, in desktop through the rows' own lines and in the app:
- Bevel on 64 separate cubes: Segments 12 counted 67,900 against Blender's
  65,024 (was 512); a Subdivision Surface below it at level 2 counted
  1,222,200 against 1,038,464 and passes; level 3 refused at 4,153,472
  (the bound refined to Blender's count). In the app, through
  `-modifier-steps`: the same numbers, the banner's sentence, Blender kept
  level 2; the Operator Search's Add Modifier ▸ Subdivision Surface on top
  refused at 4,153,472.
- A Bézier curve under two Arrays at 64: the curve Data tab's Depth 0.05
  passed at 638,976 (Blender's), Bevel Resolution 32 refused at 3,620,864,
  Resolution Preview U 64 at 3,194,880, Extrude 0.5 passed at 1,171,456
  (Blender's) — in desktop and in the app (`-points-ops data:`); the review
  had the app's own count at 18,104,320 with nothing refusing. A NURBS
  sphere under an Array at 64: the Data API row's Resolution U 64 passed at
  655,360, V 64 refused at 10,485,760 (in the app through the new
  `-data-api` hook, which sends `BlenderDataBrowser.setCommand`, the row's
  own string), and the spline's own Resolution V too. A text bevelled by a
  circle under an Array of 100 (1,032,000): the circle's Resolution Preview
  U 64 on its own Data tab refused for the text (5,504,000).
- 'Hello' under a Remesh at 0.1: the text Data tab's Size 1, 4 and 16 counted
  649, 5,406 and 67,792 against Blender's 248, 2,226 and 27,622 (was 215 each
  time); Size 1,000 refused at 241,268,405. Same in the app
  (`-textimage-ops text:`).
- An Array set to Fit Length through the Data API row: 2,000 counted 8,008,
  Blender's (was 8); 2,000,000 refused at 8,000,016; with an Object offset
  1 mm away Fit Length 1,000 refused, and moving that object to 0.01 mm
  through the row refused; Fit Curve counted from the curve's length and
  scale (scaling the curve by 1,000 refused). In the app: 8, 8,008, refused
  at 8,000,016.
- The text Offset: 50 '*' under an Array of 64, Offset 10 counted 761,600,
  Blender's; under 300 copies refused at 3,570,000, and Offset 0.5 passed at
  1,890,000 (Blender's) — those two in the app too.
- Skin under Mirror X on a 10 × 10 grid (199 loops): the Mirror row's X Y Z
  refused at 793 loops, Blender keeping X; X Y passed (397). The Data API
  row's use_axis X Y Z refused the same. In the app: both, the row's line
  carrying `use_axis` in its price.
- Non-finite: Offset and Bevel Depth 3.4e38 refused in words, Blender's text
  finite; Offset X 3.4e38 only moves the text and passes. In the app: refused
  on 'Hello'.

**Ordinary edits pass.** Desktop, each counted at or above Blender's and
priced in 0–15 ms: Suzanne at Subdivision 2 (7,958, exact), a 128 × 64 UV
sphere with Bevel 4 (240,371 against 8,066 — the bound, passing), 'Blender
Local' with Extrude and a Bevel at 4 (12,264, exact), a bevelled circle under
an Array of 20 (30,720, exact), a cube under a Remesh at 0.02 (147,790 against
61,208), Suzanne mirrored on X Y Z then Subdivision 2 (63,664 against
63,048), a NURBS torus at 16 × 16 (16,384, exact), a cube with Bevel 3, Array
10 and Subdivision 2 (20,720 against 15,380). In the app (`-modifier-steps`,
each step timed with Blender's evaluation and the mirror): Suzanne +
Subdivision, level 2, + Mirror, Y, + Bevel, Segments 4, + Array, Count 10
(366,240, Blender's, the Bevel's bound of 1,873,144 refined), then a
128 × 64 sphere + Bevel, Segments 4, + Remesh, + Solidify, + Screw: every
step passed, 71 ms to 3.2 s (the last Array at 366,240 vertices); a grid
added and adjusted to 1,000 × 1,000 (1,002,001); a cylinder of 1,000,000 with
no caps from the search (2,000,000, the app at 1.39 GB resident).

**Making the next one impossible to miss.** `scripts/run-budget-tests.sh`
(host, 12): every change each of the 36 kinds' own fields can make — 226 edits
— starts with the price, and the price names every setting the edit sends;
all 145 Add Modifier rows on five object types are priced first; and a source
scan fails any Swift string in Sources/ that assigns a modifier's or a curve's
setting except through the priced builders (an allow-list of five, each with
why). `scripts/run-budget-blender-check.sh` (desktop): (1) the model has every
modifier type; (2) completeness — for every type Add Modifier offers on a
mesh, a curve, a text and a surface, every int, float, enum and bool setting
(and its Object pointers, set to a heavier object) is stepped up and down
from a small fixture, alone and with each enum and bool switched (a growth
can hide behind another setting: Fit Length counts only once Fit Type is Fit
Length), and every such setting of the curve's, surface's and text's data and
first spline, alone, under an Array and under a Remesh; at each step the
budget's count is held to Blender's evaluated count, and a setting that grows
Blender's mesh 1.5 times while the count does not follow fails, unless it is
on the allow-list with its measurement (empty: nothing needed one). 275,357
row steps in 130 s and 134,214 data steps in 666 s pass. (3) the bypasses
above through the rows' own lines, each with its control (the lines without
the price run); (4) the ordinary edits; (5) non-finite; (6) Remesh's numpy
measures held to the old Python walk; (7) the primitives. Shown failing: in a
scratch copy of the tree with Bevel and Remesh counted as making nothing
again (round 4's bypasses put back in the module's own table), the sweep
missed 387 row settings and 564 data settings (Bevel's Segments on every
object type, a text's Size and Offset under its Remesh, …), and part 3 gave
back the review's numbers — Bevel 12 counted 512, Subdivision 2 counted
6,272, the text's Size counted 215 each time; with the rows' price taken out
of `modifierEdit` in the same copy, the host suite failed 4 (226 edits
unpriced, the Bevel's Segments, the Mirror's axes, a quoted name). In-check
controls fail the sweep with Bevel's growth taken out and with a fitted Array
counted as one copy.

Existing checks moved to the one price: the guards check holds the cheap
count at or above Blender's and the refined count to it (Solidify's Rim Fill
is a bound: 76 against 52 on a closed cube under a level-1 Subdivision, which
the old check asserted exact); the modifier, modkinds and points checks read
the rows' price line and the budget's own memory figure, Ocean model and
object types, and load the budget and Knife Project's module as the app has
them on its path (a half-run module had been left in `sys.modules` by a failed
load, answering every later price with an AttributeError: `_sibling` now takes
it out again).

Crashes and freezes: none in the app. One freeze in desktop Blender, in this
round's own check — the 1,000,000-vertex N-Gon cylinder above, killed after
30 minutes; guarded by `NGON_SIDES`. The crash reports desktop Blender left
today during these runs (20:37, 20:38, 22:31) are the guards and undostack
checks' own negative controls — Blenders of their own, started to show that
the unguarded loop cut, brush pick, interface operators and Sculpt undo
crash — as those checks are designed to.

Tests: `run-budget-tests.sh` 12; `run-budget-blender-check.sh` 96 in Blender;
the guards, modifier, modkinds and points checks updated. All 50 host suites
pass (mirror's and snap's timing checks failed once at a load average near
100 from other work on this Mac, and passed run alone), and all 37 Blender
checks pass.

Not done: an Array fitted to a length counts its copies from the mesh's size
and the offset object's place, and a viewport drag of either (the gizmo, the
N panel, Edit Mode) is not priced, nor are Edit Mode's mesh operators
(Subdivide's Number of Cuts to 100 on a large mesh) or Geometry Nodes; a
script's own property assignments stay the user's Python; each priced change
on a text, curve or surface still builds its base mesh beside Blender's copy,
which the memory check does not allow for (low).

## October 20: The Cursor tool and Measure's review, answered (round 4, group 9)

An adversarial review of the October 19 entry (the Cursor tool, Measure, Edit
Mode's measurements) found one critical defect, five medium and seven low.
Each fix was measured: desktop is Blender 5.2.1 with the app's context (its
undo push, `gpu.init()`, the borrowed 3D View where the app borrows it); "in
the app" is the real iPad build with its bundled bpy on this Mac, Designed
for iPad, through `-measure-ops` from scenes its `py:` scripts made, each run
in desktop first (the autosave backed up and put back, the user's three
scenes unchanged).

**Edit Mode's measurements are bounded (critical).** The read wrote every
selected element into one line of JSON, parsed on the main thread, and the
Canvas drew a view per label: the review measured 90,000 faces, everything
selected, all four switches on, at 2.4 s in Python and 65 MB of JSON (1.95 s
and +219 MB to parse, 810,000 labels at 0.77 s a redraw), and 490,000 faces at
12–14 s and 355 MB. Now `_blenderkit_measure.edit_overlay` is Blender's whole
read, as before, while it stays within `LABELS` (1,000 — a Canvas label costs
17 µs on this Mac, 1,000 in 16.8 ms, measured with the overlay's font, and
about that many fit on an iPad's 3D View). Past it the read stops and is
culled to the view the overlay draws, whose world-to-clip matrix the call now
carries (`MeasureOverlays.python(global:view:)`): selected edges whose segment
reaches inside the view's side planes (the app's own `clip`, done on every
edge at once with numpy over the mesh `update_from_editmode` writes, as the
mirror pass does), selected faces whose corners' box reaches inside them
(both of a face's labels are in that box); and if more are still in view,
every n-th of each. The rows are the whole read's own (one function per
element, shared), and the overlay says what it left out: "Measurement: 1,005
of the 656,658 values in view are drawn, one in every 657. Zoom in or select
less to read them all." A view change reads again only when the last read was
culled to the view, once the view has rested a quarter of a second. Face
Area's tessellation is face by face now — BMesh's own split of a quad
(`is_quad_flip_v3_first_third_fast`) and an n-gon's polyfill read from the
mesh's own tessellation (`_Tessellation`) — because `BMesh.calc_loop_triangles`
made a Python tuple per triangle of the whole mesh: 286 MB at 490,000 faces
(tracemalloc). The Canvas also draws a label only where its anchor lands
inside the view, as Blender's text cache does (`DRW_text_cache_draw`,
V3D_PROJ_TEST_CLIP_WIN).
- Desktop: 90,000 faces, all four: 99 ms, 79 KB, a Python peak of 26.5 MB
  (unbounded, the control: 2.4 s, 65 MB, 268 MB); 490,000 faces: 522 ms,
  80 KB, 71 MB (Edge Length alone 177 ms, Statistics alone 26 ms); the mirror
  pass's own Python half on that mesh takes 370–400 ms. The per-face
  tessellation gives BMesh's areas to the bit on a jittered grid with and
  without an active shape key (130 faces differ when every quad is split
  0–2, the control); with no view and nothing to thin, the culled read writes
  the whole read's rows exactly; culled to three views it keeps every one of
  the 22,296 labels the app draws (with the planes pulled in 5%, the control,
  150 are lost); 22,500 faces all selected: 1,005 labels and 104 KB in 35 ms,
  against 202,500 labels and 20.9 MB in 621 ms unbounded.
- In the app: 90,000 faces, all four: 123 ms on the main thread, 79 KB, 1,005
  labels of 768,492 in view; an orbit, one read once the view rested, 113 ms;
  zoomed in, 1,000 of 79,646 (every 80th); 20 faces selected, the whole read,
  31 ms, 201 labels, no note. 490,000 faces: 616 and 566 ms, 80 KB, 1,005
  labels; the app's peak resident size, with that mesh mirrored, 1.2 GB.

Not done: the read stays on the main thread, as every bpy call the interface
makes does. The one other thread bpy runs on is the script thread, and only
while a script holds the interface (`BpySession.isRunning`); a read there
beside the main thread's mirror passes is the two-thread use BpyRuntime's own
note says bpy tolerates far worse. Bounded, it costs about one mirror pass.

**Geometry and the cursor's drag follow Blender's final geometry (two
medium).** The Geometry orientation was refused under any modifier that
rebuilds the edit mesh (`editRegionRefusal`, the rule for handing Blender its
elements), and the drag snapped to every mirrored mesh. Blender's Geometry
click and its cursor transform both snap to the final geometry
(SNAP_GEOM_FINAL; the cursor's transform has no T_EDIT), which is the mesh the
mirror holds except under a Subdivision Surface evaluated last: that one
returns its input as the final mesh and subdivides only for whoever asks
(MOD_subsurf.cc), and Edit Mode's snapping reads the final mesh as it is
(`BKE_object_get_editmesh_eval_final`). The mirror now says so per object
(`|subdivlast`, `_blenderkit_cursor.subdivides_last`: the last modifier on in
the viewport and in Edit Mode, of a type Edit Mode evaluates, that is not off
by its own `is_disabled` — read from RNA for the types whose test RNA shows,
counted as maybe off for the rest), and only there the tap refuses and the
drag leaves the edited object out of its snap, saying why in its readout
(`BKObject.finalGeometryRefusal`, `CursorTool.dragExcluded`).
- Desktop (`run-measure-blender-check.sh`): Blender's own cursor3d with a made
  event at 1,333 pixels under each of ten stacks, against the mirror's
  `to_mesh()`: it met the mirror's mesh everywhere with no modifier, Mirror,
  Array, Subdivision Surface then Mirror, then Simple Deform, one hidden in
  Edit Mode, one at level 0 then Mirror; and not under Subdivision Surface
  alone (52 pixels), Mirror then Subdivision Surface (95), or Subdivision
  Surface then a Boolean with no object (52) — exactly the stacks
  `subdivides_last` names. The old rule is wrong under five of them.
- In the app: a cube at x = +2 with a Mirror, Edit Mode, front view, Geometry:
  a tap on the copy at x = −2 placed the cursor on it, turned to its face
  (normal (0, −1, 0), the drawn Z axis (0, −1, 0)); under a Subdivision
  Surface the same tap was refused on the banner in the new words, View
  placed on the subdivided surface (y = −0.70), and a drag with Snap on to
  Vertex past a subdivided corner did not snap and said why.

**The Cursor's settings no longer leave unnamed tools (medium).**
`set_settings` made the mode's workspace tool with
`from_space_view3d_mode(create=True)`, named '': measured again in desktop,
kept by a save and a reload, and Blender's `wm.tool_set_by_id('')` then
answered CANCELLED ("Tool '' not found"). Now the tool is made as Blender
makes one, through `wm.tool_set_by_id` with the mode's default
(`toolsystem_default_tool`: Box Select), and an unnamed one an earlier build
left is named the same way. Only in the modes whose default is Box Select
(Object, Pose and the Edit Modes): Edit Text's Select Text cannot be started
without a window — measured, its `tool_set_by_id` failed in Blender's own
`_activate_by_item` and left an unnamed tool — so there, and in the brush
modes, a write with no tool yet is refused in words. Desktop: Box Select made
for Object and Edit Mode from factory startup, an unnamed lattice tool named,
all three kept by a save and a reload with the UI and set again by Blender's
own `tool_set_by_id` (FINISHED), Edit Text refused with no tool left, Sculpt
Mode's own tool written to and left Brush. In the app: Edit Lattice had no
tool; one made the old way read `''`; the bar's Orientation then left it
`builtin.select_box` holding Transform.

**The 3D cursor is drawn turned (medium).** The crosshair was three
world-aligned lines, so View, Transform and Geometry all looked alike. It is
Blender's overlay now (`CursorGlyph`, overlay_cursor.hh): the cursor's own
axes turned by its rotation, a widget unit (20 points) out, the outer part in
the theme's axis colours (the negative ends shaded as
`get_color_blend_shade_3fv` shades them), the rest black (View Overlay, read
in desktop), a white and red circle facing the viewer, drawn over everything
as Blender's pass is. In the app: Transform with Local on a cube turned
(0.3, 0.2, 0.5): the cursor's axes are the cube's, and the drawn axes the same
to four places.

**A new or opened file takes the rulers with it (medium).** The rulers are the
app's, in the scene object that outlives every load. The mirror now carries
how many files have been loaded in front of the reader (`file` record,
`_blenderkit_undo.file_loads`: File ▸ New, Open, Recover, a script's load, but
not the undo history's own checkpoint loads), and a new count clears them.
Desktop: New and Open each counted one, a checkpoint load none (Blender's own
count, the control, took all three). In the app: a ruler, then
`read_homefile`: none left.

**Low, fixed.** A Cursor drag no longer brings auto keying's follow-up
(`BpyAnimation.transformMode` skips `cursor_transform=True`; in the app, Auto
Keying on with Only Insert Available, a drag: no banner, no action). Ruler
Remove takes only the angle when the angle point was the part last pressed,
as RULERITEM_USE_ANGLE_ACTIVE does (in the app: an angle dragged out, Ruler
Remove, the ruler left as a length ruler, active), and a tap on nothing
leaves the active ruler (`RulerTool.tap`; in the app the ruler stayed
active, and the next Ruler Remove took it). Delete is enabled for Ruler Remove
with no active object (built; the menu state is not reachable from a hook).
The cursor drag reads Ctrl on every move (in the app: snapped, with Ctrl
held not snapped, released snapped again), and says when Snap Target holds
elements it does not follow, as Increment, Blender's factory setting.
`run-measure-blender-check.sh` keeps the measure phase's exit code, and
Global's edge angles, face angles and areas are now held to Blender's
formulas (in double, apart from the module) on the three fixtures.

**Not done (low).** Ruler Add and Ruler Remove push no undo step (Blender's
do: the rulers are the app's, not data Blender's history holds); Surface
Project and Geometry still pass through an object sent as its bounds, with no
word; Statistics outside Edit Mode; the cursor's rotation in the Sidebar;
Increment stepping of the cursor's drag.

Crashes: one, in desktop Blender during a probe — `WorkSpaceTool.setup()`
called from Python on a tool `from_space_view3d_mode(create=True)` made
(WorkSpaceTool_setup_call, exit 139, report Blender-2026-10-20-145846). Guard:
nothing calls `setup`; tools are made only through `wm.tool_set_by_id`, in the
modes where it was measured to work. None in the app.

Tests: `run-measure-tests.sh` 119 (the call's view row by row, a thinned
record and its note, Geometry and the drag under Mirror and under a last
Subdivision Surface with the old rule as control, the snap note, the auto
keying skip, the drawn cursor turned with the world-aligned drawing as
control, Ruler Remove's angle and the tap, the file record clearing rulers);
`run-measure-blender-check.sh` 46 in Blender (was 22: the tools, the stacks
against Blender's own click, the bounded read, Global, the file loads).

## October 20: Collections, constraints and Local View's review, answered (round 4, group 7)

An adversarial review of the October 19 entry (collections, constraints, the
Object menu's search-only rows, Local View) found three high defects, four
medium and five low. Each fix was measured: desktop is Blender 5.2.1 with the
app's context (its undo push, `gpu.init()`, the borrowed 3D View where the app
borrows it); "in the app" is the real iPad build with its bundled bpy on this
Mac, Designed for iPad, through `-relations-ops` and `-object-ops` from scenes
their `-eval64` scripts made, each script run in desktop first (the autosave
backed up and put back, the user's three scenes checked unchanged).

**Local View: every 3D View command takes only what it holds (high).** Only
Select ▸ All and Invert ran under the borrowed view; every other command ran
with none, so Select by Type, Random, Pattern, Grouped, Linked and Mirror
selected objects the 3D View does not draw, and Delete, the gizmo's commit,
Mirror, Randomize and Move to Collection acted on them — the gizmo previewed
the drawn ones and committed all. Now `BpyBridge.execute`, which every menu
row, key, gizmo commit and redo-panel re-run goes through, sends its source
inside `_blenderkit_localview.run` while the mirror shows Local View
(`LocalViewBpy.scoped`): in Object Mode, on the main thread, with Blender in
Local View, it runs under the borrowed view, as Blender runs its 3D View's
commands there (`BKE_base_is_visible` checks the view's bit, so
`selected_objects`, `visible_objects` and a proportional move's neighbours
hold only what Local View holds); otherwise it runs bare. The two special
cases (`LocalViewBpy.selectAll`, `localViewSelectAll`) are gone. A
constrained drag's frames run in the same scope. Measured before choosing it:
124 of the app's Object Mode bodies (the Select menu, Delete, Duplicate, the
Object menu's rows, a gizmo Move, Rotate and Scale in every orientation,
proportional and Individual Origins, the adds with `include_active`, Move and
Link to Collection, Local View's own rows), each from the same fixture with
every object in Local View, plain and under the view: the same scene for all
but one kind. An unconstrained `transform.rotate` turned the other way: in a 3D
View Blender flips the axis of a rotation with no constraint axis
(`transform_mode_rotation_axis_get`) — value 0.4 about Z took a cube at 0.7 rad
to 0.3, where the app's preview, a headless Blender's, says 1.1. So under the
scope such a call is sent with its value negated, the same turn about the
flipped axis (`_blenderkit_context._Rotate`, `flips_rotation`); then all 124
the same. No crash in any of it.
- Desktop (`scripts/run-relations-blender-check.sh`): Local View holding Cube
  and Cone, with Sphere and Light outside it and selected (as an Outliner tap
  selects them): Select by Type, Pattern, Grouped, Linked, All, Invert,
  Random, Delete, Duplicate, the gizmo's Move, Rotate and Scale, Rotate,
  Mirror, Randomize and Move to Collection each changed what Local View holds
  and left every object outside it as it was; the bare bodies, the control,
  changed objects outside it in every one but Random. A duplicate joins Local
  View; Rotate under the scope turned Cone 0.4, as the bare call does
  (control, with `flips_rotation` off: -0.4); outside Local View the scope
  changes nothing (the same Move moved every selected object).
- In the app: Cube and Cone in Local View, Cone, Sphere and Light selected;
  Select ▸ Select All by Type ▸ Mesh (the menu's `select`) selected Cube and
  left Sphere and Light selected and untouched; the gizmo's Move Z (below)
  moved Cube to z 1 and Cone to 0.5 (its Limit Location) and not Sphere or
  Light; Mirror X mirrored Cube and Cone alone (determinant -1, Sphere and
  Light +1 where they were); Move to New Collection took Cube and Cone alone;
  Select Pattern * said Blender's "No unselected object's name matches" (both
  drawn objects already selected, Empty and Lattice outside left unselected);
  Delete (X) deleted Cube and Cone, left Sphere and Light, and Local View
  ended with it empty, as Blender's redraw ends it; Undo put both back.

**A constrained drag holds everything else (high).** A drag Blender previews
(`_blenderkit_constraints.drag_frame`) puts the channels back and runs the
release's call again each frame, the curve-point drag's design, but held
nothing: Undo, a key or the autosave could run between frames. Now
`BpyBridge.beginConstrainedDrag` opens `BpySession.constrainedDragOpen` and
`endConstrainedDrag` closes it before the commit runs; `gestureHold` includes
it, so `execute`, Undo and Redo (`canUndo`), the console, scripts and
`autosaveIfQuiet` wait, saying "Objects are being moved. Lift the finger
first." `_blenderkit_undo.step` refuses while a drag is open, a drag begun
over one whose end never came ends it first (in Swift and in
`drag_begin`), the viewport ends one when it is torn down, and a Transform
field's scrub that the system cancels now ends once, committing what it
previewed, as a cancelled gizmo drag commits (`BNumberField` keeps a
`@GestureState`; its `onEnded` is not called on a cancel), as does a panel
closed mid-edit (`ObjectTransformFields.onDisappear`). Those two are built
and not run: a cancelled SwiftUI gesture and a closing sheet cannot be driven
through a hook here.
- Desktop: the review's case — Limit Location, Move Y to 2, a frame, Undo —
  is refused in words with the step still Move Y and y 2; after the drag's
  end y 2, z 0, and Undo then undoes Move Y. The control, the same Undo with
  the guard out of the way: the cube back at y 2 at the constraint's step,
  the review's corruption.
- Host (`scripts/run-relations-tests.sh`): the hold refuses a command, Undo
  and Redo mid-drag, lets a frame run, ends at `endConstrainedDrag`, and a
  drag over an unended one ends it first; a field's edit of a constrained
  object holds until its commit and writes once; without a constraint it
  holds nothing.
- In the app: Undo pressed in the middle of a gizmo drag left Blender's
  active step where it was ("Select by Type" before and after; "Local View"
  in another run), the hold said so; a field's edit held while Blender
  previewed it and let go after ("hold after: none").

**A lattice's constraints reach the interface (high).** `_push_lattice` now
sends the constraints record, as the other three push paths do. Desktop: a
lattice and an empty with Copy Location both send one; the Swift replay of
that pass shows each one's constraint and its evaluated place (the lattice
going through its own path, drawn as its grid). The control, the old line
back in a scratch copy: the lattice's record is missing and the replay's
"Lattice's constraints are Blender's" fails. In the app the mirror's Lattice
carries Blender's Copy Location (the hook's print of what the app holds) and
is drawn at Blender's (3, 0, 3).

**Local View frames an object with no box as Blender does (medium).**
`LocalViewFraming.box(of:)` is Blender's `BKE_object_minmax`: an object with
a box adds the box's min and max corners through its matrix (only those two),
one without — an empty, a light, a camera — its location ± its scale, an
empty's times its display size. Desktop, the borrowed view against the Swift
on the mirrored objects: an empty, a point light and a camera alone each
3.2081 away about their own place, an empty of display size 2 and scale
(1, 2, 1) 12.8325, a cube turned 0.7 about Z 4.5204 (the two-corner rule);
the control, the objects' world bounds, frames the first four elsewhere (the
near limit, 0.075 m). In the app an empty and a point light alone in Local
View were framed 3.8889 away (the app's lens and its 1194 × 730 view, the
distance a 2 m cube gets), about their places, where they had been 0.075 m.

**A collection linked into two parents (medium).** The record gives each
layer collection its path (`path=10/12`, the uids from the Scene Collection's
child down), `CollectionTree.Entry.id` is that path, `children(of: entry)`
lists an instance's own children and `children(of: uid)` a collection's,
once each; the Outliner folds and renames by the instance. Exclude from View
Layer, Hide in Viewport and the active collection name their instance
(`set_exclude(uid, value, path=[…])`, `layer(uid, path)`); Disable Selection
and Disable in Renders are the collection's own. Host: Scene ▸ A ▸ C ▸ D and
Scene ▸ B ▸ C ▸ D with Cube in D give C, D and Cube under A and again under B,
nine rows with distinct ids; without the paths (the control) the tree is not
Blender's. Desktop: B ▸ C's checkbox excluded B ▸ C and left A ▸ C, its eye hid
B ▸ C alone, a tap made that instance active, the replayed Outliner tree
Blender's; the control, the uid alone, excludes A ▸ C. In the app the
Outliner's tree and its accessibility listing showed both instances, B ▸ C's
checkbox On and A ▸ C's Off after B ▸ C's was pressed.

**An instancer is not moved into what it instances (medium).**
`check_move` refuses, in words, a move or link of an object whose
`instance_collection` is the target or holds it (Blender's cyclic check,
`collection_object_add`), and Move to New Collection inside one. Desktop: an
empty instancing Parts, into Parts, into Inner inside Parts, linked into
Parts and moved into a new collection inside Parts, each refused with nothing
changed; into Collection it moves. The controls, Blender's own operators: Move
left the empty in no collection with no users, out of the scene; Link
answered and changed nothing. In the app all four refused on the banner
("Move to Collection: Instancer instances Parts, so it cannot be moved into
Parts, which is inside what it instances; …") and the move into Collection
was a "Move to Collection" step. `_selected_or_refuse` reads the context's
`selected_objects`, which the operator takes (only what Local View holds,
under the scope).

**The preview numbers come from the shipped code (medium).** The `gizmo:`
tokens of `-relations-ops` and `-transform-ops` now drive the 3D View on
screen through its own `beginGizmo` (the handle its hit test finds),
`updateGizmo` and `endGizmo` (`MetalViewportView.Coordinator.debugDrag`), and
the `-object-ops field:` token drives `TransformFieldDrag`, the type
`ObjectTransformFields` now runs — the view is a binding over it. The negative
control `constrained-preview:off` is read by `BpyBridge.beginConstrainedDrag`
itself. The desktop check runs the Swift's own strings through `drag_frame`:
`LastOperator.gizmo` for the Move (as `TransformGizmo.commitOperator` builds
it) and `TransformFieldEdit.python` for Location Z. In the app: the gizmo's
Move Z on Cube and Cone in Local View, Cone with Limit Location (max z 0.5),
previewed 0.00 m from where Blender put them, every drawn object's place
0.00 m from where it ended; with the control, 1.00 m. A field, Location Z to
1 on a cube with Copy Location from a sphere and Limit Location: 0.000 m (the
cube held at the sphere, (3, 0, 0)); with the control, Location Z to 0.25,
0.750 m.

**The Operator Search in Local View, and Blender's own interface (found
taking over the repair).** The search's rows do run under Local View's scope:
its Run goes through `bridge.run`, so `execute` sends it inside
`_blenderkit_localview.run` like every command (an earlier draft of this
entry said otherwise), as Blender's F3 runs from its 3D View. But no sweep
had run the search under the borrowed view. `tests/opsearch/blender` now has a
seventh starting mode, LOCAL_VIEW: Object Mode, the cube alone in Local View,
an empty outside it selected, each row through `_blenderkit_localview.scope`
and then the mirroring pass's `state`. From it, 9 of 3,430 runs took desktop
Blender down with the app's context: `wm.toolbar`,
`view3d.object_mode_pie_or_toggle`, `screen.region_quadview`, `view2d.pan` and
the four `view2d.scroll_*` (exit -11), and `screen.area_close` (past a
minute). `screen.space_type_set_or_cycle`, `screen.area_split`,
`screen.screen_full_area`, `screen.region_toggle` and `screen.delete` answered
FINISHED there, on the borrowed area itself, which sculpting, Knife Project
and hiding borrow after; with no area each fails its poll. Probing the
interface's popups with what they open found four that crash with no area at
all, in the search's ordinary context and a script's: `wm.call_menu(name=
'VIEW3D_MT_object')`, `wm.call_menu_pie(name=…)`, `wm.call_panel(name=…)` and
`wm.context_menu_enum(data_path='scene.render.engine')` (exit 139; with no
name, as the sweep runs them, each fails in words). Now:
- `_blenderkit_context.INTERFACE_ONLY` names those thirteen, by Blender's
  names for them, and in a Blender with no interface each is refused in words
  in any context (`_InterfaceOnly`) — a script, the console, the search. The
  search's form says why before Run (`_blenderkit_sync._refusal`).
- In Local View the search runs the interface's own modules (`screen`,
  `view2d`, `wm`, `ui`, `workspace`) with no area, as it runs them everywhere
  else (`_blenderkit_sync._interface_context`); every other row stays under the
  view.
- Desktop: the sweep again, 24,010 runs, none crashed; the 3,430 from Local
  View all under its scope, and the same interface rows ran there as from
  Object Mode. `scripts/run-guards-blender-check.sh`: all thirteen refused
  from a script, inside the borrowed view and from the search, the form saying
  why; the controls, unwrapped in a Blender of their own, `wm.call_menu(name=
  'VIEW3D_MT_object')` with no area and `wm.toolbar()` under the view each crash
  it (exit -11). `scripts/run-relations-blender-check.sh`, with the search's own
  string (`OperatorCatalogue.runCommand`, moved out of the form so the
  bridge-only checks run it): its (De)select All and Delete in Local View take
  what it holds and leave Sphere and Light, outside it, as they were (bare,
  the control, they take them); its Cycle Space Type Set is refused by its
  poll and the borrowed area stays a 3D View in Local View (the control, the
  rule off: it becomes an Image Editor, then is put back); its Call Menu is
  refused in words.
- In the app (`-relations-ops search:<path>[:<key>=<value>]`, new: the form's
  Run through `bridge.run`), Cube alone in Local View, Sphere outside it and
  selected: the search's (De)select All with Deselect deselected Cube and left
  Sphere selected, Select selected Cube; Cycle Space Type Set was refused by
  its poll; Call Menu (VIEW3D_MT_object) and Toolbar were refused on the banner
  in words; the gizmo's Move after them moved Cube alone, previewed 0.00e+00
  from Blender, and Toggle Local View left it — the borrowed view intact.

**Blender's undo stack where no history step came first (the 10:29 crash).**
Desktop Blender's report Blender-2026-10-20-102909.ips (SIGSEGV in
`ED_undosys_stack_memfile_id_changed_tag` from Sculpt Mode's `push_begin_ex`,
from `paint.mask_flood_fill`, through bpy from a `--python` file) is
`scripts/run-undostack-blender-check.sh`'s negative control doing what it is
for: the repair's last suite run (its output ends at 10:29:09; the report's
process started at 10:29:08.05 under that script's subshell), the history's
`ensure_stack` switched off, in `deferred-mask` or `load-homefile`, which both
crash on exactly that stack. No app path was involved. Whether one could reach
it: the app pushes the history's first step before every labelled command,
script and Python console line (`prepareBackendChange`), and `_FileRead` makes
the stack again after a load — and only that ordering stood between a command
and the crash. Measured in desktop with the app's modules: a launch whose
recovery file opened in Sculpt Mode leaves Blender with no stack (`_FileRead`
finds no `_blenderkit_undo` yet); with the first push, the search's Mask
Flood Fill, a script's and Face Sets ▸ Initialize run; without it, the
search's crashed (exit 139). And the console skipped the push: it counted a
line as Python only when its first word was `python`, so `time python -c "…"`
(`watch … python`, ncdu's mini-shell) ran Python with no first step — and,
from the code (`runConsole` queried such a line instead of evaluating it), with
no mirror and no undo step either.
- `_blenderkit_context.require_undo_stack`: every operator called in Sculpt
  Mode, or into it (`SCULPT_ENTRIES`), asks first. Once per file load
  (`_bk_context_load_post`, which `install` puts on `load_post`) it reads
  Blender's stack; with none it makes one (`ed.undo_push`, on the main thread
  with a window and a screen) or, off the main thread, refuses the call in
  words.
- `BpySession.runConsole` pushes the history's first step before any console
  line, and `ConsoleShell.touchesScene` reads past `time` and `watch` (and
  `watch`'s flags), so such a line is mirrored and gets its "Console Command"
  step.
- Desktop: `scripts/run-undostack-blender-check.sh` runs eight cases — the
  four it had, `launch-sculpt`, and three with no history step
  (`console-mask`, `console-search`, `console-in-view`): each survives with
  both guards and with the operators' alone, the first four with the
  history's alone; off the main thread the call is refused in words and no
  stack is made; the controls: with neither guard the first four crash, with
  the history's alone `launch-sculpt` and `console-mask` crash (27 PASS). Host
  (`scripts/run-scriptthread-tests.sh`): `time python …`, `watch -n 0.5 -c 3
  python …` and `watch --count 2 time python …` run Python, `time ls`, `echo
  python` and `grep python a.py` do not, and `runConsole` seeds the history
  before any line; a scratch copy with the old rule and the old seeding fails 6.
- In the app: the wrappers in place, the load counter counting the autosave's
  load, the stack readable (`blender_steps`). With the history's guard
  switched off in the script, `open_mainfile` of a file saved in Sculpt Mode
  left Blender with no stack (steps 0) and the mask fill ran: FINISHED, one
  step, the operators' guard's. `time python -c "…objects.new('ConsoleEmpty',
  None)…"` typed into the console (`-console64`) added the empty and the
  history recorded "Console Command"; `time ls` after it recorded nothing.

**Low.** Rename's Info line names the collection by the name it had (it was
keyed by the new one and raised KeyError when copied). An object outside
Local View that is also hidden with H, or disabled, keeps the Outliner's
dimming. Not done: Blender's M, Shift+M, Ctrl+M and Ctrl+L are not bound in
Object Mode (the October 19 entry's "(M)" and "(Shift+M)" are Blender's keys,
not the app's); Move and Link to New Collection still run without Blender's
redo panel (its Name field).

Crashes: none in the app (no BlenderLocal report since 2026-10-19 23:50). In
desktop Blender, each with a home of its own:
- From a check, fixed in the check: `verify.py` held a `LayerCollection`
  across the fixture's file load and read it
  (`LayerCollection_children_lookup_string`); it now reads the layer collection
  at each use. No product code holds such a reference.
- Found in desktop, as the crash rule asks, and guarded: the operator sweep's
  first run from Local View, 9 (8 segfaults and a hang, above), and the probe
  of the interface's popups with names typed, 12 (`wm.call_menu`,
  `wm.call_menu_pie`, `wm.call_panel`, `wm.context_menu_enum` with two data
  paths, with no area and under the view; `wm.toolbar` and
  `view3d.object_mode_pie_or_toggle` under the view). The guard is
  `INTERFACE_ONLY`, with the search's interface modules run with no area in
  Local View; the sweep run again crashed nothing.
- Measurement and negative controls, by design: the undo-stack probe's launch
  without the first push (1), and every run of
  `scripts/run-undostack-blender-check.sh` (6) and
  `scripts/run-guards-blender-check.sh` (6, two of them new). The report of
  10:29 is the repair's own run of the first (above).

Tests: `scripts/run-relations-tests.sh` (136, ALL PASS; the hold and the scope
fail in a scratch copy without them, 5 FAILED) and
`scripts/run-relations-blender-check.sh` (730 in Blender, the search's rows
in Local View and their controls among them, and 2,076 in the Swift
replaying 67 passes; in a scratch copy with the five Python changes reverted,
16 fail in Blender and 1 in the replay); `scripts/run-undostack-blender-check.sh`
(27), `scripts/run-guards-blender-check.sh` (86),
`scripts/run-opsearch-blender-check.sh` (its verify ALL PASS; the sweep 24,010
runs, none crashed) and `scripts/run-scriptthread-tests.sh` (46). After the
last change every Blender check passed (36, 11,948 PASS besides the modeguard
check's table), as did every host suite (49, 4,793 PASS; run before the last
change, a reworded refusal that no host suite reads); the app builds.
Not done: a scene change made from ncdu's mini-shell is still neither
mirrored nor an undo step (its line reads as `ncdu`; the history's first step
is pushed before it, so the stack is there); the search's `wm.window_close`,
`screen.delete` and `workspace.delete` answer FINISHED from every mode, as
before (none crashed; what they leave the app with was not measured); the
cancelled field scrub and the panel closed mid-edit are built and not run.

## October 20: Edge Slide's Flipped row is live, as Blender draws it

The Edge menu's Edge Slide redo panel no longer greys Flipped while Even is
off. That rule came from a measurement: Flipped alone gave exactly the default
result on a tilted grid. But Blender's own panel never greys it:
`TRANSFORM_OT_edge_slide` has no `ui` callback, and `transform_poll_property`
(transform_ops.cc) has no rule for `flipped`. This is the rule Loop Cut and
Knife's review already applied to the Loop Cut panel; its "Not done" list,
below, named this row as the one still left. The row is now a plain
`Parameter`. The code comment keeps the measurement.

Tests: tests/redo's check is now "Flipped is live while Even is off, as in
Blender's panel" (`activeWhen` is nil). It is followed by "and still live once
it is on" and "every Edge Slide and Bevel row is live". `run-redo-tests.sh`
passes. Negative control: in a scratch copy with the old `Parameter.dependent`
wrapper put back, the first check FAILs (1 FAILED). Not run in the app: the
round-4 repair agents were using it. The change is the panel's greying alone,
since the call it runs has always sent `flipped`.

## October 20: the Mesh menu's review, answered (round 4, group 6)

An adversarial review of the October 19 entry (the Mesh menu's search-only
rows, Rip and Extrude to Cursor) found one high defect, four medium and six
low. Each fix was measured: desktop is Blender 5.2.1 with the app's context
(its undo push, `gpu.init()`, the borrowed 3D View where the app uses it);
"in the app" is the real iPad build with its bundled 5.3 bpy on this Mac,
through `-object-ops` and `-sculpt-stroke` from scenes their `-eval64`
scripts made, every script and row run in desktop first (the autosave backed
up and put back, the user's three scenes checked unchanged).

**The 3D View shades a mesh as Blender's Solid view does (high).** The mirror
sent Blender's vertex normals only and the 3D View drew every mesh by them,
so whatever changes only how Blender shades a mesh changed nothing on screen:
the Normals menu's custom normals (Set from Faces, Point to Target…, Average,
Smooth Vectors), Shade Flat and Smooth, Smooth by Angle — and every flat
mesh, which since 4.1 is every primitive: 70 of the 80 meshes of the app's
Scene.blend and all 48 of Dinosaur Car Bike.blend are flat (`normals_domain`
FACE, measured on copies). Now `_blenderkit_sync._push_shading` sends
Blender's `normals_domain` with each mesh and, for FACE and CORNER, Blender's
`corner_normals` with the loop behind each triangle corner (`sync_shading`,
the UV map's way: two `foreach_get` calls, 0.33 ms and 0.20 ms a pass on
those two scenes, 0.7 ms and 9.9 MB handed over for one flat mesh of 273,612
triangles); `_blenderkit_anim.push_mesh` sends them too, so a frame
change and a sculpt stroke's chunks carry them. `SceneMirror.installShading`
keeps one normal per triangle for FACE and one per corner for CORNER
(`MeshData.shadingNormals`, packed as the GPU reads them: 12 bytes a
triangle, or 36), compares an unchanged set in place, and takes the object
out of the fast path's unchanged set when it changed — Shade Smooth moves no
vertex. The renderer draws such a mesh corner by corner (`mesh_shaded_vertex`
and its Material Preview, paint and Texture Paint counterparts, and the
offscreen render), and a mesh Blender shades by its vertex normals indexed as
before. A drag's preview, and a frame change before its normals arrive,
turn each normal with its triangle (`MeshData.carryShading`: exact for a
planar flat face) until Blender's arrive. Blender's `corner_normals` and not its `polygon_normals`: with
custom normals set, 5.2.1's `vertex_normals` and `polygon_normals` stop being
the geometry's (on a smooth sphere after Point to Target… up to 2.0 from what
the faces' positions give, the vertex normals equal to the corner normals).
- Desktop (`scripts/run-shading-blender-check.sh`): the app's own sync and
  `push_mesh` replayed through the Swift, every triangle corner held to
  Blender's corner normals: the six rows by their own first press on the
  meshmenu check's sphere and Point to Target… on a smooth one, a flat cube, a
  smooth sphere, Shade Smooth by Angle on a cylinder, a cube in Edit Mode with
  a face hidden, Shade Smooth and Shade Flat through the fast path, and a frame
  change: worst 0.00000° over every corner of four passes. The control, the
  same passes without `sync_shading` (the 3D View as it was): every flat mesh
  7.9° to 58.5° off, Shade Smooth by Angle 46.7°, the edited cube 54.7°, Set
  from Faces 20.8°. What each row changed, worst corner: Blender's turned
  20.75° (Average ▸ Corner Angle), 20.83° (Custom Normal), 22.42° (Face Area),
  172.05° (Point to Target…), 33.28° (Set from Faces), 1.25° (Smooth
  Vectors), and the 3D View's the same; the old drawing turned 0.00°, 2.18°,
  5.02°, 171.20°, 17.51° and 1.25°. So the review held for the Average rows
  and in part for Set from Faces; Point to Target… and Smooth Vectors did
  show, because 5.2.1 hands the custom normals out as the vertex normals there.
- In the app, on a 12 × 6 UV sphere (`-object-ops normals`, new: the 3D View's
  normals against Blender's, read back): as added FACE, drawn by its faces'
  normals 0.0000° from Blender's (its vertex normals 20.75°); after Shade
  Smooth POINT, 0.0000°; in Edit Mode after each of the six rows CORNER,
  0.0000°; Undo back to FACE, 0.0000°. The 3D View's own frame (`view-stats`,
  new, 400 × 300, overlays off, each against the last; `shading:old` draws as
  before): the flat sphere and the old drawing differ in 1,093 pixels, and the
  old drawing is pixel for pixel the Shade Smooth frame; Average ▸ Custom
  Normal changed the old drawing by no pixel (at most 6 of 255) and the new by
  475 (Undo, back); Set from Faces on the top face, 98 and 208. A Draw stroke
  in Sculpt Mode on a flat 488-vertex block (`-sculpt-stroke`, its chunks
  through `push_mesh`): after the stroke, Undo and Redo, all 2,916 corners
  0.0000° from Blender's (its vertex normals 54.7°).
- Host: `scripts/run-shading-tests.sh` (31: FACE and CORNER installed per
  corner, POINT clearing them, malformed buffers refused, a NaN drawn by the
  vertex normals, the fast path and the merge with its negative control, the
  frame change's way onto the screen, the preview turning a tilted face's
  normal with it and a custom normal keeping its angle, with a negative
  control).

**Merge ▸ At First with no order says so in words (medium).** `check_merge`
read `history[0]` unguarded, so with three vertices selected without an
order — as a box select or Select All leaves them — the banner read Python's
"list index out of range". Either end of an empty history is no vertex now.
The check refuses At First on Select All's cube and on three vertices
selected with no order, and its Sculpt Mode loop holds every refusal to the
app's own words (a RuntimeError, not Python's nor Blender's "Error: …"); the
negative control, Merge's old check, fails that loop with the IndexError. In
the app: "At First merges at the vertex selected first, and Blender holds no
order for this selection: …" on the banner, the cube as it was.

**The meshmenu check does not depend on memory any more (medium).**
`bmesh.ops.create_uvsphere` gives its faces in another order from one call to
the next once other meshes have come and gone (measured: 11 orders in 40
calls with BMeshes made and freed between, one in 30 with none), which moved
the corner normals an index-by-index read compared, the face a tie picked and
what averaging operators summed first. The fixtures are built with their
faces in an order of their own (`_canonical`, `from_pydata`), which the check
measures (each of its six fixtures one order of faces, edges and corner
normals in 20 builds under the same churn; the control, the raw sphere, 8
orders in 20), and `state()` compares the edge and face selection and the
custom normals by their vertices, not their index. Five runs in a row before
the lows below: 178 of 178 each time.

**Average ▸ Custom Normal is Blender's, reproducibly (medium).** The October
19 finding that its result is not reproducible was the fixture (corrected in
that entry): the same 40 calls after the same Python lines give 4 results on
the old fixture compared corner by corner and one on the new, none with more
than 100 corners at (0, 0, 1). `UNSTABLE_NORMALS` is gone, every row's custom
normals are held to Blender's, and Blender's own second run is a check that
Blender agrees with itself (all eight normals cases do) instead of a reason to
skip the comparison.

**Rip Vertices and Extend says what it does (medium).** It does not extend
anything toward the 3D cursor: `edbm_rip_edge_exec` splits each selected
vertex's edge that points most toward the pointer's line at the vertex, so
the new vertex starts on the old one, and the macro's Move — the panel's —
moves it. Measured with the row's call on a cube's corner (1, -1, 1), the
cursor at (2, -1, 2.5): 8 → 9 vertices, the new one at (1, -1, 1) on the edge
toward (1, 1, 1), nothing moved. The row's refusal, Rip's tooltip and the
Operator Search's sentences say that now. The search's reason for
`rip_edge` and `rip_edge_move` was wrong as well (a low): they have an exec
that takes the ray as hidden properties — `rip_edge('INVOKE_DEFAULT')` under
the borrowed view falls back to it, FINISHED, 8 → 9 (measured) — and what the
search lacks is the 3D View their poll asks for and a ray. In the app: the
refusal with nothing selected on the banner in the new words; a corner ripped
8 → 9 vertices with the panel open.

**The lows.**
- Extrude Manifold's refusal said faces; it extrudes what is selected
  (measured: one edge 8/12/6 → 10/15/7, one vertex → 9/13/6). It says faces,
  edges or vertices, and the check holds an edge's extrusion to Blender's. In
  the app, a corner: 8 → 9.
- `require_unselected_faces` is wired: Intersect (Knife) with Source
  Selected/Unselected and Intersect (Boolean) without Self Intersection refuse
  a selection that leaves no face unselected (Blender's own, measured: Knife
  FINISHED with nothing changed, Boolean 8/12/6 → 0/0/0). Self Intersection is
  not refused — a Self Union is a use of it — and its Difference on two whole
  cubes empties them in Blender as in the app (16/24/12 → 0/0/0), so the
  refusal does not point at it. In the app: both refused on the banner.
- The Merge rows and Smooth Vertices (Laplacian) say when Blender changed
  nothing (measured: Collapse on two corners no edge joins, Laplacian on one
  corner and on a whole cube, FINISHED and unchanged). `LastOperator.unchanged`
  compares counts, positions and edges now (`_blenderkit_loopcut.edit_state`):
  At Cursor moves one vertex with the counts as they were, and compared by
  counts alone — the check's negative control — it is refused. In the app:
  both on the banner. Not done: Rotate Edge on a whole cube, which the review
  measured unchanged; here it turns edges in every select mode with the row's
  call, so no sentence was added.
- Extrude to Cursor or Add refuses an object scaled to 0 on an axis, before
  any mesh changes (a scale of 1e-6 still runs); in the app, refused on the
  banner.
- Poly Build: all nine `polybuild_*` the search lists are measured now (the
  other four PASS_THROUGH, nothing changed).
- Stale numbers: the October 19 counts are marked as that day's; the vacuous
  negative control (a string never there, still absent) is replaced by one
  that reads every row the search's sentences name and fails when one is
  misnamed.

Tests: `scripts/run-shading-tests.sh` (31) and
`scripts/run-shading-blender-check.sh` (41, above);
`scripts/run-meshmenu-tests.sh` (115: the new words, the Intersect guard's
lines, `edit_state`, the rows the search names), `scripts/run-meshmenu-shim-tests.sh`
(78 calls, 85 checks) and `scripts/run-meshmenu-blender-check.sh` (197: the
fixtures, every row against Blender with custom normals compared for all,
the new refusals each beside Blender's own call there, the scale-0 refusal,
every `polybuild_*`). The redo check's scenes give the Merge rows two joined
vertices in order, Smooth Vertices (Laplacian) a grid with one vertex pulled
off it and the Intersect rows two crossing cubes, the small one selected: on
its old ones (two unjoined vertices, a whole cube) the new refusals failed 12
of its runs, each a panel value Blender does nothing with. Every host suite
(39) and every Blender check (36) passed; three runs that failed with "input
file … was modified during the build" (edits made while they compiled, one of
them another group's, to LastOperator.swift) passed when run again.

Crashes: none in the app. Desktop Blender crashed only in other checks'
deliberate negative controls, as designed (the guards check's brush pick and
`temp_override` controls at 08:19, the undostack check's at 08:55); none in
this group's probes or checks.

## October 20: Typed values, orientations and Dimensions' review, answered (round 4, group 5)

An adversarial review of the October 18 entry (typed values in Edit Mode,
transform orientations, typed Dimensions) found three high defects, four
medium and eight low. Each fix was measured: desktop is Blender 5.2.1 with the
app's context (`scripts/run-transformops-blender-check.sh`, now thirteen
fixtures and 1,455 drags and redo changes); "in the app" is the real iPad
build with its bundled 5.3 bpy on this Mac, through `-transform-ops` from a
scene its `-eval64` script made (the autosave backed up and put back).

**A tap read early is still the one the redo panel re-runs on (high).** With
Normal in Edit Mode or the Sidebar open, every tap is handed to Blender by a
read (`captureWithSelection`), outside any undo step — and the read cleared
`editSelectionPending`, so the next command carried no push and its redo
panel, rewinding to the step before, re-ran on the selection from before the
tap. The read leaves the tap pending now; the command pushes it again (the
same push: the whole selection and its order written afresh) and keeps it
for its re-run. The same flow in the review's own order — tap, then Normal
from the Orientation menu, then the Move — had a second way in: the menu's
setting carries the tap and records no step, and the mirror clears the flag.
So the bridge marks where the history stood when a tap reached Blender with
no step to hold it (`unrecordedPushMark`: a read, a setting, a command that
failed), and while the history has not moved since, the next operator's redo
pushes the viewport's selection — the mirror's, Blender's — before it re-runs.
Desktop: the bridge's own sources (the read or the setting, the Move, the
redo's Move Z 0.5) run with the app's undo on a sphere whose vertex 40 was
recorded and vertex 12 tapped: both re-runs are the preview to 6e-8 m; each
re-run as the bridge sent it before, without the tap, is 0.50 m off (it moved
vertex 40). Host: six checks on what the Move and the re-run send; compiled
back to the old code they fail (three for the read, one for the setting).
In the app, a cube turned 30° about X: Normal, vertex 7 tapped and moved
0.5, vertex 0 tapped (Blender's selection [0] before any command, still
pending), moved 0.5, then the panel's Move Z 1.0: vertex 0 at (-1.57735,
-0.57735, -2.15470), its start plus 1.0 along its normal (-0.5774, -0.2113,
-0.7887), and vertex 7 kept its own Move. Then in Global: vertex 7 moved 0.5
up, vertex 0 tapped, Normal chosen from the menu, a Move, Move Z 1.0: vertex
0 at the same (-1.57735, -0.57735, -2.15470), vertex 7 still (1, 0.36602,
1.86603).

**Scale's preview inverts as Blender does (two highs).** The preview scaled by
A · diag · Aᵀ for Global and Local and by simd's inverse otherwise. Blender
takes `spacemtx_inv` from `invert_m3_m3_safe_ortho`: the adjoint over the
determinant when that is not exactly zero, else the identity (after
rebuilding any zero axis). `BlenderMatrix` is that function, used for every
orientation. Before, the check's new fixtures failed: a gimbal-locked object
(Euler (0.3, 90°, 0.2)) in Gimbal, Scale X 1.5 m off, Z 1.0, XY 1.4, all
0.59, and the same in Edit Mode; a child of a turned parent scaled (2, 1, 1)
in Edit Mode Local, Scale X 1.9, Z 2.0, XY 2.3, all 1.0. After: Gimbal's
worst 8.3e-7 m, Local's 9.5e-7. In the app: the locked cube's Gimbal Scale
X 1.5, Z 1.4 and all 1.3 held to Blender within 3.2e-6, 3.2e-6 and 4.4e-6
m; the sheared child's Edit Mode Local Scale X, Z and all within 5.0e-6,
4.7e-6 and 5.3e-6, its Gimbal Scale X 4.8e-6. Limit: within a hair of the
lock (det tiny, not zero) the C compiler's fused multiply-adds round the
determinant differently from Swift's, so the last digits may part.

**The redo panel's Normal, in Edit Mode, is the 3D View's (medium).** Switched
to from another orientation it went bare, and a headless Blender works Normal
out with the bounds centre for its pivot: under Active Element it was the
whole selection's. It now carries `orient_matrix=__import__('_blenderkit_orient').redo_matrix('NORMAL')`,
the port's matrix worked out when the re-run runs — after the rewind and the
selection's push — with the scene's pivot, as Blender's own panel works it
out then (`redo_matrix` refuses in words where the port has none). Object
Mode keeps it bare: there Blender's Normal is Local. Desktop: faces 1 and 5
of a cube, 5 active, Active Element, a Local Move Z then Orientation Normal:
0.14 m off before, 1.2e-7 after. In the app, the same cube: Normal read
(0.2211, -0.4803, 0.8488), face 5's own; the Local Move Z 0.5 switched to
Normal left every vertex where it was to five places, along face 5's normal
(the bare call's (0.218, -0.255, 0.942) would have moved it about 0.12 m).

**Dimensions are typed in Object Mode (medium).** Blender's Item tab offers
none in Edit Mode, and its Edit Mode undo keeps only the mesh. The Data tab
shows them there as Blender's numbers, without fields, and
`set_dimension` refuses in words whatever calls it. Desktop: refused, the
scale untouched; the negative control, a scale written in Edit Mode and
recorded, is still 2.50 after Undo; in Object Mode a typed Dimension is
undone. In the app: Edit Mode's Dimensions X 5 refused on the banner, the
Data tab reading "X 2.000 m, Y 4.000 m, Z 1.500 m" without fields; in Object
Mode X 3 read back (3, 4, 1.5), its step "X".

**The orientation and the read-back Dimensions follow the frame (medium).** A
frame change is a `capture` (TimelineDriver.setFrame), which moves no
revision, and none of the three keys held the frame: the gizmo kept the last
frame's axes and committed them as `orient_matrix`. The orientation, the Item
tab's and the Data tab's keys hold the frame and subframe now. In the app
(new `frame:<n>` token, the timeline's own call and no refresh of the hook's):
a cube keyed from rotation Z 0 and scale X 1 at frame 1 to 1.2 and 2 at frame
20, Local: at 20 the app's X (0.3624, 0.9320, 0) and Blender's, at 10
(0.8511, 0.5250, 0) both, at 1 the identity; the Sidebar read Dimensions (4,
2, 2), (2.9211, 2, 2), (2, 2, 2) at each; a Local Move at 20, 4.6e-6 m from
Blender. Not measured: playback in Edit Mode under Normal now reads the edit
mesh each frame (the review measured 93 ms per read at 90k faces).

**Typed values cannot leave non-finite data (medium).** Blender's fields take
any number up to FLT_MAX and keep what comes of it; `set_median` and
`set_dimension` now put back and refuse, in words, a result that is not a
finite float32 — a coordinate, a scale, the Median the panel reads (in both
spaces), the Dimensions — and the state and Dimensions JSON writes a
non-finite number as Blender's UI prints it ('inf', 'nan'), which the Swift
reads, where it wrote Infinity, which JSONSerialization refuses. A typed
number past Float's range goes as `float('inf')`, for the module to refuse.
Desktop: Median X 3e38, -3e38 and 2e38 (the sum overflows) refused, the mesh
unchanged; 1e6 goes in; a vertex a script put at infinity reads ['inf',
'inf', '-inf'], parsed by the Swift, and a typed Median on it is refused;
Dimensions X 3e38 refused with the scale put back, 1e9 goes in. In the app:
Median X 3e38 refused on the banner and the Median read back unchanged;
Dimensions X 3e38 refused. Not run: what huge but finite coordinates do to
the app's mirror and renderer.

**The lows.** A custom orientation named "Pipe none" reads as its matrix (the
nine numbers are looked for first). A redo field opened and left as it was
re-runs nothing (`typingFrom`; built, not tapped: no hook drives the gesture).
Proportional Size is unitless, as Blender's PROP_NONE ("Proportional Size
0.700" in the app). Dimensions are read and offered only for the types
Blender draws them for (null and a refusal for an Empty, a Camera, a Light,
measured). The Dimensions fields' steps are X, Y and Z, the buttons' words, as
the Median's (in the app, "X"). Local Rotate's deviation with several objects
is documented beside Local Move's (`commitsBare`). The check's Swift fails in
words, not on a force unwrap, when a fixtures file lacks `obj_pair`. Not
done: the Normal and Item read-backs still loop over the whole edit mesh in
Python on the main thread (93 ms + 16 ms at 90k faces, measured by the review).

Crashes: none in the app and none in desktop Blender from these runs (the
two Blender reports of the day, 01:33 and 05:33, predate them).

## October 20: the picks' and Select menu's review, answered (round 4, group 4)

An adversarial review of the October 18 pick selections and Select menu found
two critical defects, three medium and four low. Each fix below was measured:
desktop is Blender 5.2.1 with the app's context (its undo push, `gpu.init()`,
the borrowed 3D View where the app uses it); "in the app" is the real iPad
build with its bundled 5.3 bpy, run on this Mac as Designed for iPad through
`-select-pick`, `-region-select` and `-object-ops`, each from a scene its
`-eval64` script made (the autosave backed up first and put back after).

**The undo guard reads the undo argument as Blender does, as the call is made
(the two criticals).** The review measured a positional `1` past a guard that
refused `True` only — `loop_select('EXEC_DEFAULT', 1, …)` under the borrowed
view segfaulted in `ED_area_type_hud_ensure` ← `wm_operator_finished` — and an
operator looked up outside an area override and called inside it never
wrapped (`op = bpy.ops.mesh.select_all`, then `op('EXEC_DEFAULT', True, …)`
inside `temp_override_view3d`, the same crash). Group 3's answer to its own
review had already changed both in `_blenderkit_context` the same day
(`undo_requested` is Blender's `bpy_op_parse_args`; with no interface every
operator is handed out wrapped and the area is asked at the call), so nothing
more changed there; this measured it for the picks. Desktop: `loop_select`
and `loopcut_slide` with `True`, `1`, `2` and `-1` each refused in words under
the borrowed view, `0` ran Blender's call (FINISHED); `select_all` and
`loop_select` looked up outside and called inside with `True` and `1` refused,
nothing selected. In the app: `loop_select` with `1`, `select_all` looked up
outside with `True` and `loopcut_slide` with `2` each refused on its line, 1 of
25 vertices still selected; `loop_select` with `0` ran (5). The selectpick
check tries `True`, `1`, `2`, `-1`, `0` and the looked-up-outside call with
`True` and `1`; one let through would crash that check's Blender, which fails
it.

**Ctrl+L and Select ▸ Select Linked ▸ Linked start from Blender's first-press
Delimit.** The row sent `delimit={'SEAM'}` in every select mode. Blender's
Ctrl+L and its row call `mesh.select_linked` with no Delimit, and its exec
picks one by the scene's select mode (`USE_LINKED_SELECT_DEFAULT_HACK`,
`select_linked_delimit_default_from_op`): none while vertices or edges are
selectable, Seam in Face mode alone. The row sends that now, by the select
mode the mirror read back, and its panel draws Delimit as Blender's does, a
toggle per item (Normal, Material, Seam, Sharp, UVs: 5.2.1's labels) — as the
L pick's already did. Desktop, a 4 × 4 grid with a seam down its middle, from
its corner: Blender's own Ctrl+L 25, 25 and 15 vertices in Vertex, Edge and
Face mode, the row the same three; the row as it was 15 in Vertex mode (the
negative control). In the app: 25 in Vertex mode with every Delimit toggle
off, Seam toggled on in the panel re-ran it to 15, 25 in Edge mode, 15 in Face
mode with Seam on. Without a select mode (none of the app's callers) the row
leaves Delimit to Blender and shows no value for it.

**No pick row where taps ignore it.** `SelectMenuItems` drew the pick rows
whenever Edit Mode was on, while the 3D View is handed the pick only for a
mesh. The header gives a curve's or a lattice's points their own Select menu
(`pointsMenus`, since round 3), so those rows were not reached from there; the
component now draws them only when told the view takes the pick (`picks`, the
condition the view is given), and the Mac menu bar's Ctrl+L Linked row is
greyed while a curve or a lattice is edited (`ViewportKeyActions.editingMesh`),
as L and Shift+L already were. Built, not opened: the menus need clicks, and
the screen was locked.

**The active element is checked off ties.** Loop and Edge Ring were sampled at
edge middles only, where the end Vertex mode makes active is a tie pixel
rounding decides (`length_1 < length_2`) and, on the grid from the top, both
faces' middles are equally near. The check now also aims a quarter of the way
along each edge, from one end or the other, 3 px to one side: 147 to 149 more
pixels per pick and mode across the four meshes (the sphere's count depends on
how that Blender numbers its edges, which varied between runs), 882 to 894
more calls, each held to Blender's result element for element with the active
element, all the same in four runs. Two wrong rules run there as negative
controls — the edge's first end always, caught at 77 to 79 of them; its
lower-numbered face always, caught at 55 to 62 — so these pixels tell the
invoke's rule from either. The reference is
still `edbm_select_loop_or_ring_invoke_impl` read line for line in Python
(`loop_active`), not Blender running it: the invoke reads the mouse from the
window's event state, which Blender makes only for a GHOST window
(wm_window.cc), so without one an INVOKE call goes straight to the exec; and
`Window.event_simulate` under `-b --enable-event-simulate` segfaulted in
`Window_event_simulate_call` (exit 139). No script in the app reaches that:
`bpy.app.use_event_simulate` can only be turned off (measured), and without it
`event_simulate` raises.

**The tap ranks what is near it as Blender's click does.** The new pixels found
one where the app's tap took another edge than Blender's click: a quarter of
the way along a UV sphere's edge, MeshPicker took the edge beside it, 2.996
pixels away against the aimed edge's 3.176. Blender ranks by the Manhattan
distance (`len_manhattan_v2v2` to a vertex, or to an edge's nearest point:
`find_nearest_vert__doClosest`, `find_nearest_edge__doClosest`), 3.840 against
3.824 there, and took the aimed one. MeshPicker ranks the same way now; its
reach is still a finger's 22-point circle. The sphere's numbering varies from
one Blender to the next, so that pixel came up in one run of three before the
fix; after it, four runs, three numberings, every pixel Blender's. In the app,
after it, on the seam grid from the top: Alt+click a quarter of the way along
an edge from its left end made that end active (v5), three quarters along the
other (v6), 5 vertices each; a face loop tapped just below and just above the
same edge made the face on that side active (f0, f4); Ctrl+Alt+click a ring of
5 edges; Ctrl+click corner to corner 9 vertices — Blender and the viewport the
same after each. Blender's solid-mode click reads its GPU selection buffer
instead, which nothing headless can, so that one is not measured.

**Also (the low ones).** A Box, Circle or Lasso Set over exactly what is
selected pushes now, as Blender's own gesture finishes there: its
pre-deselect counts as a change whenever anything is selected, and it clears
the selection order (`BKObject.regionChanges`; `SEL_OP_USE_PRE_DESELECT` in
view3d_select.cc). Desktop, X-Ray on, a box over the grid's centre vertex:
Set with it selected and active FINISHED and the order 1 → 0, with no order
FINISHED, over nothing with nothing selected CANCELLED, Extend over it
CANCELLED with the order kept; the app's decisions and pushes gave the same
four, and the rule as it was (the elements alone) kept the active vertex
Blender's box drops. In the app: Extend over the active vertex kept Blender's
order (1, the viewport's 1); Set over it, Blender's 0 and the viewport's 0.
`_blenderkit_select.aimed_view` (Side of Active's View axis) turns the view
back and leaves the borrowed view when anything after entering it raises, and
refuses a direction that is not three numbers before borrowing it — desktop,
before: an `up` of two numbers left `bpy.context.area` VIEW_3D after the
failed `with`; after: None, both ways. `drawActiveElement` and
`drawEditedPoints` have their own doc comments again. `-region-select` prints
Blender's selection order's length beside the viewport's.

Suites run: all 48 host suites (selectpick 91, regionselect 111, names 426,
meshpick 40 among them; folding rerun after it raced an edit, then passing),
and thirteen Blender checks — selectpick (251, four runs), regionselect,
objectmenu, measure, modifier, points, names, context, guards, cuttools,
opsearch, 3dview, redo — every one passing.

Crashes: none in the app. In desktop one deliberate probe, `Window.event_simulate`
under `-b --enable-event-simulate` (above); no product path reaches it.

Not done: the Mac menu bar's Shift+L row keeps "Select Linked (Deselect)"
(docs/blender-names.md says why; Blender's keymap lists both keys as Select
Linked, and whether two menu bar rows may share a title was not tried with
the screen locked). A curve's own Ctrl+L and L (`curve.select_linked`,
`select_linked_pick`) are not offered. `_bpy.ops` and a wrapped operator's
private `_operator` still reach Blender's operator unguarded.

## October 20: Loop Cut and Knife's review, answered (round 4, group 3)

An adversarial review of the October 18 Loop Cut and Knife work found two
critical defects, one high and two medium, and six low ones. Each fix below was
measured: desktop is Blender 5.2.1 with the app's context (its undo push,
`gpu.init()`, the borrowed 3D View where the app uses it); "in the app" is the
real iPad build with its bundled 5.3 bpy, run on this Mac as Designed for iPad
through `-cut-ops` and `-object-ops`, each from a scene its `-eval64` script
made (the autosave backed up first and put back after).

**The undo argument is read as Blender reads it.** The guard against a
registered operator's redo panel opening in the borrowed 3D View (where the
area has no type and `ED_area_type_hud_ensure` segfaults) refused a positional
`True` only. Blender takes the first int as the undo flag (`bpy_op_parse_args`:
`PyBool_Check || PyLong_Check`, then `PyObject_IsTrue`), and the review measured
`loopcut_slide`, `loopcut` and `transform.translate` given `1` crashing past
it. `_blenderkit_context.undo_requested` is a copy of Blender's parse, and all
three guards ask it (`_NeedsView`, `_SculptEntry`, `_UndoInArea`). Cuttools
check, under `temp_override_view3d`: `True`, `1`, `2`, `-1` and a bare `1`
refused in words for `loopcut_slide`, `loopcut`, `subdivide`,
`transform.translate` and `object.mode_set`, nothing changed; `0` and `False`
run Blender's own call (12/20/10); arguments Blender refuses stay its
ValueError; with no area in the context the undo is Blender's. The negative
control: the old rule reads `1` as no undo.

**Two more crashes of the same kind, found in desktop probes and guarded.**
First, an unregistered operator that runs a registered one: `object.mode_set
('EXEC_DEFAULT', True, mode='EDIT')` (bl_options empty) under the borrowed view
segfaulted (exit 139; `ED_area_type_hud_ensure` ← `wm_operator_finished` ←
`wm_operator_call_internal` ← `mode_set_ex`, the `editmode_toggle` it runs).
Which operators run others cannot be read off them, so with the undo on inside
an area override only the unregistered BLOCKING ones run now — the strokes the
app itself calls that way (`sculpt.brush_stroke`, `paint.vertex_paint`,
`paint.weight_paint`), the editors' navigation, eyedroppers and area edits: 49
in 5.2.1 (`refuse_undo_in_area`; none read as running another operator, which
is not something their RNA can show). Second, an operator looked up before the override and
called inside it: `op = bpy.ops.transform.translate`, then `op('EXEC_DEFAULT',
1, …)` inside `temp_override_view3d`, segfaulted (exit 139), because only
operators looked up inside an override were wrapped. In a Blender with no
interface every operator is handed out wrapped now, the call is asked as it is
made, and everything else is the operator's own (the context check's row says
so: idname, RNA, signature and doc read as Blender's). Both refused in words in
the cuttools check.

**The Knife snaps as Blender's knife snaps.** Knife Project, which the commit
runs, has the knife's edge and vertex snapping turned off, so a tap a pixel
inside an edge cut a hexagon with slivers where Blender's knife cuts two quads.
`KnifeSnap` (CutTools.swift) is Blender's `knife_snap_curr`: the face under the
pointer (or the nearest one the view sees within 10 points, as
`EDBM_face_find_nearest` finds it), the nearest of its sides within 10 points
(`ethresh`) by `closest_ray_to_segment_v3`, then that side's end within 9
(`vthresh`), both scaled down by the face's nearby corners (`knife_snap_size`),
and a point the path already has on the mesh within 9 — the path's own vertex,
as a click on the first point closes Blender's knife. The point it keeps is
exactly on the edge or the vertex, and Knife Project takes a point within half
a pixel of one as a hit on it (`knife_find_line_hits`), so the cut is the one
Blender's knife makes from those clicks. Under a modifier that rebuilds the mesh
it snaps to Blender's cage, asked once (`_blenderkit_knife.cage_json`). The
hover's segment ends where the tap would put the point. Desktop, the cube from
(0, -6, 0): the review's taps 2 px inside the side edges 10/15/7 with the new
vertices on x = ±1 and faces [4, 4, 4, 4, 4, 5, 5] (unsnapped, the negative
control: [4, 4, 4, 4, 4, 4, 6]); taps near opposite corners 8/13/7, two
triangles, no new vertex; a fifth tap 3.6 pt from the first closes a square, 4
new vertices (unsnapped: 5). In the app: the same three, worst 0 m against the
crossings worked out from the mesh, the hover's end the tapped point to the
digit, and under a Subdivision Surface at level 2 the same cut onto the cage's
edges. Cuttools host suite: the snaps, Blender's density scaling, the
silhouette within 10 points and not at 30, a hidden or off-mesh path point not
snapped to, and a zoomed-in negative control that stays in the face.

**What the overlay shows from the Confirm view is what is cut.** Points that
land on one line of sight (orbiting between taps puts them there) made no plane,
and Knife Project cut something else. `KnifePath.cutPoints` makes each point
within a point of an earlier one on screen that earlier point (Blender's
interactive knife ignores a segment under a pixel), and `_blenderkit_knife._wire`
does the same in Blender's own view at half a pixel (the knife's vertex
tolerance without a pointer) for a script's call; a path that comes back to a
point it had is a closed outline, which Knife Project cuts closed. Desktop: the
review's p1, p2 on its line of sight at 1.8 times the depth, p3 — the cut p1 to
p3 alone makes, vertex for vertex; p1 and p2 alone, and two points along an
orthographic view, refused in words. In the app: p1 tapped from the front, p2
from behind, Confirm from (0, -6, 3) where they line up refused with the path
kept, then p3 tapped and Confirm cut two points, 2 and 2 crossings, 0 m.

**What Blender's knife leaves selected.** Knife Project clears the selection;
the knife keeps it, selects the edges along the cut outside Face mode (made or
already there), the edges joining a closed path to its face when that face is
selected, keeps a split edge's and face's selection in every piece, and flushes
the select mode up. Integer layers the knife carries through its splits
(`BM_edge_split`, `BM_face_split_edgenet` copy their data) tell old pieces from
the knife's edges, and the cut's place in Blender's view tells the edges along
it from those joining an island (`_select_like_the_knife`). Desktop: Face mode
with the front face selected, both halves selected after; a corner vertex, the
bottom edge and an untouched face kept with their selection order. In the app:
Face mode, 4 selected vertices before, 6 after (both halves); a path that missed
in Vertex mode refused with Vertex mode and the 4 selected vertices kept.

**Subdivide Edge-Ring is Blender's panel.** Its rows were the old Loop Cut
row's (1 cut, Linear, Smoothness 0, in metres). They are Blender's five in
Blender's order with 5.2.1's RNA defaults — Number of Cuts 10, Interpolation
Blend Path, Smoothness 1, Profile Factor 0, Profile Shape Smooth — and ten cuts
are priced against the vertex budget first (`_blenderkit_loopcut.check_edgering`).
Desktop: two ring edges 8/12/6 → 28/42/16; with the budget lowered to 20,
refused in words. In the app: 28 vertices, the panel's 2 cuts 12, Linear and
Profile Factor 0.5 re-run, Undo back to 8.

**Also (the low ones).** Every Loop Cut starts at one cut, as Blender's does
(`number_cuts` is PROP_SKIP_SAVE): in the app, after the panel's 3 cuts the
next hover previewed and cut 1. No row of Loop Cut and Slide's panel is greyed
(Blender greys none), and Edge Slide's Clamp, Mirror Editing and Correct UVs
are there, on as Blender's own Loop Cut records them, each measured: Factor 1.5
stops the loop at the ring's end clamped (z = -1) and passes it unclamped
(-1.5) — so Factor takes Blender's hard range, ±10 —; with the mesh's X mirror
on, a loop across X stays on the plane with Mirror Editing (x = 0) and slides
without (0.5); Correct UVs changes the cut corners' UVs. A hidden object is
refused in words naming it (Blender answered CANCELLED, which read as "no edge
4"), and `object_index` counts only the objects the view shows. The Knife acts
on every mesh in Edit Mode, so its mesh-backup re-run is not offered with
another selected (`actsOnSelection`). New DEBUG: `-cut-ops` takes
`orbit:<azimuth>,<elevation>,<distance>`, prints what a tap snapped to and the
hover's next point, and a Confirm's face sizes.

Suites run: all 48 host suites (cuttools 78, redo, names among them) and all 35
Blender checks (cuttools 118 and 13 previews, context, guards, selectpick,
sculpt, vwpaint, undostack, opsearch among them), every one passing; the
measure check failed once under four checks at a time — its scan of the 8 KB
past the View3D found other memory changing beside the depth flag — and passed
run alone, twice as the whole check and twice its measuring phase. No crash in
the app.

Not done: the Knife does not snap to the middle of the path's own segments
(Blender's knife does, making a T junction); snapping looks at the active
object's cage alone in multi-object editing; a Loop Cut re-run from the panel
with more than one cut leaves Edge select mode, as Blender's own exec does
("We can't slide multiple edges in vertex select mode", editmesh_loopcut.cc;
the modal tool's `USE_LOOPSLIDE_HACK` puts the mode back, the exec does not);
the Edge menu's Edge Slide row still greys Flipped until Even, the rule this
review removed from Loop Cut (another group's row); `_bpy.ops`, the private
module behind `bpy.ops`, is not wrapped.

## October 20: Weight and Vertex Paint's review, answered (round 4, group 2)

An adversarial review of the October 18 group-2 work found two high and four
medium defects, and seven low ones. Each fix below was measured: desktop is
Blender 5.2.1 with the app's context (its undo push, `gpu.init()`, the
borrowed 3D View where the app uses it); "in the app" is the real iPad build
with its bundled 5.3 bpy, run on this Mac as Designed for iPad through the
DEBUG hooks, each run from a fixture file copied over the autosave (backed up
first and put back after).

**Vertex Paint's colour is scene linear in Blender.** `Brush.color`,
`UnifiedPaintSettings.color` and their `secondary_color` are subtype COLOR in
5.2.1, and the header wrote the picker's sRGB into them as it came: 0.5 grey
painted sRGB 0.737 and the swatch showed 0.5. `_blenderkit_vwpaint` now
converts with Blender's own colour management (`mathutils.Color`), reading
the property's subtype from the running build: `set_color` takes sRGB,
`state()` gives `color` in sRGB (the swatch, what a stroke paints into
`color_srgb`), `color_held` and `color_space` (SCENE_LINEAR). Vwpaint check:
sRGB 0.5 held as 0.2140, (0.2, 0.6, 0.9) as (0.0331, 0.3185, 0.7874), each
read back as picked; a Paint Hard stroke at strength 1 paints 68 corners
within a byte of the picked colour; the negative control (0.5 written raw)
paints 0.7373. The old check tested red only, which is the same in both
spaces. In the app: 0.5 grey held 0.214 SCENE_LINEAR, the darkest corner
drawn and held 0.4980 on the 1,106-vertex ball; (0.2, 0.6, 0.9) painted
(0.2000, 0.6000, 0.8980) on a 40,962-vertex sphere.

**No bridge, no stand-in paint on Blender's mesh.** A drag in Weight Paint or
Vertex Paint that Blender's own stroke did not take went to the stand-in's
`paintVertices`, which painted the display cache: the Scripting tab keeps the
mode and its Showcase 3D View has no bridge. `BKObject.standInPaintRefusal`
(the rule `standInSculptRefusal` keeps) now refuses it on an evaluated mesh,
`paintVertices` paints nothing there, and the drag goes through
`standInPaintDrag`, which orbits and says the refusal as the drag ends, as a
refused sculpt drag does. Sculpt host suite: refused in words with nothing
painted for both modes; the negative control, the simulator's mesh, paints 3
vertices. In the app (`-workspace Scripting -standin-dab 4`, Weight Paint):
four moves and the end orbit, the refusal is printed, 0 weighted before and
after.

**Subdivision Set from Sculpt Mode keeps the heavy-base budget.** The search
runs `object.subdivision_set` in Object Mode, where Blender's operator
subdivides a Multires once per missing level and each level raises the Sculpt
level (`multires_set_tot_level`). `run_operator` now prices the Sculpt level
it would leave (`_subdivision_set_sculpt_level`) through `_heavy_sculpt_level`,
as Multires Subdivide's branch does. Guards check: the review's case (8,066
vertices, a new Multires, level 1) refused, 0/0/0 kept, still in Sculpt Mode;
level 1 over an existing level runs (it sets the viewport level only, 1/0/1);
level 2 refused. Negative controls: without the check Blender's operator
reaches 1/1/1 and the Sculpt Mode guard below keeps it in Object Mode; without
both, back in Sculpt Mode at 1/1/1 sculpting the Multires, as the review
measured. In the app (`-opsearch object.subdivision_set`, the base saved in
Sculpt Mode): refused in words, still in Sculpt Mode.

**Every way into Sculpt Mode asks its budget.** `refuse_heavy_multires` was
asked by the mode menu only. `_blenderkit_context` now wraps
`object.mode_set`, `object.mode_set_with_submode` and `sculpt.sculptmode_toggle`
as it wraps the file reads (`SCULPT_ENTRIES`, `_SculptEntry`): a call that
would take the active object into Sculpt Mode asks `refuse_heavy_multires`
first. That covers the search, a script line and the app's own way back into
Sculpt Mode after an Object Mode operation. Guards check, on the 8,066-vertex
base at 1/1/1: the search's `mode_set(mode='SCULPT')` and
`sculptmode_toggle`, and a script line's `mode_set`, `mode_set` with its undo
and toggle, and `sculptmode_toggle`, each refused in words, still in Object
Mode; the negative control enters; at Sculpt level 0 it enters, and leaving is
never asked. In the app: both search paths refused, still in Object Mode,
levels 1/1/1. An object already sculpted on a heavy level (a file saved so)
whose Multires row from Sculpt Mode leaves it heavy stays in Object Mode with
the change kept (guards check: Delete Higher from 2/1/2 leaves 1/1/1, Object
Mode); the reason goes to the console there, and from the search too, not to
the banner, since the operation itself was done.

**Both sides of a face are drawn, as Blender draws them.** Blender's
`show_backface_culling` is False on every startup screen, and the renderer
culled back faces in Solid mode. The surface passes (Solid, Material Preview,
Weight and Vertex Paint) cull nothing now (`ViewportRenderer.surfaceCull`,
`FaceWinding.cullsBackFaces`), and a back face is lit from its own side
(`facing_normal` in Shaders.metal, `texpaint_fragment`), as the workbench
flips the normal of a fragment that is not front facing. Region select host
suite: a plane seen from behind is taken by face mode and drawn; culling
(the rule before) draws none of it. In the app (`-textimage-ops view:top,
capture:…,culling:old,capture:…`, two planes from the top, the left one
turned over): the left half 28,559 px off the background, 6,358 (the grid
alone) with culling; the right half 27,966 both ways; both planes the same
grey. Desktop Workbench render of the same file: 10,000 and 10,000 px
covered, 0 and 10,000 with Backface Culling on.

**The Vertex Paint mirror is numpy, and the throttle counts it.** `values`
averaged a corner layer per vertex in a Python loop; it is one numpy
`bincount` now, reading each corner's vertex through the mesh's
`.corner_vert` attribute (0.01 ms for 245,760 corners, where
`loops.foreach_get('vertex_index')` took 9.3), with the loop kept for a
Python without numpy. The throttle's replay cost includes the mirror after it.
40,962 vertices, 245,760 corners: desktop 7.5 ms against the loop's 98.2,
the same values to 1e-7 (vwpaint check); in the app 19.7 ms against 126.3, `push` 23.1 ms,
weights 16.8 ms (Blender has no bulk read of a group's weights; still a loop).
Vwpaint check: with the budget at 50 ms a 120 ms mirror holds 9 of 10 chunks
and the end replays them, the same stroke; the mirror as it is holds none. In
the app, Vertex Paint on the dense sphere: mirror 24 to 32 ms a replay, every
other chunk held, drawn and held 1e-6 apart, Undo and Redo exact; Weight
Paint 17 to 21 ms, the same.

**A crash found on the way, and guarded.** The first in-app run picked a
brush through the header's call (`-vwpaint-ops brush-Paint_Hard`) and the app
crashed: EXC_BAD_ACCESS at 0xe0 in `WM_toolsystem_activate_brush_and_tool` ←
`brush_asset_activate_exec` (report BlenderLocal-2026-10-19-235016). The
autosave had been saved in Vertex Paint; the app opens every file with
`load_ui=False`, keeping its startup workspace, which has no 3D View tool for
that mode, and Blender reads that tool without asking whether there is one.
Desktop does the same: a file saved in Vertex Paint, opened in a Blender of
its own, crashes on `asset_activate` (exit -11), and so does one saved in
Sculpt Mode on the sculpt Brush menu. `_blenderkit_sculpt.ensure_view_tool`
now makes the tool (`wm.tool_set_by_id`, as a stroke's `_ensure_brush_tool`
does) before both modules' `activate`, which run on the main thread only.
Guards check, each case a Blender of its own: Vertex Paint, Weight Paint and
Sculpt files reopened with no tool, the pick runs and the tool is there; the
two controls without the guard crash. In the app, the same autosave: Paint
Hard picked, the stroke made. A second crash, in a desktop probe of mine:
`temp_override(window=None, screen=None)` segfaults in
`WM_window_get_active_screen`; any script line could do it, so the app's
`temp_override` wrapper refuses a screen with no window in words (guards
check, with a crash control; `window=None` and the others alone still enter).

**Also (the low ones).** A Line stroke is spaced as Blender's line end spaces
it (`paint_space_stroke`), in both modules: a 273 px line at 6 px spacing
sends 46 dabs (it sent 2) and weights 23 vertices where its ends alone weight
4. A chunk Blender refuses ends a paint stroke with `PaintModeBpy.cancel`,
which replays nothing held back (`BpyBridge.sculptEnd(afterRefusal:)`):
flushed 0 where `end` flushes 46. MAX_STROKE_DABS cuts at its value: the
throttle let a stroke grow past it and replay all of it; now 2,468 dabs at
size 10 are one cut and two of Blender's strokes, one history step, Undo
exact. The sculpt check's Dynamic Topology cut no longer passes on no chunks.
The Name field applies a typed edit to the name it was typed over when that
name changes under it (a tap on another group's row): in the app
(`-name-draft-switch Renamed`) Blender holds Renamed and Other, Other active.
The two steps are in the other order from Blender's (Active Vertex Group,
then Name): the row's tap reaches Blender before the field sees it. Align
Active Camera to View aims `scene.camera`, as `view3d.camera_to_view` does:
in the app with another camera selected and active, the scene camera moved
to the view and the other stayed where it was. New DEBUG: `-name-draft-switch`,
`-standin-dab` in the paint modes, `-textimage-ops culling:old|blender` and
the capture's coverage, `-opsearch` printing Multires levels, and
`-vwpaint-stroke` printing the darkest colour drawn and held.

Not done: the Voxel Remesh estimate's over-refusal of detailed meshes and its
Python walk on the main thread (the review's figures stand); Align Active
Camera to View still ignores locked channels and Euler continuity; the Name
field's step order above; weights still a Python loop.

## October 19: the names held to the app, and Blender's own steps measured in it (round 4's review of Blender's names)

An adversarial review of the October 2 names work found three medium
defects. Each is fixed and measured; so is a crash the measurement found.

**The Blender check now reads the app's 3D View steps from the app.**
tests/names/blender/verify.py typed in sixteen of the app's undo labels (Edit
Mode, Add Duplicate, Duplicate Objects, Delete, Shade Smooth, Shade Flat,
Move, Rotate, Resize, Hide Selected, Reveal Hidden, Add Modifier, (De)select
All…), and nothing read LayoutWorkspace, where they lived: the review changed
the Edit Mode step to "Enter Edit" and Shift+D's to "Duplicate Mesh" and no
check failed. They are `UndoStep` now (Sources/BlenderLocalBridge/
UndoSteps.swift), which LayoutWorkspace, RootView, PropertiesView,
TransformGizmo, the gizmo's commit (`GizmoCommit.name`) and the Cursor tool
use; tests/names/main.swift prints each with its call and the Python the
button sends, the Blender check holds them to Blender's measured steps with
no name of its own, `tests/names/verify.py` holds each Python to its call,
and `tests/names/scan.py` fails a call in BlenderLocalUI or BlenderLocalApp
that runs one of those builders with an `undo:` that is not UndoStep's (a
literal, or a name the UI defines), any literal repeating one of UndoStep's
names as a step, and an `undoName` holding a literal. The review's two edits,
made in a scratch copy of the tree: scan.py failed "Duplicate Mesh"
(`Bpy.duplicateElements runs with undo '"…"'`); with "Enter Edit" in UndoStep
the Blender check failed editmode_toggle and mode_set into and out of Edit
Mode; with UndoStep's Shift+D renamed it failed mesh.duplicate_move. Separate
and the gizmo's steps, typed into the dump before, come from the app too.

**Blender's own steps, measured in the app.** The app's history pushes every
step under the app's label, so the October 2 entry's in-app readout showed
the app's strings arriving, not Blender's (corrected there). Now
tests/names/app_steps.py calls 41 of the measured operators with their undo
on in whatever Blender runs it, in its own fixture in the open scene, and
reads each step Blender pushed from Blender's stack; app_steps_compare.py
holds the app's names (the dump) to them. In the app (`-eval64`, the real
iPad build on this Mac, its bundled Blender "5.3.0 Alpha"): 41 calls, each
pushed a step, and 41 of 41 are the names the app records — Edit Mode in and
out, Sculpt Mode (not the "Sculpting" October 2 saw under a stroke), Add
Duplicate, Import Wavefront OBJ, Triangulate Faces, … The names check runs the
same script in desktop 5.2.1 with the app's script context (a window and its
screen, no area), where it has to equal the check's own 43 measurements (it
does), and the comparison is first shown failing a measurement with one name
changed.

**A crash this found, and the guard.** The first run of that script in the app
crashed it (report BlenderLocal-2026-10-19-210858): `object.mode_set(mode=
'SCULPT')` with its undo on, `ED_undosys_stack_memfile_id_changed_tag` with a
null undo stack, from `push_enter_sculpt_mode`. The app's autosave opened
with Ball in Vertex Paint, which defers the history's probe, so nothing had
made Blender's undo stack (a Blender with no interface has none until
`ed.undo_push` makes one). The desktop probe before it had pushed a step
first, so it never had that state. Measured in desktop 5.2.1 with no stack:
`mode_set(SCULPT)` with its undo on, `sculpt.sculptmode_toggle` the same way,
and `paint.mask_flood_fill` or `sculpt.face_sets_init` in Sculpt Mode even
without it, each exit 139; so did `mask_flood_fill` after `read_homefile` or
`open_mainfile`, which free the stack; Vertex Paint, Weight Paint, Texture
Paint, Edit Mode and Dynamic Topology did not. A user's script line, or the
Operator Search, could reach any of them. `_blenderkit_undo.ensure_stack` now
makes the stack whenever the history has not — in `push` while the probe is
deferred or has failed — and `_blenderkit_context`'s file-read guard calls it
after every load. `scripts/run-undostack-blender-check.sh` (new) runs each of
four of those calls in a Blender of its own, the app's way: all four survive,
and with the guard switched off all four crash (exit 139), so the check can
fail. app_steps.py also refuses to measure where Blender has no stack. The
second run in the app, after the guard, did not crash. The guard changes when
the stack is first made — at the history's first push, or right after a load,
not at the first stroke — so the paths that used to make it were run again:
the sculpt check's relaunch under Dynamic Topology (the first push, its probe
deferred, now makes the stack; the stroke keeps Dynamic Topology on through
all 6 chunks, 5,958 → 6,114 vertices, Undo and Redo exact) and its stroke
after a load; the Vertex Paint check's stroke after a load, with Weight Paint
entered as the bar enters it. Both checks keep their old no-stack cases with
the guard switched off for the load, so the strokes' own stack-making
(`_require_undo_stack`) is still tested. In the app, launched on its autosave
in Vertex Paint (`-vwpaint-stroke -vwpaint-undo`): 36 dabs in 27 chunks, 121
of 1,106 vertices painted, drawn and held 0 apart, Undo 0, Redo 121, as round 4
group 2 measured before the guard.

**The docs say what is measured.** README and docs/blender-names.md said every
undo step is the one Blender's history records. Now the names doc sorts steps
into three kinds: an operator's (measured, 43 calls on desktop and 41 in the
app; every operator's step is its name but a mode change's); a field edit's
(the field's text, as Blender's source names it — `ui_apply_but_undo`, the
text up to its colon, a tooltip where there is none — read, not measured,
since no headless Blender has a field to press); and the app's own ("Edit
Modifier" for a modifier setting, where Blender records the field's text; the
3D cursor's two snaps, which Blender records no step for; Run Script). The
unmeasured view-polling operators are held to their names "as every measured
operator's was but a mode change's" — the October 2 doc said "as every
measured one was", which mode_set ("Set Object Mode", recorded as Edit Mode
or Sculpt Mode) is not.

**The smaller items.** The Timeline's field steps are the fields' text, Start
and End (were Start Frame / End Frame and Preview Range Start / End Frame;
Blender's Timeline draws all four as Start and End). Three redo-panel fields
take their properties' names — Bisect's Plane Normal (was Axis), Edge Rings'
Edge Ring Delimit (Delimit), Slide Vertices' Slide Direction (Direction) — and
the names check now holds every field of every redo panel it dumps to its
RNA name (a vector's rows to X/Y/Z, a macro's to its operators'), with one
exception said: Shear's Axes row, which is Blender's Axis and Axis Ortho in
one. The Object tab's Show in Viewports switch sits in Visibility ▸ Show In ▸
Viewports, as Blender's (OBJECT_PT_visibility), not in Relations; an area
light's Shape and Size are in its one Light panel (there were two panels
titled Light, and an area showed a Radius it does not use); the sculpt
header's Remesh button is Remesh (was Voxel Remesh; the step is still the
operator's name); Texture Paint's colour is labelled Color (was Brush Color);
the simulator's sculpt brushes show their Essentials names in the header, the
Sidebar and the drag's status (Inflate/Deflate, not Inflate); refusals point
at rows that exist — Remesh ▸ Add Multires and Subdivide, Mesh ▸ Edge ▸ Mark
Seam, the Layout tab (there is no Sculpting tab) — and the stand-in's render
message at the Layout tab. FocusLog no longer documents an `-ax-dump` flag
that never existed; the redo suite's stale comment (and its check) read the
groups' `rows`. Not changed, and listed in docs/blender-names.md: the Mac
menu's Script, the camera's Cameras panel, Shear's Axes, the Animation menu's
same-titled pairs, and "Blender's 3D View" in refusals. The Mesh ▸ Edge row the
review called "Loop Cut" was already Blender's Subdivide Edge-Ring (round 4,
group 3).

## October 2: Blender's names (round 4, group 1)

Asked for every tool and command to carry Blender's own name, the app now
does: the toolbar's tools (Tweak, Select Box, Select Circle, Select Lasso),
modes (Edit Mode and Object Mode in place of Edit Mesh and Done), the tabs
(Scripting and Layout; "3D View" was no Blender workspace), the header
(Pivot Point, Snapping's Snap Base and Snap Target, Proportional Editing),
the More menu (Cameras ▸ Active Camera, Viewport Shading, Properties,
Operator Search, Tool Settings, Duplicate Objects, Delete), the Mac menu bar
(a Select menu of its own, the Text editor's Run Script, Jump To, Unindent),
File ▸ Import's per-format rows, the panels and their fields, the Operator
Search's list (each operator by its RNA name: "Select Keyframes", not
"Clickselect"), the redo panel's titles and every undo step. The Mesh menu is
made of Blender's own menus now — Transform, Extrude, Merge, Split, Normals,
Clean Up, Delete, Vertex, Edge, Face — each row where Blender has it, running
the operator Blender's row runs; Add Geometry, Cut and Divide, Fill and
Deform are gone. docs/blender-names.md has every old name beside Blender's,
where each was read, and the names kept as the app's own (More, Image to 3D
Model, the Scripting tab's, …).

Measured in desktop 5.2.1 with the app's undo history and gpu.init: 43
operators called with their undo on, each step read back with
print_undo_steps (and, since October 19, 41 of them in the app's own bpy —
see that entry; what this entry first gave as the in-app proof was not one). Blender records `select_all` as "(De)select All" whatever
the action, every Edit Mode entry and exit (`editmode_toggle` and `mode_set`)
as "Edit Mode", Shift+D in Edit Mode as "Add Duplicate", an OBJ import as
"Import Wavefront OBJ", and a sculpt stroke after its brush — "Draw Brush",
"Grab Brush", "Inflate Brush" — which the history now reads from Blender's
stack when the stroke ends (`_blenderkit_sculpt.end`'s `step`). A
view-polling operator called with its undo on under the borrowed 3D View
crashes desktop Blender in `ED_area_type_hud_ensure` (hide_view_set,
camera_to_view, object_as_camera, snap_selected_to_grid; probe crashes only —
the app makes no such call), so those steps are held to the operator's name.
One brief item turned out to be Blender's already: Edit Mode's Show/Hide ▸
Reveal Hidden is `mesh.reveal`'s own name.

Run in the real app (Designed for iPad, real bpy) through `-object-ops`,
whose new `ax` token prints the app's own accessibility tree: the bar read
Tweak, Move, Rotate, Scale, Pivot Point, Snap, Proportional Editing, Select,
Add, Mesh, Sculpt, Outliner, Edit Mode, More; in Edit Mode, Edit Mode Cube,
Vertex, Edge, Face, Object Mode, Options, Extrude Along Normals, Bevel, Inset
Faces, Subdivide; the redo panel, "Extrude Region and Shrink/Fatten"; the
sheets, Properties (Scene, Object, Modifiers, Data, Material, Data API), Tool
Settings (Snap Base, Snap Target, Target Selection, Include Non-Edited,
Proportional Editing Falloff, Proportional Size), Outliner (Hide in
Viewport, Disable in Renders), Operator Search (All Operators); and the
`steps` token read Blender's own history as (De)select All, Edit Mode,
Extrude Region and Shrink/Fatten, Add Duplicate, Mark Seam, Edit Mode; File ▸
Import's path (`-export obj`) recorded "Import Wavefront OBJ"; the Operator
Search listed "Select Keyframes, action.clickselect"; and a Draw stroke
(`-sculpt-stroke`) was recorded as "Draw Brush", Blender's own step, Undo and
Redo taking it back and forth. (Corrected October 19, after round 4's review:
every one of those steps but the stroke was pushed by the app under its own
label — `_blenderkit_undo.push` → `ed.undo_push(message=label)` — so reading
them back showed the app's strings arriving in Blender's history, not that
they are Blender's names. The stroke, which Blender names itself, was the one
in-app measurement; the desktop check was the evidence for the rest, until
October 19's measurement in the app.) That stroke found a difference between the
builds: the app's bundled bpy prints a sculpt step's type as "SCULPT" where
desktop 5.2.1 prints "Sculpt", so the name is read without case
(`_blenderkit_sculpt.stroke_step`). `_below_is_sculpt_step` compares the
type to "Sculpt" exactly, so on the device it never sees a sculpt step below
a stroke and anchors every stroke (a zero-strength first dab) — correct but
slower; left for a round that may change behaviour. Under the stroke the
device's stack held a Global Undo step named "Sculpting" where desktop
5.2.1's step for entering Sculpt Mode is "Sculpt Mode", the name the app's
label keeps (measured on desktop, as the brief asks).
Tests: `scripts/run-names-tests.sh` (every literal the app ships scanned for
the old names, with snippets proving it can fail, and every table-built name
held to Blender's menus and toolbar) and `scripts/run-names-blender-check.sh`
(titles, undo steps, enums and brushes held to Blender itself).

## October 18: Weight Paint and Vertex Paint reach Blender, and round 3's open defects (round 4, group 2)

Begun on October 2 by an agent stopped before it reported, finished and
measured here. Desktop numbers are Blender 5.2.1 with the app's context (its
undo push, `gpu.init()`, the borrowed 3D View); "in the app" is the real iPad
build with its bundled 5.3 bpy, run on this Mac as Designed for iPad through
the DEBUG hooks (the screen was locked, so no taps).

**Weight Paint and Vertex Paint are Blender's own.** Their dabs used to paint
the display cache and never reach Blender (round 3's review; the seventh
control of that kind). Now the bar's mode rows run `object.mode_set` (steps
"Weight Paint Mode" / "Vertex Paint Mode"), the brushes are Blender's
Essentials assets (both `.blend` files staged beside the sculpt one), and a
stroke is `paint.weight_paint` / `paint.vertex_paint` under the 3D View
override, streamed as a sculpt stroke is (`_blenderkit_vwpaint`,
SculptStrokeInput's `BrushStroke.paint`). After each chunk, and in every
mirroring pass in those modes, `_blenderkit.sync_paint` hands the viewport
the active group's weights or the active colour attribute (sRGB, a corner
layer averaged per vertex) read from the evaluated mesh. PaintModeHeader is
Blender's header: brush, Brush / Blur / Average / Smear, Blend, Weight or the
colour, Size, Strength — each written through `bridge.run`, each shown as read
back. What was measured:
- By `EXEC_DEFAULT` the operators paint only with `override_location=True`.
  One stroke cut into strokes is not the same stroke (without Accumulate a
  stroke caps at the brush's strength), so each chunk undoes the stroke so far
  and replays it whole: 10 chunks matched one Blender stroke to 3e-7 (weights)
  and exactly (colours), all 4 + 8 Essentials brushes, Undo and Redo exact.
- A long stroke is not cut for being long (new this pass). Cut at 64 dabs, as a
  sculpt stroke is, 216 dabs back and forth over a ball at strength 0.3 came
  out 0.456 apart in weight and 0.345 in colour from one stroke. Now a replay
  dearer than 25 ms waits until twice its cost has passed (the view shows
  Blender's last replay) and the end replays the rest (`_flush`); only past
  2,048 dabs is a stroke kept and continued. Check: 269 dabs, 59 of 60 chunks
  held, the end replaying all of them, one step, 3e-7 from one stroke; the
  negative control, cut at 64, 0.455 apart.
- Blender's exec path skips what its invoke checks: a locked group (warns,
  still pushes a step), a hidden object, a mesh with no faces, every dab off
  the surface (an empty step). Each is refused or skipped first. With no 3D
  View the operators fail their own poll: a script line is refused, not crashed.
- In the app (`-object-ops paintmode:weightPaint -vwpaint-stroke -vwpaint-undo`,
  a 48 × 24 ball): 36 dabs in 27 chunks (median 7.4 ms), one step "Weight
  Paint"; the 3D View drew weights on 119 of 1,106 vertices, 0 apart from what
  Blender held; Undo 0 and 0, Redo 119 again. The same points through the same
  module in desktop, from the app's autosave: 119 painted, at most 4.8e-4
  apart. Vertex Paint (red, strength 0.8): 121 vertices (484 corners) drawn and
  held, desktop's replay exactly equal. Weight Paint differing where Vertex
  Paint through the same path does not points at 5.3's weight brush, not the
  path; that is not proven. A long stroke (`-vwpaint-passes 4`, size 30,
  strength 0.3): 637 dabs, one step, 0 cuts, the throttle holding 20 chunks
  and the end replaying the rest; desktop's replay 2.2e-4 apart.
- The vertex-group list (Add, Remove, active, Lock, name) works in Weight
  Paint too, whose brush paints the active group (the groups check, desktop).

**Dynamic Topology over a labelled change.** The stroke's anchor joins the
history step under it (`_blenderkit_undo.join_current`), and under Dynamic
Topology the anchor is Blender's Dynamic Topology Toggle off and on, whose
DyntopoBegin step rebuilds the BMesh a Redo replays onto. Sculpt check: Undo
5,367 vertices, Redo 6,588, Undo past the change and Redo back, Dynamic
Topology on throughout, the history one step at a time; round 3's anchor (the
negative control) turned it off and lost the stroke. In the app
(`-sculpt-ops dyntopo-on,labelled -sculpt-undo -sculpt-undo-depth 3`): 1,106 →
1,171 vertices; Undo 1,106 with it on, Redo 1,171; three Undos to the Labelled
Change, the toggle and Sculpt Mode (off there, as entered), three Redos back to
1,171 with it on. Two strokes in a row (`-sculpt-repeat 2`): the second, over
the first's Sculpt step, has no anchor (the device's "SCULPT" type is compared
without case now), rewinds of 0.3 to 0.8 ms, Undo exact.

**Voxel Remesh's estimate is an upper bound.** Thin shapes remesh into a tube
or blob about a voxel across. The estimate is Steiner's offset surface (area
+ 2·d·M + 4π·d² a piece, d 0.42 voxel, M the total mean curvature, an open
piece's area twice) at 1.87 vertices a voxel square; the module records the
fit, over 46 remeshes, every one at least 1.25 times under it. The sculpt check
holds 8 thin, open and ordinary shapes at 2 sizes within it, and ordinary ones
under 3.5 times it. The refusal says "as many as". A 2 m cube at 0.0048 is estimated at
1,954,089 (it makes 1,043,336) and runs; 0.003 is refused. In the app with
the budget lowered to 3,000 by a script: 30 hairs of 4 mm at 0.02 (area alone
said 2,772, Blender makes 3,328) refused at 6,730; a sphere with the budget at
10,000, 0.05 voxel, ran to 7,784 (area alone would have refused it at 12,465).
It walks the mesh in Python: 0.43 s for 131,072 faces on desktop.

**Align Active Camera to View** writes the view as the camera's
`matrix_world`, through its parent and rotation mode. In the app, then read
in desktop: a camera parented to a moved, turned, scaled empty 0 m and 0° from
the view (the old lines: 13.52 m, 74.2°); a quaternion camera 0 m, 0° (old:
43.1°).

**Mirrored objects are drawn as Blender draws them.** Each draw sets Metal's
front face from the object's matrix (`ViewportRenderer.frontFacing`). In the
app (`render-stats`): the cube at scale.x = -1 covers the same 9,784 pixels
at the same brightness, cell for cell, as at +1; with `winding:old` (the rule
before) two cells drop from 124.6 / 131.4 to 116.9 / 116.4. A face box select
on the mirrored cube took the 3 faces drawn, Blender holding the same.

**Multires from inside Sculpt Mode.** The panel's Subdivide, the search's
`multires_subdivide` and the Sculpt stepper are held to Sculpt Mode's
base-mesh budget (`refuse_heavy_level`), and levels to 300,000 vertices
(MULTIRES_LEVEL_BUDGET; the module records level 5 of a 1,986-vertex base
as 2,064,386 vertices, a 2.1 s Undo and 1.06 GB more for a Grab in desktop). The stepper was not, though the
check said so: it tested the Python, and the stepper's Swift sent its level
bare. Each Multires level now rides behind its check line, as the Subdivision
row's does; the modifier check runs the Swift's own edit on an 8,066-vertex
base (refused) and without the check line (level 1 set). In the app on that
base: the stepper, the panel's Subdivide and the search's Subdivide each
refused in words with the levels unchanged; the viewport level went through.
On a 1,986-vertex base at level 3, Subdivide was refused naming 516,098;
Sculpt levels 2 and 3 were set. The Sculpt header's Subdivide goes through the
panel's path: four presses left 0/4/4 (viewport/sculpt/total) in the app, as
Blender's own operator does from Sculpt Mode on a new Multires (the viewport
level stays where it was: from 1 it leaves 1/4/4, the modifier check's case).

**Vertex groups.** The Name field sends its edit when it loses focus as well as
on Return (`NameDraft`). In the app (`-name-draft Renamed`, the field's own
focus state): it took focus, lost it without Return, its draft was gone, and
Blender, the panel and the field held "Renamed". The position fallback for a
selection deselects edges and faces too: desktop only, 10 kept through two key
switches where the old string gave 25; in the app every path into it refuses
first under a rebuilding modifier (`editRegionRefusal`).

**A script's first Cycles render** prints the Render panel's warning before
the render (`_blenderkit_cycles`, armed while `bl_cycles_kernels_built` is
false). In the app, flag cleared, a script rendering Cycles on the M4's Metal
GPU: the warning between the script's lines and before its own `render_stats`
handler's first line, the render 38.5 s (2.5 s the next time), the flag true
after.

**Also:** Box, Circle and Lasso take only what the 3D View shows (in the app a
box reaching half a view past each edge of a 60 m grid took the same
171 vertices / 307 edges as one the size of the view); a frame handler that
clears the handler list no longer stops the frame reaching the timeline; the
shape-key switches are held to Object and Edit Mode (built, not tapped); the
Weight field's check reads its own step. New DEBUG hooks: `-sculpt-undo-depth`,
`-sculpt-repeat`, `-vwpaint-passes`, `-name-draft`, and `-object-ops`'s
`winding:old` / `winding:blender`.

Crashes: none in the app. In desktop, one report this pass, the guards
check's deliberate loop-cut negative control (`loopcut_init` ←
`wm_macro_exec`). The October 2 agent recorded one while probing: reading
`tool_settings` held across a memfile undo (freed memory,
`pyrna_prop_to_py`); the module reads it afresh each time.

Not done (each more than a small, certain fix): deleted-object frames outside
`depsgraph.updates`; the stand-in's refusal with no bridge; the private entry
points on the evaluated mesh; writers not held during a stroke and the
Multires stroke's silent wait; the rebuilding-modifier refusal's wording; the
transform fields' command subset, constraints, auto-keying and Collection
label; symmetry's drawn-position falloff and 12 bytes a vertex; point drags
against frame changes, Save/Export, the redo rewind and Start/End; Lock
Shape's preview, Assign racing the Weight field, unlabelled changes not
autosaved, the groups record's costs, claims measured on 5.2.1 not 5.3. A
sculpt stroke is still cut at 64 dabs; whether that changes a long sculpt
stroke as it did a paint one was not measured.

## October 18: Loop Cut and Knife (round 4, group 3)

The two cutting tools a modeller reaches for most were missing (round 3's
review, toolkit items 1 and 2). Both are tools in the Edit Mode bar now, Loop
Cut and Knife (Blender's toolbar names; Ctrl+R and K), and the Mesh menu has
the rows Blender has for them: Edge ▸ Loop Cut and Slide after Edge Slide, and
Knife Topology Tool after Knife Project, each picking the tool as Blender's row
starts it. Desktop numbers are 5.2.1 with the app's context (its undo push,
`gpu.init()`, the borrowed 3D View); "in the app" is the real iPad build with
its bundled 5.3 bpy on this Mac, driven through the DEBUG hook `-cut-ops`,
which makes the calls a pointer and a finger make (`loopCutHover`,
`loopCutTap`, `knifeTap`, `CutToolActions`).

**Loop Cut.** A pointer over an edge (hover with a mouse, trackpad or Pencil),
or a first tap, shows Blender's ring in Gizmo Primary yellow; a click, or a
second tap on that edge, cuts. The drawn edge is mapped to Blender's index by
its two vertices in the mirror's `blenderEdges` (Blender's own order; the
viewport's edge numbers are its own, diagonals included), and the ring is
Blender's: `_blenderkit_loopcut.ring` is `bmw_EdgeringWalker` with the flags
`edgering_select` gives it (hidden elements tested, quads only), and its
preview order is `edgering_find_order`'s. The commit is the line Blender's Info
editor logs, inside `temp_override_view3d('Loop Cut')`, after
`_blenderkit_loopcut.check` (the edge there and not hidden — on a hidden edge
Blender answers FINISHED and cuts nothing —, `object_index` naming the active
object, and the vertex budget through the whole stack, `stack_vertices(base=…)`).
The redo panel is Loop Cut and Slide's: Number of Cuts, Smoothness, Falloff
(greyed at Smoothness 0, where it measured no effect), Factor, Even, Flipped
(greyed until Even), each measured changing a cut, re-run on the same edge.
(Since the review, October 20: nothing greyed, as in Blender, and Clamp,
Mirror Editing and Correct UVs added.)
Under a modifier that rebuilds the mesh it refuses in `editRegionRefusal`'s
words ("… to cut a loop here"). Measured:
- Every edge of a cube (1 and 3 cuts), a grid (1, 2, and with 4 faces
  hidden), a 12 × 6 UV sphere (its pole fans: one point, as Blender previews
  them), an 8-sided cylinder (a rim's ring stops at the n-gon caps), a torus,
  an icosphere (all triangles) and a strip with a triangle, a pentagon and a
  hexagon (1, 2, and hidden faces): 655 cuts in 13 cases (and 9 hidden edges
  refused in words), every ring the cut Blender made, and the Swift preview
  drawn from it every vertex Blender made, with every preview line an edge of
  the cut mesh. Negative controls: a walker that
  crosses even n-gons disagrees on 10 edges; previews drawn without Blender's
  orientation fail 147 two- and three-cut edges.
- In the app (5.3): the same walker against the app's own cut, 397 of 397
  edges; a cube's edge, hovered then clicked, Blender's 4 new vertices on the 4
  previewed points (0 m apart), and a tap then a tap on another edge the same;
  Number of Cuts 3, Factor 0.5 and Smoothness 1 from the panel, then one Undo
  back to 8/12/6; a 32 × 16 sphere's pole edge (1 point, 1 vertex) and
  equator (32 and 32, 7e-7 m); a cylinder's rim (2 and 2) and side (8 and 8);
  under a Subdivision the refusal on the banner.
- The edge index is the edit mesh's: after a delete and an extrude left holes
  in BMesh's pools, the mirror's 108 edges numbered as the edit mesh's.

**Knife.** Taps add points — on the mesh where the line of sight meets it,
past it at the depth of the object's middle —, drawn as Blender's knife draws
its path, with the next segment following a hovering pointer. The bar has
Blender's knife names: Cut Through (off by default), Undo, Cancel (Escape),
Confirm (Return). `knife_tool` has no non-modal form, so Confirm runs Knife
Project, the same knife (`EDBM_mesh_knife`: a start, then a cut per point, the
snapping off), with the path as a temporary wire object and Blender's view
aimed from the app's eye — perspective, the longest lens (250 mm), looking at
the path's middle — or along its direction (orthographic), so a cut is the
plane the eye and two points make (`_blenderkit_knife.drawing`). Its undo step
and redo panel are Knife Topology Tool, what Blender's history calls a knife
cut; the Info line is the `knife_project` call. Measured:
- A cube from a perspective eye and an orthographic view, two- and three-point
  paths, Cut Through off and on: every new vertex where the path's planes cross
  the cube's edges (worked out independently with mathutils), plus one per face
  a point's line of sight meets, as a click on a face makes one: worst 8e-7 m
  in perspective, 4e-5 m orthographic. Cut Through off cut the 3 front
  crossings, on also the back (4); Vertex select mode kept and the cut edges
  selected, as Blender's knife leaves them; no path object left; the view, lens
  and clipping put back. Under a Subdivision the cage is cut at the same three
  crossings. Negative control: the perspective cut held to an orthographic
  projection is 0.021 m off.
- The clipping was the knife's error, not the lens: with Blender's default
  1000 m clip range the knife starts each line of sight 500 m out in float32,
  and an orthographic cut 22° above the horizon landed 2.2 mm off the plane
  (constant whatever the framing); fitted to the mesh, 0.04 mm.
- In the app: perspective, 3 crossings and 3 vertices (1e-6 m), Cut Through
  4 and 4, and the panel's Cut Through re-run; three taps on the surface, 4 and
  4; orthographic 3 and 3, through 4 and 4 (0 m); a path past the cube refused
  in words with the path kept for Cancel.
- That miss found a defect: Knife Project clears the selection and turns
  Vertex select mode off before the app can see that nothing was cut, and the
  refusal left Blender in Edge select mode. The mode and every element's
  selection are put back now (desktop: Vertex mode and vertices 0 and 3 kept).

**Subdivide Edge-Ring.** The Edge menu's old "Loop Cut" selected the whole
ring and then ran `subdivide_edgering`, which no row of Blender's does. It is
Blender's Subdivide Edge-Ring now, that operator alone: with one edge, or two
sharing a corner, Blender answers FINISHED and cuts nothing, which is refused
in words (`LastOperator.unchanged`); two edges across a face 8/12/6 → 10/15/7.
(It still sent the old row's 1 cut, Linear and Smoothness 0 under Blender's
name; since October 20 it has Blender's five rows and defaults: 28/42/16.)
In the app: two ring edges cut, none selected refused.

**A crash, and its guard.** `bpy.ops.mesh.loopcut_slide('EXEC_DEFAULT', True, …)`
— the undo argument on — under the borrowed 3D View segfaulted desktop Blender
in `ED_area_type_hud_ensure` (a probe of mine; the app makes no such call).
`_blenderkit_context` refuses Loop Cut's two operators with their undo on.
(The review measured `1` crashing past it — Blender reads any int as the undo —
and every registered operator crashing the same way; October 20 has the fix.)

Tests: `scripts/run-cuttools-tests.sh` (50: the edge mapping and its negative,
ring parsing and the preview's geometry, the exact calls, the knife path, the
refusals' words) and `scripts/run-cuttools-blender-check.sh` (the sweeps, the
Swift-made calls and refusals, the knife cases, then the Swift preview over
Blender's cuts and its negative control). The redo and names checks follow the
rename. New DEBUG flags: `-cut-ops`, `-cut-view`, `-cut-wait` (in scan-app's
HOOKS).

Not done: Loop Cut under a modifier that rebuilds the mesh is refused, where
Blender cuts the cage; a Knife cut keeps none of the earlier selection (Blender's
adds the cut edges to it); a knife path is cut from the view as it is at
Confirm, so orbiting between taps changes the planes; the knife's Close (a
closed path) and angle snapping are not offered. (The review found the Knife
not snapping to edges and vertices, which this entry did not say; since October
20 it snaps, keeps the earlier selection, cuts the path as the Confirm view
shows it, and closes on a tap on its first point. Angle snapping is still not
offered.)

## October 18: Pick loops, rings, paths and linked; the whole Select menu (round 4, group 4)

Round 3's review (toolkit item 5) measured Blender's Alt+click, Ctrl+Alt+click,
Ctrl+click and L returning CANCELLED under the borrowed 3D View. They were
called without an index. Each of the four (`mesh.loop_select`,
`edgering_select`, `shortest_path_pick`, `select_linked_pick`) finds the
element under the mouse in its invoke and hands its index to its exec — the
hidden `edge_index` / `index` "for redo" — and given the index the exec is the
whole operator. So the app picks the element on the cage with its own tap
(`MeshPicker`), names it by Blender's index (`SelectPick.element`), works out
the element the invoke would make active (`SelectPick.loopActive`: the nearer
end in Vertex mode, the face with the nearer middle in Face mode) and runs
Blender's own operator with them, inside the borrowed view where its poll asks
for one, after `_blenderkit_select.check_pick` (the mesh the tap picked on is
still Blender's, the element is there and not hidden). Redo panels are
Blender's: Loop Select's Delimit (Face Loop Delimit in Face mode), Edge Ring
Select's Edge Ring Delimit, Pick Shortest Path's Edge Tag, Face Stepping,
Topology Distance, Fill Region and checker fields, Select Linked's Deselect
and Delimit — enum flags as a row of toggles under their heading
(`Parameter.Kind.flag`). Shift is Blender's keymap's: Toggle Select for loops
and rings, Fill Region for paths, Deselect for Linked. A pointer's Alt,
Ctrl+Alt and Ctrl (or ⌘) make them; a finger gets a pick bar over the view's
top left while editing (Select, Loop Select, Edge Ring Select, Pick Shortest
Path, Select Linked, and the Shift variant by Blender's name) and the same
rows in the Select menu; L and Shift+L pick under the hovering pointer, Ctrl+L
is Select Linked ▸ Linked. Under a modifier that rebuilds the mesh all of
them refuse in Box Select's words (`editRegionRefusal`).

The task proposed instead pushing the element as the selection and running
Select Loops from it. Measured in desktop 5.2.1 on every edge of a grid, a
cube, a UV sphere and a cylinder: the same loop in Vertex and Edge mode, a
different one in Face mode on 0 of 252 edges (Alt+click walks a face loop
there), no loop-to-boundary cycling on a second click, no active element. It
is the check's negative control.

**Blender's selection order.** The app's taps never set it, so nothing was
active for Ctrl+click, Next Active or Side of Active (the reason round 3 greyed
the last two). Now a tap updates the order as Blender's click does
(`EditSelection.picked`: Set makes it the order, Extend moves it to the end,
Shift — newly Blender's toggle for a pointer, Toggle Selection on the bar for a
finger — adds or takes it out), `Bpy.pushEditSelection` writes it
(`select_history`, and the active face), the mirror reads it back
(`_blenderkit_select.history_bytes`, a new optional argument of
`sync_edit_selection`), and the viewport draws the active element white
(Blender's theme: vertex and edge #FFFFFF, the face #FFFFFF33). A Set region
select clears it, as Blender's deselect-all does. Ctrl+click with nothing
selected selects the element, as Blender's invoke does, under the operator's
name.

**The Select menu**, against 5.2.1's: Next Active and Previous Active
(`select_next_item` / `select_prev_item`, refused in words when they would
change nothing — they answer FINISHED with "Selection pair not found" only in
a report), Side of Active (`select_axis` with its panel; its View axis runs in
the borrowed view aimed as the app looks, `_blenderkit_select.aimed_view`;
with no view View acted as Global, measured), By Attribute (Blender's poll
words on the banner: "There must be an active attribute"). Select Grouped's
operator can never run in a bpy module — its poll returns False for
G.background ("uses popup menus") — so it is its exec, type by type
(`_blenderkit_select.select_grouped`), Extend and Type in its panel; two
collections are refused naming them, where Blender asks in a menu. The Object
Mode rows (Active Camera, Mirror, Random, More/Less, Parent/Child, All by Type,
Linked, Pattern) go through `perform` now, with Blender's redo panels; their
guard (`object_select`, which puts back what a CANCELLED changed) is kept out
of the Info log (`LastOperator.guardWithin`).

**A crash class, and its guard.** A registered operator called with its undo
on inside an area override opens its redo panel there, and with no interface
that area has no type: `ED_area_type_hud_ensure` segfaults. Three deliberate
probes in desktop crashed this way (`loop_select`, `select_linked_pick`,
`select_next_item`, `'EXEC_DEFAULT', True` under `temp_override_view3d`), as
group 1 found for four others and group 3 for `loopcut_slide`. An operator
looked up inside an area override is now wrapped and refuses that call in
words (`_blenderkit_context.refuse_undo_in_area`; unregistered ones such as
`brush_stroke` keep their undo; outside an override every operator is still
Blender's own object). The app never makes such a call; a script could.
(Corrected October 20, after round 4's review: this guard refused `True` only
and wrapped only operators looked up inside an override, and both gaps
crashed desktop Blender. The guard now reads the undo as Blender does and
wraps every operator in a Blender with no interface — group 3's fix — and only
unregistered BLOCKING operators keep their undo there; see October 20, group
4.)

Measured:
- `scripts/run-selectpick-blender-check.sh`: at 1,183 pixels of a grid (top,
  orthographic), a cube, a 12 × 6 UV sphere and an 8-sided cylinder (n-gon
  caps), in all three modes, MeshPicker named the element Blender's own click
  takes there (`view3d.select` with X-Ray, the only pick Blender makes without
  a window) every time; 12 sphere pixels where Blender's click took another
  edge than the one aimed at (two within 0.15 to 0.35 of a point on the
  silhouette) are counted and left out. The app's calls from those pixels gave
  Blender's own result element for element, the active element included, in
  1,393 of 1,393 cases (1,183 picks, 96 second clicks, 114 Fill Regions);
  where a pointer is exactly between two faces' middles (24, the grid from the
  top) either face is accepted as active. (Since October 20 Loop and Edge Ring
  are also sampled off the middle, where neither is a tie — see that entry.)
  Negative controls: the multi-select
  in Face mode 0 of 84 agree; the far end of an edge made active, 84 of 84
  caught; a path pushed without the order refused. Select Grouped's eleven
  types against what the exec does, Extend, the refusals; the order's round
  trip; Next/Previous Active and Side of Active (Local and View) counted;
  `scripts/run-selectpick-tests.sh` (74) the Swift half.
- In the app (5.3, `-select-pick`, the tap's own `meshEditTap` with keys, the
  pick bar's state, the L key's notification, the menu rows): a 7 × 7 grid
  from the top — Alt+click 7v/6e, again on its boundary 7 then 24 (Blender's
  cycle), Ctrl+Alt+click a ring of 7 edges, Shift adding a second ring, the
  Delimit toggles re-run from the panel; Ctrl+click corner to corner 13
  vertices, Shift+Ctrl+click to the centre 16 (Fill Region), the panel's Fill
  Region off 7; a tap, a Shift-tap beside it, Next Active 3 then 4, Previous
  Active 3, Undo and Redo; Face mode Alt+click 6 faces, a finger's Pick
  Shortest Path 10 faces, its Select Linked the cube island's 6 faces (Seam),
  Shift taking them away; Side of Active 36 and in View 36 (top view: View X
  is X). A UV sphere from above: equator loop 12, its ring 5, a pole edge's
  loop 6 (pole to pole) and ring 1, an n-gon's rim 8 and its face, a face loop
  4, a vertex path 4, L under the pointer on the n-gon island 8 vertices and
  Shift+L off again. A Subdivision cube: Alt+click, Ctrl+click, the finger's
  Select Linked and L each refused in words, Blender's selection untouched.
  Object Mode: Select Grouped Children 3, Extend from the panel, Color 2,
  Random's Ratio and Seed re-run, by Type, Linked, Pattern, Child, Parent,
  Active Camera refused. After every token the viewport's selection and order
  were Blender's. The accessibility tree read the pick bar as Select, Loop
  Select, Edge Ring Select, Pick Shortest Path, Select Linked, Toggle Selection.

Crashes: none in the app. In desktop the three probes above (guarded), and the
guards and opsearch checks' deliberate negative controls.

Not done: Blender remembers an operator's last redo values from one press to
the next (Select Linked's Delimit per mode, too); here each press starts from
Blender's first-press defaults, as the app's other operators do. (Corrected
October 20: Select ▸ Select Linked ▸ Linked and Ctrl+L did not — they sent
Seam in every mode; they follow the select mode now.) The active
face on a tie takes the later face, which is the edit mesh's order only for a
mesh entered fresh. The white active element was drawn but not looked at (the
screen was locked; no window capture). The order is carried 256 entries deep.
Ctrl+click from an iPad trackpad may arrive as a secondary click (not
measured). The selection-action buttons a tap was meant to read
(`MetalViewportView.selectAction`) are still set by nothing. New DEBUG flags:
`-select-pick`, `-select-pick-view`, `-select-pick-wait` (in scan-app's HOOKS).

## October 18: Typed values in Edit Mode, transform orientations, typed Dimensions (round 4, group 5)

Round 3's review (toolkit items 3, 6 and 16): Edit Mode had no way to type a
number, a gizmo drag opened no redo panel, every gizmo was Global (the only
orientation picker, ToolHeader's, was never on screen) and Dimensions was a
label. Desktop numbers are 5.2.1 with the app's context (its undo stack,
`gpu.init()`, the borrowed 3D View where noted); "in the app" is the real iPad
build with its bundled 5.3 bpy on this Mac, driven through the new DEBUG hook
`-transform-ops`, which makes the calls the controls make.

**The Sidebar.** SidebarN is on screen: More ▸ Sidebar and N (Blender's View ▸
Sidebar; N opened Properties until now), over the 3D View's right edge. Its
Item tab is Blender's Transform panel. In Object Mode: Location, Rotation,
Scale (`ObjectTransformFields`) and Dimensions. In a mesh's Edit Mode it is
`v3d_editvertex_buts` (view3d_buttons.cc in the 5.3 source; every label also
found in 5.2.1's binary): Median: (Vertex: for one) X:, Y:, Z:, Global and
Local, then Vertex Data: / Vertices Data: with Bevel Weight: / Mean Bevel
Weight: and Vertex Crease: / Mean Vertex Crease:, and Edge Data: / Edges Data:
with Bevel Weight: and Crease: (Mean … for several). `_blenderkit_item` reads
them from the edit mesh after the viewport's selection is handed over
(`BpyBridge.captureWithSelection`: a tap changes only the viewport's selection
until the next command), and each typed number is one `bridge.run` and one
undo step, written on the edit mesh with bmesh the way Blender's panel
applies it: the selection moved by the difference, one vertex put where it was
typed, weights scaled towards the typed mean (`compute_scale_factor`,
`apply_scale_factor_clamp`, 0 and 1 set outright), the layer added on demand.
The undo steps carry the fields' own words (X, Y, Z, Mean Bevel Weight, …):
Blender records the button's text and value ("X:1 m"), which a bpy module
cannot press. Global and Local is the 3D View's own flag in Blender (not in
the Python API) and is kept per device here, Local first, as Blender's: the
flag is clear in every View3D of the factory startup file (its SDNA read with
Python's zstd: `flag` 0x0808, 0x0800 or 0x080c, V3D_GLOBAL_STATS being bit 13).

**Dimensions** are fields in the Data tab and the Item tab, typed in Object
Mode (in Edit Mode the Data tab shows Blender's numbers without fields since
the review's fixes of October 20, below). Each axis is
written as Blender's N panel writes it (`BKE_object_dimensions_set_ex` with the
other axes masked, and the scale and world matrix from before), not through
`obj.dimensions = …`, whose setter leaves out a parent's and a delta scale:
under a parent scaled 2, a cube typed to 2 came back 4.000 that way (the
check's negative control). They show `obj.dimensions` as Blender reports it,
which in Edit Mode is the edit mesh's once evaluated (the old label measured
the drawn mesh's world box, which is not Blender's number: for a cube turned
45° about Z that box is 2√2 ≈ 2.828 wide where Blender's Dimensions say 2).

**Transform orientations.** The 3D View header has Blender's Orientation menu
(Global, Local, Normal, Gimbal, View, Cursor, Parent — `TransformOrientationSlot.type`'s
items), written into `scene.transform_orientation_slots[0].type` and read back
with its matrix. The gizmo's handles — Scale's too, as Blender's — are drawn on
that matrix, and every release sends it: `orient_type` with `orient_matrix` and
an equal `orient_matrix_type`, which makes Blender use the matrix as given
("Constraints are forced to use the custom matrix when redoing",
transform_generics.cc). Global goes bare, and so does a Scale in Local, which
Blender then applies in Object Mode to each object along its own axes, and in
Edit Mode along the edited object's — inverted, not transposed, where its axes
are not at right angles (the October 20 fixes), as the preview does.
A move's value is in the orientation's axes (Blender's exec takes
`global_dir = spacemtx · values`), and the preview multiplies the printed
numbers by the printed matrix. A headless Blender cannot be asked for its
matrix — no API returns it, and without a 3D View it reads neither the slot
nor the pivot — so `_blenderkit_orient` is `calc_orientation_from_type_ex` and
`getTransformOrientation_ex` ported line for line from the 5.3 source (the edit
mesh's face, edge, vertex and active-element cases, Gimbal for every Euler
order and an axis angle, the fall-throughs). Measured against Blender's own
matrix (the one `transform.translate` stores when given the type alone, read
from the operator it registers, or, for Active Element, by displacement under
the borrowed 3D View, the only place Blender reads the pivot): 67 cases in
Object and Edit Mode on cubes, grids, spheres, a cylinder's n-gon, an
icosphere, Suzanne, a sheared child, a lattice and a custom orientation — all
equal but one rounding tie (an icosahedron's equilateral triangles, whose
"most unique edge" differs by 1e-11, float in Blender, double here; the
normal agrees). Negative control: the port without the inverse transpose
disagrees. A curve's Edit Mode Normal (Bézier normals) is not ported: the menu
says so and no gizmo is drawn rather than one on axes Blender would not use.

**A gizmo drag is Blender's Adjust Last Operation.** The release rolls the
preview back and performs `LastOperator.gizmo` (`TransformGizmo.commit`) where
it used to `bridge.run`, which clears the panel. The panel's rows are Blender's
(`transform_poll_property` and the operators' RNA): Move X/Y/Z, Angle and Axis,
or Scale X/Y/Z; Orientation; Mirror Editing (Edit Mode); Proportional
Editing, and while it is on Proportional Falloff, Proportional Size and
Connected — hidden while it is off, as Blender hides them (new
`Parameter.shownWhen`). Constraint Axis is not a row: Blender hides it, and
for Move and Scale its exec forces all three axes. Projected (2D) is left out:
it projects along a 3D View region, which a headless Blender has none of. Each
Orientation choice carries what Blender needs to use it: the drag's own its
matrix, View the view's, the rest nothing, for Blender to work out from the
selection, the cursor, the parent. The redo panel's numbers can be typed now
(a tap on the field), not only scrubbed — built, not tapped: the screen was
locked, so the hook drove the calls behind the controls (`setOrientation`,
`readjust`, `ItemActions`, the Sidebar's state), not the controls. Auto keying's follow-up rides along
out of the Info log (`LastOperator.afterward`).

Measured in desktop 5.2.1 (`scripts/run-transformops-blender-check.sh`): 1,003
drags and redo changes on nine of Blender's scenes (objects turned, parented,
quaternion, a pair; a cube's face, a grid's boundary edge, Suzanne's faces, a
sphere's vertex, Active Element), every drag of every handle in all seven
orientations through the real session, each release's call run in Blender
and held to the Swift preview: worst 7.6e-6 m (View), 9.5e-7 m or less in the
other six; the redo changes — Orientation switched to each other one, Move X,
Y and Z typed, Proportional Editing turned on — through the bridge's own
rewind (`_blenderkit_undo.rewind`, the run, the step replaced). Two plane
drags were skipped: their handle is edge-on in the test's view. Negative
control: View drags sent without their matrix all land elsewhere. The Item
tab: 74 checks (each typed Median, Vertex and weight reads back, every element
where Blender's formula puts it, one undo step each, the refusals in words).

In the app (`-transform-ops`, a cube turned 30° about X, Edit Mode entered
from the bar, its top face selected): Normal's Z read (0, -0.5, 0.866), the
face's normal; a Move of 1 along it, preview 4e-6 m from Blender; the redo
panel "Move: X 0, Y 0, Z 1.000 m, Orientation Normal, Mirror Editing Off,
Proportional Editing Off"; Z typed 0.5 moved the face back to 0.5 along the
normal (vertex (-1, -1.616, 0.799)), Orientation Global to 0.5 up global Z
((-1, -1.366, 0.866)), one Undo to the start. Median Y typed 0.4 read back
0.4 (Dimensions following the edit mesh, (2, 2.78, 1.55)), Undo back; in the
earlier run Median Z typed 1.25 Global and X 0.1 Local read back, Edges' Mean
Bevel Weight 0.5 and Mean Vertex Crease 0.3 read back, one Undo took back the
crease alone and Redo put it back. Local
Rotate 20° about Y (4e-6 m) and its panel; Proportional Editing turned on
showed Proportional Falloff Smooth, Proportional Size 0.700 m, Connected Off;
Mirror Editing on re-ran with `mirror=True`; Normal Scale Z 1.5 (4e-6 m), then
Orientation Cursor re-ran bare. Object Mode (an earlier run): Local Rotate,
Gimbal Scale and View Move (0 to 2.5e-6 m), each with its panel; Dimensions X 3
and Y 2.5 read back as typed. Blender's history after the Edit Mode part:
Original, Original, Run Script, Edit Mode, Rotate, Resize, Edit Mode, then
Dimensions (the Move and the Median edit undone, as asked). The Sidebar read
Item, Transform, Median:, X:, Y:, Z:, Global, Local, Vertices Data:, Mean
Bevel Weight:, Mean Vertex Crease:, Edges Data:, Mean Bevel Weight:, Mean
Crease:; in Object Mode Location, Rotation, Scale, Dimensions: X: 2.000 m,
Y: 2.500 m, Z: 2.687 m — and desktop Blender reading the app's autosave held
dimensions (2.0, 2.5, 2.6868), scale (1, 1.0425, 1), the slot Parent. With
the final build the Sidebar opened in Local, as Blender's does: the top face's
Median read X 0, Y 0, Z 1.000 m, its own coordinates (Global is (0, -0.5,
0.866)). A curve in Edit Mode: Normal said unavailable and drew no gizmo;
Local drew one on the curve's axes.

That run found one limit, not new: when a session's first steps are made in
Edit Mode (here a script entered it), Blender's undo is not probed yet
(`_blenderkit_undo.probe` waits for Object Mode) and the history is
checkpoint files, where an operator adjusted only through Blender's undo —
Parent, Join, and now a gizmo drag — commits without a panel. Entering Edit
Mode from the bar, the panel opens.

A defect the check caught before the app ran: adding a weight layer to the
edit mesh moves every element's data, and `set_data` wrote through the
references it had gathered ("BMesh data of type BMVert has been removed");
it gathers them again now. Scale's gizmo used to be pinned to the object's
own axes whatever the orientation; it follows the orientation, Global by
default, as Blender's does — `TransformOperation` gained `.axes(matrix)`
for it. Every gizmo call now carries Blender's full set of arguments
(`orient_type`, `mirror=False` in Edit Mode, the proportional ones off),
as Blender's Info log writes them.

Tests: `scripts/run-transformops-tests.sh` (67: Blender's names and the
report's parsing with broken lines refused, the gizmo on each orientation and
none for an unknown or unavailable one, the commit's values and matrix, the
panel's rows and hidden rows, rotate, scale, the view ring, Individual
Origins, auto keying out of the log, the Item tab's labels and calls, what
reaches Blender in which order) and `scripts/run-transformops-blender-check.sh`
(the five stages above). The gizmo, tools and symmetry suites follow the new
strings (Blender's header wording "along global Y"; `mirror=False` is not
mirroring); the 3dview check's Local scale cases set Local, and the points
check holds a curve's scale to Global by default and to bare Local in Local. New DEBUG flag: `-transform-ops` (in scan-app's HOOKS).

Crashes: none in the app, none in desktop Blender from this group's runs.
(Two desktop reports at 22:38 and 22:45 today fall between this group's
Blender runs — 22:34, 22:41, then 23:16 on — and are not from them; one
"main" report at 23:33 is this check's own Swift reading a file an earlier
failed stage had not written, which now fails in words.)

Not done: typed positions for a curve's or a lattice's points (Blender's
Control Point: / Median: there; the tab says so); a curve's Normal; Blender
remembers the last orientation per transform type (slots 1–3, "use" off by
default) — only the main slot is offered; custom orientations are honoured
when a script made one, but there is no Create Orientation button; the Item
tab's Skin radius rows (Radius X / Y, with a Skin modifier); a field dragged
in the Item tab moves nothing until the finger lifts.

## October 19: The Mesh menu's search-only rows, Rip and Extrude to Cursor (round 4, group 6)

Round 3's review (toolkit items 8, 9 and 14) found these reachable only by
name in the Operator Search. They are Mesh menu rows now, each where
Blender's menu has it and by its label, through `LastOperator` with
Blender's redo panel (5.2.1's RNA: labels, defaults, soft ranges, and the
rows each panel's `ui` callback hides): **Merge** ▸ At Cursor, Collapse, At
First, At Last (beside At Center and By Distance; Merge's panel is Type, its
five items, and UVs — it was "Merge" with two); **Delete** ▸ Vertices, Edges,
Faces, Only Edges & Faces, Only Faces, Limited Dissolve (also in Clean Up,
as in Blender), Collapse Edges & Faces, Edge Loops (Face Split); **Vertex** ▸
Extrude to Cursor or Add, Connect Vertex Pairs, Rip Vertices, Rip Vertices
and Fill, Rip Vertices and Extend, Smooth Vertices (Laplacian); **Edge** ▸
Rotate Edge CW / CCW; **Face** ▸ Intersect (Knife), Intersect (Boolean), Weld
Edges into Faces; the Mesh menu's own Convex Hull and Snap to Symmetry;
**Normals** ▸ Recalculate Inside, Set from Faces, Point to Target… (Target
starts at the 3D cursor), Average ▸ Custom Normal / Face Area / Corner
Angle (a submenu, as Blender's), Smooth Vectors; **Extrude** ▸ Extrude
Manifold (the macro Blender's row calls: Dissolve Orthogonal Edges and a Move
along the Normal's Z — its panel's one moving field). Titles and undo steps
are the operators' names (Merge, Delete, Vertex Connect, Rotate Selected
Edge, Laplacian Smooth Vertices, Extend Vertices, …). Recalculate Outside's
panel field is Blender's Inside checkbox (it was "Facing"). Separate (By
Material, By Loose Parts) and Split (Selection, Faces by Edges) were rows
already; `mesh.separate` is UNDO without REGISTER, so Blender has no panel for
it either. The new rows are Edit Mode rows, as in Blender: from Object Mode
they would act on the stored selection (every element of a new primitive),
and Intersect (Boolean) with nothing unselected empties a cube. A sub-operator
vector is one entry of its dictionary now (`"value": (0, 0, 0.2)`, where the
old assembly would have sent `"value.z"`).

Each row refuses in words, before or instead of Blender, where Blender would
answer FINISHED having done nothing or fail in its own terms: measured in
desktop 5.2.1 on a cube, merge's At First and At Last fail with
'enum "FIRST" not found in (...)' without a vertex order (`check_merge` says
what to do), every Merge type and Edge Loops, Collapse, Weld and Connect
Vertex Pairs answer FINISHED unchanged on a selection they cannot use, and the
Delete types, Connect Vertex Pairs, Laplacian, Snap to Symmetry and Point to
Target answer CANCELLED with nothing selected. Only an empty selection is
refused where a panel field decides what there is to do (Intersect's Source,
Convex Hull's switches, Snap to Symmetry's Threshold). Weld Edges into Faces
splits only selected faces along selected loose edges
(`edbm_face_split_by_edges_exec`): a loose diagonal alone selected changed
nothing.

**Extrude to Cursor or Add** (Blender's Ctrl+right click). Its operator has an
invoke and no exec, and a Blender with no window has no event to give it
(`eventstate` exists only for a window with a GHOST window, wm_window.cc):
PASS_THROUGH, nothing changed, under the borrowed 3D View (measured again
here). `_blenderkit_meshmenu.to_cursor` is `edbm_dupli_extrude_cursor_invoke`
ported from the 5.3 source with the pointer over the 3D cursor in the app's
view: the selected edges' screen normal against the pointer
(`line_point_side_v2`), the point under the pointer at the selection's depth
(`ED_view3d_win_to_3d`), the rotation toward it (halved with Rotate Source,
the source turned by the other half), `edbm_extrude_ex` as the
`extrude_face_region` BMesh operator with the select history kept and a
clipping Mirror's plane edges left out, then Blender's own `rotate` and
`translate` operators; with nothing selected, a vertex at the cursor. Blender
shows no redo panel for it (the panel needs an exec,
`WM_operator_repeat_check`), so neither does the app; its step is Extrude to
Cursor or Add. Held to Blender's own invoke, run in desktop with a made event
through `WM_operator_name_call_with_properties` inside an operator (so nothing
registers a redo panel — the `ED_area_type_hud_ensure` crash class): 264 cases
(12 views, perspective and orthographic, 11 selections — a vertex, an edge, a
face, none, an edge loop, two vertices, a whole cube, a sphere's face, a moved
and scaled object, a clipped Mirror's half grid — Rotate Source on and off),
the same topology, selection and select history, positions within 3.5e-6 m.
Negative controls: the port with its side test turned round disagrees in 190,
Rotate Source the other way in 190.

**Rip.** Rip Vertices and Rip Vertices and Fill (`mesh.rip_move`) are shown
greyed with the reason: `mesh.rip` has no exec — which side tears away comes
from the pointer — and `rip_move` answered FINISHED with nothing changed
under the borrowed view (both, measured). **Rip Vertices and Extend**
(`rip_edge_move`) is built: `rip_edge`'s exec takes the ray its invoke makes
from the pointer (`location`, `direction`, hidden), so the row sends the ray
from the app's eye through Blender's 3D cursor
(`_blenderkit_meshmenu.pointer_ray`), under the borrowed 3D View its poll
wants, with Blender's Move X/Y/Z in its redo panel (the drag Blender's macro
makes; 0 is a click that does not drag). Against Blender's own `rip_edge`
invoke at the same pointer: 72 of 72 cases the same; different views ripped 4
selections along different edges; the ray through a mirrored point (the
negative control) disagrees in 45. Turning the ray round is no control: the
exec reads only its line. **Poly Build** stays greyed, its tooltip saying
what was measured: all five `polybuild_*` operators changed nothing under the
borrowed view (FINISHED or PASS_THROUGH) — "Not wired up yet — Blender can do
it" was not true. (October 20: all nine the search lists; the check now
measures the other four too, each PASS_THROUGH with nothing changed.)

**The simulator's stand-in** refuses each new row in words (its
`total_*_sel` reads, or a NotImplementedError naming the row); Merge's At
Cursor, At First and At Last used to weld by distance and answer FINISHED, and
Recalculate Normals had two definitions, the reachable one a no-op for Inside
too — Inside is refused in words now (tests/meshmenu/shim.py, 77 calls; 78
since October 20).

A finding about Blender, not the app: **Average ▸ Custom Normal's result is
not reproducible** in desktop 5.2.1. On the same 12 × 6 sphere, all selected,
154 (or 230) of 264 corner normals came out (0, 0, 1) instead of the averaged
ones in 4 to 6 of 40 tries whenever any Python line ran just before the call
(a `mode_set` to the mode Blender was in, a read of `total_vert_sel`,
`update_from_editmode`), and in 0 of 80 with nothing between two calls; with
custom normals already set, 0 to 3 of 40. The app's call is that call; the
check holds that row's mesh and selection to Blender's, not its normals. The
3D View draws vertex normals, so custom normals (all five Normals rows that
set them) show in a render and an export, not in Solid shading — as with
Shade Smooth and Flat before.

*Corrected October 20, after round 4's review of this entry: both findings
were wrong.* The variation was the check's fixture, not Blender:
`bmesh.ops.create_uvsphere` gives its faces in another order from one call to
the next once other meshes have come and gone (measured: 11 orders in 40
calls with BMeshes made and freed between, one in 30 with none), and the
corner normals were compared index by index. With the fixture's faces in an
order of their own, the same 40 calls after the same Python lines give one
result (four on the old fixture even compared corner by corner), and in none
of the 80 did more than 100 corners read (0, 0, 1). The row's custom normals
are held to Blender's now. And the 3D View draws Blender's face and corner
normals since October 20 (that day's entry), so Shade Flat, Smooth by Angle
and the Normals rows show in Solid shading.

In the app (5.3, `-object-ops` with the new tokens `py:<base64>`,
`cap:<base64>`, `cursor:x;y;z`, `extrude-cursor`; a cube rebuilt in Edit Mode
by a script per case, its selection and order set): Merge At Center 5/8/5 at
(0, 0, 1), the panel's Type to At Cursor put it at the cursor (0.5, 0.25, 2);
At First on two picked corners 7/10/5 at the first, the panel's At Last at the
second, Undo back to 8 with the order kept, Redo; At Last with no order
refused on the banner; Delete ▸ Vertices 7/9/3, Edges 8/11/4, Faces 8/12/5,
Only Edges & Faces 8/8/1, Only Faces 8/12/5, Only Faces on an edge refused;
Collapse 7/11/6; Edge Loops on a 7 × 7 grid 64 → 56 vertices, Face Split off
re-run; Connect Vertex Pairs 8/13/7, an edge's ends refused; Laplacian and
Repeat 5; Rotate Edge CW then CCW from the panel, different edges; Intersect
(Knife) 16 → 24, Source Self Intersect; Intersect (Boolean) and Union, Float
(17); Weld 16 → 17 faces, a cube refused; Convex Hull 12/23/13, Join
Triangles off, two vertices refused; Snap to Symmetry and its Threshold;
Recalculate Inside turned every face in, Inside off out again; Set from Faces,
Point to Target (and Spherize), Average Face Area (Weight 90), Custom Normal,
Smooth Vectors each left a custom normal layer; Extrude Manifold the top at
z = 1.2, the panel's Z −0.5 at 0.5, Undo (and again after the call stopped
sending the macro's own defaults, with a grid's face 25/40/16 → 29/48/20, as
in desktop); Rip Vertices and Extend 9/13/6 and
the panel's Move Z 0.5 moved the new vertex to (1, 1, 1.5), a whole cube
refused; Extrude to Cursor or Add on a vertex, an edge, a face and nothing
(9/13/6, 10/15/7, 12/20/10, and a vertex at exactly the cursor), Undo.
Blender's history read Extend Vertices, Extrude to Cursor or Add. The app's
results held to desktop: the port with the app's printed pointer within
7.1e-6 m (the log's five places) of what the app made; Blender's own invoke on
the pixel over the cursor 4 to 8 mm away (the cursor fell 0.4 px from a pixel
centre; on Blender's own ray the check above matches to 3.5e-6 m); Rip
Vertices and Extend at three cursors split the same edge as Blender's own
`rip_edge` there, two of them different edges. Every row's call also came
back through the borrowed view safely before it ran in the app; no crash in
the app or in desktop Blender from this group's runs.

Tests (counts as of October 19; October 20's entry has today's):
`scripts/run-meshmenu-tests.sh` (106: names, groups and order, the
calls, refusals, panels and hidden rows, the member vector and its negative,
the pointer's numbers, the rows that cannot run, the rows the search names),
`scripts/run-meshmenu-shim-tests.sh` (the stand-in, 77 calls and a negative
control) and `scripts/run-meshmenu-blender-check.sh` (160: every row against
Blender's own call, the refusals leaving the mesh as it was, every row from
Sculpt Mode, the two invokes and their negative controls, the rows that cannot
run measured). The names checks hold the new rows to Blender's menus (the
Vertex menu's three special rows, Normals ▸ Average, Limited Dissolve in both
menus); the redo check runs the new rows with order-carrying scenes for Merge
and the Weld, Connect and Extend scenes.

Not done: Rip Vertices and Rip Vertices and Fill (no exec; a port of
`edbm_rip_invoke`'s 1,100 lines was not attempted); the toolbar's Extrude to
Cursor, Rip Region and Rip Edge tools (a tap as the pointer); Normals ▸
Rotate, Merge, Split, Copy/Paste/Reset Vectors and the Face Strength menus;
Clean Up's Decimate Geometry, Degenerate Dissolve, Make Planar, Split
Non-Planar/Concave and its own Merge by Distance row; Average ▸ Custom
Normal's own nondeterminism (Blender's).

**October 19, later: the hand-over, checked and finished (round 4, group 6).**
The agent above was cut off before reporting; this pass read its whole diff
against the brief, rebuilt, re-ran its suites and the app, and added one
thing. *The Operator Search* refused Blender's pointer operators with "needs a
different selection or Blender editor context", which sends a reader looking
for a selection. Measured in desktop 5.2.1 from Edit Mode: all fourteen
(`dupli_extrude_cursor`, `rip`, `rip_move`, `rip_edge`, `rip_edge_move` and
nine `polybuild_*`) poll False with no context and with the search's window
and screen, True under a 3D View. `_blenderkit_sync._POINTER_OPERATORS` now
refuses them by name, before any mode switch, saying why and naming the row
that works toward the 3D cursor (Mesh ▸ Vertex ▸ Extrude to Cursor or Add, Rip
Vertices and Extend); the form shows the sentence and greys Run.
tests/opsearch/blender/verify.py holds every one of those polls (a Blender
that lets one run fails it), the sentence from Edit and Object Mode with the
mode left alone, and a negative control (without the table, the poll's
sentence); tests/meshmenu/main.swift holds the rows it names to the menu's
labels. run-opsearch-blender-check.sh's verify.py now gets a home of its own,
as its sweep always had. A DEBUG `-object-ops` token, `separate:<type>`, runs
Mesh ▸ Separate's rows.

Measured in the real app (Designed for iPad, this build, one launch, 235
tokens): 65 steps over every new row, each panel change above, Undo and Redo,
Split, Separate ▸ By Loose Parts and Extrude to Cursor or Add on a vertex, an
edge, a face, nothing and a sphere's face — each step's mesh, selection, select
history, face normals and custom normals held to desktop 5.2.1 running
Blender's own operator as its menu row calls it on the same fixture (the two
pointer rows: the app's own call, with the pointer the app printed): 65 of 65
the same, coordinates identical to the log's five places, the seven
refusals (At Last with no order, Only Faces on an edge, Connect Vertex Pairs
on an edge's ends, Weld on a cube, Convex Hull on two vertices, Extrude
Manifold with nothing, Extend on a whole cube) each on the banner with the
mesh as built. Panel titles were the operators' names (Merge, Delete, Vertex
Connect, Laplacian Smooth Vertices, Rotate Selected Edge, Extend Vertices, …),
Blender's history read Extrude to Cursor or Add and Separate. In two more
launches the search's form and Run refused `mesh.dupli_extrude_cursor` from
Edit Mode and `mesh.rip_edge_move` from Object Mode with the new sentences, the
mode unchanged. No crash in the app; desktop Blender crashed only in
opsearch verify.py's deliberate negative control (Multires Apply Base from Edit
Mode, `multires_reshape_create_subdiv`). Suites: meshmenu (106), meshmenu-shim,
symmetry, selectpick, redo, names, cuttools, transformops; Blender checks
meshmenu (160: Extrude to Cursor or Add 264 cases against Blender's own invoke,
worst 3.5e-6 m, negative controls 190 and 190; Rip Vertices and Extend 72 of
72, its control 45), opsearch (verify, and the sweep's 20,580 runs, none
crashed), names and redo.

## October 19: Collections, constraints, the Object menu's search-only rows, Local View (round 4, group 7)

Round 3's review (toolkit items 11, 12, 15 and 17) found the Outliner showing
one hard-coded "Collection" row, constraints reachable only as Add
Constraint by name with nothing to show or edit one, Mirror, Link/Transfer
Data, Make Single User, Copy Modifiers, Randomize Transform and Align Objects
reachable only through the Operator Search, and Local View unusable. Desktop
numbers below are Blender 5.2.1 with the app's context (its undo push,
`gpu.init()`, window and screen and no area, or the borrowed 3D View where
the app borrows it); "in the app" is the real iPad build with its bundled 5.3
bpy on this Mac, Designed for iPad, through the new `-relations-ops` hook.

**Collections.** The mirror reads the view layer's collection tree every pass
(`_blenderkit_collections.record`, `sync_record('collections', …)`, the C
entry point added for whole records) and the Outliner draws it
(`BKScene.outlinerTree`): the Scene Collection, its collections before its
objects, each object under every collection it is in, a child under its
parent when both are there, an excluded branch greyed. Each collection row
has the Exclude from View Layer checkbox, the eye (the view layer's Hide in
Viewport), the arrow (Disable Selection), the camera (Disable in Renders),
a tap that makes it Blender's active collection (where new objects go; no
undo step, as an object tap makes none), a double-tap rename ("Rename",
ended by Return or by the field losing focus, as Blender's is — the
constraint name field too, `NameDraft`'s rule), and
New Collection, Delete and Delete Hierarchy (also the header's New
Collection). The toggles' steps are the properties' names. Properties ▸
Object ▸ Relations ▸ Collection lists the collections the object is in, and
the viewport's text reads "(frame) *active collection* | *object*" (it said
"(1) Collection"). Object ▸ Collection has Move to Collection (M) and Link to
Collection (Shift+M) as Blender draws them: New Collection, the Scene
Collection, then its collections, a collection with children a submenu; New
Collection asks for the name Blender proposes (`BKE_collection_new_name_get`)
in "Move to New Collection" / "Link to New Collection" with Create. Measured:
`move_to_collection` and `link_to_collection` run headless once
`collection_uid` (the `session_uid`) is set — without it Blender says "No
collection selected", what the search hit, since the field is hidden in its
form (the check still holds that); with nothing selected both answer
FINISHED having moved nothing, refused first; linking an object to a
collection it is in is Blender's own "Cube already in Parts". The Outliner's
own New, Delete and Delete Hierarchy poll False with no Outliner (their tree
is built at draw time), so they are `BKE_collection_add` and
`BKE_collection_delete` written with the data API: Delete relinks the
children and objects into every parent first, Delete Hierarchy frees objects
no other collection holds. Excluding or deleting the collection of an object
in Edit Mode left it at mode EDIT with no edit object and `mode_set` failing
("Context missing active object"), so those are refused while any object they
take out of the view layer is in another mode; the eye is allowed (Blender
leaves the object hidden in Edit Mode). Blender check: the tree, every toggle
on two collections with the property read back, Select All skipping a
collection with selection disabled, an excluded collection's objects leaving
`view_layer.objects`, New's names (with `.001` when taken), Delete's
relinking (control: the data API's remove alone loses the child collection),
Delete Hierarchy, the refusals, each step's name against Blender's own call
with its undo on.

**The Object Constraints tab** (Properties ▸ Constraints, `ConstraintsPanel`):
Add Object Constraint in Blender's four columns with the 27 types the object
operator takes (Inverse Kinematics and Spline IK are a bone's: 'enum "IK" not
found'), then each constraint as Blender's panel draws it: the name, Enabled,
the menu (Apply, Duplicate, Copy to Selected, Move to First, Move to Last),
Move Constraint Up and Down, Delete Constraint; rows for Copy Location, Copy
Rotation, Copy Scale, Copy Transforms, Track To, Damped Track, Limit
Location, Limit Rotation, Limit Scale, Child Of (Set Inverse, Clear Inverse)
and Follow Path (Animate Path), each field by its panel text with the enum
items read from the running Blender; Influence; any other type opens on its
Data API path. Every control is Blender's operator (`constraint_add`,
`constraint.delete`, `move_up`/`move_down`/`move_to_index`, `apply`, `copy`,
`copy_to_selected`, `childof_set_inverse`/`_clear_inverse`,
`followpath_path_animate`, all headless with `constraint=<name>,
owner='OBJECT'` on the active object) or a property write
(`_blenderkit_constraints`), and the tab shows the record read back.
Spaces offer World and Local: an object's spaces are World, Custom and Local
only ('POSE' refused), and Custom needs an object of its own. Object ▸
Constraints has Add Constraint (with Targets), Copy Constraints to Selected
Objects and Clear Object Constraints. The viewport draws the evaluated
matrix (it always mirrored `matrix_world`); measured, a cube with Copy
Location from a sphere at (3, 0, 0) at (3, 0, 0), at Influence 0.5 at
(1.5, 0, 0), disabled at the origin, with its `location` (0, 0, 0)
throughout. **A drag of something a constraint decides** is previewed by
Blender (`_blenderkit_constraints.drag_frame`): each frame the channels go
back, the release's own call runs, and the viewport gets Blender's evaluated
matrices through the frame-change path (`anim_frame`); the channels go back
before the commit runs once as its step. Previewed from the channels, a cube
on Copy Location slid 1 m off its target and jumped back on release. Desktop:
the frame equal to the committed drag to 1e-6, the cube following a dragged
target, no step pushed by the frames. The Transform fields (Properties ▸
Object and the Sidebar's Item tab) preview the same way, by the very
assignments their commit sends: round 3's open "the preview ignores
constraints".

**The Object menu's rows** (More and the menu bar's Object menu, Blender's
places and labels, `ObjectMenuRows.swift`, each through `perform` with
Blender's redo panel): Transform ▸ Randomize Transform and Align Objects;
Mirror ▸ X/Y/Z Global and Local (`transform.mirror` with Orientation and the
Constraint Axis toggles — a new `Parameter.Kind.toggle` composes the boolean
vector, `constraint_axis=(True, False, False)`; Interactive Mirror greyed, it
waits for an axis key); Relations ▸ Make Single User's six rows (its panel's
Type and five switches); Modifiers ▸ Copy Modifiers to Selected Objects;
Link/Transfer Data's eleven `make_links_data` types and Copy UV Maps. Each
refuses in words where Blender answers FINISHED having done nothing (nothing
selected, only the active selected, a stack to copy that is empty) or fails
its poll (no active object). Measured on a cube turned 0.7 rad: X Global
scale (-1, 1, 1) rotation -0.7, X Local rotation 0.7; every row held to
Blender's own call on the same fixture; the steps are the operators' names.

**Local View** (More ▸ Local View and the menu bar's View, Toggle Local View
on /, Remove from Local View). `view3d.localview` and
`localview_remove_from` run under the borrowed 3D View, whose Local View is
the one the app shows: each pass reads which objects it holds
(`_blenderkit_localview.state`) and sends the others as not drawn
(`|notlocal`, not greyed in the Outliner, as Blender's is not). Entering
frames the objects with Blender's own rule (`LocalViewFraming`: the box's
largest side × 1.4 to fit the narrower side; 3.2081 for a 2 m cube in the
borrowed 1574 × 954 region, matched by the check) on the app's camera,
leaving camera view; leaving puts back the view it was entered from.
Measured: entering without an undo step and undoing the next change left
Local View (`view3d_data_consistency_ensure` clears a Local View no object
carries), so both are steps of their operators' names, as Blender's history
has them — then an Undo of a later change stays in Local View and an Undo of
Local View's own step leaves it, as in Blender. Under the view
`select_all` took only Local View's objects and without it all four, so
Object Mode's All and Invert run under the view there; deleting the last
object in Local View leaves it, as Blender's next redraw does
(`ED_localview_exit_if_empty`); an add from the app's menus joins Local View
as Blender's Add from its view does (`include_active`; `local_view_set`
reads back after an evaluation), while a script's add stays outside, as in
Blender. From Edit Mode and Sculpt Mode the toggle takes the object being
edited (measured, both ways); Remove from Local View is refused in Edit Mode,
where Blender's poll fails.

Tests: `scripts/run-relations-tests.sh` (100: the collection record with
separators in names and its control, the tree, folding, search, the
stand-in's fallback, Local View's record and framing with the fitting-side
control, the constraint record, the merge, the commands' calls, bodies and
steps, the rows' Python and panels) and `scripts/run-relations-blender-check.sh`
(607 in Blender — every command above against Blender's own operator or
RNA, each refusal leaving the scene as it was, the controls — and 1,728 in
the Swift replaying 57 mirroring passes: tree, active collection, Local View,
drawn state, Relations ▸ Collection, constraints and the drawn matrix each
Blender's, with three controls that drop a record and fail). The names
checks hold every new row to Blender's menus (Mirror's from space_view3d.py)
and each title and step to its operator's name (400 and 556).

In the app (four launches, a fixture script, 193 tokens; after each the hook
printed selection, Local View, the active collection and every object's
place, x scale, determinant, collections and constraints as the app showed
them beside Blender's): 0 mismatches. New Collection made "Collection 2",
rename Props, Move to Props and Link to Parts, the four toggles on Parts,
Select All with Parts' selection disabled (Cone and Ring left out), Exclude
(Cone and Ring not drawn, greyed), Move to New Collection (the prompt
proposed "Collection 2", Blender's rule) with Undo and Redo, Delete
(Sphere relinked into the Scene Collection), the active collection, and the
three refusals on the banner; the Outliner sheet's accessibility tree listed
Scene Collection, Collection (active), Parts and Props with their toggles.
Constraints: Copy Location to the Sphere drew the cube at (3, 0, 0), 0.5 at
(1.5, 0, 0), off at the origin; Limit Location max X 1 at (1, 0, 0), moved
above Copy Location at (3, 0, 0); Child Of's Clear and Set Inverse (1, 4, 0)
and (1, 1, 0); Track To, Follow Path on the circle, Animate Path, Move to
First, Undo and Redo; a self-target refused; the tab's accessibility tree
showed Add Object Constraint, each panel's Name, Enabled, Target, Track Axis
-Z, Influence, and Armature's Data API row. A gizmo Move of 1 in Z on the
constrained cube: preview against Blender 0.00 m; with
`constrained-preview:off` (the old preview, the control) 1.00 m; dragging
the target Sphere, the cube followed in the preview, 0.00. A fifth launch,
`-object-ops field:` on a cube with Copy Location and Limit Location (max
Z 0.5): its Location Z field to 1 previewed 0.000 m from where Blender put
it, (3, 0, 0); the control 1.000 m; the Sphere's Y and Z fields with the
cube following and clamped, 0.000 m over both. Rows: Mirror X
Global (both selected, determinant -1), the panel's Y (+1, positions
mirrored), Z Local; Link Object Data, Make Single User, Copy Modifiers,
Randomize with the panel's Location X 2 and seed 5 (Cube to x 0.334 then
0.596), Align with X, Add Constraint (with Targets) with Copy Rotation, Copy
and Clear Constraints, Copy UV Maps (Blender's own warning on the banner:
face counts differ), and the refusals. Local View: Cube and Sphere alone
drawn, the camera from (0.75, -2, 0) at 27.81 to (1.25, 0.25, 1.25) at 8.75
(the rule with the app's lens and the 1194 × 730 view), Select All in it
selecting Cube alone where outside it selected all four, Remove from Local
View (Sphere out and deselected), Undo and Redo, leaving restored the camera
exactly; Add ▸ Monkey in Local View drawn there, its redo panel, Undo, Redo;
nothing selected refused. No crash in the app or in desktop Blender from
this group's runs (the 10:30 desktop report today is opsearch's deliberate
Multires Apply Base control, before this group's first run).

Two of round 3's open Low defects are closed with these: Relations ▸
Collection's hard-coded label, and the Transform fields' preview ignoring
constraints. Suites run: relations (100), its Blender check (607 + 1,728),
names (400, 556), mirror (127; its 5 ms timing check failed twice at a load
average over 150 — 7.16 and 5.59 ms — and passed idle, 2.76 ms; nothing here
touches that path), mirror Blender check (144), redo (176) and its Blender
check (751), objectops (96, 373), transformops (68), meshmenu (107), undo
Blender check (95), opsearch Blender check (55), 3dview Blender check (396).

Not done: the Outliner's drag and drop, Collection properties, Holdout and
Indirect Only, Duplicate and Instance Collection, collection colour tags, and
Object ▸ Collection's other five rows; constraints' Custom Space and
sub-targets (bones, vertex groups), Disable and Keep Transform (its poll needs
a constraint in the context: "context is incorrect"), drag reordering, bone
constraints and Object ▸ Track; Interactive Mirror, Link Objects to Scene
(one scene: Blender's "Cannot link objects into the same scene"), Transfer
Mesh Data and the light-linking rows; Local Collections. The app's other 3D
Views (Sculpting, Shading) share the one borrowed Local View.

## October 19: Every modifier in Add Modifier, text objects, reference images (round 4, group 8)

Round 3's review (toolkit items 7, 13 and 18) found eleven modifiers reachable
only through the Operator Search and Every Property, Edit Mode on a text
object refused with no other way to change its text, and image empties drawn
as a frame ("The picture itself is not drawn"). Desktop numbers below are
Blender 5.2.1 with the app's context (its undo push, `gpu.init()`, the window
and screen with no area, or the borrowed 3D View where the app borrows it);
"in the app" is the real iPad build with its bundled bpy on this Mac,
Designed for iPad.

**Add Modifier is Blender's menu** (`ModifierCatalog`, ModifierFields.swift):
for each object type the categories and rows Blender's own `draw()` makes
(properties_data_modifier.py), in its order and words — Edit 8, Generate 21,
Deform 16, Normals 2, Physics 9 and Geometry Nodes on a mesh; a curve's or a
text's without Normals; a lattice's Edit, Deform and Physics. Generate's three
Essentials node groups (Array, Curve to Tube, Scatter on Surface) are greyed
without Blender's asset library, which the device's bpy does not ship, and
say so when run (`_blenderkit_modifiers.add_asset`); the legacy Array is
"Array (Legacy)", as 5.2's menu has it. Every row's add is priced by the
vertex budget first (`Bpy.addModifierRow`, `_blenderkit_multires.check_add`).
A kind with no rows of its own still opens its Data API row.

**Eleven kinds have rows**: Curve (a picker of curves only — measured,
Blender leaves `CurveModifier.object` as it was for a mesh or a text, and
raises for the object itself — and Deform Axis), Wireframe, Skin (with Create
Armature, and Mark Loose, Clear Loose, Mark Root and Equalize Radii in Edit
Mode), Hook (any object but its own, Strength, Falloff, and Reset, Recenter,
Select and Assign in Edit Mode: they fail their poll elsewhere, even with the
modifier in the context, and with no vertices assigned a Hook moves nothing),
Armature (armatures only), Surface Deform and Mesh Deform (target, Bind and
Unbind), Data Transfer (Source, Object Transform, Mix Mode, Mix Factor, the
four data panels with their types and Mapping, Generate Data Layers), Normal
Edit, Mask and Build. They are declared (`ModifierKind.fields`, labels from
MOD_*.cc `panel_draw`, items from RNA) and keep their settings as the text
Blender's record sent (`Modifier.values`), so a row shows only what Blender
holds and an edit sends one assignment (`Bpy.declaredSettings`). The record
(`_blenderkit_sync._MODIFIER_FIELDS`, `_MODIFIER_POINTERS`) carries each
setting, enum sets joined, the other object by name, a Hook's vertex count
and a Bind's state. The simulator's stand-in takes them all but Curve (it
keeps a Curve modifier of its own). Measured: Curve bent the cube's X range
from [-1, 1] to [-2.47, 0.15]; Data Transfer's Mix Mode is Blender's one
dynamic list (Replace alone with no data type, all seven with Vertex Groups),
which the row follows; Bind is a toggle that binds at the next evaluation, so
it runs in Object Mode and is refused while the modifier is hidden (Blender
answered FINISHED and bound nothing); Mesh Deform bound a cube in a cage at
Precision 2–4 in 0.00–0.03 s, at 5 in 3.2 s, and at 6 had not finished after
two minutes — 6 and above are refused.

**The budget for what makes geometry.** `stack_vertices` now counts Wireframe
(2(V+E) vertices, exact on a cube, a UV sphere, a grid with Boundary and
Suzanne), Screw (steps × iterations, exact), Ocean (Generate's
(rx·r²+1)(ry·r²+1) grid, exact at r 1–12 and repeat 3 × 2) and Skin (an upper
estimate, 48 per vertex: measured 4 to 42). Skin is also refused on more than
600 independent loops of edges, for time: a 20,000-edge chain took 0.04 s, a
30 × 30 grid (900 loops) 18.3 s. `check_setting` prices Wireframe's Replace
Original, Screw's Steps, Ocean's resolutions and repeats, and Show in
Viewport turned on (a hidden Subdivision at level 7 on a sphere is refused).
Round 4's review found six holes in this budget; they are closed below
("Round 4's review of group 8").

**Text** (Properties ▸ Data, `TextDataPanels`): Body Text, then Shape,
Geometry, Bevel, Transform, Alignment and Spacing with Blender's words.
Blender's Edit Mode on a text keeps its typing in a buffer no Python can read:
measured, `font.text_insert` works headless, but `data.body` and the evaluated
copy's both return the text from before Edit Mode, and a body set during Edit
Mode is overwritten on leaving (rna_curve.cc: "TODO: how to handle
editmode?"). So the body is typed into the Body Text field and written to
`data.body` in Object Mode when the edit ends (`_blenderkit_text.set_body`,
undo "Body Text"), and Tab on a text object opens that field instead of
refusing; Edit Mode from a script is refused with a sentence. The body and
the rows that add geometry are priced — first by an estimate calibrated on the
vertices the app drew, which other letters beat (round 4's review), now from
the letters' own outlines (below); Blender's 8,192-byte body limit is refused
in words. The viewport draws Blender's evaluated text, as before.

**Reference images**: Add ▸ Image ▸ Reference..., Background... (Photos or
Files) and Empty Image. `object.empty_image_add` polls for a 3D View region,
so it runs under the borrowed view (`_blenderkit_images.add`), in Object Mode
only, facing the app's view; Background takes Blender's Back depth and Front
side, and from an orthographic app view hides itself in perspective, as
Blender's operator decides from the view. The picture is packed into the
.blend. The empty's Data tab has Blender's Empty and Image panels. The
viewport draws the picture (`ImageEmptyDraw`, `ImageEmptyPass`) as
overlay_empty.hh and overlay_image_*.glsl do: tinted by the object colour;
Default without Opacity depth-tested and alpha-tested at 5%, with Opacity
blended back to front, Back behind everything and the grid, Front and In
Front over everything; nothing in a view its Show In switches hide it from,
nothing from behind with Side Front (or in front with Back), nothing off-axis
with Only Axis Aligned, nothing with Opacity on at 0
(`BKE_object_empty_image_*_is_visible_in_view3d`, copied rule for rule).

Tests: `scripts/run-modkinds-tests.sh` (host: the catalog by type, every
declared row's record, lines and one-line edits, the buttons, the budget's
lines, text and image records, the visibility rules and passes, each with a
control), `scripts/run-modkinds-shim-tests.sh` (88: the simulator's stand-in
taking every line the ten rows it models send, its table held to the Swift's
declared fields read out of ModifierFields.swift) and
`scripts/run-modkinds-blender-check.sh` (908 in Blender over two
runs: the catalog against Blender's menus drawn for thirteen object types,
every row added on a mesh, curve, text, surface and lattice and read by the
pass, the counts against `to_mesh()`, the refusals, every declared field
against RNA, 66 edits built from Blender's record and replayed, the buttons,
the Vertex Group field changing each kind's result and Invert changing it
again, the text and the pictures). Its first version missed that a second
`_POINTER_FIELDS` later in _blenderkit_sync.py emptied the new pointer
table — the app showed no picked object — so the Swift now fails any setting
Blender's record leaves out. The modifier tests' examples of kinds with no rows
moved to Warp and Laplacian Deform; the groups tests count 22 kinds with a
Vertex Group field, and the groups Blender check leaves the six that act only
with their other object, and Normal Edit (normals only), to the modkinds
check, which sets each up.

In the app (DEBUG hooks `-modifier-steps`, now taking any row by type and
`@select=`, and the new `-textimage-ops`): on a 30 × 30 grid Skin was refused
in words (900 loops) and Wireframe added; on a cube Curve, Wireframe, Skin,
Hook, Surface Deform (bound, unbound, bound), Mesh Deform (Precision 6
refused, 3 bound), Data Transfer (Source, Vertex Groups, Generate Data Layers,
Mix), Normal Edit, Mask, Build, Armature, Warp and Ocean added and edited,
the Essentials Array refused; Hook Assign refused in Object Mode and taking
all eight in Edit Mode; Skin's Create Armature; Curve applied. Desktop
Blender reading the autosaves held each value the rows showed, the cube's X
range [-2.473, 0.147], both binds and the generated "Top" group. A text:
body "Hello\nWorld", Extrude, Horizontal Center, Bevel Depth (461, 1,844,
6,454 vertices drawn, Blender's), Tab opening Body Text with Blender in Object
Mode, Undo and Redo; Blender's steps Add Text, Body Text, Extrude, Horizontal,
Depth. A 64 × 32 picture added in the front view: the frame captured from the
3D View's own pass (`capture:`) red and blue where the picture's halves are
(the control, overlays off: the cube's grey); Opacity 0.5 blended (171, 44,
46); Back behind the cube (the cube's grey) and the grid; Front over it; Side
Front hidden from behind; Only Axis Aligned hidden at 20°; Perspective off
hidden in perspective; Background from the orthographic view Back, Front side,
hidden in perspective; Undo and Redo of its add. Desktop Blender read both
pictures packed, at 90° facing the view, Size 5.

No crash in the app or in desktop Blender from this group's runs.

Not done: the Hook's Bone and the
falloff curve, Ocean's other settings and the physics modifiers beyond their
Data API rows; Essentials node groups on device; picking an image empty by
its picture (its frame picks); stereo images and image sequences; text
styles (bold, italic) and text boxes; Blender's typing Edit Mode itself.

### Round 4's review of group 8 (October 20)

The review found the budget beaten six ways, the empty body lost, Photos'
pictures unreadable by Blender and drawn turned, every picture decoded whole,
and the Mesh Plane row missing for a reason that was not true. Desktop
numbers are 5.2.1 with the app's context (its undo push, `gpu.init()`, the
borrowed 3D View where the app borrows it); "in the app" is the real iPad
build on this Mac, Designed for iPad.

**The text's price is Blender's own layout** (`_blenderkit_text.vertices`).
The old estimate scaled what the text made now by its number of letters, so
other letters beat it: "I" at Resolution U 64 and Bevel Resolution 32 is 276
vertices, and 1,000 "O" priced at 276,000 against 35,328,000. Measured: a
text's vertices are its letters' outline points — a Bézier segment between
two Vector handles is one point, every other one Resolution U points
(`Object.to_curve` lays the text out without building a mesh; 8,000 "O" in
0.03 s) — times a number Extrude, Bevel and Fill Mode decide, the same for
every letter (1 flat; with Extrude 2, 3 or 4 by Fill Mode; with a Bevel 2b + 4,
b + 3, 2b + 5, or with Extrude 4b + 6, b + 4, 2b + 6), which Blender is asked
for by building one letter at Resolution U 1, so Profile and Object bevels
are counted too. A negative Bevel Depth bevels as a positive one (the old
estimate priced it flat, 1,050 against 22,050). Fill Mode is priced (None to
Both with Extrude doubles the text). Geometry ▸ Offset makes outlines cross
themselves and the fill adds a vertex at each crossing ("*" at Resolution U 3
and Offset 10: 238 against an outline of 66), so with an Offset each letter
is built once, flat, and what its fill added is counted for each time it
occurs. Measured exact for 5 bodies × 2 resolutions × 8 settings priced from
another text, every ASCII letter at four resolutions and ten Offsets (3,960
cases, none under), and with an Offset never under and at most 0.8% over. A
text with modifiers is priced through its stack, and the Data API row on a
text's data is priced as the Data tab is. In the app: "I" at 64/32 drew 276;
1,000 "O" refused at 35,328,000 with Blender keeping "I"; ten "O" drew
353,280, Blender's count; Bevel Depth -0.02 on 1,000 flat letters refused at
37,025,400; the Data API row's Bevel Depth on 100 "O" at Resolution U 1024
refused at 10,649,600.

**Texts, curves and surfaces are in the budget** (`_blenderkit_multires.
base_counts`): what Blender makes of them before their modifiers — measured
equal to their own `to_mesh()` outside the depsgraph, which leaves an Object
bevel out (4 against 192), so with a Bevel Object the stand-in is evaluated in
the scene and taken out again. In the app, on a text "Hello": two Arrays at
Count 64 passed (1,761,280, Blender's), the third was refused at 56,360,960,
and a Subdivision Surface after them at 6,922,240; desktop: a bevelled curve's
Subdivision level 6 and a NURBS sphere's Array 4,000 refused.

**Ocean, Screw and Edge Split.** An Ocean simulates (r²)² points whatever it
builds — 91 bytes a point, 171 with Normals, Foam and Spray (measured: +30 MB
at Resolution 24, +95 MB at 32) — so its resolutions are refused past
2,500,000 points in Displace mode too, and Geometry Generate is priced (the
review's Repeat 200 × 200, 96,059,601 vertices). Screw's Iterations is priced
(10,000 on a UV sphere, 77,120,482), and the Screw row's Steps stepper now
sends the price its Subdivision twin sends (512 on a 100 × 100 grid refused,
in the app 5,222,912). Edge Split is priced at most what every corner split
makes (measured never above it, exact at Split Angle 0; an 800 × 800 grid's
2,560,000 corners refused).

**Skin's loop cap holds after the add** (`refuse_slow_skin`): every priced
change asks — a setting, Show in Viewport, Multires Subdivide, Subdivision
Set, and Move Up or Down. In the app: with Skin under a level-1 Subdivision,
level 2 passed (95 loops) and level 4 (1,535) was refused. A move is priced
before Blender makes it (`check_move`). The first version priced it after
and put it back: `bpy.ops` evaluates the view layer once an operator
finishes, and in the app the refused Move Up of a level-4 Subdivision above
a Skin froze it for over a minute at 100% CPU before the refusal showed (in
desktop Blender the bare move took 44.1 s). Priced first, it was refused in
0.00 s in desktop Blender and at once in the app, Blender's order untouched;
at level 1 the move went through.

**A cleared body is an empty body.** `ObjectDataSettings.parse` dropped the
empty `body=`, so the Data tab lost its text panels and the Body Text sheet
said the text "has not arrived yet". In the app: the body cleared, the Data
tab kept its rows, Tab opened Body Text, Undo brought the text back.

**What Blender is handed for a picture** (`ReferenceImages.prepare`, which the
pickers and the hook both go through). Blender reads no HEIC (0 × 0), ignores
a JPEG's EXIF orientation and an embedded colour profile, and decodes a
picture whole when its size is asked for (a 6,000 × 6,000 PNG of 486 KB:
+212 MB resident). So a PNG or JPEG goes as it is only when it is upright,
sRGB, 8-bit and at most 4,096 on a side; anything else is turned the way
Photos shows it, scaled, converted to sRGB at 8 bits and written as a PNG or
a JPEG. `_blenderkit_images.add` refuses what is not a PNG or JPEG, or would
decode past 4,096 × 4,096 at 8 bits (a 16-bit PNG decodes to floats), and the
record reads the size from the file's header (`picture_size`; Blender decoded
nothing, `has_data` stayed False). The viewport draws the file as Blender
reads it, its EXIF tag and profile ignored (`ReferenceImages.viewportImage`),
and decodes no picture past 8,192 × 8,192 for its texture. In the app,
through `-textimage-ops`: a HEIC added as a JPEG Blender read at 64 × 32,
its four quarters captured where they are stored; a JPEG tagged to turn a
quarter added at 32 × 64, Blender's size, its quarters captured as Photos
shows them; a 6,000 × 6,000 PNG added at 4,096 × 4,096. Desktop Blender read
the autosave: the picture packed at 4,096 × 4,096.

**Mesh Plane...** is back in Add ▸ Image: `image.import_as_mesh_planes` is a
core operator (bl_operators/image_as_planes.py, in the bundled bpy too), not
an add-on's importer. Measured: it polls with the window and screen alone,
adds a plane sized to the picture at the 3D cursor, facing the scene camera's
main axis (+Z without one), with a material whose Image Texture is the
picture, which is packed. Undo step "Import Images as Planes". In the app a
64 × 32 PNG made a 4-vertex plane; desktop Blender read it from the autosave
at 2 × 1 with its texture packed.

Also: Edit Mode's refusal names only what rebuilds the mesh (a Hook beside a
Subdivision is no longer said to); the text rows take Blender's ranges
(Offset X and Y, Offset and Depth to ±FLT_MAX, Extrude to FLT_MAX); in the
simulator the eleven rows whose kinds its stand-in draws the mesh without say
so.

Tests: modkinds host 284, from 241 (a cleared body, Blender's ranges, the Screw row's
price, the move priced first, the stand-in's eleven held to `ModifierStack`,
the refusal's names, and pictures made with ImageIO as a device makes them —
HEIC, an EXIF-turned JPEG, 16-bit, 6,000 × 3,000, Display P3 — converted and
drawn, each with a control; six of them fail with their fix taken out);
modkinds Blender check 982, from 908 (the review's cases run with the rows' own lines,
Blender reading each converted picture, the header against Blender's size,
Mesh Plane, each with a control).

No crash in the app or in desktop Blender. One freeze, the move above, now
guarded.

Not done: the Skin's Edit Mode buttons act on Blender's selection, which the
app refuses to make while the Skin is shown (hide it first); Opacity's
blending space against Blender's overlay is unmeasured; an image of a format
other than PNG or JPEG that Blender holds from an opened file is still sized
by Blender, which decodes it.

## October 19: The Cursor tool, Measure, and Edit Mode's measurements (round 4, group 9)

Round 3's review (toolkit items 10 and 16) found no way to place the 3D
cursor by tapping (`view3d.cursor3d` answers PASS_THROUGH without a window)
and no ruler (`view3d.ruler_add` fails its poll even under the borrowed 3D
View). The toolbar's Cursor and Measure were greyed. Both work now, and so do
Blender's Statistics overlay and Edit Mode's Measurement overlays. Desktop
numbers are 5.2.1 with the app's context (its undo push, `gpu.init()`, the
borrowed 3D View aimed as the app looks); "in the app" is the real iPad build
with its bundled 5.3 bpy, run on this Mac as Designed for iPad through the new
DEBUG hook `-measure-ops`.

**The Cursor tool.** A tap is Blender's click, ported:
`_blenderkit_cursor.place` is `ED_view3d_cursor3d_update` with
`ED_view3d_cursor3d_position` and `_position_rotation` line for line
(view3d_edit.cc). Its two settings are Blender's own, read from and written
to the workspace tool Blender keeps for the mode (`WorkSpaceTool.
operator_properties('view3d.cursor3d')`, per mode as Blender's are): Surface
Project and Orientation (None, View, Transform, Geometry), on the Cursor's
bar, shown as read back every pass (`cursor` record). What only a drawn 3D
View has, the app works out on the mirror, which is Blender's evaluated mesh as
the 3D View draws it (`CursorTool`): Surface Project's depth as
`ED_view3d_autodist` reads its depth buffer — the pixel, then Blender's 2m-
pixel rectangles at margins 2 and 4 (`BLI_rcti_init_pt_radius`, one more
pixel left and below than right and above) — and Geometry's face as
`snap_object_project_view3d_ex` finds it: the nearest triangle, two-sided, its
normal the object-space triangle's through the inverse transpose
(`register_result_raycast`), objects drawn as wire or bounds passed through.
In empty space the cursor goes to its own depth (to the view's centre when it
is behind the eye, `ED_view3d_calc_zfac_ex`'s flip). The rotation is written
as `View3DCursor::set_rotation` writes it in each rotation mode, compatible
with the one before, and Axis Angle in a numpad view as the special case
`ED_view3d_cursor3d_update` makes. No undo step: `VIEW3D_OT_cursor3d` has
none, and Blender's undo keeps the cursor where it is (`scene_undo_preserve`).
`scene.ray_cast` was no stand-in: in Edit Mode under a Subdivision Surface it
met the edit mesh (y = −0.5 where the drawn surface is at −0.15) and faces
Edit Mode hides.

A drag is the tool's `transform.translate(cursor_transform=True)` — Blender's
Cursor drag is that operator — run headless with the value the preview
showed, as the step Move: a Pencil's or a pointer's press places the cursor
first, as Blender's press does; a finger's drag moves the cursor only from on
it (elsewhere it orbits). It snaps as Blender's translate does, to the header's
Snap Target elements while Snap is on, Ctrl inverting it (GeometrySnap).

Measured against Blender's own Cursor tool (`scripts/run-measure-blender-check.sh`):
`view3d.cursor3d`'s invoke run with a made event (as the meshmenu check runs
`dupli_extrude_cursor`) at pixels of five fixtures (a turned cube beside a
sphere, a mirrored one, one behind a wire-drawn sphere, Edit Mode under a
Subdivision Surface, a grid with hidden faces) in four views (two
perspectives, a user orthographic, Front), both Surface Projects, every
Orientation, four rotation modes, the cursor in front and behind: 4,272 clicks.
One finding about headless Blender came first: it draws a 3D View's depth
buffer for the first Surface Project click only — `ED_view3d_depth_override`
sets V3D_RUNTIME_DEPTHBUF_OVERRIDDEN, which only the region's own draw clears
— so every later click read a stale buffer (after a sphere in front was
turned from Wire to Solid, the next click still landed on the cube; in an
orthographic view the cursor went to the far clip, 498.9 m out). The check
finds that flag in the View3D's memory and clears it before each click. Then:
of the 4,146 clicks the app makes a call for, 4,139 put the cursor where
Blender's own tool did — within 5.0e-4 m in the view's plane (Blender's own
line is that noisy: `ED_view3d_win_to_vector` subtracts the eye from a point
1.3 cm before it, so points are held to 1e-4 of their distance from the eye),
1.05e-3 m from the depth buffer (its float), 6.2e-4 m on a face Geometry
snapped to — rotations within 8.3e-7 (an Axis Angle at nought compared as
the rotation it is: 2π from Blender and 0 here, settled by float noise in a
cross product's sign). The other 7 are clicks whose ray passes within a pixel
of a vertex, where the two ray-triangle tests settle the tie differently,
counted apart; 126 Geometry clicks on the subdivided edit mesh are refused by
the app (below). Negative controls:
the world cross product's normal 128 of 680 disagree, the X roll to the wrong
axis 226 of 680, the flip left out 349 of 530.

**Geometry under a modifier that rebuilds the edit mesh** is refused in words
(`CursorTool.geometryRefusal`, `editRegionRefusal`'s sentence): Blender's
snap in Edit Mode casts at the edit mesh where the final mesh is its BMesh
wrapper — as under a GPU-subdivided Subdivision Surface — and turned the cursor
to the cage's face, 0.20 to 0.67 m (56 pixels) from the surface the mirror holds. Surface
Project and the other orientations read the drawn surface, as Blender's depth
buffer does, and still place.

**The checkpoint history keeps the cursor too.** Where Blender's undo cannot
be used, an Undo is a file load, which took the cursor back with everything
else: measured, Blender's own undo left it at (7, 8, 9) and the checkpoint
history put it back to (0, 0, 0). `_blenderkit_undo._load` now keeps the
cursor in hand across the load, as `scene_undo_preserve` does (the measure
check: kept, and without it, the control, taken back).

**Measure.** The rulers are the app's overlay, built as Blender's ruler gizmo
behaves (view3d_gizmo_ruler.cc), since `ruler_add` cannot run: a drag makes a
ruler, a drag from an end moves it, a drag from a ruler's line puts an angle
point there (an angle ruler's arms take nothing, as Blender's return −1), a
tap on a point makes the ruler active, Ruler Remove (the bar, X and Delete)
takes it away. A point lands where Blender's would: in the view's plane through
where the drag started (a new ruler's first point and an angle point at the
world origin's depth — Blender's zeroed `drag_start_co`), or, while snapping
is on — the header's Snap, Ctrl inverting it, as `ED_gizmotypes_snap_3d_
is_enabled` reads it — on what Blender's snap cursor finds within 12 points
with `snap_elements_tool`'s elements (Geometry: vertices, edges, faces, their
centres), and where it finds nothing on the plane through the 3D cursor facing
Z (`v3d_cursor_snap_update`'s placement plane; the view's own plane for an
orthographic view along it). In Edit Mode a rebuilt edit mesh is left out of
the snap, the bar saying why: Blender's ruler snaps to the cage there. Its
text is `ruler_item_as_string`'s, through `BlenderUnits` — a port of
`BKE_unit_value_as_string(_scaled)`: no Python API reaches it
(`bpy.utils.units.to_string` ignores the scene's Length unit: 0.02 m is
"0.02 m" from Blender's C and "2 cm" from it). It changes nothing in the
scene and pushes no step (Blender pushes "Ruler Add" because it writes
annotation strokes on leaving the tool; these are kept in the app's scene
until removed, drawn while the tool is in hand).

Measured: 1,335 unit strings — 15 settings (Metric, Imperial, None; Degrees
and Radians; scales 0.01 to 1000; Adaptive and each Length unit; Separate
Units), lengths, areas and angles at precisions 2, 3 and 6 — every one
Blender's own C function's, called through ctypes (the control: `to_string`
disagrees on 30). The port first had nanometres and picometres, which unit.cc
leaves under `#if 0`; the check caught it. 699 ruler points on the fixtures'
mirrors, each where Blender's geometry and view put it: on a vertex, an edge,
one of Blender's own edges' midpoints (not a triangulation diagonal's — the
control, the mirror without the face corners the device sends with the UV map,
put 40 of 87 edge snaps on a diagonal), a face (where `scene.ray_cast` meets
it), the cursor's plane, or the view's plane. 2,250 ruler texts, Blender's
(47 a float ulp from the next of six figures).

**Edit Mode's overlays.** More ▸ Viewport Overlays ▸ Text ▸ Statistics, and
in Edit Mode More ▸ Mesh Edit Mode ▸ Measurement ▸ Edge Length, Edge Angle,
Face Area, Face Angle — the 3D View's own switches, as its X-Ray is. What they
draw is Blender's: `_blenderkit_measure.edit_overlay` is
`DRW_text_edit_mesh_measure_stats` and `stats_object_edit` ported, read from
the edit mesh after the viewport's selection is handed over
(`captureWithSelection`), in the object's space or, with the Sidebar's Global
(the same 3D View flag in Blender, V3D_GLOBAL_STATS), through its matrix — the
edge angles' normals through the world-to-object matrix as Blender carries
them. The app clips each edge to the view's sides as Blender does and writes
each value as Blender writes it (`EditMeasurements`). With a modifier shown on
the cage the measurements are not drawn and say why; the labels are hidden
while a transform drag previews. Measured: every number bmesh's own (lengths,
face angles, corner angles, areas summed over the tessellation — the control,
`BMFace.calc_area`, differs on 18 warped faces; Local and Global differ on 22
edges of a scaled cube), the statistics the edit mesh's counts, and 8,730
labels written as Blender writes them.

**In the app** (four launches, the Mac's screen locked, so through the hook):
on a cube turned (0.3, 0.2, 0.5) beside a sphere, from an orbit view, a tap on
the cube with View put the cursor on its face at (0.660, −0.744, 0.717) facing
the view (Euler 65°, 0, 30°); with Geometry, turned as the cube (0.3, 0.2,
0.5); Transform with Global, unturned; in empty space at its own depth; on the
front face with Geometry, (1.871, 0.2, 0.5). An Axis Angle cursor in Front
(the numpad view's special case) and a Quaternion one from another orbit. The
same calls run in desktop 5.2.1 on the same fixture with the same cursor
before gave the same cursor, all 9 checked to the log's six places
(worst 9.3e-7). A drag from the cursor with Snap on to Vertex ended on the
vertex, (1.574820, −0.565015, 0.447995); Undo and Redo left the cursor there,
as Blender's do; with Ctrl held it did not snap; a Pencil's drag placed, then
moved it. That run found a defect: the first build put the dragged cursor at
the snap's move (GeometrySnap.move answers the move, not the place), 0.94 m
from the origin on no vertex; fixed, and a host test now holds it. Measure with
Snap: two cube corners, "2 m"; the line dragged to a third, "45°"; Ctrl held
moved an end in its plane; a tap on an end made the ruler active and Ruler
Remove took it. Edit Mode on the top face: Statistics "Objects 1 / 2,
Vertices 4 / 8, Edges 4 / 12, Faces 1 / 6, Triangles 12", labels "2 m" ×4,
"90.000°" ×4, the area and the corners, bmesh's own lengths beside them; on a
cube scaled (1, 2, 0.5), Global "4 m", "1 m", "2 m" and Local "2 m". Under a
Subdivision Surface, Geometry was refused on the banner and View placed on the
subdivided surface. A fourth launch, after Surface Project's margin was
narrowed to the triangles near the pointer (a mesh of a million would
otherwise be tried 81 times), gave the same depths to the last digit, and
desktop Blender reading that launch's autosave held the cursor at
(1.57482, −0.565015, 0.447994), turned (1.870796, 0.2, 0.5), as the app showed.

Crashes: none in the app; none in desktop Blender from this group's runs (no
report since 17:00 today but the system's own `intelligencetasksd`).

Tests: `scripts/run-measure-tests.sh` (host: the records, the calls, a
mirrored and a sheared object's normal, the margin's rectangle, the drag onto
a snap, the refusals, the ruler's picks, points and text, the labels' clipping,
order and text, the units; each with a control) and
`scripts/run-measure-blender-check.sh` (above). The names checks hold the new
labels to Blender's RNA and its own `space_view3d.py`. New DEBUG flags:
`-measure-ops`, `-measure-overlays` (in scan-app's HOOKS; a Release build
scanned CLEAN, 0 of 76 hooks). Suites run: measure (86) and its Blender check
(22 in Blender over 4,272 clicks, 1,335 strings, 699 points, 2,250 texts and
8,730 labels), names (and its Blender check, 580), mirror (128) and its Blender
check (142), relations (99) and its Blender check (2,333), undo (40) and its
Blender check (94), redo (175) and its Blender check (749), snap (122), tools
(128) and its shim (74), gizmo (118), selectpick (73), cuttools (53),
transformops (67), meshpick (40), regionselect (107), editselection (57).

Not done: the ruler's Shift (surface thickness), its axis constraints while
dragging (X, Y, Z), Edge Perpendicular snapping, and Blender's keeping of
rulers as annotation strokes; the cursor drag's Increment snapping and Align
Rotation to Target; a wire-drawn object's edges, which Blender's depth buffer
has and the mirror does not (no fixture pixel hit one); the 3D cursor's
rotation in the Sidebar's View tab (Blender shows it; the app shows the
location); Statistics outside Edit Mode, and the status bar's own counts,
which still come from the display cache; the measurements on a cage a modifier
makes.

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
| `TransformOrientation.swift`, `TransformCommit.swift` | Blender's orientations and the report the gizmo is drawn on; a gizmo drag's commit as the redo panel's operator |
| `ItemPanel.swift` | the Sidebar's Item tab in Edit Mode, and the Dimensions fields' calls |
| `Collections.swift` | Blender's collection tree and Local View as the mirror reads them, the Outliner's tree, Local View's framing, and the Outliner's, Object ▸ Collection's and Local View's commands |
| `Constraints.swift` | an object's constraints as the mirror reads them, the Constraints tab's commands, Blender's preview of a drag a constraint decides |
| `ObjectMenuRows.swift` | Object ▸ Mirror, Transform's Randomize and Align, Relations ▸ Make Single User, Modifiers, Constraints and Link/Transfer Data, as redo-panel operators |
| `OperatorCatalogue.swift` | More ▸ Operator Search's list, read from `bpy.ops`, and the string its Run sends (`runCommand`) |
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
| `-panel <name>` | opens a More-menu panel at launch: `Outliner`, `Properties`, `Tool Settings`, `Render`, `Image to 3D Model` (before round 4: Scene, Object Details, Transform Tools) |
| `-properties-tab <tab>` | opens the Properties editor on a tab, e.g. `-panel Properties -properties-tab modifiers` |
| `-modifier-dump` / `-modifier-steps <steps>` | prints the active object's modifier rows as the panel holds them, then runs comma-separated steps through what the buttons send: `+kind` (Add Modifier), `Name:viewport\|render\|up\|down\|apply\|remove`, a Multires `Name:subdivide\|unsubdivide\|deleteHigher\|applyBase`, or `Name:key=value;key=value` (an edit by Blender's property names), a declared row's button (`Name:bind_surface`, `bind_mesh`, `generate`, `hook_assign`, …), `+TYPE` (any Add Modifier row on the object, by Blender's type), `@select=Name`, plus `@mode=<MODE>` (F3's Run on `object.mode_set`) and `@hide=1\|0` (the Object tab's Show in Viewports); prints the banner on a failure; waits for `-eval64` to finish |
| `-opsearch <path>` / `-opsearch-args <json>` | More ▸ Operator Search on one operator: reads its form (`BlenderOperatorForm.infoCall`) and presses Run (`BlenderOperatorForm.command` through `bridge.run`), printing what the form showed, the outcome, the banner, the mode after and the active object's Multires levels as Blender holds them; waits for `-eval64` to finish |
| `-uv-row <UVOperator>` | runs one row of the UV Editor's UV menu as the menu does (`Bpy.uv`), e.g. `-uv-row unwrapConformal`, printing the outcome and the banner |
| `-sculpt-enter` | picks Sculpt from the Sculpt menu once a `-eval64` script has finished: Blender's Sculpt Mode on the active object |
| `-sculpt-stroke` | once the sculpt header has read Blender's state, runs `-sculpt-ops a,b,…` (`dyntopo-on\|off`, `remesh`, `voxel-<size>`, `multires`, `mask-fill\|invert\|clear`, `facesets-loose`, `facesets-from-mask`, `size-<px>`, `strength-<v>`, sent as the header sends them, and `labelled`, a labelled change with a memfile step of its own) and `-sculpt-brush <name>`, frames the object (not with `-sculpt-no-frame`), and feeds one stroke across it at 60 points a second through the calls a drag makes (`-sculpt-stroke-points <n>`, `-sculpt-stroke-span <fraction>`). Prints the chunks' costs, what moved in the viewport's mesh and the normals it is shaded with against Blender's corner normals, and with `-sculpt-undo` what Undo and Redo leave, then with `-sculpt-undo-depth <n>` n more Undos and n Redos, each with the history's label and Dynamic Topology; `-sculpt-repeat <n>` makes n strokes one after another first. `-sculpt-header-only` stops after the header's read. The stroke goes through `sculptDrag`, the state machine a finger's drag runs. `-sculpt-midstroke undo\|mask\|leave\|mode` does that at the stroke's midpoint: the top bar's Undo, the header's Mask ▸ Fill, Leave Sculpt Mode, or the mode leaving Sculpt under the finger. It prints what each left: refused or not, the history, and whether the rest of the drag orbited |
| `-region-select <gestures>` | Box, Circle and Lasso drags through the calls a drag makes (`beginRegion`, `extendRegion`, `finishRegion`): `box:x,y;x,y`, `circle:x,y;…:radius`, `lasso:x,y;x,y;…`, points as fractions of the view or `@x,y,z` in the scene, `+extend` / `+subtract` / `+intersect` for Shift / Ctrl / both, `mode:VERT\|EDGE\|FACE` and `none` between, separated by `\|`. Prints the pass's pick, what Blender holds and what the viewport shows, as vertices, edges and faces, the length of Blender's selection order beside the viewport's, whether a refusal was said, and how many samples of the overlay's shaded path disagree with the region selected from. `-region-mode edit` waits for edit mode, `-region-wait <name>` for an object of that name, `-region-view top` snaps and frames first, `-region-view persp:8` puts the opening perspective view 8 from the origin |
| `-region-action <mode>` | The select tools' Mode (`set`, `extend`, `subtract`, `difference`, `intersect`), as the Select tool menu's Mode rows set it |
| `-xray` | X-Ray on, as Viewport Shading ▸ X-Ray does |
| `-select-menu <rows>` | presses Select menu rows through `select`, the call the rows make (`more`, `linked`, `similar:VERT_NORMAL`, `object:child`, `type:MESH`, `objlinked:MATERIAL`, `pattern:Wheel*`, `grouped:CHILDREN`, `nextActive`, `sideOfActive`, …, see `SelectMenu.Command(token:)`), and `adjust:key=value` moves a redo-panel field through `readjust`; after `-select-menu-delay <s>` (3) and any script |
| `-cut-ops <tokens>` | Loop Cut and the Knife through the calls a pointer and a finger make (`loopCutHover`, `loopCutTap`, `knifeTap`, `knifeHover`, `CutToolActions`), `\|`-separated: `tool:loopCut\|knife\|select`, `hover:<p>`, `tap:<p>`, `through:on\|off`, `undo-point`, `cancel`, `confirm`, `ortho:on\|off`, `orbit:<azimuth>,<elevation>,<distance>` (the view turned between taps), `adjust:<key>=<value>`, `undo`, `redo`, `mode:VERT\|EDGE\|FACE`, `state`, `pause:<s>`; `<p>` a fraction `x,y` or a scene point `@x,y,z`. `-cut-view top\|front\|right\|persp:<d>\|orbit:<az>,<el>,<d>` sets the view first and `-cut-wait <name>` waits for that object in Edit Mode. Prints what a Knife tap snapped to and where the hover's next point is, a Loop Cut's preview against the vertices Blender made, a Knife Confirm's new vertices against the crossings worked out from the mesh and its face sizes, and after each Blender's counts, select mode, redo panel and banner |
| `-select-pick <tokens>` | Blender's pick selections and Select menu rows in a mesh's Edit Mode through the calls a pointer, a finger and a key make (`meshEditTap`, `selectLinkedUnderPointer`, the rows' `perform`), `\|`-separated: `tap:<p>`, `tap+alt:`, `tap+ctrl+alt:`, `tap+ctrl:`, `+shift`, `pick:loop\|ring\|path\|linked\|none`, `shift:on\|off`, `hover:<p>`, `leave`, `key:L`, `key:shift+L`, `menu:<row token>`, `adjust:k=v`, `view:<name>`, `undo`, `redo`, `mode:VERT\|EDGE\|FACE`, `pause:<s>`; `<p>` a fraction `x,y` or a scene point `@x,y,z`. `-select-pick-view` and `-select-pick-wait <name>` as `-cut-ops`'s. Prints Blender's counts, active element and order beside the viewport's |
| `-transform-ops <tokens>` | the Orientation menu, gizmo drags and their redo panel, and the Sidebar's Item tab through the calls the controls make, once a `-eval64` script has finished, comma-separated: `orient:<TYPE>` (the menu's `setOrientation`), `select:A+B`, `edit`, `object`, `tap:<vertex>` (what a tap on one vertex leaves in Vertex mode: the viewport's selection pending, then the views' early reads), `frame:<n>` (the timeline's `TimelineDriver.setFrame`, then the gizmo's axes beside Blender's for the frame, with no refresh of the hook's own), `view:top\|persp:<d>`, `gizmo:<translate\|rotate\|scale>:<0\|1\|2\|p0\|p1\|p2\|s>:<amount>` (since October 20 the 3D View's own drag in the view on screen, with its camera and size: the handle the hit test finds at the finger, `beginGizmo`, `updateGizmo`, `endGizmo` — `MetalViewportView.Coordinator.debugDrag`; before, a copy of that sequence in a 1000 × 800 frame), `adjust:<key>=<value>` (a redo row, `readjust`), `redo-panel`, `sidebar:on\|off`, `local`, `global`, `item:<axis>=<v>`, `data:<attribute>=<v>`, `dims:<axis>=<v>`, `item-state`, `undo`, `redo`, `ax`, `steps`. Prints the axes, the call, the preview against Blender, the panel and the banner |
| `-dump-state` | prints the mirrored tool switches (Auto Merge and Split, Affect Only Parents and Origins) and what the UV Editor draws for the active object, before and after the two above |
| `-object-ops <rows>` | presses Object and Mesh menu rows through the calls the rows make, once a `-eval64` script has finished: `select:A+B` (the last is active), `edit`, `object`, `all`, `none`, `dup-linked`, `join`, `parent`, `parent-keep`, `clear`, `clear-keep`, `clear-inverse`, `convert-mesh`, `convert-curve`, `mesh:<LastOperator.Mesh>` (with the menu's pointer, the 3D cursor in this view), `extrude-cursor` (Mesh ▸ Vertex ▸ Extrude to Cursor or Add), `separate:<SELECTED\|MATERIAL\|LOOSE>` (Mesh ▸ Separate's rows), `cursor:x;y;z` (the 3D cursor, as the Sidebar writes it, printing the pointer), `py:<base64>` (a script line with an undo step of its own, to set a fixture up between rows), `cap:<base64>` (what a script prints, read without a step), `shear` (Edit or Object Mode, as the row is), `adjust:key=value` (the redo panel, through `readjust`), `undo`, `redo`, `field:<location|rotation|scale>:<axis>=<value>` (a Transform field of the active object, through `TransformFieldDrag`, the type the fields themselves run — its `change`, with Blender's preview of a field a constraint decides and the session's hold, then its `commit` — printing what the field showed, the Python, what it shows after, Blender's location and world position, and how far the preview was from Blender), and, to read what the screen says: `ax` (every accessibility label in the app's windows — the bar, the tabs, the redo panel, an open sheet — `AccessibilityDump`), `steps` (Blender's own undo history by name), `panel:<name>` and `close` (a More-menu sheet), `search` (the Operator Search), `tool:<ActiveTool>` (a tool, as `choose` picks it), `paintmode:weightPaint\|vertexPaint` (the bar's mode row, `enterPaintMode`), `aim-camera` (Cameras ▸ Align Active Camera to View, printing where the scene camera ended up in the world beside the view) `normals` (the normals the 3D View shades the active mesh with, corner by corner, against the corner normals Blender's Solid view draws, and the vertex normals it drew before as the control) `render-stats` (the viewport's own drawing of the scene, offscreen at 400 × 300, as covered pixels and brightness by cell) `view-stats` (the same for the 3D View's own frame, overlays off; both also print how many pixels differ from the last frame of their kind) `winding:old` / `winding:blender` (the renderer's front face for a mirrored object as it was, or flipped as Blender flips it), `culling:old` / `culling:blender` (back faces culled as they were, or both sides drawn as Blender's 3D View draws them) and `shading:old` / `shading:blender` (every surface by its vertex normals, as before October 20, or by Blender's face and corner normals). After each it prints every object's type, parent and counts read from Blender beside the mirror's and the Outliner's tree, the redo panel and the banner |
| `-groups-ops <steps>` | the Data tab's Vertex Groups and Shape Keys panels and the modifiers' Vertex Group field through the commands their controls send, once a `-eval64` script has finished: `select:Name`, `edit`, `object`, `pick:x<0`, `group:add\|remove\|remove-all\|rename:New\|active:Name\|lock:Name\|assign\|remove-from\|select\|deselect`, `weight:<w>`, `key:add\|mix\|remove\|delete-all\|apply-all\|active:Name\|value:Name:<v>\|set:Name:<setting>:<python>`, `switch:relative\|showonly\|editmode:on\|off`, `+kind`, `mod:Name:group:Group`, `mod:Name:invert`, `drag:z:<amount>` (a gizmo Move), `undo`, `redo`. After each it prints what Blender holds beside what the panels show, and the banner |
| `-points-ops <steps>` | Edit Mode on curves and lattices through the calls the controls make, once a `-eval64` script has finished: `select:Name`, `edit`, `object`, `tap:i[:extend]` (a tap beside cage point i, through `MetalViewportView.pointTap`), `box:x0:y0:x1:y1` (view fractions, `pointRegion`), `drag:translate\|rotate\|scale:0\|1\|2:amount:frames[:what@k]` (a gizmo session, `beginPointDrag`, one Blender preview per frame, the commit; `what@k` after frame k: `undo`, `redo`, `tab`, `done` or `tap` as the controls send them, or `bypass-mode` / `bypass-points`, a change put straight into Blender past the drag's hold), `stale-mesh-tap` (a mesh selection marked pending, as a tap on an emptied curve once marked one), `curve:<row>` and `lattice:<row>` (subdivide, extrude, delete, segments, handle:TYPE, cyclic, switch, regular, flip), `all`, `none`, `delete`, `data:property=value` (a Data tab field), `add-lattice`, `lattice-mod:Mesh:Lattice` (the Modifiers panel's Add and Object field), `cube-top:Name`, `undo`, `redo`. After each it prints the selected points and their positions read from Blender beside what the viewport shows, and for a drag each frame's cost and its last frame against the commit |
| `-standin-dab <n>` | in a 3D View without the bridge (the Scripting tab's), once the scene is in Sculpt Mode with an object: `n` taps through `standInSculptTap` and `n` dabs through `sculptDab`, the calls a tap and a drag make, at the object's centre; prints whether each was refused or installed and the vertices drawn after it. In Weight Paint or Vertex Paint: `n` moves and the end of a drag through `standInPaintDrag`, printing whether each kept the drag or left it to the camera, and the weights and colours drawn before and after |
| `-vwpaint-stroke` | once the scene is in Blender's Weight Paint or Vertex Paint and the paint header has read Blender's state, runs `-vwpaint-ops a,b,…` (`brush-<name>` with `_` for a space, `tool-<BRUSH\|BLUR\|AVERAGE\|SMEAR>`, `size-<px>`, `strength-<v>`, `weight-<v>`, `color-<r>-<g>-<b>`, `blend-<ID>`, as the header sends them), frames the object and feeds one stroke across it through `sculptDrag` (`-vwpaint-points <n>`, `-vwpaint-span <fraction>`, `-vwpaint-passes <n>` back and forth n times); prints the camera, the chunks' costs, and what the 3D View draws beside what Blender holds (in Vertex Paint the darkest colour of each) before, after, and with `-vwpaint-undo` after Undo and Redo; each op prints the colour as the swatch shows it and as Blender holds it |
| `-name-draft <text>` | the first Name field shown (the Data tab's vertex group, with `-panel Properties -properties-tab data`) takes focus, gets the text typed into its draft and loses focus without Return, through its own focus state; prints whether it took focus, the draft after, and the name the panel then holds. `-name-draft-switch <text>` instead keeps the focus and taps another group's row (the row's own call), printing what the field sent and Blender's groups and active group after |
| `-relations-ops <tokens>` | the Outliner's collections, Object ▸ Collection, the Constraints tab, the Object menu's Mirror, Link/Transfer Data, Make Single User, Copy Modifiers, Randomize and Align rows, and Local View, through the commands their controls send, once a `-eval64` script has finished, comma-separated: `select:A+B` (B active), `new:<parent>`, `rename:<name>=<new>`, `delete:` / `delete-h:<name>`, `toggle:<name>:<exclude\|hide\|selectable\|render>`, `active:<name>` (a collection's name, or `B/C` for the instance of C under B), `move:` / `link:<name>`, `move-new:` / `link-new:<parent>=<name>` (the prompt's proposal printed), `con-add:<TYPE>`, `con-del:` / `con-up:` / `con-down:` / `con-first:` / `con-last:<name>`, `con-set:<name>:<prop>=<python>`, `con-target:<name>=<object>`, `con-op:<name>:<operator>`, `mirror:<0\|1\|2>:<g\|l>`, `links:<TYPE>`, `uvs`, `single:<row>`, `modcopy`, `randomize`, `align`, `con-targets:<TYPE>`, `con-copy`, `con-clear`, `adjust:k=v`, `redo-panel`, `add:<primitive>`, `local`, `local-remove`, `all`, `invert`, `sel:<Select menu row>` (`SelectMenu.Command(token:)`, through the menu's `select`), `delete-selected` (X), `search:<path>[:<key>=<value>]` (More ▸ Operator Search's Run, `OperatorCatalogue.runCommand` through `bridge.run` as the form sends it; one string argument), `frame` (the app's camera), `outliner` (the tree as the Outliner lists it), `gizmo:` (as `-transform-ops`; both now drive the 3D View's own `beginGizmo`, `updateGizmo` and `endGizmo` in the view on screen, `MetalViewportView.Coordinator.debugDrag`, and press Undo mid-drag), `constrained-preview:off\|on` (the negative control for Blender's preview of a constrained drag, read by `BpyBridge.beginConstrainedDrag`, so it switches the gizmo's and the fields' shipped path), `panel:<sheet>`, `undo`, `redo`, `steps`, `ax`. After each it prints selection, Local View, the active collection and every object's place, scale, collections and constraints as the app shows them beside Blender's, and Blender's collection tree |
| `-textimage-ops <tokens>` | a text object's Body Text and Data tab rows, Tab on a text, Add ▸ Image ▸ Reference... and Background..., the Empty panel's image rows and the pictures the 3D View draws, through the calls the controls make, once a `-eval64` script has finished, comma-separated: `select:<name>`, `add-text`, `body:<text>` (`\n` a new line), `text:<key>=<value>`, `tab`, `image-ref:<file>`, `image-bg:<file>`, `image-plane:<file>` (each through `ReferenceImages.prepare`, as the pickers), `empty:<key>=<python>`, `view:<top\|front\|…\|persp\|ortho>`, `orbit:<azimuth°>:<elevation°>`, `images` (what `ImageEmptyDraw` draws), `capture:<file.png>` (the 3D View's frame read back, with how many pixels, and in each half, differ from the background, the colours at the centres of the picture's four quarters and an overlays-off control), `culling:old\|blender` (the surface passes culling back faces as they did, or not, `ViewportRenderer.surfaceCull`), `undo`, `redo`, `steps`. After each it prints the active object as the app shows it beside Blender's |
| `-measure-ops <tokens>` / `-measure-overlays <list>` | the Cursor tool, the Measure tool and Edit Mode's overlays through the calls a finger, a Pencil and the bars make (`cursorTap`, `beginCursorDrag`/`updateCursorDrag`/`endCursorDrag`, `beginRulerDrag`/`updateRulerDrag`/`endRulerDrag`, `rulerTap`, `MeasureActions`), `\|`-separated: `tool:cursor\|measure\|select`, `depth:on\|off`, `orient:NONE\|VIEW\|XFORM\|GEOM`, `snap:on\|off`, `ctrl:on\|off`, `tap:<p>`, `drag:<p>><p>…` (a finger's), `pencil:<p>><p>…`, `remove` (Ruler Remove), `global:on\|off` (the Sidebar's), `py:<base64>`, `cap:<base64>` (what a script prints, without a step), `glyph` (the 3D cursor's axes as the renderer draws them), `view:<name>\|orbit:<az>,<el>,<dist>`, `ortho:on\|off`, `undo`, `redo`, `state`, `pause:<s>`; `<p>` a fraction `x,y`, a scene point `@x,y,z` or `@cursor`, written `^<p>` to reach it with Ctrl held. With the flag, each overlay read prints its time on the main thread, its bytes and labels, and its thinning. After each it prints Blender's cursor (location, mode, Euler, quaternion, axis-angle), the mirror's and the Cursor's settings as Blender holds them, the rulers and their text, and in Edit Mode bmesh's own counts and lengths beside the overlays' statistics and labels. `-measure-overlays stats,length,eangle,area,fangle` sets Viewport Overlays' Statistics and Measurement switches |
| `-frames <a,b,…>` / `-frames-wait <text>` | once the console shows the text (printed by a `-eval64` script) and no script runs, each frame through `TimelineDriver.setFrame`, the call a scrub and playback make; prints after each what the timeline and the viewport show beside what Blender holds |
| `-self-test` / `-feature-test` | opens Preferences at launch and presses the Self-Test or Test All Features button through its own action, then Run; prints `[bk-selftest] ended: …` or each feature's line and `[bk-featuretest] ended: …` with the report's path. `-feature-test-cycles` switches the test's Cycles render on |

---

## Testing

### Host suites — pure logic, no simulator

```bash
for s in scripts/run-*-tests.sh; do "$s"; done
```

| Suite | Checks | Covers |
|---|---:|---|
| `mesh` | 219 | primitives, modifiers, edit-mesh operators |
| `redo` | 173 | Adjust Last Operation, the operator catalogue, Spin's composed centre, Knife Project's call, the edge tools' calls, groups, refusals and factor fields, Auto Smooth, Smooth by Angle, QuadriFlow and Add ▸ Curve and Text |
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
| `scriptthread` | 46 | which thread a script runs on (a script that loads a file included, and the list of loading operators held to `_blenderkit_context.FILE_READS`), which scripts have the GPU module started on the main thread first (the start run in python3 with a `gpu.init()` that raises), which console lines run Python (`time` and `watch` before `python`; the first-word rule as the control), and that every console line seeds the history first |
| `tools` | 119 | snapping, the pivot point and proportional editing: the simulator numbering the edit selection on the cage (taps, the gizmo, box select, Select All and its mesh operators), the mirror's packing (Auto Merge and Target Selection included), the Python each control sends, where the gizmo pivots, Blender's falloff curves and measured numbers, Increment and Grid, Connected Only's distance, the preview committing what it showed, the simulator's operators running the same operation, and hidden vertices left out of it |
| `snap` | 122 | snapping a move to vertices, Affect Only Parents keeping a child as a target and Affect Only Origins snapping onto anything, edges, edge centres, faces and face centres: the 30-point reach, what moves left out (children and dependents too, and everything proportional editing may pull), children carried by the preview, the occlusion plane, X-Ray and Wireframe, Face Center's corners, Blender's edge zones and edge direction, quads rather than triangles, empties, wires, curves by their control points and Display As Bounds, Target Selection, the constraints, Snap With, Auto Merge's welds, the drag committing what it previewed, the marker, and the search's cost at 80,000 and 1.28 million triangles |
| `tools-shim` | 73 | the simulator's `bpy.ops.transform` and tool settings (Auto Merge and Split, Target Selection, Affect Only, a move with Affect Only Origins refused, which Snap To set may empty): what it hands TransformOperation, what it refuses (the edge tools by name), the Snap menu's new actions, Individual Origins with proportional editing, Show/Hide's flags and the Object and Mesh menus' rows it cannot run (Duplicate Linked, Parent, Convert, Shear, Split and the clean-up rows, Inset Individual) |
| `modifier` | 283 | the Modifiers panel: a row for every modifier Blender has (unmodelled kinds as `.other`, by Blender's type and name, an unreadable one as a header), the header every row has (both switches, Apply, the moves and remove), the six new kinds' defaults, sends and record, Multires's buttons in object mode, escaped names, identity kept by type, the Python each row sends and the one change an edit sends, the mirror record parsed back (integers included), old saved files still opening, Wave's Motion against Blender's numbers, Remesh's scaled floor (from the Remesh's input, never its output), Mirror's Bisect, Flip, Clipping and Merge (the simulator's Mirror against Blender's counts, Clipping's rule), the simulator's Screw / Decimate / Remesh and its Faces count, its Apply and Origin to Geometry evaluating the stack once, and a Geometry Nodes row (Smooth by Angle's two settings) |
| `modifier-shim` | 45 | the simulator's modifiers: every line the rows send taken by the shim (Mirror's new rows and the six new kinds included, the keys it takes read from the Swift), object pointers by name, the header's moves, switch and remove, Multires's operators, what it refuses as Blender does |
| `mirror` | 128 | the mirror's Swift half: a frame's names looked up once (3,000 keyed objects' channels in under 5 ms), a pushed object, a mesh with no faces carried by its edges, the merge onto what is on screen (the stack, never run twice — nor by a frame change or a duplicate), a frame change moving a wire, Knife Project's cutters, a wire object picked by its lines where Blender draws it, the two visibility flags the Outliner shows, and the UV map and seams (per-corner UVs, the fast path, diagonals, what is refused) |
| `undo` | 40 | reading Blender's undo state, the recovery file, and the simulator's undo keeping a modified mesh's base (drag, undo, redo keep 24 / 48 under a Mirror) |
| `featuretest` | 52 | Test All Features' Swift half: the rating at each threshold, frame times, the report's lines read back, a stopped run named, the Python sent and its answer, every inventory entry run by a case of the runner's or listed with why not |
| `sculpt` | 39 | Sculpt Mode's Swift half: the Python each control sends (object names escaped, the camera to nine figures), Blender's state and a stroke's answers read back, when a stroke's points go, and the Size field in pixels |
| `shader` | 8 | the line shader compiled from Shaders.metal and drawn on the Mac's GPU, fast and safe math: an edge from a vertex Blender gives the normal (0,0,0) is drawn |
| `objectops` | 95 | Object ▸ Duplicate Linked, Join, Parent, Clear Parent and Convert, the Mesh menu's Split, clean-up, Un-Subdivide, Beautify, Bevel Vertices and Extrude Individual rows, Inset Individual and Shear (Edit and Object Mode): the Python each sends, their fields, the checks before the call reading every edit-mode mesh and the panel's own values, which rows are offered, the Outliner's parent tree, and the object selection a redo-panel re-run hands back |
| `transformfields` | 50 | the Transform fields (Properties ▸ Object, the N panel): the eleven numbers the mirror sends and where they go, every rotation mode's fields, what the fields show when the channels are missing, the one-component Python an edit sends, each mode's turn, and the viewport's preview of an edit (a child of a moved parent, the parent carrying its child, the roll-back) |
| `symmetry` | 53 | mirror editing: the `|mirror=` flag the mirror carries and the merge keeping it Blender's, which vertices follow which (the selection's side, both sides selected, on the plane, X+Y's diagonal, hidden images, proportional editing, followers taking no share of the move), Topology Mirror's pairs on paths and grids, a vertex out of place paired by its edges, X+Y with Topology Mirror cancelling, a drag previewing the image and sending `mirror=True` only while editing with an axis on, pairs on Blender's coordinates under a modifier that moves what is drawn, the toggles' Python and undo steps, the five Mesh-menu transforms that send `mirror=True` on any edited mesh and keep the current flags on a redo, Topology Mirror offered in Edit Mode and Weight Paint only |
| `vwpaint` | 27 | Weight Paint and Vertex Paint's Swift half: the toolbar's four tools and every step by Blender's names, the Python each control and the stroke send (Weight, Size and colour held to Blender's ranges), Blender's state read past what it printed first, the region scale, and the Cycles warning's strings and key |
| `groups` | 70 | vertex groups and shape keys: the record the mirror carries (escaped names, counts, a head-less record refused), a key's clamp, counts kept across a frame change, `carryGroups` and the merge, every Data-tab control's call and undo name in Object and Edit Mode, and the modifiers' Vertex Group field read, sent alone, outside the simulator's settings and kept by a saved file |
| `points` | 94 | Edit Mode on curves and lattices: the cage the mirror carries (`ControlCage`, its flags and refusals), a tap (a knot takes its handles, a hidden point is never picked, a knot wins a tie with its handle), a box, what is drawn (`ControlCageOverlay`), the Data tab's settings parsed, `carryPoints` and the merge, the modes a curve or a lattice may enter, the gizmo's points drag (its pivot, its followers, a preview that touches no display cache), and the Python each control sends |
| `names` | 426 | Blender's names (docs/blender-names.md): every string literal the app ships, comments left out, scanned for the names it used to show instead of Blender's (snippets that carry them must be caught first), the 3D View's own steps held to `UndoStep` at every call site in the UI and the App (round 4's review's two edits caught first), each of those steps' calls held to the Python its button sends, and every name built from the app's tables — the Mesh menu's groups, rows, operators and order, the Select, Snap, Show/Hide, Apply, Curve and Lattice menus, Import and Export, the toolbar's tools, the two tabs — held to Blender 5.2.1's menus and toolbar (`tests/names/reference`) |
| `selectpick` | 91 | Blender's pick selections' Swift half: the keys (Blender's keymap), a hit named by Blender's index (and the viewport's own number shown not to be it), the active element a loop makes and its ties, the exact calls and panels (enum flags as sets), the selection order a tap leaves, the push writes and the mirror reads, a region keeping it, the Select menu's new rows, Select Linked ▸ Linked's Delimit by select mode, when a region Set over the selection pushes, and the tap ranking what is near it by Blender's Manhattan distance |
| `transformops` | 87 | the orientations by Blender's names and the report the mirror reads, the gizmo on each orientation (none for one unknown or unavailable), a drag's commit as the redo panel's operator — values in the orientation's axes, the printed matrix the preview multiplies, Blender's rows and the rows it hides — rotate, scale, the view ring, Individual Origins, auto keying out of the log, the Item tab's labels and calls, and the selection handed over before a read; since the October 20 fixes Blender's 3×3 inverse (gimbal lock, a sheared Local, a zero axis), "Pipe none", non-finite numbers read and sent, the redo panel's Edit Mode Normal, unitless Proportional Size, and a tap read early or carried by a setting still re-run on by the redo panel |
| `meshmenu` | 115 | the Mesh menu's round-4 rows' Swift half: Blender's labels, groups and order (Normals ▸ Average, Limited Dissolve in two menus), titles and steps, the exact calls (Merge's five types and UVs, Delete's hidden Type, Rotate Edge, Laplacian's 5e-5 sent as such), the refusals' words kept out of the Info log (the Intersect rows' unselected-face guard by their Source and Self Intersection, Merge's and Laplacian's "changed nothing" read by `edit_state`), the panels' hidden rows, a macro's vector as one entry (and the old per-axis key shown not to be sent), the pointer's numbers, Extrude to Cursor or Add's line, the rows that cannot run, and every row the Operator Search's sentences name read as one of the menu's (a misnamed one shown to fail) |
| `shading` | 31 | the normals the 3D View shades with: Blender's FACE and CORNER normals installed per triangle corner, POINT clearing them, malformed buffers refused, the fast path and the merge (with a negative control), a frame change's way onto the screen, a drag's preview turning a face's normal with it (with a negative control) |
| `meshmenu-shim` | 85 | the simulator's stand-in given every call those rows send: each done as Blender does it or refused in words, never an AttributeError (an unnamed operator shown to be one) |
| `cuttools` | 78 | Loop Cut and the Knife's Swift half: a drawn edge named by Blender's index (the cube's twelve, none of its six diagonals, the viewport's own numbers shown not to be Blender's), Blender's ring parsed and its preview's lines and points for one and three cuts, the exact Loop Cut and Slide and Knife calls and their panels (no row greyed, Clamp, Mirror Editing, Correct UVs, Factor's hard range), the knife's path, Blender's knife snapping (onto an edge, a vertex, the outline from just outside, the path's own first point; density scaling; a hidden or off-mesh path point not snapped to; a zoomed-in negative control), the path Confirm cuts from its view (points on one line of sight joined, a closed path, the same points apart from another view), the refusals' words, and a preview held to the mesh it was made over |
| `modkinds` | 284 | round 4, group 8's Swift half, and its review's fixes (a cleared body, Blender's text ranges, the Screw row's price, a move priced first, the stand-in's notes, pictures converted for Blender and drawn as it reads them): Add Modifier by object type (Blender's categories, counts and words, Array (Legacy), the Essentials rows), the eleven declared rows' records, lines and one-line edits (sets, vectors, pointers, Replace Original's price, a setting or item Blender did not send never written), the buttons, Show in Viewport's price, Data Transfer's dynamic Mix Mode, the text and image empty records, Blender's picture visibility rules and the passes, each with a control |
| `modkinds-shim` | 88 | the simulator's stand-in given every line the ten declared rows it models send: each key down the channel the Swift declares (a number, a vector, an identifier or an object), an identifier the Swift does not have refused |
| `measure` | 119 | the Cursor tool's, the Measure tool's and Edit Mode's overlays' Swift half: the cursor and units records (settings kept from a pass off the main thread), the tap's and the drag's calls, a sheared and a mirrored object's face normal (the inverse transpose; the matrix and the world cross product its controls), Surface Project's margin rectangle, the drag landing on a snap, Geometry and the drag's snap under a last Subdivision Surface refused and under a Mirror kept (the old rule as control), the snap note, no auto keying after a cursor drag, the cursor drawn turned (the world-aligned drawing as control), the ruler's picks, angle point, Ruler Remove's angle, a tap on nothing, placing and text, the file record clearing the rulers, the read's view row by row and a thinned record's note, the labels' clipping, order, offsets and text, the unit strings |

### Blender-side checks — the ones that cannot lie

Each gives desktop Blender a HOME and BLENDER_USER_RESOURCES of its own, so no
check writes this Mac's Blender settings or its `~/.thumbnails` (a bare
`-b --factory-startup` run writes the latter). `scripts/run-sandbox-tests.sh`
fails on any check script that starts Blender without them.

```bash
./scripts/run-redo-blender-check.sh        # 506 calls, Knife Project included, the edge tools measured on grids, then Knife Project after a script-thread render in a fresh Blender
./scripts/run-viewport-blender-check.sh
./scripts/run-context-blender-check.sh     # 54: temp_override off the main thread, and the six file loads refused there and run on the main thread
./scripts/run-image3d-blender-check.sh     # Image to 3D Model's relief and full 3D in Blender
./scripts/run-render-blender-check.sh      # renders, and the 3D View's own framing
./scripts/run-tools-blender-check.sh       # 271: every drag's preview against Blender's commit, Mirror Clipping, Auto Merge, parent chains and Affect Only Parents and Origins included, snaps onto Blender's own meshes, and what moves with what against the depsgraph
./scripts/run-modifier-blender-check.sh    # 238: each modifier row into Blender, its record back, edits made from Blender's record (Smooth by Angle's included), the Remesh row dragged to its floor, every type modifier_add takes on a mesh reaching the panel, the six new rows, every row's header (moves Blender refuses included), Multires's buttons from Edit and Sculpt Mode, the Sculpt stepper's own edit refused on a base too heavy to sculpt on a level (and, without its check line, setting it), a name with the record's separators, and the Data API browser on a modifier
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
./scripts/run-opsearch-blender-check.sh    # the operator search's mode rule and refusals, then every operator it lists run through run_operator on three fixtures from seven starting modes — Local View among them, each of its rows through `_blenderkit_localview.scope` as the app sends it there: 24,010 runs, no crash, every Local View run under the borrowed view
./scripts/run-vwpaint-blender-check.sh     # Weight Paint and Vertex Paint, Blender's own: in and out under Blender's step names, the refusals Blender's exec path does not make, a stroke streamed in chunks against the same dabs as one of Blender's strokes (and, as the negative control, cut into strokes of its own), a long stroke back and forth held back by the replay throttle and replayed whole at its end (against cutting it at 64 dabs), every Essentials brush of both modes with Undo and Redo, the header's settings where Blender reads them, what the viewport is handed through a Subdivision, a stroke held open, and one after a load freed the undo stack; the colour held scene linear and painted as picked (against writing the picker's sRGB raw), a mirror dearer than the budget holding replays back, a refused chunk's cancel against end's flush, a Line stroke's spacing against its two ends, a stroke cut at MAX_STROKE_DABS, and the numpy mirror against the loop on 40,962 vertices
./scripts/run-names-blender-check.sh       # each redo panel's title against its operator's name and each of its fields against its property's, 43 undo steps measured against Blender's own history (operators called with their undo on, the app's undo stack; the app's names read from the dump, UndoStep's included), app_steps.py (the in-app measuring script) measuring the same in the app's script context, the enums the app names choices by, a stroke's step read whichever case the build prints, and the simulator's brushes against the Essentials
./scripts/run-undostack-blender-check.sh   # 27: eight ways to Sculpt Mode's undo code with no undo stack (Sculpt Mode entered with its undo on while the history's probe is deferred, a mask fill there, a mask fill and Face Sets ▸ Initialize after a file load, a launch whose recovery file opened in Sculpt Mode, and a script line, the search's runner and a borrowed-view call with no history step), each in a Blender of its own: all survive with both guards and with `require_undo_stack` alone, the first four with `ensure_stack` alone, refused in words off the main thread; with neither the first four crash, with the history's alone the launch and a console line crash (each crash leaves a Blender-*.ips, on purpose)
./scripts/run-selectpick-blender-check.sh  # 251: the app's pick at 2,065 to 2,077 pixels of four meshes against Blender's own click there (loops and rings at each edge's middle and off it), and the result of each call against Blender's own Alt+click, Ctrl+Alt+click, Ctrl+click and L (2,275 to 2,287 calls by the sphere's numbering, all the same), seven negative controls, the refusals, the undo-in-an-area guard (True, 1, 2, -1, looked up outside), Select Linked ▸ Linked against Blender's Ctrl+L per select mode, Box Select's Set over the selection, the aimed view's failure path, Next/Previous/Side of Active, Select Grouped type by type
./scripts/run-transformops-blender-check.sh # the orientation port against Blender's own matrix (67 cases), 1,455 drags in seven orientations on thirteen fixtures (gimbal lock, a sheared child, Active Element's pair since October 20) and their redo changes held to the preview, a tap read early or carried by a setting, the Item tab and Dimensions (Edit Mode refused, non-finite results refused, no Dimensions for an Empty, a Camera, a Light), with negative controls
./scripts/run-meshmenu-blender-check.sh    # 197: its fixtures shown to be the same from build to build (the raw sphere's 8 orders in 20 as the control), every round-4 Mesh row against Blender's own call on the same selection (counts, positions, selection and custom normals, compared by their vertices; Blender's own run twice for each normals row), the refusals leaving the mesh as it was (each new one beside Blender's own call there, and compared by counts alone as a negative control), each from Sculpt Mode in the app's own words (Merge's old check as the negative control), Extrude to Cursor or Add (264 cases, and an object scaled to 0 refused) and Rip Vertices and Extend (72) against Blender's own invokes run with a made event, with negative controls, and Rip and all nine Poly Build operators measured changing nothing
./scripts/run-shading-blender-check.sh     # 41: the app's sync and push_mesh replayed through the Swift, every triangle corner of the six Normals rows' meshes, flat, smooth, by-angle, edited-with-a-hidden-face and deformed meshes held to Blender's corner normals (worst 0.00000°), what each row changed on screen beside what it changed in Blender, and the same passes without sync_shading as the control
./scripts/run-cuttools-blender-check.sh    # 118, then 13 previews: Loop Cut's ring against Blender's cut on every edge of 13 cases (and a walker crossing n-gons shown to differ), the edge index the mirror sends, the Swift-made Loop Cut and Slide, its re-runs, its Clamp, Mirror Editing and Correct UVs each changing the cut, and its refusals (a hidden object; the undo argument as True, 1, 2, -1 for five operators in the borrowed view and an operator looked up before it, with the old rule's negative control), the Knife in perspective and orthographic with Cut Through off and on against crossings worked out apart from it, the Swift-snapped Knife against Blender's knife result (edge to edge, corner to corner, a closed path; unsnapped negative controls), points on one line of sight, the selection the cut keeps in each select mode, Blender's cage under a Subdivision, a missed path leaving the selection as it was, Subdivide Edge-Ring with Blender's defaults and its budget; then the Swift preview held to each cut (and, drawn without Blender's orientation, failing)
./scripts/run-modkinds-blender-check.sh   # 982 over two Blender runs: Add Modifier against Blender's own menus for thirteen object types, every row added on five, the budget's counts against to_mesh() and its refusals, every declared field against RNA, 66 edits built from Blender's record and replayed through the Swift, the buttons (Bind, Precision 6 refused with a control), each kind's Vertex Group, the Body Text and text rows with their price, and Add ▸ Image's pictures packed and drawn by Blender's rules; and round 4's review's cases: the text priced from its letters (other letters, negative Bevel, Fill Mode, Offset, the Data API row, a cleared body), the budget on a text, curve and surface, Screw's row and Iterations, Ocean in Displace, Skin after a Subdivision change and a move, Edge Split, pictures from a device converted and read by Blender, Mesh Plane...
./scripts/run-unsafe-blender-check.sh     # 118: _blenderkit_context.UNSAFE_OPERATORS by every route a call takes (a script line on either thread, the borrowed view, an early lookup, create_function, a reload, a script's macro, the search, the module in any case), the brush pick given its tool, Mask Fill with no undo stack, the macro steps every way Blender names them, and 17 scenarios (a BLOCKING macro, the brush pick outside a brush mode, inside a load's handlers, ...) guarded and with the unguarded controls that crash or hang a Blender of their own
./scripts/run-guards-blender-check.sh     # the guards round 3's and round 4's reviews found missing: loop cut with no 3D View (a crash control), the vertex budget over the whole stack and every way to it, Subdivision Set and every way into Sculpt Mode held to the heavy-base budget (negative controls), a brush picked in a file saved in a paint or sculpt mode and temp_override with a screen and no window (each with a crash control in a Blender of its own), symmetry under a shape key, Duplicate in Edit Mode, and Blender's own interface operators (`INTERFACE_ONLY`: all thirteen refused from a script, inside the borrowed 3D View and from the search, with two crash controls)
./scripts/run-measure-blender-check.sh    # the Cursor tool against Blender's own invoke (4,272 clicks with the depth buffer redrawn each time, 4,146 calls, negative controls), no undo step and the cursor kept by both histories, the drag's translate, 1,335 unit strings against Blender's C, 699 ruler points and 2,250 texts, 8,730 overlay labels against bmesh, Global's against Blender's formulas; the Cursor's settings in a tool Blender would have made (the unnamed one as control); Blender's own Geometry click under ten modifier stacks against `subdivides_last` (the old rule as control); the bounded read (per-face tessellation, the culled rows, every drawn label kept, the bound, each with a control); the file-load count
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

**Blender's own interface operators crash a Blender with no interface**
(found 2026-10-20). The app's bpy draws nothing, and Blender's menus, pies and
panels, and the operators of its areas and regions, assume something does.
Measured in desktop 5.2.1 with the app's context: `wm.call_menu`,
`wm.call_menu_pie`, `wm.call_panel` and `wm.context_menu_enum`, given what to
open, segfault with or without an area; `wm.toolbar`,
`view3d.object_mode_pie_or_toggle`, `screen.region_quadview`, `view2d.pan` and
the `view2d.scroll_*` segfault under the borrowed 3D View, and
`screen.area_close` hangs there. The operator sweep runs defaults with no area,
where each fails in words; it took a sweep from Local View, where every
command runs under the borrowed view, and names typed into the popups, to see
them. `_blenderkit_context.INTERFACE_ONLY` refuses them in words; anything of
the same kind found later — an operator that opens a popup or works on an area
or a region — belongs there, measured in desktop Blender first. Under the
borrowed view an interface operator that does not crash can still change the
area every later borrowing uses (`screen.space_type_set_or_cycle` made it an
Image Editor), so the search runs the interface's modules with no area even in
Local View (`_blenderkit_sync._interface_context`).

**Sculpt Mode's undo code needs Blender's undo stack, which only
`ed.undo_push` makes** (2026-10-19 and 20). A Blender with no interface has no
stack until `ed.undo_push`, and a file load frees it; entering Sculpt Mode with
the undo argument on, or a mask fill or Face Sets ▸ Initialize in it, then
segfaults (`ED_undosys_stack_memfile_id_changed_tag` with a null stack; the
app hit the first, BlenderLocal-2026-10-19-210858). The history makes the stack
with its first step and after every load (`ensure_stack`), and
`_blenderkit_context.require_undo_stack` makes it as any operator is called in
Sculpt Mode or into it, looking once per load. A new way into Python that
skips `prepareBackendChange` is covered by the second only on the main thread:
off it the call is refused. `scripts/run-undostack-blender-check.sh`'s negative
controls crash desktop Blender on purpose, and each leaves a Blender-*.ips with
that stack in ~/Library/Logs/DiagnosticReports (`mask_flood_fill_exec`,
`face_sets_init`, `push_enter_sculpt_mode`): match the report's time against
the check's runs before chasing one.

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
Snap is Blender's Shift+S menu, and More ▸ Tool Settings holds the fields
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
    render and not the Solid view. (Fixed October 20: the 3D View draws
    Blender's face and corner normals, `MeshData.shadingNormals`.)
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
| Knife | modal — Blender refuses it without a window | still not possible (a tool since round 4: see October 18, group 3) |
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

**Loop Cut** (2026-09-17; superseded in round 4, group 3: this row is Blender's
Subdivide Edge-Ring now, and Loop Cut is a toolbar tool) cuts across the *selected* edges rather than the edge
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
| Knife (drawn) | `knife_tool` is modal and fails its poll without a window. Knife Project, which cuts with another object's outline, works — see *Spin's centre, and Knife Project after all*. (Round 4, group 3: the toolbar's Knife cuts along a drawn path through Knife Project.) |
| Poly Build | modal, driven by the pointer |

These are not missing because Blender cannot do them, but because Blender does
them by tracking a pointer inside a window it does not have here. Reaching them
means reimplementing the interaction and calling the non-modal operator
underneath, as Loop Cut now does.
