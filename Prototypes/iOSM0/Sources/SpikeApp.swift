import UIKit
import UniformTypeIdentifiers

@main
final class SpikeApp: UIResponder, UIApplicationDelegate {
    func application(_: UIApplication, configurationForConnecting _: UISceneSession,
                     options _: UIScene.ConnectionOptions) -> UISceneConfiguration
    {
        let configuration = UISceneConfiguration(name: "M0", sessionRole: .windowApplication)
        configuration.delegateClass = SpikeScene.self
        return configuration
    }
}

final class SpikeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo _: UISceneSession, options _: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = SpikeViewController()
        window.makeKeyAndVisible()
        self.window = window
    }
}

@MainActor
final class SpikeViewController: UIViewController, UIDocumentPickerDelegate {
    private let editor = SourceEditor()
    private let probe = Probe()
    private lazy var session = DocumentSession(editor: editor, probe: probe)
    private let status = UILabel()
    private var pickerScope: AccessGrant.Scope = .singleFile

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        editor.textView.isEditable = false
        status.numberOfLines = 0
        status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        status.accessibilityIdentifier = "m0-status"
        let controls = UIStackView(arrangedSubviews: [
            row([button("Fixture", #selector(fixture)), button("File", #selector(pickFile)),
                 button("Folder", #selector(pickFolder)), button("Recent", #selector(recent))]),
            row([button("Save", #selector(save)), button("Undo", #selector(undo)),
                 button("Redo", #selector(redo)), button("Delay", #selector(delay))]),
            row([button("Inspect", #selector(inspect)), button("Recovery", #selector(recovery)),
                 button("Save copy", #selector(saveCopy)), button("Export log", #selector(exportLog))]),
            row([button("View switch", #selector(viewSwitch)), button("External probe", #selector(externalProbe))]),
            status, editor.textView,
        ])
        controls.axis = .vertical
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            controls.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])
        session.updated = { [weak self] in self?.refresh() }
        refresh()
    }

    private func row(_ buttons: [UIButton]) -> UIStackView {
        let row = UIStackView(arrangedSubviews: buttons)
        row.distribution = .fillEqually
        row.spacing = 4
        return row
    }

    private func button(_ title: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func refresh() {
        let selection = editor.textView.selectedRange
        status.text = "M0 OPEN | TextKit2=\(editor.textView.textLayoutManager != nil)\n" +
            "v=\(editor.revision) UTF16=\(editor.textView.text.utf16.count) sel=\(selection) " +
            "marked=\(editor.textView.markedTextRange != nil)\n" +
            "dirty=\(session.dirty) saving=\(session.saving) conflict=\(session.conflict)\n" + session.message
    }

    @objc private func fixture() {
        guard let fixture = Bundle.main.url(forResource: "m0", withExtension: "md") else { return }
        Task {
            do {
                let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let url = directory.appendingPathComponent("m0-\(UUID()).md")
                try Data(contentsOf: fixture).write(to: url, options: .atomic)
                let grant = try AccessGrant(root: url, scope: .singleFile, appPrivate: true)
                await session.open(url: url, grant: grant)
            } catch { session.report("Fixture creation failed.", event: "fixture-failed") }
        }
    }

    @objc private func pickFile() {
        pick(scope: .singleFile)
    }

    @objc private func pickFolder() {
        pick(scope: .directory)
    }

    private func pick(scope: AccessGrant.Scope) {
        guard editor.textView.markedTextRange == nil else {
            session.report("Picker refused during composition.", event: "picker-refused-marked"); return
        }
        pickerScope = scope
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: scope == .directory ? [.folder] : [.text],
                                                    asCopy: false)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        do {
            let grant = try AccessGrant(root: url, scope: pickerScope)
            try grant.saveRecent()
            choose(grant)
        } catch { session.report("Grant/bookmark failed. Reselect in Files.", event: "grant-failed") }
    }

    func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
        session.record("picker-cancelled")
    }

    @objc private func recent() {
        do { try choose(AccessGrant.restoreRecent()) }
        catch {
            session.report("Recent bookmark unavailable/stale. Reselect in Files.", event: "bookmark-restore-failed")
        }
    }

    private func choose(_ grant: AccessGrant) {
        if grant.scope == .singleFile {
            Task { await session.open(url: grant.root, grant: grant) }
            return
        }
        Task {
            do {
                let files = try await Task.detached { try grant.listMarkdownFiles() }.value
                let sheet = UIAlertController(
                    title: "Folder grant",
                    message: "Top-level Markdown files; symlinks excluded.",
                    preferredStyle: .actionSheet
                )
                for file in files.prefix(30) {
                    sheet.addAction(UIAlertAction(title: file.lastPathComponent, style: .default) { [self] _ in
                        Task { await session.open(url: file, grant: grant) }
                    })
                }
                sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                anchor(sheet)
                present(sheet, animated: true)
                session.record("directory-enumerated")
            } catch { session.report(
                "Folder unavailable/read denied. No empty snapshot substituted.",
                event: "directory-failed"
            ) }
        }
    }

    @objc private func save() {
        session.save()
    }

    @objc private func undo() {
        editor.undo()
    }

    @objc private func redo() {
        editor.redo()
    }

    @objc private func delay() {
        session.delaySave.toggle()
        editor.delayNanoseconds = session.delaySave ? 3_000_000_000 : 150_000_000
        session.report(session.delaySave ? "3s delay ON: capture save N, type N+1 before completion." : "Delay OFF.",
                       event: "delay-toggled")
    }

    @objc private func inspect() {
        guard editor.textView.markedTextRange == nil else {
            session.record("inspect-refused-marked"); return
        }
        let source = editor.textView.text ?? ""
        let selection = editor.textView.selectedRange
        let units = source.utf16.map { String(format: "%04x", $0) }.joined(separator: " ")
        alert("Source probe", "Source SHA256: \(digest(source))\nUTF-16: \(units)\nSelection: \(selection)\n" +
            "Undo=\(editor.textView.undoManager?.canUndo ?? false) Redo=\(editor.textView.undoManager?.canRedo ?? false)")
    }

    @objc private func recovery() {
        guard editor.textView.markedTextRange == nil else { session.record("recovery-view-refused-marked"); return }
        do {
            let snapshots = try RecoveryStore.applicationStore().readAll()
            alert("Recovery readback", snapshots.prefix(5).map {
                "\($0.documentID) v\($0.revision) \($0.reason)\n\($0.source)"
            }.joined(separator: "\n\n"))
            session.record("recovery-view-readback")
        } catch { session.report("Recovery readback failed.", event: "recovery-view-failed") }
    }

    @objc private func saveCopy() {
        guard editor.textView.markedTextRange == nil else { session.record("copy-refused-marked"); return }
        do {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = directory.appendingPathComponent("m0-copy-\(UUID()).md")
            let bytes = Data(editor.textView.text.utf8)
            try bytes.write(to: url, options: .atomic)
            guard try Data(contentsOf: url) == bytes else { throw CocoaError(.fileReadCorruptFile) }
            share(url)
            session.record("save-copy-readback")
        } catch { session.report("Save copy failed.", event: "save-copy-failed") }
    }

    @objc private func exportLog() {
        guard editor.textView.markedTextRange == nil else { session.record("export-refused-marked"); return }
        do { try share(probe.export()) }
        catch { session.report("Log export failed.", event: "log-export-failed") }
    }

    @objc private func viewSwitch() {
        guard editor.textView.markedTextRange == nil else { session.record("view-switch-refused-marked"); return }
        // Minimal read-only source pane, not the product Markdown preview.
        let pane = UIViewController()
        let label = UITextView()
        label.text = editor.textView.text
        label.isEditable = false
        pane.view = label
        present(pane, animated: true)
        session.record("read-only-pane-presented")
    }

    @objc private func externalProbe() {
        guard let document = session.document else { return }
        session
            .externalChange(url: document.fileURL) { [weak self] _ in self?.session.record("external-probe-returned") }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func anchor(_ controller: UIViewController) {
        controller.popoverPresentationController?.sourceView = view
        controller.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: 20, width: 1, height: 1)
    }

    private func share(_ url: URL) {
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        anchor(activity)
        present(activity, animated: true)
    }
}
