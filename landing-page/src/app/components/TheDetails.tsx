import { type ReactNode } from "react";

function KeyboardShortcut() {
  return (
    <div style={{
      display: "flex",
      alignItems: "center",
      gap: "1.5rem",
      backgroundColor: "#fff",
      border: "1px solid #E5E5E1",
      borderRadius: "100px",
      padding: "1.25rem 2.5rem",
      boxShadow: "0 15px 40px rgba(0,0,0,0.06)",
      width: "fit-content"
    }}>
      <div style={{ display: "flex", gap: "0.5rem" }}>
        {["⌥", "Space"].map((key) => (
          <div key={key} style={{
            backgroundColor: "#F8F8F6",
            border: "1px solid #D4D4D0",
            borderRadius: "8px",
            padding: "0.6rem 1rem",
            fontFamily: "'IBM Plex Mono', monospace",
            fontSize: "0.9rem",
            color: "#1A1A18",
            boxShadow: "inset 0 -2px 0 #D4D4D0",
            minWidth: key === "Space" ? "80px" : "auto",
            textAlign: "center"
          }}>
            {key}
          </div>
        ))}
      </div>
      <div style={{ width: "1px", height: "24px", backgroundColor: "#E5E5E1" }} />
      <div style={{ display: "flex", alignItems: "center", gap: "0.8rem" }}>
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="#1A5C3A" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" /><path d="M19 10v2a7 7 0 0 1-14 0v-2" /><line x1="12" y1="19" x2="12" y2="22" />
        </svg>
        <span style={{ fontFamily: "'Plus Jakarta Sans', sans-serif", fontSize: "1.05rem", fontWeight: 500, color: "#1A5C3A" }}>Start Recording</span>
      </div>
    </div>
  );
}

function DictionaryVisual() {
  const pairs = [
    { spoken: '"swift ui"', output: "SwiftUI" },
    { spoken: '"gpt four oh"', output: "GPT-4o" },
    { spoken: '"l g t m"', output: "Looks good to me!" },
  ];
  return (
    <div style={{
      backgroundColor: "#fff",
      border: "1px solid #E5E5E1",
      borderRadius: "16px",
      padding: "2.5rem",
      boxShadow: "0 20px 50px rgba(0,0,0,0.04)",
      width: "100%",
      maxWidth: "480px"
    }}>
      <div style={{ display: "flex", justifyContent: "space-between", marginBottom: "1.5rem", borderBottom: "1px solid #F0F0EE", paddingBottom: "1rem" }}>
        <span style={{ fontFamily: "'IBM Plex Mono', monospace", fontSize: "0.65rem", textTransform: "uppercase", letterSpacing: "0.2em", color: "#9B9890" }}>Spoken</span>
        <span style={{ fontFamily: "'IBM Plex Mono', monospace", fontSize: "0.65rem", textTransform: "uppercase", letterSpacing: "0.2em", color: "#9B9890" }}>Output</span>
      </div>
      <div style={{ display: "flex", flexDirection: "column", gap: "1.5rem" }}>
        {pairs.map((p, i) => (
          <div key={i} style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline" }}>
            <span style={{ fontFamily: "'IBM Plex Mono', monospace", fontSize: "1rem", color: "#6B6860" }}>{p.spoken}</span>
            <span style={{ fontFamily: "'IBM Plex Mono', monospace", fontSize: "1rem", color: "#1A1A18", fontWeight: 600 }}>{p.output}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

function ChipVisualization() {
  return (
    <div style={{
      backgroundColor: "#fff",
      border: "1px solid #E5E5E1",
      borderRadius: "16px",
      padding: "2.5rem",
      boxShadow: "0 20px 50px rgba(0,0,0,0.04)",
      width: "100%",
      maxWidth: "480px"
    }}>
      <p style={{
        fontFamily: "'IBM Plex Mono', monospace",
        fontSize: "0.65rem",
        color: "#9B9890",
        letterSpacing: "0.2em",
        textTransform: "uppercase",
        marginBottom: "2rem"
      }}>Apple Silicon</p>

      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "1rem", marginBottom: "1rem" }}>
        {["CPU", "GPU"].map(id => (
          <div key={id} style={{
            backgroundColor: "#F8F8F6",
            border: "1px solid #D4D4D0",
            borderRadius: "8px",
            padding: "1.25rem",
            textAlign: "center",
            boxShadow: "inset 0 -2px 0 #D4D4D0"
          }}>
            <span style={{ fontFamily: "'IBM Plex Mono', monospace", fontSize: "0.85rem", color: "#1A1A18", letterSpacing: "0.15em", fontWeight: 500 }}>{id}</span>
          </div>
        ))}
      </div>

      <style>{`
        @keyframes neuralGlow {
          0%, 100% { box-shadow: 0 0 15px rgba(26,92,58,0.15); border-color: rgba(26,92,58,0.4); }
          50% { box-shadow: 0 0 25px rgba(26,92,58,0.5); border-color: rgba(26,92,58,0.8); }
        }
      `}</style>

      <div style={{
        borderRadius: "8px",
        padding: "1.5rem",
        textAlign: "center",
        border: "1px solid rgba(26,92,58,0.4)",
        backgroundColor: "rgba(26,92,58,0.05)",
        animation: "neuralGlow 3s ease-in-out infinite"
      }}>
        <span style={{
          fontFamily: "'IBM Plex Mono', monospace",
          fontSize: "0.9rem",
          color: "#1A5C3A",
          letterSpacing: "0.15em",
          fontWeight: 600
        }}>NEURAL ENGINE ✦</span>
      </div>
    </div>
  );
}

function MultilingualVisual() {
  const langs = ["English", "Español", "中文", "日本語", "Français", "Deutsch", "Português", "한국어", "العربية", "+16 more"];
  return (
    <div style={{ display: "flex", flexWrap: "wrap", gap: "1rem", maxWidth: "480px", justifyContent: "center" }}>
      {langs.map((lang, i) => (
        <div key={i} style={{
          backgroundColor: "#fff",
          border: "1px solid #E5E5E1",
          borderRadius: "100px",
          padding: "0.8rem 1.6rem",
          fontSize: "1rem",
          color: "#1A1A18",
          fontFamily: "'Plus Jakarta Sans', sans-serif",
          boxShadow: "0 6px 15px rgba(0,0,0,0.04)"
        }}>
          {lang}
        </div>
      ))}
    </div>
  );
}

interface DetailRowProps {
  index: string;
  category: string;
  title: string;
  body: string;
  visual: ReactNode;
  reversed?: boolean;
}

function DetailRow({ index, category, title, body, visual, reversed }: DetailRowProps) {
  return (
    <div style={{
      display: "grid",
      gridTemplateColumns: "repeat(auto-fit, minmax(320px, 1fr))",
      gap: "clamp(4rem, 12vw, 10rem)",
      alignItems: "center",
      marginBottom: "clamp(8rem, 18vw, 15rem)"
    }}>
      <div style={{ order: reversed ? 2 : 1 }}>
        <p style={{
          fontFamily: "'IBM Plex Mono', monospace",
          fontSize: "0.85rem",
          color: "#9B9890",
          letterSpacing: "0.25em",
          textTransform: "uppercase",
          marginBottom: "1.25rem"
        }}>
          {index} / {category}
        </p>
        <h3 style={{
          fontFamily: "'Instrument Serif', serif",
          fontSize: "clamp(2.8rem, 5vw, 4.8rem)",
          letterSpacing: "-0.03em",
          color: "#1A1A18",
          fontWeight: 400,
          lineHeight: 1.02,
          marginBottom: "1.75rem"
        }}>
          {title}
        </h3>
        <p style={{
          fontFamily: "'Plus Jakarta Sans', sans-serif",
          fontSize: "1.2rem",
          color: "#6B6860",
          lineHeight: 1.75,
          maxWidth: "36rem"
        }}>
          {body}
        </p>
      </div>
      <div style={{
        order: reversed ? 1 : 2,
        display: "flex",
        justifyContent: reversed ? "flex-start" : "flex-end"
      }}>
        {visual}
      </div>
    </div>
  );
}

export function TheDetails() {
  return (
    <section style={{
      backgroundColor: "#FAFAF7",
      paddingTop: "clamp(8rem, 15vw, 15rem)",
      paddingBottom: "clamp(4rem, 10vw, 8rem)",
      paddingLeft: "clamp(1.5rem, 8vw, 12rem)",
      paddingRight: "clamp(1.5rem, 8vw, 12rem)"
    }}>
      <div style={{ maxWidth: "1280px", margin: "0 auto" }}>
        <DetailRow
          index="01"
          category="Global Shortcuts"
          title="Always ready, at your cursor."
          body="Configure a global hotkey to start dictating instantly, no matter what app you're in. Optimized for speed, designed for workflows that never stop."
          visual={<KeyboardShortcut />}
        />
        <DetailRow
          index="02"
          category="Custom Dictionary"
          title="Personal Dictionary."
          body="User-definable word replacements and AI post-processing formatting. Handles industry-specific terms, brands, and smart text expansion automatically."
          visual={<DictionaryVisual />}
          reversed
        />
        <DetailRow
          index="03"
          category="On-Device AI"
          title="On-Device AI."
          body="Powered by latest Automatic Speech Recognition (ASR) models running on the Apple Neural Engine. Zero latency, zero cloud dependency, absolute privacy."
          visual={<ChipVisualization />}
        />
        <DetailRow
          index="04"
          category="Multilingual"
          title="25+ languages."
          body="Speak in your native language or switch between them naturally. All processing happens locally with no data ever leaving your machine."
          visual={<MultilingualVisual />}
          reversed
        />
      </div>
    </section>
  );
}