import { renderToString } from "react-dom/server";
import App from "./app/App";
import { faqs } from "./app/components/FAQ";

const SITE_URL = "https://singhkays.com/kalam/";

/**
 * Server-side render of the full app. Used only by scripts/prerender.mjs at
 * build time; the browser bundle never imports this file.
 */
export function render() {
  return renderToString(<App />);
}

/**
 * Structured data (schema.org), rendered into dist/index.html as JSON-LD.
 * FAQ answers are imported from the FAQ component so the visible page and
 * the structured data can never drift apart.
 */
export function jsonLd() {
  const graph = [
    {
      "@type": "WebSite",
      "@id": "https://singhkays.com/#website",
      url: "https://singhkays.com/",
      name: "KAY SINGH",
    },
    {
      "@type": "WebPage",
      "@id": `${SITE_URL}#webpage`,
      url: SITE_URL,
      name: "Kalam — On-device dictation for macOS",
      isPartOf: { "@id": "https://singhkays.com/#website" },
      description:
        "Kalam is a high-performance dictation and audio processing engine for macOS. Runs entirely on-device with zero network access.",
    },
    {
      "@type": "SoftwareApplication",
      "@id": `${SITE_URL}#software`,
      name: "Kalam",
      operatingSystem: "macOS",
      applicationCategory: "UtilitiesApplication",
      description:
        "A dictation app for macOS that cleans up speech in real time — knows 'um' isn't a word and 'scratch that' is an instruction. Runs entirely on-device.",
      url: SITE_URL,
      image: `${SITE_URL}vector-quill.png`,
      isAccessibleForFree: true,
      license: "https://opensource.org/licenses/MIT",
      downloadUrl: "https://github.com/singhkays/Kalam/releases/latest",
      softwareVersion: "1.0.0",
      author: {
        "@type": "Person",
        name: "Kay Singh",
        url: "https://singhkays.com/about/",
      },
      offers: {
        "@type": "Offer",
        price: "0",
        priceCurrency: "USD",
      },
    },
    {
      "@type": "FAQPage",
      "@id": `${SITE_URL}#faq`,
      mainEntity: faqs.map((f) => ({
        "@type": "Question",
        name: f.question,
        acceptedAnswer: { "@type": "Answer", text: f.answer },
      })),
    },
  ];

  return { "@context": "https://schema.org", "@graph": graph };
}
