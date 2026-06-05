import AppKit
import QuartzCore
import SceneKit

@MainActor
private let resizeSynchronousLayerActions: [String: CAAction] = [
    "bounds": NSNull(),
    "position": NSNull(),
    "frame": NSNull(),
    "contents": NSNull(),
    "cornerRadius": NSNull(),
    "backgroundColor": NSNull(),
    "borderColor": NSNull(),
    "borderWidth": NSNull(),
    "shadowPath": NSNull(),
    "shadowOpacity": NSNull(),
    "shadowRadius": NSNull(),
    "shadowOffset": NSNull(),
    "transform": NSNull(),
    "sublayers": NSNull()
]

@MainActor
final class OrbPrototypeViewController: NSViewController {
    private let showcaseView = ShowcaseView()
    private let sceneView = MetalAuroraView(frame: .zero)
    private let listPlaceholder = PrototypeListPlaceholderView()
    private let subtitleLabel = NSTextField(labelWithString: "轻轻移动鼠标，让这个实体回应你")
    private let actionButton = CapsuleActionButton(title: "显示列表")

    override func loadView() {
        view = showcaseView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        sceneView.startAnimation()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        sceneView.stopAnimation()
    }

    func windowWillStartLiveResize() {
        sceneView.entersLiveResizeMode()
        synchronizeLayoutForResize()
    }

    func windowDidEndLiveResize() {
        synchronizeLayoutForResize()
        sceneView.leavesLiveResizeMode()
    }

    func windowDidResize() {
        synchronizeLayoutForResize()
    }

    private func synchronizeLayoutForResize() {
        withDisabledLayerActions {
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            showcaseView.synchronizeBackingLayers()
            sceneView.synchronizeForResize()
        }
    }

    private func buildInterface() {
        let navigation = CapsuleNavigationView(items: ["右键菜单", "窗口操作", "菜单栏", "输入框", "剪贴板"])
        navigation.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Orb")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.90)
        titleLabel.alignment = .center
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        sceneView.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.76)
        subtitleLabel.alignment = .center

        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.target = self
        actionButton.action = #selector(toggleListPlaceholder)

        listPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        listPlaceholder.alphaValue = 0
        listPlaceholder.isHidden = true

        showcaseView.addSubview(titleLabel)
        showcaseView.addSubview(navigation)
        showcaseView.addSubview(sceneView)
        showcaseView.addSubview(subtitleLabel)
        showcaseView.addSubview(actionButton)
        showcaseView.addSubview(listPlaceholder)

        let preferredSceneSize = sceneView.widthAnchor.constraint(equalTo: showcaseView.heightAnchor, multiplier: 0.46)
        preferredSceneSize.priority = .defaultHigh

        let preferredListWidth = listPlaceholder.widthAnchor.constraint(equalToConstant: 520)
        preferredListWidth.priority = .defaultHigh
        let preferredListHeight = listPlaceholder.heightAnchor.constraint(equalToConstant: 330)
        preferredListHeight.priority = .defaultHigh
        let preferredListCenterY = listPlaceholder.centerYAnchor.constraint(equalTo: showcaseView.centerYAnchor, constant: 12)
        preferredListCenterY.priority = .defaultHigh

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: showcaseView.safeAreaLayoutGuide.topAnchor, constant: 18),
            titleLabel.centerXAnchor.constraint(equalTo: showcaseView.centerXAnchor),

            navigation.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            navigation.centerXAnchor.constraint(equalTo: showcaseView.centerXAnchor),
            navigation.heightAnchor.constraint(equalToConstant: 56),
            navigation.widthAnchor.constraint(equalToConstant: 530),
            navigation.widthAnchor.constraint(lessThanOrEqualTo: showcaseView.widthAnchor, constant: -72),

            sceneView.centerXAnchor.constraint(equalTo: showcaseView.centerXAnchor),
            sceneView.centerYAnchor.constraint(equalTo: showcaseView.centerYAnchor, constant: -20),
            sceneView.widthAnchor.constraint(equalTo: sceneView.heightAnchor),
            preferredSceneSize,
            sceneView.widthAnchor.constraint(greaterThanOrEqualToConstant: 230),
            sceneView.widthAnchor.constraint(lessThanOrEqualToConstant: 370),
            sceneView.widthAnchor.constraint(lessThanOrEqualTo: showcaseView.widthAnchor, multiplier: 0.44),

            subtitleLabel.topAnchor.constraint(equalTo: sceneView.bottomAnchor, constant: 18),
            subtitleLabel.centerXAnchor.constraint(equalTo: showcaseView.centerXAnchor),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: actionButton.topAnchor, constant: -18),

            actionButton.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 22),
            actionButton.centerXAnchor.constraint(equalTo: showcaseView.centerXAnchor),
            actionButton.widthAnchor.constraint(equalToConstant: 210),
            actionButton.heightAnchor.constraint(equalToConstant: 54),
            actionButton.bottomAnchor.constraint(lessThanOrEqualTo: showcaseView.safeAreaLayoutGuide.bottomAnchor, constant: -36),

            listPlaceholder.centerXAnchor.constraint(equalTo: showcaseView.centerXAnchor),
            preferredListCenterY,
            preferredListWidth,
            preferredListHeight,
            listPlaceholder.widthAnchor.constraint(lessThanOrEqualTo: showcaseView.widthAnchor, constant: -120),
            listPlaceholder.heightAnchor.constraint(lessThanOrEqualTo: showcaseView.heightAnchor, multiplier: 0.50),
            listPlaceholder.heightAnchor.constraint(greaterThanOrEqualToConstant: 250),
            listPlaceholder.topAnchor.constraint(greaterThanOrEqualTo: navigation.bottomAnchor, constant: 44),
            listPlaceholder.bottomAnchor.constraint(lessThanOrEqualTo: actionButton.topAnchor, constant: -28)
        ])
    }

    @objc private func toggleListPlaceholder(_ sender: CapsuleActionButton) {
        let shouldShowList = listPlaceholder.isHidden
        if shouldShowList {
            listPlaceholder.alphaValue = 0
            listPlaceholder.isHidden = false
            listPlaceholder.layer?.transform = CATransform3DMakeTranslation(0, 22, 0)
        } else {
            sceneView.alphaValue = 0
            sceneView.isHidden = false
            sceneView.layer?.transform = CATransform3DMakeTranslation(0, -24, 0)
            subtitleLabel.alphaValue = 0
            subtitleLabel.isHidden = false
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            sceneView.animator().alphaValue = shouldShowList ? 0 : 1
            subtitleLabel.animator().alphaValue = shouldShowList ? 0 : 1
            sceneView.layer?.transform = shouldShowList ? CATransform3DMakeTranslation(0, -24, 0) : CATransform3DIdentity
            listPlaceholder.animator().alphaValue = shouldShowList ? 1 : 0
            listPlaceholder.layer?.transform = shouldShowList ? CATransform3DIdentity : CATransform3DMakeTranslation(0, 22, 0)
        } completionHandler: {
            Task { @MainActor in
                self.sceneView.isHidden = shouldShowList
                self.subtitleLabel.isHidden = shouldShowList
                self.listPlaceholder.isHidden = !shouldShowList
                sender.updateTitle(shouldShowList ? "收起列表" : "显示列表")
            }
        }
    }
}

private final class ShowcaseView: NSView {
    private let gradient = NSGradient(colors: [
        NSColor(red: 0.025, green: 0.145, blue: 0.115, alpha: 1),
        NSColor(red: 0.050, green: 0.370, blue: 0.260, alpha: 1),
        NSColor(red: 0.390, green: 0.760, blue: 0.570, alpha: 1)
    ])

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizesSubviews = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        needsDisplay = true
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        withDisabledLayerActions {
            needsDisplay = true
            layoutSubtreeIfNeeded()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        withDisabledLayerActions {
            needsDisplay = true
            layoutSubtreeIfNeeded()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        gradient?.draw(in: bounds, angle: -90)
    }

    func synchronizeBackingLayers() {
        withDisabledLayerActions {
            needsDisplay = true
            displayIfNeeded()
        }
    }
}

private final class CapsuleNavigationView: NSView {
    private let selectedIndex = 0

    init(items: [String]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.actions = resizeSynchronousLayerActions
        layer?.cornerRadius = 28
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.10
        layer?.shadowOffset = CGSize(width: 0, height: 10)
        layer?.shadowRadius = 24

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 9, bottom: 8, right: 9)

        for (index, item) in items.enumerated() {
            stack.addArrangedSubview(NavButton(title: item, isSelected: index == selectedIndex))
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class NavButton: NSButton {
    init(title: String, isSelected: Bool) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        refusesFirstResponder = true
        if let cell = cell as? NSButtonCell {
            cell.highlightsBy = []
            cell.showsStateBy = []
        }
        font = .systemFont(ofSize: 14.5, weight: isSelected ? .semibold : .medium)
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 14.5, weight: .medium),
                .foregroundColor: isSelected ? NSColor.black : NSColor.white.withAlphaComponent(0.68)
            ]
        )
        attributedAlternateTitle = attributedTitle
        wantsLayer = true
        layer?.actions = resizeSynchronousLayerActions
        layer?.cornerRadius = 20
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = isSelected ? NSColor.white.withAlphaComponent(0.92).cgColor : NSColor.clear.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class CapsuleActionButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        refusesFirstResponder = true
        if let cell = cell as? NSButtonCell {
            cell.highlightsBy = []
            cell.showsStateBy = []
        }
        font = .systemFont(ofSize: 17, weight: .semibold)
        updateTitle(title)
        wantsLayer = true
        layer?.actions = resizeSynchronousLayerActions
        layer?.cornerRadius = 27
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowOffset = CGSize(width: 0, height: 12)
        layer?.shadowRadius = 22
    }

    required init?(coder: NSCoder) {
        nil
    }

    func updateTitle(_ title: String) {
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: NSColor.black
            ]
        )
        attributedAlternateTitle = attributedTitle
    }
}

private final class PrototypeListPlaceholderView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.actions = resizeSynchronousLayerActions
        layer?.cornerRadius = 24
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        layer?.borderWidth = 1

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let title = NSTextField(labelWithString: "右键菜单")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.textColor = .white

        let subtitle = NSTextField(labelWithString: "这里后续接入真正的列表内容。")
        subtitle.font = .systemFont(ofSize: 14, weight: .regular)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.62)

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.addArrangedSubview(SeparatorLine())

        for label in ["打开 VS Code", "新建 Markdown", "复制路径"] {
            stack.addArrangedSubview(PlaceholderRow(title: label))
        }

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class PlaceholderRow: NSView {
    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 46).isActive = true
        wantsLayer = true
        layer?.actions = resizeSynchronousLayerActions
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.13).cgColor

        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.88)

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class SeparatorLine: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.actions = resizeSynchronousLayerActions
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class InertialSphereSceneView: SCNView {
    private let sphereNode = SCNNode()
    private var animationTimer: Timer?
    private var angularVelocity = SIMD2<Float>(0.34, -0.50)
    private let velocityLimit: Float = 5.2
    private let dampingPerSecond: Float = 0.82
    private var wasPlayingBeforeLiveResize = false

    override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layer?.actions = resizeSynchronousLayerActions
        layer?.needsDisplayOnBoundsChange = true
        configureScene()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func startAnimation() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, target: self, selector: #selector(animationTick), userInfo: nil, repeats: true)
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    func entersLiveResizeMode() {
        wasPlayingBeforeLiveResize = isPlaying
        isPlaying = true
        rendersContinuously = true
        synchronizeForResize()
    }

    func leavesLiveResizeMode() {
        rendersContinuously = false
        isPlaying = wasPlayingBeforeLiveResize
        synchronizeForResize()
    }

    func synchronizeForResize() {
        withDisabledLayerActions {
            needsLayout = true
            layer?.setNeedsDisplay()
            setNeedsDisplay(bounds)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        withDisabledLayerActions {
            super.setFrameSize(newSize)
            needsLayout = true
            layer?.setNeedsDisplay()
            setNeedsDisplay(bounds)
        }
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        withDisabledLayerActions {
            super.resize(withOldSuperviewSize: oldSize)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let impulse: Float = event.hasPreciseScrollingDeltas ? 0.016 : 0.042
        angularVelocity.y += Float(event.scrollingDeltaX) * impulse
        angularVelocity.x += Float(event.scrollingDeltaY) * impulse
        angularVelocity.x = min(max(angularVelocity.x, -velocityLimit), velocityLimit)
        angularVelocity.y = min(max(angularVelocity.y, -velocityLimit), velocityLimit)
    }

    @objc private func animationTick(_ timer: Timer) {
        step(deltaTime: 1 / 60)
    }

    private func step(deltaTime: TimeInterval) {
        let dt = Float(deltaTime)
        sphereNode.eulerAngles.x += CGFloat(angularVelocity.x * dt)
        sphereNode.eulerAngles.y += CGFloat(angularVelocity.y * dt)

        let damping = pow(dampingPerSecond, dt)
        angularVelocity *= damping

        if length(angularVelocity) < 0.045 {
            angularVelocity = SIMD2<Float>(0.045, -0.034)
        }
    }

    private func configureScene() {
        allowsCameraControl = false
        backgroundColor = .clear
        preferredFramesPerSecond = 60
        antialiasingMode = .multisampling4X
        isJitteringEnabled = true

        let scene = SCNScene()
        self.scene = scene

        let sphere = SCNSphere(radius: 1.28)
        sphere.segmentCount = 128
        sphere.firstMaterial = makeSphereMaterial()
        sphereNode.geometry = sphere
        installGlassDetailRings()
        scene.rootNode.addChildNode(sphereNode)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 32
        cameraNode.position = SCNVector3(0, 0, 6.6)
        scene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode

        let keyLight = SCNNode()
        keyLight.light = SCNLight()
        keyLight.light?.type = .area
        keyLight.light?.intensity = 430
        keyLight.light?.color = NSColor(red: 0.92, green: 1.0, blue: 0.94, alpha: 1)
        keyLight.light?.areaExtents = SIMD3<Float>(5.8, 5.8, 1)
        keyLight.position = SCNVector3(-3.6, 4.6, 4.8)
        scene.rootNode.addChildNode(keyLight)

        let rimLight = SCNNode()
        rimLight.light = SCNLight()
        rimLight.light?.type = .omni
        rimLight.light?.intensity = 130
        rimLight.light?.color = NSColor(red: 0.70, green: 1.00, blue: 0.82, alpha: 1)
        rimLight.position = SCNVector3(3.8, 1.4, 2.8)
        scene.rootNode.addChildNode(rimLight)

        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .ambient
        fillLight.light?.intensity = 190
        fillLight.light?.color = NSColor(red: 0.62, green: 0.90, blue: 0.72, alpha: 1)
        scene.rootNode.addChildNode(fillLight)
    }

    private func installGlassDetailRings() {
        let ringMaterial = SCNMaterial()
        ringMaterial.diffuse.contents = NSColor.white.withAlphaComponent(0.26)
        ringMaterial.emission.contents = NSColor(red: 0.56, green: 1.0, blue: 0.78, alpha: 0.12)
        ringMaterial.lightingModel = .constant
        ringMaterial.isDoubleSided = true
        ringMaterial.blendMode = .alpha
        ringMaterial.writesToDepthBuffer = false

        let rotations: [SCNVector3] = [
            SCNVector3(0.24, 0.10, 0.16),
            SCNVector3(1.22, 0.34, -0.28),
            SCNVector3(-0.62, 1.08, 0.38)
        ]

        for rotation in rotations {
            let torus = SCNTorus(ringRadius: 1.19, pipeRadius: 0.006)
            torus.ringSegmentCount = 192
            torus.pipeSegmentCount = 8
            torus.firstMaterial = ringMaterial

            let node = SCNNode(geometry: torus)
            node.eulerAngles = rotation
            node.opacity = 0.34
            sphereNode.addChildNode(node)
        }
    }

    private func makeSphereMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = makeFrostedGlassTexture()
        material.transparent.contents = NSColor.white.withAlphaComponent(0.56)
        material.transparency = 0.58
        material.transparencyMode = .dualLayer
        material.blendMode = .alpha
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        material.metalness.contents = 0.02
        material.roughness.contents = 0.72
        material.emission.contents = NSColor(red: 0.06, green: 0.20, blue: 0.13, alpha: 1)
        material.specular.contents = NSColor.white.withAlphaComponent(0.56)
        material.fresnelExponent = 1.45
        return material
    }

    private func makeFrostedGlassTexture() -> NSImage {
        let size = CGSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor(red: 0.62, green: 1.0, blue: 0.78, alpha: 0.46).setFill()
        NSRect(origin: .zero, size: size).fill()

        for index in 0..<18 {
            let alpha = CGFloat(0.018 + Double(index % 5) * 0.006)
            let y = CGFloat(index) * 34 - 72
            let path = NSBezierPath()
            path.move(to: CGPoint(x: -40, y: y))
            path.curve(
                to: CGPoint(x: size.width + 60, y: y + 110),
                controlPoint1: CGPoint(x: 130, y: y + 28),
                controlPoint2: CGPoint(x: 330, y: y + 96)
            )
            path.lineWidth = CGFloat(18 + (index % 3) * 7)
            NSColor.white.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }

        var seed: UInt32 = 43
        for _ in 0..<1400 {
            seed = 1664525 &* seed &+ 1013904223
            let x = CGFloat(seed % 512)
            seed = 1664525 &* seed &+ 1013904223
            let y = CGFloat(seed % 512)
            let alpha = CGFloat((seed % 18) + 4) / 1000
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSRect(x: x, y: y, width: 1, height: 1).fill()
        }

        image.unlockFocus()
        return image
    }
}

private func withDisabledLayerActions(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}
