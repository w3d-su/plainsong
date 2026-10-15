# BoundedWait handle race

The racy bytes are `racy-BoundedWait.swift`, SHA-256 `2c14e6e2f1fa15e8634eb1e94e022c00766dc85978019a20015d71ae1f2f8d64`. Line 112 reads `predicateTask` inside the timer closure. Line 116 writes it while holding the lock. This file is the pre-fix source. It is not the code under test after the fix.

`probe.swift` is the isolated driver, SHA-256 `d70defce2e2fbb6a8562b2354d0513bacc929cfd64198e996df8a27434dcdf39`. It is not an XCTest and not the 26-case suite. Both binaries were `swiftc -sanitize=thread -g -Onone -parse-as-library` for `arm64-apple-macos14.0`. Compile exit was 0 for both (`tsan-racy-compile.log`, `tsan-fixed-compile.log`, each SHA-256 `bac34729956f6130ef30ae54f86a84989d070be717ce516f5e91719a9085dd8f`).

## Racy process

`tsan-racy-run.log`, SHA-256 `36ae0644e6e264c24cc87cb50278b689908a97a1ec0cc7fe44a7636be37633be`.

`TSAN_OPTIONS=halt_on_error=1:abort_on_error=1:symbolize=1`. Return code `-6`. `PROBE_DONE` was not printed. The report is:

```text
WARNING: ThreadSanitizer: data race
  Read of size 8 ... closure #2 in AttemptRace.begin racy-BoundedWait.swift:112
  Previous write of size 8 ... AttemptRace.begin racy-BoundedWait.swift:116 (mutexes: write M0)
```

`atos -o racy -arch arm64 0x100009864 0x100006b04` resolved those frames to the same two lines. This is a harness-waiter race, not an XCTest failure, a simulator result, or a product UI incident.

## Fixed process

The same probe compiled with the fixed `IOSAcceptanceTests/Sources/IOSAcceptanceHarness/BoundedWait.swift`. `tsan-fixed-run.log`, SHA-256 `b8b8cb9768671f726c353d426cf351b4f0a39026101d2facc1a3a39d8d5a8a19`. Return code 0. Output is `PROBE_DONE`. The log contains no Thread Sanitizer warning.

The timer no longer reads the stored handles. `finish` copies them while holding the lock and cancels them after releasing it. A continuation is resumed from one path, and a second resume trips a precondition.

## Functional checks

`fence-tests.log`, SHA-256 `aff3e4abbb85b1718d224737359bc8276ea73906b9872786613bdebfcab59a6c`, is `swift test --filter BoundedWaitFenceTests`: 7 tests, 0 failures. That run has no Thread Sanitizer and does not replace the probe above. Product gates stay open.
