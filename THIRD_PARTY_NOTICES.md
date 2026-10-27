# Third-party notices

Navi is licensed under the Apache License 2.0 (see `LICENSE`). It includes or can be built with the following, each under its own licence.

## Bundled in the app

| Component | Where | Licence |
|---|---|---|
| Figtree (Erik Kennedy) | `Resources/Fonts/Figtree[wght].ttf` | SIL Open Font License 1.1, text in `Resources/Fonts/Figtree-OFL.txt` |
| Patrick Hand (Patrick Wagesreiter) | `Resources/Fonts/PatrickHand-Regular.ttf` | SIL Open Font License 1.1, text in `Resources/Fonts/PatrickHand-OFL.txt` |
| Sparkle (the Sparkle Project) | `Navi.app/Contents/Frameworks/Sparkle.framework`, fetched by Swift Package Manager | MIT licence, text in `Resources/Sparkle-LICENSE.txt` (and inside the framework) |

The fonts may be bundled and redistributed with the app; they may not be sold on their own.

## Optional, not in this repository

Builds made with the on-device voice (an empty `.with-kokoro` file next to `Package.swift`) also bundle the Kokoro speech model and its Swift and MLX runtime. They come from their own repositories under their own licences (Kokoro: Apache 2.0; MLX: MIT), and those notices must ship with any such build. Release builds without the voice use the Mac's own voices and include none of it.
