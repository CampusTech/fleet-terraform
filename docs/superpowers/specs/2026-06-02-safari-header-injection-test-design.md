# Safari Header-Injection Empirical Test

**Date:** 2026-06-02
**Status:** Approved for build

## Question

When a Safari **App Extension** injects a custom request header via
`SFSafariExtensionHandler.additionalRequestHeaders(for:completionHandler:)`,
what exact header **name** lands on the wire?

Specifically: does Safari emit `X-GoogApps-Allowed-Domains` intact, or rewrite it
to `X-Safari-Extension-<org>.<app>.<ext>-<sig>-X-GoogApps-Allowed-Domains`?

This decides whether Safari can ever deliver Google's
`X-GoogApps-Allowed-Domains` Workspace-restriction header (Google's edge matches
the literal name; a prefixed variant is ignored).

## Why empirical

`SFSafariExtensionHandler` lives in Apple's closed `SafariServices.framework`,
not the open WebKit tree. The prefixing behavior is documented only by
practitioner observation ([Carroll/Medium]). The highest-confidence check
available for closed Apple code is observing the actual bytes received.

## Background (already settled from primary sources)

- WebExtension `declarativeNetRequest` `modifyHeaders` **rejects** custom header
  names ("The header `Foo` is not recognized.") — WebKit bug #290922, open.
  So the WebExtension path is already dead for custom headers.
- The App Extension `additionalRequestHeaders` path is the only Safari mechanism
  that *accepts* a custom header — this test checks whether it preserves the name.

## Components

1. **Python echo server** (`echo_server.py`) — stdlib only, HTTP on
   `127.0.0.1:8080`. Reflects all received request headers as JSON in the body
   and logs them to stdout. NOTE: Python's `http.server` title-cases header
   names, so it is the *backup* view, not authoritative on exact casing/prefix.

2. **ngrok tunnel** — `ngrok http 8080 --url campussafari.ngrok.dev` → reserved
   static `https://campussafari.ngrok.dev` with a valid cert (satisfies the
   HTTPS-only injection constraint per Apple forum #104468). Static host means we
   bake the exact domain into the extension — no wildcard-matching risk. The
   ngrok **local inspector** at `http://127.0.0.1:4040` shows raw headers as
   received — this is the **authoritative** view for the exact header name/prefix.

3. **Safari App Extension + container app** — minimal Xcode project built with
   `xcodebuild`. `additionalRequestHeaders` returns
   `["X-GoogApps-Allowed-Domains": "campus.edu"]`. Info.plist carries the
   undocumented `Allowed Domains for Header Injection` array set to the exact
   host `campussafari.ngrok.dev`.

## Flow

```text
Safari → GET https://campussafari.ngrok.dev/  (extension injects header)
       → ngrok edge (valid TLS) → 127.0.0.1:8080
       → echo server logs + returns received headers
Read header NAME via ngrok inspector (primary) + echo JSON (backup)
```

## Interpretation

- Name arrives as `X-Googapps-Allowed-Domains` → **prefix refuted**; Safari
  preserves the name; approach becomes viable; reopen the recommendation.
- Name arrives prefixed `X-Safari-Extension-…-` → **prefix confirmed**;
  definitively dead; matches the Medium claim.
- Header **absent** → injection didn't fire (allowed-domains mismatch, or
  App-Extension-on-Tahoe regression). Debug the harness, do not conclude.

## Caveats on the record

- Safari App Extensions are **deprecated** by Apple in favor of WebExtensions.
  On macOS 26.5 (Tahoe) the API still compiles, but if it won't load at all,
  that is itself a finding (path dead on current macOS regardless of prefixing).
- No MDM force-enable exists for App Extensions: enabling requires a manual
  one-time grant in Safari Settings → Extensions + per-site permission. Even a
  PASS here does not yield silent fleet enforcement.

## Manual steps (operator)

1. `python3 echo_server.py` and `ngrok http 8000` (note the https URL).
2. Build + open the container app once.
3. Safari → Settings → Extensions → enable, grant permission on the ngrok host.
4. Visit the ngrok https URL; read headers in ngrok inspector + echo output.

[Carroll/Medium]: https://medium.com/@christian.carroll.1703/adding-custom-request-headers-with-a-safari-extension-5019874569c3
