import { useState } from "react";

interface FAQItem {
  question: string;
  answer: string;
}

const faqs: FAQItem[] = [
  {
    question: "Is any of my data shared? Does it leave my laptop?",
    answer:
      "Never. Kalam is compiled without any network entitlements. Your audio is processed entirely on-device using Apple's Neural Engine and is wiped from memory the instant transcription is complete. No data is ever transmitted, stored, or accessible to us or any third party.",
  },
  {
    question: "Can I use it for free?",
    answer:
      "Yes — completely. Kalam is free and open-source under the MIT license. There are no subscriptions, no usage limits, no premium tiers. Download it, inspect the source, and use it however you like.",
  },
  {
    question: "Does it work with my apps?",
    answer:
      "If you can type into it, Kalam can fill it. It works at the OS level, injecting clean text directly into any focused text field — Slack, Notion, Xcode, Terminal, email clients, browsers, code editors, and everything in between.",
  },
  {
    question: "Which languages does it support?",
    answer:
      "Kalam currently supports 25+ languages on-device, powered by Apple's multilingual speech recognition stack. This includes English, Spanish, French, German, Japanese, Mandarin, Hindi, Arabic, Portuguese, and many more — all without a network connection.",
  },
];

function FAQRow({ item }: { item: FAQItem }) {
  const [open, setOpen] = useState(false);

  return (
    <div style={{ borderTop: "0.5px solid #D4D4D0" }}>
      <button
        onClick={() => setOpen(!open)}
        style={{
          width: "100%",
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          padding: "1.4rem 0",
          background: "none",
          border: "none",
          cursor: "pointer",
          textAlign: "left",
          gap: "1rem",
        }}
      >
        <span
          style={{
            fontFamily: "'Instrument Serif', serif",
            fontSize: "clamp(1.4rem, 2vw, 1.8rem)",
            letterSpacing: "-0.01em",
            color: "#1A1A18",
            lineHeight: 1.2,
          }}
        >
          {item.question}
        </span>
        <span
          style={{
            color: "#6B6860",
            flexShrink: 0,
            transition: "transform 0.25s ease",
            transform: open ? "rotate(45deg)" : "rotate(0deg)",
            display: "flex",
          }}
        >
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
            <line x1="8" y1="2" x2="8" y2="14" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round"/>
            <line x1="2" y1="8" x2="14" y2="8" stroke="currentColor" strokeWidth="1.2" strokeLinecap="round"/>
          </svg>
        </span>
      </button>
      <div
        style={{
          maxHeight: open ? "300px" : "0",
          overflow: "hidden",
          transition: "max-height 0.35s ease",
        }}
      >
        <p
          style={{
            fontFamily: "'Plus Jakarta Sans', sans-serif",
            fontSize: "0.95rem",
            color: "#6B6860",
            lineHeight: 1.75,
            paddingBottom: "1.4rem",
            maxWidth: "44rem",
          }}
        >
          {item.answer}
        </p>
      </div>
    </div>
  );
}

export function FAQ() {
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
          fontSize: "clamp(2rem, 4vw, 3.5rem)",
          letterSpacing: "-0.03em",
          color: "#1A1A18",
          fontWeight: 400,
          lineHeight: 1.1,
          marginBottom: "clamp(2rem, 4vw, 3rem)",
        }}
      >
        Frequently asked.
      </h2>

      <div style={{ maxWidth: "52rem", margin: "0 auto", textAlign: "left" }}>
        {faqs.map((faq) => (
          <FAQRow key={faq.question} item={faq} />
        ))}
        {/* Bottom border */}
        <div style={{ borderTop: "0.5px solid #D4D4D0" }} />
      </div>
    </section>
  );
}
