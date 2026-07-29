import SwiftUI

struct ContentView: View {
    @ObservedObject var model: RecorderViewModel

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.045, blue: 0.043)
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                WordhandMark(isActive: model.isRecording)

                VStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.system(size: 17))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(maxWidth: 330)
                }

                if !model.latestTranscript.isEmpty {
                    Text(model.latestTranscript)
                        .font(.system(size: 17))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(4)
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18))
                }

                Menu {
                    ForEach(RecorderViewModel.EngineCandidate.allCases) { engine in
                        Button {
                            model.selectEngine(engine)
                        } label: {
                            if engine == model.selectedEngine {
                                Label(engine.name, systemImage: "checkmark")
                            } else {
                                Text(engine.name)
                            }
                        }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.selectedEngine.name)
                                .font(.subheadline.weight(.semibold))
                            Text(model.selectedEngine.detail)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(16)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(model.isRecording || model.state == .transcribing)

                Button {
                    Task { await model.toggleRecording() }
                } label: {
                    Label(
                        model.isRecording ? "Stop recording" : "Start recording",
                        systemImage: model.isRecording ? "stop.fill" : "mic.fill"
                    )
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(red: 0.035, green: 0.045, blue: 0.043))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 17)
                    .background(
                        Color(red: 0.50, green: 0.95, blue: 0.73),
                        in: RoundedRectangle(cornerRadius: 18)
                    )
                }
                .disabled(
                    model.state == .transcribing
                        || model.state == .preparing
                        || model.state == .authorizing
                )

                Text("Audio and text stay on this iPhone.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white.opacity(0.45))

                Spacer()
            }
            .padding(24)
        }
    }

    private var title: String {
        switch model.state {
        case .preparing:
            return "Getting Wordhand ready"
        case .authorizing:
            return "Getting Wordhand ready"
        case .ready:
            return "Speak. Then paste anywhere."
        case .recording:
            return "Listening"
        case .transcribing:
            return "Transcribing on device"
        case .readyInKeyboard:
            return "Ready in your keyboard"
        case .failed:
            return "Wordhand needs attention"
        }
    }

    private var detail: String {
        switch model.state {
        case .preparing:
            return "Checking the local speech model and permissions."
        case .authorizing:
            return "Checking the local speech model and permissions."
        case .ready:
            return "Record here, return to the previous app, then tap Insert in the Wordhand keyboard."
        case .recording:
            return "Tap once when you are finished."
        case .transcribing:
            return "The speech model is running locally on your iPhone 17 Pro."
        case .readyInKeyboard:
            return "Return to the app you were typing in and tap Insert."
        case .failed(let message):
            return message
        }
    }
}

private struct WordhandMark: View {
    let isActive: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(.white.opacity(0.07))
                .frame(width: 104, height: 104)
            Image(systemName: isActive ? "waveform" : "text.cursor")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color(red: 0.50, green: 0.95, blue: 0.73))
                .symbolEffect(.variableColor.iterative, isActive: isActive)
        }
    }
}
