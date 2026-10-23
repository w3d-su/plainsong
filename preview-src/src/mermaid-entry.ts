// Entry point of the separately loaded `mermaid.js` (see `mermaid-loader.ts`).
// build.mjs emits it as an IIFE with `globalName: "PlainsongMermaid"`.
import mermaid from "mermaid";

export default mermaid;
