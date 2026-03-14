import { type ReactNode } from "react";

function SandboxIcon() {
  return (
    <svg width="42" height="42" viewBox="0 0 28 28" fill="none" aria-hidden="true">
      <rect x="4" y="8" width="20" height="16" rx="1.5" stroke="#1A5C3A" strokeWidth="1"/>
      <path d="M4 12H24" stroke="#1A5C3A" strokeWidth="1"/>
      <path d="M10 8V5C10 3.9 10.9 3 12 3H16C17.1 3 18 3.9 18 5V8" stroke="#1A5C3A" strokeWidth="1"/>
      <rect x="11" y="16" width="6" height="5" rx="1" stroke="#1A5C3A" strokeWidth="0.8"/>
    </svg>
  );
}

function NoNetworkIcon() {
  return (
    <svg width="42" height="42" viewBox="0 0 28 28" fill="none" aria-hidden="true">
      <path d="M4 10C7 7 11 5.5 14 5.5C17 5.5 21 7 24 10" stroke="#1A5C3A" strokeWidth="1" strokeLinecap="round"/>
      <path d="M7 14C9 12 11.5 11 14 11C16.5 11 19 12 21 14" stroke="#1A5C3A" strokeWidth="1" strokeLinecap="round"/>
      <path d="M10.5 17.5C11.5 16.5 12.8 16 14 16C15.2 16 16.5 16.5 17.5 17.5" stroke="#1A5C3A" strokeWidth="1" strokeLinecap="round"/>
      <circle cx="14" cy="21" r="1.5" fill="#1A5C3A"/>
      <line x1="5" y1="5" x2="23" y2="23" stroke="#1A5C3A" strokeWidth="1" strokeLinecap="round"/>
    </svg>
  );
}

function ErasureIcon() {
  return (
    <svg width="42" height="42" viewBox="0 0 28 28" fill="none" aria-hidden="true">
      <rect x="9" y="4" width="10" height="6" rx="1" stroke="#1A5C3A" strokeWidth="1"/>
      <path d="M7 10H21L20 22C20 23.1 19.1 24 18 24H10C8.9 24 8 23.1 8 22L7 10Z" stroke="#1A5C3A" strokeWidth="1"/>
      <line x1="5" y1="10" x2="23" y2="10" stroke="#1A5C3A" strokeWidth="1" strokeLinecap="round"/>
      <path d="M14 14L14 20M11 16L17 18" stroke="#1A5C3A" strokeWidth="0.8" strokeLinecap="round" opacity="0.5"/>
    </svg>
  );
}

interface PillarProps {
  icon: ReactNode;
  title: string;
  copy: string;
}

function Pillar({ icon, title, copy }: PillarProps) {
  return (
    <div style={{ display: "flex", flexDirection: "column", alignItems: "center", textAlign: "center" }}>
      <div style={{ marginBottom: "1.5rem" }}>{icon}</div>
      <h3
        style={{
          fontFamily: "'IBM Plex Mono', monospace",
          fontSize: "0.85rem",
          color: "#1A1A18",
          letterSpacing: "0.18em",
          textTransform: "uppercase",
          marginBottom: "1rem",
        }}
      >
        {title}
      </h3>
      <p
        style={{
          fontFamily: "'Plus Jakarta Sans', sans-serif",
          fontSize: "1.05rem",
          color: "#6B6860",
          lineHeight: 1.75,
          maxWidth: "22rem",
        }}
      >
        {copy}
      </p>
    </div>
  );
}

export function Privacy() {
  return (
    <section
      style={{
        backgroundColor: "#FAFAF7",
        paddingTop: "clamp(6rem, 12vw, 11rem)",
        paddingBottom: "clamp(3rem, 6vw, 4rem)",
        paddingLeft: "clamp(1.5rem, 8vw, 10rem)",
        paddingRight: "clamp(1.5rem, 8vw, 10rem)",
      }}
    >
      <h2
        style={{
          fontFamily: "'Instrument Serif', serif",
          fontSize: "clamp(2.8rem, 6vw, 4.8rem)",
          letterSpacing: "-0.03em",
          color: "#1A1A18",
          fontWeight: 400,
          lineHeight: 1.05,
          marginBottom: "clamp(4rem, 8vw, 6rem)",
          textAlign: "center",
          maxWidth: "70rem",
          margin: "0 auto clamp(4rem, 8vw, 6rem)",
        }}
      >
        What happens on your Mac, stays on your Mac.
      </h2>

      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(280px, 1fr))",
          gap: "clamp(3rem, 6vw, 5rem)",
          maxWidth: "1100px",
          margin: "0 auto",
        }}
      >
        <Pillar
          icon={<SandboxIcon />}
          title="Completely Isolated"
          copy="Kalam runs in a strictly contained environment. It operates entirely on-device, only accessing the specific hardware resources it absolutely needs to function."
        />
        <Pillar
          icon={<NoNetworkIcon />}
          title="Verifiably Offline"
          copy="We chose absolute privacy over auto-download convenience. Kalam is compiled entirely without network access capabilities, meaning it has zero ability to connect to the internet or phone home."
        />
        <Pillar
          icon={<ErasureIcon />}
          title="Leaves No Trace"
          copy="Your voice data exists only for the millisecond it takes to transcribe. Once converted to text, the audio is instantly wiped from memory. Nothing is ever saved to disk."
        />
      </div>
    </section>
  );
}