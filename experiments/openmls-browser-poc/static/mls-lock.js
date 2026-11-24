/**
 * Serializes MLS mutations for one account/device/group across same-origin tabs.
 *
 * Web Locks are intentionally required. If unavailable, callers must fail closed
 * rather than silently running concurrent state mutations.
 */
export async function withMlsGroupLock({ accountId, deviceId, groupId }, operation) {
  if (typeof operation !== "function") {
    throw new TypeError("MLS lock operation must be a function.");
  }

  for (const [name, value] of Object.entries({ accountId, deviceId, groupId })) {
    if (typeof value !== "string" || value.length === 0) {
      throw new TypeError(`MLS lock scope requires a non-empty ${name}.`);
    }
  }

  if (!globalThis.navigator?.locks?.request) {
    throw new Error("Web Locks API is unavailable; refusing an unlocked MLS state mutation.");
  }

  const lockName = [
    "baddielink",
    "mls",
    encodeURIComponent(accountId),
    encodeURIComponent(deviceId),
    encodeURIComponent(groupId),
  ].join(":");

  return globalThis.navigator.locks.request(
    lockName,
    { mode: "exclusive" },
    operation,
  );
}
