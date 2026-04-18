import Metal

final class TextureManager {
    private let device: MTLDevice
    private var cache: [String: MTLTexture] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func makeCanvasTexture(width: Int, height: Int, label: String? = nil) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private

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
