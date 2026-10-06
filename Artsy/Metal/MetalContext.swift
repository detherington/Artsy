import Metal
import MetalKit

final class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary

    // Pipeline states
    let strokeProceduralPipelineState: MTLRenderPipelineState
    /// Dabs of a stamp brush, blended source-over into the stroke texture.
    let stampPipelineState: MTLRenderPipelineState
    /// Dabs as paint thickness, added to a layer's height map
    let stampHeightPipelineState: MTLRenderPipelineState
    /// Height maps: a layer's added into the composite's, erased by a stroke, cleared, and
    /// stamped through an affine transform
    let heightAccumulatePipelineState: MTLRenderPipelineState
    let heightErasePipelineState: MTLRenderPipelineState
    let clearHeightPipelineState: MTLRenderPipelineState
    let heightAffinePipelineState: MTLRenderPipelineState
    /// Smudge brushes: lays carried paint into the layer, then picks up what is under the dab
    let smudgeDepositPipelineState: MTLRenderPipelineState
    let smudgePickupPipelineState: MTLRenderPipelineState
    /// The same for the paint's thickness, on a layer's height map
    let smudgeDepositHeightPipelineState: MTLRenderPipelineState
    let smudgePickupHeightPipelineState: MTLRenderPipelineState
    /// Merges a finished stroke into its layer when fixed-function blending will not do
    let compositeStrokeMergePipelineState: MTLRenderPipelineState
    /// Mixes colours as pigments, for tests and tools
    let mixPigmentsPipelineState: MTLComputePipelineState
    /// Tips and paper grain for stamp brushes.
    let brushTextures: BrushTextureLibrary
    // Radial-distance variants for stroke caps (rounded endpoints, Procreate-style)
    let strokeRadialPipelineState: MTLRenderPipelineState
    let compositeNormalPipelineState: MTLRenderPipelineState
    let compositeBlendPipelineState: MTLRenderPipelineState
    // Active-layer variants that merge the in-progress stroke into the layer first
    let compositeNormalWithStrokePipelineState: MTLRenderPipelineState
    let compositeBlendWithStrokePipelineState: MTLRenderPipelineState
    /// Removes the source's coverage from the destination (eraser strokes).
    let compositeErasePipelineState: MTLRenderPipelineState
    /// Writes transparent black; used under a scissor rect to clear part of a texture.
    let clearPipelineState: MTLRenderPipelineState
    /// Shrinks a texture to a quarter of its size with a box filter.
    let downsamplePipelineState: MTLRenderPipelineState
    let displayPipelineState: MTLRenderPipelineState
    /// The display pass into a half-float target, for 16-bit export
    let display16PipelineState: MTLRenderPipelineState
    /// Flags textures that differ, for undo snapshots that share unchanged layers
    let texturesDifferPipelineState: MTLComputePipelineState
    let maskedCutPipelineState: MTLComputePipelineState
    let maskedClearPipelineState: MTLComputePipelineState
    let maskedFillPipelineState: MTLComputePipelineState

    // Vertex descriptors
    let strokeVertexDescriptor: MTLVertexDescriptor
    let compositeVertexDescriptor: MTLVertexDescriptor

    // Samplers
    let linearSampler: MTLSamplerState
    let nearestSampler: MTLSamplerState
    /// Trilinear, clamped to the edge: brush tips at any size.
    let tipSampler: MTLSamplerState
    /// Trilinear, repeating: the paper grain tiles across the canvas.
    let grainSampler: MTLSamplerState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalError.noDevice
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalError.noCommandQueue
        }
        self.commandQueue = commandQueue

        guard let library = device.makeDefaultLibrary() else {
            throw MetalError.noLibrary
        }
        self.library = library

        // --- Vertex Descriptors ---

        // Stroke vertex: position (float2), texCoord (float2), opacity (float)
        let strokeVD = MTLVertexDescriptor()
        strokeVD.attributes[0].format = .float2
        strokeVD.attributes[0].offset = 0
        strokeVD.attributes[0].bufferIndex = 0
        strokeVD.attributes[1].format = .float2
        strokeVD.attributes[1].offset = MemoryLayout<Float>.size * 2
        strokeVD.attributes[1].bufferIndex = 0
        strokeVD.attributes[2].format = .float
        strokeVD.attributes[2].offset = MemoryLayout<Float>.size * 4
        strokeVD.attributes[2].bufferIndex = 0
        strokeVD.layouts[0].stride = MemoryLayout<Float>.size * 5
        strokeVD.layouts[0].stepFunction = .perVertex
        self.strokeVertexDescriptor = strokeVD

        // Composite vertex: position (float2), texCoord (float2)
        let compVD = MTLVertexDescriptor()
        compVD.attributes[0].format = .float2
        compVD.attributes[0].offset = 0
        compVD.attributes[0].bufferIndex = 0
        compVD.attributes[1].format = .float2
        compVD.attributes[1].offset = MemoryLayout<Float>.size * 2
        compVD.attributes[1].bufferIndex = 0
        compVD.layouts[0].stride = MemoryLayout<Float>.size * 4
        compVD.layouts[0].stepFunction = .perVertex
        self.compositeVertexDescriptor = compVD

        // --- Pipeline States ---

        // Stroke procedural (soft/hard round)
        self.strokeProceduralPipelineState = try MetalContext.makeStrokePipeline(
            device: device, library: library, vertexDescriptor: strokeVD,
            fragmentFunction: "strokeProceduralFragment"
        )

        // Stamp brushes: instanced dabs, premultiplied source-over
        let stampDesc = MTLRenderPipelineDescriptor()
        stampDesc.vertexFunction = try Self.function("stampVertex", in: library)
        stampDesc.fragmentFunction = try Self.function("stampFragment", in: library)
        stampDesc.colorAttachments[0].pixelFormat = .rgba16Float
        let stampAttachment = stampDesc.colorAttachments[0]!
        stampAttachment.isBlendingEnabled = true
        stampAttachment.rgbBlendOperation = .add
        stampAttachment.alphaBlendOperation = .add
        stampAttachment.sourceRGBBlendFactor = .one
        stampAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        stampAttachment.sourceAlphaBlendFactor = .one
        stampAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.stampPipelineState = try device.makeRenderPipelineState(descriptor: stampDesc)

        let stampHeightDesc = MTLRenderPipelineDescriptor()
        stampHeightDesc.vertexFunction = try Self.function("stampVertex", in: library)
        guard let stampHeightFragment = library.makeFunction(name: "stampHeightFragment") else {
            throw MetalError.pipelineCreationFailed("stampHeightFragment not found")
        }
        stampHeightDesc.fragmentFunction = stampHeightFragment
        stampHeightDesc.colorAttachments[0].pixelFormat = .r16Float
        let stampHeightAttachment = stampHeightDesc.colorAttachments[0]!
        stampHeightAttachment.isBlendingEnabled = true
        stampHeightAttachment.rgbBlendOperation = .add
        stampHeightAttachment.alphaBlendOperation = .add
        stampHeightAttachment.sourceRGBBlendFactor = .one
        stampHeightAttachment.destinationRGBBlendFactor = .one
        stampHeightAttachment.sourceAlphaBlendFactor = .one
        stampHeightAttachment.destinationAlphaBlendFactor = .one
        self.stampHeightPipelineState = try device.makeRenderPipelineState(descriptor: stampHeightDesc)

        // Smudge deposit: the same quads, drawn straight onto the layer. The fragment reads
        // the layer from a copy of the patch under the dab and writes the mix itself.
        let smudgeDesc = MTLRenderPipelineDescriptor()
        smudgeDesc.vertexFunction = try Self.function("stampVertex", in: library)
        smudgeDesc.fragmentFunction = try Self.function("smudgeDepositFragment", in: library)
        smudgeDesc.colorAttachments[0].pixelFormat = .rgba16Float
        smudgeDesc.colorAttachments[0].isBlendingEnabled = false
        self.smudgeDepositPipelineState = try device.makeRenderPipelineState(descriptor: smudgeDesc)

        let pickupDesc = MTLRenderPipelineDescriptor()
        pickupDesc.vertexFunction = try Self.function("smudgePickupVertex", in: library)
        pickupDesc.fragmentFunction = try Self.function("smudgePickupFragment", in: library)
        pickupDesc.colorAttachments[0].pixelFormat = .rgba16Float
        pickupDesc.colorAttachments[0].isBlendingEnabled = false
        self.smudgePickupPipelineState = try device.makeRenderPipelineState(descriptor: pickupDesc)
        pickupDesc.colorAttachments[0].pixelFormat = .r16Float
        self.smudgePickupHeightPipelineState = try device.makeRenderPipelineState(descriptor: pickupDesc)

        guard let smudgeDepositHeight = library.makeFunction(name: "smudgeDepositHeightFragment") else {
            throw MetalError.pipelineCreationFailed("smudgeDepositHeightFragment not found")
        }
        smudgeDesc.fragmentFunction = smudgeDepositHeight
        smudgeDesc.colorAttachments[0].pixelFormat = .r16Float
        self.smudgeDepositHeightPipelineState = try device.makeRenderPipelineState(descriptor: smudgeDesc)
        self.brushTextures = BrushTextureLibrary(device: device)
        brushTextures.warmUp()

        // Radial cap variants
        self.strokeRadialPipelineState = try MetalContext.makeStrokePipeline(
            device: device, library: library, vertexDescriptor: strokeVD,
            fragmentFunction: "strokeRadialFragment"
        )

        // Composite normal
        self.compositeNormalPipelineState = try MetalContext.makeCompositePipeline(
            device: device, library: library, vertexDescriptor: compVD,
            fragmentFunction: "compositeNormal", blending: .sourceOver
        )
        self.compositeNormalWithStrokePipelineState = try MetalContext.makeCompositePipeline(
            device: device, library: library, vertexDescriptor: compVD,
            fragmentFunction: "compositeNormalWithStroke", blending: .sourceOver
        )

        // Blend pipelines — alpha blending is disabled since the shader does
        // all compositing internally and writes the final composited result
        self.compositeBlendPipelineState = try MetalContext.makeCompositePipeline(
            device: device, library: library, vertexDescriptor: compVD,
            fragmentFunction: "compositeBlend", blending: .replace
        )
        self.compositeBlendWithStrokePipelineState = try MetalContext.makeCompositePipeline(
            device: device, library: library, vertexDescriptor: compVD,
            fragmentFunction: "compositeBlendWithStroke", blending: .replace
        )

        self.compositeStrokeMergePipelineState = try MetalContext.makeCompositePipeline(
            device: device, library: library, vertexDescriptor: compVD,
            fragmentFunction: "compositeStrokeMerge", blending: .replace
        )

        self.heightAccumulatePipelineState = try MetalContext.makeCompositePipeline(
            device: device, library: library, vertexDescriptor: compVD,
            fragmentFunction: "heightAccumulateFragment", blending: .add, pixelFormat: .r16Float
        )
        self.heightErasePipelineState = try MetalContext.makeCompositePipeline(
            device: device, library: library, vertexDescriptor: compVD,
            fragmentFunction: "compositeNormal", blending: .destinationOut, pixelFormat: .r16Float
        )
        self.clearHeightPipelineState = try MetalContext.makeCompositePipeline(
            device: device, library: library, vertexDescriptor: compVD,
            fragmentFunction: "clearFragment", blending: .replace, pixelFormat: .r16Float
        )
        self.heightAffinePipelineState = try MetalContext.makeCompositePipeline(
            device: device, library: library, vertexDescriptor: compVD,
            fragmentFunction: "compositeNormal", blending: .add, pixelFormat: .r16Float
        )

        self.compositeErasePipelineState = try MetalContext.makeCompositePipeline(
            device: device, library: library, vertexDescriptor: compVD,
            fragmentFunction: "compositeNormal", blending: .destinationOut
        )
        self.clearPipelineState = try MetalContext.makeCompositePipeline(
            device: device, library: library, vertexDescriptor: compVD,
            fragmentFunction: "clearFragment", blending: .replace
        )
        self.downsamplePipelineState = try MetalContext.makeCompositePipeline(
            device: device, library: library, vertexDescriptor: compVD,
            fragmentFunction: "downsampleFragment", blending: .replace
        )

        // Display
        let displayDesc = MTLRenderPipelineDescriptor()
        displayDesc.vertexFunction = try Self.function("compositeVertex", in: library)
        displayDesc.fragmentFunction = try Self.function("displayWhiteFragment", in: library)
        displayDesc.vertexDescriptor = compVD
        displayDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.displayPipelineState = try device.makeRenderPipelineState(descriptor: displayDesc)
        displayDesc.colorAttachments[0].pixelFormat = .rgba16Float
        self.display16PipelineState = try device.makeRenderPipelineState(descriptor: displayDesc)

        // --- Compute Pipelines ---

        guard let maskedCutFunc = library.makeFunction(name: "maskedCutKernel") else {
            throw MetalError.pipelineCreationFailed("maskedCutKernel not found")
        }
        self.maskedCutPipelineState = try device.makeComputePipelineState(function: maskedCutFunc)

        guard let maskedClearFunc = library.makeFunction(name: "maskedClearKernel") else {
            throw MetalError.pipelineCreationFailed("maskedClearKernel not found")
        }
        self.maskedClearPipelineState = try device.makeComputePipelineState(function: maskedClearFunc)
        self.maskedFillPipelineState = try device.makeComputePipelineState(function: Self.function("maskedFillKernel", in: library))

        guard let texturesDifferFunc = library.makeFunction(name: "texturesDifferKernel") else {
            throw MetalError.pipelineCreationFailed("texturesDifferKernel not found")
        }
        self.texturesDifferPipelineState = try device.makeComputePipelineState(function: texturesDifferFunc)

        guard let mixPigmentsFunc = library.makeFunction(name: "mixPigmentsKernel") else {
            throw MetalError.pipelineCreationFailed("mixPigmentsKernel not found")
        }
        self.mixPigmentsPipelineState = try device.makeComputePipelineState(function: mixPigmentsFunc)

        // --- Samplers ---

        let linearDesc = MTLSamplerDescriptor()
        linearDesc.minFilter = .linear
        linearDesc.magFilter = .linear
        linearDesc.mipFilter = .notMipmapped
        linearDesc.sAddressMode = .clampToZero
        linearDesc.tAddressMode = .clampToZero
        guard let linear = device.makeSamplerState(descriptor: linearDesc) else {
            throw MetalError.samplerCreationFailed
        }
        self.linearSampler = linear

        let nearestDesc = MTLSamplerDescriptor()
        nearestDesc.minFilter = .nearest
        nearestDesc.magFilter = .nearest
        nearestDesc.sAddressMode = .clampToZero
        nearestDesc.tAddressMode = .clampToZero
        guard let nearest = device.makeSamplerState(descriptor: nearestDesc) else {
            throw MetalError.samplerCreationFailed
        }
        self.nearestSampler = nearest

        let tipDesc = MTLSamplerDescriptor()
        tipDesc.minFilter = .linear
        tipDesc.magFilter = .linear
        tipDesc.mipFilter = .linear
        tipDesc.sAddressMode = .clampToEdge
        tipDesc.tAddressMode = .clampToEdge
        let grainDesc = MTLSamplerDescriptor()
        grainDesc.minFilter = .linear
        grainDesc.magFilter = .linear
        grainDesc.mipFilter = .linear
        grainDesc.sAddressMode = .repeat
        grainDesc.tAddressMode = .repeat
        guard let tip = device.makeSamplerState(descriptor: tipDesc),
              let grain = device.makeSamplerState(descriptor: grainDesc) else {
            throw MetalError.samplerCreationFailed
        }
        self.tipSampler = tip
        self.grainSampler = grain
    }

    // MARK: - Pipeline Helpers

    /// A shader function by name; a missing one is a build mistake worth stopping for,
    /// not a pipeline that silently draws nothing.
    private static func function(_ name: String, in library: MTLLibrary) throws -> MTLFunction {
        guard let function = library.makeFunction(name: name) else {
            throw MetalError.pipelineCreationFailed("\(name) not found")
        }
        return function
    }

    private static func makeStrokePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexDescriptor: MTLVertexDescriptor,
        fragmentFunction: String
    ) throws -> MTLRenderPipelineState {
        // A pipeline with a missing fragment function builds, and then draws nothing.
        guard let fragment = library.makeFunction(name: fragmentFunction) else {
            throw MetalError.pipelineCreationFailed("\(fragmentFunction) not found")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = try Self.function("strokeVertex", in: library)
        desc.fragmentFunction = fragment
        desc.vertexDescriptor = vertexDescriptor
        desc.colorAttachments[0].pixelFormat = .rgba16Float

        // MAX blending: prevents opacity accumulation when a stroke overlaps itself
        // at direction changes. Instead of adding alpha (which creates dark spots),
        // we take the maximum — so overlapping parts of the same stroke never
        // get darker than the single-pass value. This is how Krita/Procreate work.
        let attachment = desc.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .max
        attachment.alphaBlendOperation = .max
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one

        return try device.makeRenderPipelineState(descriptor: desc)
    }

    private enum CompositeBlending {
        /// Premultiplied source over destination
        case sourceOver
        /// The fragment's output replaces the destination
        case replace
        /// Destination-out: erases by the source's alpha
        case destinationOut
        /// Source plus destination: height maps add up
        case add
    }

    private static func makeCompositePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexDescriptor: MTLVertexDescriptor,
        fragmentFunction: String,
        blending: CompositeBlending,
        pixelFormat: MTLPixelFormat = .rgba16Float
    ) throws -> MTLRenderPipelineState {
        guard let fragment = library.makeFunction(name: fragmentFunction) else {
            throw MetalError.pipelineCreationFailed("\(fragmentFunction) not found")
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = try Self.function("compositeVertex", in: library)
        desc.fragmentFunction = fragment
        desc.vertexDescriptor = vertexDescriptor
        desc.colorAttachments[0].pixelFormat = pixelFormat

        let attachment = desc.colorAttachments[0]!
        switch blending {
        case .replace:
            attachment.isBlendingEnabled = false
        case .sourceOver:
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .destinationOut:
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .zero
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .zero
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .add:
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        }

        return try device.makeRenderPipelineState(descriptor: desc)
    }
}

enum MetalError: LocalizedError {
    case noDevice
    case noCommandQueue
    case noLibrary
    case samplerCreationFailed
    case textureCreationFailed
    case pipelineCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDevice: return "No Metal-compatible GPU found"
        case .noCommandQueue: return "Failed to create Metal command queue"
        case .noLibrary: return "Failed to load Metal shader library"
        case .samplerCreationFailed: return "Failed to create sampler state"
        case .textureCreationFailed: return "Failed to create texture"
        case .pipelineCreationFailed(let msg): return "Pipeline creation failed: \(msg)"
        }
    }
}

extension MetalContext {
    /// Mix pairs of Display P3 colours (gamma-encoded, as the canvas holds them) as pigments,
    /// `t` being the share of the second.
    /// Runs the same code the brushes use; meant for tests and tools, and it waits for the GPU.
    func mixPigments(_ pairs: [(SIMD3<Float>, SIMD3<Float>, Float)]) -> [SIMD3<Float>] {
        guard !pairs.isEmpty else { return [] }
        var input: [SIMD4<Float>] = []
        for (a, b, t) in pairs {
            input.append(SIMD4(a, t))
            input.append(SIMD4(b, 0))
        }
        guard let inBuffer = device.makeBuffer(bytes: input, length: input.count * 16, options: .storageModeShared),
              let outBuffer = device.makeBuffer(length: pairs.count * 16, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return [] }
        encoder.setComputePipelineState(mixPigmentsPipelineState)
        encoder.setBuffer(inBuffer, offset: 0, index: 0)
        encoder.setBuffer(outBuffer, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: pairs.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(pairs.count, 32), height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let results = outBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: pairs.count)
        return (0..<pairs.count).map { SIMD3(results[$0].x, results[$0].y, results[$0].z) }
    }
}
