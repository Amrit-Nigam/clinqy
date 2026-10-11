let cached: string | null = null

/**
 * Displacement map for feDisplacementMap: each pixel pushes its sample point
 * outward by r², so the middle of the picture swells and the edges squeeze in,
 * like light through curved CRT glass. R = x offset, G = y offset (0.5 = none).
 */
export function barrelMap() {
  if (cached) return cached
  const n = 256
  const c = document.createElement('canvas')
  c.width = c.height = n
  const ctx = c.getContext('2d')!
  const img = ctx.createImageData(n, n)
  for (let y = 0; y < n; y++) {
    for (let x = 0; x < n; x++) {
      const u = (x / (n - 1)) * 2 - 1
      const v = (y / (n - 1)) * 2 - 1
      const r2 = (u * u + v * v) / 2
      const i = (y * n + x) * 4
      img.data[i] = Math.round((0.5 + u * r2 * 0.5) * 255)
      img.data[i + 1] = Math.round((0.5 + v * r2 * 0.5) * 255)
      img.data[i + 2] = 128
      img.data[i + 3] = 255
    }
  }
  ctx.putImageData(img, 0, 0)
  cached = c.toDataURL()
  return cached
}
