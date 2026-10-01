import Foundation

/// Blender's two flags for not drawing an object, as the simulator's shim
/// keeps them: the view layer's hide (`hide_get()` — H, Alt+H, the Outliner's
/// eye) and Disable in Viewports (`hide_viewport` — the Outliner's monitor).
/// On device the flags live in Blender and the mirror reads them back; here
/// they are the whole of it, so these follow what Blender 5.2.1 was measured
/// doing, and the host suites run them (tests/mirror).
public extension BKScene {

    /// `Object.hide_set(state)` (`inViewLayer`) or `hide_viewport = state`.
    ///
    /// Hiding either way deselects, and showing selects nothing: measured,
    /// `hide_set(True)` left a selected cube with `select_get()` False, and
    /// so did `hide_viewport = True`, which stayed False once set back.
    func setHidden(_ obj: BKObject, _ hidden: Bool, inViewLayer: Bool) {
        if inViewLayer { obj.hiddenInViewLayer = hidden } else { obj.disabledInViewports = hidden }
        obj.visible = !obj.hiddenInViewLayer && !obj.disabledInViewports
        if hidden { selection.remove(obj.id) }
    }

    /// `object.hide_view_set`: the drawn objects that are selected, or with
    /// `unselected` every drawn one that is not. How many it hid; 0 is
    /// Blender's CANCELLED.
    @discardableResult
    func hideObjects(unselected: Bool) -> Int {
        let targets = objects.filter { $0.visible && selection.contains($0.id) != unselected }
        for obj in targets { setHidden(obj, true, inViewLayer: true) }
        return targets.count
    }

    /// `object.hide_view_clear`: clears the view layer's hide on every
    /// object that has it, and selects what that brings back.
    ///
    /// An object that is also disabled in viewports has its hide cleared all
    /// the same, stays disabled, and is not selected — it cannot be, not being
    /// drawn. Measured in 5.2.1: FINISHED, `hide_get()` False, `hide_viewport`
    /// still True, `select_get()` False. The shim used to skip such an object
    /// and answer CANCELLED, which the app reports as "nothing is hidden". An
    /// object disabled and not hidden is left alone, and alone it is
    /// CANCELLED. How many it changed; 0 is Blender's CANCELLED.
    @discardableResult
    func showHiddenObjects(select: Bool) -> Int {
        let targets = objects.filter(\.hiddenInViewLayer)
        for obj in targets {
            obj.hiddenInViewLayer = false
            obj.visible = !obj.disabledInViewports
            if select && obj.visible { selection.insert(obj.id) }
        }
        return targets.count
    }
}
