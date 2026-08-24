/**
 * Verifies dist/index.html is crawler-ready after a build:
 *   - substantial server-rendered text content
 *   - key marketing phrases baked into the HTML
 *   - valid JSON-LD (@graph with WebSite/WebPage/SoftwareApplication/FAQPage)
 *   - canonical URL + social card tags
 * Exits non-zero on any failure. Run after `npm run build`.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const html = readFileSync(resolve(process.cwd(), "dist/index.html"), "utf8");
let failed = false;
const check = (name, ok, detail = "") => {
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failed = true;
};

// 1. Substantial visible content
const bodyText = html
  .replace(/<script[\s\S]*?<\/script>/g, " ")
  .replace(/<style[\s\S]*?<\/style>/g, " ")
  .replace(/<[^>]+>/g, " ");
const words = bodyText.split(/\s+/).filter(Boolean).length;
check("server-rendered word count >= 300", words >= 300, `${words} words`);

// 2. Key phrases from the page must exist in raw HTML
for (const phrase of [
  "Speak messy",
  "dictation app",
  "Frequently asked",
  "Download for MacOS",
  "View on GitHub",
  "Is any of my data shared",
]) {
  const hit = html.toLowerCase().includes(phrase.toLowerCase());
  check(`phrase in raw HTML: "${phrase}"`, hit);
}

// 3. JSON-LD validity
check("exactly one JSON-LD block", (html.match(/application\/ld\+json/g) || []).length === 1);
const ldMatch = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
if (!ldMatch) {
  check("JSON-LD present", false);
} else {
  try {
    const ld = JSON.parse(ldMatch[1]);
    const types = (ld["@graph"] || []).map((n) => n["@type"]);
    for (const t of ["WebSite", "WebPage", "SoftwareApplication", "FAQPage"]) {
      check(`JSON-LD @graph contains ${t}`, types.includes(t));
    }
    const faqNode = (ld["@graph"] || []).find((n) => n["@type"] === "FAQPage");
    const qCount = faqNode?.mainEntity?.length ?? 0;
    check("FAQPage has all questions", qCount >= 4, `${qCount} questions`);
    check('@context is https://schema.org', ld["@context"] === "https://schema.org");
    // No raw '<' inside the script (would break parsing)
    check("JSON-LD has no unescaped '<'", !ldMatch[1].includes("<"));
  } catch (e) {
    check("JSON-LD parses", false, String(e));
  }
}

// 4. Head essentials
for (const [name, needle] of [
  ["canonical", 'rel="canonical" href="https://singhkays.com/kalam/"'],
  ["og:image", 'property="og:image"'],
  ["twitter:card", 'name="twitter:card" content="summary_large_image"'],
  ["meta description", 'name="description"'],
  ["theme-color", 'name="theme-color"'],
  ["favicon", 'rel="icon"'],
]) {
  check(`${name} tag`, html.includes(needle));
}

// 5. Bundle wiring — the artifact must load hashed production assets,
//    never the dev-only entry (regression guard for the prerender step)
check(
  "no dev-only /src/main.tsx script reference",
  !html.includes('/src/main.tsx'),
);
check(
  "references hashed production JS bundle",
  /\/kalam\/assets\/index-[\w-]+\.js/.test(html),
);

console.log(failed ? "\nRESULT: FAIL" : "\nRESULT: ALL CHECKS PASSED");
process.exit(failed ? 1 : 0);
