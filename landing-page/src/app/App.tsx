import { Header } from "./components/Header";
import { Hero } from "./components/Hero";
import { DictationEngine } from "./components/DictationEngine";
import { CleanupDemo } from "./components/CleanupDemo";
import { WorksEverywhere } from "./components/WorksEverywhere";
import { SpeedAdvantage } from "./components/SpeedAdvantage";
import { TheDetails } from "./components/TheDetails";
import { FAQ } from "./components/FAQ";
import { Privacy } from "./components/Privacy";
import { InstallationGuide } from "./components/InstallationGuide";
import { FinalCTA } from "./components/FinalCTA";

const Hairline = () => (
  <div style={{ borderTop: "0.5px solid #D4D4D0" }} />
);

export default function App() {
  return (
    <div
      style={{
        backgroundColor: "#FAFAF7",
        color: "#1A1A18",
        minHeight: "100vh",
        overflowX: "hidden",
      }}
    >
      {/* Hero section — grid background + header float over it */}
      <div
        className="hero-shell"
        style={{
          background: "#FAFAF7",
          backgroundImage: `
            linear-gradient(rgba(120,120,110,0.07) 1px, transparent 1px),
            linear-gradient(90deg, rgba(120,120,110,0.07) 1px, transparent 1px)
          `,
          backgroundSize: "44px 44px",
        }}
      >
        <style>{`
          @media (max-width: 900px) {
            .hero-shell {
              min-height: 100svh;
              display: flex;
              flex-direction: column;
            }

            .installation-hairline {
              display: none;
            }
          }
        `}</style>
        <Header />
        <Hero />
      </div>

      {/* All content sections on solid warm off-white */}
      <main>
        <InstallationGuide />
        <div className="installation-hairline">
          <Hairline />
        </div>
        <DictationEngine />
        <Hairline />
        <CleanupDemo />
        <Hairline />
        <WorksEverywhere />
        <Hairline />
        <SpeedAdvantage />
        <Hairline />
        <TheDetails />
        <Hairline />
        <FAQ />
        <Hairline />
        <Privacy />
        <FinalCTA />
      </main>
    </div>
  );
}
