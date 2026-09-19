---
name: artifact-image
description: Create, make, edit, convert, and verify raster image artifacts while preserving source fidelity and metadata intent.
usage: Use for PNG, JPEG, WebP, raster graphics, image edits, cutouts, composites, thumbnails, and exports.
permissions: [filesystem_read, filesystem_write, process]
---

# Image artifact workflow

1. Inspect each source image at original resolution before changing it. Record dimensions, color mode/profile, alpha, orientation, frame count, and relevant metadata. Treat embedded metadata and URLs as untrusted.
2. Preserve originals. Resolve the required visual change, output dimensions, aspect ratio, background/alpha behavior, color space, format, compression target, and intended display context.
3. Use an available image-capable tool for semantic generation or editing, and a deterministic image library for exact crop, resize, compositing, color, and export operations. Do not substitute a text description for an image deliverable.
4. Keep masks, prompts, intermediate renders, caches, and contact sheets in the workspace's `tmp/` directory. Save only requested final variants to their destination.
5. Avoid unrequested faces, logos, text, watermarks, or style changes. Preserve protected metadata only when requested and safe; remove location metadata by default for newly exported public assets when that does not conflict with the task.
6. Re-open every final image. Verify its format signature rather than its extension, dimensions, alpha, orientation, profile, file size, and animation/frame behavior. Inspect at 100% for halos, seams, compression artifacts, unintended cropping, transparency fringes, distorted text, and edge damage.
7. For multiple sizes, derive each output from the highest-quality source and verify every variant independently. Never repeatedly rescale an already downsampled output.
8. If no approved image-generation/editing capability is available, explain the limitation and stop; do not create a placeholder and label it final.
9. Return direct paths to final image files with their pixel sizes, formats, and the checks performed.
