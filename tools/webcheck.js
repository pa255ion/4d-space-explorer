// Headless test of the browser build (zig-out/web) with Deno's WebGPU:
//   --check          compare the WGSL terrain with the Zig CPU mirror (wasm)
//   --shot OUT.ppm   render one frame, like `space4d --shot`
//   --config "k v;k v"  settings lines (same names as the config file)
//   --sim SECONDS    simulate before rendering
//   --press SC       press and release a key (SDL scancode), e.g. 53 = ` menu
// Run via `zig build webcheck -- ARGS` (builds zig-out/web first).
import { createRenderer, loadWasm } from '../web/gpu.js';

const args = [...Deno.args];
const opt = { check: false, shot: null, config: '', sim: 0, press: [] };
while (args.length) {
  const a = args.shift();
  if (a === '--check') opt.check = true;
  else if (a === '--shot') opt.shot = args.shift();
  else if (a === '--config') opt.config = args.shift().replaceAll(';', '\n');
  else if (a === '--sim') opt.sim = Number(args.shift());
  else if (a === '--press') opt.press.push(Number(args.shift()));
  else throw new Error('unknown argument ' + a);
}

const dir = new URL('../zig-out/web/', import.meta.url);
const bytes = await Deno.readFile(new URL('space4d.wasm', dir));
const code = await Deno.readTextFile(new URL('shaders.wgsl', dir));

const adapter = await navigator.gpu.requestAdapter({ powerPreference: 'high-performance' });
if (!adapter) throw new Error('no WebGPU adapter (is libvulkan on LD_LIBRARY_PATH?)');
const device = await adapter.requestDevice();
let failed = false;
// Report validation errors per phase (they are otherwise asynchronous).
device.pushErrorScope('validation');
async function phase(name) {
  const err = await device.popErrorScope();
  if (err) {
    console.error(`WebGPU validation error in ${name}: ${err.message}`);
    failed = true;
  }
  device.pushErrorScope('validation');
}

const game = await loadWasm(bytes, (m) => console.log(m), (m) => { throw new Error('wasm panic: ' + m); });
const z = game.z;
game.init('render_scale 5\n' + opt.config);
z.setCaptured(true);
if (opt.sim) z.simulate(opt.sim);
for (const sc of opt.press) {
  z.keyDown(sc, false);
  z.keyUp(sc);
}
z.frame(1 / 60);

const W = z.hudWidth(), H = z.hudHeight();
const r = await createRenderer(device, code, z, 'rgba8unorm');
await phase('pipeline setup');
const target = device.createTexture({
  size: [W, H], format: 'rgba8unorm', usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.COPY_SRC,
});
r.frame(target.createView()); // warm-up (also uploads params)
await device.queue.onSubmittedWorkDone();
// GPU throughput: frames in small batches (completion callbacks are slow to
// arrive, and queueing many frames at once exhausts upload staging memory).
const frames = 24;
const t0 = performance.now();
for (let i = 0; i < frames; i++) {
  r.frame(target.createView());
  if (i % 4 === 3) await device.queue.onSubmittedWorkDone();
}
const ms = (performance.now() - t0) / frames;
await phase('frame');

if (opt.shot) {
  const readback = device.createBuffer({ size: W * H * 4, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ });
  const enc = device.createCommandEncoder();
  enc.copyTextureToBuffer({ texture: target }, { buffer: readback, bytesPerRow: W * 4 }, [W, H]);
  device.queue.submit([enc.finish()]);
  await readback.mapAsync(GPUMapMode.READ);
  const px = new Uint8Array(readback.getMappedRange());
  const header = new TextEncoder().encode(`P6\n${W} ${H}\n255\n`);
  const out = new Uint8Array(header.length + W * H * 3);
  out.set(header);
  for (let i = 0, o = header.length; i < W * H; i++, o += 3) out.set(px.subarray(i * 4, i * 4 + 3), o);
  await Deno.writeFile(opt.shot, out);
  await phase('readback');
  console.log(`wrote ${opt.shot}: frame ${ms.toFixed(1)} ms at ${z.renderWidth()}x${z.renderHeight()}`);
}

if (opt.check) {
  const count = 4096;
  const dirs = new Float32Array(z.memory.buffer, z.probeDirsPtr(), count * 4);
  let seed = 7;
  const rnd = () => ((seed = (seed * 1103515245 + 12345) >>> 0) / 4294967296);
  const gauss = () => Math.sqrt(-2 * Math.log(rnd() + 1e-12)) * Math.cos(2 * Math.PI * rnd());
  for (let i = 0; i < count; i++) {
    const v = [gauss(), gauss(), gauss(), gauss()];
    const l = Math.hypot(...v);
    for (let k = 0; k < 4; k++) dirs[i * 4 + k] = v[k] / l;
  }
  const dirBuf = device.createBuffer({ size: count * 16, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
  device.queue.writeBuffer(dirBuf, 0, dirs);
  const outBuf = device.createBuffer({ size: count * 4, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC });
  const probeBuf = device.createBuffer({ size: 12, usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST });
  const readback = device.createBuffer({ size: count * 4, usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ });
  const pipeline = await device.createComputePipelineAsync({ layout: 'auto', compute: { module: r.module, entryPoint: 'terrain_probe' } });
  const bind = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries: [[0, r.params], [6, dirBuf], [7, outBuf], [8, probeBuf]].map(([binding, buffer]) => ({ binding, resource: { buffer } })),
  });
  let worst = 0;
  for (let body = 1; body < z.numBodies(); body++) {
    device.queue.writeBuffer(probeBuf, 0, new Int32Array([count, body, z.maxOctaves()]));
    const enc = device.createCommandEncoder();
    const pass = enc.beginComputePass();
    pass.setPipeline(pipeline);
    pass.setBindGroup(0, bind);
    pass.dispatchWorkgroups(Math.ceil(count / 64));
    pass.end();
    enc.copyBufferToBuffer(outBuf, 0, readback, 0, count * 4);
    device.queue.submit([enc.finish()]);
    await readback.mapAsync(GPUMapMode.READ);
    const gpu = new Float32Array(readback.getMappedRange()).slice();
    readback.unmap();
    await phase('terrain probe');
    z.probeCpu(body, z.maxOctaves(), count);
    const cpu = new Float32Array(z.memory.buffer, z.probeOutPtr(), count);
    for (let i = 0; i < count; i++) worst = Math.max(worst, Math.abs(cpu[i] - gpu[i]));
  }
  console.log(`CPU (wasm) vs GPU (WGSL) terrain: max abs difference ${worst.toFixed(6)} m over ${count} samples per body`);
  if (!(worst <= 0.01)) failed = true;
}

await phase('end');
Deno.exit(failed ? 1 : 0);
