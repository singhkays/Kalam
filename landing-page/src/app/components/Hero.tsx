import { QuillSVG } from "./QuillSVG";

export function Hero() {
  return (
    <section
      style={{
        paddingTop: "clamp(0.75rem, 2vw, 2.5rem)",
        paddingBottom: "clamp(5rem, 10vw, 8rem)",
        paddingLeft: "clamp(1.5rem, 5vw, 5rem)",
        paddingRight: "clamp(1.5rem, 5vw, 5rem)",
        borderBottom: "1px solid #D4D4D0",
        overflow: "hidden", // Prevent horizontal scroll from the oversized quill
      }}
    >
      <style>{`
        .hero-content {
          display: grid;
          grid-template-columns: 1.15fr 0.85fr;
          gap: clamp(1.5rem, 4vw, 4rem);
          align-items: center;
          position: relative;
        }

        .quill-wrapper {
          display: flex;
          align-items: center;
          justify-content: flex-end;
          position: relative;
        }

        .hero-quill {
          height: auto;
          width: 140%; /* Very dominant sizing */
          max-width: 900px;
          opacity: 0.96;
          object-fit: contain;
          filter: contrast(1.05) brightness(0.98);
          transform: rotate(-6deg) translateX(8%);
          transform-origin: center right;
        }

        @media (max-width: 900px) {
          .hero-content {
            display: block;
          }
          .quill-wrapper {
            position: absolute;
            top: 6%;
            right: -2%;
            width: 48%;
            display: flex;
            justify-content: flex-end;
            align-items: flex-start;
            z-index: 1;
            pointer-events: none;
          }
          .hero-quill {
            width: 100%;
            max-width: 230px;
            transform: rotate(-10deg) translateY(-10%);
            opacity: 0.9;
          }
          .kicker-text {
             white-space: normal;
             line-height: 1.6 !important;
             max-width: 90%;
          }
        }
      `}</style>

      {/* Headline + Quill row */}
      <div className="hero-content">
        {/* Left: headline + subhead + CTAs */}
        <div style={{ minWidth: 0, position: "relative", zIndex: 2 }}>
          {/* Kicker */}
          <p
            className="kicker-text"
            style={{
              fontFamily: "'IBM Plex Mono', monospace",
              fontSize: "0.62rem",
              letterSpacing: "0.2em",
              color: "#6B6860",
              textTransform: "uppercase",
              marginBottom: "clamp(1.5rem, 3vw, 2.5rem)",
              lineHeight: 1,
            }}
          >
            Punjabi [&nbsp;ਕਲਮ&nbsp;] · /kə.ləm/ · A Traditional Writing Instrument
          </p>

          <h1
            style={{
              fontFamily: "'Instrument Serif', serif",
              fontSize: "clamp(3rem, 7vw, 7rem)",
              letterSpacing: "-0.03em",
              lineHeight: 1.0,
              color: "#1A1A18",
              margin: 0,
              fontWeight: 400,
            }}
          >
            <span style={{ display: "block" }}>Speak messy.</span>
            <span
              style={{
                display: "block",
                whiteSpace: "normal",
                lineHeight: 1.05,
                maxWidth: "min(26ch, 100%)",
                margin: "0 auto",
              }}
            >
              Type clean <span style={{ fontStyle: "italic", fontSize: "0.72em" }}>(privately)</span>.
            </span>
          </h1>

          <p
            style={{
              fontFamily: "'Plus Jakarta Sans', sans-serif",
              fontSize: "clamp(0.95rem, 1.5vw, 1.1rem)",
              color: "#6B6860",
              lineHeight: 1.65,
              marginTop: "clamp(1.5rem, 3vw, 2.5rem)",
              maxWidth: "36rem",
            }}
          >
            A dictation app that knows &lsquo;um&rsquo; isn&rsquo;t a word and
            &lsquo;scratch that&rsquo; is an instruction.
          </p>

          <div
            style={{
              display: "flex",
              gap: "0.75rem",
              marginTop: "clamp(1.5rem, 2.5vw, 2rem)",
              flexWrap: "wrap",
              alignItems: "flex-start",
            }}
          >
            <div
              style={{
                display: "flex",
                flexDirection: "column",
                gap: "0.4rem",
                alignItems: "center",
              }}
            >
              <a
                href="https://github.com/singhkays/Kalam/releases/tag/v1.0"
                target="_blank"
                rel="noreferrer noopener"
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
                  textDecoration: "none",
                  display: "inline-flex",
                  alignItems: "center",
                  justifyContent: "center",
                }}
              >
                Download for Mac
              </a>
              <a
                href="#installation"
                style={{
                  fontFamily: "'Plus Jakarta Sans', sans-serif",
                  fontSize: "0.8rem",
                  color: "#6B6860",
                  textDecoration: "underline",
                  textUnderlineOffset: "4px",
                  cursor: "pointer",
                }}
              >
                Installation instructions
              </a>
            </div>
            <a
              href="https://github.com/singhkays/Kalam"
              target="_blank"
              rel="noreferrer noopener"
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
                textDecoration: "none",
                display: "inline-flex",
                alignItems: "center",
                justifyContent: "center",
              }}
            >
              View on GitHub
            </a>
          </div>
        </div>

        {/* Right: Vector Quill Pen */}
        <div className="quill-wrapper">
          <img
            src={`${import.meta.env.BASE_URL}vector-quill.png`}
            alt="Vector Quill Pen"
            className="hero-quill"
          />
        </div>
      </div>
    </section>
  );
}