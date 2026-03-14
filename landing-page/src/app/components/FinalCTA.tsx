
export function FinalCTA() {
  return (
    <>
      {/* Final CTA block */}
      <section
        style={{
          backgroundColor: "#FAFAF7",
          paddingTop: "clamp(2rem, 5vw, 4rem)",
          paddingBottom: "clamp(5rem, 10vw, 9rem)",
          paddingLeft: "clamp(1.5rem, 5vw, 5rem)",
          paddingRight: "clamp(1.5rem, 5vw, 5rem)",
          textAlign: "center",
        }}
      >
        {/* Vector quill logo */}
        {/* Vector quill logo aligned with text */}
        <div
          style={{
            maxWidth: "48rem",
            margin: "0 auto",
            position: "relative",
            display: "flex",
            justifyContent: "flex-start",
            marginBottom: "-8.5rem", // Pull headline even closer
          }}
        >
          <img
            src="/vector-quill.png"
            alt="Vector Quill Pen"
            style={{
              height: "clamp(380px, 55vw, 850px)",
              width: "auto",
              objectFit: "contain",
              opacity: 1,
              filter: "brightness(0.98) contrast(1.02)",
              transform: "translateX(3.5%) translateY(4.5rem)", // Move right and down closer to text
              pointerEvents: "none",
            }}
          />
        </div>

        <h2
          style={{
            fontFamily: "'Instrument Serif', serif",
            fontSize: "clamp(2.5rem, 5vw, 4.5rem)",
            letterSpacing: "-0.03em",
            color: "#1A1A18",
            fontWeight: 400,
            lineHeight: 1.1,
            marginBottom: "1.25rem",
            maxWidth: "48rem",
            margin: "0 auto 1.25rem",
          }}
        >
          Your pen keeps your words between you and the page.
        </h2>

        <p
          style={{
            fontFamily: "'Instrument Serif', serif",
            fontStyle: "italic",
            fontSize: "clamp(1.8rem, 3.5vw, 3.2rem)",
            color: "#1A1A18",
            letterSpacing: "-0.02em",
            marginBottom: "1.5rem",
            lineHeight: 1.1,
          }}
        >
          So does Kalam.
        </p>

        <p
          style={{
            fontFamily: "'Plus Jakarta Sans', sans-serif",
            fontSize: "0.95rem",
            color: "#6B6860",
            marginBottom: "clamp(2rem, 3vw, 2.5rem)",
          }}
        >
          Free, open-source, and available now.
        </p>

        <div
          style={{
            display: "flex",
            gap: "0.75rem",
            justifyContent: "center",
            flexWrap: "wrap",
          }}
        >
          <button
            style={{
              backgroundColor: "#1A5C3A",
              color: "#fff",
              border: "none",
              borderRadius: "7px",
              padding: "0.75rem 1.5rem",
              fontFamily: "'Plus Jakarta Sans', sans-serif",
              fontSize: "0.9rem",
              cursor: "pointer",
              letterSpacing: "0.01em",
            }}
          >
            Download for Mac
          </button>
          <button
            style={{
              backgroundColor: "transparent",
              color: "#1A1A18",
              border: "1px solid #C8C8C4",
              borderRadius: "7px",
              padding: "0.75rem 1.5rem",
              fontFamily: "'Plus Jakarta Sans', sans-serif",
              fontSize: "0.9rem",
              cursor: "pointer",
              letterSpacing: "0.01em",
            }}
          >
            View Source
          </button>
        </div>
      </section>

      {/* Footer */}
      <footer
        style={{
          backgroundColor: "#FAFAF7",
          borderTop: "0.5px solid #D4D4D0",
          paddingTop: "1.75rem",
          paddingBottom: "1.75rem",
          paddingLeft: "clamp(1.5rem, 5vw, 5rem)",
          paddingRight: "clamp(1.5rem, 5vw, 5rem)",
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          flexWrap: "wrap",
          gap: "0.5rem",
        }}
      >
        <span
          style={{
            fontFamily: "'IBM Plex Mono', monospace",
            fontSize: "0.65rem",
            color: "#9B9890",
            letterSpacing: "0.08em",
          }}
        >
          © 2026 Kalam.
        </span>
        <span
          style={{
            fontFamily: "'IBM Plex Mono', monospace",
            fontSize: "0.65rem",
            color: "#9B9890",
            letterSpacing: "0.08em",
            textTransform: "uppercase",
          }}
        >
          Talk messy. Type clean.
        </span>
      </footer>
    </>
  );
}
