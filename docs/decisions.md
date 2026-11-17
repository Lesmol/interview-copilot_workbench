# Decisions

- **Local S3 store: MiniStack instead of MinIO.** MinIO's container images are no longer pulled from Docker Hub or Quay. MiniStack (`ministackorg/ministack`, MIT) provides the S3 API on port 4566; the backend only sees `S3_ENDPOINT`. A one-shot `s3-init` service creates the `transcripts` bucket. Its dummy credentials (`test`/`test`) are not secrets.
- **One auth network per service instead of a shared `auth` network.** REPOS.md describes a single `auth` network; with it the BFF could reach the backend directly, defeating the gateways. Keycloak joins `auth-edge`, `auth-bff`, `auth-internal` and `auth-backend`, each shared with exactly one service. The smoke test proves the BFF cannot reach the backend.
- **Direct access grants on the SPA client.** Needed by the app's own sign-in page (password grant) and by `scripts/smoke.sh`. Production (Cognito) needs the equivalent `USER_PASSWORD_AUTH` flow; see the frontend decisions.
- **Extra test user** (`journalist2`) for the cross-user isolation check in milestone 6.
- **Gateway product (proposal): Spring Cloud Gateway (WebFlux)** for both gateways. Verified in tests and the smoke test that requests pass through; SSE pass-through gets a real test once the stream exists (milestone 4).
- **Hosting (proposal, needs approval):** AWS, as the IdP (Cognito) and transcript store (S3) are already there: services on ECS Fargate behind an ALB (edge gateway only), RDS for PostgreSQL, a private S3 bucket with encryption, security groups mirroring the Compose networks.
- **Mailpit** receives password-reset emails (`mail` network is internal; a separate `mail-ui` network lets the host open the UI on port 8025).
- **Realm tweaks for self-service accounts:** `loginWithEmailAllowed`, a 10-character password policy, and a user profile where the last name is optional (sign-up asks for one name).
- **Local IdP admin:** the backend uses Keycloak's master admin for user management; see the backend decisions for why and what production should do.
- **AssemblyAI skipped:** its key variable was removed.
