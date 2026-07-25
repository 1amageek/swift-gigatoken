import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";

const modulePath = process.argv[2];
if (modulePath === undefined) {
  throw new Error("Usage: node run-wasi.mjs <module.wasm>");
}

const wasi = new WASI({
  version: "preview1",
  args: [modulePath],
  env: {},
  stdin: 0,
  stdout: 1,
  stderr: 2,
  returnOnExit: true,
});
const bytes = await readFile(modulePath);
const { instance } = await WebAssembly.instantiate(bytes, {
  wasi_snapshot_preview1: wasi.wasiImport,
});
const exitCode = wasi.start(instance);
if (exitCode !== 0) {
  throw new Error(`WASI module exited with status ${exitCode}: ${modulePath}`);
}
console.log(`wasi-run: ok ${modulePath}`);
