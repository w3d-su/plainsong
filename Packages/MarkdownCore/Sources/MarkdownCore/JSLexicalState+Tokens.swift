import Foundation

/// Slash, operator, identifier, number, and character-class helpers for
/// `JSLexicalState.advance`.
extension JSLexicalState {
    /// `//` and `/*` are handled as trivia before this point.
    mutating func advanceSlash(_ next: unichar, at index: Int) -> (Int, Bool) {
        // `parseExprAtom` re-reads a division slash as a regexp when it is
        // the operand `parseAwait` is parsing.
        if exprAllowed || awaitOperand {
            awaitOperand = false
            mode = .regexp(inClass: false, escaped: false)
            return (index + 1, false)
        }
        exprAllowed = true
        previous = .other(beforeExpression: true)
        return (next == 61 ? index + 2 : index + 1, false)
    }

    /// acorn `incDec` leaves `exprAllowed` unchanged; `+`/`-` are binary or
    /// prefix operators.
    mutating func advancePlusOrMinus(
        _ unit: unichar,
        _ next: unichar,
        at index: Int
    ) -> (Int, Bool) {
        if next == unit {
            previous = .other(beforeExpression: false)
            return (index + 2, false)
        }
        exprAllowed = true
        previous = .other(beforeExpression: true)
        return (next == 61 ? index + 2 : index + 1, false)
    }

    /// acorn `star.updateContext`: right after `function`, `*` marks the
    /// function context as a generator.
    mutating func advanceStar(
        _ next: unichar, in storage: NSString, at index: Int
    ) -> (Int, Bool) {
        if previous == .keyword("function"), next != 42, next != 61,
           case let .function(isExpression, _) = currentContext
        {
            contexts[contexts.count - 1] = .function(isExpression: isExpression, isGenerator: true)
            exprAllowed = true
            previous = .star
            return (index + 1, false)
        }
        let length = operatorLength(42, next: next, in: storage, at: index)
        exprAllowed = true
        previous = length == 1 ? .star : .other(beforeExpression: true)
        return (index + length, false)
    }

    mutating func consumeIdentifier(in storage: NSString, at index: Int) -> (Int, Bool) {
        var end = index + 1
        while end < storage.length, isIdentContinue(storage.character(at: end)) {
            end += 1
        }
        let word = storage.substring(with: NSRange(location: index, length: end - index))
        applyIdentifier(word)
        return (end, false)
    }

    /// acorn `readWord` + `updateContext`: keywords after `.` are property
    /// names that allow no expression; `function`/`class` open a context;
    /// `of` and generator `yield` allow an expression.
    mutating func applyIdentifier(_ word: String) {
        let memberName = previous == .dot || previous == .questionDot
        // `for await` is a loop head, not an await expression. Any other
        // `await` that can start an expression is `parseAwait`: its operand
        // may be a regexp even though this name token leaves `exprAllowed` false.
        let marksForAwait = word == "await" && !memberName && forAwaitReady
        let marksAwaitOperand = word == "await" && !memberName && !marksForAwait
        if !marksAwaitOperand {
            awaitOperand = false
        }
        forAwaitHead = marksForAwait
        forAwaitReady = false
        guard Self.keywords.contains(word) else {
            if marksForAwait || marksAwaitOperand {
                exprAllowed = false
                previous = .name
                awaitOperand = marksAwaitOperand
                return
            }
            var allowed = false
            if !memberName {
                allowed = (word == "of" && !exprAllowed) || (word == "yield" && inGeneratorContext)
            }
            exprAllowed = allowed
            previous = .name
            return
        }
        if memberName {
            exprAllowed = false
        } else if word == "function" || word == "class" {
            openFunctionContext()
        } else {
            exprAllowed = Self.beforeExpressionKeywords.contains(word)
        }
        if word == "for", !memberName {
            forAwaitReady = true
        }
        previous = .keyword(word)
    }

    /// End of an `async` modifier followed, on the same JavaScript line, by
    /// `function`, with only whitespace and block comments between them. A
    /// line terminator — CR, LF, U+2028, or U+2029, including one inside the
    /// comment — separates them, so this returns nil.
    func asyncFunctionModifierEnd(in storage: NSString, at index: Int) -> Int? {
        let keyword = "async"
        let length = (keyword as NSString).length
        guard index + length < storage.length,
              storage.substring(with: NSRange(location: index, length: length)) == keyword,
              previous != .dot,
              index == 0 || !isIdentContinue(storage.character(at: index - 1)),
              !isIdentContinue(storage.character(at: index + length))
        else { return nil }
        guard let cursor = skipSameLineTrivia(in: storage, from: index + length) else { return nil }
        let function = "function"
        let functionLength = (function as NSString).length
        guard cursor + functionLength <= storage.length,
              storage.substring(with: NSRange(location: cursor, length: functionLength)) == function
        else { return nil }
        let after = cursor + functionLength
        guard after >= storage.length || !isIdentContinue(storage.character(at: after)) else { return nil }
        return cursor
    }

    /// Skips whitespace and `/* … */` comments that close on this JavaScript
    /// line. U+2028/U+2029 are line terminators, so a comment that contains
    /// one does not keep `async` and `function` on the same line.
    func skipSameLineTrivia(in storage: NSString, from start: Int) -> Int? {
        var cursor = start
        while cursor < storage.length {
            let unit = storage.character(at: cursor)
            let next = cursor + 1 < storage.length ? storage.character(at: cursor + 1) : 0
            if lineTerminatorLength(unit, next) != nil { return nil }
            if isJSWhitespace(unit) {
                cursor += 1
                continue
            }
            guard unit == 47, next == 42 else { break }
            var scan = cursor + 2
            var closed = false
            while scan < storage.length {
                let commentUnit = storage.character(at: scan)
                let commentNext = scan + 1 < storage.length ? storage.character(at: scan + 1) : 0
                if lineTerminatorLength(commentUnit, commentNext) != nil { return nil }
                if commentUnit == 42, commentNext == 47 {
                    cursor = scan + 2
                    closed = true
                    break
                }
                scan += 1
            }
            if !closed { return nil }
        }
        return cursor
    }

    mutating func consumeDot(_ next: unichar, in storage: NSString, at index: Int) -> (Int, Bool) {
        if next >= 48, next <= 57 {
            let end = consumeNumber(in: storage, at: index)
            finishOperand()
            return (end, false)
        }
        let third = index + 2 < storage.length ? storage.character(at: index + 2) : 0
        if next == 46, third == 46 {
            exprAllowed = true
            previous = .other(beforeExpression: true)
            return (index + 3, false)
        }
        exprAllowed = false
        previous = .dot
        return (index + 1, false)
    }

    /// `?.` (not before a digit) is optional chaining, `??` nullish
    /// coalescing; a lone `?` opens a ternary whose `:` pairs at this depth.
    mutating func consumeQuestion(
        _ next: unichar,
        in storage: NSString,
        at index: Int
    ) -> (Int, Bool) {
        let third = index + 2 < storage.length ? storage.character(at: index + 2) : 0
        if next == 46, !(third >= 48 && third <= 57) {
            exprAllowed = false
            previous = .questionDot
            return (index + 2, false)
        }
        if next == 63 {
            exprAllowed = true
            previous = .other(beforeExpression: true)
            return (third == 61 ? index + 3 : index + 2, false)
        }
        ternaryContextCounts.append(contexts.count)
        exprAllowed = true
        previous = .other(beforeExpression: true)
        return (index + 1, false)
    }

    func operatorLength(
        _ unit: unichar,
        next: unichar,
        in storage: NSString,
        at index: Int
    ) -> Int {
        let third = index + 2 < storage.length ? storage.character(at: index + 2) : 0
        switch unit {
        case 61:
            if next == 61 { return third == 61 ? 3 : 2 }
            if next == 62 { return 2 }
            return 1
        case 33:
            if next == 61 { return third == 61 ? 3 : 2 }
            return 1
        case 42:
            if next == 42 { return third == 61 ? 3 : 2 }
            return next == 61 ? 2 : 1
        case 38, 124:
            if next == unit { return third == 61 ? 3 : 2 }
            return next == 61 ? 2 : 1
        case 60, 62:
            if next == unit {
                if third == unit { return storageHasEquals(at: index + 3, in: storage) ? 4 : 3 }
                return third == 61 ? 3 : 2
            }
            return next == 61 ? 2 : 1
        default:
            return next == 61 ? 2 : 1
        }
    }

    func storageHasEquals(at index: Int, in storage: NSString) -> Bool {
        index < storage.length && storage.character(at: index) == 61
    }

    func consumeNumber(in storage: NSString, at index: Int) -> Int {
        var end = index + 1
        while end < storage.length {
            let unit = storage.character(at: end)
            let continues = (unit >= 48 && unit <= 57) || unit == 46 || unit == 95 ||
                (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
            guard continues else { break }
            end += 1
        }
        return end
    }

    /// ECMAScript `LineTerminator`: LF, CR, U+2028, U+2029, and CRLF as one.
    /// The markdown line splitter only breaks on CR/LF, so the other two
    /// arrive here as ordinary text and still have to set `followsLineBreak`.
    func lineTerminatorLength(_ unit: unichar, _ next: unichar) -> Int? {
        if unit == 13, next == 10 { return 2 }
        if unit == 10 || unit == 13 || unit == 0x2028 || unit == 0x2029 { return 1 }
        return nil
    }

    func isJSWhitespace(_ unit: unichar) -> Bool {
        switch unit {
        case 9, 11, 12, 32, 0xA0, 0xFEFF, 0x1680, 0x202F, 0x205F, 0x3000:
            true
        case 0x2000 ... 0x200A:
            true
        default:
            false
        }
    }

    func isIdentStart(_ unit: unichar) -> Bool {
        if unit == 36 || unit == 95 { return true }
        if (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) { return true }
        return isUnicodeLetter(unit)
    }

    func isIdentContinue(_ unit: unichar) -> Bool {
        isIdentStart(unit) || (unit >= 48 && unit <= 57)
    }
}
