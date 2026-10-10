# Build Playbox on GitHub Actions

Open the repository's **Actions** tab, select **Build iOS IPA**, and choose **Run workflow**.

The macOS runner generates the Xcode project with XcodeGen, builds the iPhoneOS app, packages it in the standard `Payload/Playbox.app` ZIP structure, and uploads `Playbox-unsigned.ipa` as an artifact.

**Important:** This is an **unsigned IPA**, useful for CI/build verification. It is **not installable on a normal iPhone** until signed with a valid Apple certificate and provisioning profile. Do not use certificate bypass or device-security workarounds. A signed distribution build requires an Apple Developer signing setup.

The app is an early MVP. Only connect to add-ons and media you are authorized to use.
