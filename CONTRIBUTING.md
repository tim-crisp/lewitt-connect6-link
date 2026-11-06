# Contributing

Use **master** as the base branch. Keep changes focused and describe validation.
Apple's Command Line Tools and system frameworks are sufficient:

```sh
bash test.sh
bash build.sh
bash package-dmg.sh
bash Tools/verify-package.sh
```

Tests must not require hardware, change sound settings, record audio or access
the network. Hardware checks are separate, explicitly invoked diagnostic options.
Restore the original state after hardware testing.

The USB protocol is undocumented. Keep field writes narrow and preserve fresh
unrelated bytes. Do not relax the firmware guard based on version assumptions.
Additional firmware support requires layout verification, regression tests and
real hardware testing. Do not include vendor binaries/implementation code,
device serial numbers or private audio in contributions.

Bug reports should include macOS version, Intel/Apple Silicon, app version,
firmware version, expected/actual behavior and relevant routing. Redact private
information from screenshots.
