import { useEffect, useState } from "react";

interface WordPart {
  text: string;
  faded: boolean;
}

interface Example {
  id: number;
  label: string;
  before: WordPart[];
  afterLines: string[];
}

const examples: Example[] = [
  {
    id: 0,
    label: "Filler Removal",
    before: [
      { text: "um ", faded: true },
      { text: "I think we should ship on friday ", faded: false },
      { text: "you know", faded: true },
    ],
    afterLines: ["I think we should ship on Friday"],
  },
  {
    id: 1,
    label: '"Scratch That" Command',
    before: [
      { text: "send it now ", faded: true },
      { text: "scratch that ", faded: true },
      { text: "send it tomorrow", faded: false },
    ],
    afterLines: ["send it tomorrow"],
  },
  {
    id: 2,
    label: "Smart List Formatting",
    before: [
      { text: "plan is ", faded: false },
      { text: "one ", faded: true },
      { text: "gather logs ", faded: false },
      { text: "two ", faded: true },
      { text: "fix bug ", faded: false },
      { text: "three ", faded: true },
      { text: "ship", faded: false },
    ],
    afterLines: ["Plan is", "1. gather logs", "2. fix bug", "3. ship"],
  },
  {
    id: 3,
    label: "Number Formatting",
    before: [
      { text: "that will be ", faded: false },
      { text: "five dollars and fifty cents", faded: true },
      { text: " please", faded: false },
    ],
    afterLines: ["That will be $5.50 please"],
  },
];

function FadedWord({ part }: { part: WordPart }) {
  if (!part.faded) {
    return (
      <span
        style={{
          fontFamily: "'IBM Plex Mono', monospace",
          fontSize: "0.88rem",
          color: "#D4D4D0",
        }}
      >
        {part.text}
      </span>
    );
  }
  return (
    <span
      style={{
        fontFamily: "'IBM Plex Mono', monospace",
        fontSize: "0.88rem",
        color: "#D4D4D0",
        opacity: 0.22,
        position: "relative",
        display: "inline",
      }}
    >
      <span
        style={{
          textDecoration: "line-through",
          textDecorationColor: "rgba(180,180,175,0.6)",
          textDecorationThickness: "0.5px",
        }}
      >
        {part.text}
      </span>
    </span>
  );
}

export function CleanupDemo() {
  const [active, setActive] = useState(0);

  useEffect(() => {
    const t = setInterval(() => {
      setActive((prev) => (prev + 1) % examples.length);
    }, 4000);
    return () => clearInterval(t);
  }, []);

  const ex = examples[active];

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
        @keyframes fadeInEx { from{opacity:0;transform:translateY(6px)} to{opacity:1;transform:translateY(0)} }
        
        .cleanup-container {
          max-width: 1100px;
          margin: 0 auto;
        }

        .cleanup-tabs {
          display: flex;
          gap: 0.5rem;
          margin-bottom: 1.25rem;
          flex-wrap: wrap;
        }

        .cleanup-panel {
          display: grid;
          grid-template-columns: 1fr 1fr;
          gap: 0;
          align-items: start;
        }

        @media (max-width: 768px) {
          .cleanup-panel {
            grid-template-columns: 1fr;
            text-align: left;
            gap: 0;
          }
          .before-wrapper, .after-wrapper {
            padding-left: 1.5rem !important;
            padding-right: 1.5rem !important;
            min-height: auto !important;
            padding-top: 2rem !important;
            padding-bottom: 2rem !important;
          }
          .before-wrapper {
            padding-bottom: 2.5rem !important;
          }
          .arrow-divider {
            transform: rotate(90deg);
            padding: 0 !important;
            display: flex;
            justify-content: center;
            position: absolute;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%) rotate(90deg);
            z-index: 10;
          }
          .cleanup-bg-partition {
            width: 100% !important;
            height: 50% !important;
          }
        }
      `}</style>

      <div className="cleanup-container">
        <h2
          style={{
            fontFamily: "'Instrument Serif', serif",
            fontSize: "clamp(2.5rem, 5vw, 4.5rem)",
            letterSpacing: "-0.03em",
            color: "#1A1A18",
            fontWeight: 400,
            lineHeight: 1.05,
            marginBottom: "clamp(2.5rem, 4vw, 3.5rem)",
            maxWidth: "28rem",
          }}
        >
          The Cleanup Crew.
        </h2>

        {/* Tabs */}
        <div className="cleanup-tabs">
          {examples.map((e, i) => (
            <button
              key={e.id}
              onClick={() => setActive(i)}
              style={{
                fontFamily: "'IBM Plex Mono', monospace",
                fontSize: "0.62rem",
                letterSpacing: "0.12em",
                textTransform: "uppercase",
                padding: "0.4rem 0.85rem",
                borderRadius: "5px",
                border: "1px solid",
                borderColor: active === i ? "#1A5C3A" : "#D4D4D0",
                backgroundColor: active === i ? "#1A5C3A" : "transparent",
                color: active === i ? "#fff" : "#6B6860",
                cursor: "pointer",
                transition: "all 0.2s ease",
              }}
            >
              {e.label}
            </button>
          ))}
        </div>

        {/* Dark panel */}
        <div
          className="cleanup-panel"
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
            className="cleanup-bg-partition"
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

          {/* Before */}
          <div
            key={`before-${active}`}
            className="before-wrapper"
            style={{
              animationName: "fadeInEx",
              animationDuration: "0.35s",
              animationFillMode: "both",
              padding: "clamp(1.5rem, 3vw, 2.5rem)",
              minHeight: "220px",
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
                marginBottom: "1.25rem",
              }}
            >
              Messy Input
            </p>
            <div
              style={{
                minHeight: "80px",
                lineHeight: 1.8,
              }}
            >
              {ex.before.map((part, i) => (
                <FadedWord key={i} part={part} />
              ))}
            </div>
          </div>

          {/* After */}
          <div
            key={`after-${active}`}
            className="after-wrapper"
            style={{
              animationName: "fadeInEx",
              animationDuration: "0.35s",
              animationDelay: "0.08s",
              animationFillMode: "both",
              padding: "clamp(1.5rem, 3vw, 2.5rem)",
              paddingLeft: "clamp(2.5rem, 6vw, 5rem)",
              minHeight: "220px",
              position: "relative",
              zIndex: 1,
            }}
          >
            <p
              style={{
                fontFamily: "'IBM Plex Mono', monospace",
                fontSize: "0.6rem",
                color: "#2A7A50",
                letterSpacing: "0.18em",
                textTransform: "uppercase",
                marginBottom: "1.25rem",
                fontWeight: 600,
              }}
            >
              Clean Output
            </p>
            <div style={{ minHeight: "80px" }}>
              {ex.afterLines.map((line, i) => (
                <p
                  key={i}
                  style={{
                    fontFamily: "'IBM Plex Mono', monospace",
                    fontSize: "0.88rem",
                    color: "#D4D4D0",
                    lineHeight: 1.8,
                    margin: 0,
                  }}
                >
                  {line}
                </p>
              ))}
            </div>
          </div>
        </div>
      </div>

      {/* Dot indicators */}
      <div style={{ display: "flex", justifyContent: "center", gap: "0.5rem", marginTop: "1.25rem" }}>
        {examples.map((_, i) => (
          <button
            key={i}
            onClick={() => setActive(i)}
            style={{
              width: "8px",
              height: "8px",
              borderRadius: "50%",
              border: "none",
              backgroundColor: active === i ? "#1A1A18" : "#D4D4D0",
              padding: 0,
              cursor: "pointer",
              transition: "background-color 0.3s ease",
            }}
          />
        ))}
      </div>
    </section>
  );
}
