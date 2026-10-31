// The public half of the key that signs desktop update manifests (Ed25519, SPKI DER in base64). The release workflow
// holds the private half as the DESKTOP_UPDATE_KEY secret. Without a key here, the app only opens the release page.
// scripts/update-signing-key.mjs writes this file; replacing the key means copies already installed stop updating.
export const UPDATE_PUBLIC_KEY = 'MCowBQYDK2VwAyEAPWsvWDqRXOpUIIeTLH9+6CQSjWZI74iFLSDY4xqN8C8=';
