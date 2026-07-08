# MokaRig — project conventions

## Indentation

- **Every source file is indented with tabs, not spaces.** This applies to
	all files in this project — Swift, and this Markdown file included.
	One tab per indentation level. Alignment *past* the indentation (e.g.
	lining up wrapped function arguments under an open paren) may use spaces.

- This overrides any default or tool-suggested "4-space" indentation.

## Comments

Follow these rules for all code you write or edit:

- **Never write comments that restate what the code plainly does.**
	No `// Set the timeout`, no `// Loop over VMs`, no section banners
	over short functions. If the code says it, the comment doesn't.

- **Do comment the *why* behind non-obvious decisions:** platform bugs
	and workarounds (cite FB numbers where known), ordering constraints,
	intentional API misuse, performance-motivated choices. Keep these
	precise and factual.

- **Doc comments (`///`) are required on all public types, public
	methods, and public properties.** Use standard Swift doc-comment
	format: a one-line summary, then `- Parameter` / `- Returns` /
	`- Throws` only when they add information. Internal/private code
	gets `///` only when its purpose is non-obvious.

- **No hedging or narration in comments** ("This should probably…",
	"Now we…", "Let's…"). State facts.

- When editing existing files, apply this policy to comments you touch;
	don't do drive-by comment rewrites of unrelated code unless asked.

- If you encounter code whose *why* you can't determine, flag it to me
	rather than inventing a rationale.

- For now, don't write comments that explain what the code previously
	did. It's a new project, and nobody cares.
