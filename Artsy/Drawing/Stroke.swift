import Foundation

struct Stroke: Identifiable {
    let id: UUID
    let brushDescriptor: BrushDescriptor
    let color: StrokeColor
    let rawPoints: [StrokePoint]
    var interpolatedPoints: [InterpolatedPoint]?
    let layerID: UUID

    init(id: UUID = UUID(), brushDescriptor: BrushDescriptor, color: StrokeColor, rawPoints: [StrokePoint], layerID: UUID) {
        self.id = id
        self.brushDescriptor = brushDescriptor
        self.color = color
        self.rawPoints = rawPoints
        self.layerID = layerID
    }
}
