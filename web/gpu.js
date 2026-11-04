// WebGPU plumbing: buffers, pipelines, and one frame of dispatches. What to
// render is decided by the wasm module `z` (src/web.zig); this only moves
// its parameter block and HUD overlay to the GPU and runs web/shaders.wgsl.
// Shared by app.js (browser) and tools/webcheck.js (headless, Deno).

export async function createRenderer(device, code, z, format) {
  const W = z.hudWidth(), H = z.hudHeight();
  const U = GPUBufferUsage, T = GPUTextureUsage;

  const module = device.createShaderModule({ code });
  const info = await module.getCompilationInfo();
  const errors = info.messages.filter((m) => m.type === 'error');
  if (errors.length) {
    throw new Error('shader: ' + errors.map((m) => `${m.lineNum}:${m.linePos} ${m.message}`).join('\n'));
  }

  const params = device.createBuffer({ label: 'params', size: z.paramsSize(), usage: U.STORAGE | U.COPY_DST });
  const frameTex = device.createTexture({ label: 'frame', size: [W, H], format: 'rgba8unorm', usage: T.STORAGE_BINDING | T.TEXTURE_BINDING });
  const overlay = device.createTexture({ label: 'overlay', size: [W, H], format: 'rgba8unorm', usage: T.TEXTURE_BINDING | T.COPY_DST });
  const blitUniform = device.createBuffer({ label: 'blit', size: 16, usage: U.UNIFORM | U.COPY_DST });
  const lin = device.createSampler({ magFilter: 'linear', minFilter: 'linear' });

  const group = (label, layout, entries) => device.createBindGroup({
    label, layout, entries: entries.map(([binding, resource]) => ({ binding, resource })),
  });
  const pipeline = (entryPoint) => device.createComputePipelineAsync({ layout: 'auto', compute: { module, entryPoint } });
  const [marchP, alphaP, compositeP, sliceP, blit] = await Promise.all([
    pipeline('march_retina'), pipeline('retina_alpha'), pipeline('composite'), pipeline('march_slice'),
    device.createRenderPipelineAsync({
      layout: 'auto',
      vertex: { module, entryPoint: 'blit_vs' },
      fragment: { module, entryPoint: 'blit_fs', targets: [{ format }] },
      primitive: { topology: 'triangle-list' },
    }),
  ]);
  const P = { buffer: params };
  const kernel = (p, label, entries) => ({ pipeline: p, bind: group(label, p.getBindGroupLayout(0), entries) });
  const slice = kernel(sliceP, 'march_slice', [[0, P], [5, frameTex.createView()]]);
  const blitBind = group('blit', blit.getBindGroupLayout(0), [
    [10, { buffer: blitUniform }], [11, frameTex.createView()], [12, overlay.createView()], [13, lin],
  ]);

  // The retina (n^3 rays) and its RGBA volume are sized for the current
  // resolution and reallocated when it changes.
  let retinaN = 0, retina, vol, march, alpha, composite;
  const sizeRetina = (n) => {
    if (n === retinaN) return;
    retina?.destroy();
    vol?.destroy();
    retinaN = n;
    retina = device.createBuffer({ label: 'retina', size: n ** 3 * 16, usage: U.STORAGE });
    vol = device.createTexture({
      label: 'volume', size: [n, n, n], dimension: '3d', format: 'rgba16float',
      usage: T.STORAGE_BINDING | T.TEXTURE_BINDING,
    });
    march = kernel(marchP, 'march_retina', [[0, P], [1, { buffer: retina }]]);
    alpha = kernel(alphaP, 'retina_alpha', [[0, P], [1, { buffer: retina }], [2, vol.createView()]]);
    composite = kernel(compositeP, 'composite', [[0, P], [3, vol.createView()], [4, lin], [5, frameTex.createView()]]);
  };

  const ceil = (a, b) => Math.ceil(a / b);

  return {
    module,
    params,
    /** Render the current game state into `view` (a texture view of `format`). */
    frame(view) {
      const mem = z.memory.buffer;
      device.queue.writeBuffer(params, 0, mem, z.paramsPtr(), z.paramsSize());
      device.queue.writeTexture(
        { texture: overlay }, new Uint8Array(mem, z.overlayPtr(), W * H * 4),
        { bytesPerRow: W * 4, rowsPerImage: H }, [W, H]);
      const rw = z.renderWidth(), rh = z.renderHeight();
      device.queue.writeBuffer(blitUniform, 0, new Float32Array([rw / W, rh / H, W, H]));

      const enc = device.createCommandEncoder();
      const pass = enc.beginComputePass();
      const run = (k, x, y, zz) => {
        pass.setPipeline(k.pipeline);
        pass.setBindGroup(0, k.bind);
        pass.dispatchWorkgroups(x, y, zz);
      };
      if (z.view() === 0) {
        const n = z.retinaN();
        sizeRetina(n);
        run(march, ceil(n, 8), ceil(n, 8), ceil(n, 4));
        run(alpha, ceil(n, 8), ceil(n, 8), ceil(n, 4));
        run(composite, ceil(rw, 16), ceil(rh, 16), 1);
      } else {
        run(slice, ceil(rw, 16), ceil(rh, 16), 1);
      }
      pass.end();
      const rp = enc.beginRenderPass({
        colorAttachments: [{ view, loadOp: 'clear', storeOp: 'store', clearValue: [0, 0, 0, 1] }],
      });
      rp.setPipeline(blit);
      rp.setBindGroup(0, blitBind);
      rp.draw(3);
      rp.end();
      device.queue.submit([enc.finish()]);
    },
  };
}

/** Instantiate the game module. `onLog` / `onPanic` receive strings. */
export async function loadWasm(bytes, onLog, onPanic) {
  let z;
  const str = (p, n) => new TextDecoder().decode(new Uint8Array(z.memory.buffer, p, n));
  const { instance } = await WebAssembly.instantiate(bytes, {
    env: {
      js_log: (p, n) => onLog(str(p, n)),
      js_panic: (p, n) => onPanic(str(p, n)),
    },
  });
  z = instance.exports;
  return {
    z,
    /** Start the game with a saved config text. */
    init(config) {
      const b = new TextEncoder().encode(config).slice(0, z.scratchLen());
      new Uint8Array(z.memory.buffer, z.scratchPtr(), b.length).set(b);
      z.init(b.length);
    },
    settingsText() {
      return str(z.scratchPtr(), z.settingsText());
    },
  };
}
