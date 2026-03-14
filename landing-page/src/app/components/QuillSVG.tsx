interface QuillSVGProps {
  color?: string;
  strokeWidth?: number;
  className?: string;
  style?: React.CSSProperties;
}

export function QuillSVG({
  color = "#1A1A18",
  strokeWidth = 1,
  className = "",
  style,
}: QuillSVGProps) {
  return (
    <svg
      viewBox="0 0 90 260"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={className}
      style={style}
      aria-hidden="true"
    >
      {/* Left vane outline */}
      <path
        d="M45,8 C32,22 8,52 6,92 C4,128 20,158 40,175"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        fill="none"
      />
      {/* Right vane outline */}
      <path
        d="M45,8 C58,22 82,52 84,92 C86,128 70,158 50,175"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        fill="none"
      />
      {/* Bottom vane transition to shaft */}
      <path
        d="M40,175 C42,179 43.5,182 45,185 C46.5,182 48,179 50,175"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
        fill="none"
      />
      {/* Central rachis through feather */}
      <line
        x1="45" y1="8" x2="45" y2="185"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
      />
      {/* Shaft / calamus */}
      <line
        x1="45" y1="185" x2="45" y2="240"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinecap="round"
      />
      {/* Nib */}
      <path
        d="M45,240 L42,252 L45,258 L48,252 Z"
        stroke={color}
        strokeWidth={strokeWidth}
        strokeLinejoin="round"
        fill="none"
      />

      {/* Left barbs */}
      <line x1="45" y1="24" x2="29" y2="27" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="38" x2="19" y2="42" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="52" x2="11" y2="57" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="66" x2="7" y2="71" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="80" x2="6" y2="84" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="94" x2="6" y2="98" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="108" x2="9" y2="112" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="122" x2="15" y2="125" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="136" x2="24" y2="139" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="150" x2="33" y2="152" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="163" x2="40" y2="164" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>

      {/* Right barbs */}
      <line x1="45" y1="24" x2="61" y2="27" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="38" x2="71" y2="42" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="52" x2="79" y2="57" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="66" x2="83" y2="71" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="80" x2="84" y2="84" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="94" x2="84" y2="98" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="108" x2="81" y2="112" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="122" x2="75" y2="125" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="136" x2="66" y2="139" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="150" x2="57" y2="152" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
      <line x1="45" y1="163" x2="50" y2="164" stroke={color} strokeWidth={strokeWidth * 0.65} opacity="0.85" strokeLinecap="round"/>
    </svg>
  );
}
