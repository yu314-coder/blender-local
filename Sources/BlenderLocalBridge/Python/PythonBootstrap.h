#pragma once
#include <stdbool.h>

// Embedded CPython, started from the copy of the interpreter inside the app
// bundle. Nothing here touches the network: the stdlib, the extension modules
// and the bpy shim are all bundled, so scripting works with the device offline.

#ifdef __cplusplus
extern "C" {
#endif

/// Starts the interpreter. `home` is the bundled Python prefix and
/// `pythonpath` is a colon-separated search path. Returns 0 on success.
int bk_python_start(const char *home, const char *pythonpath,
                    const char *executable);

/// Runs `source` and returns everything it wrote to stdout/stderr, including
/// tracebacks. The caller owns the returned buffer. `*ok` is set to 0 if the
/// code raised.
char *bk_python_run(const char *source, int *ok);

/// "3.14.0 (…) [Clang …]" — whatever the embedded interpreter reports.
const char *bk_python_version(void);

void bk_python_stop(void);
// Cooperative cancellation, checked at Python trace boundaries.
void bk_python_request_interrupt(void);

// ---------------------------------------------------------------------------
// Implemented in Swift (@_cdecl) and called by the `_blenderkit` module below,
// which is what the bundled `bpy` shim is written against.
// ---------------------------------------------------------------------------

int  bk_scene_add_primitive(const char *kind, double x, double y, double z,
                            char *out_name, int out_cap);
int  bk_scene_delete_selected(void);
int  bk_scene_duplicate_selected(void);
void bk_scene_select_all(int select);
int  bk_scene_select(const char *name, int selected);
int  bk_scene_set_active(const char *name);
void bk_console_emit(const char *text);

/// Ask CPython to give the interface a turn.
///
/// Implemented with `Py_AddPendingCall`, which is the one CPython entry point
/// documented as safe to call from a thread that does not hold the GIL. The
/// callback it schedules runs on whichever thread is executing bytecode — the
/// main one — at the next instruction boundary, which is exactly where it is
/// safe to run the run loop for a moment. Returns 0 if the call was queued.
///
/// This is how a script that computes silently for a second still looks alive:
/// without it the only thing that pumps is output, so a loop that prints
/// nothing draws nothing.
int bk_request_pump(void);

/// Runs the run loop briefly. Implemented in Swift.
void bk_pump_runloop(void);
int  bk_scene_material_get(const char *obj, const char *key, double *out);
int  bk_scene_add_torus(double x, double y, double z,
                        double major, double minor,
                        int majorSeg, int minorSeg,
                        char *outName, int cap);
int  bk_scene_object_count(void);
int  bk_scene_object_name(int index, char *out, int cap);
int  bk_scene_get_vec(const char *name, const char *prop, double *x, double *y, double *z);
int  bk_scene_set_vec(const char *name, const char *prop, double x, double y, double z);
int  bk_scene_object_kind(const char *name, char *out, int cap);
/// Cameras, lights and empties: the settings Blender draws them from, as a
/// `key=value;...` record (ObjectDisplay.swift). `bk_sync_display` describes the
/// object the mirror has just pushed; the rest serve the shim.
/// `bk_scene_object_display` returns 1 with a display, 0 without, -1 for no object.
int  bk_sync_display(const char *name, const char *type, const char *data_name,
                     const char *record);
/// `bk_sync_modifiers` hands over the object's modifier stack as one
/// `kind=…;name=…;key=value|kind=…` record, so the Modifiers panel shows what
/// Blender actually has rather than only what this app added itself.
int  bk_sync_modifiers(const char *name, const char *record);
/// `bk_sync_local` hands over the object's own channels — location, rotation
/// as (w, x, y, z), scale, ten doubles — for Object ▸ Apply. During a mirroring
/// pass it describes the object just pushed; otherwise the one on screen, and
/// a name not on screen is skipped (0), as `anim_frame` skips it.
int  bk_sync_local(const char *name, const double *values10);
/// `bk_sync_channels` hands over what the Transform fields show and write —
/// location, rotation mode, rotation in that mode, scale, eleven doubles, no
/// deltas — onto the same object `bk_sync_local` would describe.
int  bk_sync_channels(const char *name, const double *values11);
/// `bk_sync_relations` hands over the object's parent (empty for none) and the
/// names of every object its transform or geometry depends on, `count` of them.
int  bk_sync_relations(const char *name, const char *parent,
                       const char *const *names, int count);
/// `bk_sync_knots` hands over a curve's control points in its own space,
/// three floats each: what Blender snaps a curve with no surface to.
int  bk_sync_knots(const char *name, const float *points, int count);
/// `bk_sync_points` hands over a curve's or a lattice's settings and, while it
/// is edited, its control points: `count` points of three floats and a byte of
/// flags each, and `line_count` indices, two per line. `during_pass` 0 names
/// the object on screen rather than one the pass pushed.
int  bk_sync_points(const char *name, const char *record, const float *positions,
                    const unsigned char *flags, int count,
                    const unsigned int *lines, int line_count, int during_pass);
/// `bk_sync_groups` hands over a mesh's vertex groups and shape keys as one
/// `kind=head;…|kind=group;…|kind=key;…` record (`MeshGroups`): during a pass
/// onto the object the pass pushed, with `during_pass` 0 onto the one on screen.
int  bk_sync_groups(const char *name, const char *record, int during_pass);
/// `bk_sync_edges` hands over the edges of the mesh just pushed — two vertex
/// indices each, `count` indices in all — for a mesh with no faces to draw.
int  bk_sync_edges(const char *name, const unsigned int *edges, int count);
/// `bk_sync_uvs` hands over the active UV map and the seams of the mesh just
/// pushed: the loop behind each triangle corner (`loop_count` of them, or none
/// for no UV map), two floats per loop, and two vertex indices per seam edge.
int  bk_sync_uvs(const char *name, const char *map_name,
                 const unsigned int *loops, int loop_count,
                 const float *uvs, int uv_count,
                 const unsigned int *seams, int seam_count);
/// `bk_sync_uv_layout` hands over the UV map Blender's UV Editor draws for the
/// mesh just pushed when that is not the map the pushed (evaluated) mesh
/// carries: the object's own mesh, before its modifiers — three floats per
/// vertex, three indices per triangle, then the map as `bk_sync_uvs` takes it.
int  bk_sync_uv_layout(const char *name, const char *map_name,
                       const float *positions, int position_count,
                       const unsigned int *triangles, int triangle_count,
                       const unsigned int *loops, int loop_count,
                       const float *uvs, int uv_count,
                       const unsigned int *seams, int seam_count);
int  bk_scene_add_object(const char *type, const char *name, double x, double y, double z,
                         const char *data_name, const char *record, int select,
                         char *out_name, int out_cap);
int  bk_scene_object_display(const char *name, char *out_type, int type_cap,
                             char *out_data, int data_cap, char *out_record, int record_cap);
int  bk_scene_set_object_display(const char *name, const char *data_name, const char *record);
int  bk_scene_rename(const char *old_name, const char *new_name, char *out, int cap);
int  bk_scene_remove(const char *name);
int  bk_scene_active_name(char *out, int cap);
/// The mode the interface is in, as Blender spells it ("OBJECT", "EDIT", …).
int  bk_scene_mode(char *out, int cap);
int  bk_scene_is_selected(const char *name);
int  bk_scene_bounds(const char *name, double *out6);
int  bk_scene_get_visible(const char *name, int which);
int  bk_scene_set_visible(const char *name, int visible, int which);
/// One `bpy.ops.transform` call as JSON (TransformOperation(json:)); returns
/// how many selected elements moved, or -1 with the reason in `out`.
int  bk_scene_transform_operator(const char *json, char *out, int cap);
int  bk_scene_mesh_counts(const char *name, int *verts, int *tris);
int  bk_scene_modifier_add(const char *obj, const char *kind, char *out, int cap);
int  bk_scene_modifier_remove(const char *obj, const char *mod);
int  bk_scene_modifier_list(const char *obj, char *out, int cap);
int  bk_scene_modifier_set(const char *obj, const char *mod, const char *key,
                           double a, double b, double c);
/// A Boolean's `object` or a Shrinkwrap's `target`, by object name ("" for None).
int  bk_scene_modifier_set_object(const char *obj, const char *mod, const char *key,
                                  const char *other);
int  bk_scene_get_color(const char *obj, double *rgba);
int  bk_scene_set_color(const char *obj, double r, double g, double b, double a);

// --- scene mirroring: bpy.data -> the Metal viewport ---
// Blender owns the scene; these hand its evaluated meshes to the renderer.
void bk_sync_begin(void);
int  bk_sync_push(const char *name, const char *kind,
                  const double *matrix16,
                  const float *verts, int vcount,
                  const float *normals, int ncount,
                  const unsigned int *tris, int tcount,
                  int selected, int active, const float *rgba);
void bk_sync_end(void);
/// Blender's edit-mode selection on the object being edited, reported after
/// the meshes: select-mode bits (1 vertex, 2 edge, 4 face), a flag per vertex,
/// the polygon behind each triangle, a flag per polygon, two vertex indices per
/// edge, and a flag per edge. Empty buffers mean the viewport's mesh does not
/// line up with Blender's.
int  bk_sync_edit_selection(const char *name, int select_mode,
                            const unsigned char *vertex_selected, int vertex_count,
                            const unsigned int *triangle_polygons, int triangle_count,
                            const unsigned char *polygon_selected, int polygon_count,
                            const unsigned int *edge_vertices, int edge_vertex_count,
                            const unsigned char *edge_selected, int edge_count,
                            const unsigned char *vertex_hidden, int hidden_count,
                            const float *vertex_coordinates, int coordinate_count);
// Serves the shim's own mesh back to Python, so the same extraction code runs
// against the shim in the simulator as against Blender on device.
int  bk_scene_set_mode(const char *mode);
int  bk_scene_keyframe(const char *obj, const char *path, int frame, int insert);
int  bk_scene_set_frame(int frame);
void bk_scene_set_timeline(int start, int end, int current);
int  bk_scene_sculpt_stroke(const char *obj, double x, double y, double z,
                            double nx, double ny, double nz,
                            const char *brush, double radius, double strength);
int  bk_scene_mesh_select_all(int select);
int  bk_scene_mesh_op(const char *op, double amount);
int  bk_scene_join_selected(void);
int  bk_scene_modifier_apply(const char *name);
int  bk_scene_object_shade(int smooth);
int  bk_scene_object_op(const char *op, double amount);
int  bk_scene_uv_project(const char *obj, const char *kind, double *stretch, int *count);
int  bk_scene_material_set(const char *obj, const char *key, double a, double b, double c);
int  bk_scene_paint(const char *obj, double u, double v, double r, double g, double b,
                    double radius, double strength);
int  bk_scene_texture_info(const char *obj, int *w, int *h, int *painted);
int  bk_scene_mesh_arrays(const char *name, float *verts, int vcap,
                          float *normals, int ncap,
                          unsigned int *tris, int tcap,
                          int *vcount, int *tcount);

// --- animation: Resources/python/site/_blenderkit_anim.py and the timeline ---
// The scene's animation state, eleven ints and two doubles:
//   ints    start, end, current, use_preview, preview_start, preview_end,
//           auto_key, replace_keys, only_insert_available, only_selected, loop_mode
//   doubles subframe, fps
int  bk_anim_set_state(const int *ints, const double *doubles);
int  bk_anim_get_state(int *ints, double *doubles);
/// Every object's key columns: names joined by NUL, a count per name, the
/// frames and a selected flag per key in name order, then the scene's own.
int  bk_anim_set_keys(const unsigned char *names, int names_len,
                      const unsigned int *counts, int object_count,
                      const float *frames, const unsigned char *selected, int key_count,
                      const float *scene_frames, const unsigned char *scene_selected,
                      int scene_key_count);
/// A frame change: the frame, and the row-major world matrix (16 doubles) of
/// each named object it moved. Returns how many moved, or -1.
int  bk_anim_set_frame(int frame, double subframe,
                       const unsigned char *names, int names_len,
                       const double *matrices, int matrix_count);
/// One mesh a frame change deformed. Returns 1 if replaced, 0 if unchanged, -1.
/// `edges` (two indices each, `ecount` of them) for a mesh with no faces;
/// NULL and -1 for one with faces.
int  bk_anim_set_mesh(const char *name, const float *verts, int vcount,
                      const float *normals, int ncount,
                      const unsigned int *tris, int tcount,
                      const unsigned int *edges, int ecount);
void bk_anim_notice(const char *text);
/// Blender's sculpt mask on one object, one float per vertex of the mesh the
/// viewport draws; `count` 0 for none. Returns 0, or -1 with no such object.
int  bk_sculpt_set_mask(const char *name, const float *values, int count);
/// The shim's keyed channels on one object as "path:frame,frame" lines. With
/// no buffer, returns the length needed; -1 when there is no such object.
int  bk_anim_channels(const char *name, char *out, int cap);

// --- tool settings: Resources/python/site/_blenderkit_tools.py and the header ---
// Snapping, the pivot point, proportional editing, Auto Merge and the 3D
// cursor, as eleven ints and five doubles:
//   ints    use_snap, snap elements (bits), snap elements individual (bits),
//           snap target, transform pivot point, use_proportional_edit,
//           use_proportional_edit_objects, use_proportional_connected,
//           proportional_edit_falloff, use_mesh_automerge,
//           snap target selection (bits)
//   doubles proportional_size, cursor x, cursor y, cursor z, double_threshold
// The bit fields and the enum indices are _blenderkit_tools.ELEMENTS,
// .INDIVIDUAL, .TARGETS, .PIVOTS, .FALLOFFS and .SNAP_FLAGS, in that module's
// order.
int  bk_tool_set_state(const int *ints, const double *doubles);
int  bk_tool_get_state(int *ints, double *doubles);

#ifdef __cplusplus
}
#endif
