import Metal

public final class TextureManager {
    private let device: MTLDevice
    private var cache: [String: MTLTexture] = [:]

    public init(device: MTLDevice) {
        self.device = device
    }

    /// Memory the GPU can work with comfortably, per Metal; what layers, undo history and
    /// scratch textures have to share. See `budget(workingSet:available:physical:)`.
    public var memoryBudget: Int { Self.memoryBudget(for: device) }

    public static func memoryBudget(for device: MTLDevice) -> Int {
        budget(workingSet: Int(device.recommendedMaxWorkingSetSize), available: availableToProcess,
               physical: Int(ProcessInfo.processInfo.physicalMemory))
    }

    /// What the app may still take before the system stops it: iOS says; the Mac sets no
    /// such limit.
    public static var availableToProcess: Int? {
        #if os(iOS)
        return Int(os_proc_available_memory())
        #else
        return nil
        #endif
    }

    /// What the GPU says it can hold, or a quarter of the machine's memory where it says
    /// nothing (the iOS simulator reports a working set of zero); and, where the system
    /// limits what an app may take (iOS), never more than three quarters of what is left
    /// to it, so a canvas, its layers and the undo history stay under the limit with room
    /// for the rest. A GPU's working set is not that limit: on a phone it can be most of
    /// the memory, and a canvas sized by it (an 8192² one on the iPhone Duo) was killed.
    public static func budget(workingSet: Int, available: Int?, physical: Int) -> Int {
        let budget = workingSet > 0 ? workingSet : physical / 4
        guard let available, available > 0 else { return budget }
        return min(budget, available / 4 * 3)
    }

    /// - Parameter mipLevels: more than one for a texture that is also kept at smaller
    ///   sizes (the composite, for showing the canvas zoomed out).
    public func makeCanvasTexture(width: Int, height: Int, label: String? = nil, mipLevels: Int = 1) throws -> MTLTexture {
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
    public func makeHeightTexture(width: Int, height: Int, label: String? = nil, shared: Bool = false,
                           mipLevels: Int = 1) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float,
            width: width,
            height: height,
            mipmapped: mipLevels > 1
        )
        desc.mipmapLevelCount = mipLevels
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        #if !os(macOS) || arch(arm64)   // managed storage is an Intel Mac's
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

    public func makeSharedTexture(width: Int, height: Int, label: String? = nil) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        #if !os(macOS) || arch(arm64)   // managed storage is an Intel Mac's
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

    public func clearTexture(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer, color: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) {
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
