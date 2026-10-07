import MarkdownCore
import SwiftUI

/// Frontmatter inspector rows; the hosting sidebar section supplies the header.
struct FrontmatterPanel: View {
    @ObservedObject var session: DocumentSession
    let onReplaceText: (String) -> Void

    @State private var textSnapshot: String?

    var body: some View {
        content
            .padding(.vertical, 4)
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
                Text("The frontmatter block is empty.")
                    .font(.callout)
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
            LabeledContent {
                Toggle(field.key, isOn: boolBinding(value))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            } label: {
                FieldKeyLabel(key: field.key)
            }
        case let .date(value):
            if Frontmatter.isPlainCalendarDate(value) {
                LabeledContent {
                    DatePicker(
                        field.key,
                        selection: dateBinding(value),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .controlSize(.small)
                } label: {
                    FieldKeyLabel(key: field.key)
                }
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
            FieldKeyLabel(key: key)

            TextField(key, text: binding)
                .labelsHidden()
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
            FieldKeyLabel(key: key)

            RawYAMLView(text: value, lineLimit: 8)
                .help("This value can only be edited in the source.")
        }
    }
}

private struct TagsField: View {
    let key: String
    let values: [String]
    let update: (String, FrontmatterValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            FieldKeyLabel(key: key)

            TextField(key, text: tagsBinding, prompt: Text("Comma-separated"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)

            if !values.isEmpty {
                TagFlowLayout {
                    ForEach(values, id: \.self) { tag in
                        Text(tag)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.14), in: Capsule())
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Tags: \(values.joined(separator: ", "))")
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
            Text("This document has no frontmatter.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Add Frontmatter", action: insert)
                .controlSize(.small)
        }
    }
}

private struct MalformedFrontmatterPanel: View {
    let rawYAML: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Invalid YAML")
                    .font(.callout.weight(.semibold))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            RawYAMLView(text: rawYAML, lineLimit: 12)
        }
    }
}

private struct FieldKeyLabel: View {
    let key: String

    var body: some View {
        Text(key)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Read-only YAML shown as selectable monospaced text; the source stays the only editor.
private struct RawYAMLView: View {
    let text: String
    let lineLimit: Int

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(lineLimit)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
