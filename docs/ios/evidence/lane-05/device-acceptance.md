# Lane 05 device gates

These gates stay **open**. Simulator doubles and one local UIDocument round trip do not close them.

| Gate | What the owner checks | Status |
|---|---|---|
| Local Files | Open, edit, autosave, and relaunch a `.md` file from the Files provider. The draft survives a failed save | Open |
| iCloud not downloaded | A not-downloaded document stays unavailable. No empty session is created | Open |
| Two-device edit | Mac and iOS change the same file. Clean reload proposes the external bytes. A dirty editor fences and keeps a recovery record | Open |
| Background and relaunch | Resign active, let the background budget expire, then kill the process. Recovery lists the same source, baseline, and document id | Open |
| Traditional Chinese IME | An external update arrives while Zhuyin or Pinyin marked text is active. The composition is not committed or dropped by the store | Open. Editor behavior belongs to lane 04; this lane must not install the external text itself |

No IPA, signed install, or owner recording is claimed.
