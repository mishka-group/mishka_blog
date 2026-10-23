# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Provision do
  @moduledoc """
  What a site needs before anybody can look at its blog: this extension's live components, nine
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

  Nine pattern pages in `/:lang` PATH mode, which is what seeded and starter content uses here:

      /:lang/blog                  the search, the featured strip and the paged list
      /:lang/blog/:slug            one post, its conversation and what to read next
      /:lang/blog/category/:slug   the same screen, narrowed to that category's posts
      /:lang/blog/tag/:slug        the same screen, narrowed to that tag's posts
      /:lang/blog/categories       every category, as cards
      /:lang/blog/tags             the whole tag cloud
      /:lang/blog/author/:slug     one blogger, their teams and their posts
      /:lang/blog/team/:slug       one team, its members and their posts
      /:lang/blog/people           every team with its members, and the bloggers in none

  ## What a page is drawn in

  Every page is hung on the site's `site-main` layout — see `layout_id/1` — whose header and footer
  are the site's own: the logo, the language switcher, the sign-in menu and the dark-mode switch.
  A page therefore draws only what lies between them. Every page begins with the same bar of its
  own, the blog's name and its four places (Posts, Categories, Tags and People), which `frame/2`
  writes and which marks the one the reader is in: a post is in Posts, a blogger and a team are in
  People, as the design has them. The colours, type and radii of everything below are the tokens of
  the site's theme, with a `dark:` twin for each, and the screens are the design's: the search box
  with its count, the featured strip, the row of categories above the cards, the pager that says
  which posts it shows, the article with its conversation and what to read next, and the people with
  their posts. A site that skipped the starter content has neither the layout nor the theme tokens
  the markup is written in (`bg-surface`, `text-dim`, `font-newsreader` and the rest), and these
  pages are plain on it.

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
  `/:lang/blog/tag/:slug`, a blogger on `/:lang/blog/author/:slug`, a team on `/:lang/blog/team/:slug`
  and a post on `/:lang/blog/:slug` — while a category list and a tag cloud both read `params` under
  the same default `selected_param` to mark the row the reader is on. So a capture is handed only to
  the component whose kind of row it holds, and the sidebar snippet, which an author drops on a page
  this module knows nothing about, is handed none and marks none.

  Every template stays inside what BOTH renderers assign: `@page`, `@query_params`, `@page_languages`
  and `assigns[:current_user]`. The admin's Preview tab assigns no visitor and no captures (see
  `MishkaCmsCore.Runtime.RuntimePreview`), so `@current_user` would raise there and a nil slug reached
  by `<>` would too — hence `assigns[:current_user]` and `|| ""` on everything captured.
  """

  alias MishkaBlog.Kit
  alias MishkaCmsCore.Runtime.ExtensionProvision
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Layout

  require Ash.Query

  @snippet_name "Blog sidebar"

  # THE BLOG'S ADDRESSES, WRITTEN ONCE. A page's path, the base a component builds links to it from
  # and the URL the frame writes to reach it are all the same string — `/:lang/blog/:slug` is where
  # a post is read, `/:lang/blog` is what a block appends that post's slug to, and
  # `/:lang/blog/categories` is both a page and what the frame's tabs call it — and they were twenty-seven
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
  # fills it later: a pager writes its `?page=2` to the address bar, and the frame links to a page
  # rather than to a row.
  @blog "/:lang/blog"
  @category "#{@blog}/category"
  @tag "#{@blog}/tag"
  @categories "#{@blog}/categories"
  @tags "#{@blog}/tags"
  @author "#{@blog}/author"
  @team "#{@blog}/team"
  @people "#{@blog}/people"

  # The pages whose `:slug` names one row, by the kind of row it names.
  @item_paths %{
    post: "#{@blog}/:slug",
    category: "#{@category}/:slug",
    tag: "#{@tag}/:slug",
    author: "#{@author}/:slug",
    team: "#{@team}/:slug"
  }

  @section "blog"

  # THE LAYOUT `MishkaCmsCore.Install.StarterContent` gives a site: header, footer and the room
  # between them.
  @layout_name "site-main"

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
      snippet: %{name: @snippet_name, source: &sidebar/1},
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
  names — where a post, a category, a tag, a blogger and a team is read.

      Provision.item_paths().post
      #=> "/:lang/blog/:slug"
  """
  @spec item_paths() :: %{
          post: String.t(),
          category: String.t(),
          tag: String.t(),
          author: String.t(),
          team: String.t()
        }
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
  defp page_attrs_for(%{name: site_name} = site) do
    layout_id = layout_id(site)

    Enum.map(page_definitions(), fn definition ->
      %{
        name: definition.name,
        title: definition.title,
        path: definition.path,
        description: definition.description,
        extra: shows(definition),
        format: :heex,
        template: definition.template.(site_name),
        layout_id: layout_id,
        active: true
      }
    end)
  end

  # THE PAGES HANG ON THE SITE'S OWN FRAME, the `site-main` layout, which is what draws the header
  # with the logo, the language switcher and the sign-in menu and the footer around them — so a blog
  # page is the page and nothing else, and the site's header is not drawn a second time inside it.
  # `MishkaCmsCore.Install.StarterContent` writes the layout, and the install wizard runs it before
  # the extensions' step, as do the dev seeds. A site that has none — one that started empty — gets
  # `nil`, which is the page with no layout of its own, drawn in the application's frame as it
  # always was.
  defp layout_id(%{id: site_id}) when is_binary(site_id) do
    Layout
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name == ^@layout_name and site_id == ^site_id)
    |> Ash.Query.select([:id])
    |> Ash.read!(authorize?: false, page: [limit: 1])
    |> Map.fetch!(:results)
    |> case do
      [%{id: id} | _rest] -> id
      [] -> nil
    end
  end

  defp layout_id(_site_without_an_id), do: nil

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
        description:
          "The blog's home: the search, the featured posts and the paged list under the categories",
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
      },
      %{
        name: "Blog author",
        title: "Blog author",
        path: @item_paths.author,
        record: "blog:author",
        description: nil,
        template: &blog_author/1
      },
      %{
        name: "Blog team",
        title: "Blog team",
        path: @item_paths.team,
        record: "blog:team",
        description: nil,
        template: &blog_team/1
      },
      %{
        name: "Blog people",
        title: "Blog people",
        path: @people,
        description: "Every team of the blog with its members, and the bloggers in none",
        template: &blog_people/1
      }
    ]
  end

  # THE HOME PAGE, THE CATEGORY PAGE AND THE TAG PAGE ARE ONE SCREEN, as the design draws them: the
  # title with its search box, the featured strip and the latest posts under a row of categories —
  # and a category or a tag is that same screen with the list narrowed to it and the strip left out.
  # What differs is which of the list's attributes names the filter, the address the pager and the
  # search box write to, and the words a list that matched nothing says.
  defp blog_home(site), do: index_screen(site, :everything)

  defp blog_category(site), do: index_screen(site, :category)

  defp blog_tag(site), do: index_screen(site, :tag)

  # THE DESIGN'S POST SCREEN, drawn in the blog's frame between the site's header and its footer, in
  # the Posts place. Three blocks in one column, and the column is the design's: the article and its
  # cover (`blog-post-detail`), the conversation under it in the width of the text
  # (`blog-post-comments`), then what to read next (`blog-related-posts`).
  #
  # `language` ON THE COMMENTS AND THE NEXT READS AS WELL AS ON THE ARTICLE. All three resolve the
  # same `:slug` capture, and a block that resolved it by slug alone published the English article's
  # conversation at /fa/blog/<its slug> under a detail block correctly saying that post is not here —
  # and offered a signed-in reader a box that writes onto the English post.
  defp blog_post(site) do
    frame(:posts, """
    <div class="flex w-full flex-col items-center pt-12">
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
        author_base="#{@author}"
      />

      <div class="mt-[46px] w-full max-w-[680px]">
        <.component
          component_name="blog-post-comments"
          site="#{site}"
          id="blog-post-comments"
          heading={t("Comments")}
          params={@query_params}
          post_param="slug"
          language={@page.language}
          current_user={assigns[:current_user]}
        />
      </div>

      <div class="mt-20 w-full">
        <.component
          component_name="blog-related-posts"
          site="#{site}"
          id="blog-post-related"
          current_user={assigns[:current_user]}
          params={@query_params}
          post_param="slug"
          heading={t("Keep reading")}
          language={@page.language}
          post_base="#{@blog}"
        />
      </div>
    </div>
    """)
  end

  # `parent="all"`, where the sidebar's list keeps the default and shows the roots. This page is the
  # blog's index of categories and says so in its own description, so a category nested under another
  # one has to appear on it — the sidebar is a menu, and a menu that listed every child would be the
  # whole taxonomy in a 320px column.
  defp blog_categories(site) do
    frame(:categories, """
    <.component
      component_name="blog-category-list"
      site="#{site}"
      id="blog-categories"
      current_user={assigns[:current_user]}
      variant="cards"
      masthead={true}
      eyebrow={t("Browse")}
      heading={t("Categories")}
      parent="all"
      limit={60}
      posts_per_category={3}
      show_count={true}
      show_description={true}
      count_text={t("posts")}
      view_all_text={t("View all in")}
      language={@page.language}
      category_base="#{@category}"
      post_base="#{@blog}"
    />
    """)
  end

  defp blog_tags(site) do
    frame(:tags, """
    <.component
      component_name="blog-tag-cloud"
      site="#{site}"
      id="blog-tags"
      current_user={assigns[:current_user]}
      variant="cloud"
      masthead={true}
      eyebrow={t("Browse")}
      heading={t("Tags")}
      summary_text={t("topics · larger means more posts.")}
      limit={100}
      show_count={true}
      language={@page.language}
      tag_base="#{@tag}"
    />
    """)
  end

  # A BLOGGER'S PAGE AND A TEAM'S ARE ONE PERSON'S PAGE IN THE DESIGN, so they are the same shape: the
  # row the capture names, read by the block that draws it with its head, its numbers and its posts as
  # cards, paged under it at this page's own URL, in the People place of the frame. A blogger and a team
  # are one row in every language, so `language` decides only which of their posts are listed and the
  # language the links out of them are built in. There is no sidebar: the design's person page is the
  # whole width.
  #
  # `back_href` IS THE ADDRESS OF THE PEOPLE PAGE, built here because a page is what knows its own
  # neighbours; the block draws the way back above the profile and only knows where it was told to go.
  defp blog_author(site) do
    frame(:people, """
    <div class="pt-14">
      <.component
        component_name="blog-author-profile"
        site="#{site}"
        id="blog-author"
        current_user={assigns[:current_user]}
        slug={@query_params["slug"]}
        back_href={#{live_url(@people)}}
        back_text={t("People")}
        team_text={t("Team")}
        teams_text={t("Teams")}
        post_text={t("post")}
        posts_text={t("posts")}
        posts_heading={t("Posts by %{name}")}
        per_page={9}
        language={@page.language}
        base={#{live_url(@author, "slug")}}
        params={Map.drop(@query_params, ["lang", "slug"])}
        post_base="#{@blog}"
        team_base="#{@team}"
        missing_text={t("That blogger is not here, or no longer writes for this site.")}
        empty_text={t("Nothing published yet.")}
      />
    </div>
    """)
  end

  defp blog_team(site) do
    frame(:people, """
    <div class="pt-14">
      <.component
        component_name="blog-team-profile"
        site="#{site}"
        id="blog-team"
        current_user={assigns[:current_user]}
        slug={@query_params["slug"]}
        back_href={#{live_url(@people)}}
        back_text={t("People")}
        team_text={t("Team")}
        members_heading={t("Members")}
        member_text={t("member")}
        members_text={t("members")}
        post_text={t("post")}
        posts_text={t("posts")}
        post_count_text={t("%{count} post")}
        posts_count_text={t("%{count} posts")}
        posts_heading={t("Posts by %{name}")}
        per_page={9}
        language={@page.language}
        base={#{live_url(@team, "slug")}}
        params={Map.drop(@query_params, ["lang", "slug"])}
        post_base="#{@blog}"
        author_base="#{@author}"
        missing_text={t("That team is not here, or is not active any more.")}
        members_empty_text={t("Nobody is in this team yet.")}
        empty_text={t("Nothing published yet.")}
      />
    </div>
    """)
  end

  # THE PAGE'S TITLE IS THE PAGE'S, NOT THE BLOCK'S. The design heads the people page with a small line
  # over a large `People`, which belongs to the page the way the layout's header does, so it is written
  # here — and the block under it draws the teams and the writers with no heading of its own.
  defp blog_people(site) do
    frame(:people, """
    <section class="flex flex-col gap-3 pt-16 pb-10">
      <span class="text-[12px] font-semibold tracking-[0.16em] text-subtle uppercase rtl:tracking-normal dark:text-subtle-dark">
        {t("The people behind it")}
      </span>
      <h1 class="font-newsreader text-[length:clamp(40px,5vw,60px)] font-normal tracking-[-0.03em] rtl:tracking-normal">
        {t("People")}
      </h1>
    </section>

    <.component
      component_name="blog-people"
      site="#{site}"
      id="blog-people"
      current_user={assigns[:current_user]}
      unteamed_heading={t("Writers")}
      team_text={t("Team")}
      post_text={t("%{count} post")}
      posts_text={t("%{count} posts")}
      language={@page.language}
      author_base="#{@author}"
      team_base="#{@team}"
      members_empty_text={t("Nobody is in this team yet.")}
      empty_text={t("Nobody writes here yet.")}
    />
    """)
  end

  # THE SIDEBAR SNIPPET'S SOURCE, which no page of the blog carries any more: the design's screens are
  # the whole width, and what an author wants beside the text of a page of their own is this. The
  # card chrome is here rather than in the components, because a component that drew its own card
  # could not be dropped into one.
  #
  # IT MARKS NO ROW AS THE ONE THE READER IS ON, because an author drops it on a page this module
  # knows nothing about: the page's `:slug` capture could be a category, a tag or a post there, and
  # the category list and the tag cloud both read `params` under the same default `selected_param`.
  # Handed the capture, a tag would be marked as where the reader is whenever a tag and a category
  # share a slug — and "elixir" being both is the ordinary case, not a contrived one.
  defp sidebar(site) do
    """
    <aside data-role="blog-sidebar" class="flex flex-col gap-5">
      <div class="rounded-[18px] border border-edge bg-surface p-5 dark:border-edge-dark dark:bg-surface-dark">
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
        post_base="#{@blog}"
      />

      <div class="rounded-[18px] border border-edge bg-surface p-5 dark:border-edge-dark dark:bg-surface-dark">
        <.component
          component_name="blog-tag-cloud"
          site="#{site}"
          id="blog-sidebar-tags"
          current_user={assigns[:current_user]}
          heading={t("Tags")}
          limit={24}
          show_count={true}
          language={@page.language}
          tag_base="#{@tag}"
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
        post_base="#{@blog}"
      />
    </aside>
    """
  end

  # ONE OF THE ADDRESSES ABOVE AS A URL A READER COULD HAVE TYPED, written as the `site_path/2` the
  # template calls: the `lang` capture filled in with the language this page is being read in, at the
  # address the site's URL mode gives it, which is what a pager writes to the address bar and what
  # the frame's tabs link a page by. `captured` names the page's OTHER capture, where it has one and the
  # pager's URL has to end in it; the admin's Preview assigns no captures at all, and gets no URL.
  defp live_url(address, captured \\ nil)

  defp live_url(address, nil), do: ~s|site_path("#{address}", @page.language)|

  defp live_url(address, name) do
    captures =
      ~s|%{"#{Languages.capture()}" => @page.language, "#{name}" => @query_params["#{name}"]}|

    ~s|site_path("#{address}/:#{name}", #{captures})|
  end

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

  # ---------------------------------------------------------------------------
  # The frame every page of the blog is drawn in, and the screen of the list pages
  # ---------------------------------------------------------------------------

  # HOW MANY POSTS THE FEATURED STRIP DRAWS, which is also how many the list under it leaves out so
  # that no post is on the page twice.
  @featured_strip 3

  # THE STRIP IS ITS OWN BLOCK, NOT THE LIST WITH A SWITCH. Both read posts and they read different
  # ones, so on this page they are two queries either way — and as two blocks they are also two
  # loads: whichever comes back first is drawn, and a slow read of one leaves the other standing.
  # An author can also take the strip to a page of its own, which a `featured_only` switch on the
  # list could only imitate by carrying a pager, a sort button and a heading it does not want.
  #
  # NEITHER OF THEM IS DRAWN FOR A SEARCH OR A TAG, as in the design: what was asked for is the
  # whole page then, and a strip of posts nobody asked about would push it down. The same two
  # conditions decide the list's heading and whether it leaves the strip's posts out.
  #
  # `filter` IS WHAT NARROWS THE LIST, and it is the page that says so:
  #
  #   * `:everything` — nothing; `q` and `tag` in the query string do, when a reader sends them.
  #   * `:category` — the `:slug` capture is a category. It is named by `collection`, which also
  #     makes the list head itself with the category's name and description and mark its chip.
  #   * `:tag` — the `:slug` capture is a tag, shown as the chip the design draws for one.
  defp index_screen(site, filter) do
    %{address: address, captured: captured} = index_address(filter)

    frame(:posts, """
    <section class="grid grid-cols-[repeat(auto-fit,minmax(min(100%,380px),1fr))] items-end gap-8 pt-16 pb-10">
      <div class="flex flex-col gap-3.5">
        <span class="text-xs font-semibold tracking-[0.16em] text-subtle uppercase dark:text-subtle-dark">
          {t("Journal")}
        </span>
        <h1 class="font-newsreader text-[clamp(44px,6vw,68px)] leading-none font-normal tracking-[-0.03em] text-balance">
          {t("Notes, guides &")} <em class="text-brand dark:text-[#a9a2f7]">{t("long reads")}</em>.
        </h1>
        <p class="max-w-[480px] text-[17px] leading-[1.6] text-dim dark:text-dim-dark">
          {t("Written by the team, in more than one language.")}
        </p>
      </div>

      <.component
        component_name="blog-post-search"
        site="#{site}"
        id="blog-search"
        current_user={assigns[:current_user]}
        variant="bar"
        placeholder={t("Search posts…")}
        count_text={t("posts")}
        language={@page.language}
        action={#{live_url(address, captured)}}
        params={Map.drop(@query_params, ["lang", "slug"])}
      />
    </section>

    #{featured_strip(site, filter)}
    <.component
      component_name="blog-post-list"
      site="#{site}"
      id="blog-posts"
      current_user={assigns[:current_user]}
    #{list_attributes(filter)}
      per_page={9}
      show_sort={true}
      language={@page.language}
      base={#{live_url(address, captured)}}
      params={Map.drop(@query_params, #{dropped(filter)})}
      post_base="#{@blog}"
      chips_base="#{@category}"
      all_href={#{live_url(@blog)}}
      all_text={t("All")}
      tagged_text={t("Tagged")}
      clear_text={t("Clear filters")}
      search_heading={t("Results")}
      tag_heading={t("Tagged posts")}
      no_match_text={t("No posts match.")}
      featured_text={t("Featured")}
      locked_text={t("Members")}
      minutes_text={t("min")}
      showing_text={t("Showing")}
      of_text={t("of")}
      search={@query_params["q"] || ""}
    />
    """)
  end

  # WHERE EACH VERSION OF THE SCREEN LIVES, and the capture its address ends in.
  defp index_address(:everything), do: %{address: @blog, captured: nil}
  defp index_address(:category), do: %{address: @category, captured: "slug"}
  defp index_address(:tag), do: %{address: @tag, captured: "slug"}

  # `slug` IS A CAPTURE, NOT SOMETHING A READER ASKED FOR, so it is not carried through the pager's
  # links: `site_path/2` writes it into the path they are built on.
  defp dropped(:everything), do: ~s|["lang"]|
  defp dropped(_a_page_of_its_own), do: ~s|["lang", "slug"]|

  # NO STRIP WHERE THE LIST IS NARROWED. A category's or a tag's page is the list of it alone.
  defp featured_strip(_site, filter) when filter != :everything, do: ""

  defp featured_strip(site, :everything) do
    """
    <.component
      :if={#{unfiltered()}}
      component_name="blog-featured-posts"
      site="#{site}"
      id="blog-featured"
      current_user={assigns[:current_user]}
      heading={""}
      limit={#{@featured_strip}}
      spaced={true}
      empty_text={""}
      language={@page.language}
      post_base="#{@blog}"
      featured_text={t("Featured")}
      locked_text={t("Members")}
      minutes_text={t("min")}
      minutes_long_text={t("min read")}
    />

    """
  end

  # WHAT ONE VERSION OF THE LIST IS NARROWED BY, written the way the list's attributes name it.
  defp list_attributes(:everything) do
    """
      heading={t("Latest posts")}
      tag={@query_params["tag"] || ""}
      exclude_featured={if(#{unfiltered()}, do: #{@featured_strip}, else: 0)}
      clear_href={if(#{unfiltered()}, do: "", else: #{live_url(@blog)})}
      empty_text={t("Nothing published yet.")}\
    """
  end

  defp list_attributes(:category) do
    """
      heading={t("Category")}
      collection={@query_params["slug"] || ""}
      clear_href={#{live_url(@blog)}}
      empty_text={t("Nothing is published in this category yet.")}\
    """
  end

  defp list_attributes(:tag) do
    """
      heading={t("Tag")}
      tag={@query_params["slug"] || ""}
      show_filter_title={false}
      clear_href={#{live_url(@blog)}}
      empty_text={t("Nothing is published under this tag yet.")}\
    """
  end

  # A READER HAS NOT SEARCHED AND HAS NOT FILTERED, in the one expression the strip and the list both
  # ask. `||` and not a bare read, because the admin's Preview assigns no query at all.
  defp unfiltered,
    do: ~S'String.trim(@query_params["q"] || "") == "" and (@query_params["tag"] || "") == ""'

  # THE FRAME OF A PAGE OF THE BLOG: what the site's header does not draw — the blog's own name and
  # the four places in it — and then the page, in the column the design sets it in. The header
  # itself, with the logo, the language switcher and the sign-in menu, and the footer are the site's
  # own, drawn by its layout around this; see `layout_id/1`.
  #
  # `active` IS THE PLACE THE READER IS IN, one of `:posts`, `:categories`, `:tags` and `:people`.
  # The tabs are written out in both of their looks rather than a class chosen from a hole in a
  # string, which Tailwind would not find — see `MishkaCmsWeb.InterpolatedClassTest`.
  defp frame(active, body) do
    """
    <div class="border-b border-edge dark:border-edge-dark">
      <div class="mx-auto flex w-full max-w-[1160px] flex-wrap items-center justify-between gap-4 px-8 py-3">
        <.link
          navigate={#{live_url(@blog)}}
          class="font-newsreader text-[22px] text-fg italic no-underline dark:text-fg-dark"
        >
          {t("Blog")}
        </.link>

        <nav
          data-role="blog-section-nav"
          class="flex items-center gap-1 rounded-xl border border-edge bg-surface p-1 dark:border-edge-dark dark:bg-surface-dark"
        >
    #{indent(tabs(active), 6)}
        </nav>
      </div>
    </div>

    <div class="mx-auto w-full max-w-[1160px] px-8 pb-24">
    #{indent(body, 2)}
    </div>
    """
  end

  defp tabs(active) do
    Enum.map_join(
      [
        {:posts, @blog, "Posts"},
        {:categories, @categories, "Categories"},
        {:tags, @tags, "Tags"},
        {:people, @people, "People"}
      ],
      "\n",
      fn {place, address, label} ->
        """
        <.link
          navigate={#{live_url(address)}}#{aria_current(place == active)}
          class="#{tab_class(place == active)}"
        >
          {t("#{label}")}
        </.link>
        """
      end
    )
  end

  # THE PLACE THE READER IS IN IS SAID TO A SCREEN READER TOO, not only coloured.
  defp aria_current(true), do: ~s(\n  aria-current="page")
  defp aria_current(false), do: ""

  defp tab_class(true),
    do:
      "inline-flex h-8 items-center rounded-[9px] bg-[#eceafb] px-3.5 text-[13.5px] font-medium text-brand no-underline dark:bg-[#25223f] dark:text-[#a9a2f7]"

  defp tab_class(false),
    do:
      "inline-flex h-8 items-center rounded-[9px] px-3.5 text-[13.5px] font-medium text-dim no-underline hover:text-fg dark:text-dim-dark dark:hover:text-fg-dark"
end
