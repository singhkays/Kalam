
import { CtaButtonLabel } from "./CtaButtonLabel";

export function FinalCTA() {
  return (
    <>
      {/* Final CTA block */}
      <section
        className="final-cta"
        style={{
          backgroundColor: "#FAFAF7",
          paddingTop: "clamp(2rem, 5vw, 4rem)",
          paddingBottom: "clamp(5rem, 10vw, 9rem)",
          paddingLeft: "clamp(1.5rem, 5vw, 5rem)",
          paddingRight: "clamp(1.5rem, 5vw, 5rem)",
          textAlign: "center",
        }}
      >
        <style>{`
          .final-cta-art {
            max-width: 48rem;
            margin: 0 auto;
            position: relative;
            display: flex;
            justify-content: flex-start;
            margin-bottom: -8.5rem;
          }

          .final-cta-quill {
            height: clamp(380px, 55vw, 850px);
            width: auto;
            object-fit: contain;
            opacity: 1;
            filter: brightness(0.98) contrast(1.02);
            transform: translateX(3.5%) translateY(4.5rem);
            pointer-events: none;
          }

          .final-cta-title {
            font-family: 'Instrument Serif', serif;
            font-size: clamp(2.5rem, 5vw, 4.5rem);
            letter-spacing: -0.03em;
            color: #1A1A18;
            font-weight: 400;
            line-height: 1.1;
            max-width: 48rem;
            margin: 0 auto 1.25rem;
          }

          .final-cta-actions {
            display: flex;
            gap: 0.75rem;
            justify-content: center;
            flex-wrap: wrap;
          }

          .final-cta-button {
            padding: 0.78rem 1.45rem;
            font-family: 'Plus Jakarta Sans', sans-serif;
            font-size: 0.9rem;
            font-weight: 500;
            cursor: pointer;
            letter-spacing: 0.01em;
            text-decoration: none;
            display: inline-flex;
            align-items: center;
            justify-content: center;
            border-radius: 6px;
          }

          .final-cta-mobile-label {
            display: none;
          }

          .final-cta-footer {
            background-color: #FAFAF7;
            border-top: 0.5px solid #D4D4D0;
            padding-top: 1.75rem;
            padding-bottom: 1.75rem;
            padding-left: clamp(1.5rem, 5vw, 5rem);
            padding-right: clamp(1.5rem, 5vw, 5rem);
            display: flex;
            justify-content: space-between;
            align-items: center;
            flex-wrap: wrap;
            gap: 0.5rem;
          }

          @media (max-width: 900px) {
            .final-cta {
              padding-top: 2.5rem !important;
              padding-bottom: 4.5rem !important;
            }

            .final-cta-art {
              justify-content: center;
              margin-bottom: 1rem;
            }

            .final-cta-quill {
              height: min(37vw, 12rem);
              transform: rotate(-8deg) translateY(0);
              opacity: 0.9;
            }

            .final-cta-title {
              font-size: clamp(2.5rem, 11vw, 3.8rem);
              line-height: 0.98;
              max-width: 13ch;
              margin-bottom: 1.5rem;
            }

            .final-cta-actions {
              display: flex;
              flex-direction: column;
              align-items: center;
              gap: 0.85rem;
              max-width: 18rem;
              margin: 0 auto;
            }

            .final-cta-button {
              min-height: 4rem;
              width: 100%;
              font-size: 0.95rem;
            }

            .final-cta-desktop-label {
              display: none;
            }

            .final-cta-mobile-label {
              display: inline;
            }

            .final-cta-footer {
              flex-direction: column;
              align-items: center;
              justify-content: center;
              text-align: center;
              gap: 0.85rem;
            }
          }
        `}</style>

        {/* Vector quill logo */}
        <div className="final-cta-art">
          <img
            src={`${import.meta.env.BASE_URL}vector-quill.png`}
            alt="Vector Quill Pen"
            className="final-cta-quill"
          />
        </div>

        <h2 className="final-cta-title">
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

        <div className="final-cta-actions">
          <a
            href="https://github.com/singhkays/Kalam/releases/tag/v1.0"
            target="_blank"
            rel="noreferrer noopener"
            className="final-cta-button"
            style={{
              backgroundColor: "#1A5C3A",
              color: "#fff",
              border: "1px solid #154C30",
              boxShadow: "0 1px 0 rgba(255,255,255,0.12) inset",
            }}
          >
            <span className="final-cta-desktop-label">
              <CtaButtonLabel icon="apple" iconColor="#F7F5EF">
                Download for MacOS
              </CtaButtonLabel>
            </span>
            <span className="final-cta-mobile-label">
              <CtaButtonLabel icon="apple" iconColor="#F7F5EF">
                Available for MacOS
              </CtaButtonLabel>
            </span>
          </a>
          <a
            href="https://github.com/singhkays/Kalam"
            target="_blank"
            rel="noreferrer noopener"
            className="final-cta-button"
            style={{
              backgroundColor: "#F1F1ED",
              color: "#1A1A18",
              border: "1px solid #D4D4D0",
              boxShadow: "0 1px 0 rgba(255,255,255,0.62) inset",
            }}
          >
            <CtaButtonLabel icon="github" iconColor="#1A1A18">
              View Source
            </CtaButtonLabel>
          </a>
        </div>
      </section>

      {/* Footer */}
      <footer className="final-cta-footer">
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
