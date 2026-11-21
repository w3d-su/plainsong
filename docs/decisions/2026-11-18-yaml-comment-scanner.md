# Preserve frontmatter comments with the scanner bundled in Yams

Yams exposes scalar text and node start marks. Its public nodes omit comments and
token end positions. The inspector needs both ends of each token to distinguish a
comment from a literal hash in a quoted string, plain scalar, or block scalar.
MarkdownCore uses Yams for values and limits access to the bundled CYaml scanner
to `FrontmatterComments.swift`. The manifest pins Yams 6.2.2 because CYaml is an
internal target. Updating the pin requires building MarkdownCore and running
`DocumentIntegrityTests` with the new version.

A second YAML parser would increase the dependency footprint and could interpret
the source differently. A handwritten comment lexer would duplicate the quoted
and block scalar grammar. The scanner already used to load the document supplies
the token boundaries for the same grammar.
