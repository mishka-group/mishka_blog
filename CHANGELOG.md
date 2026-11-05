# Changelog for MishkaBlog 0.0.3

- An extension adds buttons to the header of the Blog dashboard on the `blog:dashboard:actions` event. A plugin is handed `%{actions: [], current_user: user}` and answers `%{actions: [...]}` with an `id`, `label`, `icon`, `priority` and a `path:` or a `js:` command
- A comment an admin creates keeps the author it names, a user of the same site, where it was always stored as the admin's own. A comment that names no author (or a `nil` one) is still the admin's own, and an author from another site is refused
- A comment can be a guest's: a guest's name, and the email they gave, in place of a user author. The name and email are plain text, their tags taken out. Only the admin's create writes them, a comment with neither an author nor a guest's name is refused, and so is a bad email. The post names a guest, and the Comments page shows a guest's email to moderators, the only readers who ever get it
- The post content scrubber keeps `figure` and `figcaption`, the `srcset` and `sizes` of an image, and the `allowfullscreen` and `allow` of an `iframe`, and drops `<style>` and `<object>`
- The lock is on the newest Hex releases, including `guarded_struct` 0.1.5, `lazy_html` 0.1.14 and `localize` 1.6.1

# Changelog for MishkaBlog 0.0.2

- The visual editor now comes from the `mishka_cms_builder` package instead of `mishka_cms_core`. The blog runs on `mishka_cms_core` 0.0.4, `mishka_gervaz` 0.0.3 and `mishka_installer` 0.1.15 from Hex
- A `blog-notice` dropped on a page from the palette says "Nothing here yet." instead of drawing an empty box
- A blogger, team or post block placed on a page whose address names none draws nothing for a reader. The line that tells the author what the block needs shows only in the editor and the preview
- The release runs on Erlang 29.1.2 and Elixir 1.20.5. The temporary OTP 29.0.5 pin is gone
- `igniter_js` is 0.5.2 and every dependency is at its latest release, including `phoenix_html` 4.4.0, which fixes a security advisory, and `jose` 1.11.13, which fixes 8 advisories
- Dependencies are audited with `hex.audit` and `deps.audit`, the workflows use a read-only `GITHUB_TOKEN`, and Dependabot runs weekly

# Changelog for MishkaBlog 0.0.1

- Initial version: [mishka.tools/cms](https://mishka.tools/cms)
