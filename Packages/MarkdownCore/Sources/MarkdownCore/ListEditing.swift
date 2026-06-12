import Foundation

enum ListEditing {
    static func handleEnter(in text: String, selection: NSRange, fileKind _: FileKind) -> MarkdownEditResult? {
        guard selection.length == 0 else { return nil }

        let line = MarkdownTextEditingSupport.line(containing: selection.location, in: text)
        guard let item = MarkdownListItem(line.text) else { return nil }

        if item.isEmpty {
            return exitEmptyItem(item, line: line)
        }

        if item.orderedNumber != nil {
            return continueOrderedItem(item, line: line, text: text, selection: selection)
        }

        return continueUnorderedItem(item, selection: selection)
    }

    private static func exitEmptyItem(_ item: MarkdownListItem, line: MarkdownLine) -> MarkdownEditResult {
        let range = NSRange(location: line.range.location, length: item.prefixLength)
        let newLocation = line.range.location + MarkdownTextEditingSupport.utf16Length(item.indent)
        return MarkdownTextEditingSupport.replacement(
            range: range,
            string: item.indent,
            selection: NSRange(location: newLocation, length: 0)
        )
    }

    private static func continueUnorderedItem(_ item: MarkdownListItem, selection: NSRange) -> MarkdownEditResult {
        let marker = "\n\(item.nextMarkerText)"
        return MarkdownTextEditingSupport.replacement(
            range: selection,
            string: marker,
            selection: NSRange(location: selection.location + MarkdownTextEditingSupport.utf16Length(marker), length: 0)
        )
    }

    private static func continueOrderedItem(
        _ item: MarkdownListItem,
        line: MarkdownLine,
        text: String,
        selection: NSRange
    ) -> MarkdownEditResult? {
        guard let orderedNumber = item.orderedNumber else { return nil }
        let renumberedTail = renumberFollowingOrderedItems(
            in: text,
            after: line,
            indent: item.indent,
            delimiter: item.orderedDelimiter ?? ".",
            startingAt: orderedNumber + 2
        )

        let insertedMarker = "\n\(item.nextMarkerText)"
        if renumberedTail.range.length == 0 {
            return MarkdownTextEditingSupport.replacement(
                range: selection,
                string: insertedMarker,
                selection: NSRange(
                    location: selection.location + MarkdownTextEditingSupport.utf16Length(insertedMarker),
                    length: 0
                )
            )
        }

        let afterCursorRange = NSRange(location: selection.location, length: line.endLocation - selection.location)
        let afterCursor = MarkdownTextEditingSupport.substring(afterCursorRange, in: text)
        let replacementRange = NSRange(
            location: selection.location,
            length: renumberedTail.range.location + renumberedTail.range.length - selection.location
        )
        let replacement = insertedMarker + afterCursor + renumberedTail.leadingNewline + renumberedTail.text
        return MarkdownTextEditingSupport.replacement(
            range: replacementRange,
            string: replacement,
            selection: NSRange(
                location: selection.location + MarkdownTextEditingSupport.utf16Length(insertedMarker),
                length: 0
            )
        )
    }

    static func handleTab(in text: String, selection: NSRange, backwards: Bool) -> MarkdownEditResult? {
        guard selection.length == 0 else { return nil }

        let line = MarkdownTextEditingSupport.line(containing: selection.location, in: text)
        guard let item = MarkdownListItem(line.text) else { return nil }

        if backwards {
            let removable = min(4, MarkdownTextEditingSupport.utf16Length(item.indent))
            guard removable > 0 else { return nil }
            return MarkdownTextEditingSupport.replacement(
                range: NSRange(location: line.range.location, length: removable),
                string: "",
                selection: NSRange(location: max(line.range.location, selection.location - removable), length: 0)
            )
        }

        return MarkdownTextEditingSupport.replacement(
            range: NSRange(location: line.range.location, length: 0),
            string: "    ",
            selection: NSRange(location: selection.location + 4, length: 0)
        )
    }

    private static func renumberFollowingOrderedItems(
        in text: String,
        after line: MarkdownLine,
        indent: String,
        delimiter: String,
        startingAt number: Int
    ) -> OrderedListRenumbering {
        let storage = text as NSString
        let newlineRange = NSRange(location: line.endLocation, length: line.fullEndLocation - line.endLocation)
        guard newlineRange.length > 0 else {
            return OrderedListRenumbering.empty(at: line.fullEndLocation)
        }

        var cursor = line.fullEndLocation
        var nextNumber = number
        var rewritten = ""
        var blockEnd = cursor

        while cursor < storage.length {
            let nextLine = MarkdownTextEditingSupport.line(containing: cursor, in: text)
            guard let item = MarkdownListItem(nextLine.text),
                  item.indent == indent,
                  item.orderedNumber != nil,
                  item.orderedDelimiter == delimiter
            else {
                break
            }

            let replacementPrefix = "\(indent)\(nextNumber)\(delimiter) "
            let contentRange = NSRange(
                location: nextLine.range.location + item.prefixLength,
                length: nextLine.range.length - item.prefixLength
            )
            rewritten += replacementPrefix + MarkdownTextEditingSupport.substring(contentRange, in: text)
            if nextLine.fullRange.length > nextLine.range.length {
                rewritten += MarkdownTextEditingSupport.substring(
                    NSRange(location: nextLine.endLocation, length: nextLine.fullEndLocation - nextLine.endLocation),
                    in: text
                )
            }

            blockEnd = nextLine.fullEndLocation
            cursor = nextLine.fullEndLocation
            nextNumber += 1
        }

        guard blockEnd > line.fullEndLocation else {
            return OrderedListRenumbering.empty(at: line.fullEndLocation)
        }

        return OrderedListRenumbering(
            range: NSRange(location: line.fullEndLocation, length: blockEnd - line.fullEndLocation),
            leadingNewline: MarkdownTextEditingSupport.substring(newlineRange, in: text),
            text: rewritten
        )
    }
}

private struct OrderedListRenumbering {
    let range: NSRange
    let leadingNewline: String
    let text: String

    static func empty(at location: Int) -> OrderedListRenumbering {
        OrderedListRenumbering(
            range: NSRange(location: location, length: 0),
            leadingNewline: "",
            text: ""
        )
    }
}

struct MarkdownListItem {
    let indent: String
    let marker: String
    let orderedNumber: Int?
    let orderedDelimiter: String?
    let hasCheckbox: Bool
    let checkboxState: Character?
    let prefixLength: Int
    let content: String

    init?(_ line: String) {
        let units = Array(line.utf16)
        var index = 0
        while index < units.count, units[index] == 32 || units[index] == 9 {
            index += 1
        }

        let indentLength = index
        guard index < units.count else { return nil }

        guard let parsedMarker = Self.parseMarker(in: units, at: index) else { return nil }
        index = parsedMarker.nextIndex

        let spacesAfterMarkerStart = index
        while index < units.count, units[index] == 32 || units[index] == 9 {
            index += 1
        }
        guard index > spacesAfterMarkerStart else { return nil }

        let parsedCheckbox = Self.parseCheckbox(in: units, at: index)
        index = parsedCheckbox.nextIndex

        let indent = Self.string(from: units[0 ..< indentLength])
        self.indent = indent
        marker = parsedMarker.marker
        orderedNumber = parsedMarker.orderedNumber
        orderedDelimiter = parsedMarker.orderedDelimiter
        hasCheckbox = parsedCheckbox.hasCheckbox
        checkboxState = parsedCheckbox.checkboxState
        prefixLength = index
        content = Self.string(from: units[index ..< units.count])
    }

    var isEmpty: Bool {
        MarkdownTextEditingSupport.isBlank(content)
    }

    var nextMarkerText: String {
        if hasCheckbox {
            return "\(indent)\(marker) [ ] "
        }
        if let orderedNumber, let orderedDelimiter {
            return "\(indent)\(orderedNumber + 1)\(orderedDelimiter) "
        }
        return "\(indent)\(marker) "
    }

    private static func string(from units: ArraySlice<UInt16>) -> String {
        String(decoding: units, as: UTF16.self)
    }

    private static func parseMarker(in units: [UInt16], at startIndex: Int) -> ParsedMarker? {
        var index = startIndex
        if units[index] == 45 || units[index] == 42 || units[index] == 43 {
            return ParsedMarker(
                marker: String(UnicodeScalar(units[index])!),
                orderedNumber: nil,
                orderedDelimiter: nil,
                nextIndex: index + 1
            )
        }

        guard units[index] >= 48, units[index] <= 57 else { return nil }
        let numberStart = index
        while index < units.count, units[index] >= 48, units[index] <= 57 {
            index += 1
        }
        guard index < units.count, units[index] == 46 || units[index] == 41 else { return nil }

        let numberText = string(from: units[numberStart ..< index])
        let delimiter = String(UnicodeScalar(units[index])!)
        return ParsedMarker(
            marker: numberText + delimiter,
            orderedNumber: Int(numberText),
            orderedDelimiter: delimiter,
            nextIndex: index + 1
        )
    }

    private static func parseCheckbox(in units: [UInt16], at index: Int) -> ParsedCheckbox {
        guard hasCheckboxSyntax(in: units, at: index) else {
            return ParsedCheckbox(hasCheckbox: false, checkboxState: nil, nextIndex: index)
        }

        let afterCheckbox = index + 3
        guard afterCheckbox == units.count || units[afterCheckbox] == 32 || units[afterCheckbox] == 9 else {
            return ParsedCheckbox(hasCheckbox: false, checkboxState: nil, nextIndex: index)
        }

        var nextIndex = afterCheckbox
        while nextIndex < units.count, units[nextIndex] == 32 || units[nextIndex] == 9 {
            nextIndex += 1
        }

        return ParsedCheckbox(
            hasCheckbox: true,
            checkboxState: Character(UnicodeScalar(units[index + 1])!),
            nextIndex: nextIndex
        )
    }

    private static func hasCheckboxSyntax(in units: [UInt16], at index: Int) -> Bool {
        index + 2 < units.count &&
            units[index] == 91 &&
            units[index + 2] == 93 &&
            (units[index + 1] == 32 || units[index + 1] == 120 || units[index + 1] == 88)
    }
}

private struct ParsedMarker {
    let marker: String
    let orderedNumber: Int?
    let orderedDelimiter: String?
    let nextIndex: Int
}

private struct ParsedCheckbox {
    let hasCheckbox: Bool
    let checkboxState: Character?
    let nextIndex: Int
}
