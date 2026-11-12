# Feature request: sign browser-session cookies from the persisted secret (removes paste-auth-link and restart-to-auth flows)

> Drop this text into a new issue / discussion at
> https://github.com/Vithrive/Deepseek-Harness-for-VS-Code/issues/new
> and attach `dsh-gateway.mjs` as proof of concept.

---

## Current pain

`dsh web` (0.2.x) issues a **per-process launch token**: it is randomly
generated at every start, printed exactly once, and is the only credential
that can mint a browser-session cookie. The extension can obtain it in only
two ways:

1. Starting dsh itself and capturing `dsh web: ...?token=` from stdout, or
2. Asking the user to paste an auth link.

This produces a recurring conflict whenever dsh was started outside the
extension (terminal, desktop shortcut, autostart):

```
panel cannot authenticate
  → a "Restart and auto-authenticate" prompt (the recommended action)
  → restartDsh() → freePort() force-kills whatever listens on 3080
  → every browser session and other client disconnects
```

There is also a cache-miss trap: the token cache is validated with
`cache.target === getUrl()`. If the user puts a `?token=…` URL into
`dshPanel.url` (a very natural thing to copy from the browser address bar),
the target drifts on every dsh restart and the cache can never hit again.

## Proposal

dsh already persists the browser-session **signing secret** in
`~/.dsh/.credentials.yaml` (`client-connection/browser-session.secret`,
32 bytes). The auth side accepts cookies signed with that secret — this is
exactly why a browser stays logged in for 30 days across dsh restarts.
The secret does not change per-process, so the extension can skip token
exchange entirely and **sign cookies itself** for the authority it needs:

- payload: `{version: 1, authority, issuedAt, expiresAt}`
- cookie value: `v1.<base64url(payload JSON)>.<base64url(HMAC-SHA256(secret, body))>`
- cookie name: `dsh-auth-` + base64url(sha256(authority))
- secret: base64url-decoded 32 bytes; cache it keyed on the file mtime so a
  rotation is picked up automatically
- lifetime: 29 days (just under dsh's default 30 to avoid boundary expiry)

## What this removes

- the entire "paste auth link" flow and its prompts
- the restart-to-auth path for externally started instances — `freePort()`
  no longer fires during normal use, so background browser sessions survive
- the token-cache target-drift trap (no token in `dshPanel.url` at all)
- per-window auth friction: multiple VS Code windows and browsers coexist

## Proof of concept

A ~200-line standalone proxy (Node core modules only, zero dependencies)
does exactly this today; verified on dsh 0.2.1-rc.3 + extension 1.1.1:

- `GET /` through the proxy: **200** (54 KB page) while direct `GET /` is 401
- WebSocket `/api/remote.mux` through the proxy: **101 upgrade**; direct: 401
- dsh restarted → clients keep working, zero re-auth
- non-loopback `Host:` → 403 (the proxy only signs loopback authorities)

Attached as `dsh-gateway.mjs`.

## Security considerations

Whatever signs cookies holds the same power as the launch token, so the
signer must:

- listen on loopback only (refuse non-loopback binds),
- sign only for loopback authorities (`127.0.0.1` / `localhost` / `::1`;
  anything else → 403, with an explicit allow-list if ever needed),
- keep all upstream checks intact (Host/Origin fence, cross-site rejection) —
  only the missing cookie is injected.

The extension already has `isLocalLoopbackTarget()`; the same policy applies.
