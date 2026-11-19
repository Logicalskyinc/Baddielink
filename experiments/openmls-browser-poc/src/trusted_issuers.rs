//! Build-controlled device-registration trust anchors.
//!
//! The browser page and worker message protocol cannot provide or override
//! issuer keys. Production/default builds intentionally contain no issuer and
//! therefore reject every device-registration attestation. The test issuer is
//! compiled only when the explicit `attestation-test-issuer` feature is used.
//! Never enable that feature in production artifacts.

use crate::device_attestation::TrustedIssuerKey;

/// Return the issuer keys pinned into this build. This is deliberately not a
/// WASM export and accepts no caller-supplied configuration.
pub(crate) fn configured_issuers() -> Vec<TrustedIssuerKey> {
    #[cfg(all(feature = "attestation-test-issuer", not(target_arch = "wasm32")))]
    {
        return vec![TrustedIssuerKey {
            key_id: b"test-issuer-key-1".to_vec(),
            // P-256 public key derived from the deterministic test-only
            // private scalar [9; 32]. Never use this key outside tests.
            public_key: vec![
                0x04, 0x71, 0x35, 0xfa, 0x4f, 0xd9, 0x3a, 0x09,
                0xdc, 0xe9, 0x8b, 0xbf, 0x68, 0x1b, 0x4b, 0xfc,
                0xf5, 0x0e, 0x7c, 0x0d, 0x63, 0x54, 0xe6, 0x2a,
                0xfb, 0x0b, 0xff, 0x2a, 0x34, 0x29, 0x61, 0x78,
                0x65, 0xed, 0x4c, 0x1f, 0x02, 0xdd, 0xb9, 0x02,
                0x3e, 0xe5, 0x6a, 0x55, 0x7e, 0x51, 0x5d, 0x6a,
                0x9d, 0xc6, 0x6c, 0x11, 0xf2, 0x20, 0x96, 0x0d,
                0xe5, 0x94, 0x33, 0x4d, 0xf5, 0x88, 0x77, 0x67,
                0x24,
            ],
            issuer: "baddielink-test-issuer".to_owned(),
        }];
    }

    #[cfg(not(all(feature = "attestation-test-issuer", not(target_arch = "wasm32"))))]
    {
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_build_has_no_trusted_issuer() {
        #[cfg(not(feature = "attestation-test-issuer"))]
        assert!(configured_issuers().is_empty());
    }

    #[test]
    fn test_issuer_is_present_only_when_explicit_feature_is_enabled() {
        #[cfg(feature = "attestation-test-issuer")]
        {
            let issuers = configured_issuers();
            assert_eq!(issuers.len(), 1);
            assert_eq!(issuers[0].key_id, b"test-issuer-key-1");
            assert_eq!(issuers[0].issuer, "baddielink-test-issuer");
            assert_eq!(issuers[0].public_key.len(), 65);
        }
    }
}
