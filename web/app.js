// Browser plumbing: canvas, input events, pointer lock and saved settings.
// Raw events go straight to the wasm game (src/web.zig), which owns key
// bindings, the menu and everything else.
import { createRenderer, loadWasm } from './gpu.js';

const CONFIG_KEY = 'space4d.cfg';

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
  if (!navigator.gpu) {
    return fail('This page needs WebGPU: a recent Chrome, Edge or Safari, or Firefox on Windows.');
  }
  const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
  if (!adapter) return fail('WebGPU is available but found no usable GPU.');
  const device = await adapter.requestDevice();
  device.lost.then((info) => info.reason !== 'destroyed' && fail('GPU device lost: ' + info.message));
  device.addEventListener('uncapturederror', (e) => fail('GPU error: ' + e.error.message));

  status.textContent = 'Loading…';
  const [bytes, code] = await Promise.all([
    fetch('space4d.wasm').then((r) => r.arrayBuffer()),
    fetch('shaders.wgsl').then((r) => r.text()),
  ]);
  const game = await loadWasm(bytes, (m) => console.log(m), (m) => fail('Crashed: ' + m));
  const z = game.z;
  let saved = '';
  try { saved = localStorage.getItem(CONFIG_KEY) ?? ''; } catch { /* storage blocked */ }
  game.init(saved);

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
  canvas.addEventListener('mousedown', (e) => {
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

  let last = performance.now();
  const tick = (now) => {
    try {
      z.frame((now - last) / 1000);
      last = now;
      renderer.frame(ctx.getCurrentTexture().createView());
      requestAnimationFrame(tick);
    } catch (err) {
      fail('Stopped: ' + err.message);
    }
  };
  requestAnimationFrame(tick);
}

main().catch((err) => fail(err.message));
