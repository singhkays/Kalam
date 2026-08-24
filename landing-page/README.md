# Kalam Landing Page 🖋️

The modern, editorial-style landing page for Kalam, built with React and Vite.

## Development Setup

1. **Install Dependencies**:
   ```bash
   npm install
   ```

2. **Start Dev Server**:
   ```bash
   npm run dev
   ```

3. **Build for Production**:
   ```bash
   npm run build
   ```

The build runs `vite build && node scripts/prerender.mjs`: Vite emits the JS/CSS
bundles, then the prerender step server-renders the full app into
`dist/index.html` and injects JSON-LD structured data. Search crawlers get
complete HTML without executing JavaScript. Verify the result with:

```bash
node scripts/verify-prerender.mjs
```

## Tech Stack

- **Framework**: React 18
- **Build Tool**: Vite (+ build-time prerendering for SEO)
- **Styling**: Vanilla CSS with modern HSL tokens
- **Icons**: Authentic monochrome SVGs from Simple Icons & SF Symbols