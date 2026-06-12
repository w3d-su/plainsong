// Builds the preview bundle into App/Resources/preview/ (agent.md §7.4).
// The output is COMMITTED so the app builds without Node installed.
import { build } from "esbuild";
import { copyFileSync, mkdirSync } from "node:fs";

const outDir = "../App/Resources/preview";
mkdirSync(outDir, { recursive: true });

await build({
  entryPoints: ["src/index.ts"],
  bundle: true,
  minify: true,
  format: "iife",
  globalName: "BlogEditorPreview",
  target: ["safari17"],
  outfile: `${outDir}/bundle.js`,
});

copyFileSync("src/index.html", `${outDir}/index.html`);
copyFileSync("src/styles/base.css", `${outDir}/bundle.css`);
console.log(`preview bundle written to ${outDir}/`);
