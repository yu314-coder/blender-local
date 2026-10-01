import Foundation

/// The words Python reserves, and the names a bpy script leans on.
///
/// Facts about the language rather than about drawing it, so they live beside
/// the interpreter bridge: the syntax scanner colours them and the completion
/// offers them, and neither should own the list the other reads. Keeping them
/// here is also what lets the host test suites compile the bridge on its own,
/// with no UIKit anywhere near.
public enum PythonWords {

    public static let keywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue",
        "def", "del", "elif", "else", "except", "finally", "for", "from",
        "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or",
        "pass", "raise", "return", "try", "while", "with", "yield",
        "True", "False", "None",
    ]

    /// Names worth picking out because a bpy script is mostly made of them.
    public static let builtins: Set<String> = [
        "abs", "all", "any", "bool", "dict", "dir", "enumerate", "float",
        "getattr", "hasattr", "int", "isinstance", "len", "list", "map", "max",
        "min", "print", "range", "repr", "reversed", "round", "set", "setattr",
        "sorted", "str", "sum", "tuple", "type", "zip", "self",
        "bpy", "mathutils", "math", "Vector", "Matrix", "Euler", "Quaternion",
    ]
}
