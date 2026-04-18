import Metal
import MetalKit

final class MetalContext {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary

    // Pipeline states
    let strokeProceduralPipelineState: MTLRenderPipelineState
    let strokePencilPipelineState: MTLRenderPipelineState
    let strokeTexturedPipelineState: MTLRenderPipelineState
    let strokeWatercolorPipelineState: MTLRenderPipelineState
    let strokeAcrylicPipelineState: MTLRenderPipelineState
    let strokeEraserPipelineState: MTLRenderPipelineState
    // Radial-distance variants for stroke caps (rounded endpoints, Procreate-style)
    let strokeRadialPipelineState: MTLRenderPipelineState
    let strokeRadialPencilPipelineState: MTLRenderPipelineState
    let strokeRadialWatercolorPipelineState: MTLRenderPipelineState
    let strokeRadialAcrylicPipelineState: MTLRenderPipelineState
    let strokeRadialEraserPipelineState: MTLRenderPipelineState
    let compositeNormalPipelineState: MTLRenderPipelineState
    let compositeBlendPipelineState: MTLRenderPipelineState
    let displayPipelineState: MTLRenderPipelineState
    let maskedCutPipelineState: MTLComputePipelineState
    let maskedClearPipelineState: MTLComputePipelineState

    // Vertex descriptors
    let strokeVertexDescriptor: MTLVertexDescriptor
    let compositeVertexDescriptor: MTLVertexDescriptor

    // Samplers
    let linearSampler: MTLSamplerState
    let nearestSampler: MTLSamplerState

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

        // Stroke pencil
        self.strokePencilPipelineState = try MetalContext.makeStrokePipeline(
            device: device, library: library, vertexDescriptor: strokeVD,
            fragmentFunction: "strokePencilFragment"
        )

        // Stroke textured
        self.strokeTexturedPipelineState = try MetalContext.makeStrokePipeline(
            device: device, library: library, vertexDescriptor: strokeVD,
            fragmentFunction: "strokeFragment"
        )

        // Stroke watercolor
        self.strokeWatercolorPipelineState = try MetalContext.makeStrokePipeline(
            device: device, library: library, vertexDescriptor: strokeVD,
            fragmentFunction: "strokeWatercolorFragment"
        )

        // Stroke acrylic
        self.strokeAcrylicPipelineState = try MetalContext.makeStrokePipeline(
            device: device, library: library, vertexDescriptor: strokeVD,
            fragmentFunction: "strokeAcrylicFragment"
        )

        // Stroke eraser — uses destination-out blending to remove pixels
        self.strokeEraserPipelineState = try MetalContext.makeEraserPipeline(
            device: device, library: library, vertexDescriptor: strokeVD
        )

        // Radial cap variants
        self.strokeRadialPipelineState = try MetalContext.makeStrokePipeline(
            device: device, library: library, vertexDescriptor: strokeVD,
            fragmentFunction: "strokeRadialFragment"
        )
        self.strokeRadialPencilPipelineState = try MetalContext.makeStrokePipeline(
            device: device, library: library, vertexDescriptor: strokeVD,
            fragmentFunction: "strokeRadialPencilFragment"
        )
        self.strokeRadialWatercolorPipelineState = try MetalContext.makeStrokePipeline(
            device: device, library: library, vertexDescriptor: strokeVD,
            fragmentFunction: "strokeRadialWatercolorFragment"
        )
        self.strokeRadialAcrylicPipelineState = try MetalContext.makeStrokePipeline(
            device: device, library: library, vertexDescriptor: strokeVD,
            fragmentFunction: "strokeRadialAcrylicFragment"
        )
        // Eraser cap also uses destination-out blending with the radial shape
        let radialEraserDesc = MTLRenderPipelineDescriptor()
        radialEraserDesc.vertexFunction = library.makeFunction(name: "strokeVertex")
        radialEraserDesc.fragmentFunction = library.makeFunction(name: "strokeRadialFragment")
        radialEraserDesc.vertexDescriptor = strokeVD
        radialEraserDesc.colorAttachments[0].pixelFormat = .rgba16Float
        let eraserAttach = radialEraserDesc.colorAttachments[0]!
        eraserAttach.isBlendingEnabled = true
        eraserAttach.rgbBlendOperation = .add
        eraserAttach.alphaBlendOperation = .add
        eraserAttach.sourceRGBBlendFactor = .zero
        eraserAttach.destinationRGBBlendFactor = .oneMinusSourceAlpha
        eraserAttach.sourceAlphaBlendFactor = .zero
        eraserAttach.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.strokeRadialEraserPipelineState = try device.makeRenderPipelineState(descriptor: radialEraserDesc)

        // Composite normal
        self.compositeNormalPipelineState = try MetalContext.makeCompositePipeline(
            device: device, library: library, vertexDescriptor: compVD,
            fragmentFunction: "compositeNormal"
        )

        // Blend pipeline — disables alpha blending since the shader does
        // all compositing internally and writes the final composited result
        let blendDesc = MTLRenderPipelineDescriptor()
        blendDesc.vertexFunction = library.makeFunction(name: "compositeVertex")
        blendDesc.fragmentFunction = library.makeFunction(name: "compositeBlend")
        blendDesc.vertexDescriptor = compVD
        blendDesc.colorAttachments[0].pixelFormat = .rgba16Float
        blendDesc.colorAttachments[0].isBlendingEnabled = false
        self.compositeBlendPipelineState = try device.makeRenderPipelineState(descriptor: blendDesc)

        // Display
        let displayDesc = MTLRenderPipelineDescriptor()
        displayDesc.vertexFunction = library.makeFunction(name: "compositeVertex")
        displayDesc.fragmentFunction = library.makeFunction(name: "displayWhiteFragment")
        displayDesc.vertexDescriptor = compVD
        displayDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        self.displayPipelineState = try device.makeRenderPipelineState(descriptor: displayDesc)

        // --- Compute Pipelines ---

        guard let maskedCutFunc = library.makeFunction(name: "maskedCutKernel") else {
            throw MetalError.pipelineCreationFailed("maskedCutKernel not found")
        }
        self.maskedCutPipelineState = try device.makeComputePipelineState(function: maskedCutFunc)

        guard let maskedClearFunc = library.makeFunction(name: "maskedClearKernel") else {
            throw MetalError.pipelineCreationFailed("maskedClearKernel not found")
        }
        self.maskedClearPipelineState = try device.makeComputePipelineState(function: maskedClearFunc)

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
    }

    // MARK: - Pipeline Helpers

    private static func makeStrokePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexDescriptor: MTLVertexDescriptor,
        fragmentFunction: String
    ) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "strokeVertex")
        desc.fragmentFunction = library.makeFunction(name: fragmentFunction)
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

    private static func makeCompositePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexDescriptor: MTLVertexDescriptor,
        fragmentFunction: String
    ) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "compositeVertex")
        desc.fragmentFunction = library.makeFunction(name: fragmentFunction)
        desc.vertexDescriptor = vertexDescriptor
        desc.colorAttachments[0].pixelFormat = .rgba16Float

        let attachment = desc.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return try device.makeRenderPipelineState(descriptor: desc)
    }

    private static func makeEraserPipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertexDescriptor: MTLVertexDescriptor
    ) throws -> MTLRenderPipelineState {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "strokeVertex")
        desc.fragmentFunction = library.makeFunction(name: "strokeProceduralFragment")
        desc.vertexDescriptor = vertexDescriptor
        desc.colorAttachments[0].pixelFormat = .rgba16Float

        // Destination-out blending: erases by subtracting source alpha from destination
        let attachment = desc.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .zero
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .zero
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

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
