import AppKit
import MetalKit
import QuartzCore

final class TerrainView: MTKView {
    var keys = Set<UInt16>()
    var onLook: ((Float, Float) -> Void)?
    var onEndLook: (() -> Void)?
    var onZoom: ((Float) -> Void)?
    var onToggleWireframe: (() -> Void)?
    var onReset: (() -> Void)?
    var onMaterialKey: ((UInt16) -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if [UInt16(49), 17, 8, 33, 30].contains(event.keyCode) {
            if !event.isARepeat { onMaterialKey?(event.keyCode) }
            return
        }
        if event.keyCode == 3 {
            if !event.isARepeat { onToggleWireframe?() }
        } else if event.keyCode == 15 {
            if !event.isARepeat { onReset?() }
        } else { keys.insert(event.keyCode) }
    }
    override func keyUp(with event: NSEvent) { keys.remove(event.keyCode) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    override func mouseDragged(with event: NSEvent) { onLook?(Float(event.deltaX), Float(event.deltaY)) }
    override func mouseUp(with event: NSEvent) { onEndLook?() }
    override func scrollWheel(with event: NSEvent) { onZoom?(Float(event.scrollingDeltaY)) }

    init(device: MTLDevice) {
        super.init(frame: NSRect(x: 0, y: 0, width: renderWidth, height: renderHeight), device: device)
        colorPixelFormat = .bgra8Unorm_srgb
        depthStencilPixelFormat = .depth32Float
        clearColor = MTLClearColor(red: 0.59, green: 0.70, blue: 0.76, alpha: 1)
        clearDepth = 1
        framebufferOnly = true
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
        autoResizeDrawable = false
        drawableSize = CGSize(width: renderWidth, height: renderHeight)
    }

    required init(coder: NSCoder) { fatalError("Storyboard is not used") }

    override func layout() {
        super.layout()
        drawableSize = CGSize(width: renderWidth, height: renderHeight)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, MTKViewDelegate {
    private var window: NSWindow?
    private let monitor = FrameMonitor()
    private let inFlight = DispatchSemaphore(value: 2)
    private let renderer: Renderer
    private var previousTime = CACurrentMediaTime()

    init(renderer: Renderer) { self.renderer = renderer }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit HexTilingDemo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu

        let view = TerrainView(device: renderer.device)
        let help = NSTextField(labelWithString: "Space  Hex / Repeat     T  Top view     C  Contrast     [ / ]  Patch size\nWASD  Move     Drag  Look     Scroll  Height     F  Wireframe     R  Reset camera")
        help.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        help.textColor = .white
        help.backgroundColor = NSColor.black.withAlphaComponent(0.75)
        help.drawsBackground = true
        help.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(help)
        NSLayoutConstraint.activate([
            help.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            help.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        ])
        view.delegate = self
        view.onLook = { [weak self] x, y in self?.renderer.dragLook(x: x, y: y) }
        view.onEndLook = { [weak self] in self?.renderer.stopLook() }
        view.onZoom = { [weak self] delta in
            guard let renderer = self?.renderer else { return }
            renderer.altitude = min(145, max(62, renderer.altitude - delta * 0.3))
        }
        view.onToggleWireframe = { [weak self] in self?.renderer.wireframe.toggle() }
        view.onReset = { [weak self] in self?.renderer.reset() }
        view.onMaterialKey = { [weak self] key in
            guard let self else { return }
            switch key {
            case 49: renderer.useHexTiling.toggle()
            case 17: renderer.flatTopDown.toggle()
            case 8: renderer.parameters.useContrastCorrectedBlending.toggle()
            case 33: renderer.parameters.patchScale = max(0.5, renderer.parameters.patchScale - 0.5)
            case 30: renderer.parameters.patchScale = min(8, renderer.parameters.patchScale + 0.5)
            default: break
            }
            self.window?.title = renderer.modeDescription
        }

        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = renderer.modeDescription
        window.contentView = view
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)

        monitor.onUpdate = { [weak self, weak window] text in
            guard let self else { return }
            window?.title = renderer.modeDescription + " | " + text
            if CommandLine.arguments.contains("--stats") { print(text) }
        }
        previousTime = CACurrentMediaTime()
        print("HexTilingDemo on \(renderer.device.name). Space: Hex/Repeat · T: top view · C: contrast · [ / ]: patch scale · WASD: move · drag: look · scroll: altitude · F: wireframe · R: camera reset · ⌘Q: quit.")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in metalView: MTKView) {
        let now = CACurrentMediaTime()
        let delta = Float(min(now - previousTime, 0.05))
        previousTime = now
        guard let view = metalView as? TerrainView,
              let window, window.isVisible, !window.isMiniaturized else { return }

        renderer.updateLook(deltaTime: delta)
        if !window.isKeyWindow { view.keys.removeAll() }
        updateMovement(keys: view.keys, deltaTime: delta)

        guard inFlight.wait(timeout: .now()) == .success else { return }
        let cpuStart = CACurrentMediaTime()
        guard let drawable = metalView.currentDrawable,
              let pass = metalView.currentRenderPassDescriptor else {
            inFlight.signal()
            return
        }
        drawable.addPresentedHandler { [weak self] presented in
            RunLoop.main.perform(inModes: [.common]) {
                self?.monitor.presented(at: presented.presentedTime)
            }
        }
        do {
            let gate = inFlight
            try renderer.render(passDescriptor: pass, drawable: drawable) { [weak self] command in
                gate.signal()
                let milliseconds = (command.gpuEndTime - command.gpuStartTime) * 1000
                RunLoop.main.perform(inModes: [.common]) {
                    self?.monitor.completed(gpuMilliseconds: milliseconds)
                }
            }
            monitor.submitted(cpuMilliseconds: (CACurrentMediaTime() - cpuStart) * 1000)
        } catch {
            inFlight.signal()
            fputs("Metal error: \(error.localizedDescription)\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private func updateMovement(keys: Set<UInt16>, deltaTime: Float) {
        let forward = SIMD2<Float>(sin(renderer.yaw), -cos(renderer.yaw))
        let right = SIMD2<Float>(cos(renderer.yaw), sin(renderer.yaw))
        var movement = SIMD2<Float>(repeating: 0)
        if keys.contains(13) || keys.contains(126) { movement += forward }
        if keys.contains(1) || keys.contains(125) { movement -= forward }
        if keys.contains(0) || keys.contains(123) { movement -= right }
        if keys.contains(2) || keys.contains(124) { movement += right }
        let length = simd_length(movement)
        if length > 0 {
            let speed: Float = NSEvent.modifierFlags.contains(.shift) ? 85 : 32
            renderer.position += movement / length * speed * deltaTime
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

do {
    if CommandLine.arguments.contains("--help") {
        print("""
        swift run HexTilingDemo
        Space: Hex/Repeat | T: top view | C: contrast | [ / ]: patch scale
        WASD/arrows: move | Shift: boost | drag: look | scroll: altitude
        F: wireframe | R: reset camera | Command-Q: quit
        Options: --plain-tiling --top-down-flat --stats
        GPU check: --verify [--snapshot /tmp/hex-tiling.png]
        Whole-frame GPU timings: --benchmark [--top-down-flat]
        """)
        exit(0)
    }
    let renderer = try Renderer()
    if CommandLine.arguments.contains("--benchmark") {
        try renderer.benchmark()
    } else if CommandLine.arguments.contains("--verify") {
        try renderer.verify()
    } else {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate(renderer: renderer)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
} catch {
    fputs("HexTilingDemo: \(error.localizedDescription)\n", stderr)
    exit(1)
}
