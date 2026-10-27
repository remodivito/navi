import Foundation
#if canImport(CoreGraphics)
import CoreGraphics   // CGPoint and CGRect; on Windows and Linux they come with Foundation
#endif

/// Which accessibility elements a pointer may lock onto. Shared by the live
/// app (`AX.snap`) and the eval, so the eval measures what ships.
public enum SnapRule {
    public static let roles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem",
        "AXMenuBarItem", "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSlider", "AXLink",
        "AXImage", "AXCell", "AXTab", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell",
        "AXSegmentedControl", "AXStaticText", "AXDockItem", "AXRow",
    ]

    /// How many parents to climb from the hit element looking for a snappable one.
    public static let maxClimb = 3

    public static func isSnappable(role: String, frame: CGRect, screenArea: CGFloat) -> Bool {
        roles.contains(role) && frame.width >= 8 && frame.height >= 8
            && frame.width * frame.height <= screenArea * 0.12
    }
}
