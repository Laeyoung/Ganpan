// Re-record the demo videos (playwright is NOT a repo dependency — install it in a scratch dir):
//   (cd "$(mktemp -d)" && npm i playwright && NODE_PATH="$PWD/node_modules" node <repo>/demo/record.cjs)
// Writes demo/ganpan-demo-{ko,en}.mp4 (needs ffmpeg on PATH).
const { chromium } = require('playwright');
const { execFileSync } = require('node:child_process');
const { mkdtempSync, readdirSync } = require('node:fs');
const { join } = require('node:path');
const { tmpdir } = require('node:os');
const { pathToFileURL } = require('node:url');

const page = pathToFileURL(join(__dirname, 'index.html')).href;

async function record(lang) {
  const dir = mkdtempSync(join(tmpdir(), `ganpan-demo-${lang}-`));
  const browser = await chromium.launch();
  const ctx = await browser.newContext({
    viewport: { width: 1600, height: 900 },
    recordVideo: { dir, size: { width: 1600, height: 900 } },
  });
  const p = await ctx.newPage();
  await p.goto(`${page}?autoplay=1&lang=${lang}`);
  await p.waitForFunction(() => document.body.dataset.done === '1', null, { timeout: 400000, polling: 500 });
  await p.waitForTimeout(5000);                       // hold the summary screen
  await ctx.close();
  await browser.close();
  const webm = join(dir, readdirSync(dir).find(f => f.endsWith('.webm')));
  execFileSync('ffmpeg', ['-v', 'error', '-y', '-i', webm,
    '-vf', 'scale=1920:1080:flags=lanczos,fps=30', '-c:v', 'libx264', '-preset', 'veryslow',
    '-tune', 'animation', '-crf', '26', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', '-an',
    join(__dirname, `ganpan-demo-${lang}.mp4`)], { stdio: 'inherit' });
  console.log(`wrote demo/ganpan-demo-${lang}.mp4`);
}

(async () => {
  for (const lang of ['ko', 'en']) await record(lang);   // sequential: parallel runs drop frames
})();
