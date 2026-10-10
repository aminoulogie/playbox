# Player integration

Playbox integrates the open-source **wxxsw/VideoPlayer** package using Swift Package Manager through XcodeGen's `project.yml`.

- Upstream: https://github.com/wxxsw/VideoPlayer
- License: MIT (retain the upstream license and notices).
- Its Swift package also depends on GSPlayer.
- GitHub Actions resolves and downloads the complete dependency source at build time; it is not copied into this repository.
- Playbox's DetailView uses the library's SwiftUI player for HTTP(S) media sources.

This integration does not add a BitTorrent client. Magnet/info-hash streams are not directly playable.

The project has not yet been validated by a successful GitHub Actions build.
