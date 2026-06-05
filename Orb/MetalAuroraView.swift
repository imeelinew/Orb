import AppKit
import Metal
import QuartzCore
import simd

private struct AuroraUniforms {
    var time: Float
    var resolution: SIMD2<Float>
    var mouse: SIMD2<Float>
    var hoverStrength: Float
    var animationStrength: Float
}

final class MetalAuroraView: NSView {
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var animationTimer: Timer?
    private var startTime = CACurrentMediaTime()
    private var targetMouse = SIMD2<Float>(0, 0)
    private var displayMouse = SIMD2<Float>(0, 0)
    private var hoverStrength: Float = 0
    private var isLiveResizing = false
    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue()
        else {
            fatalError("Metal is required for MetalAuroraView.")
        }

        self.device = device
        self.commandQueue = commandQueue

        do {
            let options = MTLCompileOptions()
            options.languageVersion = .version3_0
            let library = try device.makeLibrary(source: AuroraShaderSource.metal, options: options)
            guard
                let vertexFunction = library.makeFunction(name: "aurora_vertex_main"),
                let fragmentFunction = library.makeFunction(name: "aurora_fragment_main")
            else {
                fatalError("Aurora Metal shader functions are missing.")
            }

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create Aurora Metal pipeline: \(error)")
        }

        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    func startAnimation() {
        guard animationTimer == nil else { return }
        startTime = CACurrentMediaTime()

        let timer = Timer(timeInterval: 1 / 60, target: self, selector: #selector(animationTick), userInfo: nil, repeats: true)
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    func entersLiveResizeMode() {
        isLiveResizing = true
        synchronizeForResize()
    }

    func leavesLiveResizeMode() {
        isLiveResizing = false
        synchronizeForResize()
    }

    func synchronizeForResize() {
        updateDrawableSize()
        renderFrame()
    }

    override func updateLayer() {
        updateDrawableSize()
        renderFrame()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
        renderFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateDrawableSize()
        renderFrame()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        updateMouse(from: event)
        hoverStrength = max(hoverStrength, 0.55)
    }

    override func mouseMoved(with event: NSEvent) {
        updateMouse(from: event)
        hoverStrength = min(1, hoverStrength + 0.08)
    }

    override func mouseExited(with event: NSEvent) {
        targetMouse = SIMD2<Float>(0, 0)
        hoverStrength = min(hoverStrength, 0.42)
    }

    private func configureLayer() {
        wantsLayer = true
        layer = metalLayer
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(bounds.width * scale, 1), height: max(bounds.height * scale, 1))
    }

    private func updateMouse(from event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let x = Float((location.x / bounds.width) * 2 - 1)
        let y = Float((location.y / bounds.height) * 2 - 1)
        targetMouse = SIMD2<Float>(
            min(max(x, -1), 1),
            min(max(y, -1), 1)
        )
    }

    @objc private func animationTick() {
        let blend: Float = isLiveResizing ? 0.38 : 0.12
        displayMouse += (targetMouse - displayMouse) * blend
        hoverStrength += ((window?.isKeyWindow == true ? 0.72 : 0.48) - hoverStrength) * 0.035
        renderFrame()
    }

    private func renderFrame() {
        guard
            bounds.width > 0,
            bounds.height > 0,
            let drawable = metalLayer.nextDrawable(),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        var uniforms = AuroraUniforms(
            time: Float(CACurrentMediaTime() - startTime),
            resolution: SIMD2<Float>(Float(max(bounds.width, 1)), Float(max(bounds.height, 1))),
            mouse: displayMouse,
            hoverStrength: hoverStrength,
            animationStrength: animationTimer == nil ? 0.35 : 1.0
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<AuroraUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
