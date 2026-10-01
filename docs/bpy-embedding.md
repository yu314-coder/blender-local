# The embedded interpreter

**Historical baseline:** device builds now stage real Blender bpy and use framework-wrapped extensions. See [the current integration notes](blender-local.md#september-10-upgrade). The shim-only layout and migration proposal below describe the earlier implementation.

Blender Local runs **real CPython 3.14**, staged into the app bundle at build time.
Nothing is fetched at build time or at runtime: the stdlib, the 67 extension
modules and the `bpy` shim all ship inside the app, so scripting works with the
device in airplane mode.

```
Blender Local.app/
  Frameworks/Python.framework           the interpreter (5.6 MB)
  python/lib/python3.14/                pure-Python stdlib (553 modules)
  python/lib/python3.14/lib-dynload/    extension modules (67 × .so)
  python/site/bpy/                      the bpy shim
```

`PYTHONHOME` points at `Blender Local.app/python`, so `sys.prefix` never leaves
the bundle. Total cost: about **28 MB**, in a 35 MB app.

## How it is wired

| Piece | Where | Does |
|---|---|---|
| `PythonBootstrap.c` | `Sources/Blender LocalBridge/Python` | Starts the interpreter, captures output, defines the `_blenderkit` module |
| `EmbeddedBpyRuntime.swift` | same | `@_cdecl` functions the module calls, and the `BpyRuntime` conformance |
| `bpy/__init__.py` | `Resources/python/site` | The `bpy`-shaped API, in Python |
| `scripts/stage-python.sh` | build phase | Copies the right slice into the bundle |

The split is deliberate: the C layer stays small and boring, and the API shape
lives in Python where matching Blender's is far easier to read and change.

Output is captured by swapping `sys.stdout` and `sys.stderr` for one buffer, so
prints, echoed expression values and tracebacks arrive in the console in the
order they happened. A single line runs as `Py_single_input` so the console
echoes values like a REPL; anything multi-line runs as `Py_file_input`, which is
what **Run Script** sends.

## Two things that cost time

- **`utf8_mode` is on `PyPreConfig`, not `PyConfig`,** as of 3.14. It has to be
  set during pre-initialisation via `Py_PreInitialize`. Miss it and the
  interpreter falls back to the POSIX locale on iOS, where any non-ASCII path
  or literal fails.
- **This build ships `lib-dynload` as plain `.so` files**, not as `.framework`
  bundles with `.fwork` stubs. That matters: the whole class of
  `@executable_path` resolution problems that makes `ios_system` load-bearing in
  CodeBench simply does not apply here. Nothing needs `ios_system`.

## What this is not

The shim is **Blender Local's own module, not Blender's `bpy`**. It implements the
calls people actually reach for — `bpy.ops.mesh.primitive_*_add`,
`bpy.data.objects[…]`, `.location` / `.rotation_euler` / `.scale`,
`select_set` — against Blender Local's scene. Real Blender operators, modifiers,
node trees and add-ons are not there, and `bpy.context.selected_objects` raises
`NotImplementedError` rather than quietly returning something wrong.

## Using Blender's actual bpy instead

The real module is cross-compiled for iOS arm64 in
[python-ios-lib](https://github.com/yu314-coder/python-ios-lib) — a headless
build with the Metal backend and Eevee working on device. Dropping it in means:

1. Adding it to `python/lib/python3.14/site-packages` and deleting the shim, so
   `import bpy` resolves to the real module.
2. **Mirroring the scene back out.** This is the actual work. The shim mutates
   `BKScene` directly, but the real `bpy` owns the scene: after any script runs,
   `bpy.data.objects` has to be walked and copied into `BKScene` — name,
   transform, and the evaluated mesh — for the Metal viewport to draw it.
3. Replacing `MeshBuilder` with real mesh extraction, and making the renderer's
   buffer cache per-object rather than per-`PrimitiveKind` (it currently assumes
   every cube shares one mesh) with invalidation when a mesh changes.

Size is the reason this has not been done: `bpy` is roughly **432 MB** in the
CodeBench bundle — around 140 MB of Python package plus ~292 MB of native
frameworks, including a 66 MB `libusd_ms`. That turns a 35 MB app into a ~470 MB
one. Blender is also GPL; see the licensing question in the README.
