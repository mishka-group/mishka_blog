<div align="center">

[![Buy Me a Coffee](https://img.shields.io/badge/Buy_Me_a_Coffee-mishkagroup-ffdd00?style=flat-square&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/mishkagroup)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-mishka--group-ea4aaa?style=flat-square&logo=github)](https://github.com/sponsors/mishka-group)

# Mishka Blog

**A multi-author [blog engine for Mishka CMS](https://mishka.tools/cms/extensions/blog), built with Elixir and Phoenix LiveView.**

[Website](https://mishka.tools/cms/extensions/blog) · [Documentation](https://mishka.tools/cms/extensions/blog/docs) · [Mishka CMS](https://mishka.tools/cms) · [Hire us](https://mishka.tools/hire-us)

</div>

## 📖 What is Mishka Blog?

`mishka_blog` is the blog extension of Mishka CMS. It adds posts, collections, tags, bloggers, editorial teams, threaded comments, ratings, bookmarks and follows to a site, with admin screens under `/admin/dashboard/blog`, a JSON:API, and ready-made page components that read the blog and draw it.

Every record belongs to a site, so each site in a Mishka CMS install has its own blog.

## 🧩 Part of Mishka CMS

Mishka Blog is an extension of [Mishka CMS](https://mishka.tools/cms), an open source real-time CMS. It runs on [mishka_cms_core](https://github.com/mishka-group/mishka_cms_core), the engine, inside the [mishka_cms](https://github.com/mishka-group/mishka_cms) application, and it is listed with the other [CMS extensions](https://mishka.tools/cms#extensions).

## ✨ Features

- Posts that are a draft, scheduled, published or archived, with a scheduled publish time (a scheduled post is published at its time by `MishkaBlog.Workers.PublishScheduledWorker`, which the host runs on its Oban crontab once a minute), an excerpt, a featured flag and image, reading time, SEO tags and Schema.org data. A post's text can place components from the site's library, and its code blocks are highlighted when the post is saved.
- Collections for nested categories, and nested tags. Posts, collections and tags can be written in several languages.
- Version history with restore for posts, collections, tags, bloggers and teams.
- Bloggers with a public profile (bio, expertise, social links and a slug). A post can have several authors. Bloggers can be grouped into teams, and each team has its own page.
- Threaded comments with the moderation states pending, approved, flagged and spam, pinning, and up and down votes.
- For readers: a 1 to 5 star rating for each post, bookmarks, follows for bloggers and teams, and a count of views and unique readers, kept in memory and written once a minute, one row per post and day.
- An analytics page with daily views, unique readers, rankings, comments and the most-read posts, over a period and filters you choose, every part of which a plugin can change.
- Seventeen page components (eleven blocks that run their own queries and six smaller pieces they draw with) and nine sample pages: the blog index, a post, a category, a tag, an author, a team, and the lists of categories, tags and people.
- The sample pages hang on the site's `site-main` layout and draw nothing around themselves. The blog hands the layout its bar (Posts, Categories, Tags and People) and, for a post, a category, a tag, a blogger or a team, the languages that record is written in, each at its own address, which the header's language menu lists.
- SEO for each record: its own head, `BlogPosting` and breadcrumb JSON-LD, `sitemap.xml` entries for posts, categories, bloggers and teams, and share cards.
- A notification to the blog's admins when a post is published, and dashboard widgets for recent posts, top posts, drafts and scheduled posts, comments to moderate, and bloggers.
- A JSON:API for admins at `/api/json/v1/master/admin/mishka-blog/…` and `/api/json/v1/tenant/admin/mishka-blog/…`, and one for readers at `/api/json/v1/user/mishka-blog/…` (published posts, comments, ratings, bookmarks, follows and votes), described in the CMS's OpenAPI spec.
- Permissions `admin:dashboard:blog:post`, `admin:dashboard:blog:publish` and `admin:dashboard:blog:comment`, with `admin:api:` twins for the API, so a moderator can hold the comments alone. A blogger whose profile is not set to Can Publish Directly saves drafts for an editor to publish, unless they hold `admin:dashboard:blog:publish`.
- Events for plugins, such as `blog:blog_post:after_publish` and `blog:comment:after_create`. An extension adds buttons to the header of the dashboard on `blog:dashboard:actions`: a plugin answers `%{actions: [...]}` with an `id`, `label`, `icon`, `priority` and a `path:` or a `js:` command (see `MishkaBlog.Dashboard.Actions`). A plugin on `blog:post:can_publish` allows or refuses a publish (see `MishkaBlog.Resources.Validations.PublishDirectly`). A plugin on `blog:post:published` hears every post that becomes published (see `MishkaBlog.Resources.Changes.PublishLifecycle`), one on `blog:post:count_view` decides whether a view counts (see `MishkaBlog.Plugins.PostViewCount`), one on `blog:post:viewed` is handed each minute's views (see `MishkaBlog.Views`), and the Analytics page is built from three events, shown below.

## 📊 Extending the Analytics page

`/admin/dashboard/blog/analytics` is drawn from two lists a plugin can change, and every panel's data passes one event before it is drawn (see `MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Panels`):

- `blog:analytics:panels` hands the panels, in order, as `%{panels: [...], current_user: user}`. A panel is `%{id:, title:, icon:, size:, tabs: [...]}`, and a tab is `%{id:, label:, note:, needs:, data:, load: {module, function, args}, component: &fun/1}`. Add, remove or reorder panels, or add a tab to one. A tab's `load` is called off the render with `args ++ [user, period, comments?]`, and its `component` gets `@data` once it lands, with `@period`, `@sort`, `@areas` and `@socket`.
- `blog:analytics:panel` hands each panel's data, the built-in ones included, as `%{panel: data_id, period:, current_user:, data:}`. Answer it with `data` changed to put another source's numbers in its place.
- `blog:analytics:filters` hands the filter bar, `%{filters: [...], current_user: user}`. A filter is `%{id:, label:, choices: {module, function, args}}`, whose `choices` answer `{[{label, value}], more?}` for `args ++ [user, opts]`. Its value is in the URL and in every panel's `period.filters`.

Views Over Time from Plausible instead of the blog's own count, keeping the rest of the overview:

```elixir
defmodule MyApp.PlausibleViews do
  use MishkaInstaller.Event.Hook, event: "blog:analytics:panel"

  @impl true
  def call(%{panel: :overview, period: period, data: data} = state) do
    series = MyApp.Plausible.daily_pageviews(period.from, period.to)
    {:reply, %{state | data: %{data | series: series, views_window: Enum.sum_by(series, & &1.count)}}}
  end

  def call(state), do: {:reply, state}
end
```

A new "Referrers (Plausible)" box, read off the render like the built-in ones, with a Source filter:

```elixir
defmodule MyApp.PlausibleReferrers do
  use MishkaInstaller.Event.Hook, event: "blog:analytics:panels"
  use Phoenix.Component

  @impl true
  def call(%{panels: panels} = state) do
    box = %{
      id: "referrers",
      title: "Referrers (Plausible)",
      icon: "hero-globe-alt",
      size: :half,
      tabs: [%{id: "referrers", data: :referrers, needs: [:post],
               load: {__MODULE__, :read, []}, component: &__MODULE__.card/1}]
    }

    {:reply, %{state | panels: panels ++ [box]}}
  end

  def read(_user, period, _comments?),
    do: MyApp.Plausible.referrers(period.from, period.to, period.filters["source"])

  def card(assigns) do
    ~H"""
    <ul><li :for={row <- @data}>{row.host} · {row.visits}</li></ul>
    """
  end
end

defmodule MyApp.PlausibleSource do
  use MishkaInstaller.Event.Hook, event: "blog:analytics:filters"

  @impl true
  def call(%{filters: filters} = state),
    do: {:reply, %{state | filters: filters ++ [%{id: "source", label: "Source", choices: {__MODULE__, :sources, []}}]}}

  def sources(_user, _opts), do: {[{"Plausible", "plausible"}, {"Google Analytics", "ga"}], false}
end
```

To send the blog's own counts to Google Analytics or Plausible from the server, listen on `blog:post:viewed`: it is handed each minute's views, `%{views: [%{site_id:, post_id:, day:, views:, unique_readers:}]}`, after they are written (see `MishkaBlog.Views`).

## 🚀 Getting started

Mishka Blog is installed with [Mishka CMS](https://github.com/mishka-group/mishka_cms#-getting-started). Add it from Hex:

```elixir
{:mishka_blog, "~> 0.0.3-alpha.2"}
```

[Mishka CMS](https://github.com/mishka-group/mishka_cms) loads it from `__extensions/mishka_blog` instead when that folder exists.

Mishka CMS registers it in three places: `MishkaBlog` in `ash_domains` and `MishkaBlogWeb` in the core's `extensions` list, both in `config/config.exs`, and `MishkaBlog` in the domains of the JSON:API router.

Then install the blog onto a site. Tick Blog in the install wizard, or open the Blog dashboard of a site that does not have it yet and press Set up. Either way the site gets the seventeen components, the nine sample pages and a sidebar snippet. Running it again adds only what is missing and leaves anything you edited.

For sample bloggers, posts and comments in development, run `mix run priv/repo/dev_seeds.exs` in `mishka_cms`.

## 📚 Documentation

- [Mishka Blog documentation](https://mishka.tools/cms/extensions/blog/docs), which is still being written
- [Features](https://mishka.tools/cms/extensions/blog#features), the [post editor](https://mishka.tools/cms/extensions/blog#editor), [SEO](https://mishka.tools/cms/extensions/blog#seo), the [REST API](https://mishka.tools/cms/extensions/blog#integrations) and the [admin preview](https://mishka.tools/cms/extensions/blog#demo)
- [Mishka CMS documentation](https://mishka.tools/cms/docs)
- [Mishka Installer documentation](https://mishka.tools/installer/docs), for plugins and events
- The [Mishka blog](https://mishka.tools/blog)

## 💬 Community and support

- Report a bug or ask a question in [GitHub issues](https://github.com/mishka-group/mishka_blog/issues).
- Read about new releases on the [Mishka blog](https://mishka.tools/blog).
- For a custom blog feature, a migration from another CMS or priority support, [hire the Mishka team](https://mishka.tools/hire-us).

## 💖 Support the project

Mishka CMS and its extensions are free and open source. You can support their development through [GitHub Sponsors](https://github.com/sponsors/mishka-group) or [Buy Me a Coffee](https://www.buymeacoffee.com/mishkagroup).

## 📜 License

Apache License 2.0. See [LICENSE](LICENSE).
