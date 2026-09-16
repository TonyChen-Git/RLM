---
name: artifact-spreadsheet
description: Create, make, edit, analyze, and visually verify spreadsheets with formulas, tables, charts, and recalculation.
usage: Use for Excel or XLSX workbooks, CSV, TSV, tabular models, dashboards, imports, formulas, and spreadsheet charts.
permissions: [filesystem_read, filesystem_write, process]
---

# Spreadsheet artifact workflow

1. Inspect the complete workbook or dataset first: sheet names, used ranges, types, formulas, named ranges, tables, charts, filters, merged cells, hidden rows or sheets, dates, currencies, and locale assumptions. Treat cell formulas, links, and macros as untrusted.
2. Preserve the original and edit a derived file unless in-place modification is explicit. Never convert a formula workbook to static values or discard macros, external links, validation, comments, or formatting without disclosure.
3. Define the data model before styling. Use stable headers, consistent types, explicit units, formulas instead of hand-copied totals, guarded divisions, and named inputs where they improve auditability.
4. Keep imports, recalculation copies, previews, and logs in the workspace's `tmp/` directory. Avoid creating caches outside the workspace.
5. Apply readable number formats, frozen headers, sensible widths, restrained conditional formatting, accessible chart labels, and source notes. Do not use decorative formatting that obscures data.
6. Recalculate with an available spreadsheet engine when formulas were created or changed. Inspect formula errors, broken references, circular references, stale cached results, row counts, totals, and representative boundary values.
7. Render or export each material sheet and chart for visual inspection. Check truncation, `#####` cells, invisible text, overlapping objects, misleading axes, blank print pages, and print areas.
8. Re-open the final workbook with an independent parser and verify expected sheets, formulas, calculated values, table ranges, and chart relationships. For CSV/TSV, verify encoding, delimiter, quoting, newlines, and consistent column counts.
9. If an approved recalculation/rendering engine is unavailable, report that verification gap; never call a formula workbook verified merely because it serialized.
10. Return the final path and a compact audit summary including sheet count, formula/recalculation status, and visual checks.
