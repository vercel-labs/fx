// Run with bun tests/e2e/fixtures/generate-oidc.ts from the repository root.
// Generate public test vectors with a new throwaway key; never save the private key.
import { generateKeyPairSync, sign } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";

const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = {
  ...publicKey.export({ format: "jwk" }),
  kid: "fx-identity-fixture",
  alg: "RS256",
  use: "sig",
  key_ops: ["verify"],
};
const header = { alg: "RS256", kid: jwk.kid, typ: "JWT" };
const claims = {
  iss: "https://issuer.example",
  sub: "fixture-member",
  aud: "fx-desktop",
  iat: 1_799_999_990,
  exp: 1_800_000_600,
  nonce: "authorization-attempt",
};
function token(payload: object, protectedHeader: object = header) {
  const segments = [protectedHeader, payload].map((value) =>
    Buffer.from(JSON.stringify(value)).toString("base64url"),
  );
  const message = segments.join(".");
  return `${message}.${sign("RSA-SHA256", Buffer.from(message), privateKey).toString("base64url")}`;
}
const cases: { name: string; token: string; failure?: string }[] = [
  { name: "valid", token: token(claims) },
  { name: "array audience", token: token({ ...claims, aud: [claims.aud] }) },
  { name: "authorized party", token: token({ ...claims, azp: claims.aud }) },
];
for (const [name, patch, failure] of [
  ["issuer", { iss: "https://untrusted.example" }, "WrongIssuer"],
  ["audience", { aud: "another-client" }, "WrongAudience"],
  ["additional audience", { aud: [claims.aud, "another-client"] }, "WrongAudience"],
  ["authorized party", { azp: "another-client" }, "WrongAudience"],
  ["nonce", { nonce: "another-attempt" }, "NonceMismatch"],
  ["missing nonce", { nonce: undefined }, "NonceMismatch"],
  ["expiry boundary", { exp: 1_800_000_000 }, "Expired"],
  ["future issue", { iat: 1_800_000_061 }, "InvalidTokenTime"],
  ["not before", { nbf: 1_800_000_001 }, "InvalidTokenTime"],
  ["missing subject", { sub: undefined }, "InvalidIdentityDocument"],
  ["empty subject", { sub: "" }, "InvalidSubject"],
] as const) {
  cases.push({ name, token: token({ ...claims, ...patch }), failure });
}
cases.push({ name: "algorithm", token: token(claims, { ...header, alg: "HS256" }), failure: "UnsupportedIdentityAlgorithm" });
cases.push({ name: "critical extension", token: token(claims, { ...header, crit: ["example"] }), failure: "UnsupportedIdentityAlgorithm" });
const forged = cases[0].token.split(".");
const signature = Buffer.from(forged[2], "base64url");
signature[0] ^= 1;
forged[2] = signature.toString("base64url");
cases.push({ name: "forged signature", token: forged.join("."), failure: "BadSignature" });
const destination = new URL("../../../src/core/auth/testdata/oidc.json", import.meta.url);
mkdirSync(new URL(".", destination), { recursive: true });
writeFileSync(destination, JSON.stringify({ jwks: JSON.stringify({ keys: [jwk] }), cases }, null, 2) + "\n");
console.log(`Generated ${cases.length} signed OIDC test cases; private key discarded.`);
