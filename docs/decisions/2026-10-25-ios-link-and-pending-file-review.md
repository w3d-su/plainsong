# iOS external links and pending selected files

PreviewKit remains the sole production owner of HTTP(S) browser opening. Its
external-link event remains observable, while the production scene no longer
installs a second UIApplication opener. Standalone PreviewController callers keep
their existing external-link behavior. Tests intercept the actual controller's
platform-open boundary instead of launching a browser.

A matching single-file document entry is classified by type before availability.
Downloading/offline entries return their typed availability failure and retain
only the still-current explicit file grant and snapshot. Files Refresh can make
that same descriptor available for retry without another picker. Unsupported
types still retire the grant; revocation never becomes download recovery, and no
sibling URL is authorized.

This avoids treating a cloud placeholder as an unsupported document and avoids
inventing directory authority or bypassing provider availability. Automatic
download initiation and physical iCloud behavior remain separate device gates.
