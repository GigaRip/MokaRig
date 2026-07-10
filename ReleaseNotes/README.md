# Release notes

One markdown file per version, named exactly `<x.y.z>.md` to match the release
version. This is the single source of truth for what a release changed.

At release time `release.sh` renders the file for the version being cut (and
re-renders every past version that still has a file here) with `cmark`, wraps it
in `packaging/release-notes.css`, and hands the HTML to Sparkle's `generate_appcast`,
which embeds it as the appcast item's `<description>`. Sparkle then shows it in
the update prompt — the one and only place MokaRig surfaces release notes.

## Format

Use the section headings below; the stylesheet renders them as small muted
labels. Drop any section you don't need for a given release.

```markdown
### New
- A brand-new capability.

### Improved
- Something existing that got better.

### Fixed
- A bug that's now gone.
```

Keep entries short and user-facing — describe the change, not the code. `release.sh`
refuses to publish a version whose notes file is missing or still contains the
`RELEASE-NOTES-TODO` placeholder.
