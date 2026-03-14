
export function InstallationGuide() {
  return (
    <section
      id="installation"
      style={{
        backgroundColor: "#FAFAF7",
        paddingTop: "clamp(3rem, 6vw, 4rem)",
        paddingBottom: "clamp(2rem, 4vw, 3rem)",
        paddingLeft: "clamp(1.5rem, 8vw, 10rem)",
        paddingRight: "clamp(1.5rem, 8vw, 10rem)",
      }}
    >
      <div style={{ maxWidth: "50rem", margin: "0 auto" }}>
        <h2
          style={{
            fontFamily: "'IBM Plex Mono', monospace",
            fontSize: "0.85rem",
            color: "#1A1A18",
            letterSpacing: "0.18em",
            textTransform: "uppercase",
            marginBottom: "2rem",
          }}
        >
          Installation Guide
        </h2>
        
        <div style={{ display: "grid", gap: "2.5rem" }}>
          <div style={{ display: "flex", gap: "1.5rem" }}>
            <span style={{ 
              fontFamily: "'IBM Plex Mono', monospace", 
              fontSize: "1.5rem", 
              color: "#1A5C3A",
              opacity: 0.5,
              flexShrink: 0 
            }}>01</span>
            <div>
              <p style={{ 
                fontFamily: "'Plus Jakarta Sans', sans-serif", 
                fontSize: "1.05rem", 
                color: "#1A1A18", 
                fontWeight: 500,
                marginBottom: "0.5rem" 
              }}>
                Drag and Drop
              </p>
              <p style={{ 
                fontFamily: "'Plus Jakarta Sans', sans-serif", 
                fontSize: "0.95rem", 
                color: "#6B6860", 
                lineHeight: 1.6 
              }}>
                Open the downloaded DMG file and drag the Kalam app icon into your Applications folder.
              </p>
            </div>
          </div>

          <div style={{ display: "flex", gap: "1.5rem" }}>
            <span style={{ 
              fontFamily: "'IBM Plex Mono', monospace", 
              fontSize: "1.5rem", 
              color: "#1A5C3A",
              opacity: 0.5,
              flexShrink: 0 
            }}>02</span>
            <div>
              <p style={{ 
                fontFamily: "'Plus Jakarta Sans', sans-serif", 
                fontSize: "1.05rem", 
                color: "#1A1A18", 
                fontWeight: 500,
                marginBottom: "0.5rem" 
              }}>
                First Launch (Gatekeeper)
              </p>
              <p style={{ 
                fontFamily: "'Plus Jakarta Sans', sans-serif", 
                fontSize: "0.95rem", 
                color: "#6B6860", 
                lineHeight: 1.6 
              }}>
                Kalam is an independent, non-commercial release. For the first launch, <strong>Right-click</strong> (or Control-click) the app and select <strong>Open</strong>. This one-time step allows macOS to verify the software.
              </p>
            </div>
          </div>

          <div style={{ display: "flex", gap: "1.5rem" }}>
            <span style={{ 
              fontFamily: "'IBM Plex Mono', monospace", 
              fontSize: "1.5rem", 
              color: "#1A5C3A",
              opacity: 0.5,
              flexShrink: 0 
            }}>03</span>
            <div>
              <p style={{ 
                fontFamily: "'Plus Jakarta Sans', sans-serif", 
                fontSize: "1.05rem", 
                color: "#1A1A18", 
                fontWeight: 500,
                marginBottom: "0.5rem" 
              }}>
                Onboarding
              </p>
              <p style={{ 
                fontFamily: "'Plus Jakarta Sans', sans-serif", 
                fontSize: "0.95rem", 
                color: "#6B6860", 
                lineHeight: 1.6 
              }}>
                Follow the 4-step setup guide to configure your microphone, accessibility settings, and download your local transcription models.
              </p>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
