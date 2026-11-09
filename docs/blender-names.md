# Blender's names

The user asked for it plainly: every tool, menu and command in the app is
named as Blender names it — the names of all tools except the ones Blender
does not have. This file is the record of that (round 4, group 1,
2026-10-02): what each name used to be, what Blender 5.2.1 calls it, where
that was read or measured, and the names the app keeps as its own and why.

## Where Blender's names come from

Nothing here is from memory. Each name was read out of desktop Blender 5.2.1
(`/Applications/Blender.app`), in a Blender with a home of its own so nothing
reached this Mac's Blender settings:

| What | Read from |
|---|---|
| Toolbar tools | `VIEW3D_PT_tools_active.tools_from_context` per mode: `tests/names/reference/blender_toolbar.json` (made by `toolbar.py` there) |
| Menus and their rows | every `VIEW3D_MT_*` / `TOPBAR_MT_*` menu's own `draw()`, in Object Mode and a mesh's Edit Mode, each row recorded with the operator it runs: `tests/names/reference/blender_menus.json` (`menus.py`). The 19 menus that could not be drawn that way were read in `scripts/startup/bl_ui/space_view3d.py` |
| Redo panel titles | the operator's `get_rna_type().name`, which is what Adjust Last Operation shows |
| Undo steps of operators | **measured**: the operator called with its undo on (a `bpy.ops` call's second argument, which is how a button's call pushes its step) in the app's context — its undo history (`_blenderkit_undo`), `gpu.init()` — and the step read back with `print_undo_steps` (`_blenderkit_undo.blender_steps()`). 43 calls in desktop 5.2.1, and 41 of them again in the app's own bpy (5.3): see "Undo steps" below |
| Undo steps of field edits | **read from Blender's source, not measured**: `ui_apply_but_undo` (interface_handlers.cc) names a field's step after the text it draws, up to its colon, and a field with no text after its tooltip's first line. A Blender with no interface has no field to press |
| Choices (modes, pivot, snapping, falloff, Separate, Set Origin, handle types, lights, modifiers, engines…) | the RNA enum item's `name` |
| Panels, popovers, Properties tabs | `bl_label`, `SpaceProperties.context`, and the panel's `draw()` for a field's own text |

Blender draws "..." where the app draws "…"; the words are Blender's, the
ellipsis is the platform's.

## What changed

### The toolbar and the bar

| Was | Blender's name | Where it is read |
|---|---|---|
| Select (the segment, with Tweak in hand) | Tweak | toolbar |
| Tap to Select / Drag a Box / Paint with a Circle / Draw a Lasso | Tweak / Select Box / Select Circle / Select Lasso | toolbar |
| Circle Radius | Radius | `view3d.select_circle`'s `radius` |
| Draw (the paint modes' first tool) | Brush | Texture, Vertex and Weight Paint toolbars |
| Inflate / Flatten / Pinch (the simulator's sculpt brushes) | Inflate/Deflate / Flatten/Contrast / Pinch/Magnify | the Essentials brush assets (a brush is an asset in 5.x, the toolbar's one tool is Brush) |
| Extrude (the bar's button while editing) | Extrude Along Normals | Edit Mesh toolbar |
| Edit Mesh / Edit Curve / Edit Lattice | Edit Mode | `Object.mode`; the mode menu |
| Editing *Cube* … Done | Edit Mode *Cube* … Object Mode | the mode menu's two rows |
| Scene (the button that opens the tree) | Outliner | the editor's name |
| Pivot | Pivot Point | the pivot popover and pie |
| Snap ▸ Snap To / Snap With | Snapping's Snap Target, Snap Target for Individual Elements, Snap Base | `VIEW3D_PT_snapping` |
| Proportional; Falloff; Size | Proportional Editing (Proportional Editing Objects in Object Mode); Proportional Editing Falloff; Proportional Size | `use_proportional_edit(_objects)`, `proportional_edit_falloff`, `proportional_size` |
| Mirror Options (the mirror row's popover) | Options (Edit Mode), Symmetry (Weight Paint) | where Blender keeps Topology Mirror |
| Leave Sculpt Mode | Object Mode | the mode menu |

### The Mesh menu

The app's Mesh menu had headings of its own — Add Geometry, Cut and Divide,
Fill, Deform — which no Blender menu has. It is now made of Blender's menus,
each row where Blender has it, in Blender's order (`LastOperator.Mesh.Group`):
Select ▸ Select Loops; the Mesh menu's Transform, Extrude, Merge and Split;
Separate, Bisect, Knife Project and Symmetrize in the menu itself; Normals,
Show/Hide, Clean Up and Delete; then the Vertex, Edge and Face menus Blender's
header keeps beside Mesh. Each row runs the operator Blender's row runs, but
two: Extrude Faces Along Normals and Extrude Manifold call the macro Blender's
row reaches through a Python wrapper that needs a 3D View region
(`view3d.edit_mesh_extrude_move_shrink_fatten`,
`view3d.edit_mesh_extrude_manifold_normal`), with the same arguments
(`OPERATOR_EXCEPTIONS` in tests/names/verify.py).

A row's **label** is its menu's; its **redo panel title** and **undo step**
are the operator's name, which is what Blender shows in both:

| Was (label = title) | Row label | Title and undo step | Menu |
|---|---|---|---|
| Bevel | Bevel Edges | Bevel | Edge |
| Bevel (vertices) | Bevel Vertices | Bevel | Vertex |
| Extrude | Extrude Faces Along Normals | Extrude Region and Shrink/Fatten | Extrude |
| Extrude Individual Faces | Extrude Individual Faces | Extrude Individual Faces and Move | Extrude |
| Loop Cut (the ring through the selected edges, subdivided) | Subdivide Edge-Ring (`subdivide_edgering` alone, since round 4 group 3) | Subdivide Edge-Ring | Edge |
| Smooth | Smooth Vertices | Smooth Vertices | Vertex |
| Merge at Center | At Center | Merge | Merge |
| Merge by Distance | By Distance | Merge by Distance | Merge |
| New Face from Edges | New Edge/Face from Vertices | Make Edge/Face | Vertex |
| Recalculate Normals | Recalculate Outside | Recalculate Normals | Normals |
| Flip Normals | Flip | Flip Normals | Normals |
| Tris to Quads | Triangles to Quads | Triangles to Quads | Face |
| Solidify | Solidify Faces | Solidify | Face |
| Select Edge Loops / Rings | Edge Loops / Edge Rings | Multi Select Edge Loops / Rings | Select Loops |
| Connect Vertex Path | Connect Vertex Path | Vertex Connect Path | Vertex |
| Slide Vertices | Slide Vertices | Vertex Slide | Vertex |
| Clear Seam / Clear Sharp | Clear Seam / Clear Sharp | Mark Seam / Mark Sharp (`clear=True`) | Edge |

The rest kept their names, which were already Blender's. Loop Cut was the one
row Blender's Edge menu did not have under that label (Select Edge Rings, then
Subdivide Edge-Ring, which no row of Blender's does). Since round 4, group 3,
the row is Blender's Subdivide Edge-Ring — that operator alone, refused in
words when it would cut nothing — and Loop Cut is the toolbar's tool.

### Loop Cut and the Knife (round 4, group 3)

| Where | Name | Blender's source |
|---|---|---|
| Toolbar (Edit Mode bar), Ctrl+R | Loop Cut | `builtin.loop_cut`, the Edit Mesh toolbar |
| Toolbar (Edit Mode bar), K | Knife | `builtin.knife` |
| Mesh ▸ Edge row that picks Loop Cut | Loop Cut and Slide | `VIEW3D_MT_edit_mesh_edges`, after Edge Slide |
| Mesh row that picks the Knife | Knife Topology Tool | `VIEW3D_MT_edit_mesh`, after Knife Project |
| Loop Cut's redo panel and undo step | Loop Cut and Slide | `mesh.loopcut_slide`'s name |
| Its fields | Number of Cuts, Smoothness, Falloff (Smooth … Linear), Factor, Even, Flipped, Clamp, Mirror Editing, Correct UVs | `MESH_OT_loopcut` and `TRANSFORM_OT_edge_slide` RNA; the last three since the review (Edge Slide's rows `transform_poll_property` shows), none greyed |
| Subdivide Edge-Ring's redo panel | Number of Cuts, Interpolation (Linear, Blend Path, Blend Surface), Smoothness, Profile Factor, Profile Shape (Smooth … Linear) | `MESH_OT_subdivide_edgering` RNA, in its order, with its defaults (10, Blend Path, 1, 0, Smooth) since the review |
| The Knife's redo panel and undo step | Knife Topology Tool | `mesh.knife_tool`'s name: what Blender's history calls a knife cut. The call that runs, and that the Info log shows, is `mesh.knife_project` (the knife without a pointer) |
| The Knife's bar | Cut Through, Undo, Cancel, Confirm | the knife's modal keymap (`knifetool_modal_keymap`) and status bar |

The task that asked for the Knife called its buttons Done and Cancel; Blender's
knife says Confirm (Return) and Cancel (Escape), so those are the names.

Sentences that name a row give the path to it in the app, in Blender's
words: "Select ▸ Select Loops ▸ Edge Loops" (was "Select Loops > Select Edge
Loops"), "Mesh ▸ Knife Project" (was "Mesh ▸ Cut and Divide ▸ Knife Project"),
"Mesh ▸ Edge ▸ Subdivide Edge-Ring" (was "Mesh ▸ Edge ▸ Loop Cut"). The path is
the app's, not Blender's, in two ways: the app's Mesh menu holds the Vertex,
Edge and Face menus Blender's header keeps beside it ("Mesh ▸ Edge ▸ Mark
Seam", where Blender's is Edge ▸ Mark Seam; `_blenderkit_uv` said the latter
and is the app's now), and its Add menu lists the mesh primitives itself
("Add ▸ Circle", Blender's Add ▸ Mesh ▸ Circle). The sculpt brush refusal
that pointed at a "Remesh ▸ Multires Subdivide" row no one has now says
Remesh ▸ Add Multires and Subdivide, the header's button; the stand-in brush's
"Sculpt in the Sculpting tab" (there is none) says the Layout tab.

### The More menu and the sheets

| Was | Blender's name |
|---|---|
| Look Through Camera | Cameras ▸ Active Camera (View ▸ Cameras) |
| Aim Camera at This View | Cameras ▸ Align Active Camera to View (View ▸ Align View) |
| View Style, and its rows wireframe / solid / material / rendered (the raw identifiers were showing) | Viewport Shading — `View3DShading.type`'s name, the header's four buttons — with Wireframe, Solid, Material Preview, Rendered |
| Object Details | Properties — the sheet *is* Blender's Properties editor (its tabs and panels); the task's suggestion, Sidebar, is the N key's editor in Blender, which shows other things |
| All Blender Tools | Operator Search (Edit ▸ Operator Search) |
| Transform Tools | Tool Settings — Blender's bar of that name (View ▸ Tool Settings) holds Pivot Point, Options, Snapping and Proportional Editing |
| Duplicate (Object Mode) | Duplicate Objects; Duplicate in Edit Mode, as Blender's Mesh menu has it |
| Delete Selected | Delete |
| Every Property | Data API — the Outliner's display mode that browses the same RNA tree |

### The Mac menu bar

| Was | Blender's name |
|---|---|
| View ▸ 3D View | Layout |
| Search Operators… | Operator Search… |
| View Selected | Frame Selected |
| Look Through Camera | Camera (View ▸ Viewpoint) |
| Aim Camera at This View | Align Active Camera to View |
| Perspective / Orthographic | Perspective/Orthographic |
| Wireframe / Solid (Shift+Z) | Toggle Shading Type |
| Script ▸ Run / Find and Replace… / Go to Line… / Toggle Comment / Outdent | Run Script / Find & Replace… / Jump To… / Toggle Comments / Unindent (the Text editor's) |
| Object ▸ Select All / Deselect All / Invert Selection | a Select menu of its own: All / None / Invert |
| Select Tool, Box Select Tool, Circle Select Tool, Lasso Select Tool, Move Tool, Rotate Tool, Scale Tool | Tweak, Select Box, Select Circle, Select Lasso, Move, Rotate, Scale (under Toolbar) |
| Duplicate (Object Mode) | Duplicate Objects |
| Edit Mesh / Finish Editing Mesh (Tab) | Edit Mode, ticked while in it — `editmode_toggle` is named "Edit Mode" in 5.2.1 |
| ✓ Vertex Select / Edge Select / Face Select | Mesh Select Mode ▸ Vertex / Edge / Face |
| Object Details (N) | Properties |
| Open the 3D View | Layout |
| Animation ▸ Delete Keyframe… | Delete Keyframes… |
| Pause Animation, Play Animation in Reverse | Play Animation (Space and Shift Ctrl Space, one operator) |
| Jump to Previous / Next Keyframe | Jump to Keyframe (↑ and ↓) |
| Previous Frame / Next Frame | Frame Offset (← and →) |
| Jump to Start / Jump to End | Jump to Endpoint (⇧← and ⇧→) |

Blender gives one operator one name for both directions, and its keymap
lists both under it with their keys; the menu bar does the same. The
Timeline's icon buttons carry Blender's tooltips the same way, and say the
direction as an accessibility value in Blender's words for the property
("Last Frame", "Next Keyframe", "Play in Reverse").

### Panels, tabs and fields

| Was | Blender's name |
|---|---|
| Workspace tab 3D View | Layout |
| Properties tabs Mods, Mat (and Object Data in the tooltip) | Modifiers, Material, Data |
| Camera: Clipping ▸ Start / End | Lens ▸ Clip Start / End |
| Camera: Scene Camera panel, Make This the Scene Camera, Aim at This View, Look Through It | Cameras: Set Active Object as Camera, Align Active Camera to View, View Camera |
| Light: Colour; Spot Shape ▸ Cone Size; Area Shape ▸ Size Y | Color; Beam Shape ▸ Angle; Light ▸ Size X and Y (Size for a square or disk) |
| Tool Settings: Transform (the pivot) | Pivot Point |
| Include Non-edited | Include Non-Edited, under Target Selection |
| Shape Key Specials: New Shape from Mix, Delete All Shape Keys, Apply All Shape Keys | New Combined, Delete All, Apply All |
| Shape Key Lock | Solo Active Shape Key |
| Sculpt: Mask Brush, Face Set Paint Brush | Mask, Face Set Paint (the brushes' names) |
| Sculpt: Detail (Relative) | Detail Size, Detail Percentage or Resolution, by the detailing method |
| Render: Eevee, Solid; Use Eevee, Use Solid | EEVEE, Workbench; Use EEVEE, Use Workbench |
| Render: 3D View, Scene Camera | 3D Viewport, Camera |
| Outliner display modes Scene, Orphan Data | Scenes, Unused Data |
| Outliner toggles' tooltips | Disable in Viewports, Hide in Viewport, Disable in Renders |
| Timeline: Auto Keying Settings; Hide Timeline | Auto Keyframing; Close Area |
| (November 9) Timeline ▸ View ▸ Show Seconds (greyed) | Use Timecode (`SpaceDopeSheetEditor.show_seconds`'s RNA name in 5.2.1, the row TIME_MT_view draws; Ctrl+T) |
| (November 9) Timeline's undo steps for its keys | the Dope Sheet's operators' names, which `ED_undo_push_op` names a step after: Select Keyframes, Box Select, Select All (both `action.select_all` and `action.select_column`), Transform, Duplicate (`action.duplicate_move`, where the 3D View's is Add Duplicate), Delete Keyframes, Paste Keyframes, Set Keyframe Interpolation, …; the markers' Add Time Marker, Select Time Marker, Move Time Marker, Rename Marker, Delete Markers — each held to `get_rna_type().name` by run-timeline-blender-check.sh |
| (round 4's review) Object tab: Relations ▸ Show in Viewports | Visibility ▸ Show In ▸ Viewports (OBJECT_PT_visibility) |
| (round 4's review) Light: a second panel titled Light for an area's Shape and Size | the one Light panel, Shape and Size where Radius is for a point or spot (DATA_PT_EEVEE_light) |
| (round 4's review) Sculpt header ▸ Remesh: Voxel Remesh | Remesh (VIEW3D_PT_sculpt_voxel_remesh's button; its step is still Voxel Remesh, the operator's name) |
| (round 4's review) Texture Paint header: Brush Color (its accessibility label) | Color |
| (round 4's review) the simulator's sculpt brushes in the header, the Sidebar and the drag's status: Inflate, Flatten, Pinch | Inflate/Deflate, Flatten/Contrast, Pinch/Magnify (`SculptBrush.name`, which the toolbar's rows are) |
| (round 4's review) redo panel fields: Bisect's Axis, Edge Rings' Delimit, Slide Vertices' Direction | Plane Normal, Edge Ring Delimit, Slide Direction (the properties' RNA names; every field is now held to its property's name by the names check) |
| Operator Search: All Tools, *n* tools | All Operators, *n* operators |
| Scripting: Run | Run Script |
| File ▸ Import Model… | File ▸ Import ▸ Alembic (.abc), Universal Scene Description (.usd*), Wavefront (.obj), Stanford PLY (.ply), STL (.stl), FBX (.fbx) (Legacy), glTF 2.0 (.glb/.gltf) — each row reads its own format and refuses another in words |
| Export ▸ glTF Binary (.glb), Universal Scene Description (.usd) | glTF 2.0 (.glb/.gltf), Universal Scene Description (.usd*), in Blender's order |
| Save Scene (the Save As prompt) | Save As |
| Curve ▸ Extrude | Extrude Curve and Move |
| Lattice ▸ Flip ▸ U, V, W | Flip (Distortion Free) ▸ U (X) Axis, V (Y) Axis, W (Z) Axis |

### Weight Paint and Vertex Paint (round 4, group 2)

Both modes are Blender's own now (`_blenderkit_vwpaint`), so their controls
take the names Blender's own header and toolbar give them in 5.2.1
(`brush_shared_settings` in properties_paint_common.py,
VIEW3D_PT_tools_active):

| Control | Blender's name | Where it is read |
|---|---|---|
| The bar's mode rows | Vertex Paint, Weight Paint (and Object Mode back) | the mode menu, `Object.mode`'s enum names |
| The four tools | Brush, Blur, Average, Smear | the Vertex and Weight Paint toolbars |
| The brushes | the Essentials assets' names: Paint, Blur, Average, Smear (Weight Paint); Paint Hard, Paint Soft, Paint Hard Pressure, Paint Soft Pressure, Airbrush, Blur, Average, Smear (Vertex Paint) | `essentials_brushes-mesh_weight.blend`, `-mesh_vertex.blend` |
| The header's fields | Weight, Size, Strength, Blend (and Blend's choices by their enum names) | `prop_unified(…, text="Size")`, the properties' names |

The paint header's Size was Radius in the app's own (never shown) tool row.

### Undo steps

An undo step's name is one of three kinds, and each is said for what it is.
Round 4's review found the first two presented together as Blender's
measured history, and the app's own 3D View steps typed into the check that
was meant to hold them to it.

**Measured: an operator's step.** The operator called with its undo on, as a
button's call is, in the app's context, and the step Blender pushed read back
from its own stack. tests/names/blender/verify.py does it for 43 calls in
desktop 5.2.1 and holds the app's name for each — read from the app
(`tests/names/main.swift`'s dump: `UndoStep` for the 3D View's own buttons,
keys and gizmo, the tables for the rest), not typed into the check — to what
Blender recorded. tests/names/app_steps.py makes 41 of the same calls in the
app's own bpy (5.3), and the app's names were the steps that Blender recorded,
41 of 41 (docs/blender-local.md, October 19).

| Was | Blender's step |
|---|---|
| Select All, Deselect, Invert Selection | (De)select All — one operator, `select_all`, objects and meshes |
| Toggle Edit Mode | Edit Mode — `editmode_toggle` in and out, and `mode_set` into Edit Mode and back to Object Mode, each push a step of that name |
| Duplicate (Edit Mode) | Add Duplicate (`mesh.duplicate_move`); Duplicate Objects in Object Mode |
| Import Model | Import Wavefront OBJ (`wm.obj_import`, measured); the other importers' rows are held to their operators' names (Import glTF 2.0, Import USD, …) |
| Add Lattice | Add Object (`object.add`) |
| New Shape from Mix | Add Shape Key |
| Every mesh operator measured (Extrude, Merge, Separate, Mark Seam, Smooth Vertices, …) | its name, as in the Mesh menu table above |
| Delete, Shade Smooth, Shade Flat, Add Modifier, Move, Rotate, Resize, Hide Selected, Reveal Hidden, Clear Parent, Set Origin, Apply Object Transform, Join, the Select menu's | the operator's name |
| Sculpt Stroke | the brush's step, as Blender names it: Draw Brush, Grab Brush, Inflate Brush, … (read from Blender's stack when the stroke ends; `brush_stroke`'s own name, Sculpt, before) |
| (new, round 4 group 2) Weight Paint and Vertex Paint, in and out | Weight Paint Mode, Vertex Paint Mode — `mode_set` into either and back to Object Mode, measured with its undo on |
| (new) a Weight Paint or Vertex Paint stroke | Weight Paint, Vertex Paint — the Global Undo step `paint.weight_paint` / `paint.vertex_paint` push, read from Blender's stack when the stroke ends |

Every operator measured recorded its own name (`get_rna_type().name`) but one
kind: a mode change. `object.mode_set` is named "Set Object Mode", and records
the mode — Edit Mode, Sculpt Mode, Weight Paint Mode, Vertex Paint Mode.

**Held to the operator's name, not measured.** Operators that poll for a 3D
View could not be called with their undo on: under the borrowed startup 3D
View, Blender 5.2.1 crashes in `ED_area_type_hud_ensure` while building a
redo panel for the background session (desktop only — hide_view_set,
camera_to_view, object_as_camera and snap_selected_to_grid each crashed the
probe; the app never makes such a call). Their steps are the operator's name,
as every measured operator's was; none of them is a mode change. The same goes
for the operators the check names but does not call: Image Paint
(`paint.image_paint`), Flip (Distortion Free), Remove Shape Key, the other
importers.

| Was | Step |
|---|---|
| Aim Camera at View | Align Camera to View (`view3d.camera_to_view`) |
| Set Scene Camera | Set Active Object as Camera (`view3d.object_as_camera`, the camera's panel) |
| Snap Cursor, Snap Selection | Snap Cursor to Selected, Snap Selection to Grid, … (`view3d.snap_*`) |
| Show/Hide in Object Mode | Show Hidden Objects, Hide Objects |
| Texture Paint | Image Paint |
| Flip (Distortion) | Flip (Distortion Free) |
| Apply All Shape Keys, Delete All Shape Keys | Remove Shape Key |

**A field edit: the field's text, read from Blender's source.** An edit made
in a field of Blender's interface is recorded under the text the field draws,
up to its colon, and a field with no text of its own (a swatch, an icon) under
its tooltip's first line (`ui_apply_but_undo`, interface_handlers.cc, the
bundled 5.3 source). A background Blender has no field to press, so none of
these is measured. The app names a field's step after the field's own text as
it shows it: Focal Length, Clip Start, Power, Color, Resolution U, Value, Range
Min, Max, Relative To…; the Timeline's Start and End (were Start Frame and End
Frame, the properties' names, which no field there shows — Blender's Timeline
draws all four as Start and End, space_time.py, 5.2.1); the Object tab's
Visibility ▸ Show In ▸ Viewports, "Viewports" (was "Show in Viewports", in a
Relations panel Blender does not have); the Render panel's Scene camera,
"Camera"; an edit in the Data API browser, the property's name. Where
Blender's field has no text the app's control does — the Outliner's toggles,
the Timeline's preview-range switch — the app's step is the property's name
(Disable in Viewports, Hide in Viewport, Disable in Renders, Use Preview
Range), where Blender, by its source, would use the tooltip; neither is
measured.

**The app's own.** Steps Blender records otherwise, or not at all:

- A modifier setting's edit is "Edit Modifier", from the Modifiers panel, the
  modifier rows of the 3D View and the Sculpt header. Blender records the
  field's text, as above.
- Snap ▸ Cursor to World Origin and Cursor to Selected push a step in the
  app's history named after the operator; Blender records none for them
  (measured: neither pushed a step). The app's history keeps one for every
  Snap row (TransformTools.swift, `SnapAction.undoName`).
- Run Script (a script run from the Scripting tab, one step for the whole
  script) is the app's.

### Pick selections and the Select menu (round 4, group 4)

Blender's Alt+click, Ctrl+Alt+click, Ctrl+click and L are keys, not rows, in
Blender. Here they are also rows of the Select menu and segments of a pick
bar over the 3D View while editing, each by its operator's name
(`get_rna_type().name`, 5.2.1), which is also its redo panel's title and its
undo step: **Loop Select**, **Edge Ring Select**, **Pick Shortest Path**,
**Select Linked**, and **Select** (`view3d.select`) for an ordinary tap. What
Shift adds in Blender's keymap is named by the property it sets: **Toggle
Select** (loops and rings), **Fill Region** (paths), **Deselect** (Linked),
and **Toggle Selection** for an ordinary click. The Mac menu bar's Select
menu has L as Select Linked and Shift+L as **Select Linked (Deselect)** — the
operator's name with its property's, since two rows cannot share one title —
and Ctrl+L as Select Linked ▸ Linked. That row's redo panel (Select Linked
All) draws **Delimit** as Blender's does since October 20, a toggle per item —
**Normal**, **Material**, **Seam**, **Sharp**, **UVs** (5.2.1's enum items, held
to `get_rna_type()` by the selectpick check) — where it was one choice from a
list.

The Select menu rows that were drawn greyed are Blender's now: Next Active
and Previous Active (Select Next Element / Select Previous Element), Side of
Active (Select Axis, with Axis Mode, Axis Sign, Axis, Threshold), By
Attribute (Select by Attribute), and Select Grouped with its eleven types
(Children, Immediate Children, Parent, Siblings, Type, Collection, Hook,
Pass, Color, Keying Set, Light Type; its step Select Grouped). The names
checks hold each to 5.2.1 (`select-pick`, `select-grouped`,
`select-object-menu` rows).

### The Sidebar, orientations and the gizmo's redo panel (round 4, group 5)

| Was | Blender's name | Where it is read |
|---|---|---|
| N opened Properties | N is **Sidebar** (View ▸ Sidebar); Properties keeps its row in More and in the menu bar | Blender's keymap and View menu |
| (no picker on screen; ToolHeader's never showed) | **Orientation**: Global, Local, Normal, Gimbal, View, Cursor, Parent | `TransformOrientationSlot.type`'s RNA name and enum items, 5.2.1 |
| SidebarN's Item tab: Transform, Dimensions and Relations panels | **Transform**, holding Location, Rotation, Scale and **Dimensions:** in Object Mode; Relations went (Blender's Item tab has no such panel) | `view3d_panel_transform`, view3d_buttons.cc |
| (Edit Mode had no fields) | **Median:** / **Vertex:**, **X:**, **Y:**, **Z:**, **Global**, **Local**, **Vertex Data:** / **Vertices Data:**, **Bevel Weight:** / **Mean Bevel Weight:**, **Vertex Crease:** / **Mean Vertex Crease:**, **Edge Data:** / **Edges Data:**, **Crease:** / **Mean Crease:** — singular for one, Mean for several, as Blender switches them | `v3d_editvertex_buts` in the 5.3 source; each string also in 5.2.1's binary |
| A gizmo drag: no redo panel | **Move**, **Rotate**, **Resize** panels, their rows by the RNA names: Move (X, Y, Z), Angle, Axis, Scale (X, Y, Z), Orientation, Mirror Editing, Proportional Editing, Proportional Falloff, Proportional Size, Connected | the operators' `bl_rna` and `transform_poll_property`, which hides Constraint Axis and, while Proportional Editing is off, the four after it |
| The drag's readout "along X" | "along global X", "around normal Z" — Blender's header puts the orientation's name in | `transform_orientations_spacename_get` |

The Item tab's edits are fields of Blender's interface, so their undo steps
keep the fields' own words, as the convention above has it: X, Y, Z, Bevel
Weight, Mean Bevel Weight, Vertex Crease, Mean Vertex Crease, Crease, Mean
Crease (Blender records the button's text with its value, "X:1 m"); the
Dimensions fields X, Y, Z by the same rule — they are Blender's "X:", "Y:",
"Z:" buttons too (they were recorded as "Dimensions" until the review's fixes
of October 20). A gizmo drag's step is the operator's name, as it was: Move,
Rotate, Resize.

### The Mesh menu's search-only rows (round 4, group 6)

Every row is its Blender menu's label, in that menu's order; the redo panel
and the undo step are the operator's name (`get_rna_type().name`, 5.2.1);
the panel's rows are its RNA properties' names.

| Menu ▸ row | Title and undo step | Panel |
|---|---|---|
| Merge ▸ At Center, At Cursor, Collapse, At First, At Last | Merge | Type (At Center … At Last), UVs — the field was "Merge" |
| Delete ▸ Vertices, Edges, Faces, Only Edges & Faces, Only Faces | Delete | none (Type is hidden in Blender's) |
| Delete ▸ Limited Dissolve (and Clean Up's) | Limited Dissolve | as before |
| Delete ▸ Collapse Edges & Faces | Collapse Edges & Faces | none |
| Delete ▸ Edge Loops | Delete Edge Loop | Face Split |
| Vertex ▸ Extrude to Cursor or Add | Extrude to Cursor or Add (the step; no panel, as Blender's has none) | — |
| Vertex ▸ Connect Vertex Pairs | Vertex Connect | none |
| Vertex ▸ Rip Vertices, Rip Vertices and Fill | (greyed, the reason as subtitle) | — |
| Vertex ▸ Rip Vertices and Extend | Extend Vertices | Move X, Y, Z |
| Vertex ▸ Smooth Vertices (Laplacian) | Laplacian Smooth Vertices | Number of iterations to smooth the mesh, Lambda factor, Lambda factor in border, Smooth X/Y/Z Axis, Preserve Volume |
| Edge ▸ Rotate Edge CW, Rotate Edge CCW | Rotate Selected Edge | Counter Clockwise |
| Face ▸ Intersect (Knife) | Intersect (Knife) | Source, Separate Mode, Solver, Merge Threshold (Float only) |
| Face ▸ Intersect (Boolean) | Intersect (Boolean) | Boolean Operation, Solver, Swap, Self Intersection, Merge Threshold (Float only) |
| Face ▸ Weld Edges into Faces | Weld Edges into Faces | none |
| Mesh ▸ Convex Hull | Convex Hull | its thirteen properties |
| Mesh ▸ Snap to Symmetry | Snap to Symmetry | Direction, Threshold, Factor, Center, Topology Mirror |
| Normals ▸ Recalculate Outside, Recalculate Inside | Recalculate Normals | Inside (was "Facing: Outside / Inside") |
| Normals ▸ Set from Faces | Set Normals from Faces | Keep Sharp Edges |
| Normals ▸ Point to Target… | Point Normals to Target | Invert, Align, Target, Spherize, Spherize Strength (with Spherize) |
| Normals ▸ Average ▸ Custom Normal, Face Area, Corner Angle | Average Normals | Type, Weight and Threshold (not for Custom Normal) |
| Normals ▸ Smooth Vectors | Smooth Normals Vectors | Factor |
| Extrude ▸ Extrude Manifold | Extrude Manifold | Move Z (the normal's, its constrained axis) |

The toolbar's Poly Build and Rip Region keep Blender's names, greyed, with
tooltips saying what was measured (MeshMenuTools.polyBuildRefusal,
ripRefusal). Blender draws "Point to Target..."; the app "Point to Target…".

### Collections, constraints, the Object menu's rows, Local View (round 4, group 7)

Each row is its Blender menu's label (5.2.1's `draw()`, tests/names/reference;
Mirror's rows read in space_view3d.py, which the reference's stand-in layout
could not draw past its first); each redo panel and undo step is the
operator's name; each toggle's step is its property's name.

| Where | Name | Blender's source |
|---|---|---|
| Object ▸ Mirror | Interactive Mirror (greyed: it waits for an axis key), X Global, Y Global, Z Global, X Local, Y Local, Z Local | `VIEW3D_MT_mirror`; panel Mirror: Orientation, Constraint Axis X Y Z |
| Object ▸ Transform | Randomize Transform, Align Objects | `VIEW3D_MT_transform_object`; their panels' fields are the operators' properties' names |
| Object ▸ Collection | Move to Collection, Link to Collection (each: New Collection, the Scene Collection, its collections), Move to New Collection / Link to New Collection's Name and Create | `OBJECT_MT_move_to_collection` / `_link_to_collection` (object_edit.cc), `move_to_collection_invoke`'s dialog |
| Object ▸ Relations | Make Single User ▸ Object, Object & Data, Object & Data & Materials, Materials, Object Animation, Object Data Animation | `VIEW3D_MT_make_single_user` |
| Object ▸ Modifiers | Copy Modifiers to Selected Objects | `VIEW3D_MT_object_modifiers` |
| Object ▸ Constraints | Add Constraint (with Targets), Copy Constraints to Selected Objects, Clear Object Constraints | `VIEW3D_MT_object_constraints` |
| Object ▸ Link/Transfer Data | Link Object Data … Copy Shadow Linking, Copy UV Maps (step Transfer UV Maps) | `VIEW3D_MT_make_links` |
| View ▸ Local View (More, the menu bar) | Toggle Local View (/), Remove from Local View; steps Local View, Remove from Local View | `VIEW3D_MT_view_local` |
| The viewport's text | "User Perspective (Local)" in Local View; "(frame) *active collection* \| *object*" (was "(1) Collection") | `draw_selected_name`, the view name (view3d_draw.cc) |
| Outliner | Scene Collection; New Collection, Delete, Delete Hierarchy, Rename; toggles Exclude from View Layer, Hide in Viewport, Disable Selection, Disable in Renders | `outliner.collection_new`, `outliner.delete`, `outliner.collection_hierarchy_delete`'s names; the properties' names |
| Properties ▸ Constraints | Add Object Constraint and its four columns (Motion Tracking, Transform, Tracking, Relationship) with the 27 object types; a panel's Enabled, Duplicate, Copy to Selected, Apply, Move to First, Move to Last, Delete Constraint, Move Constraint Up / Down, Set Inverse, Clear Inverse, Animate Path (step Auto Animate Path) and the fields' texts (Target, Axis, Invert, Offset, Mix, Owner, Track Axis, Up, Influence, …) | properties_constraint.py, `Constraint.type`'s items (Pivot is the constraint's own name), the operators' names |
| Properties ▸ Object ▸ Relations | Collection: the collections the object is in | was a label reading "Collection" |

### Add Modifier, text objects, reference images (round 4, group 8)

Add Modifier is Blender's menu for the object's type, row for row
(`ModifierCatalog`, held to `OBJECT_MT_modifier_add` and its Edit, Generate,
Deform, Normals, Physics and Color menus drawn by desktop 5.2.1 for thirteen
object types in `run-modkinds-blender-check.sh`); each row's label is the
`Modifier.type` item's name, but Blender's own "Array (Legacy)". The new rows'
fields are their panels' texts (MOD_*.cc `panel_draw`); each button's undo
step is its operator's name.

| Where | Name | Blender's source |
|---|---|---|
| Properties ▸ Modifiers ▸ Add Modifier | Edit, Generate, Deform, Normals, Physics (Color on Grease Pencil) and every row; Array, Curve to Tube, Scatter on Surface (Essentials node groups, greyed without the library); Array (Legacy); Geometry Nodes | properties_data_modifier.py |
| Curve | Curve Object, Deform Axis (X, Y, Z, -X, -Y, -Z) | MOD_curve.cc |
| Wireframe | Thickness, Offset, Boundary, Replace Original, Thickness ▸ Even, Relative, Crease Edges, Weight, Material Offset, Vertex Group ▸ Factor | MOD_wireframe.cc |
| Skin | Branch Smoothing, Symmetry X Y Z, Smooth Shading, Create Armature, Mark Loose, Clear Loose, Mark Root, Equalize Radii (steps Skin Armature Create, Skin Mark/Clear Loose, Skin Root Mark, Skin Radii Equalize) | MOD_skin.cc, the operators' names |
| Hook | Object, Strength, Falloff ▸ Type (No Falloff …), Radius, Uniform Falloff; in Edit Mode Reset, Recenter, Select, Assign (steps Reset Hook, Recenter Hook, Select Hook, Assign to Hook) | MOD_hook.cc |
| Armature | Object, Preserve Volume, Multi Modifier, Bind To ▸ Vertex Groups, Bone Envelopes | MOD_armature.cc |
| Surface Deform, Mesh Deform | Target / Object, Interpolation Falloff, Strength, Sparse Bind / Precision, Dynamic; Bind and Unbind (steps Surface Deform Bind, Mesh Deform Bind) | MOD_surfacedeform.cc, MOD_meshdeform.cc |
| Data Transfer | Source, Object Transform, Mix Mode, Mix Factor, Vertex Data, Edge Data, Face Corner Data, Face Data with their types and Mapping; Generate Data Layers (step Transfer Mesh Data Layout) | MOD_datatransfer.cc |
| Normal Edit, Mask, Build | Mode (Radial, Directional), Target, Parallel Normals, Mix ▸ Mix Mode, Mix Factor, Max Angle, Lock Polygon Normals, Offset; Mode (Vertex Group, Armature), Armature, Smooth, Threshold; Start Frame, Length, Reversed, Randomize, Seed | MOD_normal_edit.cc, MOD_mask.cc, MOD_build.cc |
| Properties ▸ Data, a text | Body Text (the property's name; the field Tab opens), Shape ▸ Resolution Preview U, Fill Mode; Geometry ▸ Offset, Extrude; Bevel ▸ Depth, Resolution; Transform ▸ Size, Shear; Alignment ▸ Horizontal, Vertical (Middle is `CENTER`); Spacing ▸ Character Spacing, Word Spacing, Line Spacing, Offset X, Y. Steps: each row's text | properties_data_curve.py |
| Add ▸ Image | Reference..., Background..., Mesh Plane..., Empty Image, in Blender's order; steps Add Empty Image/Drop Image to Empty, and Import Images as Planes for Mesh Plane... | `VIEW3D_MT_image_add`, the operators' names (`image.import_as_mesh_planes` is "Import Images as Planes") |
| Properties ▸ Data, an empty | Empty ▸ Display As, Size, Offset X, Y, Depth (Default, Front, Back), Side (Both, Front, Back), Show In ▸ Orthographic, Perspective, Only Axis Aligned, Opacity; Image | properties_data_empty.py |

Kept as the app's: Photos and Files, the choice of where Reference...,
Background... and Mesh Plane... take the picture from (Blender opens its own
file browser), and the simulator's note under a modifier its stand-in draws
the mesh without ("The simulator draws the mesh without this modifier:
Blender on a device builds it"), which Blender has no counterpart of.

### The Cursor and Measure tools, the measurement overlays (round 4, group 9)

| Where | Name | Blender's source |
|---|---|---|
| The toolbar | Cursor, Measure (they were greyed with "Needs a placeable 3D cursor gizmo" and "Needs a ruler gizmo") | `_defs_view3d_generic.cursor` / `.ruler` |
| The Cursor's bar | Surface Project, Orientation ▸ None, View, Transform, Geometry | `view3d.cursor3d`'s `use_depth` and `orientation` (RNA names and items) |
| The Cursor's drag | step Move | `transform.translate`'s name (Blender's Cursor drag is that operator) |
| The Measure tool's bar, X, Delete | Ruler Remove | `view3d.ruler_remove`'s name |
| More ▸ Viewport Overlays | Text ▸ Statistics | `VIEW3D_PT_overlay_text`, `show_stats` drawn as "Statistics" |
| More ▸ Mesh Edit Mode (in Edit Mode) | Measurement ▸ Edge Length, Edge Angle, Face Area, Face Angle | `VIEW3D_PT_overlay_edit_mesh`, `VIEW3D_PT_overlay_edit_mesh_measurement` |
| The Statistics overlay | Objects, Vertices, Edges, Faces, Triangles | `ED_info_draw_stats` (info_stats.cc) |

The Measure bar's hint and the Cursor bar's hint are the app's own sentences
(Blender says the same in the tools' tooltips); the names check holds the
labels above to 5.2.1's RNA and its own `space_view3d.py`.

## Names the app keeps as its own

Blender has nothing these could be named after:

- **More** — the 3D View bar's overflow menu. Every row in it is Blender's.
- **Image to 3D Model…** and its sheet (Full 3D, Relief, Cut out the subject,
  Detail, Create Model, Download Model…) — TripoSG, not a Blender feature.
- **The Showcase**, and the Scripting tab's own: Scripts, Examples, Options,
  Run Scripts Off the Main Thread, Stop, New Script and Save Script (files in
  the app's Documents, not text blocks), Find…, Next Error, Fold, Unfold,
  Actual Text Size, Switch Editor and Console, Copy Console and Clear Console,
  and the shell's commands.
- **Share Saved File…** — the system share sheet.
- **The Render panel's Draft, Good and Best**, and rendering the 3D
  Viewport's own viewpoint through a temporary camera.
- **Add Multires and Subdivide** — Add Modifier ▸ Multiresolution and its
  Subdivide in one button, in the sculpt header.
- **Curve ▸ Subdivide ▸ 1 Cut … 4 Cuts** — Blender's Subdivide asks for the
  number of cuts in its redo panel; here the row picks it.
- **Set Origin ▸ Origin to Geometry (Bounds)** — Blender reaches
  `center='BOUNDS'` through the redo panel these rows do not get.
- **The Data tab's Mesh and Dimensions panels** — counts and sizes read back
  from Blender; Blender's Data tab has no such panel. Dimensions' fields are
  typed in Object Mode since round 4, group 5, and write as Blender's N panel
  does; their undo steps are X, Y and Z, the buttons' words. In Edit Mode the
  panel shows Blender's numbers without fields, as Blender's Item tab offers
  no Dimensions there.
- **Edit Mode's Show/Hide ▸ Reveal Hidden** is kept *because it is Blender's*:
  the round's brief listed it as the app's own, but 5.2.1's Show/Hide menu
  draws `mesh.reveal` by its name, "Reveal Hidden" (Object Mode's row is
  Show Hidden Objects).

Where the app still differs from Blender, said rather than hidden (round 4's
review, October 19):

- **The Mac menu bar's Script menu** gathers rows Blender's Text Editor keeps
  in three menus (Text ▸ Run Script, Edit ▸ Find & Replace and Jump To,
  Format ▸ Toggle Comments and Unindent), so it has none of their names; the
  rows have Blender's.
- **The camera's Cameras panel** holds Blender's View ▸ Cameras rows for this
  camera (Set Active Object as Camera, Align Active Camera to View, View
  Camera); Blender's camera properties have no such panel, and the panel is
  named after the menu.
- **Shear's Axes row** in the redo panel is Blender's Axis and Axis Ortho in
  one, so that no choice pairs an axis with itself ("Along X, by Y", …): the
  one field the names check lets differ from its property's name
  (`FIELD_EXCEPTIONS`).
- **The Animation menu's pairs** — Frame Offset, Jump to Endpoint, Jump to
  Keyframe and Play Animation, each twice, one per direction — carry the
  operator's one name, as Blender's keymap lists both under it; the key glyph
  tells them apart, and VoiceOver reads each pair alike.
- **Refusals that say "Blender's 3D View"** name Blender's editor by the app's
  old word for it; Blender's own is 3D Viewport (the Render panel's row says
  so). The sentences are in eight of the app's modules and some checks match
  them; left for a pass that changes them together.

## The checks

- `scripts/run-names-tests.sh` (host): `tests/names/scan.py` reads every
  string literal in `Sources/` and the Python the app ships, comments left
  out, and fails if one of the old names above comes back (it is first run on
  snippets that carry them, and must catch them); `tests/names/verify.py`
  holds every name `tests/names/main.swift` prints — the Mesh menu's groups
  and rows with their operators and order, the Select menu, Snap, Show/Hide,
  Apply, the Curve and Lattice menus, Import and Export, the toolbar's tools,
  the workspace tabs — to the reference menus and toolbar.
  `scan.py` also holds the 3D View's own steps to `UndoStep`
  (Sources/BlenderLocalBridge/UndoSteps.swift): a call in BlenderLocalUI or
  BlenderLocalApp that runs one of their builders takes its `undo:` from
  there, never a literal or a name the UI defines, and no literal there
  repeats one of its names (snippets with round 4's review's two edits, "Enter
  Edit" and "Duplicate Mesh", must be caught first). `verify.py` holds each of
  those steps' calls to the Python the button sends.
- `scripts/run-names-blender-check.sh` (desktop Blender): each redo panel's
  title against its operator's name, each of its fields against its
  property's name, each undo step against the step Blender records for the
  same call (43 calls measured; the app's names read from the dump), each
  choice against its enum item, and the simulator's brushes against the
  Essentials library. It also runs tests/names/app_steps.py — the script that
  measures in the app — in the app's script context (a window and its screen,
  no area), which has to measure what the calls above did, and
  `app_steps_compare.py` on its JSON.
- In the app: `-eval64` with app_steps.py (prefixed `STEPS_RUN = True`) writes
  Blender's own steps to `blenderlocal-app-steps.json` in the app's temporary
  folder; `python3 tests/names/app_steps_compare.py <names.json> <that file>`
  holds the app's names to them.
