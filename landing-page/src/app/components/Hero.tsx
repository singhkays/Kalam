import { CtaButtonLabel } from "./CtaButtonLabel";

export function Hero() {
  return (
    <section
      className="hero-section"
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
        .hero-section {
          display: flex;
          flex: 1;
          align-items: center;
        }

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

        .hero-copy {
          min-width: 0;
          position: relative;
          z-index: 2;
        }

        .hero-body {
          max-width: 36rem;
        }

        .hero-cta-group {
          display: flex;
          gap: 0.75rem;
          margin-top: clamp(1.5rem, 2.5vw, 2rem);
          flex-wrap: wrap;
          align-items: flex-start;
        }

        .hero-primary-group {
          display: flex;
          flex-direction: column;
          gap: 0.4rem;
          align-items: center;
        }

        .hero-button-mobile-label {
          display: none;
        }

        @media (max-width: 900px) {
          .hero-section {
            align-items: stretch;
            padding-top: clamp(0.75rem, 4vw, 1.25rem);
            padding-bottom: clamp(1.5rem, 6vw, 2.25rem);
          }

          .hero-content {
            display: flex;
            flex-direction: column;
            justify-content: flex-start;
            gap: clamp(0.75rem, 3vw, 1.1rem);
            min-height: 100%;
            flex: 1;
          }

          .hero-copy {
            display: flex;
            flex-direction: column;
            min-height: 100%;
            padding-top: clamp(0.25rem, 2vw, 0.75rem);
          }

          .hero-body {
            max-width: none;
            padding-right: 0;
          }

          .quill-wrapper {
            position: relative;
            top: auto;
            right: auto;
            width: 100%;
            display: flex;
            justify-content: center;
            align-items: center;
            z-index: 1;
            pointer-events: none;
            order: -1;
            margin-bottom: -0.2rem;
          }

          .hero-quill {
            width: min(42vw, 11rem);
            max-width: none;
            transform: rotate(-8deg);
            opacity: 0.86;
          }

          .kicker-text {
            white-space: normal;
            line-height: 1.6 !important;
            max-width: 17rem;
            margin-bottom: 1.15rem !important;
          }

          .hero-headline {
            font-size: clamp(3.25rem, 16vw, 5rem) !important;
          }

          .hero-subcopy {
            font-size: 0.95rem !important;
            line-height: 1.6 !important;
            margin-top: 1rem !important;
            max-width: 19rem !important;
          }

          .hero-cta-group {
            margin-top: clamp(1rem, 4vw, 1.5rem);
            padding-top: clamp(0.35rem, 2vw, 0.75rem);
            flex-direction: column;
            align-items: center;
            width: min(100%, 18rem);
            gap: 0.7rem;
            margin-left: auto;
            margin-right: auto;
          }

          .hero-primary-group {
            align-items: center;
            width: 100%;
          }

          .hero-button {
            width: 100%;
            min-height: 3.5rem;
            font-size: 0.98rem !important;
            justify-content: center !important;
          }

          .hero-secondary {
            order: 2;
          }

          .hero-install-link {
            display: none !important;
          }

          .hero-button-desktop-label {
            display: none;
          }

          .hero-button-mobile-label {
            display: inline;
          }
        }
      `}</style>

      {/* Headline + Quill row */}
      <div className="hero-content">
        {/* Left: headline + subhead + CTAs */}
        <div className="hero-copy">
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
            className="hero-headline"
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
            className="hero-subcopy"
            style={{
              fontFamily: "'Plus Jakarta Sans', sans-serif",
              fontSize: "clamp(0.95rem, 1.5vw, 1.1rem)",
              color: "#6B6860",
              lineHeight: 1.65,
              marginTop: "clamp(1.5rem, 3vw, 2.5rem)",
              maxWidth: "36rem"
            }}
          >
            A dictation app that knows &lsquo;um&rsquo; isn&rsquo;t a word and
            &lsquo;scratch that&rsquo; is an instruction.
          </p>

          <div className="hero-cta-group">
            <div className="hero-primary-group">
              <a
                href="https://github.com/singhkays/Kalam/releases/tag/v1.0"
                target="_blank"
                rel="noreferrer noopener"
                className="hero-button"
                style={{
                  backgroundColor: "#1A5C3A",
                  color: "#fff",
                  border: "1px solid #154C30",
                  borderRadius: "6px",
                  padding: "0.78rem 1.45rem",
                  fontFamily: "'Plus Jakarta Sans', sans-serif",
                  fontSize: "0.9rem",
                  fontWeight: 500,
                  cursor: "pointer",
                  letterSpacing: "0.01em",
                  lineHeight: 1,
                  minHeight: "3.45rem",
                  textDecoration: "none",
                  display: "inline-flex",
                  alignItems: "center",
                  justifyContent: "center",
                  boxShadow: "0 1px 0 rgba(255,255,255,0.12) inset",
                }}
              >
                <span className="hero-button-desktop-label">
                  <CtaButtonLabel icon="apple" iconColor="#F7F5EF">
                    Download for MacOS
                  </CtaButtonLabel>
                </span>
                <span className="hero-button-mobile-label">
                  <CtaButtonLabel icon="apple" iconColor="#F7F5EF">
                    Available for MacOS
                  </CtaButtonLabel>
                </span>
              </a>
              <a
                href="#installation"
                className="hero-install-link"
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
              className="hero-button hero-secondary"
              style={{
                backgroundColor: "#F1F1ED",
                color: "#1A1A18",
                border: "1px solid #D4D4D0",
                borderRadius: "6px",
                padding: "0.78rem 1.45rem",
                fontFamily: "'Plus Jakarta Sans', sans-serif",
                fontSize: "0.9rem",
                fontWeight: 500,
                cursor: "pointer",
                letterSpacing: "0.01em",
                lineHeight: 1,
                minHeight: "3.45rem",
                textDecoration: "none",
                display: "inline-flex",
                alignItems: "center",
                justifyContent: "center",
                boxShadow: "0 1px 0 rgba(255,255,255,0.62) inset",
              }}
            >
              <CtaButtonLabel icon="github" iconColor="#1A1A18">
                View on GitHub
              </CtaButtonLabel>
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
