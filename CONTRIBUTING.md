# Contributing to MokaRig

Thanks for your interest in MokaRig! It's a macOS virtual machine manager built on Apple's Virtualization framework. Contributions of all kinds are welcome — bug reports, fixes features, and documentation.

This project is maintained by GigaRip LLC. Please be respectful and constructive in all interactions.

## Ways to contribute

- **Report a bug** — open an issue describing what happened, what you expected, and how to reproduce it.
- **Suggest a feature** — open an issue first so we can discuss scope before you invest time in a pull request.
- **Submit a change** — fork the repo, make your change on a branch, and open a pull request against `main`.

Because MokaRig is a focused tool, please open an issue to discuss any substantial feature before writing it. That avoids work on changes that may not fit the project's scope.

## Reporting bugs

A good bug report includes:

- Your macOS version and Mac model (Apple silicon is required).
- The MokaRig version (see the About window).
- Exact steps to reproduce, and what you expected instead.
- Relevant console output or a crash log, if any.

## Development setup

Requirements:

- A Mac with **Apple silicon** (the app uses the Virtualization framework and ships ARM64 only).
- **macOS 26.5.2 or later** (the current deployment target).
- A matching version of **Xcode**.

Then:

```sh
git clone https://github.com/GigaRip/MokaRig.git
cd MokaRig
open MokaRig.xcodeproj
```

Sparkle (used for auto-updates) is resolved automatically via Swift Package Manager — no manual setup required. Build and run the `MokaRig` scheme from Xcode.

### Code signing

MokaRig requires the `com.apple.security.virtualization` entitlement, which is already configured in the project — the app cannot launch virtual machines without it. To build and run locally, set your own signing team on the `MokaRig` target in Xcode. A free Apple ID "Personal Team" is sufficient for local development; a paid Apple Developer Program membership is only needed to distribute or notarize a build, which is a maintainer task. When adjusting signing, keep the Virtualization entitlement in place.

There is no automated test suite yet. Please verify your change builds cleanly and manually exercise the affected behavior before opening a pull request. New tests are welcome and should use the Swift Testing framework.

## Coding conventions

- Match the style of the surrounding code: PascalCase for types, camelCase for members, four-space indentation.
- Prefer Swift's `async`/`await` over Combine.
- Follow SwiftUI patterns with a clear separation of concerns.
- Public types, methods, and properties get `///` doc comments.
- Comments explain the *why*, not the *what*. The full comment policy lives in [CLAUDE.md](CLAUDE.md); please read it before adding comments.

## Pull requests

- Branch off `main` and keep each pull request focused on a single concern.
- Write clear commit messages that explain the reasoning behind a change.
- `main` is protected: history is never rewritten, and changes land through pull requests.
- Keep the diff limited to your change — avoid unrelated reformatting.

## Licensing of contributions

MokaRig is dual licensed under the MIT License or the Apache License, Version
2.0, at the user's option. Unless you explicitly state otherwise, any
contribution you intentionally submit for inclusion in the work, as defined in
the Apache-2.0 license, shall be dual licensed as above, without any additional
terms or conditions.

You retain copyright to your contributions; you are simply licensing them to the
project (and its users) under the same terms as the rest of the code. See
[LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE) for the full
terms.
