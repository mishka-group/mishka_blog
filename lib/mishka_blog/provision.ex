defmodule MishkaBlog.Provision do
  @moduledoc """
  What a site needs before anybody can look at its blog: this extension's live components, six
  sample pages built out of them, and the sidebar saved as a snippet an author can drop anywhere.

  ## Why a production site needs this at all

  `MishkaBlog.Kit.install!/1` writes the components, and until now its only caller was the dev seed.
  A real install went through `MishkaCmsCore.Install.Bootstrap`, which offers Chelekom and knows
  nothing about this extension, and a site created later in the admin gets nothing until somebody asks — so the
  builder's palette on those sites had no blog components in it and there was no page to put them
  on. `ensure!/1` is that missing step, and it runs in production two ways:
  `MishkaCmsCore.Install.Extensions` fires `installer:extension:install`, MishkaBlog.Plugins.Installer
  answers to its own key, and this is what it runs. Two screens fire it: the install wizard, for the
  extensions an operator ticked, and the "Set up blog pages" button on this extension's dashboard,
  for a site that already exists.

  ## Idempotent, and that is the whole design

  Running this twice must be indistinguishable from running it once, because both callers can run it
  again: an admin can press the button whenever they like, and the wizard and the button can both reach a site
  again.

    * **Components.** Only the ones the site has no row for at all — active or archived — are
      installed, through `selection: %{components: missing}`.
      `MishkaCmsCore.Runtime.Handlers.UiKitHandler.install_kit!/2` UPSERTS, so handing it a name the
      site already has would overwrite whatever the admin edited into it, silently. A component the
      admin archived stays archived for the same reason: it is there, and the admin put it where it
      is.
    * **Pages.** Only where every identity the page row has is free, which
      `MishkaCmsCore.Runtime.PageProvision` reads off the resource rather than this module naming
      them. A held ADDRESS is a page left to whoever holds it while the rest of the run happens; a
      held NAME is not — a site holding a page called "Blog" at an address of its own, which is
      exactly what `MishkaCmsCore.Dev.Seeds` writes at `/blog`, gets `/:lang/blog` under the next
      free name and is told which. An archived page counts as holding both, which is stricter than
      the indexes are — they are partial on `(archived_at IS NULL)` — because a page an admin
      archived is an answer, not an absence.
    * **The snippet.** Only when nothing of that name is saved for this site's page editor.

  Nothing is ever updated, so nothing an author touched can be lost. What a site that was set up
  months ago does about the sample pages having moved on since is
  `MishkaCmsCore.Runtime.PageSamples`, behind the same card as the component update: it offers each
  outdated page as a DRAFT of itself, which the admin previews in the builder and publishes when
  they want it. `sample_pages/1` is what both read the pages from.

  WHICH MEANS A SITE PROVISIONED TODAY CAN GET PAGES NEWER THAN ITS COMPONENTS. The pages below are
  written against the bundle in this checkout, and a site that already has the components keeps the
  ones it has — so an attribute added to a component since that site was seeded reaches a row that
  does not declare it, and `MishkaCmsCore.Runtime.Compilers.ComponentCompiler` sweeps every
  undeclared key into the component's global attr: it is rendered onto the element as an HTML
  attribute, read by nothing, and the behaviour the page asked for is silently the old one. Such a
  site takes the newer components from the "Blog components" card on the blog dashboard, which is
  `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade`: it says which rows are behind the bundle and which
  of them carry an edit, and writes only the ones the admin chooses. What it does NOT do is what
  `MishkaBlog.Kit.install!/1` does — upsert every component the bundle ships over whatever is there,
  the dev seed's own call — and neither does the button here, because an admin asking for pages has
  not asked to lose an edit. `MishkaBlog.ProvisionTest` holds the templates and the bundle together;
  no test can see a row installed months ago.

  ## The pages, and why they look the way they do

  Six pattern pages in `/:lang` PATH mode, which is what seeded and starter content uses here:

      /:lang/blog                  the featured strip, the paged list and the sidebar
      /:lang/blog/:slug            one post, its comments and the sidebar
      /:lang/blog/category/:slug   that category's posts
      /:lang/blog/tag/:slug        that tag's posts
      /:lang/blog/categories       every category, as cards
      /:lang/blog/tags             the whole tag cloud

  No static route in the host application's router answers any of them, which is the point of the
  `/:lang` prefix: `/mish-blog/*` is hand-written marketing the user keeps, and a runtime page
  underneath one of those routes would never be reached.

  The bare `/blog` that prefix left free is NOT provisioned. A row there could not fill the `:lang`
  segment the bases below are built from, so every link off it would name a language nobody asked
  for; and the address is the site's own to publish at, which is why it was freed.

  ONE ROW PER PAGE, not one per language. `:lang` is a capture, and `MishkaCmsCore.Runtime.Languages`
  admits only the site's own languages in it — so `/fa/blog` answers on a site that publishes Persian
  and falls through to the 404 on one that does not, and the template reads the language it was asked
  for from `@page.language`.

  ## One article, one URL, and the links that follow from it

  Every component on these pages is given `language={@page.language}`, blog-post-detail and
  blog-post-comments included: a slug belongs to one edition, so `/fa/blog/<english-slug>` finds
  nothing and says so rather than serving the English article inside a Persian, right-to-left page —
  or publishing that article's conversation underneath the message saying it is not here.

  That is also why the bases the components build links from are written with the capture still in
  them — `post_base="/:lang/blog"`, not `"/" <> @page.language <> "/blog"`. The component fills the
  `:lang` segment with the language of the ROW it is linking to, which is the language the reader
  will be reading in when they arrive, and builds the address the site's URL mode gives it
  (`site_path/2`, `MishkaCmsCore.Runtime.LiveViewHelpers`): `/blog/<slug>` in a first language the
  site leaves unprefixed, `/fa/blog/<slug>` in Persian. A base with the page's own language baked in
  gets the language right for everything except the one link that matters most: the post's
  translations row, where every other edition would be offered at a URL under the language the
  reader is leaving.

  `base`, where a page has one, is the pager's and stays a real URL — nothing appends a slug to it,
  and its `?page=2` has to be somewhere a reader could have typed.

  ## What `:slug` means depends on the page, and only the page knows

  One capture name carries a category on `/:lang/blog/category/:slug`, a tag on
  `/:lang/blog/tag/:slug` and a post on `/:lang/blog/:slug` — while the sidebar's category list and
  tag cloud both read `params` under the same default `selected_param` to mark the row the reader is
  on. So a capture is handed only to the component whose kind of row it holds, which is what the
  sidebar builder below takes its second argument for.

  Every template stays inside what BOTH renderers assign: `@page`, `@query_params`, `@page_languages`
  and `assigns[:current_user]`. The admin's Preview tab assigns no visitor and no captures (see
  `MishkaCmsCore.Runtime.RuntimePreview`), so `@current_user` would raise there and a nil slug reached
  by `<>` would too — hence `assigns[:current_user]` and `|| ""` on everything captured.
  """

  alias MishkaBlog.Kit
  alias MishkaCmsCore.Runtime.ExtensionProvision
  alias MishkaCmsCore.Runtime.Languages

  @snippet_name "Blog sidebar"

  # THE BLOG'S ADDRESSES, WRITTEN ONCE. A page's path, the base a component builds links to it from
  # and the URL the chrome writes to reach it are all the same string — `/:lang/blog/:slug` is where
  # a post is read, `/:lang/blog` is what a block appends that post's slug to, and
  # `/:lang/blog/categories` is both a page and what the header calls it — and they were twenty-seven
  # separate literals, six paths, fifteen bases and six URLs, each one its own chance to write a path
  # this site does not answer.
  #
  # THE `lang` CAPTURE STAYS IN A BASE, rather than the reader's language baked in. A component
  # fills that segment with the language of the ROW it is linking to — see `slug_href/4` in the
  # bundle — which is the only way a link can lead to another language's edition; a base with the
  # reader's current language baked in would offer every translation under the language they are
  # leaving. It also means the bases are the same on a page whose path captures no language at all,
  # which is where the snippet below ends up.
  #
  # A URL IS THE SAME ADDRESS WITH THAT CAPTURE ALREADY FILLED IN — `live_url/2` — because nothing
  # fills it later: a pager writes its `?page=2` to the address bar, and the header links to a page
  # rather than to a row.
  @blog "/:lang/blog"
  @category "#{@blog}/category"
  @tag "#{@blog}/tag"
  @categories "#{@blog}/categories"
  @tags "#{@blog}/tags"

  # The pages whose `:slug` names one row, by the kind of row it names.
  @item_paths %{post: "#{@blog}/:slug", category: "#{@category}/:slug", tag: "#{@tag}/:slug"}

  @section "blog"

  @typedoc "See `MishkaCmsCore.Runtime.ExtensionProvision.report/0`."
  @type report :: ExtensionProvision.report()

  # THE BLOG'S OWN AREAS, created when the blog is installed — with its components and its pages,
  # not with the core's names — so a site that never installs it has none to grant.
  @permissions [
    {"admin:dashboard:blog:*", "The whole blog on the dashboard: posts and comments."},
    {"admin:dashboard:blog:post",
     "The editorial side of the blog: posts, collections, tags, bloggers, teams and auto posting, with their views, ratings, bookmarks and follows. Holders are told when a post is published."},
    {"admin:dashboard:blog:comment", "Comment moderation: comments and comment votes."},
    {"admin:api:blog:*", "The whole blog over the admin JSON:API."},
    {"admin:api:blog:post",
     "Posts, collections, tags, bloggers, teams and auto posting over the admin JSON:API."},
    {"admin:api:blog:comment", "Comments over the admin JSON:API."}
  ]

  @doc """
  What this extension declares about itself, for
  `MishkaCmsCore.Runtime.ExtensionProvision` — the bundle, the section its pages belong to, the
  pages themselves and the snippet.

  `pages` and `snippet.source` take the SITE because a stored `<.component>` call names the site
  whose component it draws, so the markup cannot be written until the site is known.
  """
  @spec manifest() :: ExtensionProvision.manifest()
  def manifest do
    %{
      app: :mishka_blog,
      bundle_path: Kit.bundle_path(),
      section: @section,
      pages: &page_attrs_for/1,
      snippet: %{name: @snippet_name, source: &sidebar(&1, :nothing)},
      permissions: @permissions
    }
  end

  @doc """
  Gives `site` everything the blog ships and it is missing, and returns what happened as
  `%{permissions: names, components: names, pages: paths, snippets: names, renamed_pages: renamed,
  skipped_pages: held}` — `permissions` empty once any site has installed it, the next three empty
  on a site that already has it all, `renamed_pages`
  naming every sample page written under a name of its own because the one it asked for was taken,
  and `skipped_pages` naming every one something already there holds, so the caller can say which
  rather than leave it to the logs.

  Takes the site record the hook is handed, or its id. Raises when the site is not there, or when a
  write is refused for any reason but a page being taken.

  `opts` takes `:actor` — whoever asked for this. Every row of the site is then written as them,
  through the action their own role may use, and the resource's policy answers for it; the
  permission names, shared by every site, are written by the system. Leave it out and the whole run
  writes as the system, which is what the installer wizard and the dev seeds do: they have no
  session behind them. See `MishkaCmsCore.Runtime.ExtensionProvision.ensure!/4`.
  """
  @spec ensure!(map() | String.t(), map(), keyword()) :: report()
  def ensure!(site, answers \\ %{}, opts \\ []),
    do: ExtensionProvision.ensure!(manifest(), site, answers, opts)

  @doc """
  Creates the blog's permission names that are not stored yet, and returns the ones it created —
  for a site found already set up without a run (`MishkaCmsCore.Install.Extensions.installed?/2`).
  """
  @spec ensure_permissions() :: [String.t()]
  def ensure_permissions, do: ExtensionProvision.ensure_permissions(manifest())

  @doc "The component names this extension's bundle ships, read off the bundle itself."
  @spec component_names() :: [String.t()]
  def component_names, do: ExtensionProvision.component_names(manifest())

  @doc """
  The bundle version these pages are written against, stamped onto every page this writes.

  It is the KIT's version rather than the extension's: the pages and the components are one release
  together — a page drawing a component the site has not got renders an error where the block should
  be — and the kit is what `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade` already versions.
  """
  @spec bundle_version() :: String.t() | nil
  def bundle_version, do: ExtensionProvision.bundle_version(manifest())

  @doc "The paths of the sample pages, in the order they are created."
  @spec page_paths() :: [String.t()]
  def page_paths, do: Enum.map(page_definitions(), & &1.path)

  @doc """
  The paths of the sample pages that read one row each, by the kind of row their `:slug` capture
  names — where a post, a category and a tag is read.

      Provision.item_paths().post
      #=> "/:lang/blog/:slug"
  """
  @spec item_paths() :: %{post: String.t(), category: String.t(), tag: String.t()}
  def item_paths, do: @item_paths

  @doc """
  The sample pages as this checkout ships them, as the attribute maps a page create takes.

  `ensure!/1` writes the ones the site has no row for; `MishkaCmsCore.Runtime.PageSamples` compares
  the same maps against the rows a site already has, which is how an admin is offered a newer
  version of a page they are already serving. Both read them from here, so the two can never be
  describing different pages.

  Takes the site record or its id, and the actor to read it as — `nil` for a caller with no session
  behind it.
  """
  @spec sample_pages(map() | String.t(), map() | nil) :: [map()]
  def sample_pages(site, actor \\ nil),
    do: ExtensionProvision.pages(manifest(), site, actor)

  @doc "What the sidebar snippet is called in the Studio's list."
  @spec snippet_name() :: String.t()
  def snippet_name, do: @snippet_name

  # THE PAGES THEMSELVES, which is the one thing only this extension knows. `section` is put on by
  # `ExtensionProvision` from the manifest, so it cannot disagree with what the manifest declares.
  defp page_attrs_for(%{name: site_name}) do
    Enum.map(page_definitions(), fn definition ->
      %{
        name: definition.name,
        title: definition.title,
        path: definition.path,
        description: definition.description,
        extra: shows(definition),
        format: :heex,
        template: definition.template.(site_name),
        active: true
      }
    end)
  end

  # The kind of record a page shows, which `MishkaBlog.Plugins.PageSeo` answers for whatever path
  # the page is later given.
  defp shows(%{record: record}), do: %{"record" => record}
  defp shows(_shows_none), do: %{}

  # ---------------------------------------------------------------------------
  # The sample pages
  # ---------------------------------------------------------------------------

  defp page_definitions do
    [
      %{
        name: "Blog",
        title: "Blog",
        path: @blog,
        description: "The blog's home: featured posts, the paged list and the sidebar",
        template: &blog_home/1
      },
      %{
        name: "Blog post",
        title: "Blog post",
        path: @item_paths.post,
        record: "blog:post",
        description: nil,
        template: &blog_post/1
      },
      %{
        name: "Blog category",
        title: "Blog category",
        path: @item_paths.category,
        record: "blog:category",
        description: nil,
        template: &blog_category/1
      },
      %{
        name: "Blog tag",
        title: "Blog tag",
        path: @item_paths.tag,
        record: "blog:tag",
        description: nil,
        template: &blog_tag/1
      },
      %{
        name: "Blog categories",
        title: "Blog categories",
        path: @categories,
        description: "Every category of the blog, as cards",
        template: &blog_categories/1
      },
      %{
        name: "Blog tags",
        title: "Blog tags",
        path: @tags,
        description: "The blog's whole tag cloud",
        template: &blog_tags/1
      }
    ]
  end

  # THE STRIP IS ITS OWN BLOCK, NOT THE LIST WITH A SWITCH. Both read posts and they read different
  # ones, so on this page they are two queries either way — and as two blocks they are also two
  # loads: whichever comes back first is drawn, and a slow read of one leaves the other standing.
  # An author can also take the strip to a page of its own, which a `featured_only` switch on the
  # list could only imitate by carrying a pager, a sort button and a heading it does not want.
  defp blog_home(site) do
    chrome(
      """
      <.component
        component_name="blog-featured-posts"
        site="#{site}"
        id="blog-featured"
        current_user={assigns[:current_user]}
        heading={t("Featured")}
        limit={3}
        show_excerpt={false}
        language={@page.language}
        post_base="#{@blog}"
      />

      <.component
        component_name="blog-post-list"
        site="#{site}"
        id="blog-posts"
        current_user={assigns[:current_user]}
        heading={t("Latest posts")}
        per_page={9}
        show_sort={true}
        show_total={true}
        language={@page.language}
        base={#{live_url(@blog)}}
        params={Map.drop(@query_params, ["lang"])}
        post_base="#{@blog}"
      />
      """,
      sidebar(site, :nothing)
    )
  end

  # `language` ON THE COMMENTS AS WELL AS ON THE ARTICLE. Both resolve the same `:slug` capture, and
  # a block that resolved it by slug alone published the English article's conversation at
  # /fa/blog/<its slug> under a detail block correctly saying that post is not here — and offered a
  # signed-in reader a box that writes onto the English post.
  defp blog_post(site) do
    chrome(
      """
      <.component
        component_name="blog-post-detail"
        site="#{site}"
        id="blog-post"
        current_user={assigns[:current_user]}
        params={@query_params}
        post_param="slug"
        language={@page.language}
        post_base="#{@blog}"
        category_base="#{@category}"
        tag_base="#{@tag}"
      />

      <div class="rounded-[18px] border border-[#ecebe6] bg-white p-5 sm:p-7">
        <.component
          component_name="blog-post-comments"
          site="#{site}"
          id="blog-post-comments"
          params={@query_params}
          post_param="slug"
          language={@page.language}
          current_user={assigns[:current_user]}
        />
      </div>
      """,
      sidebar(site, :post)
    )
  end

  defp blog_category(site) do
    chrome(
      """
      <.component
        component_name="blog-post-list"
        site="#{site}"
        id="blog-category-posts"
        current_user={assigns[:current_user]}
        heading={t("Category")}
        per_page={9}
        show_total={true}
        language={@page.language}
        collection={@query_params["slug"]}
        base={#{live_url(@category, "slug")}}
        params={Map.drop(@query_params, ["lang", "slug"])}
        post_base="#{@blog}"
        empty_text={t("Nothing is published in this category yet.")}
      />
      """,
      sidebar(site, :category)
    )
  end

  defp blog_tag(site) do
    chrome(
      """
      <.component
        component_name="blog-post-list"
        site="#{site}"
        id="blog-tag-posts"
        current_user={assigns[:current_user]}
        heading={t("Tag")}
        per_page={9}
        show_total={true}
        language={@page.language}
        tag={@query_params["slug"]}
        base={#{live_url(@tag, "slug")}}
        params={Map.drop(@query_params, ["lang", "slug"])}
        post_base="#{@blog}"
        empty_text={t("Nothing is published under this tag yet.")}
      />
      """,
      sidebar(site, :tag)
    )
  end

  # `parent="all"`, where the sidebar's list keeps the default and shows the roots. This page is the
  # blog's index of categories and says so in its own description, so a category nested under another
  # one has to appear on it — the sidebar is a menu, and a menu that listed every child would be the
  # whole taxonomy in a 320px column.
  defp blog_categories(site) do
    chrome("""
    <.component
      component_name="blog-category-list"
      site="#{site}"
      id="blog-categories"
      current_user={assigns[:current_user]}
      heading={t("Categories")}
      variant="cards"
      parent="all"
      limit={60}
      show_count={true}
      show_description={true}
      language={@page.language}
      category_base="#{@category}"
      post_base="#{@blog}"
    />
    """)
  end

  defp blog_tags(site) do
    chrome("""
    <div class="rounded-[18px] border border-[#ecebe6] bg-white p-5 sm:p-7">
      <.component
        component_name="blog-tag-cloud"
        site="#{site}"
        id="blog-tags"
        current_user={assigns[:current_user]}
        heading={t("Tags")}
        limit={100}
        show_count={true}
        language={@page.language}
        tag_base="#{@tag}"
      />
    </div>
    """)
  end

  # The sidebar the lists and the post page carry, and the snippet's own source. The card chrome is
  # here rather than in the components, because a component that drew its own card could not be
  # dropped into one.
  #
  # `holds` IS WHAT THE PAGE'S `:slug` CAPTURE NAMES, and it is the only thing the sidebar differs
  # by. One key, `slug`, means a category on one of these pages, a tag on another and a post on a
  # third, while the category list and the tag cloud both read `params` under the same default
  # `selected_param` to mark the row the reader is on. Handing both of them the capture on every
  # page therefore marks a tag the reader is not on as where they are whenever a tag and a category
  # share a slug — and "elixir" being both is the ordinary case, not a contrived one. Only the
  # component whose kind of row the capture holds is given it. The snippet, which an author drops on
  # a page this module knows nothing about, is given `:nothing` and marks none.
  defp sidebar(site, holds) do
    """
    <aside data-role="blog-sidebar" class="flex flex-col gap-5">
      <div class="rounded-[18px] border border-[#ecebe6] bg-white p-5">
        <.component
          component_name="blog-post-search"
          site="#{site}"
          id="blog-sidebar-search"
          current_user={assigns[:current_user]}
          heading={t("Search")}
          language={@page.language}
          post_base="#{@blog}"
        />
      </div>

      <.component
        component_name="blog-category-list"
        site="#{site}"
        id="blog-sidebar-categories"
        current_user={assigns[:current_user]}
        heading={t("Categories")}
        posts_per_category={3}
        show_count={true}
        language={@page.language}
        category_base="#{@category}"
        post_base="#{@blog}"#{marks(holds, :category, 4)}#{without_the_open_one(holds, 4)}
      />

      <div class="rounded-[18px] border border-[#ecebe6] bg-white p-5">
        <.component
          component_name="blog-tag-cloud"
          site="#{site}"
          id="blog-sidebar-tags"
          current_user={assigns[:current_user]}
          heading={t("Tags")}
          limit={24}
          show_count={true}
          language={@page.language}
          tag_base="#{@tag}"#{marks(holds, :tag, 6)}
        />
      </div>

      <.component
        component_name="blog-post-list"
        site="#{site}"
        id="blog-sidebar-recent"
        current_user={assigns[:current_user]}
        heading={t("Recent posts")}
        variant="compact"
        per_page={5}
        show_pager={false}
        show_excerpt={false}
        language={@page.language}
        post_base="#{@blog}"#{without_the_open_one(holds, 4)}
      />
    </aside>
    """
  end

  defp marks(holds, holds, pad), do: "\n#{String.duplicate(" ", pad)}params={@query_params}"
  defp marks(_elsewhere, _kind, _pad), do: ""

  # WHAT ELSE THERE IS TO READ, which the article the reader already has open is not — in BOTH of the
  # blocks that offer it, the recent list and the three posts hung under each category. `|| ""`
  # because the admin's Preview assigns no captures, and the attribute's own default is the same
  # empty string.
  defp without_the_open_one(:post, pad),
    do: ~s(\n#{String.duplicate(" ", pad)}exclude_slug={@query_params["slug"] || ""})

  defp without_the_open_one(_no_post_here, _pad), do: ""

  # ONE OF THE ADDRESSES ABOVE AS A URL A READER COULD HAVE TYPED, written as the `site_path/2` the
  # template calls: the `lang` capture filled in with the language this page is being read in, at the
  # address the site's URL mode gives it, which is what a pager writes to the address bar and what
  # the header links a page by. `captured` names the page's OTHER capture, where it has one and the
  # pager's URL has to end in it; the admin's Preview assigns no captures at all, and gets no URL.
  defp live_url(address, captured \\ nil)

  defp live_url(address, nil), do: ~s|site_path("#{address}", @page.language)|

  defp live_url(address, name) do
    captures =
      ~s|%{"#{Languages.capture()}" => @page.language, "#{name}" => @query_params["#{name}"]}|

    ~s|site_path("#{address}/:#{name}", #{captures})|
  end

  # THE LANGUAGE NAV IS BUILT FROM `@page_languages`, never from the first path segment. The capture
  # may sit anywhere in a page's path — see `MishkaCmsCore.Runtime.PageEditions` — and that assign is
  # this same page's URL in each of the site's languages, whichever segment holds it. An `<a href>`
  # rather than a `<.link navigate>`, because `<html lang dir>` is drawn once per HTTP response and a
  # live navigation into another language would keep the first one's direction.
  defp chrome(body, aside \\ nil) do
    """
    <div class="min-h-screen bg-[#f6f5f2] text-[#1b1a18]">
      <header class="border-b border-[#ecebe6] bg-white">
        <div class="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-3 px-6 py-5">
          <.link
            navigate={#{live_url(@blog)}}
            class="font-['Space_Grotesk'] text-[20px] font-bold tracking-[-0.01em]"
          >
            {t("Blog")}
          </.link>

          <nav class="flex flex-wrap items-center gap-2 text-[12.5px] font-semibold">
            <.link
              navigate={#{live_url(@categories)}}
              class="rounded-full border border-[#ecebe6] px-3 py-1.5 text-[#3a382f] hover:bg-[#f6f5f2]"
            >
              {t("Categories")}
            </.link>
            <.link
              navigate={#{live_url(@tags)}}
              class="rounded-full border border-[#ecebe6] px-3 py-1.5 text-[#3a382f] hover:bg-[#f6f5f2]"
            >
              {t("Tags")}
            </.link>

            <a
              :for={edition <- @page_languages}
              href={edition.path}
              hreflang={edition.language}
              class={[
                "rounded-full border px-3 py-1.5 uppercase",
                (edition.language == @page.language &&
                   "border-[#5b57d6] bg-[#f2f1fc] text-[#4f4bcc]") ||
                  "border-[#ecebe6] text-[#6d6a63] hover:bg-[#f6f5f2]"
              ]}
            >
              {edition.language}
            </a>
          </nav>
        </div>
      </header>

      <main class="#{main_class(aside)}">
        <div class="flex flex-col gap-8">
    #{indent(body, 6)}
        </div>#{aside_block(aside)}
      </main>
    </div>
    """
  end

  # WRITTEN OUT IN FULL, one clause per case, rather than a column track glued onto a shared prefix.
  # Tailwind reads source text, and a class with a hole in it gets no rule — see
  # `MishkaCmsWeb.InterpolatedClassTest`. The per-site compiler scans the STORED template, where this
  # is already a literal, and only because the choice is made here rather than there.
  defp main_class(nil), do: "mx-auto grid max-w-6xl grid-cols-1 gap-6 px-6 py-8"

  defp main_class(_aside),
    do: "mx-auto grid max-w-6xl grid-cols-1 gap-6 px-6 py-8 lg:grid-cols-[minmax(0,1fr)_320px]"

  defp aside_block(nil), do: ""
  defp aside_block(aside), do: "\n\n" <> indent(aside, 4)

  defp indent(markup, spaces) do
    pad = String.duplicate(" ", spaces)

    markup
    |> String.trim_trailing("\n")
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> pad <> line
    end)
  end
end
