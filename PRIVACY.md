# Privacy Policy — PalmSlice

Last updated: 2026-10-14

PalmSlice is an on-device 3D printing slicer. This policy is short because
the app does very little with your data: it doesn't leave your device.

## Data Collection

PalmSlice collects **no data of any kind**. Specifically:

- **No servers of ours.** There is no PalmSlice server, no analytics SDK, no
  crash reporter, and no cloud sync. Slicing runs entirely on-device using an
  embedded copy of libslic3r.
- **Optional OctoPrint upload.** If you configure an OctoPrint server, the app
  connects only to the address you enter, and only when you browse folders or
  upload a file. Your OctoPrint address is stored on-device and your API key is
  stored in the iOS Keychain; neither is sent anywhere except that server.
- **No accounts.** There is no sign-in, no user identifier, and nothing is
  ever associated with you personally.
- **No tracking.** PalmSlice does not track you across apps or websites, and
  contains no advertising or tracking SDKs.
- **No analytics.** Usage is not measured, logged, or reported anywhere.

## Files You Provide

When you import an STL file or export G-code, PalmSlice reads/writes files
you explicitly choose via the iOS file picker or the Files app. Those files
stay on your device (and in your own iCloud Drive, if that's where you keep
them) — PalmSlice never transmits them anywhere, except to an OctoPrint server
when you explicitly choose to upload a G-code file to it.

## Third-Party Services

PalmSlice contains no third-party SDKs. Its only external integration is the
optional OctoPrint upload described above, to a server you run and control.

## Changes to This Policy

If this policy ever changes (e.g. a future feature adds network access),
this document will be updated and the update will be reflected in the app's
version notes.

## Contact

Questions about this policy: open an issue at
https://github.com/adickin/PalmSlice/issues
