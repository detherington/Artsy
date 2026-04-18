import Foundation

enum SelectionMode: String, CaseIterable, Identifiable {
    case rectangle = "Rectangle"
    case ellipse = "Ellipse"
    case freeform = "Freeform"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .rectangle: return "rectangle.dashed"
        case .ellipse: return "circle.dashed"
        case .freeform: return "lasso"
        }
    }
}

enum ShapeMode: String, CaseIterable, Identifiable {
    case rectangle = "Rectangle"
    case ellipse = "Ellipse"
    case freeform = "Freeform"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .freeform: return "scribble"
        }
    }
}

enum ToolType: String, CaseIterable, Identifiable {
    case brush = "Brush"
    case eraser = "Eraser"
    case fill = "Fill"
    case eyedropper = "Eyedropper"
    case selection = "Selection"
    case shape = "Shape"
    case pan = "Pan"

    var id: String { rawValue }

    var shortcutKey: String {
        switch self {
        case .brush: return "B"
        case .eraser: return "E"
        case .fill: return "G"
        case .eyedropper: return "I"
        case .selection: return "S"
        case .shape: return "U"
        case .pan: return "H"
        }
    }

    var iconName: String {
        switch self {
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .fill: return "paintbucket.fill"
        case .eyedropper: return "eyedropper"
        case .selection: return "rectangle.dashed"
        case .shape: return "square.on.circle"
        case .pan: return "hand.raised"
        }
    }
}
