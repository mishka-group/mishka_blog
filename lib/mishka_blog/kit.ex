# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Kit do
  @moduledoc """
  Where this extension's UI kit bundle is, and how to install it.

  ## What is in the bundle, and why it is a bundle

  `priv/cms_ui_kits/mishka_blog.json` carries seventeen components of two kinds. Each is complete on
  its own: its markup, its declarations, and its own code, including the Ash reads it runs. Nothing
  about them lives in Elixir.

  ### The eleven blocks, which are live components

  `blog-post-list`, `blog-featured-posts`, `blog-post-search`, `blog-tag-cloud`,
  `blog-post-detail`, `blog-category-list`, `blog-post-comments`, `blog-related-posts`,
  `blog-author-profile`, `blog-team-profile` and `blog-people`. Each is a `Phoenix.LiveComponent` that runs its own query,
  so an author can put any of them on any page, on its own or beside the others, and each holds what
  it read.

  A blogger's page and a team's read their own page of posts and draw it with the list's own
  `blog-post-card` and `blog-pager`. They cannot draw `blog-post-list` itself: a component's markup
  may not hold a live component (`MishkaCmsCore.Runtime.Resources.Validations.StatefulPlacement`).

  ### The six pieces, which are function components

  `blog-post-card`, `blog-post-meta`, `blog-term-row`, `blog-pager`, `blog-notice` and
  `blog-profile-card`. These hold nothing and read nothing: they draw what the block above hands
  them. They are components rather than markup inside one block because more than one block draws
  them — the card is drawn by the paged list and by the featured strip, the profile card by both
  profiles and by `blog-people`, the notice by every block but the search box — and an admin who
  restyles a card restyles it once.

  ### Who they read as

  Every read is the public action's, with the visitor the page hands down as `current_user` as its
  actor — `nil` for a guest — so a post, a category or a tag locked to permissions the visitor does
  not hold is left out by the same rules the record's own page keeps
  (`MishkaBlog.Resources.Preparations.OpenToActor`), and so is a record whose page, `/blog/:slug`
  or whichever path the page was given, is locked to permissions the visitor does not hold. No
  component reads as the system.

  ### The stylesheet

  `blog-code-highlight` colours the code blocks in a post's body. A post is stored with its code
  already highlighted — `MishkaBlog.Resources.Changes.HighlightCode` does it when the post is
  written — as `<pre class="highlight"><code class="language-x">` with a `<span>` per token, and the
  sheet colours the token classes Makeup emits, in its Monokai style. Installed with the components,
  per site, as a `:base` stylesheet, so a site's own `:custom` rows still win over it.

  ## What was split, and what was left alone

  `blog-post-list` used to draw the featured strip as well, through a `featured_only` switch. The
  strip is `blog-featured-posts` now: it is its own query, so it is its own load and its own place
  on a page, and an author who wants only it no longer carries a pager, a sort button and a page
  size to turn off one at a time. The switch stays on the list, because "the featured archive,
  paged" is a list and because a site provisioned before this still has a page that sets it.

  The sidebar's "Recent posts" is NOT a component of its own, and that is the same rule read the
  other way. It is the same query, the same paging and the same card as the list — `variant`
  decides whether a card or a line is drawn, and `blog-post-card` is where that decision lives now.
  A component for it would be `blog-post-list` with two attributes fixed and a second copy of the
  read, which is the duplication the split exists to remove rather than an example of it.

  ## When a block reads in step, and when in the background

  A block that runs its own query reads its FIRST page in step with the page, on both of a visit's
  renders: the GET, so a crawler and a reader with no JavaScript are served the rows themselves —
  every post a listing links, every tag and category — and the connected one, so the rows are drawn
  straight away rather than replaced by a skeleton while they are read again. Every later read —
  another page, another filter, another sort — runs in a task, and while it does the block draws a
  skeleton; when a read fails it draws a line and a button to ask again. `cold?/1` still answers
  for the builder's canvas and the Preview, where `MishkaCmsCore.Runtime.LiveViewHelpers.cold/2`
  renders a component with no process at all, and reads inline there too. That is
  `blog-post-list`, `blog-featured-posts`, `blog-tag-cloud`, `blog-category-list`,
  `blog-post-comments`, `blog-people`, and both profiles — `blog-author-profile` and
  `blog-team-profile` read the profile and its page of posts as two loads, so turning a page reads
  the posts alone. Each starts a task through `MishkaGervaz.Messages.start_async/4`, which runs it in
  the page's own locale.

  A block that streams its rows says `phx-update="stream"` only where there is a socket to stream
  from — `@myself` is nil in a cold render, and a stream container is one the client never removes a
  child from, so the builder's canvas kept the cards of the previous setting beside the new ones
  every time the Inspector changed one.

  The grid and the compact list are two containers with two ids, not one id on whichever `variant`
  chose. The client keeps a stream's bookkeeping against the container's DOM id, and these two are
  never on the page at the same time, so sharing one would have handed the grid's to the list.
  What puts the rows INTO the new one is `asked/1`: a streamed row is drawn once and never
  re-rendered, so everything a row is built from is part of the read's own signature.

  Three read in step with the page on every read, not only the first, and all on purpose:

    * `blog-post-detail` is what the page IS. A skeleton where the article should be is a worse
      page than one that takes as long as the article does, and a crawler that is served the
      skeleton is served nothing.
    * `blog-related-posts` is three cards under the article, and a read of the same kind as the
      article's own: the post the URL names, its categories and the newest posts of them. It reads
      again only when what it is read for changes, because the page re-renders it far more often
      than anybody asks for different reading.
    * `blog-post-search` reads nothing until the reader types. Its query is already a round trip
      the reader started, and one run in a task could land after a later one and answer the wrong
      words.

  They draw themselves in plain HTML and Tailwind and call no other kit. A site that installed this
  extension and skipped Chelekom renders them; before, every card on the public blog was the
  runtime's red "failed to render" box.

  That is the same shape Chelekom ships in, and it is the point. A component that arrives as data
  can be installed one at a time or in batches, can be edited in the admin like any other row, and
  carries no dependency on a module a third-party importer would not have. An extension that kept
  its components in compiled code would be asking the CMS to treat it specially.

  ## Installing

      MishkaBlog.Kit.install!(site_id)

  Per SITE rather than globally: these components read posts, and a post belongs to a tenant. The
  site is baked into the compiled module's own metadata — see `site_id/0` in the bundle's helpers —
  so a component cannot be edited into reading another site's posts.

  Re-running it upserts by name, which is what makes it safe in a seed.

  ## Updating a site that already has them

  Not with this. `install!/1` writes the bundle's copy over every row an admin ever edited, which is
  what a seed wants and what an admin does not. The "Blog components" card on the blog dashboard is
  the other way: `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade` compares each installed row with the
  version and the fingerprint the installer stamped on it, reports what is behind and what carries
  an edit, and writes only what the admin chooses.

  ## What this module is not

  It installs, and that is all. There is deliberately no query helper, no render helper and nothing
  a component's stored code could call: the components are self-contained, and a function here
  would quietly become part of their contract.
  """

  alias MishkaCmsCore.Runtime.Handlers.UiKitHandler

  @doc "The bundle's absolute path inside this extension's `priv`."
  @spec bundle_path() :: String.t()
  def bundle_path,
    do: Path.join([:code.priv_dir(:mishka_blog), "cms_ui_kits", "mishka_blog.json"])

  @doc """
  Installs the bundle for one site, upserting by component name.

  Returns whatever `MishkaCmsCore.Runtime.Handlers.UiKitHandler.install_kit!/2` returns — `{:ok, …}`
  with the rows, or `{:error, reason}` when the file is not a bundle this CMS reads.
  """
  @spec install!(String.t()) :: {:ok, map()} | {:error, term()}
  def install!(site_id) when is_binary(site_id),
    do: UiKitHandler.install_kit!(bundle_path(), site_id: site_id)
end
