import { useEffect, useState } from "react";

const FULL_TEXT = "um I think we should ship on friday you know";
const BAR_COUNT = 70;

function WaveformBars() {
  return (
    <>
      <style>{`
        @keyframes waveA { 0%,100%{height:5px} 50%{height:38px} }
        @keyframes waveB { 0%,100%{height:5px} 50%{height:26px} }
        @keyframes waveC { 0%,100%{height:5px} 50%{height:50px} }
        @keyframes waveD { 0%,100%{height:5px} 50%{height:32px} }
        @keyframes waveE { 0%,100%{height:5px} 50%{height:20px} }
      `}</style>
      <div style={{ display: "flex", alignItems: "center", gap: "3px", height: "60px", width: "100%" }}>
        {Array.from({ length: BAR_COUNT }, (_, i) => {
          const anims = ["waveA","waveB","waveC","waveD","waveE"];
          const anim = anims[i % 5];
          return (
            <div
              key={i}
              style={{
                width: "3px",
                backgroundColor: "#1A5C3A",
                borderRadius: "2px",
                animationName: anim,
                animationDuration: `${0.55 + (i % 5) * 0.1}s`,
                animationDelay: `${i * 0.045}s`,
                animationTimingFunction: "ease-in-out",
                animationIterationCount: "infinite",
                animationDirection: "alternate",
                height: "5px",
                flexShrink: 0,
              }}
            />
          );
        })}
      </div>
    </>
  );
}

function TypingText() {
  const [text, setText] = useState("");
  const [phase, setPhase] = useState<"typing" | "pause">("typing");

  useEffect(() => {
    if (phase === "typing") {
      if (text.length < FULL_TEXT.length) {
        const t = setTimeout(() => setText(FULL_TEXT.slice(0, text.length + 1)), 65);
        return () => clearTimeout(t);
      } else {
        const t = setTimeout(() => setPhase("pause"), 2200);
        return () => clearTimeout(t);
      }
    } else {
      const t = setTimeout(() => { setText(""); setPhase("typing"); }, 900);
      return () => clearTimeout(t);
    }
  }, [text, phase]);

  return (
    <span
      style={{
        fontFamily: "'IBM Plex Mono', monospace",
        fontSize: "0.85rem",
        color: "#D4D4D0",
        lineHeight: 1.7,
      }}
    >
      {text}
      <span
        style={{
          display: "inline-block",
          width: "2px",
          height: "1em",
          backgroundColor: "#1A5C3A",
          marginLeft: "2px",
          verticalAlign: "text-bottom",
          animation: "cursorBlink 1s step-end infinite",
        }}
      />
    </span>
  );
}

export function DictationEngine() {
  return (
    <section
      style={{
        backgroundColor: "#FAFAF7",
        paddingTop: "clamp(5rem, 10vw, 9rem)",
        paddingBottom: "clamp(5rem, 10vw, 9rem)",
        paddingLeft: "clamp(1rem, 5vw, 5rem)",
        paddingRight: "clamp(1rem, 5vw, 5rem)",
      }}
    >
      <style>{`
        @keyframes cursorBlink { 0%,100%{opacity:1} 50%{opacity:0} }
        @keyframes pulseRecord { 0%,100%{opacity:1;transform:scale(1)} 50%{opacity:0.4;transform:scale(0.88)} }
        
        .engine-container {
          max-width: 1100px;
          margin: 0 auto;
        }

        .engine-panel {
          display: grid;
          grid-template-columns: 1fr auto 1fr;
          gap: 0;
          align-items: center;
          min-height: 160px;
        }

        @media (max-width: 768px) {
          .engine-panel {
            grid-template-columns: 1fr;
            text-align: left;
            gap: 0;
          }
          .waveform-wrapper, .output-wrapper {
            display: flex;
            flex-direction: column;
            align-items: flex-start;
            padding-left: 1.5rem !important;
            padding-right: 1.5rem !important;
            padding-top: 2rem !important;
            padding-bottom: 2rem !important;
            overflow: hidden;
          }
          .waveform-wrapper {
            padding-bottom: 2.5rem !important;
          }
          .engine-bg-partition {
            width: 100% !important;
            height: 50% !important;
          }
        }
      `}</style>

      <div className="engine-container">
        {/* Section heading */}
        <h2
          style={{
            fontFamily: "'Instrument Serif', serif",
            fontSize: "clamp(2.5rem, 5vw, 4.5rem)",
            letterSpacing: "-0.03em",
            color: "#1A1A18",
            fontWeight: 400,
            lineHeight: 1.05,
            marginBottom: "clamp(2.5rem, 4vw, 3.5rem)",
          }}
        >
          The Dictation Engine.
        </h2>

        {/* Dark panel */}
        <div
          className="engine-panel"
          style={{
            backgroundColor: "#222220",
            borderRadius: "12px",
            boxShadow: "0 20px 60px rgba(0,0,0,0.22), 0 4px 16px rgba(0,0,0,0.12)",
            overflow: "hidden",
            position: "relative",
          }}
        >
          {/* Left Background Partition */}
          <div
            className="engine-bg-partition"
            style={{
              position: "absolute",
              top: 0,
              left: 0,
              bottom: 0,
              width: "50%",
              backgroundColor: "#0F0E0C",
              pointerEvents: "none",
              zIndex: 0,
            }}
          />

          {/* Left Content: Audio Stream */}
          <div 
            className="waveform-wrapper"
            style={{
              padding: "clamp(1.5rem, 3vw, 2.5rem)",
              position: "relative",
              zIndex: 1,
            }}
          >
            <div style={{ display: "flex", alignItems: "center", gap: "0.8rem", marginBottom: "1rem" }}>
              <p
                style={{
                  fontFamily: "'IBM Plex Mono', monospace",
                  fontSize: "0.6rem",
                  color: "#9B9890",
                  letterSpacing: "0.18em",
                  textTransform: "uppercase",
                  margin: 0,
                }}
              >
                Audio Stream
              </p>
              <div
                style={{
                  width: "8px",
                  height: "8px",
                  borderRadius: "50%",
                  backgroundColor: "#FF453A",
                  animationName: "pulseRecord",
                  animationDuration: "1.4s",
                  animationTimingFunction: "ease-in-out",
                  animationIterationCount: "infinite",
                  boxShadow: "0 0 8px rgba(255, 69, 58, 0.4)",
                }}
              />
              <span
                style={{
                  fontFamily: "'IBM Plex Mono', monospace",
                  fontSize: "0.55rem",
                  color: "#9B9890",
                  letterSpacing: "0.15em",
                  textTransform: "uppercase",
                  fontWeight: 600,
                  opacity: 0.8
                }}
              >
                Live
              </span>
            </div>
            <WaveformBars />
          </div>

          {/* Right Content: Raw text output */}
          <div
            className="output-wrapper"
            style={{
              padding: "clamp(1.5rem, 3vw, 2.5rem)",
              paddingLeft: "clamp(2.5rem, 6vw, 5rem)",
              position: "relative",
              zIndex: 1,
            }}
          >
            <p
              style={{
                fontFamily: "'IBM Plex Mono', monospace",
                fontSize: "0.6rem",
                color: "#9B9890",
                letterSpacing: "0.18em",
                textTransform: "uppercase",
                marginBottom: "1rem",
              }}
            >
              Raw Text Output
            </p>
            <div style={{ minHeight: "60px", display: "flex", alignItems: "center" }}>
              <TypingText />
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
