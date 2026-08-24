import { createRoot, hydrateRoot } from "react-dom/client";
import App from "./app/App.tsx";
import "./styles/index.css";

const rootEl = document.getElementById("root")!;

// Production builds are prerendered by scripts/prerender.mjs: the markup is
// already in index.html, so hydrate it (attaches handlers without repainting).
// Dev serves an empty #root, so mount fresh there.
if (rootEl.hasChildNodes()) {
  hydrateRoot(rootEl, <App />);
} else {
  createRoot(rootEl).render(<App />);
}
