import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";

const modulePath = process.argv[2];
if (modulePath === undefined) {
  throw new Error("Usage: node run-wasi.mjs <module.wasm>");
}

const wasi = new WASI({
  version: "preview1",
  args: [],
  env: {},
});
const bytes = await readFile(modulePath);
const { instance } = await WebAssembly.instantiate(bytes, {
  wasi_snapshot_preview1: wasi.wasiImport,
});
wasi.start(instance);
console.log(`wasi-smoke: ok ${modulePath}`);
