import Foundation

/// Punctuation, bracket, and JSX transitions for `JSLexicalState.advance`.
extension JSLexicalState {
    mutating func advanceNormal(
        _ unit: unichar,
        _ next: unichar,
        in storage: NSString,
        at index: Int
    ) -> (Int, Bool) {
        if let length = lineTerminatorLength(unit, next) {
            endOfLine()
            return (index + length, false)
        }
        if isJSWhitespace(unit) {
            return (index + 1, false)
        }
        // Comments are trivia: they keep the previous token and any pending
        // line break; a break inside one is recorded by `endOfLine`.
        if unit == 47, next == 47 {
            mode = .lineComment
            return (index + 2, false)
        }
        if unit == 47, next == 42 {
            mode = .blockComment
            return (index + 2, false)
        }
        // `async` before `function` is a name token to acorn's tokenizer; the
        // parser overrides the function to an expression outside statements.
        if let end = asyncFunctionModifierEnd(in: storage, at: index) {
            asyncOverride = isStatementStart ? .none : .awaitingFunction
            exprAllowed = false
            previous = .name
            followsLineBreak = false
            return (end, false)
        }
        let result: (Int, Bool)
        if isIdentStart(unit) {
            result = consumeIdentifier(in: storage, at: index)
        } else if unit >= 48, unit <= 57 {
            result = (consumeNumber(in: storage, at: index), false)
            finishOperand()
        } else {
            result = advancePunctuation(unit, next, in: storage, at: index)
        }
        followsLineBreak = false
        applyAsyncOverrideIfDue(afterFunctionKeyword: previous == .keyword("function"))
        return result
    }

    mutating func advancePunctuation(
        _ unit: unichar,
        _ next: unichar,
        in storage: NSString,
        at index: Int
    ) -> (Int, Bool) {
        // `for await` and an await operand survive trivia, not a real token.
        // `/` is the exception: it still needs to see `awaitOperand`.
        retireAwaitFlags(before: unit)
        switch unit {
        case 123:
            return openBrace(at: index)
        case 125:
            return closeBrace(at: index)
        case 39:
            mode = .singleQuoted
            return (index + 1, false)
        case 34:
            mode = .doubleQuoted
            return (index + 1, false)
        case 96:
            mode = .template
            return (index + 1, false)
        case 47:
            return advanceSlash(next, at: index)
        case 40:
            return openParen(at: index)
        case 41:
            closeContext()
            previous = .parenClose
            return (index + 1, false)
        case 91:
            // acorn `bracketL` has no context of its own.
            exprAllowed = true
            previous = .other(beforeExpression: true)
            return (index + 1, false)
        case 93:
            exprAllowed = false
            previous = .other(beforeExpression: false)
            return (index + 1, false)
        case 46:
            return consumeDot(next, in: storage, at: index)
        case 63:
            return consumeQuestion(next, in: storage, at: index)
        case 43, 45:
            return advancePlusOrMinus(unit, next, at: index)
        case 42:
            return advanceStar(next, in: storage, at: index)
        case 60:
            return advanceLessThan(next, in: storage, at: index)
        case 33, 37, 38, 61, 62, 94, 124, 126:
            return finishOperator(unit, next: next, in: storage, at: index)
        case 44:
            exprAllowed = true
            previous = .other(beforeExpression: true)
            return (index + 1, false)
        case 58:
            return advanceColon(at: index)
        case 59:
            exprAllowed = true
            previous = .semicolon
            return (index + 1, false)
        default:
            exprAllowed = false
            previous = .other(beforeExpression: false)
            return (index + 1, false)
        }
    }

    /// Trivia may sit between `for`, `await`, and `(`. Any other token ends
    /// that head. A `/` still has to observe `awaitOperand` before it is cleared.
    mutating func retireAwaitFlags(before unit: unichar) {
        if unit != 40 {
            forAwaitHead = false
        }
        if unit != 47 {
            awaitOperand = false
        }
        forAwaitReady = false
    }

    /// acorn `parenL`: statement parens after if/for/with/while.
    /// `for await (` is the same head — the token before `(` is `await`.
    mutating func openParen(at index: Int) -> (Int, Bool) {
        let isStatement = forAwaitHead || ["if", "for", "with", "while"].contains { previous == .keyword($0) }
        forAwaitHead = false
        contexts.append(isStatement ? .parenStatement : .parenExpression)
        exprAllowed = true
        previous = .parenOpen
        return (index + 1, false)
    }

    mutating func openBrace(at index: Int) -> (Int, Bool) {
        let isBlock = braceIsBlock()
        if !isBlock, isStatementStart {
            statementBlockContextCounts.append(contexts.count)
        }
        contexts.append(isBlock ? .blockStatement : .blockExpression)
        depth += 1
        exprAllowed = true
        previous = .braceOpen
        return (index + 1, false)
    }

    mutating func closeBrace(at index: Int) -> (Int, Bool) {
        depth -= 1
        if let resume = templateResumes.last, depth == resume.depth {
            templateResumes.removeLast()
            truncateContexts(to: resume.contextCount)
            mode = .template
            return (index + 1, false)
        }
        if depth == 0 { return (index + 1, true) }
        if let resume = jsxResumes.last, depth == resume.depth {
            jsxResumes.removeLast()
            truncateContexts(to: resume.contextCount)
            jsxDepth = resume.jsxDepth
            mode = resume.children ? .jsxChildren : .jsxTag(closing: false)
            return (index + 1, false)
        }
        let isStatementBlock = statementBlockContextCounts.last == contexts.count - 1
        closeContext()
        if isStatementBlock {
            exprAllowed = true
        }
        previous = .braceClose
        return (index + 1, false)
    }

    /// acorn `colon.updateContext` (a `function`/`class` keyword used as an
    /// object key leaves its context here), with the ternary pairing the
    /// parser uses to read what follows as an expression.
    mutating func advanceColon(at index: Int) -> (Int, Bool) {
        var isTernary = false
        if let ternary = ternaryContextCounts.last, ternary == contexts.count {
            ternaryContextCounts.removeLast()
            isTernary = true
        }
        if currentContext.isFunction {
            popContext()
        }
        exprAllowed = true
        previous = .colon(isTernary: isTernary)
        return (index + 1, false)
    }

    /// acorn-jsx: `<` starts a tag where an expression may start. After an
    /// operand, `a<b` and `a < b` are both comparisons.
    mutating func advanceLessThan(
        _ next: unichar, in storage: NSString, at index: Int
    ) -> (Int, Bool) {
        if exprAllowed, next == 47 || next == 62 || isIdentStart(next) {
            jsxQuote = 0
            mode = .jsxTag(closing: next == 47)
            return (next == 47 ? index + 2 : index + 1, false)
        }
        return finishOperator(60, next: next, in: storage, at: index)
    }

    mutating func advanceJSXTag(
        _ unit: unichar, _ next: unichar, at index: Int, closing: Bool
    ) -> (Int, Bool) {
        if jsxQuote != 0 {
            if unit == 92 { return (index + 2, false) }
            if unit == jsxQuote { jsxQuote = 0 }
            return (index + 1, false)
        }
        switch unit {
        case 34, 39:
            jsxQuote = unit
            return (index + 1, false)
        case 123:
            openJSXHole(at: index, children: false)
            return (index + 1, false)
        case 47 where next == 62:
            return finishJSXTag(selfClosing: true, closing: false, end: index + 2)
        case 62:
            return finishJSXTag(selfClosing: false, closing: closing, end: index + 1)
        default:
            return (index + 1, false)
        }
    }

    mutating func advanceJSXChildren(
        _ unit: unichar, _ next: unichar, at index: Int
    ) -> (Int, Bool) {
        if unit == 60, next == 47 || next == 62 || isIdentStart(next) {
            jsxQuote = 0
            mode = .jsxTag(closing: next == 47)
            return (next == 47 ? index + 2 : index + 1, false)
        }
        if unit == 123 {
            openJSXHole(at: index, children: true)
            return (index + 1, false)
        }
        return (index + 1, false)
    }

    /// A JSX `{…}` hole is an expression container: the parser reads its
    /// content as an expression, and its own element count starts at zero.
    mutating func openJSXHole(at _: Int, children: Bool) {
        jsxResumes.append(
            JSXResume(depth: depth, children: children, jsxDepth: jsxDepth, contextCount: contexts.count)
        )
        contexts.append(.blockExpression)
        jsxDepth = 0
        depth += 1
        mode = .normal
        exprAllowed = true
        previous = .braceOpen
        followsLineBreak = false
    }

    /// A finished element is an operand. Nested tags return to the children.
    mutating func finishJSXTag(
        selfClosing: Bool, closing: Bool, end: Int
    ) -> (Int, Bool) {
        jsxQuote = 0
        if closing {
            jsxDepth = max(0, jsxDepth - 1)
        } else if !selfClosing {
            jsxDepth += 1
        }
        if jsxDepth == 0 {
            mode = .normal
            finishOperand()
            return (end, false)
        }
        mode = .jsxChildren
        return (end, false)
    }

    mutating func finishOperator(
        _ unit: unichar,
        next: unichar,
        in storage: NSString,
        at index: Int
    ) -> (Int, Bool) {
        let length = operatorLength(unit, next: next, in: storage, at: index)
        exprAllowed = true
        previous = unit == 61 && next == 62 && length == 2 ? .arrow : .other(beforeExpression: true)
        return (index + length, false)
    }
}
