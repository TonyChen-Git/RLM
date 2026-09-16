---
name: artifact-visualization
description: Create or make accurate static or interactive data visualizations and verify data-to-mark mappings and rendering.
usage: Use for charts, diagrams, dashboards, interactive explainers, plots, timelines, maps, and data stories.
permissions: [filesystem_read, filesystem_write, process, browser]
---

# Visualization artifact workflow

1. Inspect the source data and its provenance before choosing a chart. Establish field types, units, missing values, outliers, date/time zones, categories, uncertainty, and the exact question the visual must answer.
2. Choose the smallest visual form that exposes the important relationship. Prefer tables for exact comparisons, position and length over area, honest baselines, direct labels, and accessible color. Do not add a chart when concise prose is clearer.
3. Separate data transformation from rendering. Make transformations auditable, deterministic, bounded, and reproducible; retain source values and document aggregation, filtering, normalization, and sampling.
4. Produce a self-contained artifact when practical. Escape untrusted labels and content, avoid remote scripts and trackers, and never interpolate raw data into executable HTML or JavaScript.
5. Keep generated datasets, browser profiles, screenshots, caches, and local-server output under the workspace's `tmp/` directory. Put only the final HTML, image, SVG, or supporting user-requested files at the destination.
6. Verify the data-to-mark mapping using representative and boundary records. Check scales, domains, units, sorting, legends, labels, tooltips, empty states, keyboard access, responsive layout, and color contrast.
7. For interactive output, open it through the available browser preview, exercise every control, inspect console and network activity, resize through compact and wide viewports, and confirm that it makes no unexpected external requests.
8. For static output, re-open or render at target resolution and inspect for clipping, illegible labels, overlap, misleading axes, missing glyphs, and export artifacts.
9. If data is incomplete or a geographic/projection assumption would materially change meaning, state the assumption. Never invent missing observations.
10. Return the artifact path, a short explanation of the encoding, and the verification performed.
