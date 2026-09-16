---
name: artifact-presentation
description: Create, make, revise, render, and verify slide presentations with coherent narrative and layout.
usage: Use for PowerPoint or PPTX files, slide decks, pitch decks, briefings, speaker notes, and presentation redesign.
permissions: [filesystem_read, filesystem_write, process]
---

# Presentation artifact workflow

1. Inspect supplied decks, brand references, data, and media before editing. Preserve source files, masters, layouts, notes, links, charts, and embedded assets unless their removal is requested.
2. Resolve the audience, speaking duration, slide ratio, delivery context, and target format. Build a concise narrative outline before laying out slides; one slide should communicate one primary idea.
3. Use a consistent grid, typography scale, color palette, margins, and reusable layouts. Keep text legible at presentation distance, include source notes for factual claims, and use accessible contrast and alt text.
4. Use native editable shapes, text, tables, and charts where practical. Never make a screenshot of a document masquerade as an editable deck, and never rename source markup to `.pptx`.
5. Keep downloaded media, generated illustrations, rendered slides, and conversion caches under the workspace's `tmp/` directory. Only final requested outputs belong outside it.
6. Re-open the final package and validate slide order, relationships, media, notes, charts, theme references, and package integrity. Confirm every requested fact and datum appears on the intended slide.
7. Render every slide to an image and inspect it at both fit-to-window and readable size. Correct clipping, overlap, overflow, tiny type, missing glyphs, broken images, inconsistent alignment, low contrast, and accidental blank slides.
8. If the chosen library cannot preserve an existing animation, transition, embedded object, or master behavior, disclose that limitation. Do not silently flatten or drop it.
9. Return the final deck path with slide count and a short statement of package and rendered-slide verification.

Do not fetch third-party assets or run converters without the normal network/process permission flow and clear licensing provenance.
