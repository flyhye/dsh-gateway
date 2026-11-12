# dsh-gateway — passwordless dsh web for browser AND VS Code at the same time

A ~200-line Node.js reverse proxy that fixes a common pain point of
dsh web 0.2.x: **the browser and the VS Code panel cannot both use dsh
without fighting over a one-time launch token**.

- Node.js core modules only — zero dependencies
- Listens on 127.0.0.1 only
- Survives dsh restarts: no re-auth, nothing to paste, ever
- Any number of clients at the same time

## Background: why the problem exists

dsh web (>= 0.2.x) requires a signed session cookie on every page/API
request, and the only credential that can mint one is a **per-process
launch token** — regenerated on every `dsh web` start, printed exactly once.

So every new client hits the same chain:

```
VS Code panel has no token
  → "cannot authenticate" prompt
  → user clicks "restart and auto-authenticate"
  → the extension force-kills the dsh instance on port 3080 and starts its own
  → every browser session in progress is disconnected
```

Pasting an auth link only works until the next dsh restart.

## How it works

dsh persists a browser-session **signing secret** in
`~/.dsh/.credentials.yaml` (32 bytes, set once at first install, never
rotated automatically). dsh's auth accepts cookies **signed with that
secret on the fly** — that is why a browser stays logged in for 30 days.

The gateway leverages exactly that: on every request it signs a fresh
cookie for the request's own Host authority and injects it upstream.
Persistent secret ⇒ valid cookies forever ⇒ **dsh restarts are invisible
to clients**.

```
 browser ──────┐
               ▼
         gateway 127.0.0.1:3090 ──signs cookie──► dsh web 127.0.0.1:3080
               ▲
 VS Code panel ┘
```

All upstream security checks (Host/Origin fence, cross-site rejection)
stay intact — the gateway only injects the missing cookie.

## Install

Prerequisites: Node.js and `@deepseek-ai/dsh` (`npm install -g`).

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

It will:

1. install the scripts into `~/.dsh/bin`
2. create a desktop shortcut "DeepSeek Harness" (starts dsh + gateway + browser)
3. print the one line you need in VS Code `settings.json`
4. start everything and self-check

## VS Code settings

One line in `settings.json`:

```json
{ "dshPanel.url": "http://127.0.0.1:3090" }
```

**No token, no `autoStart`.** The extension probes the gateway, gets 200,
and skips its whole auth flow — no prompt, and it never kills a running dsh.

## Daily use

| Scenario | Action |
|---|---|
| Start | double-click the desktop shortcut (or `~/.dsh/bin/start-dsh.ps1`) |
| VS Code panel | just open it — passwordless |
| Browser | open `http://127.0.0.1:3090` — passwordless |
| After a dsh restart | do nothing |
| Stop | `powershell -File ~/.dsh/bin/stop-dsh.ps1` |

Custom ports: `start-dsh.ps1 -Port 3080 -GatewayPort 3090`.

## Security boundary

- **Loopback only**: the gateway refuses to bind a non-loopback address.
  Reaching this port = being the same local user = equivalent rights to
  holding the dsh launch link.
- **Signs only loopback authorities**: `127.0.0.1` / `localhost` / `::1`;
  any other Host gets 403 (opt-in extra hosts via
  `DSH_GATEWAY_ALLOW_HOSTS=my-box.lan`).
- Not a trampoline for external reverse proxies; upstream checks are preserved.
- **Never share your `~/.dsh/.credentials.yaml`** — it is the key to your
  dsh account.

## Compatibility

- Matches the dsh 0.2.x cookie format (`v1` payload + HMAC-SHA256 +
  base64url, cookie name = `dsh-auth-` + sha256(authority)). If a future
  dsh version changes the format, update `cookieFor()` accordingly.
- The secret is cached by file mtime: if dsh rotates the credentials file,
  the next request picks up the new secret without restarting the gateway.

## FAQ

**Gateway returns 502?** Upstream dsh is not up (yet) or the port is wrong.
Check `~/.dsh/gateway-<port>.log`, and confirm dsh is running:
`curl -I http://127.0.0.1:3080/` (401 still means "running").

**VS Code panel is blank?** Make sure `dshPanel.url` points at the
**gateway port** (3090), not 3080, and has no `?token=`. Then run
`Developer: Reload Window`.

**Port already in use?** Pick another: `start-dsh.ps1 -GatewayPort 3091`,
and update `dshPanel.url` to match.

**Remote server / multiple machines?** The gateway serves the local machine
only. For remote setups use SSH port forwarding instead of allowing
non-loopback hosts.

## Uninstall

Delete the desktop shortcut and these files in `~/.dsh/bin`:
`dsh-gateway.mjs`, `start-dsh.ps1`, `start-dsh.vbs`, `stop-dsh.ps1`,
then restore your previous `dshPanel.url`.
