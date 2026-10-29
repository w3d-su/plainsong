# iOS review follow-up: search bounds, export cancellation, and print margins

Folder search stops after `maximumMatchesPerQuery`. It then reads at most eight later
files to see whether another match exists. A match in that probe is the only reason the
status says "Showing the first N matches". If the probe ends with files still unread,
the status says "Later files were not searched" and does not claim the cap was proven.
A fully searched small folder with no further match still omits both notes.

Search text cached for an open-buffer edit is dropped when the workspace provider
reports `resourceChanged` for that path, or when a snapshot refresh has the same tree
and a new request ID. The tree projection still ignores the request ID, so the browser
does not redraw. An open search reads the dropped files again. The cache epoch keeps a
read that started before the drop from storing that older text.

`cancel()` clears the running flag immediately and bumps an export id. A following
`begin` is not ignored. The cancelled run presents nothing and its cleanup does not
clear the newer run.

Print plans US Letter or A4, with a half-inch margin, instead of
`UIPrintPaper.bestPaper(forPageSize:withPapersFrom: [])`. The empty paper list is not
documented. Changing paper in the print panel scales the PDF; it does not plan the
pages again. The print job name has no `.pdf` suffix.

Not in this change: the duplicated export filename helper (it stays on the iOS side so
this PR does not retune the Mac panel), an asset folder with the same name as the
document, the estimated TextKit fragment Y on the first long-document scroll, and
physical-device checks for the clear export window and the iPad print panel.

Alternatives: keep reading every later file so truncation is exact (rejected: a folder
of non-matching files turns the cap into a full read). Mark the cap as proven when the
probe stops (rejected: the status would claim another match that was not found). Key
the cache by file modification date (rejected: the workspace entry has no date, and the
provider already reports the change).
