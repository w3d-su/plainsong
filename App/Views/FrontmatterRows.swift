import MarkdownCore
import SwiftUI

/// Frontmatter rows for the inspector's Frontmatter section; the source text stays the only
/// model.
///
/// The inspector owns text observation (one `.task` for the whole inspector). These rows
/// parse `text` and hand every edit back as a complete replacement document. They are
/// `InspectorSection` grid children: `InspectorRow`s, or full-width status views.
struct FrontmatterRows: View {
    let text: String
    let replaceText: (String) -> Void

    var body: some View {
        let result = Frontmatter.parse(text)

        if let error = result.error, let block = result.block {
            MalformedFrontmatterRows(rawYAML: block.rawYAML, message: error.message)
        } else if let block = result.block {
            if block.fields.isEmpty {
                Text("The frontmatter block is empty.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(block.fields) { field in
                    FrontmatterFieldRow(field: field, update: updateField(key:value:))
                }
            }
        } else {
            HStack {
                Text("No frontmatter")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Add", action: insertDefaultBlock)
            }
        }
    }

    private func updateField(key: String, value: FrontmatterValue) {
        guard let updatedText = Frontmatter.updating(text, key: key, value: value) else {
            return
        }
        replaceText(updatedText)
    }

    private func insertDefaultBlock() {
        replaceText(
            Frontmatter.insertingDefaultBlock(
                into: text,
                date: FrontmatterDateFormatting.string(from: Date())
            )
        )
    }
}

private struct FrontmatterFieldRow: View {
    let field: FrontmatterField
    let update: (String, FrontmatterValue) -> Void

    var body: some View {
        switch field.value {
        case let .bool(value):
            InspectorRow(field.key) {
                Toggle(field.key, isOn: Binding(
                    get: { value },
                    set: { update(field.key, .bool($0)) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
        case let .date(value):
            if Frontmatter.isPlainCalendarDate(value) {
                InspectorRow(field.key) {
                    DatePicker(
                        field.key,
                        selection: Binding(
                            get: { FrontmatterDateFormatting.date(from: value) ?? Date() },
                            set: { update(field.key, .date(FrontmatterDateFormatting.string(from: $0))) }
                        ),
                        displayedComponents: .date
                    )
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                }
            } else {
                StringFieldRow(key: field.key, value: value) { update(field.key, .date($0)) }
            }
        case let .stringList(values):
            TagsRow(key: field.key, values: values) { update(field.key, .stringList($0)) }
        case let .string(value):
            StringFieldRow(key: field.key, value: value) { update(field.key, .string($0)) }
        case let .raw(value):
            InspectorRow(field.key) {
                RawYAMLText(text: value, lineLimit: 6)
                    .help("This value can only be edited in the source.")
            }
        }
    }
}

private struct StringFieldRow: View {
    let key: String
    let value: String
    let update: (String) -> Void

    var body: some View {
        InspectorRow(key) {
            TextField(key, text: Binding(get: { value }, set: update), axis: .vertical)
                .labelsHidden()
                .lineLimit(1 ... 4)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct TagsRow: View {
    let key: String
    let values: [String]
    let update: ([String]) -> Void

    var body: some View {
        InspectorRow(key) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(key, text: tagsBinding, prompt: Text("Comma-separated"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)

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
    }

    private var tagsBinding: Binding<String> {
        Binding(
            get: { values.joined(separator: ", ") },
            set: { update(Self.splitTags($0)) }
        )
    }

    private static func splitTags(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct MalformedFrontmatterRows: View {
    let rawYAML: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Invalid YAML")
                    .fontWeight(.semibold)
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

            RawYAMLText(text: rawYAML, lineLimit: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Read-only YAML shown as selectable monospaced text; the source stays the only editor.
private struct RawYAMLText: View {
    let text: String
    let lineLimit: Int

    var body: some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(lineLimit)
            .textSelection(.enabled)
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
