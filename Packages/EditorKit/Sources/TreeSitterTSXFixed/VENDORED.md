Vendored from tree-sitter/tree-sitter-typescript v0.23.2.

Source: https://github.com/tree-sitter/tree-sitter-typescript
Tag: v0.23.2
Commit: f975a621f4e7f532fe322e13c4f79495e0a7b2e7

Only the TSX grammar C sources, support headers, public C header, and MIT
license are included here. The upstream Swift package is not used because it
depends on ChimeHQ/SwiftTreeSitter, while EditorKit pins the official
tree-sitter/swift-tree-sitter package exactly.

Local layout adjustment: `src/scanner.c` includes `../common/scanner.h`
instead of upstream's `../../common/scanner.h` because this target vendors only
the TSX grammar subtree plus the shared scanner header.
