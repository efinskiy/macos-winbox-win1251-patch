import AppKit
import Foundation
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let selectButton = NSButton(title: "Выбрать WinBox…", target: nil, action: nil)
    private let applyButton = NSButton(title: "Применить патч", target: nil, action: nil)
    private let revealButton = NSButton(title: "Показать в Finder", target: nil, action: nil)
    private let targetLabel = NSTextField(wrappingLabelWithString: "Приложение не выбрано")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Выберите WinBox для проверки совместимости.")
    private let encodingPicker = NSPopUpButton()
    private let progress = NSProgressIndicator()
    private var selected: URL?
    private var result: URL?
    private var working = false
    private var engine: PatchEngine?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 600),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "WinBox Comment Patcher"
        window.center()
        let content = NSView()
        window.contentView = content

        let title = NSTextField(labelWithString: "Кириллица в комментариях WinBox")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let subtitle = NSTextField(wrappingLabelWithString: "Обновляет выбранный WinBox. Перед изменением сохраняет резервный архив.")
        subtitle.textColor = .secondaryLabelColor
        let compatibility = NSTextField(labelWithString: "WinBox 4.4.102000 · Apple Silicon и Intel")
        compatibility.font = .systemFont(ofSize: 12)
        compatibility.textColor = .secondaryLabelColor

        let targetTitle = NSTextField(labelWithString: "Целевое приложение")
        targetTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        targetLabel.font = .systemFont(ofSize: 12)
        targetLabel.textColor = .secondaryLabelColor
        targetLabel.maximumNumberOfLines = 3
        targetLabel.isSelectable = true
        selectButton.target = self
        selectButton.action = #selector(selectTarget)
        selectButton.bezelStyle = .rounded
        let targetRow = NSStackView(views: [targetLabel, selectButton])
        targetRow.orientation = .horizontal
        targetRow.spacing = 16
        targetLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        selectButton.setContentHuggingPriority(.required, for: .horizontal)

        let modeTitle = NSTextField(labelWithString: "Отображение комментариев")
        modeTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        encodingPicker.addItems(withTitles: CommentEncoding.allCases.map(\.title))
        let modeHint = NSTextField(wrappingLabelWithString: "Автоматический режим сохраняет корректный UTF-8. Для неоднозначных старых комментариев выберите «Всегда Windows-1251».")
        modeHint.font = .systemFont(ofSize: 12)
        modeHint.textColor = .secondaryLabelColor

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.maximumNumberOfLines = 3
        let statusRow = NSStackView(views: [progress, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 10
        statusRow.alignment = .centerY

        applyButton.target = self
        applyButton.action = #selector(applyPatch)
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.isEnabled = false
        revealButton.target = self
        revealButton.action = #selector(revealResult)
        revealButton.bezelStyle = .rounded
        revealButton.isHidden = true
        let buttons = NSStackView(views: [revealButton, applyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        let topSeparator = NSBox.separator(), bottomSeparator = NSBox.separator()
        let stack = NSStackView(views: [title, subtitle, compatibility,
            topSeparator, targetTitle, targetRow, modeTitle, encodingPicker,
            modeHint, bottomSeparator, statusRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            targetRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            topSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modeHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -34)
        ])
        do {
            guard let resources = Bundle.main.resourceURL else { throw PatchError.invalid("Не найдены ресурсы патчера.") }
            engine = try PatchEngine(resources: resources)
        } catch {
            statusLabel.stringValue = error.localizedDescription
            statusLabel.textColor = .systemRed
            selectButton.isEnabled = false
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if working {
            NSSound.beep()
            return .terminateCancel
        }
        return .terminateNow
    }

    private func setupMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Завершить WinBox Comment Patcher",
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = submenu
        menu.addItem(appItem)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выбрать всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApplication.shared.mainMenu = menu
    }

    @objc private func selectTarget() {
        guard !working, let engine = engine else { return }
        let panel = NSOpenPanel()
        panel.title = "Выберите WinBox"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Выбрать"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self = self else { return }
            self.setWorking(true, "Проверка совместимости…")
            DispatchQueue.global(qos: .userInitiated).async {
                let inspection = Result { try engine.inspect(url) }
                DispatchQueue.main.async {
                    self.setWorking(false, "")
                    switch inspection {
                    case .success(let target):
                        self.selected = target.url
                        self.targetLabel.stringValue = target.url.path
                        self.statusLabel.stringValue = "WinBox \(target.version) совместим. Выберите режим и примените патч."
                        self.statusLabel.textColor = .labelColor
                        self.applyButton.isEnabled = true
                    case .failure(let error):
                        self.selected = nil
                        self.targetLabel.stringValue = url.path
                        self.statusLabel.stringValue = error.localizedDescription
                        self.statusLabel.textColor = .systemRed
                        self.applyButton.isEnabled = false
                    }
                }
            }
        }
    }

    @objc private func applyPatch() {
        guard !working, let source = selected, let engine = engine else { return }
        let mode = CommentEncoding.allCases[encodingPicker.indexOfSelectedItem]
        revealButton.isHidden = true
        setWorking(true, "Подготовка приложения…")
        DispatchQueue.global(qos: .userInitiated).async {
            let operation = Result {
                try engine.apply(source: source, encoding: mode) { message in
                    DispatchQueue.main.async { self.statusLabel.stringValue = message }
                }
            }
            DispatchQueue.main.async {
                self.setWorking(false, "")
                switch operation {
                case .success(let applied):
                    self.result = applied.application
                    self.selected = nil
                    self.applyButton.isEnabled = false
                    self.statusLabel.stringValue = "Готово. Патч применён: \(applied.application.path)"
                    self.statusLabel.textColor = .labelColor
                    self.revealButton.isHidden = false
                case .failure(let error):
                    self.statusLabel.stringValue = "Патч не применён."
                    self.statusLabel.textColor = .systemRed
                    let alert = NSAlert()
                    alert.messageText = "Не удалось применить патч"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.beginSheetModal(for: self.window)
                }
            }
        }
    }

    @objc private func revealResult() {
        if let result = result { NSWorkspace.shared.activateFileViewerSelecting([result]) }
    }

    private func setWorking(_ value: Bool, _ message: String) {
        working = value
        statusLabel.stringValue = message
        selectButton.isEnabled = !value
        encodingPicker.isEnabled = !value
        applyButton.isEnabled = !value && selected != nil
        if value { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        window.standardWindowButton(.closeButton)?.isEnabled = !value
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let view = NSBox()
        view.boxType = .separator
        return view
    }
}

@main enum PatcherMain {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count >= 2 && ["--self-test", "--self-test-rollback"].contains(arguments[1]) {
            do {
                guard arguments.count == 3, let resources = Bundle.main.resourceURL else {
                    throw PatchError.invalid("Usage: --self-test TARGET.app")
                }
                let engine = try PatchEngine(resources: resources)
                let source = URL(fileURLWithPath: arguments[2])
                if arguments[1] == "--self-test-rollback" {
                    var injected = false
                    do {
                        _ = try engine.apply(source: source, encoding: .auto, afterCommit: {
                            injected = true
                            throw PatchError.invalid("Test: forced post-commit failure")
                        }) { print($0) }
                        throw PatchError.invalid("Test: expected rollback did not occur")
                    } catch {
                        guard injected else { throw error }
                        _ = try engine.inspect(source)
                        print("Rollback verified: original hash restored at " + source.path)
                    }
                } else {
                    let result = try engine.apply(source: source, encoding: .auto) { print($0) }
                    print("Patched: " + result.application.path)
                    print("Backup: " + result.backup.path)
                }
            } catch {
                fputs(error.localizedDescription + "\n", stderr)
                exit(1)
            }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
