# Playbox iOS MVP

Playbox is a SwiftUI proof of concept for a Stremio-compatible remote add-on client.

## Included

- Install a remote add-on using its base URL or manifest URL.
- Decode manifest and catalog responses.
- Browse the first advertised catalog.
- Request stream sources for an item.
- Play ordinary HTTP/HTTPS media with AVPlayer.
- Identify info-hash/magnet-style torrent sources without embedding a torrent engine.

Use Playbox only with add-ons and media you are authorized to access.

## Xcode setup

Create an iOS App target named **Playbox** using SwiftUI and Swift, then add the source files under `Playbox/` to the target.

## Next

- Persist installed add-ons.
- Multiple catalogs and search.
- Posters and richer metadata.
- Source filtering.
- Tests and CI.
