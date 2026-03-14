export function Header() {
  return (
    <header
      style={{
        backgroundColor: "transparent",
        paddingTop: "1.5rem",
        paddingBottom: "1.5rem",
        paddingLeft: "clamp(1.5rem, 5vw, 5rem)",
        paddingRight: "clamp(1.5rem, 5vw, 5rem)",
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        position: "relative",
        zIndex: 10,
      }}
    >
      {/* Kalam wordmark */}
      <span
        style={{
          fontFamily: "'Instrument Serif', serif",
          fontSize: "1.75rem",
          color: "#1A1A18",
          letterSpacing: "-0.02em",
          lineHeight: 1,
        }}
      >
        Kalam
      </span>

      {/* Technical metadata */}
      <span
        style={{
          fontFamily: "'IBM Plex Mono', monospace",
          fontSize: "0.65rem",
          color: "#C0C0BB",
          letterSpacing: "0.08em",
          lineHeight: 1,
        }}
      >
        v1.0.0 / MAR 2026
      </span>
    </header>
  );
}
