"""The Timeline's key and marker editing, run by the Blender it runs on.

scripts/run-timeline-blender-check.sh starts desktop Blender 5.2.1 with
`-b --factory-startup`: a window and a screen, no area in the context, as for
the bpy module on a device. Every string run here is the one the Swift sends
(tests/timeline/blender/main.swift); the app's modules are loaded from the
source tree, with a `_blenderkit` that records what the timeline is told.

For each edit: what it leaves — frames, selection, type, interpolation,
easing, handles, markers — against Blender's own operator run directly under
the startup screen's Timeline on a twin of the scene, or against Blender's
rules where it works by frame (a tap, a box, a marker tap); the timeline's
report of it; and one undo step through the app's own history
(`_blenderkit_undo`), undone and redone. Then the menus' rows against
Blender's menus as their `draw()` lays them out.
"""
import bpy, sys, types, json, os, io, contextlib, pathlib
from array import array

sys.dont_write_bytecode = True
ARGS = sys.argv[sys.argv.index('--') + 1:]
CALLS, WORK, MENUS = ARGS[0], ARGS[1], ARGS[2]
ROOT = pathlib.Path(__file__).resolve().parents[3]
SITE = ROOT / 'Resources' / 'python' / 'site'
HISTORY = os.path.join(WORK, 'Documents', '.blender-history')
fail = 0


def check(label, ok, detail=''):
    global fail
    print(('  PASS  ' if ok else '  FAIL  ') + label + ('' if ok else '  ' + str(detail)))
    if not ok:
        fail += 1


blocks = {}
for chunk in open(CALLS).read().split('#--'):
    chunk = chunk.strip()
    if chunk:
        head, _, body = chunk.partition('\n')
        blocks[head[4:].strip()] = body


class Bridge(types.ModuleType):
    """Stands in for the app's `_blenderkit`: keeps what the timeline is told."""

    def __init__(self):
        super().__init__('_blenderkit')
        self.keys = None
        self.markers = None

    def anim_keys(self, names, counts, frames, flags, scene_frames, scene_flags):
        def typed(code, raw):
            values = array(code)
            values.frombytes(raw)
            return list(values)
        names = names.decode().split('\0') if names else []
        counts, frames, flags = typed('I', counts), typed('f', frames), typed('B', flags)
        self.keys, offset = {}, 0
        for name, count in zip(names, counts):
            self.keys[name] = list(zip(frames[offset:offset + count], flags[offset:offset + count]))
            offset += count
        self.keys[''] = list(zip(typed('f', scene_frames), typed('B', scene_flags)))

    def anim_markers(self, names, cameras, frames, flags, lock):
        values = array('i')
        values.frombytes(frames)
        self.markers = dict(names=names.decode().split('\0') if names else [],
                            cameras=cameras.decode().split('\0') if cameras else [],
                            frames=list(values), flags=list(flags), lock=lock)

    def is_main_thread(self):
        # The checks run on desktop Blender's main thread.
        return True

    def __getattr__(self, name):
        # Any other call of the app's bridge does nothing here.
        if name.startswith('__'):
            raise AttributeError(name)
        return lambda *a, **k: None


bridge = Bridge()
sys.modules['_blenderkit'] = bridge
sys.path.insert(0, str(SITE))
import _blenderkit_anim as anim     # noqa: E402
import _blenderkit_keys as keys     # noqa: E402
import _blenderkit_undo             # noqa: E402

namespace = {'bpy': bpy}


def run(block, **fill):
    """A block as the bridge runs it: (error or None, what it printed)."""
    source = blocks[block]
    for key, value in fill.items():
        source = source.replace('@' + key.upper() + '@', str(value))
    printed = io.StringIO()
    try:
        with contextlib.redirect_stdout(printed):
            exec(compile(source, '<' + block + '>', 'exec'), namespace)
    except Exception as error:              # noqa: BLE001 - the failure is the finding
        return str(error).strip(), printed.getvalue()
    return None, printed.getvalue()


def ok(block):
    error, printed = run(block)
    if error:
        raise RuntimeError(block + ': ' + error)
    return printed


def timeline():
    window = bpy.context.window_manager.windows[0]
    area = next(a for a in window.screen.areas if a.type == 'DOPESHEET_EDITOR')
    region = next(r for r in area.regions if r.type == 'WINDOW')
    return bpy.context.temp_override(window=window, area=area, region=region)


# ---------------------------------------------------------------------------
# The scene
# ---------------------------------------------------------------------------

def fresh():
    if bpy.context.object and bpy.context.object.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    sc = bpy.context.scene
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj)
    # What the objects used, until nothing is left unused (a mesh holds its
    # material until it goes itself).
    for _ in range(3):
        for collection in (bpy.data.meshes, bpy.data.lights, bpy.data.cameras, bpy.data.materials,
                           bpy.data.actions):
            for block in list(collection):
                if block.users == 0:
                    collection.remove(block)
    sc.timeline_markers.clear()
    sc.animation_data_clear()
    if sc.world is not None:
        sc.world.animation_data_clear()
    sc.tool_settings.lock_markers = False
    sc.tool_settings.use_snap_anim = True
    sc.show_keys_from_selected_only = True
    sc.frame_start, sc.frame_end = 1, 60
    return sc


def cube(name, location):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([(0, 0, 0), (1, 0, 0), (0, 1, 0)], [], [(0, 1, 2)])
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = location
    return obj


def build():
    """Keys on an object (two channels sets), a light's data, a material's
    node tree, a shape key, the world; a hidden object and an unselected one
    the Timeline leaves out (Only Show Selected); three markers."""
    sc = fresh()
    c = cube('Cube', (0, 0, 0))
    for f in (1, 10, 20):
        c.location = (f, 0, 0)
        c.keyframe_insert('location', frame=f)
    c.rotation_euler.z = 1
    c.keyframe_insert('rotation_euler', index=2, frame=10)
    light = bpy.data.lights.new('Lamp', 'POINT')
    lamp = bpy.data.objects.new('Lamp', light)
    sc.collection.objects.link(lamp)
    for f in (5, 15):
        light.energy = f * 10
        light.keyframe_insert('energy', frame=f)
    ball = cube('Ball', (3, 0, 0))
    mat = bpy.data.materials.new('Paint')
    ball.data.materials.append(mat)
    socket = mat.node_tree.nodes['Principled BSDF'].inputs['Base Color']
    socket.keyframe_insert('default_value', frame=30)
    ball.shape_key_add(name='Basis')
    bump = ball.shape_key_add(name='Bump')
    bump.keyframe_insert('value', frame=25)
    hidden = cube('Hidden', (6, 0, 0))
    hidden.keyframe_insert('location', frame=40)
    other = cube('Other', (9, 0, 0))
    other.keyframe_insert('location', frame=45)
    if sc.world is None:
        sc.world = bpy.data.worlds.new('World')
    sc.world.keyframe_insert('color', frame=50)
    for name, frame in (('A', 10), ('B', 20), ('C', 35)):
        sc.timeline_markers.new(name, frame=frame).select = False
    for obj in sc.objects:
        obj.select_set(obj.name in ('Cube', 'Lamp', 'Ball'))
    hidden.hide_set(True)
    bpy.context.view_layer.objects.active = c
    sc.frame_set(10)
    # Every key unselected, as a fresh start.
    with timeline():
        bpy.ops.action.select_all(action='DESELECT')
    for f in all_curves():
        for k in f[2].keyframe_points:
            k.select_control_point = k.select_left_handle = k.select_right_handle = False
    return sc


def all_curves():
    """Every F-Curve in the file: (owner, path, curve), a material's node
    tree named after its material."""
    owners = [(o.name, o) for o in bpy.data.objects] + [(l.name, l) for l in bpy.data.lights] \
        + [(m.name, m) for m in bpy.data.materials] \
        + [(m.name + '.nodes', m.node_tree) for m in bpy.data.materials if m.node_tree] \
        + [(k.user.name + '.keys', k) for k in bpy.data.shape_keys] \
        + [(w.name, w) for w in bpy.data.worlds] + [(s.name, s) for s in bpy.data.scenes]
    out = []
    for label, owner in owners:
        bag = anim.channelbag(getattr(owner, 'animation_data', None))
        if bag is None:
            continue
        for fcurve in bag.fcurves:
            out.append((label, fcurve.data_path + '[%d]' % fcurve.array_index, fcurve))
    return out


def state():
    """What the keys and markers are: every curve's keys with what an edit
    may change, the markers, the frame and Snap."""
    curves = {}
    for owner, path, fcurve in all_curves():
        curves[owner + ':' + path] = [
            (round(k.co.x, 4), round(k.co.y, 4), bool(k.select_control_point or k.select_left_handle
                                                       or k.select_right_handle),
             k.type, k.interpolation, k.easing, k.handle_left_type, k.handle_right_type)
            for k in fcurve.keyframe_points]
    sc = bpy.context.scene
    markers = sorted((m.name, m.frame, m.select, m.camera.name if m.camera else '') for m in sc.timeline_markers)
    return dict(curves=curves, markers=markers, frame=sc.frame_current,
                snap=sc.tool_settings.use_snap_anim, lock=sc.tool_settings.lock_markers)


def selected():
    """The selected keys: {(owner:path, frame)}."""
    return {(name, k[0]) for name, ks in state()['curves'].items() for k in ks if k[2]}


def select_frames(frames, owners=None):
    for owner, path, fcurve in all_curves():
        for k in fcurve.keyframe_points:
            on = round(k.co.x, 4) in frames and (owners is None or owner in owners)
            k.select_control_point = k.select_left_handle = k.select_right_handle = on


def diff(a, b):
    out = []
    for key in sorted(set(a['curves']) | set(b['curves'])):
        if a['curves'].get(key) != b['curves'].get(key):
            out.append('%s: %s vs %s' % (key, a['curves'].get(key), b['curves'].get(key)))
    for key in ('markers', 'frame', 'snap', 'lock'):
        if a[key] != b[key]:
            out.append('%s: %s vs %s' % (key, a[key], b[key]))
    return '; '.join(out)[:900]


def twin(prepare, app_block, reference, label):
    """The app's block and Blender's own operator, each on a fresh scene
    prepared the same way: what they leave must be the same."""
    build()
    prepare()
    error, printed = run(app_block)
    app = state()
    build()
    prepare()
    with timeline():
        try:
            reference()
        except RuntimeError:
            pass
    blender = state()
    check(label, error is None and app == blender, error or diff(app, blender))
    return app


in_scope_owners = {'Cube', 'Lamp', 'Paint', 'Shader Nodetree', 'Key', 'World', 'Scene'}

# ---------------------------------------------------------------------------
print('\nwhat the Timeline lists, against Blender\'s own Timeline filter')
sc = build()
with timeline():
    bpy.ops.action.select_all(action='SELECT')
blender_scope = {name for name, _ in selected()}
select_frames(set())
mine = set()
for ch in keys.timeline_channels():
    for owner, path, fcurve in all_curves():
        if fcurve == ch.fcurve:
            mine.add(owner + ':' + path)
check('the same channels as Blender\'s Select All under its Timeline (Only Show Selected on)',
      mine == blender_scope, (sorted(mine ^ blender_scope)))
check('a hidden object and an unselected one are left out',
      not any(n.startswith(('Hidden:', 'Other:')) for n in mine))
check('the light\'s data, the material\'s nodes, the shape key and the world are in',
      all(any(n.startswith(p) for n in mine) for p in ('Lamp:', 'Paint.nodes:', 'Ball.keys:', 'World:')), sorted(mine))
sc.show_keys_from_selected_only = False
with timeline():
    bpy.ops.action.select_all(action='SELECT')
blender_scope = {name for name, _ in selected()}
select_frames(set())
mine = {o + ':' + p for o, p, f in all_curves() if any(f == ch.fcurve for ch in keys.timeline_channels())}
check('Only Show Selected off: the unselected object too, the hidden one still not',
      mine == blender_scope and any(n.startswith('Other:') for n in mine)
      and not any(n.startswith('Hidden:') for n in mine), sorted(mine ^ blender_scope))

# ---------------------------------------------------------------------------
print('\nthe report: a column a byte — selected, its type, partly selected')
build()
bridge.keys = None
keys.report()
check('every listed object\'s columns, a hidden one\'s not',
      set(bridge.keys) == {'Cube', 'Lamp', 'Ball', 'Other', ''}, sorted(bridge.keys))
check('Cube\'s columns are 1, 10, 20', [f for f, _ in bridge.keys['Cube']] == [1, 10, 20], bridge.keys['Cube'])
for owner, path, fcurve in all_curves():
    if owner == 'Cube' and path == 'location[0]':
        fcurve.keyframe_points[1].select_control_point = True
        fcurve.keyframe_points[1].type = 'BREAKDOWN'
    if owner == 'Cube':
        for k in fcurve.keyframe_points:
            if round(k.co.x) == 20:
                k.type = 'EXTREME'
keys.report()
flags = dict(bridge.keys['Cube'])
check('a column with one of its keys selected is selected and partly so (1 | 16)',
      flags[10] & 1 and flags[10] & 16, flags)
check('a Breakdown among Keyframes is drawn a Keyframe (nupdate_ak_bezt)', (flags[10] >> 1) & 7 == 0, flags)
check('a column all Extreme is Extreme (1 << 1)', (flags[20] >> 1) & 7 == 1 and not flags[20] & 1, flags)
check('the world\'s key is the scene\'s own', [f for f, _ in bridge.keys['']] == [50], bridge.keys[''])
bridge.markers = None
anim.report_markers()
check('the markers: names, frames, none selected, Lock Markers off',
      bridge.markers == dict(names=['A', 'B', 'C'], cameras=['', '', ''], frames=[10, 20, 35],
                             flags=[0, 0, 0], lock=0), bridge.markers)

# ---------------------------------------------------------------------------
print('\na tap, Shift and a box, by frame (action_select.cc\'s rules)')
build()
out = ok('CLICK_10')
sel = selected()
check('a tap on 10 selects every listed key on 10',
      sel == {(n, 10.0) for n in ('Cube:location[0]', 'Cube:location[1]', 'Cube:location[2]',
                                    'Cube:rotation_euler[2]')}, sorted(sel))
with timeline():
    bpy.ops.action.select_all(action='DESELECT')
bpy.context.scene.frame_set(10)
with timeline():
    bpy.ops.action.select_column(mode='CFRA')
check('the same keys as Blender\'s Column on Current Frame on 10', selected() == sel, sorted(selected() ^ sel))
check('and the report says so', bridge.keys is not None and dict(bridge.keys['Cube'])[10] & 1)
build()
select_frames({20.0, 45.0}, owners={'Cube', 'Other'})
ok('CLICK_10')
check('a tap replaces the selection — of the keys the Timeline lists',
      {f for _, f in selected()} == {10.0, 45.0} and ('Other:location[0]', 45.0) in selected(), sorted(selected()))
check('and leaves no channel selected (ACHANNEL_SETFLAG_CLEAR)',
      not any(f.select for o, p, f in all_curves() if o == 'Cube'))
ok('CLICK_20_SHIFT')
check('Shift+tap adds a column', {f for o, f in selected() if o.startswith('Cube')} == {10.0, 20.0})
ok('CLICK_10_SHIFT')
check('Shift+tap on a selected column takes it off (select_bezier_invert)',
      {f for o, f in selected() if o.startswith('Cube')} == {20.0})
out = ok('CLICK_EMPTY')
check('a tap beside every key deselects them', {f for o, f in selected() if not o.startswith('Other')} == set())
out = ok('CLICK_EMPTY')
check('again, with nothing to deselect, it says it changed nothing', blocks['UNCHANGED'] in out, out)
build()
ok('BOX_SET')
check('a box from 12 back to 4.5 selects 5 and 10', {f for _, f in selected()} == {5.0, 10.0}, sorted(selected()))
ok('BOX_ADD')
check('Shift extends it with 20', {f for _, f in selected()} == {5.0, 10.0, 20.0})
ok('BOX_SUB')
check('Ctrl takes 5 off again', {f for _, f in selected()} == {10.0, 20.0})

# ---------------------------------------------------------------------------
print('\nBlender\'s select operators, from the app\'s module, against the operators themselves')
ops = bpy.ops.action


def select_some():
    select_frames({10.0, 25.0})


for block, reference in (('SELECT_ALL', lambda: ops.select_all(action='SELECT')),
                         ('SELECT_NONE', lambda: ops.select_all(action='DESELECT')),
                         ('SELECT_INVERT', lambda: ops.select_all(action='INVERT')),
                         ('COLUMNS_KEYS', lambda: ops.select_column(mode='KEYS')),
                         ('COLUMN_CFRA', lambda: ops.select_column(mode='CFRA')),
                         ('BEFORE', lambda: ops.select_leftright(mode='LEFT', extend=False)),
                         ('AFTER', lambda: ops.select_leftright(mode='RIGHT', extend=False)),
                         ('SIDE_RIGHT_EXTEND', lambda: ops.select_leftright(mode='RIGHT', extend=True)),
                         ('LINKED', lambda: ops.select_linked()),
                         ('MORE', lambda: ops.select_more()),
                         ('LESS', lambda: ops.select_less())):
    twin(select_some, block, reference, blocks['LABEL_' + block] + ' (' + block + ')')

# ---------------------------------------------------------------------------
print('\nedits, from the app\'s module, against Blender\'s own operators and its rules')


def select_ten():
    select_frames({10.0})


app = twin(select_ten, 'MOVE_3', lambda: bpy.ops.transform.transform(mode='TIME_TRANSLATE', value=(3, 0, 0, 0)),
           'G by 3: Transform, TIME_TRANSLATE')
check('  the keys on 10 are on 13, the rest where they were',
      [k[0] for k in app['curves']['Cube:location[0]']] == [1.0, 13.0, 20.0], app['curves']['Cube:location[0]'])
app = twin(select_ten, 'MOVE_10', lambda: bpy.ops.transform.transform(mode='TIME_TRANSLATE', value=(10, 0, 0, 0)),
           'G by 10 onto 20: the moved key replaces the one there (Auto-Merge Keyframes)')
check('  location[0] keeps two keys, the moved one\'s value on 20',
      [(k[0], k[1]) for k in app['curves']['Cube:location[0]']] == [(1.0, 1.0), (20.0, 10.0)],
      app['curves']['Cube:location[0]'])
build()
select_ten()
ok('MOVE_2_4_UNSNAPPED')
check('Ctrl held (Snap turned round): a move by 2.4 is 2.4',
      [k[0] for k in state()['curves']['Cube:location[0]']] == [1.0, 12.4, 20.0], state()['curves']['Cube:location[0]'])
check('  and Snap is on again after it', bpy.context.scene.tool_settings.use_snap_anim)
app = twin(select_ten, 'DUPLICATE_4', lambda: bpy.ops.action.duplicate_move(
    TRANSFORM_OT_transform={'mode': 'TIME_TRANSLATE', 'value': (4, 0, 0, 0)}), 'Shift+D by 4: Duplicate')
check('  the copies on 14 selected, the originals on 10 not',
      [(k[0], k[2]) for k in app['curves']['Cube:location[0]']] == [(1.0, False), (10.0, False), (14.0, True), (20.0, False)],
      app['curves']['Cube:location[0]'])
twin(select_ten, 'DUPLICATE_0', lambda: bpy.ops.action.duplicate_move(
    TRANSFORM_OT_transform={'mode': 'TIME_TRANSLATE', 'value': (0, 0, 0, 0)}),
     'Shift+D then Escape: the copies stay, replacing the originals')
check('  three keys still, the one on 10 selected',
      [(k[0], k[2]) for k in state()['curves']['Cube:location[0]']] == [(1.0, False), (10.0, True), (20.0, False)],
      state()['curves']['Cube:location[0]'])


def select_twenty_and_one():
    select_frames({1.0, 20.0})


twin(select_twenty_and_one, 'SCALE_1_5',
     lambda: bpy.ops.transform.transform(mode='TIME_SCALE', value=(1.5, 0, 0, 0)), 'S by 1.5 about frame 10')
check('  1 and 20 scaled about 10 to -3.5 and 25, snapped to frames as Blender snaps them',
      [k[0] for k in state()['curves']['Cube:location[0]']] in ([-4.0, 10.0, 25.0], [-3.0, 10.0, 25.0],
                                                                 [-3.5, 10.0, 25.0]),
      state()['curves']['Cube:location[0]'])
for block, reference, what in (
        ('DELETE', lambda: ops.delete(confirm=False), 'Delete Keyframes'),
        ('CLEAN', lambda: ops.clean(channels=False), 'Clean Keyframes'),
        ('SNAP_CFRA', lambda: ops.snap(type='CFRA'), 'Snap ▸ Selection to Current Frame'),
        ('MIRROR_CFRA', lambda: ops.mirror(type='CFRA'), 'Mirror ▸ By Times Over Current Frame'),
        ('INTERPOLATION_ELASTIC', lambda: ops.interpolation_type(type='ELASTIC'), 'T ▸ Elastic'),
        ('EASING_EASE_IN', lambda: ops.easing_type(type='EASE_IN'), 'Ctrl+E ▸ Ease In'),
        ('TYPE_BREAKDOWN', lambda: ops.keyframe_type(type='BREAKDOWN'), 'R ▸ Breakdown'),
        ('HANDLE_VECTOR', lambda: ops.handle_type(type='VECTOR'), 'V ▸ Vector'),
        ('JUMP', lambda: ops.frame_jump(), 'Ctrl+G Jump to Keyframes'),
        ('INSERT_ALL', lambda: ops.keyframe_insert(type='ALL'), 'I: Insert Keyframes')):
    app = twin(select_twenty_and_one, block, reference, what)
    loc = app['curves'].get('Cube:location[0]', [])
    if block == 'DELETE':
        check('  only the selected keys went', [k[0] for k in loc] == [10.0], loc)
    if block == 'INTERPOLATION_ELASTIC':
        check('  the selected keys Elastic, the others Bézier as they were',
              [k[4] for k in loc] == ['ELASTIC', 'BEZIER', 'ELASTIC'], loc)
    if block == 'EASING_EASE_IN':
        check('  the selected keys Ease In', [k[5] for k in loc] == ['EASE_IN', 'AUTO', 'EASE_IN'], loc)
    if block == 'TYPE_BREAKDOWN':
        check('  the selected keys Breakdown', [k[3] for k in loc] == ['BREAKDOWN', 'KEYFRAME', 'BREAKDOWN'], loc)
    if block == 'HANDLE_VECTOR':
        check('  the selected keys\' handles Vector', [k[6] for k in loc] == ['VECTOR', 'AUTO_CLAMPED', 'VECTOR'], loc)
    if block == 'JUMP':
        check('  the frame is the selected keys\' average (1 and 20 → 10.5 → 10 or 11)',
              app['frame'] in (10, 11), app['frame'])
    if block == 'SNAP_CFRA':
        check('  the selected keys onto the current frame, 10', {k[0] for k in loc} == {10.0}, loc)
build()
select_ten()
out = ok('COPY')
bpy.context.scene.frame_set(30)
ok('PASTE')
check('Ctrl+C on 10, Ctrl+V on 30: the keys again on 30 (Frame Start)',
      [k[0] for k in state()['curves']['Cube:location[0]']] == [1.0, 10.0, 20.0, 30.0],
      state()['curves']['Cube:location[0]'])
build()
error, _ = run('COPY')
check('Ctrl+C with nothing selected says Blender\'s words', error == 'No keyframes copied to the internal clipboard',
      error)
build()
error, _ = run('DELETE')
check('Delete with nothing selected is refused in words, no step', error == 'No keyframes are selected', error)
error, _ = run('MOVE_3')
check('so is a move', error == 'No keyframes are selected', error)

# ---------------------------------------------------------------------------
print('\nmarkers')
build()
sc = bpy.context.scene
ok('MARKER_SELECT_0')
check('a tap on a marker selects it alone (marker.select)', [m.select for m in sc.timeline_markers] == [True, False, False])
ok('MARKER_SELECT_1_SHIFT')
check('Shift+tap adds the next', [m.select for m in sc.timeline_markers] == [True, True, False])
ok('MARKER_SELECT_1_SHIFT')
check('and takes it off again', [m.select for m in sc.timeline_markers] == [True, False, False])
ok('MARKER_MOVE_5')
check('G over the markers by 5: A on 15', [(m.name, m.frame) for m in sc.timeline_markers][0] == ('A', 15))
ok('MARKER_DUPLICATE_3')
check('Shift+D: a copy of A on 18, selected, A not',
      sorted((m.name, m.frame, m.select) for m in sc.timeline_markers)
      == [('A', 15, False), ('A', 18, True), ('B', 20, False), ('C', 35, False)],
      sorted((m.name, m.frame, m.select) for m in sc.timeline_markers))
ok('MARKER_RENAME')
check('F2 renames the first selected marker', any(m.name == 'Hit\'s "crash"' and m.frame == 18 for m in sc.timeline_markers),
      [m.name for m in sc.timeline_markers])
ok('MARKER_SELECT_NONE')
check('a tap beside every marker deselects them', not any(m.select for m in sc.timeline_markers))
sc.frame_set(12)
ok('MARKER_ADD')
check('M: a marker F_12 on the current frame, alone selected',
      [(m.name, m.frame) for m in sc.timeline_markers if m.select] == [('F_12', 12)])
ok('LOCK_ON')
check('Lock Markers on, and reported', sc.tool_settings.lock_markers and bridge.markers['lock'] == 1)
error, _ = run('MARKER_MOVE_5')
check('a locked marker is not moved: Blender\'s "Markers are locked"', error == 'Markers are locked', error)
error, _ = run('MARKER_RENAME')
check('nor renamed', error == 'Markers are locked', error)
ok('LOCK_OFF')
ok('MARKER_SELECT_ALL')
ok('MARKER_DELETE')
check('Delete Marker takes the selected ones', len(sc.timeline_markers) == 0)
error, _ = run('MARKER_DELETE')
check('with none, Blender\'s "No markers are selected"', error == 'No markers are selected', error)
build()
sc = bpy.context.scene
cam_data = bpy.data.cameras.new('Shot')
cam = bpy.data.objects.new('Shot', cam_data)
sc.collection.objects.link(cam)
bpy.context.view_layer.objects.active = cam
cam.select_set(True)
sc.frame_set(35)
ok('MARKER_CAMERA')
check('Ctrl+B binds the active camera to the marker on the frame',
      any(m.frame == 35 and m.camera == cam for m in sc.timeline_markers))
anim.report_markers()
check('and the report names the camera', 'Shot' in bridge.markers['cameras'], bridge.markers)
build()
select_frames({10.0})
for m in bpy.context.scene.timeline_markers:
    m.select = m.name == 'C'
app = twin(lambda: (select_frames(set()), [setattr(m, 'select', m.name == 'A') for m in bpy.context.scene.timeline_markers]),
           'COLUMNS_MARKERS', lambda: ops.select_column(mode='MARKERS_COLUMN'),
           'Shift+K: Columns on Selected Markers')
check('  the keys on marker A\'s frame, 10', {f for n, ks in app['curves'].items() for f, *rest in ks if rest[1]} == {10.0})

# ---------------------------------------------------------------------------
print('\nthe scene\'s Snap, as a drag asks for it')
build()
out = ok('SNAP_STATE')
check('Snap on, by Frame, not absolute, at the scene\'s rate',
      out.strip().splitlines()[-1] == 'BK_KEYS_SNAP 1 FRAME 0 24.0', out)

# ---------------------------------------------------------------------------
print('\none undo step an edit, through the app\'s history (_blenderkit_undo)')
build()
os.makedirs(HISTORY, exist_ok=True)


def history(block, label=''):
    error, printed = run(block, root=HISTORY, label=label)
    if error:
        raise RuntimeError(block + ': ' + error)
    return json.loads([line for line in printed.splitlines() if line.startswith('{')][-1])


history('PUSH', 'Original')
for block, prepare in (('CLICK_10', None), ('BOX_SET', None), ('SELECT_ALL', None),
                       ('MOVE_3', select_ten), ('INTERPOLATION_LINEAR', select_ten),
                       ('TYPE_EXTREME', select_ten), ('DUPLICATE_4', select_ten), ('DELETE', select_ten),
                       ('MARKER_ADD', None), ('MARKER_SELECT_0', None), ('MARKER_MOVE_5', None),
                       ('PASTE', None)):
    # Each on the scene as built, held by a step of its own.
    build()
    if prepare:
        prepare()
    if block == 'MARKER_MOVE_5':
        bpy.context.scene.timeline_markers[0].select = True
    history('PUSH', 'build')
    if block == 'PASTE':
        select_ten()
        ok('COPY')
        history('PUSH', 'Copy Keyframes')
        bpy.context.scene.frame_set(40)
        history('PUSH', 'frame')
    label = blocks['LABEL_' + block]
    was = [s for s in (_blenderkit_undo.blender_steps() or []) if s[3]][-1][0]
    before = state()
    out = ok(block)
    after = state()
    history('PUSH', label)
    steps = _blenderkit_undo.blender_steps() or []
    active = [i for i, s in enumerate(steps) if s[3]][-1]
    check('%s: one step, "%s", on the step before it' % (block, label),
          steps[active][2] == label and active > 0 and steps[active - 1][0] == was
          and blocks['UNCHANGED'] not in out, [s[2] for s in steps[-3:]])
    history('UNDO')
    check('  undone, as it was', state() == before, diff(state(), before))
    history('REDO')
    check('  redone, as it was after', state() == after, diff(state(), after))

# ---------------------------------------------------------------------------
print('\nthe undo steps are Blender\'s operators\' names')
names = {
    'CLICK_10': 'action.clickselect', 'BOX_SET': 'action.select_box', 'SELECT_ALL': 'action.select_all',
    'COLUMNS_KEYS': 'action.select_column', 'BEFORE': 'action.select_leftright', 'LINKED': 'action.select_linked',
    'MORE': 'action.select_more', 'LESS': 'action.select_less', 'MOVE_3': 'transform.transform',
    'SCALE_1_5': 'transform.transform', 'DUPLICATE_4': 'action.duplicate_move', 'DELETE': 'action.delete',
    'CLEAN': 'action.clean', 'COPY': 'action.copy', 'PASTE': 'action.paste', 'SNAP_CFRA': 'action.snap',
    'MIRROR_CFRA': 'action.mirror', 'JUMP': 'action.frame_jump',
    'INTERPOLATION_ELASTIC': 'action.interpolation_type', 'EASING_EASE_IN': 'action.easing_type',
    'TYPE_BREAKDOWN': 'action.keyframe_type', 'HANDLE_VECTOR': 'action.handle_type',
    'INSERT_ALL': 'action.keyframe_insert', 'MARKER_ADD': 'marker.add', 'MARKER_DELETE': 'marker.delete',
    'MARKER_SELECT_ALL': 'marker.select_all', 'MARKER_BEFORE': 'marker.select_leftright',
    'MARKER_CAMERA': 'marker.camera_bind', 'MARKER_SELECT_0': 'marker.select', 'MARKER_MOVE_5': 'marker.move',
    'MARKER_DUPLICATE_3': 'marker.duplicate', 'MARKER_RENAME': 'marker.rename',
}
for block, idname in names.items():
    module, op = idname.split('.')
    expected = getattr(getattr(bpy.ops, module), op).get_rna_type().name
    check('%s: "%s" is %s\'s name' % (block, blocks['LABEL_' + block], idname),
          blocks['LABEL_' + block] == expected, expected)
check('Lock Markers is the property\'s name',
      blocks['LABEL_LOCK_ON'] == bpy.types.ToolSettings.bl_rna.properties['lock_markers'].name)

# ---------------------------------------------------------------------------
print('\nthe menus\' rows against Blender\'s menus, as their draw() lays them out')


class Props:
    def __setattr__(self, k, v):
        pass

    def __getattr__(self, k):
        return Props()


class Layout:
    def __init__(self, items):
        object.__setattr__(self, 'items', items)

    def __getattr__(self, name):
        def other(*a, **k):
            return self
        return other

    def __setattr__(self, k, v):
        pass

    @staticmethod
    def _op_name(idname):
        module, op = idname.split('.')
        return getattr(getattr(bpy.ops, module), op).get_rna_type().name

    def operator(self, idname, text=None, **k):
        self.items.append(text if text not in (None, '') else self._op_name(idname))
        return Props()

    def operator_menu_enum(self, idname, prop=None, text=None, **k):
        self.items.append(text or self._op_name(idname))
        return Props()

    def menu(self, name, text=None, **k):
        self.items.append(text or getattr(getattr(bpy.types, name, None), 'bl_label', name))

    def prop(self, data, prop=None, text=None, **k):
        prop = prop or k.get('property')
        self.items.append(text if text is not None else data.bl_rna.properties[prop].name)

    def label(self, text='', **k):
        pass

    def separator(self, **k):
        self.items.append('-')

    def menu_pie(self):
        return self

    def column(self, *a, **k):
        return self

    def row(self, *a, **k):
        return self


def blender_rows(name):
    items = []

    class Self:
        pass

    s = Self()
    s.layout = Layout(items)
    with timeline():
        getattr(bpy.types, name).draw(s, bpy.context)
    rows = []
    for item in items:
        if item == '-' and (not rows or rows[-1] == '-'):
            continue
        rows.append(item)
    while rows and rows[-1] == '-':
        rows.pop()
    return rows


menus = json.load(open(MENUS))
# What the app's menus leave out of Blender's, each with why.
left_out = {
    'TIME_MT_view': {'Cache', 'Area'},          # the Cache and Area submenus: no caches or areas to manage here
}
build()
for name in ('TIME_MT_view', 'DOPESHEET_MT_select', 'DOPESHEET_MT_marker', 'NLA_MT_marker_select',
             'DOPESHEET_MT_key', 'DOPESHEET_MT_key_transform', 'DOPESHEET_MT_context_menu',
             'DOPESHEET_MT_delete', 'DOPESHEET_MT_snap_pie'):
    theirs = [r for r in blender_rows(name) if r not in left_out.get(name, set())]
    clean = []
    for r in theirs:
        if r == '-' and (not clean or clean[-1] == '-'):
            continue
        clean.append(r)
    while clean and clean[-1] == '-':
        clean.pop()
    mine = ['-' if row[0] == 'sep' else row[1] for row in menus[name]]
    check('%s: %d rows as Blender draws them' % (name, len(clean)), mine == clean,
          '\n        app:     %s\n        blender: %s' % (mine, clean))
for op, prop in (('action.interpolation_type', 'type'), ('action.easing_type', 'type'),
                 ('action.keyframe_type', 'type'), ('action.handle_type', 'type'),
                 ('action.snap', 'type'), ('action.mirror', 'type')):
    module, name = op.split('.')
    items = [i.name for i in getattr(getattr(bpy.ops, module), name).get_rna_type().properties[prop].enum_items]
    mine = [row[1] for row in menus[op] if row[0] != 'heading']
    check('%s: its enum\'s %d items, in order' % (op, len(items)), mine == items, (mine, items))

print('\nALL PASS' if fail == 0 else '\n%d FAILED' % fail)
sys.exit(1 if fail else 0)
