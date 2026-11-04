// Browser plumbing: canvas, input events, pointer lock and saved settings.
// Raw events go straight to the wasm game (src/web.zig), which owns key
// bindings, the menu and everything else.
const CONFIG_KEY = 'space4d.cfg';
// Cache busting: tools/publish.sh loads this script as app.js?v=<commit>,
// and every other file is fetched with the same suffix, so a visitor never
// mixes files from two versions out of a cache.
const VERSION = new URL(import.meta.url).search;

// KeyboardEvent.code (physical key) -> SDL scancode, which is what the game's
// bindings and menu use on every platform.
const SCANCODES = { Enter: 40, Escape: 41, Backspace: 42, Tab: 43, Space: 44, Minus: 45, Equal: 46,
  BracketLeft: 47, BracketRight: 48, Backslash: 49, Semicolon: 51, Quote: 52, Backquote: 53, Comma: 54,
  Period: 55, Slash: 56, CapsLock: 57, Insert: 73, Home: 74, PageUp: 75, Delete: 76, End: 77,
  PageDown: 78, ArrowRight: 79, ArrowLeft: 80, ArrowDown: 81, ArrowUp: 82, NumpadEnter: 88,
  Numpad0: 98, ControlLeft: 224, ShiftLeft: 225, AltLeft: 226, ControlRight: 228, ShiftRight: 229,
  AltRight: 230 };
for (let i = 0; i < 26; i++) SCANCODES['Key' + String.fromCharCode(65 + i)] = 4 + i;
for (let i = 1; i <= 9; i++) SCANCODES['Digit' + i] = 29 + i;
SCANCODES.Digit0 = 39;
for (let i = 1; i <= 12; i++) SCANCODES['F' + i] = 57 + i;
for (let i = 1; i <= 9; i++) SCANCODES['Numpad' + i] = 88 + i;

const canvas = document.getElementById('view');
const status = document.getElementById('status');

function fail(msg) {
  status.textContent = msg;
  status.className = 'error';
  console.error(msg);
}

async function main() {
  const { createRenderer, loadWasm } = await import(`./gpu.js${VERSION}`);
  if (!navigator.gpu) {
    return fail('This page needs WebGPU: a recent Chrome, Edge or Safari, or Firefox on Windows.');
  }
  const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' }) ??
    await navigator.gpu.requestAdapter();
  if (!adapter) {
    const ua = navigator.userAgent;
    const linux = /Linux/.test(ua) && !/Android/.test(ua);
    let hint = 'Make sure hardware acceleration is enabled in the browser settings.';
    if (/Firefox\//.test(ua)) {
      hint = linux ? 'Firefox on Linux: set dom.webgpu.enabled to true in about:config, or use Chrome.'
        : 'Firefox: update to the latest version and check that hardware acceleration is on.';
    } else if (/Chrome\//.test(ua) && linux) {
      // Brave reports a Chrome user agent; navigator.brave tells them apart.
      const s = navigator.brave ? 'brave' : 'chrome';
      hint = `On Linux this needs four flags in ${s}://flags (listed below), then a restart; ` +
        `${s}://gpu should then say "WebGPU: Hardware accelerated". ` +
        'Read the security note below before enabling them.' +
        (navigator.brave ? ' If it still fails, try with Shields down for this site.' : '');
      document.getElementById('webgpu-note').open = true;
    }
    return fail('WebGPU is available but found no usable GPU. ' + hint);
  }
  const ai = adapter.info ?? {};
  const fallback = ai.isFallbackAdapter ?? adapter.isFallbackAdapter ?? false;
  const adapterName = [ai.vendor, ai.architecture, ai.device, ai.description].filter((x) => x).join(' ') || 'unknown';
  console.log(`space4d: WebGPU adapter: ${adapterName}${fallback ? ' (SOFTWARE fallback)' : ''}`);
  const device = await adapter.requestDevice();
  device.lost.then((info) => info.reason !== 'destroyed' && fail('GPU device lost: ' + info.message));
  device.addEventListener('uncapturederror', (e) => fail('GPU error: ' + e.error.message));

  status.textContent = 'Loading…';
  const [bytes, code] = await Promise.all([
    fetch(`space4d.wasm${VERSION}`).then((r) => r.arrayBuffer()),
    fetch(`shaders.wgsl${VERSION}`).then((r) => r.text()),
  ]);
  const game = await loadWasm(bytes, (m) => console.log(m), (m) => fail('Crashed: ' + m));
  const z = game.z;
  let saved = '';
  try { saved = localStorage.getItem(CONFIG_KEY) ?? ''; } catch { /* storage blocked */ }
  game.init(saved);
  // A software (CPU) adapter, e.g. Chromium's SwiftShader when WebGPU is
  // forced on without GPU access: very slow, so the game starts in low quality.
  if (fallback) {
    z.softwareRenderer();
    document.getElementById('webgpu-note').open = true;
  }

  canvas.width = z.hudWidth();
  canvas.height = z.hudHeight();
  const format = navigator.gpu.getPreferredCanvasFormat();
  const ctx = canvas.getContext('webgpu');
  ctx.configure({ device, format, alphaMode: 'opaque' });
  const renderer = await createRenderer(device, code, z, format);
  status.textContent = '';
  status.className = 'hidden';

  const save = () => {
    try { localStorage.setItem(CONFIG_KEY, game.settingsText()); } catch { /* storage blocked */ }
  };
  const locked = () => document.pointerLockElement === canvas;
  const lock = () => {
    try { canvas.requestPointerLock()?.catch?.(() => {}); } catch { /* needs a user gesture */ }
  };

  window.addEventListener('keydown', (e) => {
    const sc = SCANCODES[e.code];
    if (sc === undefined) return;
    // Keep browser shortcuts (Ctrl/Cmd+..., F5, F11, F12) working.
    if (!e.ctrlKey && !e.metaKey && !e.code.startsWith('F')) e.preventDefault();
    const r = z.keyDown(sc, e.repeat);
    if (r === 1 && locked()) document.exitPointerLock();
    if (r === 2) lock();
    if (z.takeSaveRequest()) save();
  });
  window.addEventListener('keyup', (e) => {
    const sc = SCANCODES[e.code];
    if (sc !== undefined) z.keyUp(sc);
  });
  window.addEventListener('blur', () => z.clearKeys());

  // Menu transitions caused by touch or gamepad presses.
  const applyCapture = () => {
    const r = z.takeCaptureRequest();
    if (r === 1 && locked()) document.exitPointerLock();
    if (r === 2 && !touchUsed) lock();
    if (z.takeSaveRequest()) save();
  };

  // Touch, pen, and the Meta Quest browser's controller laser (which arrives
  // as a mouse pointer but can't use pointer lock) drive the on-screen
  // controls. Coordinates go to the game in HUD pixels.
  const quest = /OculusBrowser|Quest/.test(navigator.userAgent);
  const isTouch = (e) => e.pointerType === 'touch' || e.pointerType === 'pen' || quest;
  let touchUsed = false;
  const hudPos = (e) => {
    const r = canvas.getBoundingClientRect();
    return [(e.clientX - r.left) / r.width * z.hudWidth(), (e.clientY - r.top) / r.height * z.hudHeight()];
  };
  const toggleFullscreen = () => {
    if (document.fullscreenElement) {
      document.exitFullscreen?.();
    } else {
      document.documentElement.requestFullscreen?.()
        .then(() => screen.orientation?.lock?.('landscape').catch(() => {}))
        .catch(() => {});
    }
  };
  canvas.addEventListener('pointerdown', (e) => {
    if (!isTouch(e)) return;
    e.preventDefault(); // also suppresses the emulated mouse events
    touchUsed = true;
    canvas.setPointerCapture?.(e.pointerId);
    const [x, y] = hudPos(e);
    if (z.touchDown(e.pointerId, x, y) & 1) toggleFullscreen();
    applyCapture();
  });
  canvas.addEventListener('pointermove', (e) => {
    if (!isTouch(e)) return;
    e.preventDefault();
    const [x, y] = hudPos(e);
    z.touchMove(e.pointerId, x, y);
    applyCapture();
  });
  const touchEnd = (e) => {
    if (!isTouch(e)) return;
    z.touchUp(e.pointerId);
  };
  canvas.addEventListener('pointerup', touchEnd);
  canvas.addEventListener('pointercancel', touchEnd);

  canvas.addEventListener('mousedown', (e) => {
    if (quest) return;
    if (!locked() && !z.menuOpen()) lock();
    z.mouseButton(e.button, true);
  });
  window.addEventListener('mouseup', (e) => z.mouseButton(e.button, false));
  canvas.addEventListener('contextmenu', (e) => e.preventDefault());
  document.addEventListener('mousemove', (e) => {
    if (locked()) z.mouseMove(e.movementX, e.movementY);
  });
  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    if (e.deltaY) z.wheel(-Math.sign(e.deltaY));
  }, { passive: false });
  document.addEventListener('pointerlockchange', () => z.setCaptured(locked()));
  window.addEventListener('pagehide', save);
  document.addEventListener('visibilitychange', () => document.hidden && save());

  // At most two frames in flight. Some browsers (e.g. Chromium on Linux with
  // Vulkan) don't hold back requestAnimationFrame while the GPU is busy, so
  // without a limit frames queue up: the FPS counter reads high while what
  // you see lags further and further behind the input, and auto quality,
  // judging by those fast-looking frames, raises the cost even more. With
  // the limit, frame times (and so the FPS and auto quality) are real, and
  // the display is at most two frames behind.
  // Gamepad: the first connected pad, preferring the standard mapping,
  // copied into the game's pad buffer (4 axes, then 17 buttons) each frame.
  const pollGamepad = () => {
    const pads = navigator.getGamepads ? [...navigator.getGamepads()].filter((p) => p && p.connected) : [];
    const gp = pads.find((p) => p.mapping === 'standard') ?? pads[0];
    z.setPadConnected(!!gp);
    if (!gp) return;
    const buf = new Float32Array(z.memory.buffer, z.padPtr(), 4 + 17);
    for (let i = 0; i < 4; i++) buf[i] = gp.axes[i] ?? 0;
    for (let i = 0; i < 17; i++) buf[4 + i] = gp.buttons[i]?.value ?? 0;
  };

  const MAX_IN_FLIGHT = 2;
  let last = performance.now();
  let inFlight = 0;
  // Visible in the console as `space4d`: the adapter, rendered frames,
  // skipped vsyncs, and how long the GPU took to finish the last frame.
  const stats = (window.space4d = { adapter: adapterName, software: fallback, frames: 0, skipped: 0, gpuMs: 0 });
  const tick = (now) => {
    if (inFlight >= MAX_IN_FLIGHT) {
      stats.skipped++;
      return;
    }
    pollGamepad();
    z.frame((now - last) / 1000);
    last = now;
    applyCapture();
    renderer.frame(ctx.getCurrentTexture().createView());
    stats.frames++;
    inFlight++;
    const submitted = performance.now();
    // .finally: a rejected promise (device lost, page torn down) must not
    // leave the frame counted as in flight forever, which would freeze the game.
    device.queue.onSubmittedWorkDone()
      .then(() => { stats.gpuMs = Math.round((performance.now() - submitted) * 10) / 10; })
      .finally(() => { inFlight--; });
  };
  const guarded = (now) => {
    try {
      tick(now);
      requestAnimationFrame(guarded);
    } catch (err) {
      fail('Stopped: ' + err.message);
    }
  };
  requestAnimationFrame(guarded);
}

main().catch((err) => fail(err.message));
