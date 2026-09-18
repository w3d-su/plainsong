// Builds the preview bundle into App/Resources/preview/ (agent.md §7.4).
// The output is COMMITTED so the app builds without Node installed.
import { build } from "esbuild";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";

const outDir = "../App/Resources/preview";
mkdirSync(outDir, { recursive: true });

const css = [
  readFileSync("src/styles/base.css", "utf8"),
  readFileSync("node_modules/katex/dist/katex.min.css", "utf8"),
  readFileSync("node_modules/highlight.js/styles/github.css", "utf8"),
].join("\n\n");

await build({
  entryPoints: ["src/index.ts"],
  // WebKit file origins deny CSSOM access to the linked bundle.css. Make the
  // exact same build input available to static export without runtime fetching.
  define: { __PLAINSONG_BUNDLED_CSS__: JSON.stringify(css) },
  bundle: true,
  minify: true,
  format: "iife",
  globalName: "PlainsongPreview",
  target: ["safari17"],
  outfile: `${outDir}/bundle.js`,
});
writeFileSync(
  `${outDir}/bundle.js`,
  readFileSync(`${outDir}/bundle.js`, "utf8").replace(/[ \t]+$/gm, ""),
);

writeFileSync(`${outDir}/index.html`, readFileSync("src/index.html", "utf8"));
writeFileSync(`${outDir}/bundle.css`, css);
rmSync(`${outDir}/fonts`, { recursive: true, force: true });
cpSync("node_modules/katex/dist/fonts", `${outDir}/fonts`, { recursive: true });
console.log(`preview bundle written to ${outDir}/`);
