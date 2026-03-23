import type { ReactNode } from "react";
import AppleIcon from "@mui/icons-material/Apple";
import GitHubIcon from "@mui/icons-material/GitHub";

interface CtaButtonLabelProps {
  icon: "apple" | "github";
  iconColor: string;
  children: ReactNode;
}

export function CtaButtonLabel({ icon, iconColor, children }: CtaButtonLabelProps) {
  const Icon = icon === "apple" ? AppleIcon : GitHubIcon;
  const iconSize = icon === "apple" ? 18 : 17;
  const iconOpacity = icon === "apple" ? 1 : 0.9;

  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        gap: "0.56rem",
        lineHeight: 1,
      }}
    >
      <Icon sx={{ fontSize: iconSize, color: iconColor, opacity: iconOpacity }} />
      <span>{children}</span>
    </span>
  );
}
