import MarkdownCore
import SwiftUI

struct FrontmatterPanel: View {
    @ObservedObject var session: DocumentSession
    let onReplaceText: (String) -> Void

    @State private var textSnapshot: String?
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            content
                .padding(.top, 6)
        } label: {
            Label("Frontmatter", systemImage: "tag")
        }
        .task(id: ObjectIdentifier(session)) {
            await observeSession()
        }
    }

    @ViewBuilder
    private var content: some View {
        let result = Frontmatter.parse(currentText)

        if let error = result.error, let block = result.block {
            MalformedFrontmatterPanel(rawYAML: block.rawYAML, message: error.message)
        } else if let block = result.block {
            FrontmatterFieldsPanel(fields: block.fields, update: updateField(key:value:))
        } else {
            MissingFrontmatterPanel(insert: insertDefaultBlock)
        }
    }

    private var currentText: String {
        textSnapshot ?? session.text
    }

    @MainActor
    private func observeSession() async {
        textSnapshot = session.text
        for await change in session.textChanges(includeCurrent: true) {
            textSnapshot = change.text
        }
    }

    private func updateField(key: String, value: FrontmatterValue) {
        guard let updatedText = Frontmatter.updating(currentText, key: key, value: value) else {
            return
        }
        textSnapshot = updatedText
        onReplaceText(updatedText)
    }

    private func insertDefaultBlock() {
        let updatedText = Frontmatter.insertingDefaultBlock(
            into: currentText,
            date: FrontmatterDateFormatting.string(from: Date())
        )
        textSnapshot = updatedText
        onReplaceText(updatedText)
    }
}

private struct FrontmatterFieldsPanel: View {
    let fields: [FrontmatterField]
    let update: (String, FrontmatterValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if fields.isEmpty {
                Text("Empty frontmatter")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fields) { field in
                    FrontmatterFieldEditor(field: field, update: update)
                }
            }
        }
    }
}

private struct FrontmatterFieldEditor: View {
    let field: FrontmatterField
    let update: (String, FrontmatterValue) -> Void

    var body: some View {
        switch field.value {
        case let .bool(value):
            Toggle(field.key, isOn: boolBinding(value))
                .controlSize(.small)
        case let .date(value):
            if Frontmatter.isPlainCalendarDate(value) {
                DatePicker(
                    field.key,
                    selection: dateBinding(value),
                    displayedComponents: .date
                )
                .controlSize(.small)
            } else {
                LabeledTextField(key: field.key, value: value) { newValue in
                    update(field.key, .date(newValue))
                }
            }
        case let .stringList(values):
            TagsField(key: field.key, values: values, update: update)
        case let .string(value):
            LabeledTextField(key: field.key, value: value) { newValue in
                update(field.key, .string(newValue))
            }
        case let .raw(value):
            ReadOnlyFrontmatterField(key: field.key, value: value)
        }
    }

    private func boolBinding(_ value: Bool) -> Binding<Bool> {
        Binding(
            get: { value },
            set: { update(field.key, .bool($0)) }
        )
    }

    private func dateBinding(_ value: String) -> Binding<Date> {
        Binding(
            get: { FrontmatterDateFormatting.date(from: value) ?? Date() },
            set: { update(field.key, .date(FrontmatterDateFormatting.string(from: $0))) }
        )
    }
}

private struct LabeledTextField: View {
    let key: String
    let value: String
    let update: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(key, text: binding)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }
    }

    private var binding: Binding<String> {
        Binding(
            get: { value },
            set: { update($0) }
        )
    }
}

private struct ReadOnlyFrontmatterField: View {
    let key: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: .constant(value))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 64, maxHeight: 120)
                .disabled(true)
        }
    }
}

private struct TagsField: View {
    let key: String
    let values: [String]
    let update: (String, FrontmatterValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField(key, text: tagsBinding)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            if !values.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(values, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
        }
    }

    private var tagsBinding: Binding<String> {
        Binding(
            get: { values.joined(separator: ", ") },
            set: { update(key, .stringList(Self.splitTags($0))) }
        )
    }

    private static func splitTags(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct MissingFrontmatterPanel: View {
    let insert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No frontmatter")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(action: insert) {
                Label("Insert", systemImage: "plus")
            }
            .controlSize(.small)
        }
    }
}

private struct MalformedFrontmatterPanel: View {
    let rawYAML: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("YAML error", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)

            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextEditor(text: .constant(rawYAML))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 90, maxHeight: 140)
                .disabled(true)
        }
    }
}

private enum FrontmatterDateFormatting {
    static func string(from date: Date) -> String {
        formatter().string(from: date)
    }

    static func date(from string: String) -> Date? {
        formatter().date(from: string)
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
