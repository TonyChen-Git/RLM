# Browser Annotation Context

Phase E browser annotations turn a user-drawn region on a browser page or
screenshot into bounded, structured metadata. They do not retain screenshot
bytes, DOM documents, cookies, credentials, or an arbitrary filesystem path.

## Data boundary

`BrowserAnnotationDraft` is the raw UI/CDP input. It carries the Browser
Session UUID, bounded opaque page and target IDs, pixel selection, viewport,
page URL/title/selected excerpt, user label/note, and timestamp.
`BrowserAnnotationContextValidator.validated(_:)` is the only conversion
boundary. It:

- rejects non-finite or out-of-viewport geometry and emits a normalized 0...1
  `BrowserNormalizedRegion`;
- accepts only credential-free HTTP(S) URLs, removes fragments, and redacts
  sensitive query values;
- bounds every identifier and text field before regex processing;
- removes unsafe control characters and redacts secret-shaped values before
  persistence;
- rejects embedded `data:image/*;base64` payloads; and
- labels the page URL/title/excerpt and annotation label/note as `untrusted`.

`BrowserAnnotationModelContext` additionally fixes handling to `dataOnly`.
Text such as "ignore previous instructions" therefore remains inspectable web
or annotation data and is never promoted to host, system, or tool authority.

## Persistence boundary

`BrowserAnnotationStore` keeps one versioned JSON envelope per Browser Session
under exactly:

```text
<repository>/tmp/browser-annotations/<session-uuid>.json
```

The store API accepts only `BrowserAnnotationDraft` or the metadata-only
`BrowserAnnotationContext`; there is no screenshot byte/path field. All path
components used for files come from typed UUIDs. A test may inject a descendant
of the same root, but an outside or traversal root fails closed.

Storage is opened relative to a pinned repository directory descriptor.
`O_NOFOLLOW_ANY`, `openat`, `fstatat(AT_SYMLINK_NOFOLLOW)`, private `0600` files,
a cross-instance record lock, same-directory temporary files, `fsync`, and
`renameat` provide symlink resistance and atomic replacement. Reads require a
bounded regular file and revalidate every decoded field. A persisted context
that would need trimming, redaction, trust repair, or URL normalization is
rejected instead of silently becoming authoritative.

Hard quotas cover context bytes, annotations per Session, Session-file bytes,
stored Session count, and total bytes. `AppPaths.browserAnnotations` is also a
protected runtime root, so normal workspace read/write/search tools cannot use
the annotation cache as project data.

## Host integration API

```swift
let context = try BrowserAnnotationContextValidator().validated(draft)
let stored = try await BrowserAnnotationStore().save(context)
let modelContext = try BrowserAnnotationContextValidator().modelContext(for: stored)
```

Session cleanup uses `remove(annotationID:sessionID:)` for one mark or
`removeAll(sessionID:)` for the complete temporary record.
