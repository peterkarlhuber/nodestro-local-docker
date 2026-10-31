# Browser sessions: design (D1)

This is the design for how a browser signs in to Nodestro Local Docker and stays signed in. It closes finding D1 of
the internal cross-check ([SECURITY-REVIEW.md](SECURITY-REVIEW.md), section 9.3): the session cookie reached every
web server on `localhost`. It is implemented in nodestro-api (`launch.py`, `local_access.py`, `local_container.py`)
and in the launchers.

## 1. The problem

Browsers decide which cookies to send by **host name**, not by port (RFC 6265, section 8.5). A cookie that
`http://127.0.0.1:8765` sets is also sent to `http://127.0.0.1:3000`. The same holds for `localhost`, and for every
other name. So when the user opens the page of any other local program under the same name, that program's server
receives the Nodestro session cookie. It can then use the session from a non-browser client, where the Origin check
does not apply. `HttpOnly`, `SameSite=Strict` and the Origin check do not prevent this.

There are two kinds of attacker:

- **Passive.** Another local web server that the user opens anyway, such as a development server on
  `localhost:3000`.
- **Active.** A local program that knows the studio's host name and gets the user to open
  `http://<that name>:<its own port>`, for example through a link.

## 2. Options considered

| Option | Passive | Active | Cost | Decision |
| --- | --- | --- | --- | --- |
| A. Keep `127.0.0.1`, rely on the Origin check | no | no | none | rejected (the D1 state) |
| B. A fixed dedicated name, e.g. `nodestro.localhost` | yes | no: the name is public | small | not enough on its own |
| C. **A random dedicated name per installation**, `nodestro-<random>.localhost` | yes | yes, as long as the name stays private | small | **chosen** |
| D. A session proof in origin-scoped storage (`sessionStorage`), sent as a header with every request | yes | yes | large: every download link, image and EventSource in the studio would need it, in all three modes | possible later step |
| E. HTTPS with `__Host-` cookies | no: still host-scoped, not port-scoped | no | a local CA in the user's trust store | rejected |
| F. A cookie per port, or a `Path` restriction | no | no | small | does not work: browsers send all cookies of the host |

**Why C.** A cookie set for `nodestro-k3f9x2ab7q.localhost` is sent only to that exact name. Other local programs
are reached as `localhost`, `127.0.0.1` or names of their own, and never receive it. An active attacker would have to
know the random name to send the user there. Nothing in the studio front end changes, so desktop and server behave
exactly as before.

## 3. The design

1. **Dedicated host name.**
   - On first start, `nodestro-local serve` creates `nodestro-<10 random lowercase letters and digits>.localhost`
     (about 50 bits) and stores it in `/var/lib/nodestro/secrets/browser-host`, mode 0600, next to the access key.
   - `nodestro-local link` and the launchers open `http://<that name>:<port>/api/launch?token=<key>`.
   - Browsers resolve every `*.localhost` name to the loopback address themselves (RFC 6761), so no DNS or hosts
     file is involved.
2. **Sessions only under that name.**
   - `/api/launch` is answered only when the request's `Host` is that name; on any other name it gets 403.
   - A session cookie is accepted only under that name. So no cookie is ever set for, or sent to, `127.0.0.1` or
     `localhost`.
   - Scripts with `Authorization: Bearer <key>` keep working under every loopback name.
   - The cookie stays `HttpOnly; SameSite=Strict; Path=/`, without a `Domain` attribute, so it is host-only.
3. **Keeping the name private.**
   - Every response carries `Referrer-Policy: no-referrer`, so links from the studio to other sites do not reveal it.
   - The name is never logged, and `./nodestro rotate-key` replaces it together with the access key.
4. **Lifetime.**
   - A session ends after 8 hours without a request (`NODESTRO_SESSION_IDLE_HOURS`) and at the latest 24 hours after
     it was opened (`NODESTRO_SESSION_MAX_HOURS`).
   - Sessions are kept in memory: a restart ends them all, as does `rotate-key`.
   - At most 64 sessions exist; the oldest is dropped first.
5. **Logout.**
   - `GET /api/logout` shows a small page with a "Sign out" button; it is the URL to bookmark.
   - The button posts to `POST /api/logout`, which ends this browser's session and deletes the cookie (`Max-Age=0`).
     It is protected by the strict Origin check, so another page cannot sign the user out.
   - `./nodestro logout` (and `.\nodestro.ps1 logout`) ends every browser session through
     `POST /api/logout?all=1` with the access key.
6. **Host and port (D3).** Only loopback names whose port is the published port (`NODESTRO_HOST_PORT`) or the
   container's own port 8080 (the launcher's and health check's calls from inside the container) are answered. Any
   other port in `Host` gets 403.

## 4. Compatibility

| Browser | `*.localhost` | Status |
| --- | --- | --- |
| Chrome, Edge (Windows, macOS, Linux) | resolved to loopback by the browser | Expected to work. The end-to-end tests check the server side only. |
| Firefox (84 and later) | resolved to loopback by the browser | Expected to work, not tested. |
| Safari | not verified | **Untested.** If the name does not open, set `NODESTRO_BROWSER_HOST=127.0.0.1` and accept residual risk 3 as it stood before. |

- With Docker Desktop on Windows and macOS, the published port is `127.0.0.1:<port>`. A browser that tries `::1`
  first falls back to `127.0.0.1`.
- `NODESTRO_BROWSER_HOST` may be set to another loopback name or address. That gives up the protection of the
  random name, and the launcher says so.

## 5. Residual risk

- A local program that learns the random name, for example from the user's browser history, can still collect
  the cookie by getting the user to open that name on its own port. Such a program usually runs as the same user and
  could read the browser's cookie store directly anyway.
- Option D would close this as well. It is the next step if this residual risk is not acceptable.
- With `NODESTRO_BROWSER_HOST` set to `127.0.0.1` or `localhost`, the protection is gone (section 1).
