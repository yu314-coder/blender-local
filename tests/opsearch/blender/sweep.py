"""Every object.*, mesh.* and uv.* operator, run with its defaults the way the
operator search runs it (`_blenderkit_sync.run_operator(path, {})`), on each
fixture, from each mode. One line before and one after each run, so the driver
can name the operator that took Blender down and carry on after it.

    Blender -b --factory-startup --python sweep.py -- <variant> <first index>

`variant` is `new` (the tree's run_operator) or `old` (the one before the mode
rule, kept here as the negative control).
"""
import bpy, gpu, sys, types, pathlib, importlib.util
sys.dont_write_bytecode = True
here = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(here))
import fixtures

variant, first = sys.argv[-2], int(sys.argv[-1])
root = here.parents[2]
sys.modules['_blenderkit'] = types.ModuleType('_blenderkit')
spec = importlib.util.spec_from_file_location('_blenderkit_sync', root / 'Resources/python/site/_blenderkit_sync.py')
ui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui)
gpu.init()


def old_run_operator(path, values):
    # run_operator as it was before the mode rule (HEAD 17d2d10), verbatim.
    op = ui.resolve('bpy.ops.' + path)
    if not op.poll():
        raise RuntimeError('This operator needs a different selection, mode, or Blender editor context: ' + path)
    properties = op.get_rna_type().properties
    for key, value in values.items():
        if properties[key].type == 'ENUM' and properties[key].is_enum_flag:
            values[key] = set(value)
    result = op('EXEC_DEFAULT', **values)
    if 'FINISHED' not in result:
        raise RuntimeError(path + ' returned ' + repr(result) + '; no completed operation')
    return sorted(result)


run = ui.run_operator if variant == 'new' else old_run_operator


# Left out of the sweep: they act on this Mac rather than on Blender's scene
# (open a URL or a folder, write the user's startup file or preferences).
# Measured 2026-09-22, when the list lacked the second half: wm.doc_view,
# run with its empty id, builds docs.blender.org/api/…/bpy.types..html and
# opens it in the Mac's browser (a "not found" tab per run, four per sweep);
# render.play_rendered_anim starts a second, windowed Blender as the
# animation player; wm.clear_recent_files emptied the desktop Blender's
# recent-files list in a run that had no home of its own.
HOST_SIDE_EFFECTS = {'wm.url_open', 'wm.url_open_preset', 'wm.path_open', 'wm.save_homefile',
                     'wm.save_userpref', 'wm.read_userpref', 'wm.read_factory_userpref',
                     'wm.app_template_install', 'wm.keyconfig_preset_add', 'wm.interface_theme_preset_add',
                     'wm.interface_theme_preset_remove', 'wm.interface_theme_preset_save',
                     'wm.keyconfig_preset_remove', 'wm.theme_install', 'wm.keyconfig_import',
                     'wm.keyconfig_export', 'wm.owner_enable', 'wm.owner_disable',
                     'wm.doc_view', 'wm.doc_view_manual', 'wm.doc_view_manual_ui_context',
                     'render.play_rendered_anim', 'image.external_edit', 'wm.previews_batch_generate',
                     'wm.previews_batch_clear', 'wm.clear_recent_files', 'wm.operator_presets_cleanup',
                     'wm.sysinfo', 'sound.mixdown', 'wm.save_auto_save'}


def host_side_effect(name):
    # A preset operator writes into the user's scripts folder, whatever its module.
    return name in HOST_SIDE_EFFECTS or name.endswith(('preset_add', 'preset_remove', 'preset_save'))


def keep_to_blender():
    """The list above is only as good as the last sweep that was read. These
    two rules hold for the operators nobody has named yet.

    1. No run against this Mac's own Blender settings: drive.py gives every
       Blender it starts a HOME and BLENDER_USER_RESOURCES of its own, and a
       run that skips drive.py stops here instead of writing presets, the
       recent-files list or preferences into the user's Blender.
    2. Nothing started outside Blender. Every Blender operator that opens a
       browser, Finder, an image editor or another Blender goes through
       webbrowser, subprocess or os (bl_operators/wm.py, image.py, file.py,
       assets.py, screen_play_rendered_anim.py), so those refuse here and the
       operator reports the refusal like any other failure.
    """
    import os, pwd, subprocess, webbrowser
    mine = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, "Library", "Application Support", "Blender")
    config = os.path.realpath(bpy.utils.user_resource('CONFIG'))
    if config.startswith(os.path.realpath(mine) + os.sep):
        print(f"REFUSED: this Blender's settings are this Mac's own ({config}); run the sweep "
              "through tests/opsearch/blender/drive.py, which gives it a home of its own", flush=True)
        raise SystemExit(2)

    def refuse(*args, **kwargs):
        raise PermissionError("the operator sweep starts nothing outside Blender")

    class NoProcess:
        def __init__(self, *args, **kwargs):
            refuse()

    for name in ('open', 'open_new', 'open_new_tab', 'get', 'register'):
        setattr(webbrowser, name, refuse)
    subprocess.Popen = NoProcess
    for name in ('system', 'popen', 'startfile', 'posix_spawn', 'posix_spawnp', 'fork', 'forkpty',
                 'execv', 'execve', 'execvp', 'execvpe', 'execl', 'execle', 'execlp', 'execlpe',
                 'spawnv', 'spawnve', 'spawnvp', 'spawnvpe', 'spawnl', 'spawnle', 'spawnlp', 'spawnlpe'):
        if hasattr(os, name):
            setattr(os, name, refuse)


keep_to_blender()


def takes_modifier(name):
    module, op = name.split('.')
    return 'modifier' in getattr(getattr(bpy.ops, module), op).get_rna_type().properties


def work():
    # With its defaults, and — for an operator that names a modifier, as the
    # Multires ones do — once per modifier on the fixture, which is what a
    # user fills in: with the default "" they find no modifier and cancel, so
    # the crash measured in the app (Apply Base from Edit Mode) needs the name.
    names = []
    mods = [a[5:] for a in sys.argv if a.startswith('mods=')]
    modules = ('object', 'mesh', 'uv')
    if mods == ['rest']:
        # Every other operator the search lists, less the few that reach
        # outside Blender: a browser, Finder, the network, or the user's own
        # preferences and add-ons on this Mac.
        modules = [m for m in dir(bpy.ops) if m not in ('object', 'mesh', 'uv', 'extensions', 'preferences')]
    for module in modules:
        names += [module + '.' + n for n in dir(getattr(bpy.ops, module))]
    names = [n for n in names if not host_side_effect(n)]
    only = [a for a in sys.argv if a.startswith('only=')]
    if only:
        names = [n for n in names if n in only[0][5:].split(',')]
    part = [a[5:] for a in sys.argv if a.startswith('part=')]
    fixture_list, mode_list = fixtures.FIXTURES, fixtures.MODES
    if part:
        fixture_list, mode_list = (part[0].split(':')[0],), (part[0].split(':')[1],)
    for fixture in fixture_list:
        for mode in mode_list:
            for name in sorted(names):
                yield fixture, mode, name, {}
                if takes_modifier(name):
                    for modifier in fixtures.MODIFIERS[fixture]:
                        yield fixture, mode, name, {'modifier': modifier}


for index, (fixture, mode, name, values) in enumerate(work()):
    if index < first:
        continue
    try:
        fixtures.build(fixture, mode)
    except Exception as error:
        print(f"S|{index}|{fixture}|{mode}|{name}|fixture failed: {error}", flush=True)
        continue
    label = name + (f"(modifier={values['modifier']})" if values else '')
    print(f"B|{index}|{fixture}|{mode}|{label}", flush=True)
    try:
        outcome = 'ran:' + ','.join(run(name, dict(values)))
    except Exception as error:
        outcome = 'refused:' + type(error).__name__ + ':' + str(error).replace('\n', ' ')[:160]
    active = bpy.context.view_layer.objects.active
    after = getattr(active, 'mode', 'OBJECT') if active is not None else 'NONE'
    print(f"E|{index}|{after}|{outcome}", flush=True)
print("DONE", flush=True)
