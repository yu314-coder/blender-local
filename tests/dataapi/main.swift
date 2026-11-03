import Foundation

// The Data API browser's values (DataAPIFormat.swift): shown with Blender's
// units and labels, read back in Blender's own units. What Blender says about
// each property is scripts/run-dataapi-blender-check.sh.
//
//     scripts/run-dataapi-tests.sh

var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "  PASS  " : "  FAIL  ") + label + (ok ? "" : "\n        " + detail()))
    if !ok { failures += 1 }
}

print("labels")
check("a Translation is X, Y, Z", DataAPIFormat.componentLabels(subtype: "TRANSLATION", count: 3) == ["X", "Y", "Z"])
check("a Quaternion is W, X, Y, Z", DataAPIFormat.componentLabels(subtype: "QUATERNION", count: 4) == ["W", "X", "Y", "Z"])
check("a Color is R, G, B, A", DataAPIFormat.componentLabels(subtype: "COLOR", count: 4) == ["R", "G", "B", "A"])
check("anything else is numbered from 1", DataAPIFormat.componentLabels(subtype: "NONE", count: 3) == ["1", "2", "3"])
check("a three- or four-long Color is a swatch", DataAPIFormat.isColor(subtype: "COLOR_GAMMA", count: 3)
      && !DataAPIFormat.isColor(subtype: "COLOR", count: 2) && !DataAPIFormat.isColor(subtype: "XYZ", count: 3))

print("\nshown")
let f = DataAPIFormat.format
check("a Length in metres, trailing zeros dropped", f(1.5, "FLOAT", "LENGTH", "DISTANCE", 5) == "1.5 m", f(1.5, "FLOAT", "LENGTH", "DISTANCE", 5))
check("zero is 0 m, never -0", f(-0.0, "FLOAT", "LENGTH", "TRANSLATION", 5) == "0 m", f(-0.0, "FLOAT", "LENGTH", "TRANSLATION", 5))
check("a Rotation in degrees", f(Double.pi / 2, "FLOAT", "ROTATION", "EULER", 5) == "90°", f(Double.pi / 2, "FLOAT", "ROTATION", "EULER", 5))
check("a Percentage integer", f(100, "INT", "NONE", "PERCENTAGE", 0) == "100%")
check("a camera lens in millimetres", f(50, "FLOAT", "CAMERA", "DISTANCE_CAMERA", 1) == "50 mm")
check("a plain float to its precision", f(0.123456, "FLOAT", "NONE", "NONE", 3) == "0.123")
check("pixels", f(1920, "INT", "NONE", "PIXEL", 0) == "1920 px")

print("\nread back")
let p = DataAPIFormat.parse
check("degrees typed become radians", abs((p("90", "FLOAT", "ROTATION", "EULER") ?? 0) - Double.pi / 2) < 1e-12)
check("a typed unit and a comma are accepted", p("1,5 m", "FLOAT", "LENGTH", "DISTANCE") == 1.5)
check("an integer rounds", p("3.6", "INT", "NONE", "NONE") == 4)
check("a percentage sign is accepted", p("50%", "INT", "NONE", "PERCENTAGE") == 50)
check("not a number is nil", p("abc", "FLOAT", "NONE", "NONE") == nil)
check("editing shows the number without its unit",
      DataAPIFormat.editable(Double.pi, kind: "FLOAT", unit: "ROTATION", precision: 5) == "180"
      && DataAPIFormat.editable(2.25, kind: "FLOAT", unit: "LENGTH", precision: 5) == "2.25",
      DataAPIFormat.editable(Double.pi, kind: "FLOAT", unit: "ROTATION", precision: 5))
check("a collection's count", DataAPIFormat.countText(1) == "1 item" && DataAPIFormat.countText(3) == "3 items")

print("\n" + (failures == 0 ? "ALL PASS" : "\(failures) FAILED"))
exit(failures == 0 ? 0 : 1)
