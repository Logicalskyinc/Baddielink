use js_sys::Uint8Array;
use wasm_bindgen::prelude::*;

#[wasm_bindgen(inline_js = "
export function opfs_write_from_wasm(bytes) {
  if (typeof globalThis.__baddielinkOpfsWrite !== 'function') {
    throw new Error('OPFS synchronous write bridge is not installed.');
  }
  globalThis.__baddielinkOpfsWrite(bytes);
}
export function opfs_read_into_wasm(length) {
  if (typeof globalThis.__baddielinkOpfsRead !== 'function') {
    throw new Error('OPFS synchronous read bridge is not installed.');
  }
  return globalThis.__baddielinkOpfsRead(length);
}
")]
extern "C" {
    #[wasm_bindgen(catch, js_name = opfs_write_from_wasm)]
    fn opfs_write_from_wasm(bytes: &Uint8Array) -> Result<(), JsValue>;

    #[wasm_bindgen(catch, js_name = opfs_read_into_wasm)]
    fn opfs_read_into_wasm(length: usize) -> Result<Uint8Array, JsValue>;
}

/// Feasibility probe only: synchronously round-trips bytes from WASM through
/// the worker's OPFS FileSystemSyncAccessHandle bridge.
/// This is not an OpenMLS StorageProvider implementation.
#[wasm_bindgen]
pub fn opfs_bridge_roundtrip(bytes: Uint8Array) -> Result<Uint8Array, JsError> {
    opfs_write_from_wasm(&bytes)
        .map_err(|error| JsError::new(&format!("OPFS write bridge failed: {error:?}")))?;
    opfs_read_into_wasm(bytes.length() as usize)
        .map_err(|error| JsError::new(&format!("OPFS read bridge failed: {error:?}")))
}
