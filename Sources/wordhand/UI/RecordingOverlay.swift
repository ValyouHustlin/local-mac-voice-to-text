import AppKit
import SwiftUI

/// A non-activating recording control that stays on the display where the pointer lives.
@MainActor
final class RecordingOverlay {
    enum State: Equatable {
        case hidden
        case recording
        case transcribing
        case finishing
    }

    var onCancel: (() -> Void)?

    private var window: NSPanel?
    private let model = OverlayModel()
    private var screenTrackingTimer: Timer?
    private var currentScreenNumber: NSNumber?

    deinit {
        screenTrackingTimer?.invalidate()
    }

    func show(_ state: State) {
        ensureWindow()
        if state == .recording {
            model.resetLevels()
        }
        guard let window else { return }
        let needsAppear = !window.isVisible
        positionOnPointerScreen(window, animated: false)
        startTrackingPointerScreen()
        if needsAppear {
            model.state = .hidden
            window.orderFrontRegardless()
            DispatchQueue.main.async { [model] in
                model.state = state
            }
        } else {
            model.state = state
        }
    }

    func hide() {
        screenTrackingTimer?.invalidate()
        screenTrackingTimer = nil
        model.state = .hidden
        let window = self.window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            window?.orderOut(nil)
        }
    }

    nonisolated func pushLevel(_ level: Float) {
        Task { @MainActor in
            self.model.pushLevel(level)
        }
    }

    private func ensureWindow() {
        if window != nil { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let host = NSHostingView(
            rootView: OverlayPill(model: model) { [weak self] in
                self?.onCancel?()
            }
        )
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        window = panel
    }

    private func startTrackingPointerScreen() {
        guard screenTrackingTimer == nil else { return }
        let timer = Timer(timeInterval: 0.16, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, window.isVisible else { return }
                self.positionOnPointerScreen(window, animated: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        screenTrackingTimer = timer
    }

    private func positionOnPointerScreen(_ window: NSPanel, animated: Bool) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: {
            NSMouseInRect(mouse, $0.frame, false)
        }) ?? NSScreen.main else { return }
        let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
            as? NSNumber
        guard screenNumber != currentScreenNumber || !window.isVisible else { return }
        currentScreenNumber = screenNumber

        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - window.frame.width / 2,
            y: visible.minY + 34
        )
        if animated, window.isVisible {
            var frame = window.frame
            frame.origin = origin
            window.setFrame(frame, display: true, animate: true)
        } else {
            window.setFrameOrigin(origin)
        }
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    static let barCount = 11
    private static let envelope: [Float] = [
        0.34, 0.48, 0.66, 0.82, 0.94, 1, 0.94, 0.82, 0.66, 0.48, 0.34,
    ]

    @Published var state: RecordingOverlay.State = .hidden
    @Published var levels: [Float] = Array(repeating: 0, count: barCount)
    @Published var energy: Float = 0
    private var smoothedLevel: Float = 0
    private var phase: Float = 0

    func pushLevel(_ level: Float) {
        let target = min(1, pow(max(0, level) * 52, 0.56))
        let response: Float = target > smoothedLevel ? 0.72 : 0.24
        smoothedLevel += (target - smoothedLevel) * response
        phase += 0.72
        energy = smoothedLevel
        levels = (0..<Self.barCount).map { index in
            let motion = 0.82 + 0.18 * sin(phase + Float(index) * 1.17)
            return max(0.04, smoothedLevel * Self.envelope[index] * motion)
        }
    }

    func resetLevels() {
        smoothedLevel = 0
        energy = 0
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

private struct OverlayPill: View {
    @ObservedObject var model: OverlayModel
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            content
            if model.state == .recording || model.state == .transcribing {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.58))
                .contentShape(Rectangle())
                .help("Cancel dictation")
                .accessibilityLabel("Cancel dictation")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color(red: 16/255, green: 17/255, blue: 19/255).opacity(0.98))
        )
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .scaleEffect(model.state == .hidden ? 0.78 : 1)
        .opacity(model.state == .hidden ? 0 : 1)
        .animation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.28), value: model.state)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden, .recording:
            Waveform(levels: model.levels)
                .frame(width: 72, height: 25)
        case .transcribing:
            OrbitGridLoader()
                .frame(width: 72, height: 25)
        case .finishing:
            OrbitGridLoader()
                .frame(width: 72, height: 25)
        }
    }
}

private struct OrbitGridLoader: View {
    private static let perimeterOrder = [0, 1, 2, 5, 8, 7, 6, 3]
    private let color = Color(red: 0.50, green: 0.72, blue: 1)

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.105)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.105)
                % Self.perimeterOrder.count
            let activeIndex = Self.perimeterOrder[step]

            Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in
                            let index = row * 3 + column
                            RoundedRectangle(cornerRadius: 1.2)
                                .fill(
                                    index == activeIndex
                                        ? color
                                        : Color.white.opacity(index == 4 ? 0.10 : 0.22)
                                )
                                .frame(width: 4.5, height: 4.5)
                        }
                    }
                }
            }
            .animation(.easeOut(duration: 0.08), value: activeIndex)
        }
    }
}

private struct Waveform: View {
    let levels: [Float]
    private let color = Color(red: 0.46, green: 0.94, blue: 0.76)

    var body: some View {
        HStack(alignment: .center, spacing: 3.2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.62), color],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 2.7, height: max(3, CGFloat(level) * 25))
                    .animation(.easeOut(duration: 0.075), value: level)
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}
