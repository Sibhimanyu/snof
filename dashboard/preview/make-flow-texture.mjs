// Bakes the water-in-the-pipe texture used by #/water (public/art/water/flow-h.webp
// and flow-v.webp): light caustic ridges from SVG feTurbulence, seamless along
// the flow (stitchTiles), transparent elsewhere. Re-run: node make-flow-texture.mjs
// then cwebp -q 80 -alpha_q 90 flow-h.png -o ../public/art/water/flow-h.webp.
import { chromium } from 'playwright';
const OUT = process.argv[2] || '/tmp/';
const b = await chromium.launch();
async function bake(name, w, h, freq, seed) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">
  <filter id="f" filterUnits="userSpaceOnUse" x="0" y="0" width="${w}" height="${h}" color-interpolation-filters="sRGB">
    <feTurbulence type="turbulence" baseFrequency="${freq}" numOctaves="3" seed="${seed}" stitchTiles="stitch" result="t"/>
    <feColorMatrix in="t" type="matrix" values="0 0 0 0 .92  0 0 0 0 .97  0 0 0 0 1  -3.4 0 0 0 1.0" result="m"/>
    <feGaussianBlur in="m" stdDeviation="0.9 0.9" edgeMode="wrap"/>
  </filter>
  <rect width="${w}" height="${h}" filter="url(#f)"/></svg>`;
  const p = await b.newPage({ viewport: { width: w, height: h } });
  await p.setContent(`<body style="margin:0;background:transparent">${svg}</body>`);
  await p.screenshot({ path: `${OUT}${name}.png`, omitBackground: true });
  await p.close();
}
await bake('flow-h', 600, 96, '0.0055 0.04', 7);
await bake('flow-v', 96, 600, '0.04 0.0055', 11);
await b.close();
