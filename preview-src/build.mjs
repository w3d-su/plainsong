// Builds the preview bundle into App/Resources/preview/ (agent.md §7.4).
// The output is COMMITTED so the app builds without Node installed.
import { build } from "esbuild";
import { cpSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const outDir = "../App/Resources/preview";
mkdirSync(outDir, { recursive: true });

const css = [
  readFileSync("src/styles/base.css", "utf8"),
  woff2OnlyFontSources(readFileSync("node_modules/katex/dist/katex.min.css", "utf8")),
].join("\n\n");

const common = {
  bundle: true,
  minify: true,
  format: "iife",
  target: ["safari17"],
  // micromark-extension-mdxjs imports acorn's ESM build while acorn-jsx requires its
  // CommonJS build; without this both copies (~120 KB) land in the bundle.
  alias: { acorn: resolve("node_modules/acorn/dist/acorn.mjs") },
};

await build({
  ...common,
  entryPoints: ["src/index.ts"],
  // WebKit file origins deny CSSOM access to the linked bundle.css. Make the
  // exact same build input available to static export without runtime fetching.
  define: { __PLAINSONG_BUNDLED_CSS__: JSON.stringify(css) },
  globalName: "PlainsongPreview",
  outfile: `${outDir}/bundle.js`,
});
// Loaded on the first diagram by src/mermaid-loader.ts.
await build({
  ...common,
  entryPoints: ["src/mermaid-entry.ts"],
  globalName: "PlainsongMermaid",
  outfile: `${outDir}/mermaid.js`,
});
for (const name of ["bundle.js", "mermaid.js"]) {
  const path = `${outDir}/${name}`;
  writeFileSync(path, readFileSync(path, "utf8").replace(/[ \t]+$/gm, ""));
}

writeFileSync(`${outDir}/index.html`, readFileSync("src/index.html", "utf8"));
writeFileSync(`${outDir}/bundle.css`, css);
rmSync(`${outDir}/fonts`, { recursive: true, force: true });
mkdirSync(`${outDir}/fonts`);
const fontFiles = readdirSync("node_modules/katex/dist/fonts")
  .filter((name) => name.endsWith(".woff2"))
  .sort();
for (const name of fontFiles) {
  cpSync(`node_modules/katex/dist/fonts/${name}`, `${outDir}/fonts/${name}`);
}
writeFileSync(
  `${outDir}/font-manifest.json`,
  `${JSON.stringify({ format: "woff2", files: fontFiles }, null, 2)}\n`,
);
console.log(`preview bundle written to ${outDir}/`);

/** WebKit always picks the woff2 source and static export embeds only woff2, so the
 * woff and ttf fallbacks KaTeX lists are never loaded. Drop them from the CSS (and the
 * files from the bundle); fail the build if KaTeX's CSS stops matching this shape. */
function woff2OnlyFontSources(katexCSS) {
  const stripped = katexCSS.replace(
    /,url\(fonts\/KaTeX_[A-Za-z0-9-]+\.(?:woff|ttf)\) format\("(?:woff|truetype)"\)/g,
    "",
  );
  if (/\.(?:woff|ttf)\)/.test(stripped)) {
    throw new Error("katex.min.css still references woff/ttf fonts after stripping");
  }
  return stripped;
}
