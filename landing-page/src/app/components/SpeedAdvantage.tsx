export function SpeedAdvantage() {
  const maxWPM = 160;
  const typingWPM = 40;
  const speakingWPM = 160;

  return (
    <section
      style={{
        backgroundColor: "#FAFAF7",
        paddingTop: "clamp(5rem, 10vw, 9rem)",
        paddingBottom: "clamp(5rem, 10vw, 9rem)",
        paddingLeft: "clamp(1.5rem, 5vw, 5rem)",
        paddingRight: "clamp(1.5rem, 5vw, 5rem)",
        textAlign: "center",
      }}
    >
      <h2
        style={{
          fontFamily: "'Instrument Serif', serif",
          fontSize: "clamp(2.5rem, 5vw, 4.5rem)",
          letterSpacing: "-0.03em",
          color: "#1A1A18",
          fontWeight: 400,
          lineHeight: 1.05,
          marginBottom: "clamp(1rem, 2vw, 1.5rem)",
        }}
      >
        Writing at the speed of sound.
      </h2>

      <p
        style={{
          fontFamily: "'Plus Jakarta Sans', sans-serif",
          fontStyle: "italic",
          fontSize: "clamp(1.05rem, 1.5vw, 1.15rem)",
          color: "#6B6860",
          lineHeight: 1.7,
          maxWidth: "38rem",
          margin: "0 auto",
          marginBottom: "clamp(3rem, 5vw, 4.5rem)",
        }}
      >
        Watch your thoughts hit the page as fast as you can speak them.
        Speaking is ~4x faster than typing, keeping you in flow while your
        hands do something else.
      </p>

      {/* Bar chart */}
      <div
        style={{
          maxWidth: "520px",
          margin: "0 auto",
          display: "flex",
          flexDirection: "column",
          gap: "1.75rem",
        }}
      >
        {/* Typing bar */}
        <div>
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "baseline",
              marginBottom: "0.5rem",
            }}
          >
            <span
              style={{
                fontFamily: "'IBM Plex Mono', monospace",
                fontSize: "0.8rem",
                letterSpacing: "0.14em",
                textTransform: "uppercase",
                color: "#6B6860",
              }}
            >
              Typing
            </span>
            <span
              style={{
                fontFamily: "'IBM Plex Mono', monospace",
                fontSize: "1.1rem",
                color: "#6B6860",
                letterSpacing: "-0.01em",
              }}
            >
              {typingWPM} wpm
            </span>
          </div>
          <div
            style={{
              width: "100%",
              height: "12px",
              backgroundColor: "#ECEAE5",
              borderRadius: "3px",
              overflow: "hidden",
            }}
          >
            <div
              style={{
                width: `${(typingWPM / maxWPM) * 100}%`,
                height: "100%",
                backgroundColor: "#9B9890",
                borderRadius: "3px",
                transition: "width 1s ease",
              }}
            />
          </div>
        </div>

        {/* Speaking bar */}
        <div>
          <div
            style={{
              display: "flex",
              justifyContent: "space-between",
              alignItems: "baseline",
              marginBottom: "0.5rem",
            }}
          >
            <span
              style={{
                fontFamily: "'IBM Plex Mono', monospace",
                fontSize: "0.8rem",
                letterSpacing: "0.14em",
                textTransform: "uppercase",
                color: "#1A1A18",
              }}
            >
              Speaking
            </span>
            <span
              style={{
                fontFamily: "'IBM Plex Mono', monospace",
                fontSize: "1.1rem",
                color: "#1A5C3A",
                letterSpacing: "-0.01em",
              }}
            >
              {speakingWPM} wpm
            </span>
          </div>
          <div
            style={{
              width: "100%",
              height: "12px",
              backgroundColor: "#ECEAE5",
              borderRadius: "3px",
              overflow: "hidden",
            }}
          >
            <div
              style={{
                width: `${(speakingWPM / maxWPM) * 100}%`,
                height: "100%",
                backgroundColor: "#1A5C3A",
                borderRadius: "3px",
                transition: "width 1s ease",
              }}
            />
          </div>
        </div>

        <p
          style={{
            fontFamily: "'IBM Plex Mono', monospace",
            fontSize: "0.75rem",
            color: "#C0C0BB",
            letterSpacing: "0.06em",
            textAlign: "right",
            marginTop: "0.25rem",
          }}
        >
          avg. words per minute
        </p>
      </div>
    </section>
  );
}
