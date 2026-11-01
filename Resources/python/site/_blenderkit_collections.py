"""Blender's collections, as the Outliner shows them and changes them.

`record` reads the view layer's collection tree for the interface (`push`
hands it over through `_blenderkit.sync_record`); every other function is one
control of the Outliner or of Object ▸ Collection, held to the conditions
Blender's own are, and refusing in words where Blender would do nothing
without saying so or would leave the scene in a state no control leads to.

Measured in desktop Blender 5.2.1 under `-b --factory-startup` with the app's
context — its undo push, `gpu.init()`, a window and a screen and no area, as
the operator search has (round 4, group 7; tests/relations/blender):

  * `object.move_to_collection` and `object.link_to_collection` run there
    once `collection_uid` is set: the collection's `session_uid` (the scene
    collection's is `scene.collection.session_uid`). Without it Blender says
    "No collection selected", which is what the operator search hit, since
    the field is hidden in its form. A uid nothing has is "Unexpected error,
    collection not found". `is_new` makes a collection inside the one named
    and moves (or links) the selection there. Their steps are "Move to
    Collection" and "Link to Collection".
  * With nothing selected both answer FINISHED and change nothing (the exec
    walks an empty list; Blender's invoke says "No objects selected"), so
    that is refused first. Linking one object to a collection it is already
    in fails in Blender's own words ("Cube already in Collection").
  * The Outliner's own operators (`outliner.collection_new`,
    `outliner.delete`, `outliner.collection_hierarchy_delete`) act on the
    Outliner's selected tree elements, which a Blender with no window never
    builds: their poll is False here. New, Delete and Delete Hierarchy are
    therefore Blender's own code, `BKE_collection_add` and
    `BKE_collection_delete` (collection.cc), written with the data API:
    the name `BKE_collection_new_name_get` gives, and Delete relinking the
    children and objects into every parent first, as `hierarchy=false` does.
  * Excluding the collection of an object in Edit Mode left that object's
    mode at EDIT with no edit object and the context in Object Mode, and
    `mode_set` then failed ("Context missing active object"); removing the
    collection did the same. Exclude, Delete and Delete Hierarchy are refused
    while an object they would take out of the view layer is in any mode but
    Object Mode. Hide in Viewport there left the object in Edit Mode, hidden,
    as in Blender, and is allowed.
  * The toggles are properties: `LayerCollection.exclude` ("Exclude from
    View Layer"), `LayerCollection.hide_viewport` ("Hide in Viewport"),
    `Collection.hide_select` ("Disable Selection"), `Collection.hide_render`
    ("Disable in Renders"). An excluded collection's objects leave
    `view_layer.objects` and stay in `scene.objects`; an object in a
    collection with selection disabled is deselected and `select_all` skips
    it.
"""

import bpy

Refusal = RuntimeError

# The record's separators, escaped inside a value — the same table as
# `_blenderkit_sync._RECORD_ESCAPES`, read by `Modifier.fields` in Swift.
# A collection or an object may be called anything.
_ESCAPES = (('%', '%25'), (';', '%3B'), ('|', '%7C'), ('=', '%3D'), ('\n', '%0A'))

# What Blender's Outliner calls the scene's own collection
# (`BKE_collection_ui_name_get`).
SCENE_COLLECTION = 'Scene Collection'


def _value(value):
    if isinstance(value, bool):
        return '1' if value else '0'
    if isinstance(value, int):
        return str(value)
    text = str(value)
    for raw, escaped in _ESCAPES:
        text = text.replace(raw, escaped)
    return text


def _names(names):
    """Object names as one value: each with its own `%` and `,` escaped, then
    joined by commas. The whole value is escaped again by `_value`, so Swift
    decodes the value once, splits on the commas and decodes each name."""
    return ','.join(n.replace('%', '%25').replace(',', '%2C') for n in names)


def _entry(pairs):
    return ';'.join(k + '=' + _value(v) for k, v in pairs)


def _walk(layer, depth, parent, active, out, path=()):
    collection = layer.collection
    master = depth == 0
    # `path`: the uids from the Scene Collection's child down to this one. A
    # collection linked into two parents has one layer collection under each,
    # with the same uid, and each instance has its own Exclude, Hide in
    # Viewport and active state; the path says which (`layer`). Round 4's
    # review of group 7 measured Scene ▸ A ▸ C ▸ D and Scene ▸ B ▸ C ▸ D: the
    # uid alone made the Outliner list every instance's children under each
    # (13 rows, D four times) and B ▸ C's checkbox exclude A ▸ C.
    pairs = [('kind', 'collection'), ('uid', collection.session_uid),
             ('name', SCENE_COLLECTION if master else collection.name),
             ('depth', depth), ('parent', parent),
             ('path', '/'.join(str(uid) for uid in path)),
             ('exclude', bool(layer.exclude) and not master),
             ('hide', bool(layer.hide_viewport)),
             ('select', not collection.hide_select),
             ('disabled', bool(collection.hide_viewport)),
             ('render', not collection.hide_render),
             ('active', layer == active),
             ('objects', _names([o.name for o in collection.objects]))]
    out.append(_entry(pairs))
    for child in layer.children:
        _walk(child, depth + 1, collection.session_uid, active, out,
              path + (child.collection.session_uid,))


def record():
    """`kind=view_layer;…|kind=collection;…`: the view layer's collection
    tree, depth first in Blender's order, each with its toggles and the
    objects directly in it, in the collection's order. An object in two
    collections is in both entries, as the Outliner lists it under both."""
    view_layer = bpy.context.view_layer
    active = view_layer.active_layer_collection
    out = [_entry([('kind', 'view_layer'), ('name', view_layer.name)])]
    _walk(view_layer.layer_collection, 0, 0, active, out)
    return '|'.join(out)


def push():
    """Hands the interface the collection tree. A Blender without collections
    (the simulator's stand-in) sends nothing, and the Outliner shows the
    objects without a tree rather than one it made up."""
    try:
        import _blenderkit
    except ImportError:
        return
    send = getattr(_blenderkit, 'sync_record', None)
    if send is None or not hasattr(bpy.context, 'view_layer') \
            or not hasattr(getattr(bpy.context, 'view_layer', None), 'layer_collection'):
        return
    send('collections', '', record())


# ---------------------------------------------------------------------------
# Finding a collection

def _layers(layer):
    yield layer
    for child in layer.children:
        yield from _layers(child)


def layer(uid, path=None):
    """The view layer's layer collection for the collection with `uid`: the
    instance at `path` (the uids from the Scene Collection's child down, as
    `record` writes it), or the first one when no path is given."""
    if path is not None:
        found = bpy.context.view_layer.layer_collection
        for step in path:
            found = next((child for child in found.children if child.collection.session_uid == step), None)
            if found is None:
                break
        if found is not None and found.collection.session_uid == uid:
            return found
        raise Refusal("The collection the Outliner showed is no longer there in the view layer.")
    for found in _layers(bpy.context.view_layer.layer_collection):
        if found.collection.session_uid == uid:
            return found
    raise Refusal("The collection the Outliner showed is no longer in the view layer.")


def collection(uid, master=True):
    """The collection with `uid` — the scene's own when `master` allows it."""
    scene = bpy.context.scene
    if scene.collection.session_uid == uid:
        if not master:
            raise Refusal("The Scene Collection is the scene's own and cannot be changed this way.")
        return scene.collection
    for found in bpy.data.collections:
        if found.session_uid == uid:
            return found
    raise Refusal("The collection the Outliner showed is gone.")


def _parents(child):
    """Every collection `child` is directly inside, the scenes' own included —
    `collection->runtime->parents`."""
    found = [s.collection for s in bpy.data.scenes
             if child.name in s.collection.children and s.collection.children[child.name] == child]
    found += [c for c in bpy.data.collections
              if child.name in c.children and c.children[child.name] == child]
    return found


def _objects_within(coll):
    seen = set()
    stack = [coll]
    while stack:
        c = stack.pop()
        for o in c.objects:
            seen.add(o)
        stack.extend(c.children)
    return seen


def _refuse_busy(coll, what):
    """Refuses `what` while an object it takes out of the view layer is in a
    mode other than Object Mode (see the module's notes)."""
    for o in _objects_within(coll):
        mode = getattr(o, 'mode', 'OBJECT')
        if mode != 'OBJECT':
            raise Refusal(what + " would take " + o.name + " out of the view layer while it is in "
                          + mode.replace('_', ' ').title() + " Mode. Go back to Object Mode first.")


# ---------------------------------------------------------------------------
# The Outliner's controls

def new_name(parent):
    """`BKE_collection_new_name_get`: "Collection N" inside the scene's own
    collection, "<parent> N" inside another, N one more than it has
    children. Blender adds `.001` if that name is taken, as `new` does."""
    count = len(parent.children) + 1
    if parent == bpy.context.scene.collection:
        return "Collection %d" % count
    return "%s %d" % (parent.name, count)


def new(parent_uid, name=None):
    """The Outliner's New Collection: an empty collection inside the one with
    `parent_uid`, its colour tag the parent's, as `collection_new_exec`
    makes it. Returns its name."""
    parent = collection(parent_uid)
    made = bpy.data.collections.new(name or new_name(parent))
    parent.children.link(made)
    if hasattr(parent, 'color_tag') and parent != bpy.context.scene.collection:
        made.color_tag = parent.color_tag
    return made.name


def rename(uid, name):
    """A double-click rename. Blender's `.001` rule decides the name it
    keeps; the Outliner shows what comes back."""
    coll = collection(uid, master=False)
    wanted = str(name).strip()
    if not wanted:
        raise Refusal("A collection needs a name.")
    coll.name = wanted
    return coll.name


def delete(uid, hierarchy=False):
    """The Outliner's Delete (`hierarchy` False) and Delete Hierarchy:
    `BKE_collection_delete`. Without the hierarchy, the collection's child
    collections and objects are linked into each of its parents first, so
    nothing it held leaves the scene; with it, its objects that are in no
    other collection are deleted and so are its child collections."""
    coll = collection(uid, master=False)
    _refuse_busy(coll, "Delete Hierarchy" if hierarchy else "Delete")
    _delete(coll, hierarchy)


def _delete(coll, hierarchy):
    if hierarchy:
        for o in list(coll.objects):
            coll.objects.unlink(o)
            # `collection_object_remove(..., free_us=true)`: an object no
            # other collection holds is freed.
            if o.users == 0:
                bpy.data.objects.remove(o)
        for child in list(coll.children):
            _delete(child, True)
    else:
        parents = _parents(coll)
        for child in list(coll.children):
            for parent in parents:
                if not (child.name in parent.children and parent.children[child.name] == child):
                    parent.children.link(child)
        for o in list(coll.objects):
            for parent in parents:
                if not (o.name in parent.objects and parent.objects[o.name] == o):
                    parent.objects.link(o)
    bpy.data.collections.remove(coll)


def set_exclude(uid, value, path=None):
    """The checkbox: Exclude from View Layer, of the instance at `path`."""
    found = layer(uid, path)
    if found == bpy.context.view_layer.layer_collection:
        raise Refusal("The Scene Collection cannot be excluded from the view layer.")
    if value:
        _refuse_busy(found.collection, "Exclude from View Layer")
    found.exclude = bool(value)


def set_hide(uid, value, path=None):
    """The eye: the view layer's Hide in Viewport, of the instance at `path`."""
    layer(uid, path).hide_viewport = bool(value)


def set_selectable(uid, value):
    """The arrow: Disable Selection, which is `hide_select` — off when the
    collection's objects can be selected."""
    collection(uid, master=False).hide_select = not value


def set_render(uid, value):
    """The camera: Disable in Renders, `hide_render` — off when the
    collection renders."""
    collection(uid, master=False).hide_render = not value


def set_active(uid, path=None):
    """A tap on a collection: Blender's active collection, which new objects
    go into — the instance at `path`. An excluded collection cannot be
    active (Blender makes the Scene Collection active when the active one is
    excluded)."""
    found = layer(uid, path)
    if found.exclude:
        raise Refusal(found.name + " is excluded from the view layer, so it cannot be the active "
                      "collection.")
    bpy.context.view_layer.active_layer_collection = found


# ---------------------------------------------------------------------------
# Object ▸ Collection: Move to Collection (M) and Link to Collection (Shift+M)

def _selected_or_refuse(what):
    view_layer = bpy.context.view_layer
    active = view_layer.objects.active
    if active is not None and getattr(active, 'mode', 'OBJECT') != 'OBJECT':
        raise Refusal(what + " works in Object Mode, as in Blender; " + active.name + " is in "
                      + active.mode.replace('_', ' ').title() + " Mode.")
    # What the operator takes (`selected_objects_get`: the context's
    # `selected_objects`) — in Local View, under the borrowed view, only what
    # it holds (`_blenderkit_localview.run`).
    selected = getattr(bpy.context, 'selected_objects', None)
    if selected is None:
        selected = [o for o in view_layer.objects if o.select_get()]
    if not selected:
        raise Refusal(what + " moves the selected objects, and none is selected. Select one first."
                      if what.startswith('Move') else
                      what + " links the selected objects, and none is selected. Select one first.")
    return selected


def _inside(collection, ancestor):
    """Whether `collection` is `ancestor` or somewhere inside it."""
    return collection == ancestor or collection in ancestor.children_recursive


def check_move(uid, link=False, new_collection=False):
    """What `move_to_collection` / `link_to_collection` need, refused in
    words before Blender is asked: Object Mode, something selected, a
    collection that is there, and none of the selection an instancer of it.

    Blender cannot put an object inside the collection it instances, or inside
    one within it (`collection_object_add`'s cyclic check), and says nothing.
    Measured in desktop 5.2.1 with the app's context, an empty instancing
    "Parts" moved into Parts with Blender's own operator and with `move`:
    FINISHED, and the empty was left in no collection, with 0 users, gone from
    `scene.objects` and the Outliner and lost on save — the add failed and the
    move's remove from every other collection went ahead
    (`BKE_collection_object_move`). Link to Collection answered FINISHED and
    changed nothing. A new collection made inside it is inside it too."""
    what = "Link to Collection" if link else "Move to Collection"
    selected = _selected_or_refuse(what)
    target = collection(uid)
    for o in selected:
        instanced = getattr(o, 'instance_collection', None)
        if instanced is None or not _inside(target, instanced):
            continue
        place = ("a new collection inside " + target.name) if new_collection else target.name
        # The banner puts the row's name before it ("Move to Collection: …").
        if link:
            raise Refusal(o.name + " instances " + instanced.name + ", so it cannot also be in " + place
                          + ", which is inside what it instances; Blender would do nothing. Choose another "
                          "collection, or deselect " + o.name + ".")
        raise Refusal(o.name + " instances " + instanced.name + ", so it cannot be moved into " + place
                      + ", which is inside what it instances; Blender would take it out of every collection "
                      "and lose it. Choose another collection, or deselect " + o.name + ".")


def move(uid, link=False, new_collection=None):
    """`object.move_to_collection` or `object.link_to_collection` into the
    collection with `uid`, or into a new one inside it called
    `new_collection`. Returns Blender's result."""
    check_move(uid, link, new_collection is not None)
    run = bpy.ops.object.link_to_collection if link else bpy.ops.object.move_to_collection
    if new_collection is not None:
        return run(collection_uid=uid, is_new=True, new_collection_name=str(new_collection))
    return run(collection_uid=uid)
