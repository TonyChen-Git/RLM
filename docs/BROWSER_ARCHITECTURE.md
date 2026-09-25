# Luma Chat Browser/CDP architecture

Status: Phase E implementation complete; focused Browser/annotation tests and
the combined Phase C–H development gate passed on 2026-09-25 as part of the
744-test LumaChat 1.4.1 development release.

## Runtime ownership

Browser automation is a separate structured capability from Computer Use. Each
Agent Task is bound by `BrowserToolCoordinator` to at most one Browser session.
The binding key contains the Agent session, Task, workspace identity and
canonical repository root; its authority fingerprint also contains the
host-selected profile mode, persistent profile name, or existing-debug endpoint.
Model arguments cannot select a profile, endpoint, repository, or another Task's
session/tab.

Concurrent opens for the same Task are reserved and rejected. Changing Browser
authority closes the old binding before a new session is accepted. Task stop,
pause, authority revocation, deletion and application shutdown close the binding;
an open that completes after revocation is treated as an orphan and immediately
stopped.

## Profiles

The default is a randomly named isolated profile under
`<repository>/tmp/browser/ephemeral`. It owns independent cookies, storage,
cache and credentials and is removed when its managed process ends. A user may
explicitly choose a named persistent profile under
`<repository>/tmp/browser/persistent`; it survives normal session shutdown.

All runtime/profile directories are exact descendants of the repository runtime
root. Symlinks, path traversal, wrong-owner directories and non-directories fail
closed. Current-user legacy directories are repaired to owner-only permissions.
Only an explicit host action can delete a persistent profile.

`Attach Existing Browser` accepts only an explicit normalized loopback HTTP
DevTools origin. It is intentionally higher authority because it may expose an
already authenticated Chrome profile. Attached processes are never terminated,
and downloads are disabled because CDP download policy is browser-global.

## CDP boundary and tools

`BrowserService` launches Chromium with a loopback ephemeral debugging port and
uses bounded WebSocket CDP commands. It supports:

- lifecycle, tabs, navigation/back/forward/reload and bounded readiness;
- bounded DOM/layout projection plus a sanitized Accessibility tree;
- semantic/text/CSS find and DOM actions before any pixel fallback;
- PNG screenshots carried through the existing image-attachment store;
- console, page exceptions, requests/responses/status/safe headers and
  performance metrics;
- bounded JavaScript execution and redacted cookie inspection/clearing;
- approved, size/time-limited downloads with a verified artifact receipt.

Model-facing Browser tools never accept a Browser session ID. Page mutation,
arbitrary JavaScript, cookie clearing and downloads use the existing approval
pipeline. Navigation and Browser DOM actions remain explicit execute-class
operations; reads remain read-class operations.

## Untrusted-data handling

Every structured Browser result crossing into model-visible tool content is
wrapped as `browser_data` with `trust=untrusted` and `handling=data_only`.
Delimiter characters are escaped, URL credentials/query values/fragments are
removed, secret-shaped fields are redacted, and retained CDP events are projected
before entering their bounded ring buffer. Request bodies, cookie material and
unknown event payloads are never retained. Unknown header values are redacted;
only a small safe metadata allowlist remains readable.

DOM capture does not return Chromium's raw columnar document. It projects at
most 300 visible useful elements and omits password/credential controls and form
values. The Accessibility projection is likewise bounded and strips sensitive
values. Oversized model envelopes remain valid JSON with an explicit truncation
receipt instead of returning a sliced JSON stream.

Initial navigation, final redirect destinations and new tabs reject credentialed,
non-HTTP(S), cloud-metadata and link-local targets. Chromium additionally receives
blocked-URL and host-resolver rules for known metadata services.

## Downloads

Managed sessions configure `Browser.setDownloadBehavior` with
`allowAndName` into `<repository>/tmp/browser/downloads/<session UUID>`.
The model supplies only a credential-free URL and bounded limits. Chromium picks
a GUID path; Luma Chat correlates browser-level download events, cancels on
timeout/size/cancellation, removes only the exact partial GUID artifact, opens
the completed path with `O_NOFOLLOW`, requires a single-link regular file, and
streams a SHA-256 digest. The tool returns byte count, digest, sanitized source,
suggested filename, repository-relative path and artifact path. Completed
downloads are retained as explicit Task artifacts under project `tmp`.

## Annotation

The Agent detail view can annotate the latest Browser screenshot with a bounded
normalized region, label and note. Annotation records use the Browser session ID
as the storage partition and separately persist the owning Task ID, tab/page
identity, viewport, trust metadata and timestamp. Cross-Task records fail closed.
The prompt projection is structured, bounded and explicitly untrusted; image
bytes are never embedded in the JSON annotation.

## Known limits after the development gate

- Browser functionality requires an installed Chromium/Google Chrome compatible
  with the used CDP methods.
- Attach Existing Browser deliberately cannot download or provide the same
  process/profile lifecycle guarantees as a managed session.
- The DOM semantic projection is bounded and selector hints are advisory; highly
  dynamic or closed-shadow-root applications can still require a screenshot or
  Computer Use fallback.
- Browser events and annotations survive only according to their documented
  Task/artifact stores; live CDP connections are not reattached after relaunch.
- Full Swift regression and development build/package gates pass. Real-browser
  integration, packaged native UI acceptance and long-duration soak still
  require an explicitly provisioned external environment.
