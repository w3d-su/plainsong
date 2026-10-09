import EditorKitIOS
import MarkdownCore
import SwiftUI

struct IOSAuthoringToolbar<Editor: IOSSourceEditorControlling>: View {
    @ObservedObject var controller: IOSAuthoringController
    let editor: Editor

    var body: some View {
        let snapshot = editor.captureSnapshot()
        HStack {
            ForEach(toolbarActions, id: \.title) { item in
                Button(item.title) {
                    controller.perform(item.id, using: editor)
                }
                .accessibilityLabel(item.accessibilityLabel)
                .disabled(!controller.isEnabled(item.id, snapshot: snapshot))
            }
            Menu("Heading") {
                ForEach(grouped("Heading"), id: \.title) { item in
                    Button(item.title) {
                        controller.perform(item.id, using: editor)
                    }
                    .accessibilityLabel(item.accessibilityLabel)
                }
            }
            Menu("Code") {
                ForEach(grouped("Code"), id: \.title) { item in
                    Button(item.title) {
                        controller.perform(item.id, using: editor)
                    }
                    .accessibilityLabel(item.accessibilityLabel)
                    .disabled(!controller.isEnabled(item.id, snapshot: snapshot))
                }
            }
            Menu("Format") {
                ForEach(formatActions, id: \.title) { item in
                    Button(item.title) {
                        controller.perform(item.id, using: editor)
                    }
                    .accessibilityLabel(item.accessibilityLabel)
                    .disabled(!controller.isEnabled(item.id, snapshot: snapshot))
                }
            }
        }
        .sheet(item: $controller.linkDraft) { draft in
            IOSAuthoringLinkSheet(controller: controller, editor: editor, draft: draft)
        }
    }

    private var toolbarActions: [IOSAuthoringAction] {
        controller.actions.filter { if case .toolbar = $0.placement { true } else { false } }
    }

    private var formatActions: [IOSAuthoringAction] {
        controller.actions.filter {
            if case .formatMenu = $0.placement { true } else { false }
        }
    }

    private func grouped(_ name: String) -> [IOSAuthoringAction] {
        controller.actions.filter {
            if case let .toolbarGroup(group) = $0.placement { group == name } else { false }
        }
    }
}

struct IOSAuthoringLinkSheet<Editor: IOSSourceEditorControlling>: View {
    @ObservedObject var controller: IOSAuthoringController
    let editor: Editor
    let draft: IOSLinkDraft

    var body: some View {
        VStack(alignment: .leading) {
            if draft.collectsLabel {
                TextField("Label", text: label)
                    .accessibilityLabel("Link label")
            }
            TextField("URL", text: url)
                .accessibilityLabel("Link URL")
            Button("Add Link") {
                controller.confirmLink(using: editor)
            }
            .accessibilityLabel("Add Link")
            if !controller.statusMessage.isEmpty {
                Text(controller.statusMessage).accessibilityLabel(controller.statusMessage)
            }
        }
        .padding()
    }

    private var label: Binding<String> {
        Binding(get: { controller.linkDraft?.label ?? "" }, set: controller.setLinkLabel)
    }

    private var url: Binding<String> {
        Binding(get: { controller.linkDraft?.url ?? "" }, set: controller.setLinkURL)
    }
}

struct IOSAuthoringFrontmatterPanel<Editor: IOSSourceEditorControlling>: View {
    @ObservedObject var controller: IOSAuthoringController
    let editor: Editor

    var body: some View {
        let parse = controller.frontmatter.acceptedParse
        VStack(alignment: .leading) {
            if let error = parse.error {
                Text(parse.block?.rawYAML ?? "")
                    .accessibilityLabel("Frontmatter source")
                Text(error.message).accessibilityLabel(error.message)
            } else if parse.block == nil {
                Button("Add Frontmatter") {
                    controller.insertDefaultFrontmatter(date: displayedDate, using: editor)
                }
                .accessibilityLabel("Add Frontmatter")
            } else if let fields = parse.block?.fields {
                ForEach(fields) { field in
                    fieldRow(field)
                }
            }
            if !controller.frontmatter.drafts.isEmpty {
                Button("Discard Draft") { controller.discardFrontmatterDrafts(using: editor) }
                    .accessibilityLabel("Discard frontmatter draft")
            }
            if !controller.statusMessage.isEmpty {
                Text(controller.statusMessage).accessibilityLabel(controller.statusMessage)
            }
        }
        .onAppear { controller.startObservingFrontmatter(using: editor) }
        .onDisappear { controller.stopObservingFrontmatter() }
    }

    private var displayedDate: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    @ViewBuilder
    private func fieldRow(_ field: FrontmatterField) -> some View {
        if field.value.isEditable {
            switch displayed(field) {
            case let .bool(value):
                Toggle(field.key, isOn: Binding(
                    get: { value },
                    set: { _ in controller.toggleFrontmatterBool(key: field.key, using: editor) }
                ))
            case let .string(value):
                CommitField(key: field.key, initial: value, begin: beginDraft, change: {
                    controller.setFrontmatterDraft(key: field.key, value: .string($0), using: editor)
                }) { controller.commitFrontmatter(key: field.key, value: .string($0), using: editor) }
            case let .date(value):
                CommitField(key: field.key, initial: value, begin: beginDraft, change: {
                    controller.setFrontmatterDraft(key: field.key, value: .date($0), using: editor)
                }) { controller.commitFrontmatter(key: field.key, value: .date($0), using: editor) }
            case let .stringList(values):
                CommitField(key: field.key, initial: values.joined(separator: ", "), begin: beginDraft, change: {
                    controller.setFrontmatterDraft(key: field.key, value: .stringList(tags($0)), using: editor)
                }) { controller.commitFrontmatter(key: field.key, value: .stringList(tags($0)), using: editor) }
            case .raw:
                EmptyView()
            }
        } else {
            Text(field.rawValue ?? field.value.stringValue)
                .accessibilityLabel(field.key)
        }
    }

    private func displayed(_ field: FrontmatterField) -> FrontmatterValue {
        controller.displayedFrontmatterValue(field)
    }

    private func beginDraft() {
        controller.beginFrontmatterDraft(using: editor)
    }

    private func tags(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

private struct CommitField: View {
    let key: String
    let initial: String
    let begin: () -> Void
    let change: (String) -> Void
    let commit: (String) -> Void
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(key: String, initial: String, begin: @escaping () -> Void,
         change: @escaping (String) -> Void, commit: @escaping (String) -> Void)
    {
        self.key = key
        self.initial = initial
        self.begin = begin
        self.change = change
        self.commit = commit
        _text = State(initialValue: initial)
    }

    var body: some View {
        TextField(key, text: $text)
            .focused($isFocused)
            .accessibilityLabel(key)
            .onChange(of: isFocused) { _, focused in if focused { begin() } }
            .onChange(of: text) { _, value in if isFocused, value != initial { change(value) } }
            .onChange(of: initial) { _, value in text = value }
            .onSubmit { commit(text) }
    }
}

struct IOSAuthoringFindBar<Editor: IOSSourceEditorControlling>: View {
    @ObservedObject var controller: IOSAuthoringController
    let editor: Editor
    @FocusState private var findFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading) {
            TextField("Find", text: Binding(
                get: { controller.find.queryText },
                set: { controller.setFindQuery($0, using: editor) }
            ))
            .focused($findFieldFocused)
            .accessibilityLabel("Find")
            .onChange(of: findFieldFocused) { _, focused in
                if focused {
                    controller.noteFindFieldFocused(using: editor)
                }
            }
            Picker("Case", selection: Binding(
                get: { controller.find.caseSensitivity },
                set: { controller.setFindCase($0, using: editor) }
            )) {
                Text("Smart").tag(TextSearchCaseSensitivity.smart)
                Text("Sensitive").tag(TextSearchCaseSensitivity.sensitive)
                Text("Insensitive").tag(TextSearchCaseSensitivity.insensitive)
            }
            .accessibilityLabel("Find case")
            Toggle("Whole Word", isOn: Binding(
                get: { controller.find.wholeWord },
                set: { controller.setFindWholeWord($0, using: editor) }
            ))
            .accessibilityLabel("Whole Word")
            Text(controller.find.counterText).accessibilityLabel("Find count")
            Text(controller.find.message).accessibilityLabel(controller.find.message)
            HStack {
                Button("Find Next") { controller.perform(.nextMatch, using: editor) }
                Button("Find Previous") { controller.perform(.previousMatch, using: editor) }
            }
            TextField("Replace", text: Binding(
                get: { controller.find.replacement },
                set: controller.setReplacement
            ))
            .accessibilityLabel("Replace")
            Button("Replace") { controller.perform(.singleReplace, using: editor) }
                .accessibilityLabel("Replace")
        }
    }
}
