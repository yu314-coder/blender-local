import Foundation

/// How the Data API browser shows and reads back a value, from what Blender
/// says about its property (`_blenderkit_sync.property_info`): its kind, its
/// subtype and its unit — the way Blender's own fields show a Location in
/// metres, a rotation in degrees and a color's channels as R, G, B, A.
public enum DataAPIFormat {

    /// The labels of an array's fields: X, Y, Z for a vector, W, X, Y, Z for
    /// a quaternion or an axis-angle, R, G, B, A for a color, else 1, 2, 3.
    public static func componentLabels(subtype: String?, count: Int) -> [String] {
        let letters: [String]
        switch subtype ?? "NONE" {
        case "XYZ", "XYZ_LENGTH", "TRANSLATION", "EULER", "DIRECTION", "VELOCITY", "ACCELERATION", "COORDINATES":
            letters = ["X", "Y", "Z", "W"]
        case "QUATERNION", "AXISANGLE":
            letters = ["W", "X", "Y", "Z"]
        case "COLOR", "COLOR_GAMMA":
            letters = ["R", "G", "B", "A"]
        default:
            letters = []
        }
        return (0..<count).map { $0 < letters.count ? letters[$0] : String($0 + 1) }
    }

    /// Whether the property is a color, drawn as a swatch.
    public static func isColor(subtype: String?, count: Int) -> Bool {
        (subtype == "COLOR" || subtype == "COLOR_GAMMA") && (count == 3 || count == 4)
    }

    /// The suffix the value is shown with: Blender's unit, or its subtype's
    /// (Pixel, Percentage).
    public static func suffix(unit: String?, subtype: String?) -> String {
        switch unit ?? "NONE" {
        case "LENGTH":            return " m"
        case "ROTATION":          return "°"
        case "CAMERA":            return " mm"
        case "MASS":              return " kg"
        case "TIME", "TIME_ABSOLUTE": return " s"
        case "VELOCITY":          return " m/s"
        case "ACCELERATION":      return " m/s²"
        case "AREA":              return " m²"
        case "VOLUME":            return " m³"
        case "POWER":             return " W"
        case "TEMPERATURE", "COLOR_TEMPERATURE": return " K"
        case "WAVELENGTH":        return " nm"
        case "FREQUENCY":         return " Hz"
        default: break
        }
        switch subtype ?? "NONE" {
        case "PIXEL":      return " px"
        case "PERCENTAGE": return "%"
        default:           return ""
        }
    }

    /// Blender stores a rotation in radians and shows it in degrees.
    static func shownScale(unit: String?) -> Double { unit == "ROTATION" ? 180 / .pi : 1 }

    /// The value as the browser shows it: an integer whole, a float to its
    /// property's precision (four places at most, trailing zeros dropped),
    /// with the unit after it.
    public static func format(_ value: Double, kind: String, unit: String?, subtype: String?,
                              precision: Int?) -> String {
        guard value.isFinite else { return String(value) }
        let shown = value * shownScale(unit: unit)
        let text: String
        if kind == "INT" {
            text = String(Int(shown.rounded()))
        } else {
            let places = max(1, min(precision ?? 3, unit == "ROTATION" ? 2 : 4))
            text = trimmed(String(format: "%.\(places)f", shown))
        }
        return text + suffix(unit: unit, subtype: subtype)
    }

    /// The number to edit: as shown, without the unit.
    public static func editable(_ value: Double, kind: String, unit: String?, precision: Int?) -> String {
        format(value, kind: kind, unit: unit, subtype: nil, precision: max(precision ?? 3, 4))
            .replacingOccurrences(of: suffix(unit: unit, subtype: nil), with: "")
    }

    /// What was typed, back in Blender's own units: a comma for a decimal
    /// point, a typed unit or stray spaces accepted, degrees back to radians.
    /// Nil when it is not a number, so the field keeps the value it had.
    public static func parse(_ text: String, kind: String, unit: String?, subtype: String?) -> Double? {
        var cleaned = text.replacingOccurrences(of: ",", with: ".")
        for s in [suffix(unit: unit, subtype: subtype), "°", "%"] where !s.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: s.trimmingCharacters(in: .whitespaces), with: "")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Double(cleaned), number.isFinite else { return nil }
        let value = number / shownScale(unit: unit)
        return kind == "INT" ? value.rounded() : value
    }

    /// "1.500" → "1.5", "2.000" → "2", "-0" → "0".
    static func trimmed(_ text: String) -> String {
        guard text.contains(".") else { return text == "-0" ? "0" : text }
        var t = text
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t == "-0" ? "0" : t
    }

    /// A collection link's second line: how many items it holds.
    public static func countText(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }
}
