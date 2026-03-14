# Prompt: Editorial Broadsheet — "The Art Book" Layout

Please build the landing page for Kalam, a free, open-source macOS dictation engine. I want you to act as an expert UI/UX designer and implement the "Editorial Broadsheet" design direction, specifically focusing on a highly asymmetrical, editorial hero layout. 

I am giving you strict constraints. I want YOU to figure out the exact CSS implementation and layout rhythm, using the exact copy provided.

### Brand Context
- **Headline concept:** "Talk messy. Type clean."
- **Core product value:** Edits out fillers, formats lists, and cleans up text before it hits the page.

### The Layout Rule: "The Art Book" Hero
Implement a highly asymmetrical layout resembling a high-end photography book or museum poster, breaking away from standard centered conventions.
1. **The Headline:** Push the entire hero headline flush left, taking up 60-70% of the screen width. Use this massive, elegant, stacked two-line layout exactly as follows (rely on standard casing and italics for the word "clean"):
   `Talk messy.`
   `Type *clean*.`
2. **The Content Constraint:** Tuck the subhead and the two CTA buttons neatly into the bottom left beneath the headline. 
3. **The Quill (The Visual Anchor):** Position an elegantly proportioned, high-resolution SVG rendering of the Kalam "Quill/Pen" logo in close proximity to the right of the hero headline. Critically, ensure its stroke weight is severely thin (`1px` or `1.5px`) to perfectly harmonize with the delicate hairlines and typography stems used throughout the page. Size it beautifully to complement the text, forming a tight, cohesive lockup on wide desktop screens without overpowering the copy.
   - **Mobile/Narrow Screen Constraint:** Do not hide the quill on smaller screens. Stack it elegantly just above or immediately to the right of the hero headline so it is highly visible.

### Color, Typography, & Layout System (Strict)
- **Breathing Room (Crucial):** Apply generous vertical spacing/padding (e.g., `8rem` to `12rem`) between all major sections so the layout breathes and never feels cramped as the user scrolls.
- **Background Motif (The Title Page Effect):** To create maximum impact, treat the Hero section like the cover of a document and the rest of the page like its contents:
  - **Grid Background:** Exclusively use a faint, precise square graph-paper grid for the Hero section. The grid lines must have extremely low opacity—so subtle they are barely noticeable at a glance. Crucially, do not let these grid lines form tight vertical \"boxes\" around elements like the Top Nav or the Kicker; allow those elements to float freely in the negative space above the expansive grid.
  - **Solid Warm Off-White (`#FAFAF7`):** Every other section below the Hero must use a pure, solid warm off-white background.
  - **Section Dividers (Hairlines):** To prevent the off-white sections from feeling like one giant sheet of paper, separate them with a single, ultra-thin (`0.5px` to `1px`) horizontal **hairline** in `#D4D4D0`. This mimics the crisp ruling found in high-end broadsheets.
  - **Depth Metric:** Apply a very delicate `1px` border separating the bottom of the Hero section from the rest of the page to ground the transition.
- **Demo Panel Background:** `#0F0E0C` (for the dark inset terminal UI panels). Use elegant, soft drop shadows on these panels to give them depth and a premium, slightly elevated look above the page.
- **Text:** Primary `#1A1A18`. Secondary `#6B6860`. Emphasize the word "*clean*" in the hero using strong serif italics while keeping the color consistent with the rest of the headline (`#1A1A18`).
- **Buttons:** Subtly rounded (6-8px radius) in deep, flat forest green (`#1A5C3A`) with white text.
- **Headlines:** `Instrument Serif`. Apply a slight negative letter-spacing (e.g., `-0.02em` to `-0.04em`) to massive display serifs to create a tight, highly cohesive, customized editorial \"lockup\" out of the typography.
- **Section Headings:** Major section headings (like the one above the demo) must be massive: `clamp(2.5rem, 5vw, 4.5rem)` with tight tracking. Maintain massive scale; avoid treating these as standard secondary subheads.
- **Body:** `Plus Jakarta Sans`. **Monospace:** `IBM Plex Mono` (or JetBrains).
- **Demo Panel Text:** All raw input and clean output text in the terminal panels should be a consistent, sophisticated light grey (`#D4D4D0`) so the UI feels unified.
- **Cleanup Motif (Faded Ink):** In the "Messy Input" panels, identify discarded words using the **"Faded Ink"** motif: Reduce the opacity of the removed words significantly (down to `0.2` or `0.25` opacity, making them look like the ghost of a mistake) and overlay them with a true, delicate hairline (`0.5px`) horizontal strike-through in a muted graphite grey. Ensure *only* the specific removed words/filler patterns carry this mark, leaving the surrounding text untouched. This simulates a highly refined, red-pen editorial correction rather than a heavy, jarring error.

### Content Constraints (Use Exact Copy Where Provided)

**0. The Header (Sleek & Low-Profile)**
- **Layout:** A static top header that disappears as the user scrolls. Use minimal vertical height.
- **Design:** Use an elegant split layout. Place the "Kalam" wordmark flush left (aligned with the main text column).
- **Right App Metadata:** The right side features extremely subtle **Technical Metadata**.
  - **Content:** Display the current version and publishing date (e.g., `v1.0.0 / MAR 2026`).
  - **Design:** Use a tiny, monospaced font (`IBM Plex Mono`). The color is a very faint grey (e.g., `#D4D4D0`) to ensure it remains secondary to the primary "Kalam" wordmark.
- **Visuals:** Keep it crisp and flat on the grid paper background.

**1. Hero**
- **The Kicker (Etymology):** Above the main massive headline, in the negative space of the grid, place the origins as a small, widely-tracked, uppercase mono-spaced or sans-serif "kicker" that simply reads: `PUNJABI [ ਕਲਮ ] · /kə.ləm/ · A TRADITIONAL REED PEN`
- Headline: "Talk messy. Type *clean*."
- Subhead: "A dictation app that knows 'um' isn't a word and 'scratch that' is an instruction." (Must be clean and modern. Strictly use the `Plus Jakarta Sans` body font).
- CTAs: "Download for Mac" and "View on GitHub"

**2. The Dictation Engine (Audio Integration)**
- **Headline:** "The Dictation Engine."
- **Visual/Animation:** Create a sleek, dark inset UI panel (`#0F0E0C`) that visually demonstrates audio being converted into text. 
  - Be highly prescriptive: Left side should show `AUDIO STREAM` with an animating green waveform. Middle should have a pulsing record indicator. Right side should show `RAW TEXT OUTPUT` with a monospaced gray text string effectively typing out the actual words being spoken (e.g., `um I think we should ship on friday you know`).

**3. Expanded Cleanup Demo**
- **Headline:** "See it clean up." (Styled consistently with "The Dictation Engine" heading).
- Use a dark inset UI panel (`#0F0E0C`) to match the engine above.
- **Technical Constraint (Height Stability):** The container for the "clean output" terminal must have a fixed minimum height so the section does not jump around vertically as the output text length changes between examples.
- Build an interactive or multi-layered demo that cycles through these EXACT four Strings:
  1. `"um I think we should ship on friday you know"` → `"I think we should ship on Friday"`
  2. `"send it now scratch that send it tomorrow"` → `"send it tomorrow"`
  3. `"plan is one gather logs two fix bug three ship"` → `"Plan is <br /> 1. gather logs <br /> 2. fix bug <br /> 3. ship"` *(Format this as a vertical block list)*
  4. `"that will be five dollars and fifty cents please"` → `"That will be $5.50 please"`
- Identify the "before" state using the **Faded Ink** motif established in the system constraints. Ensure *only* the removed words carry the strikethrough.

**4. Works Everywhere**
- **Layout Constraint:** This specific section should be perfectly center-aligned to break up the asymmetrical rhythm.
- Headline: "Works Everywhere." (Make this font size huge). 
- Subcopy: "Speak naturally and watch your words appear perfectly in any text field—emails, documents, code, chat. No more backspacing or typos."
- Visual: Place the app logos (Slack, Notion, Xcode, Terminal, etc.) in a neat horizontal row directly below the subcopy.

**5. The Speed Advantage (Data Visualization)**
- **Layout Constraint:** Center this entire section. 
- Headline: "Writing at the speed of sound."
- Subhead: *"Watch your thoughts hit the page as fast as you can speak them. Speaking is ~4x faster than typing, keeping you in flow while your hands do something else."*
- Visual: Implement a stark, editorial horizontal bar chart center-aligned underneath the copy, comparing **Typing (40 wpm)** (dark grey) vs **Speaking (160 wpm)** (bold accent color). (Do NOT include redundant text-heavy side-by-side comparison boxes).

**6. The Details (Minimalist UI Displays)**
- Build a crisp, typographic layout that mimics high-end editorial indexing:
  - **Typography Structure:** Above each section Title, include a small, muted, mono-spaced or tracked-out label denoting the index and category (e.g., `01 / GLOBAL SHORTCUTS`). Below this, place the large, elegant Serif section heading (e.g., "Always one type away.").
  - **Global Shortcuts (UI Mockup):** Present a clean UI element representing hotkey configuration (e.g., pill-shaped keys showing `Configure Key` -> `Start Recording`). Apply a soft, elegant drop shadow to this element to give it depth and a premium feel.
  - **Custom Dictionary (Personal Dictionary):** User-definable word replacements and AI post-processing formatting. Explain that it handles industry-specific terms, brands (`SwiftUI`, `GPT-4o`), and smart text expansion. 
  - **On-Device AI & Multilingual:** Powered by Apple Silicon and a Neural Engine, supporting 25+ languages entirely on-device.
  - **Visual Detail:** Implement the black chip design with a green animated version of the "Neural Engine" block, indicating that's where the audio is processed. Use a stark, premium black card background with dark, subtle borders for the chip components ("CPU", "GPU", "Neural Engine"), and have the "Neural Engine" block pulse or illuminate in Kalam's accent green.

**7. Frequently Asked Questions**
- Simple, elegant accordion interface sitting just above the dark inversion section (use crisp horizontal lines separating questions, expanding smoothly on click).
- Questions to include: "Is any of my data shared? Does it leave my laptop?", "Can I use it for free?", "Does it work with my apps?", "Which languages does it support?".

**8. Privacy**
- Maintain the primary light aesthetic.
- Copy: Headline should be "What happens on your Mac, stays on your Mac."
- List the three privacy pillars side-by-side. To enhance scannability, place a minimalist, editorial line-art icon (e.g., in accent green or dark grey) directly above each title:
  - **1. Icon:** A geometric outlined box or subtle shield. **Title:** SANDBOXED. **Copy:** OS-enforced at the kernel level. Kalam operates within a strict sandbox, ensuring it only has access to what it absolutely needs.
  - **2. Icon:** An elegant slashed Wi-Fi symbol or crossed-out cloud. **Title:** NO NETWORK PERMISSION. **Copy:** The app physically cannot phone home. It is compiled without network entitlements, making data exfiltration impossible.
  - **3. Icon:** A padlock or a fragmented data symbol. **Title:** CRYPTOGRAPHIC ERASURE. **Copy:** Audio buffers are securely wiped from memory the millisecond transcription is complete. Nothing is saved to disk.

**9. Final CTA & Footer**
- Maintain the primary light aesthetic (solid warm off-white `#FAFAF7`).
- Create a massive, generously-padded, center-aligned final CTA block featuring this exact copy and layout:
  - *Visual Detail: Include a large Outline/Path drawing of the Quill leaf logo above this text.*
  - **Main Heading:** `Your pen keeps your words between you and the page.` (Huge Serif).
  - **Sub Heading:** `So does Kalam.` (Make this text elegant and slightly smaller, or simply italicize it using the primary text color to ensure it feels like an emphatic continuation).
  - **Body:** `Free, open-source, and available now.`
  - *(Include "Download for Mac" and "View Source" buttons side-by-side here)*
- **The Footer:** This section flows seamlessly into a minimalist footer at the very bottom.
- **Footer Layout:** Split the content into a two-column layout:
  - **Left side:** `© 2026 Kalam.`
  - **Right side:** `Talk messy. Type clean.`

**Anti-Patterns (DO NOT USE):**
- Centered text in the hero.
- Pill-shaped or fully square buttons.
- 4-column feature grids.

Embrace the stark, asymmetrical editorial aesthetic and write the code.
