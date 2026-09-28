import Foundation

/// JavaScript lexical state for `{…}` expression bodies: strings, escapes,
/// line/block comments, template literals with nested `${…}`, regex literals,
/// and JSX.
///
/// Whether `/` starts a regex and whether `{` opens a block or an object
/// mirrors acorn's tokenizer context algorithm (`tokencontext.js`: the context
/// stack, `braceIsBlock`, and each token type's `updateContext`) plus the
/// parser overrides acorn applies after the tokenizer: `{` → object,
/// `async function` → expression, `parseAwait`'s operand re-reads `/` as a
/// regexp, and `for await (` is a statement head. The preview parses MDX
/// expressions with acorn, so following acorn — including its heuristics —
/// is what keeps the expression's extent here identical to the preview's.
struct JSLexicalState {
    enum Mode: Equatable {
        case normal
        case singleQuoted
        case doubleQuoted
        case template
        case lineComment
        case blockComment
        case regexp(inClass: Bool, escaped: Bool)
        /// Inside `<Tag …>` or `</Tag>`. `closing` is the `</` form.
        case jsxTag(closing: Bool)
        /// Text and nested tags between an opening tag and its close.
        case jsxChildren
    }

    /// acorn's `TokContext`.
    enum Context: Equatable {
        case blockStatement
        case blockExpression
        case templateExpression
        case parenStatement
        case parenExpression
        case function(isExpression: Bool, isGenerator: Bool)

        var isExpression: Bool {
            switch self {
            case .blockExpression, .parenExpression: true
            case let .function(isExpression, _): isExpression
            case .blockStatement, .templateExpression, .parenStatement: false
            }
        }

        var isFunction: Bool {
            if case .function = self { return true }
            return false
        }
    }

    enum AsyncOverride: Equatable {
        case none
        case awaitingFunction
        case awaitingNextToken
    }

    /// acorn token types of the previous token, reduced to what the context
    /// rules compare against.
    enum Token: Equatable {
        /// acorn's `eof`: nothing read yet in this expression.
        case start
        case name
        case keyword(String)
        case dot
        /// `?.` before a name: the name is a member, like the name after `.`.
        case questionDot
        case colon(isTernary: Bool)
        case semicolon
        case braceOpen
        case braceClose
        case parenOpen
        case parenClose
        case arrow
        case star
        /// Any other token; `beforeExpression` is acorn's `beforeExpr` flag.
        case other(beforeExpression: Bool)

        var beforeExpression: Bool {
            switch self {
            case .start, .name, .dot, .questionDot, .braceClose, .parenClose:
                false
            case .colon, .semicolon, .braceOpen, .parenOpen, .arrow, .star:
                true
            case let .keyword(word):
                JSLexicalState.beforeExpressionKeywords.contains(word)
            case let .other(beforeExpression):
                beforeExpression
            }
        }
    }

    /// Brace depth; the expression starts at 1 for its opening `{`.
    var depth = 1
    var mode: Mode = .normal
    /// acorn's context stack. `parseExpressionAt` starts from `[b_stat]`.
    var contexts: [Context] = [.blockStatement]
    /// acorn's `exprAllowed`: `/` starts a regex and `<` starts JSX.
    var exprAllowed = true
    var previous: Token = .start
    /// A line break (or a comment containing one) lies between the previous
    /// token and the next — acorn's `lineBreak.test(input.slice(lastTokEnd, start))`.
    var followsLineBreak = false
    /// An `async function` the parser reads as an expression atom. acorn calls
    /// `overrideContext(f_expr)` only after reading the token that follows
    /// `function`, so the override replaces whatever context that token left
    /// on top — the function's own for a name or `*`, but the parameter
    /// paren's for `async function (`.
    var asyncOverride = AsyncOverride.none
    /// The previous token is the statement keyword `for` (not a member name).
    /// Trivia may follow; `await` then begins `for await`.
    var forAwaitReady = false
    /// `for await` has been read and its `(` is still ahead. That paren is a
    /// statement head even though the token before it is `await`, not `for`.
    var forAwaitHead = false
    /// `parseAwait` is about to read a unary operand. The name token left
    /// `exprAllowed` false, but `parseExprAtom` re-reads a `/` in that
    /// position as a regexp.
    var awaitOperand = false
    /// `contexts.count` below each `{` acorn tokenizes as an object but the
    /// parser reads as a block statement. The parser re-reads a following `/`
    /// as a regex (`parseExprAtom` → `readRegexp`), so closing one allows it.
    var statementBlockContextCounts: [Int] = []
    /// `contexts.count` at each unmatched `?`. A `:` at the same count is the
    /// ternary's; the parser then expects an expression atom after it.
    var ternaryContextCounts: [Int] = []
    /// Depths (and context counts to restore) at which `}` returns to a template.
    var templateResumes: [(depth: Int, contextCount: Int)] = []
    /// Open JSX elements of the JSX tree being scanned right now. An embedded
    /// `{…}` expression starts its own count at zero.
    var jsxDepth = 0
    /// Attribute quote while scanning a JSX tag. Zero means not inside one.
    var jsxQuote: unichar = 0
    /// Where a JSX `{…}` hole returns once its `}` closes.
    struct JSXResume {
        /// Brace depth at which `}` returns to JSX instead of closing the MDX expression.
        let depth: Int
        /// Returns to element children rather than to the tag's attributes.
        let children: Bool
        /// The enclosing JSX tree's open-element count.
        let jsxDepth: Int
        let contextCount: Int
    }

    var jsxResumes: [JSXResume] = []

    static let keywords: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger", "default",
        "delete", "do", "else", "export", "extends", "false", "finally", "for", "function",
        "if", "import", "in", "instanceof", "new", "null", "return", "super", "switch",
        "this", "throw", "true", "try", "typeof", "var", "void", "while", "with",
    ]
    static let beforeExpressionKeywords: Set<String> = [
        "case", "default", "delete", "do", "else", "extends", "in", "instanceof",
        "new", "return", "throw", "typeof", "void",
    ]

    /// Line comments end at the line boundary.
    mutating func endOfLine() {
        // A regex literal cannot contain a line break. Dropping the attempt
        // here does not reopen braces already consumed inside it.
        if case .regexp = mode {
            mode = .normal
            finishOperand()
        }
        // A break inside a string or template literal is not between tokens.
        if mode == .normal || mode == .lineComment || mode == .blockComment {
            followsLineBreak = true
        }
        if mode == .lineComment { mode = .normal }
    }

    /// Consume one UTF-16 unit at `index`; returns the next index and whether
    /// the outermost expression finished.
    mutating func advance(in storage: NSString, at index: Int) -> (next: Int, finished: Bool) {
        let unit = storage.character(at: index)
        let next = index + 1 < storage.length ? storage.character(at: index + 1) : 0
        switch mode {
        case .normal:
            return advanceNormal(unit, next, in: storage, at: index)
        case .singleQuoted, .doubleQuoted:
            let quote: unichar = mode == .singleQuoted ? 39 : 34
            if unit == 92 { return (index + 2, false) }
            if unit == quote {
                mode = .normal
                finishOperand()
            }
            return (index + 1, false)
        case .template:
            if unit == 92 { return (index + 2, false) }
            if unit == 96 {
                mode = .normal
                finishOperand()
                return (index + 1, false)
            }
            if unit == 36, next == 123 {
                templateResumes.append((depth, contexts.count))
                contexts.append(.templateExpression)
                depth += 1
                mode = .normal
                exprAllowed = true
                previous = .other(beforeExpression: true)
                return (index + 2, false)
            }
            return (index + 1, false)
        case .lineComment:
            if let length = lineTerminatorLength(unit, next) {
                endOfLine()
                return (index + length, false)
            }
            return (index + 1, false)
        case .blockComment:
            if unit == 42, next == 47 {
                mode = .normal
                return (index + 2, false)
            }
            if let length = lineTerminatorLength(unit, next) {
                endOfLine()
                return (index + length, false)
            }
            return (index + 1, false)
        case let .regexp(inClass, escaped):
            if let length = lineTerminatorLength(unit, next) {
                endOfLine()
                return (index + length, false)
            }
            return advanceRegexp(unit, in: storage, at: index, inClass: inClass, escaped: escaped)
        case let .jsxTag(closing):
            return advanceJSXTag(unit, next, at: index, closing: closing)
        case .jsxChildren:
            return advanceJSXChildren(unit, next, at: index)
        }
    }

    /// A string, template, regex, number, or JSX element: acorn tokens with
    /// no `beforeExpr` and no context update.
    mutating func finishOperand() {
        exprAllowed = false
        previous = .other(beforeExpression: false)
        followsLineBreak = false
        awaitOperand = false
        forAwaitReady = false
        forAwaitHead = false
    }

    mutating func advanceRegexp(
        _ unit: unichar,
        in storage: NSString,
        at index: Int,
        inClass: Bool,
        escaped: Bool
    ) -> (Int, Bool) {
        if escaped {
            mode = .regexp(inClass: inClass, escaped: false)
            return (index + 1, false)
        }
        if unit == 92 {
            mode = .regexp(inClass: inClass, escaped: true)
            return (index + 1, false)
        }
        if unit == 91 {
            mode = .regexp(inClass: true, escaped: false)
            return (index + 1, false)
        }
        if unit == 93, inClass {
            mode = .regexp(inClass: false, escaped: false)
            return (index + 1, false)
        }
        if unit == 47, !inClass {
            mode = .normal
            finishOperand()
            var next = index + 1
            while next < storage.length {
                let flag = storage.character(at: next)
                let isLetter = (flag >= 65 && flag <= 90) || (flag >= 97 && flag <= 122)
                guard isLetter else { break }
                next += 1
            }
            return (next, false)
        }
        mode = .regexp(inClass: inClass, escaped: false)
        return (index + 1, false)
    }
}
