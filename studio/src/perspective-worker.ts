type Point = { x: number; y: number };
self.onmessage = (
  event: MessageEvent<{
    width: number;
    height: number;
    pixels: ArrayBuffer;
    points: Point[];
  }>,
) => {
  try {
    const { width, height, points } = event.data,
      source = new Uint8ClampedArray(event.data.pixels);
    const p = points.map((point) => ({
      x: point.x * width,
      y: point.y * height,
    }));
    const distance = (a: Point, b: Point) => Math.hypot(a.x - b.x, a.y - b.y);
    const outWidth = Math.max(
      2,
      Math.round(Math.max(distance(p[0], p[1]), distance(p[3], p[2]))),
    );
    const outHeight = Math.max(
      2,
      Math.round(Math.max(distance(p[0], p[3]), distance(p[1], p[2]))),
    );
    const dx1 = p[1].x - p[2].x,
      dx2 = p[3].x - p[2].x,
      dx3 = p[0].x - p[1].x + p[2].x - p[3].x;
    const dy1 = p[1].y - p[2].y,
      dy2 = p[3].y - p[2].y,
      dy3 = p[0].y - p[1].y + p[2].y - p[3].y;
    const denominator = dx1 * dy2 - dx2 * dy1;
    const g =
      Math.abs(denominator) < 1e-9 ? 0 : (dx3 * dy2 - dx2 * dy3) / denominator;
    const h =
      Math.abs(denominator) < 1e-9 ? 0 : (dx1 * dy3 - dx3 * dy1) / denominator;
    const a = p[1].x - p[0].x + g * p[1].x,
      b = p[3].x - p[0].x + h * p[3].x,
      c = p[0].x;
    const d = p[1].y - p[0].y + g * p[1].y,
      e = p[3].y - p[0].y + h * p[3].y,
      f = p[0].y;
    const pixels = new Uint8ClampedArray(outWidth * outHeight * 4);
    for (let y = 0; y < outHeight; y++)
      for (let x = 0; x < outWidth; x++) {
        const u = x / (outWidth - 1),
          v = y / (outHeight - 1),
          z = g * u + h * v + 1;
        const sx = Math.max(0, Math.min(width - 1, (a * u + b * v + c) / z)),
          sy = Math.max(0, Math.min(height - 1, (d * u + e * v + f) / z));
        const x0 = Math.floor(sx),
          y0 = Math.floor(sy),
          x1 = Math.min(width - 1, x0 + 1),
          y1 = Math.min(height - 1, y0 + 1),
          fx = sx - x0,
          fy = sy - y0;
        for (let channel = 0; channel < 4; channel++)
          pixels[(y * outWidth + x) * 4 + channel] =
            source[(y0 * width + x0) * 4 + channel] * (1 - fx) * (1 - fy) +
            source[(y0 * width + x1) * 4 + channel] * fx * (1 - fy) +
            source[(y1 * width + x0) * 4 + channel] * (1 - fx) * fy +
            source[(y1 * width + x1) * 4 + channel] * fx * fy;
      }
    self.postMessage(
      { width: outWidth, height: outHeight, pixels: pixels.buffer },
      { transfer: [pixels.buffer] },
    );
  } catch (error) {
    self.postMessage({ error: String(error) });
  }
};
