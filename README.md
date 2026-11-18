# interview-copilot_workbench

Run the whole Interview Co-Pilot system locally with Docker Compose. **For local testing only, not production.**

```
cp .env.example .env     # replace every CHANGE_ME (use random values)
make up                  # builds each service from GitHub and waits until healthy
make smoke
```

Open http://localhost:8080 and sign in on the app's own page as `journalist` with `TEST_USER_PASSWORD` from your `.env`.

To build from local sibling checkouts, copy `compose.override.example.yaml` to `compose.override.yaml`.

## Reset emails

Password-reset emails go to Mailpit, a local mail catcher (nothing is delivered). Open http://localhost:8025 to read them.

## Keys

Deepgram and Anthropic keys are needed for the live loop (milestones 2+); audio goes from the browser straight to Deepgram, so the browser needs internet access. Nothing secret is committed; `.env` is gitignored. No Anthropic key or credit? Set `COMPOSE_PROFILES=fake-llm` and `ANTHROPIC_BASE_URL=http://fake-llm:8080` in `.env` to use a stand-in model that checks the plumbing (not suggestion quality).

## Topology

Separate Compose networks stop the layers being skipped: `web` (frontend, edge-gateway, keycloak), `edge-bff`, `bff-internal`, `internal-backend`, `data`, one `auth-*` network per service that talks to the IdP, and `egress` (backend only). Only the frontend (8080) and Keycloak (8081) ports are published. `make smoke` proves the BFF cannot reach the backend directly and nothing but the edge gateway reaches the BFF.

**Issuer URL:** Keycloak runs with a fixed public hostname (`KC_HOSTNAME=http://localhost:8081`), so `iss` is the same for the browser and for services. Services validate `iss` against that public issuer and fetch keys from `http://keycloak:8080/...` (`OIDC_JWKS_URI`).

`make clean` removes containers, networks and volumes. Local AWS emulation is [MiniStack](https://ministack.org). Licence: Apache-2.0.
