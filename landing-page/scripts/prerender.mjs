/**
 * Build-time prerender: renders the React app to static HTML and bakes it
 * into dist/index.html, so search crawlers (and social scrapers) receive
 * fully-painted markup without executing JavaScript.
 *
 * Runs after `vite build`:   "build": "vite build && node scripts/prerender.mjs"
 */
import { createServer } from "vite";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = process.cwd();

// Reuse the project's own vite config (react plugin, aliases, base path)
// in middleware mode purely as an SSR module loader.
const vite = await createServer({
  root,
  logLevel: "error",
  clearScreen: false,
  server: { middlewareMode: true },
  appType: "custom",
});

try {
  const { render, jsonLd } = await vite.ssrLoadModule("/src/entry-server.tsx");

  const appHtml = render();
  if (!appHtml || appHtml.length < 1000) {
    throw new Error(
      `[prerender] rendered markup suspiciously small (${appHtml ? appHtml.length : 0} chars); refusing to write`,
    );
  }

  const ldScript = `<script type="application/ld+json">${JSON.stringify(jsonLd()).replace(/</g, "\\u003c")}</script>`;

  // Template = Vite's BUILT index.html (already references hashed
  // /kalam/assets/*.js bundles), never the source index.html whose dev-only
  // <script src="/src/main.tsx"> must not leak into the deploy artifact.
  const template = readFileSync(resolve(root, "dist/index.html"), "utf8");

  const ROOT_DIV = '<div id="root"></div>';
  if (!template.includes(ROOT_DIV)) {
    throw new Error(
      '[prerender] built index.html no longer contains the exact "<div id=\\"root\\"></div>" placeholder; update scripts/prerender.mjs',
    );
  }
  if (!template.includes("</head>")) {
    throw new Error('[prerender] built index.html has no </head>; update scripts/prerender.mjs');
  }
  if (!/\/kalam\/assets\/.+\.js/.test(template)) {
    throw new Error(
      "[prerender] built index.html does not reference hashed asset bundles; aborting",
    );
  }

  let html = template.replace(ROOT_DIV, `<div id="root">${appHtml}</div>`);
  html = html.replace("</head>", `  ${ldScript}\n  </head>`);

  writeFileSync(resolve(root, "dist/index.html"), html);
  console.log(
    `[prerender] dist/index.html written (${appHtml.length} chars of app markup, ${ldScript.length} chars of JSON-LD script)`,
  );
} finally {
  await vite.close();
}
