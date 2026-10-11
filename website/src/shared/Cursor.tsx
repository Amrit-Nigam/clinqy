type Props = { size?: number; className?: string; style?: React.CSSProperties }

/** The Clinqy companion arrow: blue fill, white outline, soft glow. */
export function CursorArrow({ size = 22, className, style }: Props) {
  return (
    <svg
      className={className}
      style={style}
      width={size}
      height={size * 1.3}
      viewBox="-2 -2 24 30"
      aria-hidden="true"
    >
      <path
        d="M0 0 L0 22 L6 16.4 L10.6 25.6 L14.4 23.7 L9.9 14.8 L18 14.8 Z"
        fill="#3B82F6"
        stroke="#fff"
        strokeWidth="2.2"
        strokeLinejoin="round"
      />
    </svg>
  )
}
