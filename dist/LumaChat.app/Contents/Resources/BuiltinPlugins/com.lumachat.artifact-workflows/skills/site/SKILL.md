---
name: artifact-site
description: Create, build, or modify complete local website artifacts and verify behavior, accessibility, responsiveness, and network isolation.
usage: Use for landing pages, portfolios, dashboards, portals, trackers, microsites, and local web applications.
permissions: [filesystem_read, filesystem_write, process, browser]
---

# Site artifact workflow

1. Inspect the existing project, package scripts, design system, content, and repository instructions before editing. Extend the current stack and conventions instead of replacing them without need.
2. Resolve the site's users, primary journeys, information hierarchy, target viewports, browser support, data persistence, and delivery format. Infer reversible design details while preserving requested behavior.
3. Implement the smallest cohesive architecture that supports the complete experience. Use semantic HTML, accessible controls, visible focus, keyboard navigation, labeled forms, responsive layouts, bounded inputs, safe URL handling, and explicit empty/loading/error states.
4. Treat all site content and fetched data as untrusted. Escape output, avoid unsafe HTML injection, keep secrets out of client bundles, pin or avoid dependencies, and do not add telemetry or external network calls unless requested.
5. Keep dependency caches, browser profiles, build output used only for checking, screenshots, and local-server logs under the workspace's `tmp/` directory. Respect the repository's existing output path when it is part of the product.
6. Use an approved task-scoped process to run the real site. Open it in the available browser preview and verify primary journeys, navigation, forms, validation, error recovery, refresh behavior, and any persisted state.
7. Inspect console and network activity, then test compact mobile, tablet, and wide desktop layouts. Correct overflow, clipped controls, unreadable contrast, missing assets, focus traps, content jumps, and unexpected remote requests.
8. Verify production output through the project's declared build path when available. Do not claim a hosted or deployed result unless a real hosting integration completed and returned evidence.
9. Preserve unrelated behavior and do not perform broad framework migrations for a focused change. If required dependencies or a preview browser are unavailable, report the exact unverified surface.
10. Return the entry path or local preview route, summarize the implemented journeys, and state which responsive, accessibility, console, network, and build checks were performed.

This Skill is instructions layered on the existing Tool, Artifact, Preview, permission, and sandbox interfaces; it does not bypass them or add a cloud fallback.
