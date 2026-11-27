# Reuse KaTeX output in the preview

On 2026-11-28 we measured two costs for the 100 KB math fixture. A whole render converted six equations into 1,752 KaTeX trees. A settled edit reused Markdown segments but still sent 5.68 million characters of HTML through the inert parser and DOM patch. Measurements and reproduction commands are in `docs/perf/2026-11-28-math-preview.md`.

Each whole render or segment owns its formula table. The exact TeX text and display mode identify a successful fragment. `rehype-katex` uses the existing options, including MathML output and `trust: false`. Each occurrence keeps its own wrapper, source lines and math index. Errors stay expanded and keep the VFile diagnostic for that occurrence. Segments containing authored lowercase JSX use the original tree pipeline because an enclosing HTML element can change how KaTeX interprets a descendant.

The serializer emits a private span for a successful fragment. Markdown drops raw source HTML and the MDX sanitizer strips the slot attribute before this span is generated. The string-rendering API expands every slot. The bridge instead assigns slots across the assembled segments for that render. During the DOM patch it compares the complete serialized fragment with the last markup on the live wrapper. It clones changed markup from an inert template before reporting completion. A `WeakMap` releases the association with a removed wrapper and a normal children update clears it when the wrapper changes role.

A segment cache alone still reparses and visits every formula in the live document. A process-wide TeX cache would retain content across documents, and a hash-only DOM comparison could preserve stale output on a collision. The fragment tables follow the existing render and segment lifetimes.
