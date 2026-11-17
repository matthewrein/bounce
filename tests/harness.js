// Injected into index.html before it loads (Playwright addInitScript). Runs in the page.
// Step mode: the page's animation loop only advances when the runner calls __harness.tick(), and the app's
// camera <video> (a real getUserMedia stream from Chrome's --use-file-for-fake-video-capture) is swapped, at
// draw time, for the exact clip frame the runner chose. That makes every run frame-exact and repeatable.
// Live mode: nothing is stepped; the fake camera plays in real time and the runner only listens.
/* eslint-disable no-undef */
(function (cfg) {
  try { localStorage.setItem("slabFov", String(cfg.fov)); } catch (_) {}
  const H = (window.__harness = { mode: cfg.mode, frames: null, cur: -1 });
  // A phone returns its camera's own portrait frames whatever size the page asks for; Chrome would instead crop the
  // 720x1280 fake camera to the app's requested landscape shape, so ask it to leave the frames alone.
  if (navigator.mediaDevices && navigator.mediaDevices.getUserMedia) {
    const gum = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
    navigator.mediaDevices.getUserMedia = (c) => { if (c && c.video && typeof c.video === "object") c = { ...c, video: { ...c.video, resizeMode: "none" } }; return gum(c); };
  }
  H.motion = (s) => window.dispatchEvent(new DeviceMotionEvent("devicemotion", {
    accelerationIncludingGravity: { x: s.aig[0], y: s.aig[1], z: s.aig[2] },
    acceleration: s.acc ? { x: s.acc[0], y: s.acc[1], z: s.acc[2] } : null,
    rotationRate: s.rot, interval: 16.7 }));
  H.load = async (url) => {
    const b = new Uint8Array(await (await fetch(url)).arrayBuffer()), st = [];
    for (let i = 0; i < b.length - 1; i++) if (b[i] === 0xff && b[i + 1] === 0xd8 && (i === 0 || (b[i - 2] === 0xff && b[i - 1] === 0xd9))) st.push(i);
    H.frames = st.map((s, k) => b.subarray(s, k + 1 < st.length ? st[k + 1] : b.length));
    return H.frames.length;
  };
  if (cfg.mode !== "step") return;
  const q = [];
  window.requestAnimationFrame = (cb) => { q.push(cb); return q.length; };
  window.cancelAnimationFrame = () => {};
  let bmp = null;
  const orig = CanvasRenderingContext2D.prototype.drawImage;
  CanvasRenderingContext2D.prototype.drawImage = function (img, ...a) { if (bmp && img instanceof HTMLVideoElement) img = bmp; return orig.call(this, img, ...a); };
  H.setFrame = async (i) => { if (H.cur === i) return; const nb = await createImageBitmap(new Blob([H.frames[i]], { type: "image/jpeg" })); if (bmp) bmp.close(); bmp = nb; H.cur = i; };
  H.tick = (ts) => { const cbs = q.splice(0); for (const cb of cbs) cb(ts); };
})(__CFG__);
