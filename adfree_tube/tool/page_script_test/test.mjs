// Runs the app's injected page script (from lib/yt_web_player.dart) in
// headless Chromium against a YouTube-like page, and checks it does what the
// app relies on. Run from adfree_tube/: node tool/page_script_test/test.mjs
// Needs Node and Playwright (npm i -g playwright && npx playwright install chromium).
import { readFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const here = dirname(fileURLToPath(import.meta.url));

// Pull _css and _script out of the Dart source, undoing Dart string escapes.
const dart = readFileSync(join(here, '../../lib/yt_web_player.dart'), 'utf8');
const between = (start, from) => {
  const i = dart.indexOf("'''", dart.indexOf(start)) + 3;
  return dart.slice(i, dart.indexOf("''';", i));
};
const css = between('static const _css');
const script = between('static final _script')
  .replace('${jsonEncode(_css)}', JSON.stringify(css))
  .replace(/\\\\/g, '\\').replace(/\\'/g, "'");

const server = createServer((req, res) => {
  const file = join(here, req.url.split('?')[0].replace(/^\//, ''));
  try {
    const body = readFileSync(file);
    const type = file.endsWith('.html') ? 'text/html' : file.endsWith('.webm') ? 'video/webm' : 'application/octet-stream';
    res.writeHead(200, { 'content-type': type }).end(body);
  } catch { res.writeHead(404).end(); }
}).listen(0);
const url = `http://localhost:${server.address().port}/youtube_like.html`;

let failures = 0;
const check = (name, ok, detail = '') => {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ' (' + detail + ')' : ''}`);
  if (!ok) failures++;
};

// Fraction of screenshot pixels matching a colour test, sampled on a grid.
async function colourShare(page, test) {
  const png = await page.screenshot();
  return await page.evaluate(async ({ b64, testSrc }) => {
    const img = new Image();
    img.src = 'data:image/png;base64,' + b64;
    await img.decode();
    const c = document.createElement('canvas');
    c.width = img.width; c.height = img.height;
    const g = c.getContext('2d');
    g.drawImage(img, 0, 0);
    const d = g.getImageData(0, 0, c.width, c.height).data;
    const t = new Function('r', 'g', 'b', 'return ' + testSrc);
    let hit = 0, n = 0;
    for (let i = 0; i < d.length; i += 4 * 7) { n++; if (t(d[i], d[i + 1], d[i + 2])) hit++; }
    return hit / n;
  }, { b64: png.toString('base64'), testSrc: test });
}
const GREEN = 'r < 60 && g > 150 && b < 60';
const ORANGE = 'r > 220 && g > 100 && g < 180 && b < 60';

// The app turns off the WebView's "user gesture needed to play media" rule
// (setMediaPlaybackRequiresUserGesture(false)), so do the same here.
const browser = await chromium.launch({ args: ['--autoplay-policy=no-user-gesture-required'] });
try {
  for (const canvasVideo of [true, false]) {
    const page = await browser.newPage({ viewport: { width: 360, height: 202 } });
    const bridge = [];
    await page.exposeFunction('__post', (m) => bridge.push(JSON.parse(m)));
    await page.addInitScript(() => { window.AdFreeBridge = { postMessage: (m) => window.__post(m) }; });
    await page.goto(url);
    // What the app does on page start/finish.
    const inject = `window.__adfreeOptions = ${JSON.stringify({ pageDrawnVideo: true, canvasVideo })};\n${script}`;
    await page.evaluate(inject);
    await page.evaluate(inject); // injected twice in the app; must be harmless
    await page.waitForTimeout(2500);
    const tag = `canvas=${canvasVideo}`;

    const info = JSON.parse(await page.evaluate('window.__adfree.debug()'));
    const main = info.videos.find((v) => v.main);
    check(`${tag}: debug() reports the main video`, !!main && main.src.startsWith('blob:'), main && main.src);
    check(`${tag}: video playing and unmuted`, main && !main.paused && !main.muted, main && `paused=${main.paused} muted=${main.muted}`);
    check(`${tag}: video fills the view`, main && main.rect === '0,0,360,202', main && main.rect);
    check(`${tag}: site header hidden`, await page.evaluate(() => getComputedStyle(document.querySelector('header')).display === 'none'));
    const last = bridge[bridge.length - 1] || {};
    check(`${tag}: state reaches the app`, last.playing === true && last.d > 5, JSON.stringify(last));
    if (canvasVideo) {
      check(`${tag}: canvas is drawing frames`, info.canvasFrames > 10, `frames=${info.canvasFrames}`);
      check(`${tag}: canvas centre is green`, /^\d+,(1[5-9]\d|2\d\d),\d+ /.test(info.canvasCentre || ''), info.canvasCentre);
    } else {
      check(`${tag}: canvas hidden`, info.canvasCentre === null || / \(none\)$/.test(info.canvasCentre), info.canvasCentre);
    }
    const green = await colourShare(page, GREEN);
    check(`${tag}: green video visible on screen`, green > 0.5, `${(green * 100).toFixed(0)}% of pixels`);

    await page.evaluate('window.__adfree.testSquare()');
    await page.waitForTimeout(200);
    const orange = await colourShare(page, ORANGE);
    check(`${tag}: test square shows above the video`, orange > 0.05, `${(orange * 100).toFixed(0)}% of pixels`);

    await page.evaluate('window.__adfree.pause()');
    await page.waitForTimeout(600);
    const before = JSON.parse(await page.evaluate('window.__adfree.debug()')).canvasFrames;
    await page.waitForTimeout(600);
    const after = JSON.parse(await page.evaluate('window.__adfree.debug()')).canvasFrames;
    check(`${tag}: paused video isn't redrawn`, before === after, `${before} -> ${after}`);
    check(`${tag}: pause sticks (no auto-resume)`, await page.evaluate(() => document.querySelector('video').paused));
    await page.evaluate('window.__adfree.play()');
    await page.waitForTimeout(500);
    check(`${tag}: play resumes`, await page.evaluate(() => !document.querySelector('video').paused));

    // Bug 20: while YouTube's player is buffering (state 3, as after a seek)
    // the script mustn't force the video to play; once YouTube reports it
    // paused by itself (state 2), it resumes.
    await page.evaluate(() => {
      window.__ytState = 3;
      document.getElementById('movie_player').getPlayerState = () => window.__ytState;
      document.querySelector('video').pause();
    });
    await page.waitForTimeout(800);
    check(`${tag}: no forced play while YouTube is buffering`, await page.evaluate(() => document.querySelector('video').paused));
    await page.evaluate(() => { window.__ytState = 2; });
    await page.waitForTimeout(800);
    check(`${tag}: resumes once YouTube says it paused by itself`, await page.evaluate(() => !document.querySelector('video').paused));
    await page.evaluate(() => { delete document.getElementById('movie_player').getPlayerState; });

    const perf = JSON.parse(await page.evaluate('window.__adfree.debug()')).perf;
    check(`${tag}: debug() reports frame timing`, perf && perf.fps > 10 && typeof perf.waitingEvents === 'number', JSON.stringify(perf));
    if (canvasVideo) {
      check(`${tag}: debug() times canvas copies`, perf && perf.canvasDrawMs !== null, JSON.stringify(perf));
    }
    // refresh() (run when the app comes back to the front) keeps playing
    // from the same spot.
    const t0 = await page.evaluate(() => document.querySelector('video').currentTime);
    await page.evaluate('window.__adfree.refresh()');
    await page.waitForTimeout(500);
    const t1 = await page.evaluate(() => document.querySelector('video').currentTime);
    check(`${tag}: refresh keeps playing from the same spot`,
      t1 >= t0 && t1 - t0 < 2 && await page.evaluate(() => !document.querySelector('video').paused), `${t0} -> ${t1}`);
    await page.evaluate('window.__adfree.pause()');
    await page.evaluate('window.__adfree.refresh()');
    const refreshes = JSON.parse(await page.evaluate('window.__adfree.debug()')).perf.refreshes;
    check(`${tag}: refresh leaves a paused video alone`, refreshes === 1, `refreshes=${refreshes}`);
    await page.close();
  }
} finally {
  await browser.close();
  server.close();
}
console.log(failures ? `${failures} check(s) failed` : 'All page script checks passed');
process.exit(failures ? 1 : 0);
