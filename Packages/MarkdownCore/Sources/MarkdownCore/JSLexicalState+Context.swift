import Foundation

/// acorn's token-context rules (`tokencontext.js`, acorn 8) and the parser
/// overrides that correct them at expression atoms.
extension JSLexicalState {
    var currentContext: Context {
        contexts.last ?? .blockStatement
    }

    /// acorn `braceIsBlock`, plus the parser's `overrideContext(b_expr)` for a
    /// `{` it parses as an expression atom: the first token of the expression,
    /// after a ternary `:`, and inside `for (…;…;…)` heads.
    func braceIsBlock() -> Bool {
        switch previous {
        case .start:
            return false
        case .colon(isTernary: true):
            return false
        case .semicolon where currentContext == .parenStatement:
            return false
        default:
            break
        }
        let parent = currentContext
        if parent.isFunction { return true }
        if case .colon = previous, parent == .blockStatement || parent == .blockExpression {
            return !parent.isExpression
        }
        if previous == .keyword("return") || (previous == .name && exprAllowed) {
            return followsLineBreak
        }
        switch previous {
        case .keyword("else"), .semicolon, .parenClose, .arrow:
            return true
        case .braceOpen:
            return parent == .blockStatement
        case .keyword("var"), .keyword("const"), .name:
            return false
        default:
            return !exprAllowed
        }
    }

    /// acorn `_function` / `_class` `updateContext`: `f_expr` only after a
    /// `beforeExpr` token outside statement positions. The colon and `{`
    /// exclusions apply to ternary colons too — acorn's heuristic, kept so the
    /// following `/` classifies exactly as the preview's parser reads it.
    mutating func openFunctionContext() {
        var isColonOrBrace = previous == .braceOpen
        if case .colon = previous { isColonOrBrace = true }
        let isExpression = previous.beforeExpression
            && previous != .keyword("else")
            && !(previous == .semicolon && currentContext != .parenStatement)
            && !(previous == .keyword("return") && followsLineBreak)
            && !(isColonOrBrace && currentContext == .blockStatement)
        contexts.append(.function(isExpression: isExpression, isGenerator: false))
        exprAllowed = false
    }

    /// Applies acorn's delayed `overrideContext(f_expr)` once the token after
    /// `function` has updated the context stack.
    mutating func applyAsyncOverrideIfDue(afterFunctionKeyword: Bool) {
        switch asyncOverride {
        case .none:
            return
        case .awaitingFunction:
            asyncOverride = afterFunctionKeyword ? .awaitingNextToken : .none
        case .awaitingNextToken:
            if !contexts.isEmpty {
                contexts[contexts.count - 1] = .function(isExpression: true, isGenerator: false)
            }
            asyncOverride = .none
        }
    }

    /// acorn `parenR` / `braceR` `updateContext`: a statement body closing a
    /// function also closes the function context.
    mutating func closeContext() {
        guard contexts.count > 1 else {
            exprAllowed = true
            return
        }
        var closed = popContext()
        if closed == .blockStatement, currentContext.isFunction {
            closed = popContext()
        }
        exprAllowed = !(closed?.isExpression ?? false)
    }

    @discardableResult
    mutating func popContext() -> Context? {
        let closed = contexts.popLast()
        forgetTernaries()
        return closed
    }

    /// Restores the context stack to `count` when a template or JSX
    /// `{…}` hole closes.
    mutating func truncateContexts(to count: Int) {
        if contexts.count > count {
            contexts.removeLast(contexts.count - count)
        }
        forgetTernaries()
    }

    mutating func forgetTernaries() {
        while let last = ternaryContextCounts.last, last > contexts.count {
            ternaryContextCounts.removeLast()
        }
        while let last = statementBlockContextCounts.last, last >= contexts.count {
            statementBlockContextCounts.removeLast()
        }
    }

    /// acorn `inGeneratorContext`: the innermost function context is a generator.
    var inGeneratorContext: Bool {
        for context in contexts.dropFirst().reversed() {
            if case let .function(_, isGenerator) = context { return isGenerator }
        }
        return false
    }

    /// Where the parser starts a statement, so `async function` there is a
    /// declaration. Everywhere else acorn overrides it to a function
    /// expression (`parseExprAtom` → `overrideContext(f_expr)`).
    var isStatementStart: Bool {
        // `parseAwait` is still reading its operand. A line break or a comment
        // does not end that expression, so `await⏎async function` is the
        // operand, not a declaration.
        if awaitOperand { return false }
        if followsLineBreak, !previous.beforeExpression || previous == .keyword("return") {
            // ASI: the previous statement ends at the line break.
            return previous != .start
        }
        if followsLineBreak, previous == .name, exprAllowed {
            return true // `yield⏎`
        }
        switch previous {
        case .semicolon:
            return currentContext != .parenStatement
        case .braceOpen:
            return currentContext == .blockStatement
        case .braceClose, .parenClose:
            // Closing a statement block or an `if (…)` head allows a regex next.
            return exprAllowed
        case .keyword("else"), .keyword("do"):
            return true
        case .colon(isTernary: false):
            return currentContext == .blockStatement
        default:
            return false
        }
    }
}
