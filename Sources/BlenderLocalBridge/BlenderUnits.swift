import Foundation

/// Blender's scene units, and how Blender writes a length, an area or an
/// angle with them: `BKE_unit_value_as_string_scaled` and
/// `BKE_unit_value_as_string` (blenkernel/intern/unit.cc in the 5.3 source),
/// ported line for line.
///
/// The Measure tool's rulers and Edit Mode's Edge Length, Face Area, Edge
/// Angle and Face Angle print their numbers through these two functions, and
/// no Python API reaches them: `bpy.utils.units.to_string` is the adaptive
/// variant, which ignores the scene's Length unit (measured in desktop 5.2.1:
/// 0.02 with Metric and Length Meters is "0.02 m" from Blender's C and
/// "2 cm" from `to_string`). So the strings are made here, from the settings
/// the mirror reads off `scene.unit_settings` (`_blenderkit_cursor.units_record`),
/// and scripts/run-measure-blender-check.sh holds every one of them to
/// Blender's own C function, called through ctypes in desktop Blender.
public struct UnitSettings: Equatable, Sendable {
    /// `UnitSettings.system`.
    public enum System: String, Sendable { case none = "NONE", metric = "METRIC", imperial = "IMPERIAL" }
    /// `UnitSettings.system_rotation`.
    public enum Rotation: String, Sendable { case degrees = "DEGREES", radians = "RADIANS" }

    public var system: System = .metric
    public var rotation: Rotation = .degrees
    /// `scale_length`, a float in Blender.
    public var scaleLength: Float = 1
    /// `length_unit`'s identifier: `ADAPTIVE` or one of the collection's.
    public var lengthUnit = "METERS"
    /// `use_separate`: Separate Units.
    public var separate = false
    /// The 3D View's `overlay.grid_scale`, which Edit Mode's measurements
    /// take their precision from when the scene has no unit system
    /// (`DRW_text_edit_mesh_measure_stats`: `unit.system ? unit.scale_length : v3d->grid`).
    public var grid: Float = 1

    public init(system: System = .metric, rotation: Rotation = .degrees, scaleLength: Float = 1,
                lengthUnit: String = "METERS", separate: Bool = false, grid: Float = 1) {
        self.system = system; self.rotation = rotation; self.scaleLength = scaleLength
        self.lengthUnit = lengthUnit; self.separate = separate; self.grid = grid
    }

    /// Blender's factory scene: Metric, Degrees, 1.0, Meters (5.2.1).
    public static let factory = UnitSettings()

    /// `system=METRIC;rotation=DEGREES;scale=1;length=METERS;split=0;grid=1`,
    /// as `_blenderkit_cursor.units_record` writes it; nil for anything else.
    public init?(record: String) {
        var fields: [String: String] = [:]
        for part in record.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            fields[pair[0]] = pair[1]
        }
        guard let system = fields["system"].flatMap(System.init(rawValue:)),
              let rotation = fields["rotation"].flatMap(Rotation.init(rawValue:)),
              let scale = fields["scale"].flatMap(Float.init), scale.isFinite,
              let length = fields["length"], !length.isEmpty,
              let split = fields["split"], let grid = fields["grid"].flatMap(Float.init), grid.isFinite
        else { return nil }
        self.init(system: system, rotation: rotation, scaleLength: scale, lengthUnit: length,
                  separate: split == "1", grid: grid)
    }
}

public enum BlenderUnits {
    /// `B_UNIT_LENGTH`, `B_UNIT_AREA`, `B_UNIT_ROTATION`: the three kinds a
    /// measurement prints.
    public enum Kind: Sendable { case length, area, rotation }

    struct Unit {
        let short: String
        let scalar: Double
        let suppress: Bool
        let tenth: Bool
        let noSpace: Bool
        let identifier: String?
    }

    struct Collection {
        let units: [Unit]
        let base: Int
    }

    // The scalars are `float` macros stored into a double, so 0.01 is
    // 0.009999999776482582 here as in Blender (`UN_SC_CM 0.01f`), and an area
    // is the float product (`UN_SC_CM * UN_SC_CM`).
    private static func f(_ x: Float) -> Double { Double(x) }
    private static func f2(_ x: Float) -> Double { Double(x * x) }

    static let metricLength = Collection(units: [
        Unit(short: "km", scalar: f(1000), suppress: false, tenth: false, noSpace: false, identifier: "KILOMETERS"),
        Unit(short: "hm", scalar: f(100), suppress: true, tenth: false, noSpace: false, identifier: "HECTOMETERS"),
        Unit(short: "dam", scalar: f(10), suppress: true, tenth: false, noSpace: false, identifier: "DEKAMETERS"),
        Unit(short: "m", scalar: f(1), suppress: false, tenth: false, noSpace: false, identifier: "METERS"),
        Unit(short: "dm", scalar: f(0.1), suppress: true, tenth: false, noSpace: false, identifier: "DECIMETERS"),
        Unit(short: "cm", scalar: f(0.01), suppress: false, tenth: false, noSpace: false, identifier: "CENTIMETERS"),
        Unit(short: "mm", scalar: f(0.001), suppress: false, tenth: true, noSpace: false, identifier: "MILLIMETERS"),
        Unit(short: "µm", scalar: f(0.000001), suppress: false, tenth: false, noSpace: false, identifier: "MICROMETERS"),
        // Nanometers and picometers are in unit.cc under `#if 0` ("float
        // precision problems in the transform header").
    ], base: 3)

    static let imperialLength = Collection(units: [
        Unit(short: "mi", scalar: f(1609.344), suppress: false, tenth: false, noSpace: false, identifier: "MILES"),
        Unit(short: "fur", scalar: f(201.168), suppress: true, tenth: false, noSpace: false, identifier: "FURLONGS"),
        Unit(short: "ch", scalar: f(20.1168), suppress: true, tenth: false, noSpace: false, identifier: "CHAINS"),
        Unit(short: "yd", scalar: f(0.9144), suppress: true, tenth: false, noSpace: false, identifier: "YARDS"),
        Unit(short: "'", scalar: f(0.3048), suppress: false, tenth: false, noSpace: true, identifier: "FEET"),
        Unit(short: "\"", scalar: f(0.0254), suppress: false, tenth: false, noSpace: true, identifier: "INCHES"),
        Unit(short: "thou", scalar: f(0.0000254), suppress: false, tenth: false, noSpace: false, identifier: "THOU"),
    ], base: 4)

    static let metricArea = Collection(units: [
        Unit(short: "km²", scalar: f2(1000), suppress: false, tenth: false, noSpace: false, identifier: nil),
        Unit(short: "hm²", scalar: f2(100), suppress: true, tenth: false, noSpace: false, identifier: nil),
        Unit(short: "dam²", scalar: f2(10), suppress: true, tenth: false, noSpace: false, identifier: nil),
        Unit(short: "m²", scalar: f2(1), suppress: false, tenth: false, noSpace: false, identifier: nil),
        Unit(short: "dm²", scalar: f2(0.1), suppress: true, tenth: false, noSpace: false, identifier: nil),
        Unit(short: "cm²", scalar: f2(0.01), suppress: false, tenth: false, noSpace: false, identifier: nil),
        Unit(short: "mm²", scalar: f2(0.001), suppress: false, tenth: true, noSpace: false, identifier: nil),
        Unit(short: "µm²", scalar: f2(0.000001), suppress: false, tenth: false, noSpace: false, identifier: nil),
    ], base: 3)

    static let imperialArea = Collection(units: [
        Unit(short: "sq mi", scalar: f2(1609.344), suppress: false, tenth: false, noSpace: false, identifier: nil),
        Unit(short: "sq fur", scalar: f2(201.168), suppress: true, tenth: false, noSpace: false, identifier: nil),
        Unit(short: "sq ch", scalar: f2(20.1168), suppress: true, tenth: false, noSpace: false, identifier: nil),
        Unit(short: "sq yd", scalar: f2(0.9144), suppress: false, tenth: false, noSpace: false, identifier: nil),
        Unit(short: "sq ft", scalar: f2(0.3048), suppress: false, tenth: false, noSpace: false, identifier: nil),
        Unit(short: "sq in", scalar: f2(0.0254), suppress: false, tenth: false, noSpace: false, identifier: nil),
        Unit(short: "sq mil", scalar: f2(0.0000254), suppress: false, tenth: false, noSpace: false, identifier: nil),
    ], base: 4)

    /// `buNaturalRotCollection`, every system's rotation.
    static let rotation = Collection(units: [
        Unit(short: "°", scalar: Double.pi / 180, suppress: false, tenth: false, noSpace: true, identifier: "DEGREES"),
        Unit(short: "'", scalar: (Double.pi / 180) / 60, suppress: true, tenth: false, noSpace: true, identifier: "ARCMINUTES"),
        Unit(short: "\"", scalar: (Double.pi / 180) / 3600, suppress: true, tenth: false, noSpace: true, identifier: "ARCSECONDS"),
        Unit(short: "rad", scalar: 1, suppress: false, tenth: false, noSpace: false, identifier: "RADIANS"),
        // Turns are under `#if 0` too.
    ], base: 0)

    /// `buDummyCollection`: what a system without the kind falls back to.
    static let dummy = Collection(units: [
        Unit(short: "", scalar: 1, suppress: false, tenth: false, noSpace: false, identifier: nil),
    ], base: 0)

    /// `bUnitSystems[system][type]`; nil where Blender's table has nullptr.
    static func collection(_ system: UnitSettings.System, _ kind: Kind) -> Collection? {
        switch (system, kind) {
        case (_, .rotation):          return rotation
        case (.metric, .length):      return metricLength
        case (.metric, .area):        return metricArea
        case (.imperial, .length):    return imperialLength
        case (.imperial, .area):      return imperialArea
        case (.none, _):              return nil
        }
    }

    /// `EPS` in unit.cc.
    private static let eps = 0.001

    /// `integer_digits_d`.
    static func integerDigits(_ d: Double) -> Int {
        d == 0 ? 0 : Int(floor(log10(abs(d)))) + 1
    }

    /// `unit_best_fit`.
    static func bestFit(_ value: Double, _ usys: Collection, start: Int = 0, suppress: Bool = true) -> Int {
        let valueAbs = value > 0 ? value : -value
        var i = start
        while i < usys.units.count {
            let unit = usys.units[i]
            defer { i += 1 }
            if suppress && unit.suppress { continue }
            if unit.tenth {
                if valueAbs >= unit.scalar * (0.1 - eps) { return i }
            } else if valueAbs >= unit.scalar * (1.0 - eps) {
                return i
            }
        }
        return usys.base
    }

    /// `unit_as_string` with `pad` off (every caller here passes false) and
    /// the suffix on.
    static func asString(_ value: Double, prec precIn: Int, variableWidth: Bool, _ usys: Collection,
                         unit unitIndex: Int?) -> String {
        let index = unitIndex ?? (value == 0 ? usys.base : bestFit(value, usys))
        let unit = usys.units[index]
        let valueConv = value / unit.scalar
        var prec = precIn
        if variableWidth { prec -= integerDigits(valueConv) }
        prec = min(max(prec, 0), 6)
        var text = String(format: "%.*f", prec, valueConv)
        if prec > 0, variableWidth {
            // 4.300 -> 4.3, 10. -> 10 (the pad is '\0', so they are cut).
            var chars = Array(text)
            var i = chars.count - 1
            while i > 0 && chars[i] == "0" { i -= 1 }
            if i > 0 && chars[i] == "." { i -= 1 }
            chars = Array(chars[0...i])
            text = String(chars)
        }
        if !unit.noSpace { text += " " }
        return text + unit.short
    }

    static func shouldSplit(_ kind: Kind) -> Bool { kind == .length }

    /// `unit_as_string_split_pair`; nil where Blender returns -1.
    static func splitPair(_ value: Double, prec precIn: Int, variableWidth: Bool, _ usys: Collection,
                          main: Int?) -> String? {
        let unitA = main ?? bestFit(value, usys)
        let scaled = value / usys.units[unitA].scalar
        let valueA = scaled.rounded(.towardZero) * usys.units[unitA].scalar
        let valueB = value - valueA
        let unitB = bestFit(valueB, usys, start: unitA)
        guard unitB > unitA else { return nil }
        let first = asString(valueA, prec: precIn, variableWidth: true, usys, unit: unitA)
        var prec = precIn
        if variableWidth {
            let b = usys.units[unitB].scalar
            prec -= integerDigits(valueA / b) - integerDigits(valueB / b)
            prec = max(prec, 0)
        }
        return first + " " + asString(valueB, prec: prec, variableWidth: variableWidth, usys, unit: unitB)
    }

    /// `get_preferred_display_unit_index_if_used`.
    static func preferredIndex(_ kind: Kind, _ settings: UnitSettings, _ usys: Collection) -> Int? {
        switch kind {
        case .length, .area:
            guard settings.lengthUnit != "ADAPTIVE" else { return nil }
            // `units.length` is the enum's value, the unit's index in the
            // length collection (`rna_UnitSettings_itemf_wrapper`), clamped
            // to the collection — the area one is shorter.
            guard let index = (settings.system == .imperial ? imperialLength : metricLength).units
                .firstIndex(where: { $0.identifier == settings.lengthUnit }) else { return nil }
            return min(index, usys.units.count - 1)
        case .rotation:
            return settings.rotation == .radians ? 3 : 0
        }
    }

    /// `BKE_unit_value_as_string` (`scaled` false) or
    /// `BKE_unit_value_as_string_scaled` (true), `pad` off, the unit's suffix
    /// on — what the ruler and the measurement overlays call.
    public static func string(_ value: Double, prec: Int, kind: Kind, settings: UnitSettings,
                              scaled: Bool = true) -> String {
        var value = value
        if scaled, settings.system != .none {
            // BKE_unit_value_scale.
            let s = Double(settings.scaleLength)
            switch kind {
            case .length:   value *= s
            case .area:     value *= pow(s, 2)
            case .rotation: break
            }
        }
        var usys = dummy
        var main: Int?
        if let found = collection(settings.system, kind) {
            usys = found
            main = preferredIndex(kind, settings, found)
        }
        var variableWidth = true
        var prec = prec
        if prec < 0 { prec = -prec; variableWidth = false }
        if settings.separate, shouldSplit(kind),
           let split = splitPair(value, prec: prec, variableWidth: variableWidth, usys, main: main) {
            return split
        }
        return asString(value, prec: prec, variableWidth: variableWidth, usys, unit: main)
    }

    /// The precision Edit Mode's Edge Length and Face Area use without a
    /// unit system: proportionate to the grid (`conv_float` in
    /// `DRW_text_edit_mesh_measure_stats`), for `String(format:)`.
    public static func overlayFormat(grid: Float) -> String {
        if grid <= 0.01 { return "%.6g" }
        if grid <= 0.1 { return "%.5g" }
        if grid <= 1.0 { return "%.4g" }
        if grid <= 10.0 { return "%.3g" }
        return "%.2g"
    }
}
