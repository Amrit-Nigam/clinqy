import { createElement } from 'react'

type Props = { text: string; as?: keyof JSX.IntrinsicElements; className?: string; id?: string; start?: boolean }

/** Plain heading text. (Formerly decoded out of random glyphs; that effect was removed.) */
export function Scramble({ text, as = 'span', className, id }: Props) {
  return createElement(as, { className, id }, text)
}
