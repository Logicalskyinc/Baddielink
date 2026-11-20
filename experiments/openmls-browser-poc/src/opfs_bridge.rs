use js_sys::Uint8Array;
use wasm_bindgen::prelude::*;
#[wasm_bindgen(inline_js = "
export function opfs_write_from_wasm(bytes) {
  if (typeof globalThis.__baddielinkOpfsWrite !== 'function') throw new Error('OPFS write bridge is not installed.');
  globalThis.__baddielinkOpfsWrite(bytes);
}
export function opfs_read_all_from_wasm() {
  if (typeof globalThis.__baddielinkOpfsReadAll !== 'function') throw new Error('OPFS read bridge is not installed.');
  return globalThis.__baddielinkOpfsReadAll();
}
")]
extern "C" {
    #[wasm_bindgen(catch, js_name = opfs_write_from_wasm)]
    fn opfs_write_from_wasm(bytes: &Uint8Array) -> Result<(), JsValue>;
    #[wasm_bindgen(catch, js_name = opfs_read_all_from_wasm)]
    fn opfs_read_all_from_wasm() -> Result<Uint8Array, JsValue>;
}
#[wasm_bindgen]
pub fn opfs_bridge_write(bytes: Uint8Array) -> Result<(), JsError> {
    opfs_write_from_wasm(&bytes).map_err(|error| JsError::new(&format!("OPFS write failed: {error:?}")))
}
#[wasm_bindgen]
pub fn opfs_bridge_read() -> Result<Uint8Array, JsError> {
    opfs_read_all_from_wasm().map_err(|error| JsError::new(&format!("OPFS read failed: {error:?}")))
}
#[wasm_bindgen]
pub fn opfs_bridge_roundtrip(bytes: Uint8Array) -> Result<Uint8Array, JsError> {
    opfs_bridge_write(bytes)?;
    opfs_bridge_read()
}
