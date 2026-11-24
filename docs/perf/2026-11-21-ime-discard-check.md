# Marked-text discard check on a normal IME commit

- Date: 2026-11-21
- Commit: the commit that adds this file (parent `9e96d93`)
- Environment: macOS 26.6.2, Xcode 26.6, Apple M4 Pro (virtual machine), Debug (`swift test`)
- Fixture: generated in the test, 2,097,062 UTF-8 bytes (1,151,906 UTF-16 units) of mixed
  CJK and ASCII lines held in an `NSString`-backed `String`, with a two-unit Zhuyin marked
  range in the middle. No agent.md §12 budget names this check; it runs inside the 16 ms
  keystroke budget.
- Procedure: a temporary XCTest (not committed) called
  `MarkdownSTTextView.discardedReplacementLength` 10 times for a Return-key commit that
  turned the marked text into one character, next to the previous implementation
  (`replacingCharacters` plus a full `==` for each of "", "\n", "\r").
- Result: previous 61.3–68.9 ms per call, new 0.009–0.025 ms per call. Pass.

This measures the check alone, not end-to-end typing latency. The previous code built up
to three copies of the document and compared each one on every Return or Space that
ended a composition. A one-character commit has the same length as a stray newline, so a
length check alone does not skip the copies; the new code also compares the replaced
units first. A real discard still pays for one copy and one comparison.

Raw samples (ms):

- previous: 62.85, 66.67, 67.37, 63.24, 68.88, 61.76, 63.56, 64.71, 61.27, 66.36
- new: 0.018, 0.023, 0.016, 0.018, 0.011, 0.010, 0.024, 0.010, 0.009, 0.025
