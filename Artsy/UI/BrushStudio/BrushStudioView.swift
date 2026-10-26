import SwiftUI

/// Edits the canvas's current brush, with a live preview. See `BrushStudioModel` for how
/// changes reach the canvas and the library.
struct BrushStudioView: View {
    @ObservedObject var model: BrushStudioModel
    @ObservedObject var library: BrushLibrary

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                shapeSection
                if model.stampSettings != nil {
                    smudgeSection
                    impastoSection
                    if model.stampSettings?.smudge == nil {
                        loadSection
                        bristlesSection
                    }
                    secondTipSection
                    grainSection
                    jitterSection
                }
                wetSection
                waterSection
                pressureSection
                tiltSection
                speedSection
                strokeSection
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 420, idealWidth: 440, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.white
                if let preview = model.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            HStack {
                TextField("Name", text: model.binding(\.name))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, weight: .semibold))
                Picker("", selection: model.binding(\.category)) {
                    Text("Sketching").tag(BrushCategory.sketching)
                    Text("Inking").tag(BrushCategory.inking)
                    Text("Painting").tag(BrushCategory.painting)
                }
                .labelsHidden()
                .frame(width: 110)
            }

            HStack {
                Picker("", selection: Binding(
                    get: { model.stampSettings != nil },
                    set: { model.setRendersWithDabs($0) }
                )) {
                    Text("Ribbon").tag(false)
                    Text("Dabs").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 160)
                Text(model.stampSettings == nil
                     ? "One continuous strip: crisp, for pens and inks."
                     : "Copies of a tip laid along the stroke: texture, build-up and scatter.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            if model.isBuiltIn {
                Label("Built-in brush. The first change makes a copy of it in your library.", systemImage: "lock")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
    }

    // MARK: - Sections

    private var shapeSection: some View {
        Section("Shape") {
            slider("Hardness", model.binding(\.hardness), in: 0...1, percent: true)
            Toggle("Graphite: takes a pencil grade, 2H to 6B, in the brush panel", isOn: model.binding(\.graphite))

            if model.stampSettings != nil {
                Picker("Tip", selection: model.stampBinding(\.tip, default: .round)) {
                    Text("Round").tag(StampSettings.Tip.round)
                    Text("Chalk").tag(StampSettings.Tip.chalk)
                    Text("Bristle").tag(StampSettings.Tip.bristle)
                    Text("Knife").tag(StampSettings.Tip.knife)
                    ForEach(library.textureNames, id: \.self) { name in
                        Text(name).tag(StampSettings.Tip.image(name))
                    }
                }
                slider("Spacing", model.stampBinding(\.spacing, default: 0.1), in: 0.02...1, percent: true)
                slider("Flow", model.stampBinding(\.flow, default: 0.5), in: 0.01...1, percent: true)
                Picker("Accumulation", selection: model.stampBinding(\.accumulation, default: .wash)) {
                    Text("Wash — builds to the stroke's opacity, then stops").tag(StampSettings.Accumulation.wash)
                    Text("Build-up — every pass adds more").tag(StampSettings.Accumulation.buildUp)
                }
                Toggle("Turn dabs to face along the stroke", isOn: model.stampBinding(\.followsDirection, default: false))
                slider("Spray while resting", model.stampBinding(\.holdRate, default: 0), in: 0...120, unit: " dabs/s")
            } else {
                Toggle("Fixed nib (calligraphy)", isOn: Binding(
                    get: { model.brush.fixedNibAngle != nil },
                    set: { on in model.apply { $0.fixedNibAngle = on ? .pi / 4 : nil } }
                ))
                if model.brush.fixedNibAngle != nil {
                    slider("Nib angle", Binding(
                        get: { (model.brush.fixedNibAngle ?? 0) * 180 / .pi },
                        set: { degrees in model.apply { $0.fixedNibAngle = degrees * .pi / 180 } }
                    ), in: 0...180, unit: "°")
                }
            }
        }
    }

    private var smudgeSection: some View {
        Section("Smudge") {
            Toggle("Move the paint under the brush instead of adding paint", isOn: Binding(
                get: { model.stampSettings?.smudge != nil },
                set: { on in
                    model.stampBinding(\.smudge, default: nil).wrappedValue = on ? StampSettings.Smudge() : nil
                }
            ))
            if let smudge = model.stampSettings?.smudge {
                Picker("Mode", selection: smudgeBinding(\.mode, smudge)) {
                    Text("Smearing — drags the paint along with the stroke").tag(StampSettings.Smudge.Mode.smearing)
                    Text("Dulling — blends what is under the brush, without dragging").tag(StampSettings.Smudge.Mode.dulling)
                }
                slider(smudge.mode == .smearing ? "Carry" : "Strength", smudgeBinding(\.strength, smudge), in: 0...1, percent: true)
                slider("Add brush colour", smudgeBinding(\.colorRate, smudge), in: 0...1, percent: true)
            }
        }
    }

    private var impastoSection: some View {
        Section("Thick paint") {
            Toggle("Builds up thickness that catches the light (impasto)", isOn: Binding(
                get: { model.stampSettings?.impasto != nil },
                set: { on in
                    model.stampBinding(\.impasto, default: nil).wrappedValue = on ? StampSettings.Impasto() : nil
                }
            ))
            if let impasto = model.stampSettings?.impasto {
                slider("Thickness", impastoBinding(\.thickness, impasto), in: 0...0.5, percent: true)
                slider("Pushes paint", impastoBinding(\.squeeze, impasto), in: 0...1, percent: true)
                slider("Grooves", impastoBinding(\.grooves, impasto), in: 0...1, percent: true)
            }
        }
    }

    private var bristlesSection: some View {
        Section("Bristles") {
            Toggle("A bundle of bristles: fans with pressure, parts at speed, dry-brushes at a light touch", isOn: Binding(
                get: { model.stampSettings?.bristles != nil },
                set: { on in
                    model.stampBinding(\.bristles, default: nil).wrappedValue = on ? StampSettings.Bristles() : nil
                }
            ))
            if let bristles = model.stampSettings?.bristles {
                Stepper("Clumps: \(bristles.count)", value: bristlesBinding(\.count, bristles), in: 2...24)
                slider("Fan", bristlesBinding(\.fan, bristles), in: 0...1, percent: true)
                slider("Parting", bristlesBinding(\.parting, bristles), in: 0...1, percent: true)
                slider("Dry brush", bristlesBinding(\.dryBrush, bristles), in: 0...1, percent: true)
            }
        }
    }

    private func bristlesBinding<Value>(_ keyPath: WritableKeyPath<StampSettings.Bristles, Value>,
                                        _ current: StampSettings.Bristles) -> Binding<Value> {
        Binding(
            get: { (model.stampSettings?.bristles ?? current)[keyPath: keyPath] },
            set: { value in
                model.apply { brush in
                    guard case .stamp(var settings) = brush.rendering else { return }
                    var bristles = settings.bristles ?? current
                    bristles[keyPath: keyPath] = value
                    settings.bristles = bristles
                    brush.rendering = .stamp(settings)
                }
            }
        )
    }

    private var loadSection: some View {
        Section("Loaded brush") {
            Toggle("Carries paint: runs out along a stroke and picks up what it crosses", isOn: Binding(
                get: { model.stampSettings?.load != nil },
                set: { on in
                    model.stampBinding(\.load, default: nil).wrappedValue = on ? StampSettings.Load() : nil
                }
            ))
            if let load = model.stampSettings?.load {
                slider("Load", loadBinding(\.amount, load), in: 0.05...1, percent: true)
                slider("Runs out", loadBinding(\.depletion, load), in: 0...1, percent: true)
                slider("Refills", loadBinding(\.resaturation, load), in: 0...1, percent: true)
                slider("Picks up", loadBinding(\.bleed, load), in: 0...1, percent: true)
                slider("Uneven bristles", loadBinding(\.variation, load), in: 0...1, percent: true)
                Text("Per diameter of stroke: how much of the paint on the brush comes off, how much of its own colour comes back, and how much of what is under it comes up.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var secondTipSection: some View {
        Section("Second tip") {
            Toggle("Mask each dab with a second tip", isOn: Binding(
                get: { model.stampSettings?.secondTip != nil },
                set: { on in
                    model.stampBinding(\.secondTip, default: nil).wrappedValue =
                        on ? StampSettings.SecondTip(tip: .chalk, scale: 1, angleJitter: 1) : nil
                }
            ))
            if let second = model.stampSettings?.secondTip {
                Picker("Tip", selection: secondTipBinding(\.tip, second)) {
                    Text("Chalk").tag(StampSettings.Tip.chalk)
                    Text("Bristle").tag(StampSettings.Tip.bristle)
                    Text("Knife").tag(StampSettings.Tip.knife)
                    ForEach(library.textureNames, id: \.self) { name in
                        Text(name).tag(StampSettings.Tip.image(name))
                    }
                }
                slider("Size", secondTipBinding(\.scale, second), in: 0.2...3, unit: "×")
                slider("Angle jitter", secondTipBinding(\.angleJitter, second), in: 0...1, percent: true)
            }
        }
    }

    private var grainSection: some View {
        Section("Grain") {
            Toggle("Paper grain", isOn: Binding(
                get: { model.stampSettings?.grain != nil },
                set: { on in
                    model.stampBinding(\.grain, default: nil).wrappedValue =
                        on ? StampSettings.Grain(mode: .height, scale: 1, depth: 0.6) : nil
                }
            ))
            if let grain = model.stampSettings?.grain {
                Picker("Texture", selection: grainBinding(\.texture, grain)) {
                    Text("Paper").tag(StampSettings.Grain.Texture.paper)
                    Text("Bristles").tag(StampSettings.Grain.Texture.bristles)
                    ForEach(library.textureNames, id: \.self) { name in
                        Text(name).tag(StampSettings.Grain.Texture.image(name))
                    }
                }
                Picker("Fixed to", selection: grainBinding(\.attachment, grain)) {
                    Text("Canvas — every stroke meets the same tooth").tag(StampSettings.Grain.Attachment.canvas)
                    Text("Stroke — runs along the stroke, like bristles").tag(StampSettings.Grain.Attachment.stroke)
                }
                Picker("Mode", selection: grainBinding(\.mode, grain)) {
                    Text("Multiply — tints each dab").tag(StampSettings.Grain.Mode.multiply)
                    Text("Height — light pressure reaches only the peaks").tag(StampSettings.Grain.Mode.height)
                }
                slider("Scale", grainBinding(\.scale, grain), in: 0.2...4, unit: "×")
                slider("Depth", grainBinding(\.depth, grain), in: 0...1, percent: true)
            }
        }
    }

    private var jitterSection: some View {
        Section("Jitter") {
            slider("Size", model.stampBinding(\.sizeJitter, default: 0), in: 0...1, percent: true)
            slider("Opacity", model.stampBinding(\.opacityJitter, default: 0), in: 0...1, percent: true)
            slider("Angle", model.stampBinding(\.angleJitter, default: 0), in: 0...1, percent: true)
            slider("Scatter", model.stampBinding(\.scatter, default: 0), in: 0...1, percent: true)
        }
    }

    private var pressureSection: some View {
        Section("Pressure") {
            slider("Size at lightest touch", model.binding(\.pressureDynamics.sizeMin), in: 0...1, percent: true)
            slider("Opacity at lightest touch", model.binding(\.pressureDynamics.opacityMin), in: 0...1, percent: true)
            slider("Opacity at full pressure", model.binding(\.pressureDynamics.opacityMax), in: 0...1, percent: true)
        }
    }

    private var tiltSection: some View {
        Section("Tilt") {
            Toggle("Respond to the pen leaning over", isOn: Binding(
                get: { model.brush.tiltDynamics != nil },
                set: { on in model.apply { $0.tiltDynamics = on ? TiltDynamics(sizeScale: 2, opacityScale: 0.6, aspect: 1.8) : nil } }
            ))
            if let tilt = model.brush.tiltDynamics {
                slider("Size when flat", tiltBinding(\.sizeScale, tilt), in: 0.5...4, unit: "×")
                slider("Opacity when flat", tiltBinding(\.opacityScale, tilt), in: 0.1...1, unit: "×")
                slider("Stretch when flat", tiltBinding(\.aspect, tilt), in: 1...4, unit: "×")
            }
        }
    }

    private var speedSection: some View {
        Section("Speed") {
            Toggle("Respond to the speed of the stroke", isOn: Binding(
                get: { model.brush.velocityDynamics != nil },
                set: { on in model.apply { $0.velocityDynamics = on ? VelocityDynamics(referenceSpeed: 1500, sizeScale: 0.6, opacityScale: 1) : nil } }
            ))
            if let velocity = model.brush.velocityDynamics {
                slider("Full effect at", velocityBinding(\.referenceSpeed, velocity), in: 200...5000, unit: " px/s")
                slider("Size at speed", velocityBinding(\.sizeScale, velocity), in: 0.1...1, unit: "×")
                slider("Opacity at speed", velocityBinding(\.opacityScale, velocity), in: 0.1...1, unit: "×")
            }
        }
    }

    private var strokeSection: some View {
        Section("Stroke") {
            slider("Starting size", model.binding(\.baseSize), in: 1...200, unit: " px")
            slider("Opacity", model.binding(\.opacity), in: 0.05...1, percent: true)
            slider("Smoothing", model.binding(\.smoothing), in: 0...1, percent: true)
            Picker("Colour mixing", selection: model.binding(\.mixing)) {
                Text("Light — colours average, as on a screen").tag(PaintMixing.light)
                Text("Pigment — yellow over blue makes green").tag(PaintMixing.pigment)
                Text("Glaze — a transparent wash that darkens what is under it").tag(PaintMixing.glaze)
            }
        }
    }

    private var wetSection: some View {
        Section("Wet") {
            slider("Stays wet", model.binding(\.wetness), in: 0...1, percent: true)
            Toggle("Dries as a wash: crisp edges where the pigment gathers", isOn: Binding(
                get: { model.brush.wet != nil },
                set: { on in model.apply { $0.wet = on ? BrushDescriptor.Wet() : nil } }
            ))
            if let wet = model.brush.wet {
                slider("Edges", wetBinding(\.edges, wet), in: 0...1, percent: true)
                slider("Granulation", wetBinding(\.granulation, wet), in: 0...1, percent: true)
                slider("Paper scale", wetBinding(\.grainScale, wet), in: 0.2...4, unit: "×")
                slider("Blends when wet", wetBinding(\.blendsWhenWet, wet), in: 0...1, percent: true)
            }
        }
    }

    private var waterSection: some View {
        Section("Water") {
            Toggle("Flows: lays water that spreads, runs with the canvas tilt and dries from the edges in", isOn: Binding(
                get: { model.brush.water != nil },
                set: { on in model.apply { $0.water = on ? BrushDescriptor.Water() : nil } }
            ))
            if let water = model.brush.water {
                slider("Amount", waterBinding(\.amount, water), in: 0...1, percent: true)
                slider("Flow", waterBinding(\.flow, water), in: 0...1, percent: true)
                slider("Settling", waterBinding(\.settling, water), in: 0...1, percent: true)
                slider("Granulation", waterBinding(\.granulation, water), in: 0...1, percent: true)
            }
        }
    }

    // MARK: - Bindings into nested settings

    private func waterBinding<Value>(_ keyPath: WritableKeyPath<BrushDescriptor.Water, Value>,
                                     _ current: BrushDescriptor.Water) -> Binding<Value> {
        Binding(
            get: { (model.brush.water ?? current)[keyPath: keyPath] },
            set: { value in
                model.apply { brush in
                    var water = brush.water ?? current
                    water[keyPath: keyPath] = value
                    brush.water = water
                }
            }
        )
    }

    private func grainBinding<Value>(_ keyPath: WritableKeyPath<StampSettings.Grain, Value>,
                                     _ current: StampSettings.Grain) -> Binding<Value> {
        Binding(
            get: { (model.stampSettings?.grain ?? current)[keyPath: keyPath] },
            set: { value in
                var grain = model.stampSettings?.grain ?? current
                grain[keyPath: keyPath] = value
                model.stampBinding(\.grain, default: nil).wrappedValue = grain
            }
        )
    }

    private func smudgeBinding<Value>(_ keyPath: WritableKeyPath<StampSettings.Smudge, Value>,
                                      _ current: StampSettings.Smudge) -> Binding<Value> {
        Binding(
            get: { (model.stampSettings?.smudge ?? current)[keyPath: keyPath] },
            set: { value in
                var smudge = model.stampSettings?.smudge ?? current
                smudge[keyPath: keyPath] = value
                model.stampBinding(\.smudge, default: nil).wrappedValue = smudge
            }
        )
    }

    private func loadBinding<Value>(_ keyPath: WritableKeyPath<StampSettings.Load, Value>,
                                    _ current: StampSettings.Load) -> Binding<Value> {
        Binding(
            get: { (model.stampSettings?.load ?? current)[keyPath: keyPath] },
            set: { value in
                var load = model.stampSettings?.load ?? current
                load[keyPath: keyPath] = value
                model.stampBinding(\.load, default: nil).wrappedValue = load
            }
        )
    }

    private func impastoBinding<Value>(_ keyPath: WritableKeyPath<StampSettings.Impasto, Value>,
                                       _ current: StampSettings.Impasto) -> Binding<Value> {
        Binding(
            get: { (model.stampSettings?.impasto ?? current)[keyPath: keyPath] },
            set: { value in
                var impasto = model.stampSettings?.impasto ?? current
                impasto[keyPath: keyPath] = value
                model.stampBinding(\.impasto, default: nil).wrappedValue = impasto
            }
        )
    }

    private func secondTipBinding<Value>(_ keyPath: WritableKeyPath<StampSettings.SecondTip, Value>,
                                         _ current: StampSettings.SecondTip) -> Binding<Value> {
        Binding(
            get: { (model.stampSettings?.secondTip ?? current)[keyPath: keyPath] },
            set: { value in
                var second = model.stampSettings?.secondTip ?? current
                second[keyPath: keyPath] = value
                model.stampBinding(\.secondTip, default: nil).wrappedValue = second
            }
        )
    }

    private func wetBinding<Value>(_ keyPath: WritableKeyPath<BrushDescriptor.Wet, Value>,
                                   _ current: BrushDescriptor.Wet) -> Binding<Value> {
        Binding(
            get: { (model.brush.wet ?? current)[keyPath: keyPath] },
            set: { value in
                model.apply { brush in
                    var wet = brush.wet ?? current
                    wet[keyPath: keyPath] = value
                    brush.wet = wet
                }
            }
        )
    }

    private func tiltBinding<Value>(_ keyPath: WritableKeyPath<TiltDynamics, Value>, _ current: TiltDynamics) -> Binding<Value> {
        Binding(
            get: { (model.brush.tiltDynamics ?? current)[keyPath: keyPath] },
            set: { value in
                model.apply { brush in
                    var tilt = brush.tiltDynamics ?? current
                    tilt[keyPath: keyPath] = value
                    brush.tiltDynamics = tilt
                }
            }
        )
    }

    private func velocityBinding<Value>(_ keyPath: WritableKeyPath<VelocityDynamics, Value>,
                                        _ current: VelocityDynamics) -> Binding<Value> {
        Binding(
            get: { (model.brush.velocityDynamics ?? current)[keyPath: keyPath] },
            set: { value in
                model.apply { brush in
                    var velocity = brush.velocityDynamics ?? current
                    velocity[keyPath: keyPath] = value
                    brush.velocityDynamics = velocity
                }
            }
        )
    }

    // MARK: - Controls

    private func slider(_ title: String, _ value: Binding<Float>, in range: ClosedRange<Float>,
                        percent: Bool = false, unit: String = "") -> some View {
        HStack {
            Text(title)
                .frame(width: 160, alignment: .leading)
            Slider(value: value, in: range)
            Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : formatted(value.wrappedValue) + unit)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
    }

    private func formatted(_ value: Float) -> String {
        value == value.rounded() || value >= 100 ? String(Int(value.rounded())) : String(format: "%.2f", value)
    }
}
