# LspAgSVGA

SVGA 2.x decoding and UIKit animation playback for iOS 17 and later. The library has no network or cache policy; callers provide the animation data and own resource loading and caching.

After publication to CocoaPods Trunk:

```ruby
pod 'LspAgSVGA', '0.1.0'
```

## Usage

Decode away from the main thread, then configure the player on the main actor:

```swift
import LspAgSVGA
import UIKit

@MainActor
func showAnimation(data: Data, in player: MovenSVGAPlayerView) async throws {
    let decoder = Task.detached(priority: .userInitiated) {
        try MovenSVGAParser.decode(data)
    }
    let movie = try await decoder.value
    player.movie = movie
    player.loop = false
    player.onComplete = { print("Animation finished") }
    player.play()
}
```

Call `stop()` when playback is no longer needed. `clearsAfterStop` controls whether the last frame remains visible; `fillsBounds` chooses aspect fill instead of aspect fit.

The decoder supports the subset needed by the application: zlib-compressed protobuf movies, bitmap and vector sprites, transforms, and clipping. Audio bytes are retained but not played; matte compositing and SVGA 1.x JSON are not supported.

## License

Proprietary. Copyright Moven. All rights reserved.
