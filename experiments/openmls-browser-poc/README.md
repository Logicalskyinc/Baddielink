# OpenMLS browser proof of concept

**Status:** Experimental scaffold only. Not integrated into BaddieLink and not approved for production use.

This isolated crate evaluates whether the OpenMLS Messaging Layer Security (MLS) implementation can run in BaddieLink's browser-first frontend through WebAssembly. The wrapper and sample harness are adapted from upstream OpenMLS revision `bcde2afd3d1fb6045753b544ea290605081abe20`; see `NOTICE.md` and `LICENSE`. It is based on the upstream OpenMLS `openmls-wasm` experiment, with the workspace path dependencies changed to versioned crates.io dependencies.

## Why this exists

BaddieLink's current frontend is plain HTML, CSS and JavaScript with no build pipeline. OpenMLS is a Rust implementation of MLS. Its upstream repository includes a WebAssembly bindings experiment and browser demo, but the upstream project lists `wasm32-unknown-unknown` as built on CI and not tested on CI. This folder isolates that evaluation from the member application.

## Run locally

Prerequisites:
- Rust toolchain compatible with OpenMLS 0.9.0.
- `wasm32-unknown-unknown` Rust target.
- `wasm-pack`.
- A modern browser with WebAssembly and Web Crypto support.

From this directory:

```sh
rustup target add wasm32-unknown-unknown
cargo install wasm-pack
./build.sh
```

Then serve the generated `pkg/` directory over localhost using a static HTTP server and open `/index.html`. Do not open it using a `file://` URL. The build script copies the browser harness beside the generated WebAssembly JavaScript and binary files.

## What this first harness checks

- WebAssembly module initialization in a browser.
- Local identity creation for multiple participants.
- MLS group creation and invitation of another member.
- Group membership update propagation.
- Encryption and decryption of an application message between group members.
- Matching exported group secrets for participants in the same group epoch.

## Known limitations

- The upstream sample provider uses in-memory storage. State is lost when the page reloads. Persistent, encrypted client-side state is a separate required test.
- This sample is not a complete chat protocol integration. It does not implement a delivery service, account/device binding, key transparency, secure recovery, offline delivery, attachment encryption, push notification handling, or membership revocation UX.
- The upstream sample contains demonstration-only panic paths and incomplete handling for some MLS message types. It must not be exposed to real user data.
- No message content should be sent to Supabase from this experiment.
- Do not add this experiment to the production page or deploy it.

## Acceptance gates before protocol selection

1. Compile the crate for `wasm32-unknown-unknown`.
2. Run browser tests on desktop Chromium and Firefox.
3. Test the target mobile browser, including iOS Safari.
4. Measure compressed WASM size, cold-start time and memory use on a low-end mobile device.
5. Add persistent encrypted MLS state and verify reload/restart behavior.
6. Test add/remove membership, stale epochs, replay rejection, device replacement and recovery.
7. Complete an independent security review before any production E2EE claim.

## Upstream references

- OpenMLS: https://github.com/openmls/openmls
- Upstream WebAssembly experiment: https://github.com/openmls/openmls/tree/main/openmls-wasm
- MLS standard, RFC 9420: https://datatracker.ietf.org/doc/rfc9420/

The upstream OpenMLS WebAssembly sample is MIT-licensed. Its source attribution and license are retained in this experimental folder.
