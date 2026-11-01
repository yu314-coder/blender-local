"""The names the app shows, held to Blender's.

The user asked for every tool, menu and command to carry Blender 5.x's own
English name (docs/blender-names.md). This is the half of that check that
needs no Blender: it reads every string literal the app ships — Swift in
Sources/, the Python in Resources/python/site — with comments left out, and
fails when one of the names the app used to show instead of Blender's comes
back. The other half, tests/names/main.swift with verify.py here and
tests/names/blender/verify.py, holds the names the app builds against
Blender's menus, toolbar and operators.

A check that cannot fail checks nothing, so the scanner is first run on
snippets that carry old names (and must be caught) and on snippets that only
mention them in comments (and must not be).
"""
import ast
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]

# Old name -> Blender's. Matched anywhere in a literal, as whole words: none
# of these is Blender's wording in any context (docs/blender-names.md).
ANYWHERE = {
    "Select Tool": "Tweak",
    "Box Select Tool": "Select Box",
    "Circle Select Tool": "Select Circle",
    "Lasso Select Tool": "Select Lasso",
    "Move Tool": "Move",
    "Rotate Tool": "Rotate",
    "Scale Tool": "Scale",
    "Tap to Select": "Tweak",
    "Drag a Box": "Select Box",
    "Paint with a Circle": "Select Circle",
    "Draw a Lasso": "Select Lasso",
    "Finish Editing": "Edit Mode / Object Mode",
    "Object Details": "Properties",
    "All Blender Tools": "Operator Search",
    "Search Operators": "Operator Search",
    "Edit Mesh": "Edit Mode",
    "Edit Curve": "Edit Mode",
    "Edit Lattice": "Edit Mode",
    "View Style": "Viewport Shading",
    "Transform Tools": "Tool Settings",
    "Look Through Camera": "Active Camera / Camera",
    "Look Through It": "View Camera",
    "Aim Camera at This View": "Align Active Camera to View",
    "Aim at This View": "Align Active Camera to View",
    "Aim Camera at View": "Align Camera to View",
    "Make This the Scene Camera": "Set Active Object as Camera",
    "Set Scene Camera": "Set Active Object as Camera / Camera",
    "Delete Selected": "Delete",
    "Leave Sculpt Mode": "Object Mode",
    "Every Property": "Data API",
    "Cut and Divide": "(Blender's own menus)",
    "Add Geometry": "(Blender's own menus)",
    "Tris to Quads": "Triangles to Quads",
    "New Face from Edges": "Make Edge/Face / New Edge/Face from Vertices",
    "Merge at Center": "Merge / At Center",
    "Spot Shape": "Beam Shape",
    "Area Shape": "Light",
    "Import Model": "Import",
    "Mirror Options": "Options / Symmetry",
    "Circle Radius": "Radius",
    "Pause Animation": "Play Animation",
    "Play Animation in Reverse": "Play Animation",
    "Jump to Previous Keyframe": "Jump to Keyframe",
    "Jump to Next Keyframe": "Jump to Keyframe",
    "New Shape from Mix": "New Combined",
    "Delete All Shape Keys": "Delete All",
    "Apply All Shape Keys": "Apply All",
    "Shape Key Lock": "Solo Active Shape Key",
    "Wireframe / Solid": "Toggle Shading Type",
    "Perspective / Orthographic": "Perspective/Orthographic",
    "Go to Line": "Jump To",
    "Find and Replace": "Find & Replace",
    "Auto Keying Settings": "Auto Keyframing",
    "glTF Binary": "glTF 2.0 (.glb/.gltf)",
    "Orphan Data": "Unused Data",
    "Sculpt Stroke": "(the brush's step: Draw Brush, ...)",
    "Mask Brush": "Mask",
    "Face Set Paint Brush": "Face Set Paint",
    "Include Non-edited": "Include Non-Edited",
    "Toggle Edit Mode": "Edit Mode",
    "Open the 3D View": "Layout",
    "Render the 3D View": "Render the 3D Viewport",
    # Round 4's review: a tab the app does not have, and a row no menu has.
    "Sculpting tab": "the Layout tab",
    "Remesh ▸ Multires Subdivide": "Remesh ▸ Add Multires and Subdivide",
}

# Old name -> Blender's, matched only as a whole literal (a label): each of
# these words is fine inside a sentence or as some other Blender name.
EXACT = {
    "Scene Camera": "Cameras / Camera",
    "Snap With": "Snap Base",
    "Snap To": "Snap Target",
    "Pivot": "Pivot Point",
    "Proportional": "Proportional Editing",
    "Colour": "Color",
    "Range Max": "Max",
    "Cone Size": "Angle",
    "Outdent": "Unindent",
    "Previous Frame": "Frame Offset",
    "Next Frame": "Frame Offset",
    "Jump to Start": "Jump to Endpoint",
    "Jump to End": "Jump to Endpoint",
    "3D View": "Layout (the tab) / 3D Viewport (the editor)",
    "Mat": "Material",
    "Mods": "Modifiers",
    "Use Solid": "Use Workbench",
    "Eevee": "EEVEE",
    # Round 4's review.
    "Brush Color": "Color",
    "Show in Viewports": "Visibility ▸ Show In ▸ Viewports",
}

# A whole-literal match that is another of Blender's names, by file: the
# Pivot constraint is called "Pivot" (`Constraint.type`'s item PIVOT in 5.2.1,
# Add Object Constraint ▸ Relationship), and is no pivot point.
EXACT_ELSEWHERE = {("Sources/BlenderLocalBridge/Constraints.swift", "Pivot")}

# Undo steps: what Blender's undo history shows for the same action
# (measured in desktop 5.2.1, docs/blender-names.md). These old labels were
# the app's own words for steps Blender names otherwise.
UNDO = {
    "Select All": "(De)select All",
    "Deselect": "(De)select All",
    "Invert Selection": "(De)select All",
    "Toggle Edit Mode": "Edit Mode",
    "Duplicate": "Add Duplicate",
    "Enable in Viewports": "Disable in Viewports",
    "Disable in Render": "Disable in Renders",
    "Show": "Hide in Viewport",
    "Hide": "Hide in Viewport",
    "Snap Cursor": "Snap Cursor to ...",
    "Snap Selection": "Snap Selection to ...",
    "Texture Paint": "Image Paint",
    "Add Lattice": "Add Object",
    # The Timeline's fields read Start and End (round 4's review).
    "Start Frame": "Start",
    "End Frame": "End",
    "Preview Range Start Frame": "Start",
    "Preview Range End Frame": "End",
}


def swift_literals(source):
    """Every string literal in Swift source, outside comments, as
    (line, text, code-before): the text with each interpolation `\\(...)`
    replaced by a space, and the code on the line before the literal opened."""
    out = []
    i, n, line = 0, len(source), 1
    code_line = []
    # Each entry: ('code', paren_depth) inside an interpolation.
    stack = []

    def read_string(i, line, multi):
        text = []
        start_line = line
        while i < n:
            c = source[i]
            if c == '\n':
                line += 1
                if not multi:
                    break
            if c == '\\' and i + 1 < n:
                if source[i + 1] == '(':
                    # An interpolation: code until the matching parenthesis.
                    depth, j = 1, i + 2
                    while j < n and depth:
                        d = source[j]
                        if d == '"':
                            # A string inside the interpolation.
                            if source.startswith('"""', j):
                                _, j, line = read_string(j + 3, line, True)
                            else:
                                _, j, line = read_string(j + 1, line, False)
                            continue
                        if d == '(':
                            depth += 1
                        elif d == ')':
                            depth -= 1
                        elif d == '\n':
                            line += 1
                        j += 1
                    text.append(' ')
                    i = j
                    continue
                text.append(source[i:i + 2])
                i += 2
                continue
            if multi and source.startswith('"""', i):
                return (''.join(text), start_line), i + 3, line
            if not multi and c == '"':
                return (''.join(text), start_line), i + 1, line
            text.append(c)
            i += 1
        return (''.join(text), start_line), i, line

    while i < n:
        c = source[i]
        if source.startswith('//', i):
            while i < n and source[i] != '\n':
                i += 1
            continue
        if source.startswith('/*', i):
            depth = 1
            i += 2
            while i < n and depth:
                if source.startswith('/*', i):
                    depth += 1; i += 2; continue
                if source.startswith('*/', i):
                    depth -= 1; i += 2; continue
                if source[i] == '\n':
                    line += 1
                i += 1
            continue
        if c == '"':
            before = ''.join(code_line)
            if source.startswith('"""', i):
                (text, at), i, line = read_string(i + 3, line, True)
            else:
                (text, at), i, line = read_string(i + 1, line, False)
            out.append((at, text, before))
            code_line.append('"…"')
            continue
        if c == '\n':
            line += 1
            code_line = []
        else:
            code_line.append(c)
        i += 1
    return out


def python_literals(source):
    """Every string constant in Python source but docstrings, as (line, text,
    code-before)."""
    tree = ast.parse(source)
    docs = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            body = getattr(node, 'body', [])
            if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant) \
                    and isinstance(body[0].value.value, str):
                docs.add(id(body[0].value))
    out = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and id(node) not in docs:
            out.append((node.lineno, node.value, ''))
    return out


def _word(phrase):
    return re.compile(r'(?<![A-Za-z0-9])' + re.escape(phrase) + r'(?![A-Za-z0-9])')


ANY_RE = [(old, new, _word(old)) for old, new in ANYWHERE.items()]


def label_of(text):
    """A literal as the label it would show: trailing ellipses and space gone."""
    label = text.strip()
    while label.endswith(('…', '...')):
        label = label[:-1] if label.endswith('…') else label[:-3]
    return label.strip()


# The code right before a literal that makes it an undo step's name (or a
# LastOperator's, which is the step's and the redo panel's title).
UNDO_CONTEXT = re.compile(r'(?:\bundo:|\bundoName\b|\bundoLabel\b|\bname:)[^,()]*$|undo\.push\(\s*$')


def problems(literals, path, python=False):
    found = []
    for line, text, before in literals:
        for old, new, pattern in ANY_RE:
            if pattern.search(text):
                found.append(f"{path}:{line}: \"{text[:70]}\" has \"{old}\" (Blender: {new})")
        label = label_of(text)
        if label in EXACT and (str(path), label) not in EXACT_ELSEWHERE:
            found.append(f"{path}:{line}: \"{text}\" (Blender: {EXACT[label]})")
        if label in UNDO and UNDO_CONTEXT.search(before):
            found.append(f"{path}:{line}: undo step \"{text}\" (Blender's undo history: {UNDO[label]})")
    return found


# The 3D View's own undo steps (Sources/BlenderLocalBridge/UndoSteps.swift):
# measured in Blender by tests/names/blender/verify.py, which reads them from
# the dump. A step typed in the UI instead of taken from there would drift
# from what is measured with nothing failing — round 4's review changed
# LayoutWorkspace's Edit Mode step to "Enter Edit" and Shift+D's to
# "Duplicate Mesh", and no check noticed.
STEP_FILE = ROOT / "Sources" / "BlenderLocalBridge" / "UndoSteps.swift"
# The builders whose steps those are: a `run(...)` sending one of these takes
# its `undo:` from UndoStep, or from Bpy.ShowHide's `undoName`, never from a
# literal or a name the UI defines.
STEP_BUILDERS = [re.compile(p) for p in (
    r"\bBpy\.toggleEditMode\b", r"\bBpy\.setMode\(", r"\bBpy\.duplicateElements\b", r"\bBpy\.duplicate\b",
    r"\bBpy\.deleteSelection\(", r"\bBpy\.shadeSmooth\b", r"\bBpy\.shadeFlat\b", r"\bBpy\.separate\(",
    r"\bBpy\.addModifier\(", r"\bBpy\.addModifierRow\(", r"\bBpy\.showHide\(")]
STEP_SOURCE = re.compile(r"^(?:[\w?.]*\s*\?\s*)?(?:UndoStep\.\w+|[\w.?]+\.undoName\b(?:\([^()\"]*\))?)"
                         r"(?:\s*:\s*(?:UndoStep\.\w+))?$")


def step_names(source):
    return dict(re.findall(r'static let (\w+) = "([^"]+)"', source))


def swift_code(source):
    """Swift source with comments blanked and each string literal's text
    replaced by "…" (interpolations kept as code), lines kept."""
    out, i, n = [], 0, len(source)

    def string(i, multi):
        # Returns the index after the literal, appending its code form.
        out.append('"')
        while i < n:
            if source[i] == '\\' and i + 1 < n and source[i + 1] == '(':
                depth, j = 1, i + 2
                inner_start = j
                while j < n and depth:
                    if source[j] == '"':
                        break
                    depth += {'(': 1, ')': -1}.get(source[j], 0)
                    j += 1
                out.append('\\(' + source[inner_start:j])
                i = j
                continue
            if source[i] == '\\':
                i += 2
                continue
            if multi and source.startswith('"""', i):
                out.append('…"')
                return i + 3
            if not multi and source[i] in '"\n':
                out.append('…"')
                return i + 1
            if source[i] == '\n':
                out.append('\n')
            i += 1
        return i

    while i < n:
        if source.startswith('//', i):
            while i < n and source[i] != '\n':
                i += 1
            continue
        if source.startswith('/*', i):
            depth, i = 1, i + 2
            while i < n and depth:
                if source.startswith('/*', i):
                    depth, i = depth + 1, i + 2
                elif source.startswith('*/', i):
                    depth, i = depth - 1, i + 2
                else:
                    if source[i] == '\n':
                        out.append('\n')
                    i += 1
            continue
        if source.startswith('"""', i):
            i = string(i + 3, True)
            continue
        if source[i] == '"':
            i = string(i + 1, False)
            continue
        out.append(source[i])
        i += 1
    return ''.join(out)


def run_calls(code):
    """Each `run(` call in code (from swift_code) as (line, [top-level args])."""
    found = []
    for m in re.finditer(r'\brun\(', code):
        depth, j, start, args = 1, m.end(), m.end(), []
        while j < len(code) and depth:
            c = code[j]
            if c in '([{':
                depth += 1
            elif c in ')]}':
                depth -= 1
            elif c == ',' and depth == 1:
                args.append(code[start:j].strip())
                start = j + 1
            j += 1
        args.append(code[start:j - 1].strip())
        found.append((code.count('\n', 0, m.start()) + 1, args))
    return found


def step_problems(source, path, names):
    """A UI or App file's undo steps for the 3D View's own buttons: each from
    UndoStep, none typed in."""
    found = []
    labels = set(names.values())
    for line, text, before in swift_literals(source):
        if label_of(text) in labels and UNDO_CONTEXT.search(before):
            found.append(f"{path}:{line}: undo step \"{text}\" typed in (it is UndoStep's, which the names "
                         "check measures in Blender)")
    code = swift_code(source)
    for line, args in run_calls(code):
        if not args or not any(b.search(args[0]) for b in STEP_BUILDERS):
            continue
        undo = [a[len("undo:"):].strip() for a in args if a.startswith("undo:")]
        if not undo or '"' in undo[0] or not STEP_SOURCE.match(undo[0]):
            found.append(f"{path}:{line}: {args[0][:50]} runs with undo {undo[0] if undo else 'none'!r}, "
                         "not UndoStep's name")
    for m in re.finditer(r'\bvar undoName\b[^{]*\{', code):
        depth, j = 1, m.end()
        while j < len(code) and depth:
            depth += {'{': 1, '}': -1}.get(code[j], 0)
            j += 1
        if '"' in code[m.end():j]:
            found.append(f"{path}:{code.count(chr(10), 0, m.start()) + 1}: an undoName with a name typed in "
                         "(UndoStep's, which the names check measures)")
    for m in re.finditer(r'\blet \w*[uU]ndo\w*\s*(?::\s*String)?\s*=\s*"', code):
        found.append(f"{path}:{code.count(chr(10), 0, m.start()) + 1}: an undo name defined in the UI "
                     "(UndoStep's, which the names check measures)")
    return found


def scan_steps():
    names = step_names(STEP_FILE.read_text())
    found = []
    for folder in ("BlenderLocalUI", "BlenderLocalApp"):
        for path in sorted((ROOT / "Sources" / folder).rglob("*.swift")):
            found += step_problems(path.read_text(), path.relative_to(ROOT), names)
    return names, found


def scan_tree():
    found = []
    for path in sorted((ROOT / "Sources").rglob("*.swift")):
        found += problems(swift_literals(path.read_text()), path.relative_to(ROOT))
    site = ROOT / "Resources" / "python" / "site"
    for path in sorted(list(site.glob("_blenderkit_*.py")) + list((site / "bpy").rglob("*.py"))):
        found += problems(python_literals(path.read_text()), path.relative_to(ROOT), python=True)
    return found


fail = 0


def check(label, ok, detail=""):
    global fail
    print(("  PASS  " if ok else "  FAIL  ") + label + ("" if ok else "\n        " + str(detail)))
    if not ok:
        fail += 1


def main():
    print("\nThe scanner, on snippets (it has to be able to fail)")
    caught = problems(swift_literals('Button("Select Tool") { }\n'
                                     'bridge.run(x, undo: "Select All")\n'
                                     'Menu("View Style") {}\n'
                                     'Text("Editing \\(name) — Edit Mesh first")\n'
                                     'segment(tool.isRegionSelect ? tool.label : "Pivot", icon: "x")\n'),
                      "snippet.swift")
    check("an old tool name, an old undo label, an old menu, one beside an interpolation, and an "
          "old label in an expression are each caught", len(caught) == 5, caught)
    clean = problems(swift_literals('// Button("Select Tool")\n/* Menu("View Style") */\n'
                                    'Button("Tweak") {}\nText("Select All")\n'
                                    'bridge.run(x, undo: "(De)select All")\n'
                                    'let s = """\n  Pivot Point\n  """\n'), "snippet.swift")
    check("comments, Blender's names, and Select All as a label rather than an undo step pass",
          clean == [], clean)
    caught = problems(python_literals('def f():\n    """Edit Mesh in a docstring is fine."""\n'
                                      '    raise RuntimeError("Use Edit Mesh first")\n'), "snippet.py",
                      python=True)
    check("a Python message is caught, its docstring is not", len(caught) == 1, caught)

    print("\nThe 3D View's own steps, on snippets (round 4's review: two edits no check caught)")
    names = {"editMode": "Edit Mode", "duplicateElements": "Add Duplicate", "shadeSmooth": "Shade Smooth",
             "shadeFlat": "Shade Flat", "move": "Move"}
    caught = step_problems('static let editModeUndo = "Enter Edit"\n'
                           'func a() { bridge?.run(Bpy.toggleEditMode, undo: Self.editModeUndo) }\n'
                           'func b() { bridge.run(Bpy.duplicateElements, undo: "Duplicate Mesh") }\n'
                           'func c() { bridge.run(Bpy.setMode(.edit), undo: "Edit Mode") }\n'
                           'func d() { bridge.run(python, undo: "Add Duplicate") }\n'
                           'var undoName: String {\n  switch self {\n  case .translate: return "Move"\n  }\n}\n',
                           "snippet.swift", names)
    check("a step the UI names itself, a literal at a builder's call, Blender's own name typed in, and an "
          "undoName with a literal are each caught", len(caught) == 7, "\n        ".join(caught))
    clean = step_problems('// bridge.run(Bpy.duplicateElements, undo: "Duplicate Mesh")\n'
                          'func a() { bridge?.run(Bpy.toggleEditMode, undo: UndoStep.editMode) }\n'
                          'func b() { bridge.run(Bpy.duplicateElements, undo: UndoStep.duplicateElements) }\n'
                          'func c() { bridge.run(smooth ? Bpy.shadeSmooth : Bpy.shadeFlat,\n'
                          '                      undo: smooth ? UndoStep.shadeSmooth : UndoStep.shadeFlat) }\n'
                          'func d() { bridge.run(Bpy.showHide(what, editing: e), undo: what.undoName(editing: e)) }\n'
                          'func e() { bridge.run("bpy.ops.mesh.duplicate_move()", undo: "Add Duplicate (x)") }\n'
                          'Button("Shade Smooth") { }\n'
                          'var undoName: String {\n  switch self {\n  case .translate: return UndoStep.move\n  }\n}\n',
                          "snippet.swift", names)
    check("UndoStep's names, Show/Hide's undoName, a comment and a label pass", clean == [],
          "\n        ".join(clean))

    print("\nEvery literal the app ships")
    found = scan_tree()
    check("no old name, label or undo step is back (%d found)" % len(found), not found,
          "\n        ".join(found))
    names, found = scan_steps()
    check("UndoStep has the 3D View's steps (%d)" % len(names), len(names) >= 10, names)
    check("every step the UI and the App record for those buttons is UndoStep's (%d found)" % len(found),
          not found, "\n        ".join(found))
    print("\n" + ("ALL PASS" if not fail else "%d FAILED" % fail))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
