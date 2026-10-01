import UIKit

/// A pan recogniser that only accepts Apple Pencil, and reports the pressure
/// and tilt of the touch driving it.
///
/// `UIPanGestureRecognizer` exposes translation but not force, so the touch has
/// to be inspected as it arrives.
final class PencilPanGestureRecognizer: UIPanGestureRecognizer {

    /// 0…1. Stays at a neutral 0.5 on hardware that reports no force, so
    /// pressure-scaled behaviour degrades to ordinary behaviour rather than
    /// to zero.
    private(set) var normalizedForce: CGFloat = 0.5
    /// Radians from the screen plane: π/2 is perpendicular, 0 is flat.
    private(set) var altitudeAngle: CGFloat = .pi / 2
    /// Pressure as Blender takes it from a tablet, 0 to 1. UIKit reports force
    /// with 1 as an average touch, so an average touch is half pressure and a
    /// firm one is full. 1 where no force is reported, as for a mouse.
    private(set) var pressure: Float = 1

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        maximumNumberOfTouches = 1
    }

    private func sample(_ touches: Set<UITouch>) {
        guard let touch = touches.first(where: { $0.type == .pencil }) else { return }
        if touch.maximumPossibleForce > 0 {
            normalizedForce = touch.force / touch.maximumPossibleForce
            pressure = Float(min(1, max(0, touch.force / 2)))
        }
        altitudeAngle = touch.altitudeAngle
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        sample(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        sample(touches)
    }

    /// Light contact gives fine control, firm contact moves quickly — the same
    /// relationship a real tool has with the surface.
    var sensitivity: Float {
        Float(0.35 + 1.15 * normalizedForce)
    }
}

/// A tap recogniser restricted to one touch type, so Pencil taps and finger
/// taps can be told apart.
final class TypedTapGestureRecognizer: UITapGestureRecognizer {
    init(target: Any?, action: Selector?, touchType: UITouch.TouchType) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: touchType.rawValue)]
    }
}
