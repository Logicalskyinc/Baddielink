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
                0x04, 0xea, 0x68, 0xd7, 0xb6, 0xfe, 0xdf, 0x0b,
                0x71, 0x87, 0x89, 0x38, 0xd5, 0x1d, 0x71, 0xf8,
                0x72, 0x9e, 0x0a, 0xcb, 0x8c, 0x2c, 0x6d, 0xf8,
                0xb3, 0xd7, 0x9e, 0x8a, 0x4b, 0x90, 0x94, 0x9e,
                0xe0, 0x2a, 0x27, 0x44, 0xc9, 0x72, 0xc9, 0xfc,
                0xe7, 0x87, 0x01, 0x4a, 0x96, 0x4a, 0x8e, 0xa0,
                0xc8, 0x4d, 0x71, 0x4f, 0xea, 0xa4, 0xde, 0x82,
                0x3f, 0xe8, 0x5a, 0x22, 0x4a, 0x4d, 0xd0, 0x48,
                0xfa,
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
