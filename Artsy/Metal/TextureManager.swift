import Metal

final class TextureManager {
    private let device: MTLDevice
    private var cache: [String: MTLTexture] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    /// Memory the GPU can work with comfortably, per Metal; what layers, undo history and
    /// scratch textures have to share.
    var memoryBudget: Int { Int(device.recommendedMaxWorkingSetSize) }

    /// - Parameter mipLevels: more than one for a texture that is also kept at smaller
    ///   sizes (the composite, for showing the canvas zoomed out).
    func makeCanvasTexture(width: Int, height: Int, label: String? = nil, mipLevels: Int = 1) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: mipLevels > 1
        )
        desc.mipmapLevelCount = mipLevels
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw MetalError.textureCreationFailed
        }
        texture.label = label
        return texture
    }

    /// A layer's height map (impasto): one half-float per pixel, paint thickness in 0...1.
    func makeHeightTexture(width: Int, height: Int, label: String? = nil, shared: Bool = false,
                           mipLevels: Int = 1) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float,
            width: width,
            height: height,
            mipmapped: mipLevels > 1
        )
        desc.mipmapLevelCount = mipLevels
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        #if arch(arm64)
        desc.storageMode = shared ? .shared : .private
        #else
        desc.storageMode = shared ? .managed : .private
        #endif

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw MetalError.textureCreationFailed
        }
        texture.label = label
        return texture
    }

    func makeSharedTexture(width: Int, height: Int, label: String? = nil) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        #if arch(arm64)
        desc.storageMode = .shared
        #else
        desc.storageMode = .managed
        #endif

        guard let texture = device.makeTexture(descriptor: desc) else {
            throw MetalError.textureCreationFailed
        }
        texture.label = label
        return texture
    }

    func clearTexture(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer, color: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) {
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = color

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) {
            encoder.endEncoding()
        }
    }
}
