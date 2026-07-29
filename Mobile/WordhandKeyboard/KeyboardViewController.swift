import UIKit
import WordhandMobileCore

final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let previewLabel = UILabel()
    private let recordButton = UIButton(type: .system)
    private let insertButton = UIButton(type: .system)
    private let nextKeyboardButton = UIButton(type: .system)
    private var pendingDraft: MobileTranscriptDraft?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureInterface()
        refreshDraft()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshDraft()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        refreshDraft()
    }

    private func configureInterface() {
        view.backgroundColor = UIColor(red: 0.035, green: 0.045, blue: 0.043, alpha: 1)

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .secondaryLabel
        statusLabel.text = "WORDHAND"

        previewLabel.font = .systemFont(ofSize: 16)
        previewLabel.textColor = .label
        previewLabel.numberOfLines = 2

        var recordConfiguration = UIButton.Configuration.filled()
        recordConfiguration.title = "Record"
        recordConfiguration.image = UIImage(systemName: "mic.fill")
        recordConfiguration.imagePadding = 8
        recordConfiguration.baseBackgroundColor = UIColor(
            red: 0.50,
            green: 0.95,
            blue: 0.73,
            alpha: 1
        )
        recordConfiguration.baseForegroundColor = UIColor(
            red: 0.035,
            green: 0.045,
            blue: 0.043,
            alpha: 1
        )
        recordConfiguration.cornerStyle = .large
        recordButton.configuration = recordConfiguration
        recordButton.addTarget(self, action: #selector(openRecorder), for: .touchUpInside)

        var insertConfiguration = UIButton.Configuration.tinted()
        insertConfiguration.title = "Insert"
        insertConfiguration.image = UIImage(systemName: "arrow.down.to.line.compact")
        insertConfiguration.imagePadding = 8
        insertConfiguration.cornerStyle = .large
        insertButton.configuration = insertConfiguration
        insertButton.addTarget(self, action: #selector(insertTranscript), for: .touchUpInside)

        nextKeyboardButton.setImage(UIImage(systemName: "globe"), for: .normal)
        nextKeyboardButton.addTarget(
            self,
            action: #selector(handleInputModeList(from:with:)),
            for: .allTouchEvents
        )

        let buttons = UIStackView(arrangedSubviews: [
            nextKeyboardButton,
            recordButton,
            insertButton,
        ])
        buttons.axis = .horizontal
        buttons.spacing = 10
        nextKeyboardButton.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let stack = UIStackView(arrangedSubviews: [statusLabel, previewLabel, buttons])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 176),
        ])
    }

    private func refreshDraft() {
        do {
            pendingDraft = try MobileConfiguration.sharedTranscriptStore().pending()
            previewLabel.text = pendingDraft?.text ?? "Record locally, then return here to insert."
            insertButton.isEnabled = pendingDraft != nil
        } catch {
            pendingDraft = nil
            previewLabel.text = error.localizedDescription
            insertButton.isEnabled = false
        }
    }

    @objc
    private func openRecorder() {
        guard let url = URL(string: "\(MobileConfiguration.callbackScheme)://record") else {
            return
        }
        extensionContext?.open(url) { [weak self] didOpen in
            guard !didOpen else { return }
            self?.previewLabel.text = "Open Wordhand to record, then return here."
        }
    }

    @objc
    private func insertTranscript() {
        guard let draft = pendingDraft else { return }
        textDocumentProxy.insertText(draft.text)
        do {
            _ = try MobileConfiguration.sharedTranscriptStore().consume(id: draft.id)
            pendingDraft = nil
            previewLabel.text = "Inserted. Tap Record for another."
            insertButton.isEnabled = false
        } catch {
            previewLabel.text = "Inserted, but the saved copy could not be cleared."
        }
    }
}
