import Cocoa
import AVFoundation
import CoreGraphics
import Vision
import WebKit

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class InteractiveWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler,
    WKNavigationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    private struct GestureTrackingState {
        var enabled = false
        var generation: UInt64 = 0
    }

    private var window: WallpaperWindow?
    private var rootView: NSView?
    private var webView: WKWebView?
    private var cameraPreviewView: NSView?
    private var keyMonitor: Any?
    private var renderTimer: Timer?
    private let gestureSession = AVCaptureSession()
    private lazy var gesturePreviewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: gestureSession)
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = NSColor(
            calibratedRed: 0.018,
            green: 0.052,
            blue: 0.05,
            alpha: 1
        ).cgColor
        return layer
    }()
    private let gestureQueue = DispatchQueue(
        label: "local.windnest.gesture-camera",
        qos: .userInitiated
    )
    private let handPoseRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()
    private let bodyPoseRequest = VNDetectHumanBodyPoseRequest()
    private var gestureOutput: AVCaptureVideoDataOutput?
    private var gestureCaptureConfigured = false
    private let gestureStateLock = NSLock()
    private var gestureTrackingState = GestureTrackingState()
    private var cameraPreviewRequestedVisible = true
    private var lastVisionFrameUptime: TimeInterval = 0
    private var lastHandSeenUptime: TimeInterval = 0
    private var lastGestureDiagnosticUptime: TimeInterval = 0
    private var smoothedHandX: CGFloat?
    private var lastGestureStatus = "off"
    private let isQAMode =
        ProcessInfo.processInfo.environment["WIND_NEST_QA"] == "1"

    private func fanFrame(for screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let side = min(
            860,
            min(visible.width * 0.58, visible.height * 0.9)
        )
        let width = min(
            visible.width - 40,
            side * 1.72
        )
        return NSRect(
            x: visible.maxX - width - 20,
            y: visible.minY + 22,
            width: width,
            height: side
        )
    }

    private func layoutCameraPreview() {
        guard
            let rootView,
            let cameraPreviewView
        else {
            return
        }

        let bounds = rootView.bounds
        let previewWidth = bounds.width * 0.37
        let previewHeight = previewWidth * 0.75
        let topInset = bounds.height * 0.16
        cameraPreviewView.frame = NSRect(
            x: bounds.width * 0.035,
            y: bounds.height - topInset - previewHeight,
            width: previewWidth,
            height: previewHeight
        )
        gesturePreviewLayer.frame = cameraPreviewView.bounds
    }

    @discardableResult
    private func updateGestureTrackingState(_ enabled: Bool) -> UInt64 {
        gestureStateLock.lock()
        defer { gestureStateLock.unlock() }
        gestureTrackingState.enabled = enabled
        gestureTrackingState.generation &+= 1
        return gestureTrackingState.generation
    }

    private func currentGestureTrackingState() -> GestureTrackingState {
        gestureStateLock.lock()
        defer { gestureStateLock.unlock() }
        return gestureTrackingState
    }

    private func isGestureTrackingStateCurrent(
        generation: UInt64,
        enabled: Bool
    ) -> Bool {
        gestureStateLock.lock()
        defer { gestureStateLock.unlock() }
        return gestureTrackingState.generation == generation &&
            gestureTrackingState.enabled == enabled
    }

    private func isBundledResourceURL(_ url: URL) -> Bool {
        guard
            url.isFileURL,
            let resourcesURL = Bundle.main.resourceURL
        else {
            return false
        }

        let resourcesPath = resourcesURL.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let requestedPath = url.resolvingSymlinksInPath()
            .standardizedFileURL.path
        return requestedPath == resourcesPath ||
            requestedPath.hasPrefix(resourcesPath + "/")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "wallpaper")
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: "window.__WIND_NEST_NATIVE__ = true;",
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        if isQAMode {
            configuration.preferences.setValue(
                true,
                forKey: "developerExtrasEnabled"
            )
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: "window.__WIND_NEST_QA__ = true;",
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }

        let view = InteractiveWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        guard let screen = NSScreen.main else {
            NSApp.terminate(nil)
            return
        }

        let wallpaperWindow = WallpaperWindow(
            contentRect: fanFrame(for: screen),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        wallpaperWindow.title = "风巢"
        wallpaperWindow.isOpaque = false
        wallpaperWindow.backgroundColor = .clear
        wallpaperWindow.hasShadow = false
        wallpaperWindow.ignoresMouseEvents = false
        wallpaperWindow.acceptsMouseMovedEvents = true
        wallpaperWindow.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        let desktopIconLevel = CGWindowLevelForKey(.desktopIconWindow)
        wallpaperWindow.level = NSWindow.Level(
            rawValue: Int(desktopIconLevel) + 1
        )
        let contentRoot = NSView(
            frame: NSRect(origin: .zero, size: fanFrame(for: screen).size)
        )
        contentRoot.wantsLayer = true
        contentRoot.layer?.backgroundColor = NSColor.clear.cgColor

        let previewView = NSView(frame: .zero)
        previewView.wantsLayer = true
        previewView.layer = gesturePreviewLayer
        previewView.layer?.cornerRadius = 24
        previewView.layer?.masksToBounds = true
        previewView.isHidden = true

        view.frame = contentRoot.bounds
        view.autoresizingMask = [.width, .height]
        contentRoot.addSubview(previewView)
        contentRoot.addSubview(view)
        wallpaperWindow.contentView = contentRoot
        wallpaperWindow.setFrame(fanFrame(for: screen), display: true)
        wallpaperWindow.makeKeyAndOrderFront(nil)
        wallpaperWindow.makeFirstResponder(view)

        guard
            let resources = Bundle.main.resourceURL,
            let indexURL = Bundle.main.url(
                forResource: "index",
                withExtension: "html"
            )
        else {
            NSApp.terminate(nil)
            return
        }

        view.loadFileURL(indexURL, allowingReadAccessTo: resources)
        window = wallpaperWindow
        rootView = contentRoot
        webView = view
        cameraPreviewView = previewView
        layoutCameraPreview()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == 53 {
                self?.webView?.evaluateJavaScript(
                    "window.wallpaperEscape && window.wallpaperEscape()"
                )
                return nil
            }
            if event.modifierFlags.contains(.command), event.characters == "q" {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    @objc private func screenChanged() {
        guard let screen = NSScreen.main else { return }
        window?.setFrame(fanFrame(for: screen), display: true, animate: false)
        layoutCameraPreview()
    }

    private func sendGestureStatus(
        _ status: String,
        matching generation: UInt64,
        enabled: Bool
    ) {
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                self.isGestureTrackingStateCurrent(
                    generation: generation,
                    enabled: enabled
                ),
                self.lastGestureStatus != status
            else {
                return
            }
            self.lastGestureStatus = status
            if self.isQAMode {
                NSLog("[WindNestGesture] status=%@", status)
            }
            self.webView?.evaluateJavaScript(
                """
                window.windNestGestureStatus &&
                window.windNestGestureStatus('\(status)')
                """
            )
        }
    }

    private func setCameraPreviewVisible(_ visible: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let previewView = self?.cameraPreviewView else { return }
            previewView.isHidden = !visible
            previewView.layer?.opacity = visible ? 1 : 0
        }
    }

    private func refreshCameraPreviewVisibility() {
        let trackingEnabled = currentGestureTrackingState().enabled
        setCameraPreviewVisible(
            trackingEnabled && cameraPreviewRequestedVisible
        )
    }

    private func sendGestureOverlay(
        _ points: [
            VNHumanHandPoseObservation.JointName: VNRecognizedPoint
        ]?,
        matching generation: UInt64,
        enabled: Bool
    ) {
        guard let points else {
            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    self.isGestureTrackingStateCurrent(
                        generation: generation,
                        enabled: enabled
                    )
                else {
                    return
                }
                self.webView?.evaluateJavaScript(
                    """
                    window.windNestGestureOverlay &&
                    window.windNestGestureOverlay(null)
                    """
                )
            }
            return
        }

        let joints: [(
            name: String,
            joint: VNHumanHandPoseObservation.JointName
        )] = [
            ("wrist", .wrist),
            ("thumbCMC", .thumbCMC),
            ("thumbMP", .thumbMP),
            ("thumbIP", .thumbIP),
            ("thumbTip", .thumbTip),
            ("indexMCP", .indexMCP),
            ("indexPIP", .indexPIP),
            ("indexDIP", .indexDIP),
            ("indexTip", .indexTip),
            ("middleMCP", .middleMCP),
            ("middlePIP", .middlePIP),
            ("middleDIP", .middleDIP),
            ("middleTip", .middleTip),
            ("ringMCP", .ringMCP),
            ("ringPIP", .ringPIP),
            ("ringDIP", .ringDIP),
            ("ringTip", .ringTip),
            ("littleMCP", .littleMCP),
            ("littlePIP", .littlePIP),
            ("littleDIP", .littleDIP),
            ("littleTip", .littleTip),
        ]

        var payloadPoints: [String: [String: Double]] = [:]
        for joint in joints {
            guard
                let point = points[joint.joint],
                point.confidence >= 0.06
            else {
                continue
            }
            payloadPoints[joint.name] = [
                "x": Double(1 - point.location.x),
                "y": Double(1 - point.location.y),
            ]
        }

        guard
            let data = try? JSONSerialization.data(
                withJSONObject: ["points": payloadPoints]
            ),
            let json = String(data: data, encoding: .utf8)
        else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                self.isGestureTrackingStateCurrent(
                    generation: generation,
                    enabled: enabled
                )
            else {
                return
            }
            self.webView?.evaluateJavaScript(
                """
                window.windNestGestureOverlay &&
                window.windNestGestureOverlay(\(json))
                """
            )
        }
    }

    private func pointDistance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }

    private func classifyHandPose(
        _ points: [
            VNHumanHandPoseObservation.JointName: VNRecognizedPoint
        ]
    ) -> (pose: String, fingerCount: Int?) {
        guard
            let wrist = points[.wrist],
            wrist.confidence >= 0.06
        else {
            return ("neutral", nil)
        }

        let fingers: [(
            tip: VNHumanHandPoseObservation.JointName,
            pip: VNHumanHandPoseObservation.JointName,
            mcp: VNHumanHandPoseObservation.JointName
        )] = [
            (.indexTip, .indexPIP, .indexMCP),
            (.middleTip, .middlePIP, .middleMCP),
            (.ringTip, .ringPIP, .ringMCP),
            (.littleTip, .littlePIP, .littleMCP),
        ]

        var evaluatedFingerCount = 0
        var extendedFingerCount = 0
        for finger in fingers {
            guard
                let tip = points[finger.tip],
                let pip = points[finger.pip],
                let mcp = points[finger.mcp],
                min(tip.confidence, pip.confidence, mcp.confidence) >= 0.06
            else {
                continue
            }

            evaluatedFingerCount += 1
            let tipToWrist = pointDistance(tip.location, wrist.location)
            let pipToWrist = pointDistance(pip.location, wrist.location)
            let tipToMCP = pointDistance(tip.location, mcp.location)
            let pipToMCP = pointDistance(pip.location, mcp.location)
            if tipToWrist > pipToWrist * 1.08 &&
                tipToMCP > pipToMCP * 1.16 {
                extendedFingerCount += 1
            }
        }

        guard evaluatedFingerCount >= 3 else {
            return ("neutral", nil)
        }
        if extendedFingerCount == 0 {
            return ("fist", 0)
        }
        if extendedFingerCount == 1 || extendedFingerCount == 2 {
            return ("neutral", extendedFingerCount)
        }
        if extendedFingerCount == 3, evaluatedFingerCount == 4 {
            return ("neutral", 3)
        }
        if extendedFingerCount == 4 {
            return ("open", 4)
        }
        return ("neutral", nil)
    }

    private func sendGestureFrame(
        _ handX: CGFloat?,
        hasHand: Bool,
        pose: String = "neutral",
        fingerCount: Int? = nil,
        matching generation: UInt64
    ) {
        let xValue: String
        if let handX {
            xValue = String(
                format: "%.5f",
                locale: Locale(identifier: "en_US_POSIX"),
                Double(handX)
            )
        } else {
            xValue = "null"
        }
        let safePose = ["open", "fist"].contains(pose) ? pose : "neutral"
        let fingerCountValue = fingerCount.map(String.init) ?? "null"
        DispatchQueue.main.async { [weak self] in
            guard
                let self,
                self.isGestureTrackingStateCurrent(
                    generation: generation,
                    enabled: true
                )
            else {
                return
            }
            self.webView?.evaluateJavaScript(
                """
                window.windNestGestureFrame &&
                window.windNestGestureFrame(
                  \(xValue),
                  \(hasHand ? "true" : "false"),
                  '\(safePose)',
                  \(fingerCountValue)
                )
                """
            )
        }
    }

    @discardableResult
    private func setGestureTracking(_ enabled: Bool) -> UInt64 {
        let generation = updateGestureTrackingState(enabled)
        refreshCameraPreviewVisibility()

        guard enabled else {
            sendGestureOverlay(
                nil,
                matching: generation,
                enabled: false
            )
            sendGestureStatus(
                "off",
                matching: generation,
                enabled: false
            )
            gestureQueue.async { [weak self] in
                guard let self else { return }
                self.smoothedHandX = nil
                if self.gestureSession.isRunning {
                    self.gestureSession.stopRunning()
                }
            }
            return generation
        }

        sendGestureStatus(
            "checking",
            matching: generation,
            enabled: true
        )
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        if isQAMode {
            NSLog(
                "[WindNestGesture] camera authorization=%ld",
                authorization.rawValue
            )
        }
        switch authorization {
        case .authorized:
            sendGestureStatus(
                "starting",
                matching: generation,
                enabled: true
            )
            startGestureCapture(matching: generation)
        case .notDetermined:
            sendGestureStatus(
                "prompting",
                matching: generation,
                enabled: true
            )
            NSApp.setActivationPolicy(.regular)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                AVCaptureDevice.requestAccess(for: .video) {
                    [weak self] granted in
                    DispatchQueue.main.async {
                        guard
                            let self,
                            self.isGestureTrackingStateCurrent(
                                generation: generation,
                                enabled: true
                            )
                        else {
                            NSApp.setActivationPolicy(.accessory)
                            return
                        }
                        if granted {
                            if self.isQAMode {
                                NSLog(
                                    "[WindNestGesture] camera permission granted"
                                )
                            }
                            self.sendGestureStatus(
                                "starting",
                                matching: generation,
                                enabled: true
                            )
                            self.startGestureCapture(matching: generation)
                        } else {
                            let disabledGeneration =
                                self.setGestureTracking(false)
                            self.setCameraPreviewVisible(false)
                            self.sendGestureStatus(
                                "denied",
                                matching: disabledGeneration,
                                enabled: false
                            )
                        }
                        NSApp.setActivationPolicy(.accessory)
                    }
                }
            }
        case .denied, .restricted:
            let disabledGeneration = setGestureTracking(false)
            setCameraPreviewVisible(false)
            sendGestureStatus(
                "denied",
                matching: disabledGeneration,
                enabled: false
            )
        @unknown default:
            let disabledGeneration = setGestureTracking(false)
            setCameraPreviewVisible(false)
            sendGestureStatus(
                "unavailable",
                matching: disabledGeneration,
                enabled: false
            )
        }
        return generation
    }

    private func startGestureCapture(matching generation: UInt64) {
        gestureQueue.async { [weak self] in
            guard
                let self,
                self.isGestureTrackingStateCurrent(
                    generation: generation,
                    enabled: true
                )
            else {
                return
            }
            do {
                if !self.gestureCaptureConfigured {
                    try self.configureGestureCapture()
                }
                guard
                    self.isGestureTrackingStateCurrent(
                        generation: generation,
                        enabled: true
                    )
                else {
                    return
                }
                if !self.gestureSession.isRunning {
                    self.gestureSession.startRunning()
                }
                self.lastHandSeenUptime = ProcessInfo.processInfo.systemUptime
                self.sendGestureStatus(
                    "searching",
                    matching: generation,
                    enabled: true
                )
            } catch {
                let disabledGeneration = self.setGestureTracking(false)
                self.setCameraPreviewVisible(false)
                self.sendGestureStatus(
                    "unavailable",
                    matching: disabledGeneration,
                    enabled: false
                )
                if self.isQAMode {
                    print(
                        "WIND_NEST_GESTURE_ERROR \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func configureGestureCapture() throws {
        guard let camera =
            AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .front
            ) ?? AVCaptureDevice.default(for: .video)
        else {
            throw NSError(
                domain: "local.windnest.gesture",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "没有找到可用摄像头"
                ]
            )
        }

        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: gestureQueue)

        gestureSession.beginConfiguration()
        gestureSession.sessionPreset = .medium
        defer { gestureSession.commitConfiguration() }

        guard
            gestureSession.canAddInput(input),
            gestureSession.canAddOutput(output)
        else {
            throw NSError(
                domain: "local.windnest.gesture",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "摄像头采集通道不可用"
                ]
            )
        }

        gestureSession.addInput(input)
        gestureSession.addOutput(output)
        gestureOutput = output
        gestureCaptureConfigured = true
        DispatchQueue.main.async { [weak self] in
            guard
                let connection = self?.gesturePreviewLayer.connection,
                connection.isVideoMirroringSupported
            else {
                return
            }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        if isQAMode {
            NSLog(
                "[WindNestGesture] camera=%@ preset=medium",
                camera.localizedName
            )
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let trackingState = currentGestureTrackingState()
        guard trackingState.enabled else { return }
        let generation = trackingState.generation

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastVisionFrameUptime >= 0.08 else { return }
        lastVisionFrameUptime = now

        let handler = VNImageRequestHandler(
            cmSampleBuffer: sampleBuffer,
            orientation: .up,
            options: [:]
        )

        do {
            try handler.perform([handPoseRequest])

            var detectedX: CGFloat?
            var detectedPose = "neutral"
            var detectedFingerCount: Int?
            var detectedOverlayPoints: [
                VNHumanHandPoseObservation.JointName: VNRecognizedPoint
            ]?
            var detectionSource = "hand"
            if let observation = handPoseRequest.results?.first {
                let points = try observation.recognizedPoints(.all)
                detectedOverlayPoints = points
                let handGesture = classifyHandPose(points)
                detectedPose = handGesture.pose
                detectedFingerCount = handGesture.fingerCount
                let confidentPoints = points.values.filter {
                    $0.confidence >= 0.06
                }
                if !confidentPoints.isEmpty {
                    let confidenceSum = confidentPoints.reduce(
                        CGFloat.zero
                    ) {
                        $0 + CGFloat($1.confidence)
                    }
                    detectedX = confidentPoints.reduce(CGFloat.zero) {
                        $0 + $1.location.x * CGFloat($1.confidence)
                    } / max(confidenceSum, 0.001)
                }
            }

            if detectedX == nil {
                try handler.perform([bodyPoseRequest])
                if let body = bodyPoseRequest.results?.first {
                    let bodyPoints = try body.recognizedPoints(.all)
                    let wristNames: [
                        VNHumanBodyPoseObservation.JointName
                    ] = [.leftWrist, .rightWrist]
                    let wrists = wristNames.compactMap {
                        bodyPoints[$0]
                    }.filter {
                        $0.confidence >= 0.12
                    }
                    detectedX = wrists.max {
                        abs($0.location.x - 0.5) <
                            abs($1.location.x - 0.5)
                    }?.location.x
                    detectionSource = "wrist"
                }
            }

            guard let detectedX else {
                reportMissingHand(at: now, matching: generation)
                return
            }

            guard
                isGestureTrackingStateCurrent(
                    generation: generation,
                    enabled: true
                )
            else {
                return
            }

            let mirroredX = min(1, max(0, 1 - detectedX))
            let filteredX: CGFloat
            if let previous = smoothedHandX {
                filteredX = previous + (mirroredX - previous) * 0.46
            } else {
                filteredX = mirroredX
            }
            smoothedHandX = filteredX
            lastHandSeenUptime = now
            if isQAMode && now - lastGestureDiagnosticUptime > 1 {
                lastGestureDiagnosticUptime = now
                NSLog(
                    "[WindNestGesture] source=%@ pose=%@ fingers=%ld x=%.3f",
                    detectionSource,
                    detectedPose,
                    detectedFingerCount ?? -1,
                    Double(filteredX)
                )
            }
            sendGestureStatus(
                "tracking",
                matching: generation,
                enabled: true
            )
            sendGestureOverlay(
                detectedOverlayPoints,
                matching: generation,
                enabled: true
            )
            sendGestureFrame(
                filteredX,
                hasHand: true,
                pose: detectedPose,
                fingerCount: detectedFingerCount,
                matching: generation
            )
        } catch {
            reportMissingHand(at: now, matching: generation)
        }
    }

    private func reportMissingHand(
        at now: TimeInterval,
        matching generation: UInt64
    ) {
        guard
            isGestureTrackingStateCurrent(
                generation: generation,
                enabled: true
            )
        else {
            return
        }
        if isQAMode && now - lastGestureDiagnosticUptime > 3 {
            lastGestureDiagnosticUptime = now
            NSLog("[WindNestGesture] camera frames active; no hand")
        }
        guard now - lastHandSeenUptime > 1.35 else { return }
        if now - lastHandSeenUptime > 2.6 {
            smoothedHandX = nil
        }
        sendGestureStatus(
            "searching",
            matching: generation,
            enabled: true
        )
        sendGestureOverlay(
            nil,
            matching: generation,
            enabled: true
        )
        sendGestureFrame(
            nil,
            hasHand: false,
            matching: generation
        )
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard
            message.name == "wallpaper",
            message.frameInfo.isMainFrame,
            let pageURL = message.webView?.url,
            isBundledResourceURL(pageURL)
        else {
            return
        }
        if let body = message.body as? [String: Any],
           let action = body["action"] as? String {
            if action == "quit" {
                NSApp.terminate(nil)
            }
            if action == "gesture-toggle",
               let enabled = body["enabled"] as? Bool {
                setGestureTracking(enabled)
            }
            if action == "camera-preview-toggle",
               let visible = body["visible"] as? Bool {
                cameraPreviewRequestedVisible = visible
                refreshCameraPreviewVisibility()
            }
            if action == "gesture-settings",
               let settingsURL = URL(
                   string:
                    "x-apple.systempreferences:" +
                    "com.apple.preference.security?Privacy_Camera"
               ) {
                NSWorkspace.shared.open(settingsURL)
            }
            if action == "qa-power",
               isQAMode {
                print("WIND_NEST_QA_POWER \(body["power"] ?? "unknown")")
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        if isBundledResourceURL(url) || url.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }

        if navigationAction.navigationType == .linkActivated,
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        renderTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) {
            [weak webView] _ in
            guard let webView else { return }

            let pointer = NSEvent.mouseLocation
            let frame = NSScreen.screens.reduce(NSRect.null) {
                $0.union($1.frame)
            }
            guard !frame.isNull, frame.width > 0, frame.height > 0 else {
                return
            }
            let pointerX = min(
                1,
                max(0, (pointer.x - frame.minX) / frame.width)
            )
            let pointerY = min(
                1,
                max(0, (pointer.y - frame.minY) / frame.height)
            )
            webView.evaluateJavaScript(
                """
                window.windNestNativeFrame &&
                window.windNestNativeFrame(
                  performance.now(),
                  \(pointerX),
                  \(pointerY)
                )
                """
            )
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer

        guard isQAMode else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let diagnostics = """
            JSON.stringify({
              title: document.title,
              loading: document.querySelector('#loading')?.className,
              canvasCount: document.querySelectorAll('canvas').length,
              canvasWidth: document.querySelector('canvas')?.width,
              canvasHeight: document.querySelector('canvas')?.height,
              frame: window.__WIND_NEST_QA_FRAME__
            })
            """
            webView.evaluateJavaScript(diagnostics) { result, error in
                if let error {
                    print("WIND_NEST_QA_ERROR \(error.localizedDescription)")
                } else {
                    print("WIND_NEST_QA_STATE \(result ?? "null")")
                }
            }

            let overlayDiagnostics = """
            (() => {
              window.windNestGestureOverlay({
                points: {
                  wrist: { x: 0.50, y: 0.80 },
                  thumbCMC: { x: 0.42, y: 0.68 },
                  thumbMP: { x: 0.34, y: 0.59 },
                  thumbIP: { x: 0.27, y: 0.51 },
                  thumbTip: { x: 0.20, y: 0.44 },
                  indexMCP: { x: 0.43, y: 0.58 },
                  indexPIP: { x: 0.40, y: 0.42 },
                  indexDIP: { x: 0.39, y: 0.29 },
                  indexTip: { x: 0.38, y: 0.16 },
                  middleMCP: { x: 0.50, y: 0.56 },
                  middlePIP: { x: 0.50, y: 0.37 },
                  middleDIP: { x: 0.50, y: 0.23 },
                  middleTip: { x: 0.50, y: 0.09 },
                  ringMCP: { x: 0.57, y: 0.58 },
                  ringPIP: { x: 0.59, y: 0.41 },
                  ringDIP: { x: 0.60, y: 0.29 },
                  ringTip: { x: 0.61, y: 0.17 },
                  littleMCP: { x: 0.64, y: 0.62 },
                  littlePIP: { x: 0.69, y: 0.49 },
                  littleDIP: { x: 0.72, y: 0.39 },
                  littleTip: { x: 0.75, y: 0.29 }
                }
              });
              return JSON.stringify({
                visible: document.body.classList.contains(
                  'gesture-hand-visible'
                ),
                lines: [...document.querySelectorAll(
                  '#handSkeleton line'
                )].filter((line) => line.style.display !== 'none').length,
                points: [...document.querySelectorAll(
                  '#handSkeleton circle'
                )].filter((point) => point.style.display !== 'none').length
              });
            })()
            """
            webView.evaluateJavaScript(
                overlayDiagnostics
            ) { result, error in
                if let error {
                    print(
                        "WIND_NEST_QA_OVERLAY_ERROR " +
                        error.localizedDescription
                    )
                    return
                }
                print("WIND_NEST_QA_OVERLAY \(result ?? "null")")
                let overlaySnapshot = WKSnapshotConfiguration()
                overlaySnapshot.afterScreenUpdates = true
                webView.takeSnapshot(
                    with: overlaySnapshot
                ) { image, snapshotError in
                    guard
                        snapshotError == nil,
                        let image,
                        let data = image.tiffRepresentation,
                        let bitmap = NSBitmapImageRep(data: data),
                        let png = bitmap.representation(
                            using: .png,
                            properties: [:]
                        )
                    else {
                        print(
                            "WIND_NEST_QA_OVERLAY_SNAPSHOT_ERROR " +
                            (snapshotError?.localizedDescription ??
                                "unknown")
                        )
                        return
                    }
                    let url = URL(
                        fileURLWithPath:
                            "/tmp/wind-nest-gesture-overlay.png"
                    )
                    do {
                        try png.write(to: url, options: .atomic)
                        print(
                            "WIND_NEST_QA_OVERLAY_SNAPSHOT \(url.path)"
                        )
                    } catch {
                        print(
                            "WIND_NEST_QA_OVERLAY_SNAPSHOT_ERROR \(error)"
                        )
                    }
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                webView.evaluateJavaScript(
                    "JSON.stringify(window.__WIND_NEST_QA_FRAME__)"
                ) { result, error in
                    if let error {
                        print(
                            "WIND_NEST_QA_MOTION_ERROR " +
                            error.localizedDescription
                        )
                    } else {
                        print("WIND_NEST_QA_MOTION \(result ?? "null")")
                    }
                }
            }

            let speedChecks: [(speed: Int, delay: Double)] = [
                (1, 1.4),
                (2, 3.0),
                (3, 4.6),
            ]
            for check in speedChecks {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + check.delay
                ) {
                    webView.evaluateJavaScript(
                        """
                        document.querySelector(
                          '[data-speed="\(check.speed)"]'
                        )?.click()
                        """
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        webView.evaluateJavaScript(
                            "JSON.stringify(window.__WIND_NEST_QA_FRAME__)"
                        ) { result, error in
                            if let error {
                                print(
                                    "WIND_NEST_QA_SPEED_ERROR " +
                                    error.localizedDescription
                                )
                            } else {
                                print(
                                    "WIND_NEST_QA_SPEED_\(check.speed) " +
                                    "\(result ?? "null")"
                                )
                            }
                        }
                    }
                }
            }

            let gestureChecks: [
                (label: String, x: Double, delay: Double)
            ] = [
                ("LEFT", 0.12, 6.2),
                ("RIGHT", 0.88, 7.8),
            ]
            for check in gestureChecks {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + check.delay
                ) {
                    webView.evaluateJavaScript(
                        """
                        window.windNestGestureStatus('tracking');
                        window.windNestGestureFrame(\(check.x), true);
                        """
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        webView.evaluateJavaScript(
                            "JSON.stringify(window.__WIND_NEST_QA_FRAME__)"
                        ) { result, error in
                            if let error {
                                print(
                                    "WIND_NEST_QA_GESTURE_ERROR " +
                                    error.localizedDescription
                                )
                            } else {
                                print(
                                    "WIND_NEST_QA_GESTURE_\(check.label) " +
                                    "\(result ?? "null")"
                                )
                            }
                        }
                    }
                }
            }
            let fingerChecks: [
                (count: Int, delay: Double)
            ] = [
                (1, 9.2),
                (2, 10.1),
                (3, 11.0),
            ]
            for check in fingerChecks {
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + check.delay
                ) {
                    webView.evaluateJavaScript(
                        """
                        JSON.stringify(
                          window.__WIND_NEST_QA_GESTURE_COMMAND__(
                            'neutral',
                            \(check.count)
                          )
                        )
                        """
                    ) { result, error in
                        print(
                            error == nil
                                ? "WIND_NEST_QA_FINGERS_" +
                                    "\(check.count) \(result ?? "null")"
                                : "WIND_NEST_QA_FINGERS_ERROR " +
                                    (error?.localizedDescription ?? "unknown")
                        )
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) {
                webView.evaluateJavaScript(
                    """
                    JSON.stringify(
                      window.__WIND_NEST_QA_GESTURE_COMMAND__('fist', 0)
                    )
                    """
                ) { result, error in
                    print(
                        error == nil
                            ? "WIND_NEST_QA_FIST \(result ?? "null")"
                            : "WIND_NEST_QA_FIST_ERROR " +
                                (error?.localizedDescription ?? "unknown")
                    )
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.9) {
                webView.evaluateJavaScript(
                    """
                    JSON.stringify(
                      window.__WIND_NEST_QA_GESTURE_COMMAND__('open', 4)
                    )
                    """
                ) { result, error in
                    print(
                        error == nil
                            ? "WIND_NEST_QA_OPEN \(result ?? "null")"
                            : "WIND_NEST_QA_OPEN_ERROR " +
                                (error?.localizedDescription ?? "unknown")
                    )
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 13.9) {
                webView.evaluateJavaScript(
                    "window.windNestGestureStatus('off')"
                )
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15.0) {
                webView.evaluateJavaScript(
                    """
                    JSON.stringify({
                      loading: document.querySelector('#loading')?.className,
                      frame: window.__WIND_NEST_QA_FRAME__
                    })
                    """
                ) { result, error in
                    if let error {
                        print(
                            "WIND_NEST_QA_FINAL_ERROR " +
                            error.localizedDescription
                        )
                    } else {
                        print("WIND_NEST_QA_FINAL \(result ?? "null")")
                    }
                    print("WIND_NEST_QA_COMPLETE")
                    NSApp.terminate(nil)
                }
            }

            webView.evaluateJavaScript(
                "document.querySelector('canvas')?.toDataURL('image/png')"
            ) { result, error in
                guard
                    error == nil,
                    let dataURL = result as? String,
                    let comma = dataURL.firstIndex(of: ","),
                    let png = Data(
                        base64Encoded: String(dataURL[dataURL.index(after: comma)...])
                    )
                else {
                    print(
                        "WIND_NEST_QA_CANVAS_ERROR " +
                        (error?.localizedDescription ?? "unknown")
                    )
                    return
                }
                let url = URL(fileURLWithPath: "/tmp/wind-nest-canvas.png")
                do {
                    try png.write(to: url, options: .atomic)
                    print("WIND_NEST_QA_CANVAS \(url.path)")
                } catch {
                    print("WIND_NEST_QA_CANVAS_ERROR \(error)")
                }
            }

            let snapshot = WKSnapshotConfiguration()
            snapshot.afterScreenUpdates = true
            webView.takeSnapshot(with: snapshot) { image, error in
                guard
                    error == nil,
                    let image,
                    let data = image.tiffRepresentation,
                    let bitmap = NSBitmapImageRep(data: data),
                    let png = bitmap.representation(
                        using: .png,
                        properties: [:]
                    )
                else {
                    print(
                        "WIND_NEST_QA_SNAPSHOT_ERROR " +
                        (error?.localizedDescription ?? "unknown")
                    )
                    return
                }
                let url = URL(
                    fileURLWithPath: "/tmp/wind-nest-webview-snapshot.png"
                )
                do {
                    try png.write(to: url, options: .atomic)
                    print("WIND_NEST_QA_SNAPSHOT \(url.path)")
                } catch {
                    print("WIND_NEST_QA_SNAPSHOT_ERROR \(error)")
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateGestureTrackingState(false)
        renderTimer?.invalidate()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        NotificationCenter.default.removeObserver(self)
        gestureQueue.sync { [self] in
            gestureOutput?.setSampleBufferDelegate(nil, queue: nil)
            if gestureSession.isRunning {
                gestureSession.stopRunning()
            }
        }
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: "wallpaper"
        )
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
