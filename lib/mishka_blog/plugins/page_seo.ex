# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.PageSeo do
  @moduledoc """
  Gives each post, category, tag, blogger and team its own head on the blog page that serves it,
  through the
  `runtime:page:seo` mishka_installer hook `MishkaCmsWeb.RuntimeLive` fires in
  `handle_params/3` (see `MishkaCmsCore.Runtime.Seo` for the map it is handed and what the head
  builds from it).

  A page is matched by the kind of record it says it shows (`record`, its `extra`'s `"record"`):
  `"blog:post"`, `"blog:category"`, `"blog:tag"`, `"blog:author"` or `"blog:team"`, the kinds
  `MishkaBlog.Plugins.PageRecords`
  names. Its path may be anything that captures the `slug`. Every other page is handed back
  untouched before anything is read. A kind has one owner, so the answer for one of these halts the
  chain: no later plugin is asked.

  Everything returned is a default: what the page sets in its own SEO — a title, a description, a
  tag, structured data — wins, and may name the variables below, `{{post.title}} | Blog`.

  ## What is read

  Nothing, on a page a visitor reads: `MishkaCmsWeb.RuntimeLive` hands it the rows the page read
  once for its head, its frame and its blocks, as the visitor (`source`, `MishkaBlog.PageSource`),
  and the record below is the one there, with what that read loaded. A record the visitor's read
  left out is answered with its lock alone, read here as the system, so the address answers them
  404 and nothing else of it reaches them. An editor's preview and a share card hand no rows, and
  the record is read here, once: a post, a category or a tag as the system, and a blogger or a
  team, which carry no lock of their own, as a guest, through the public action.

  ## A post, `"blog:post"`

  The post the `slug` capture names in the page's language, published — read through
  `:public_list` as `blog-post-detail` reads it, on the page's site, with its authors, categories,
  tags and its other published editions:

    * `title`, `description`, `image` — the post's title, excerpt and featured image;
    * `type` — `"article"`;
    * `tags` — `author` (the authors' names), a `twitter:creator` with the X account of the first
      author, in the authors' order, who has one, `article:published_time`, `article:modified_time`,
      `article:section` (the first category), one `article:tag` per tag, the pairs Slack and
      Discord show under a link — `twitter:label1`/`twitter:data1`, then `twitter:label2`/
      `twitter:data2`: "Written by" the authors' names, "Reading time" the post's, each only when
      known and numbered from 1 — and a `rel="alternate"` link per language the post is published
      in among the site's languages, with `x-default` at the site's primary one, when there are two
      or more. The post's own `seo_tags` come last and replace any of these they name;
    * `schema` — the post's own `schema` when it holds one, else a `BlogPosting` whose `author` is
      a `Person` per author — their name, their address on the site's `"blog:author"` page and
      `sameAs` their social links — whose `articleSection` is the first category, and whose
      `publisher` is the site's Organization by its `@id`, `<site address>/#organization`; then a
      `BreadcrumbList`, Home → Blog → the post;
    * `vars` — `post.title`, `post.excerpt`, `post.image`, `post.author`, `post.published_at`,
      `post.modified_at`, `post.url`, `post.collection`, `post.tags`, and `post.rating` (the
      readers' average, one decimal) with `post.rating_count` once a reader has rated it.

  `card` — what its share card shows (`MishkaCmsCore.Runtime.ShareCard`): the first category above
  the title, the authors' photos and names, their teams, the date and the reading time, over the
  featured image.

  ## A category, `"blog:category"`

  The active category the `slug` capture names in the page's language: its name and description,
  its own `seo_tags`, its own `schema` (else a `CollectionPage`) and a
  `BreadcrumbList`, Home → Blog → the category. `vars` — `collection.name`,
  `collection.description`, `collection.url`. Its share card says "Category" above the name.

  ## A tag, `"blog:tag"`

  The tag the `slug` capture names in the page's language: its name and description, its own
  `seo_tags`, a `CollectionPage` and a `BreadcrumbList`, Home → Blog → the tag. A public tag says
  `robots` `noindex, follow`, unless its own `seo_tags` hold a `robots`; the sitemap lists exactly the
  tags that say `index` (`MishkaBlog.Plugins.SitemapUrls`). `vars` — `tag.name`, `tag.description`,
  `tag.url`. Its share card says "Tag" above the name.

  ## A blogger, `"blog:author"`

  The blogger the `slug` capture names: their name, their bio as plain text, their avatar, a
  `twitter:creator` with their X account when they have one, a
  `ProfilePage` whose `mainEntity` is the `Person` — with `sameAs` their social links and
  `knowsAbout` their expertise — and a `BreadcrumbList`, Home → Blog → the blogger. `vars` —
  `author.name`, `author.bio`, `author.image`, `author.url`. Its share card says "Author" above the
  name, with their photo and their teams. A blogger is the same row in every language, so the slug
  alone names them.

  ## A team, `"blog:team"`

  The active team the `slug` capture names: its name, description and avatar, a `ProfilePage`
  whose `mainEntity` is the `Organization` with its members as `Person`s, and a `BreadcrumbList`,
  Home → Blog → the team. `vars` — `team.name`, `team.description`, `team.url`. Its share card
  says "Team" above the name, with the members' photos and how many they are.

  ## Where "Blog" points

  The breadcrumb's middle item is the blog's home, read off the page's own path: the post page's
  parent, the parent of every other kind's parent — `/blog/:slug` and `/blog/tag/:slug` both lead
  to `/blog`, `/:lang/blog/:slug` to `/:lang/blog` in the page's language.

  ## What every matched page returns

  `permissions` — what the record opens with: named, `MishkaCmsWeb.RuntimeLive` opens the address
  only for whoever holds one of them, and the head keeps it out of an index. A tag opens with its
  own; a category with its own, else its nearest parent category's; a post with its own, else its
  categories' (`MishkaBlog.Resources.Calculations.EffectivePermissions`).

  `var_docs` lists the page's variables in the current locale, whether or not this request filled
  them. Called with no `params` — an editor asking which variables a page has — that is all it
  changes. A slug that names no row a reader may open changes nothing else.

  A module because a mishka_installer hook is one. Registered in `MishkaBlog.Application`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext
  use MishkaInstaller.Event.Hook, event: "runtime:page:seo", initial: %{priority: 50}

  require Ash.Query

  alias MishkaBlog.{Blogger, BlogPost, Collection, PageSource, Tag, Team}
  alias MishkaCmsCore.Localized
  alias MishkaCmsCore.PlainText
  alias MishkaCmsCore.Runtime.{Languages, Page, Seo}

  @post_fields [
    :id,
    :title,
    :slug,
    :excerpt,
    :featured_image_url,
    :reading_time_minutes,
    :published_at,
    :updated_at,
    :language,
    :language_group_id,
    :seo_tags,
    :schema,
    :permissions
  ]

  @collection_fields [
    :id,
    :name,
    :slug,
    :description,
    :language,
    :seo_tags,
    :schema,
    :permissions
  ]
  @tag_fields [:id, :name, :slug, :description, :language, :seo_tags, :permissions]
  @blogger_fields [:id, :display_name, :slug, :bio, :avatar_url, :social_links, :expertise_areas]
  @team_fields [:id, :name, :slug, :description, :avatar_url]
  @x_hosts ~w(x.com twitter.com www.x.com www.twitter.com mobile.twitter.com)

  @impl true
  def call(%{record: "blog:post"} = seo), do: {:reply, :halt, post(seo)}
  def call(%{record: "blog:category"} = seo), do: {:reply, :halt, category(seo)}
  def call(%{record: "blog:tag"} = seo), do: {:reply, :halt, tag(seo)}
  def call(%{record: "blog:author"} = seo), do: {:reply, :halt, author(seo)}
  def call(%{record: "blog:team"} = seo), do: {:reply, :halt, team(seo)}
  def call(seo), do: {:reply, seo}

  # The photos, names and teams a share card shows of a post's authors, their X accounts, and the
  # slugs and links their `Person` is written from.
  defp people_query do
    Blogger
    |> Ash.Query.select([:display_name, :slug, :avatar_url, :social_links])
    |> Ash.Query.sort(display_name: :asc)
    |> Ash.Query.load(
      teams:
        Team
        |> Ash.Query.select([:name])
        |> Ash.Query.sort(name: :asc)
        |> Ash.Query.page(limit: 5)
    )
  end

  # THE RECORD IS THE PAGE'S OWN READ, made once for its head, its frame and its blocks as the
  # visitor (`source`, `MishkaBlog.PageSource`), when `MishkaCmsWeb.RuntimeLive` hands it over; a read
  # of its own, as the system, for an editor's preview and a share card, which hand none.
  defp post(seo) do
    seo = %{seo | var_docs: post_docs()}

    case shared(seo) do
      {:ok, %BlogPost{} = post} -> post_seo(seo, post)
      {:ok, nil} -> locked(seo, BlogPost, [:effective_permissions], & &1.effective_permissions)
      :none -> system(seo, read(BlogPost, seo, @post_fields, post_loads()), &post_seo/2)
    end
  end

  defp category(seo) do
    seo = %{seo | var_docs: collection_docs()}

    case shared(seo) do
      {:ok, %Collection{} = collection} ->
        collection_seo(seo, collection)

      {:ok, nil} ->
        locked(seo, Collection, [:effective_permissions], & &1.effective_permissions)

      :none ->
        system(
          seo,
          read(Collection, seo, @collection_fields, [:effective_permissions]),
          &collection_seo/2
        )
    end
  end

  defp tag(seo) do
    seo = %{seo | var_docs: tag_docs()}

    case shared(seo) do
      {:ok, %Tag{} = tag} -> tag_seo(seo, tag)
      {:ok, nil} -> locked(seo, Tag, [], & &1.permissions)
      :none -> system(seo, read(Tag, seo, @tag_fields, []), &tag_seo/2)
    end
  end

  # A BLOGGER AND A TEAM CARRY NO LOCK OF THEIR OWN: one the visitor's read does not find is not
  # here, and the page answers that.
  defp author(seo) do
    seo = %{seo | var_docs: author_docs()}

    case shared(seo) do
      {:ok, %Blogger{} = blogger} ->
        author_seo(seo, blogger)

      {:ok, nil} ->
        seo

      :none ->
        seo
        |> read_one(Blogger, @blogger_fields,
          teams:
            Team
            |> Ash.Query.select([:name])
            |> Ash.Query.sort(name: :asc)
            |> Ash.Query.page(limit: 5)
        )
        |> then(&system(seo, &1, fn seo, blogger -> author_seo(seo, blogger) end))
    end
  end

  defp team(seo) do
    seo = %{seo | var_docs: team_docs()}

    case shared(seo) do
      {:ok, %Team{} = team} ->
        team_seo(seo, team)

      {:ok, nil} ->
        seo

      :none ->
        members =
          Blogger
          |> Ash.Query.for_read(:public_list)
          |> Ash.Query.select([:display_name, :slug, :avatar_url])
          |> Ash.Query.sort(:display_name)

        seo
        |> read_one(Team, @team_fields, tenant_members: members)
        |> then(&system(seo, &1, fn seo, team -> team_seo(seo, team) end))
    end
  end

  # `{:ok, record}` out of the rows the page read once, as its visitor, for this same page — `nil`
  # where the visitor's read found none — and `:none` for a caller that handed no rows. The head is
  # handed no visitor of its own: the source core hands it is the one read for this request.
  defp shared(%{source: %PageSource{record: record} = source} = seo) do
    if PageSource.for_page?(source, seo), do: {:ok, record}, else: :none
  end

  defp shared(_no_source), do: :none

  defp system(seo, nil, _answer), do: seo
  defp system(seo, record, answer), do: answer.(seo, record)

  # A RECORD THE VISITOR'S OWN READ LEFT OUT: its lock alone is read, as the system, for
  # `MishkaCmsWeb.RuntimeLive` to refuse them with, and the head says nothing else of it — nothing of
  # a record reaches a visitor it was kept from. One whose lock names nothing was left out for a
  # reason the lock does not say, and opens for whoever holds `*`, as a record whose lock could not
  # be read does (`MishkaCmsCore.Runtime.Seo`). A slug the system finds nothing at changes nothing.
  defp locked(seo, resource, loads, lock_of) do
    case read(resource, seo, [:id, :permissions], loads) do
      nil ->
        seo

      record ->
        case List.wrap(lock_of.(record)) do
          [] -> %{seo | permissions: ["*"], card: false}
          lock -> %{seo | permissions: lock, card: false}
        end
    end
  end

  # The row the `slug` capture names, in the page's language, on the page's site; `nil` when the
  # request names none or none is shown. Read as the system, for the two callers that are no
  # visitor — a preview and a share card — and for the lock `MishkaCmsWeb.RuntimeLive` admits the
  # visitor by when the visitor's own read left the record out: read as a visitor who may not open
  # it, a locked record is no record at all, and the gate is handed no permissions to refuse them
  # with.
  defp read(resource, %{params: %{"slug" => slug}, site_id: site_id} = seo, fields, loads)
       when is_binary(slug) and slug != "" and is_binary(site_id) do
    resource
    |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.filter(slug == ^slug)
    |> in_language(seo.language)
    |> Ash.Query.select(fields)
    |> Ash.Query.load(loads)
    |> Ash.read(tenant: site_id, authorize?: false, page: [limit: 1])
    |> case do
      {:ok, %{results: [row | _rest]}} -> row
      _none -> nil
    end
  end

  defp read(_resource, _seo, _fields, _loads), do: nil

  # A blogger or a team is one row in every language: the slug alone names it. Read as a guest
  # reads it, through the public action, for a caller handed no rows.
  defp read_one(%{params: %{"slug" => slug}, site_id: site_id}, resource, fields, loads)
       when is_binary(slug) and slug != "" and is_binary(site_id) do
    resource
    |> Ash.Query.for_read(:public_list, %{}, tenant: site_id)
    |> Ash.Query.filter(slug == ^slug)
    |> Ash.Query.select(fields)
    |> Ash.Query.load(loads)
    |> Ash.read(tenant: site_id, page: [limit: 1])
    |> case do
      {:ok, %{results: [row | _rest]}} -> row
      _none -> nil
    end
  end

  defp read_one(_seo, _resource, _fields, _loads), do: nil

  defp in_language(query, language) when is_binary(language) and language != "",
    do: Ash.Query.filter(query, language == ^language)

  defp in_language(query, _no_language), do: query

  defp post_loads do
    [
      :rating_average,
      :rating_count,
      :effective_permissions,
      bloggers: people_query(),
      collections:
        Collection
        |> Ash.Query.select([:name])
        |> Ash.Query.sort(display_order: :asc, name: :asc),
      tags:
        Tag
        |> Ash.Query.select([:name])
        |> Ash.Query.sort(name: :asc)
        |> Ash.Query.page(limit: 50),
      editions:
        BlogPost
        |> Ash.Query.select([:id, :slug, :language, :title])
        |> Ash.Query.sort(language: :asc)
    ]
  end

  defp post_seo(seo, post) do
    base = base(seo)
    image = Seo.absolute(post.featured_image_url, base)
    authors = Enum.map(post.bloggers, & &1.display_name)
    tag_names = Enum.map(rows(post.tags), & &1.name)
    section = post.collections |> List.first() |> then(&(&1 && &1.name))
    published = iso8601(post.published_at)
    modified = iso8601(post.updated_at)

    posting =
      compact(%{
        "@context" => "https://schema.org",
        "@type" => "BlogPosting",
        "headline" => post.title,
        "description" => post.excerpt,
        "image" => image,
        "datePublished" => published,
        "dateModified" => modified,
        "author" => authors(post, seo.site_id, base),
        "publisher" => publisher(base),
        "mainEntityOfPage" => seo.url,
        "inLanguage" => post.language,
        "articleSection" => section,
        "keywords" => Enum.join(tag_names, ", ")
      })

    generated =
      List.flatten([
        meta("name", "author", Enum.join(authors, ", ")),
        meta(
          "name",
          "twitter:creator",
          Enum.find_value(post.bloggers, &x_account(&1.social_links))
        ),
        meta("property", "article:published_time", published),
        meta("property", "article:modified_time", modified),
        meta("property", "article:section", section),
        Enum.map(tag_names, &meta("property", "article:tag", &1)),
        preview_pairs(authors, post),
        alternates(post, seo, base)
      ])

    %{
      seo
      | title: post.title,
        description: post.excerpt,
        image: post.featured_image_url || seo.image,
        type: "article",
        language: post.language,
        tags: with_own(generated, post.seo_tags),
        schema:
          own_schema(post.schema, posting) ++
            breadcrumb(seo, base, 1, post.title),
        permissions: post.effective_permissions,
        card: %{
          eyebrow: section,
          people: Enum.map(post.bloggers, &person/1),
          byline: teams_of(post.bloggers),
          meta: Enum.reject([day(post.published_at, post.language), minutes(post)], &is_nil/1),
          picture: post.featured_image_url
        },
        vars:
          Map.merge(
            seo.vars,
            compact(%{
              "post.title" => post.title,
              "post.excerpt" => post.excerpt,
              "post.image" => image,
              "post.author" => Enum.join(authors, ", "),
              "post.published_at" => published,
              "post.modified_at" => modified,
              "post.url" => seo.url,
              "post.collection" => section,
              "post.tags" => Enum.join(tag_names, ", "),
              "post.rating" => rating(post),
              "post.rating_count" => rated(post)
            })
          )
    }
  end

  defp collection_seo(seo, collection) do
    base = base(seo)

    page =
      compact(%{
        "@context" => "https://schema.org",
        "@type" => "CollectionPage",
        "name" => collection.name,
        "description" => collection.description,
        "url" => seo.url,
        "inLanguage" => collection.language
      })

    %{
      seo
      | title: collection.name,
        description: collection.description,
        language: collection.language,
        tags: List.wrap(collection.seo_tags),
        schema:
          own_schema(collection.schema, page) ++
            breadcrumb(seo, base, 2, collection.name),
        permissions: collection.effective_permissions,
        card: %{eyebrow: gettext("Category")},
        vars:
          Map.merge(
            seo.vars,
            compact(%{
              "collection.name" => collection.name,
              "collection.description" => collection.description,
              "collection.url" => seo.url
            })
          )
    }
  end

  defp tag_seo(seo, tag) do
    base = base(seo)

    page =
      compact(%{
        "@context" => "https://schema.org",
        "@type" => "CollectionPage",
        "name" => tag.name,
        "description" => tag.description,
        "url" => seo.url,
        "inLanguage" => tag.language
      })

    %{
      seo
      | title: tag.name,
        description: tag.description,
        language: tag.language,
        tags: with_own(tag_robots(tag.permissions), tag.seo_tags),
        schema: [page | breadcrumb(seo, base, 2, tag.name)],
        permissions: List.wrap(tag.permissions),
        card: %{eyebrow: gettext("Tag")},
        vars:
          Map.merge(
            seo.vars,
            compact(%{
              "tag.name" => tag.name,
              "tag.description" => tag.description,
              "tag.url" => seo.url
            })
          )
    }
  end

  defp author_seo(seo, blogger) do
    base = base(seo)
    bio = plain(blogger.bio)
    image = Seo.absolute(blogger.avatar_url, base)

    person =
      compact(%{
        "@type" => "Person",
        "name" => blogger.display_name,
        "description" => bio,
        "image" => image,
        "url" => seo.url,
        "sameAs" => links(blogger.social_links),
        "knowsAbout" => List.wrap(blogger.expertise_areas)
      })

    profile =
      compact(%{
        "@context" => "https://schema.org",
        "@type" => "ProfilePage",
        "url" => seo.url,
        "mainEntity" => person
      })

    %{
      seo
      | title: blogger.display_name,
        description: bio,
        image: blogger.avatar_url || seo.image,
        type: "profile",
        tags: meta("name", "twitter:creator", x_account(blogger.social_links)),
        schema: [profile | breadcrumb(seo, base, 2, blogger.display_name)],
        permissions: [],
        card: %{
          eyebrow: gettext("Author"),
          people: [person(blogger)],
          byline: teams_of([blogger]),
          picture: nil
        },
        vars:
          Map.merge(
            seo.vars,
            compact(%{
              "author.name" => blogger.display_name,
              "author.bio" => bio,
              "author.image" => image,
              "author.url" => seo.url
            })
          )
    }
  end

  defp team_seo(seo, team) do
    base = base(seo)

    organization =
      compact(%{
        "@type" => "Organization",
        "name" => team.name,
        "description" => team.description,
        "logo" => Seo.absolute(team.avatar_url, base),
        "url" => seo.url,
        "member" => Enum.map(members_of(team), &%{"@type" => "Person", "name" => &1.display_name})
      })

    profile =
      compact(%{
        "@context" => "https://schema.org",
        "@type" => "ProfilePage",
        "url" => seo.url,
        "mainEntity" => organization
      })

    %{
      seo
      | title: team.name,
        description: team.description,
        image: team.avatar_url || seo.image,
        schema: [profile | breadcrumb(seo, base, 2, team.name)],
        permissions: [],
        card: %{
          eyebrow: gettext("Team"),
          people: team |> members_of() |> Enum.map(&person/1),
          meta: [members(length(members_of(team)))],
          picture: nil
        },
        vars:
          Map.merge(
            seo.vars,
            compact(%{
              "team.name" => team.name,
              "team.description" => team.description,
              "team.url" => seo.url
            })
          )
    }
  end

  defp person(blogger), do: %{name: blogger.display_name, image: blogger.avatar_url}

  # The teams of `bloggers`, each once; `nil` for none.
  defp teams_of(bloggers) do
    case bloggers |> Enum.flat_map(&rows(&1.teams)) |> Enum.map(& &1.name) |> Enum.uniq() do
      [] -> nil
      names -> names |> Enum.take(2) |> Enum.join(", ")
    end
  end

  # The day a post was published, in the post's language: `Mar 3, 2025` in English.
  defp day(%DateTime{} = at, language), do: Localized.date(at, :yMMMd, locale: language)
  defp day(_never, _language), do: nil

  defp minutes(%{reading_time_minutes: minutes}) when is_integer(minutes) and minutes > 0,
    do: ngettext("%{count} min read", "%{count} min read", minutes)

  defp minutes(_unknown), do: nil

  defp members(count), do: ngettext("%{count} member", "%{count} members", count)

  # The label and value pairs Slack and Discord show under a link's description, as
  # `twitter:label<n>` and `twitter:data<n>`: who wrote the post and how long it takes to read. A
  # pair is shown only when both halves are there, so the ones known are numbered from 1.
  defp preview_pairs(authors, post) do
    [
      {gettext("Written by"), Enum.join(authors, ", ")},
      {gettext("Reading time"), minutes(post)}
    ]
    |> Enum.filter(fn {_label, value} -> is_binary(value) and value != "" end)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {{label, value}, number} ->
      meta("name", "twitter:label#{number}", label) ++
        meta("name", "twitter:data#{number}", value)
    end)
  end

  # The text the bio's HTML shows, on one line: escaped once, where the head writes it out.
  defp plain(html) when is_binary(html),
    do: html |> PlainText.from_html() |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp plain(_none), do: nil

  defp links(links) do
    for link <- List.wrap(links), url = field(link, :url), is_binary(url) and url != "", do: url
  end

  # The first of `links` that is an X account, as `@handle`; `nil` for none. A link is one when its
  # address is on X, or names no host and its platform is `x` or `twitter`, and its handle is one X
  # accepts.
  defp x_account(links), do: links |> List.wrap() |> Enum.find_value(&x_handle/1)

  defp x_handle(link) do
    with url when is_binary(url) <- field(link, :url),
         {host, handle} <- x_address(String.trim(url)),
         true <- x_link?(host, field(link, :platform)),
         true <- is_binary(handle) and Regex.match?(~r/^[A-Za-z0-9_]{1,15}$/, handle) do
      "@" <> handle
    else
      _not_an_x_account -> nil
    end
  end

  # `{host, handle}`, read off the address as `URI.parse/1` parses it: no host for `@handle` or
  # `handle` alone; else an `http` or `https` address's host, with no user info, and its path's
  # first segment. An address with no scheme is read as `https`.
  defp x_address("@" <> handle), do: {nil, handle}

  defp x_address(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, userinfo: nil, host: host, path: path}
      when scheme in ["http", "https"] and is_binary(host) ->
        {String.downcase(host), first_segment(path)}

      %URI{scheme: nil, host: nil, path: ^url} ->
        if String.contains?(url, "/"), do: x_address("https://" <> url), else: {nil, url}

      _not_an_address ->
        nil
    end
  end

  defp first_segment(path) when is_binary(path),
    do: path |> String.split("/", trim: true) |> List.first()

  defp first_segment(_no_path), do: nil

  defp x_link?(nil, platform) when is_binary(platform),
    do: String.downcase(String.trim(platform)) in ["x", "twitter"]

  defp x_link?(host, _platform), do: host in @x_hosts

  # The readers' average to one decimal, and how many rated; nothing before the first rating.
  defp rating(%{rating_count: count, rating_average: average})
       when is_integer(count) and count > 0,
       do: one_decimal(average)

  defp rating(_unrated), do: nil

  defp one_decimal(%Decimal{} = average),
    do: average |> Decimal.round(1) |> Decimal.to_string(:normal)

  defp one_decimal(average) when is_number(average),
    do: :erlang.float_to_binary(average / 1, decimals: 1)

  defp one_decimal(_none), do: nil

  defp rated(%{rating_count: count}) when is_integer(count) and count > 0, do: count
  defp rated(_unrated), do: nil

  # Each language the post is published in among the site's own, at its address, and `x-default` at
  # the site's primary language — `MishkaCmsCore.Runtime.Seo.alternate_links/3`, the head's own
  # rule; nothing for a post in one language.
  defp alternates(post, %{page: %{path: path}, site_id: site_id}, base) do
    served = Languages.site(site_id)

    editions =
      for edition <-
            [post | rows(post.editions)]
            |> Enum.uniq_by(& &1.language)
            |> Enum.sort_by(& &1.language),
          edition.language in served,
          captures = %{Languages.capture() => edition.language, "slug" => edition.slug},
          address = Languages.url(path, captures, site_id),
          is_binary(address),
          do: %{language: edition.language, path: address}

    Seo.alternate_links(editions, base, site_id)
  end

  # A relationship read through an action that pages arrives as a page.
  defp rows(%Ash.Page.Offset{results: results}), do: results
  defp rows(rows) when is_list(rows), do: rows
  defp rows(_not_loaded), do: []

  # A team's members: the ones its page read with it, as its visitor, else the ones read here.
  defp members_of(%{members: members}) when is_list(members), do: members
  defp members_of(team), do: rows(team.tenant_members)

  defp meta(key, name, value) when is_binary(value) and value != "",
    do: [%{tag: "meta", attrs: %{key => name}, content: value}]

  defp meta(_key, _name, _no_value), do: []

  # The record's own tags last, each replacing every generated tag of the same name and attributes.
  defp with_own(generated, own) do
    own = List.wrap(own)
    named = MapSet.new(own, &identity/1)
    Enum.reject(generated, &MapSet.member?(named, identity(&1))) ++ own
  end

  defp identity(tag) do
    attrs =
      for {key, value} <- field(tag, :attrs) || %{},
          key = String.downcase(to_string(key)),
          key not in ["content", "href"],
          into: %{},
          do: {key, value}

    {tag |> field(:tag) |> to_string() |> String.downcase(), attrs}
  end

  defp field(%{} = map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_not_a_map, _key), do: nil

  # The record's own JSON-LD, else the one built for it.
  defp own_schema([_ | _] = own, _built), do: own
  defp own_schema(_none, built), do: [built]

  defp breadcrumb(_seo, nil, _depth, _name), do: []

  # `depth` is how many segments of the page's path come after the blog's home: one for a post,
  # two for a category, a tag, a blogger or a team.
  defp breadcrumb(
         %{language: language, url: url, page: %{path: path}, site_id: site_id},
         base,
         depth,
         name
       ) do
    blog_url =
      path
      |> drop_segments(depth)
      |> Languages.url(%{Languages.capture() => language}, site_id)
      |> Seo.absolute(base)

    items =
      Enum.reject(
        [{gettext("Home"), base}, {gettext("Blog"), blog_url}, {name, url}],
        fn {_name, item} -> is_nil(item) end
      )

    [
      %{
        "@context" => "https://schema.org",
        "@type" => "BreadcrumbList",
        "itemListElement" =>
          items
          |> Enum.with_index(1)
          |> Enum.map(fn {{name, item}, position} ->
            %{"@type" => "ListItem", "position" => position, "name" => name, "item" => item}
          end)
      }
    ]
  end

  defp drop_segments(path, 0), do: path
  defp drop_segments(path, depth), do: path |> Path.dirname() |> drop_segments(depth - 1)

  # The site's own Organization, by the `@id` core gives it.
  defp publisher(base) when is_binary(base), do: %{"@id" => base <> "/#organization"}
  defp publisher(_no_base), do: nil

  # Each author as a `Person`: their name, their profile at the site's blogger page in the post's
  # language, and their social links.
  defp authors(%{bloggers: []}, _site_id, _base), do: []

  defp authors(post, site_id, base) do
    profiles = profiles_path(site_id)

    Enum.map(post.bloggers, fn blogger ->
      compact(%{
        "@type" => "Person",
        "name" => blogger.display_name,
        "url" => profile_url(profiles, blogger.slug, post.language, site_id, base),
        "sameAs" => links(blogger.social_links)
      })
    end)
  end

  # The path of the site's page that shows a blogger (`"blog:author"`), active and open to every
  # visitor, the first by path; `nil` for none. Read as the system, as `read/4` reads.
  defp profiles_path(site_id) do
    Page
    |> Ash.Query.filter(active == true and extra["record"] == "blog:author")
    |> Ash.Query.select([:path, :permissions])
    |> Ash.Query.sort(path: :asc)
    |> Ash.read(tenant: site_id, authorize?: false, page: false)
    |> case do
      {:ok, pages} -> Enum.find_value(pages, &(&1.permissions in [nil, []] && &1.path))
      _unreadable -> nil
    end
  end

  defp profile_url(nil, _slug, _language, _site_id, _base), do: nil

  defp profile_url(path, slug, language, site_id, base),
    do:
      path
      |> Languages.url(%{Languages.capture() => language, "slug" => slug}, site_id)
      |> Seo.absolute(base)

  # `robots` "noindex, follow" for a public tag; nothing for one that names a permission, which the
  # head keeps out of an index already.
  defp tag_robots([_ | _] = _permissions), do: []
  defp tag_robots(_no_permissions), do: meta("name", "robots", "noindex, follow")

  # The address of the site the canonical address is on, as `Seo.base/1` writes it.
  defp base(%{url: url}) when is_binary(url),
    do: url |> URI.parse() |> Map.get(:host) |> Seo.base()

  defp base(_no_url), do: nil

  defp iso8601(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp iso8601(_never), do: nil

  defp compact(map), do: Map.reject(map, fn {_key, value} -> value in [nil, "", []] end)

  defp post_docs do
    [
      var(
        "post.title",
        gettext("Post title"),
        gettext("The title of the post this address shows.")
      ),
      var("post.excerpt", gettext("Post excerpt"), gettext("The post's summary.")),
      var(
        "post.image",
        gettext("Post image"),
        gettext("The post's featured image, as a full address.")
      ),
      var("post.author", gettext("Post authors"), gettext("The names of the post's authors.")),
      var(
        "post.published_at",
        gettext("Post published"),
        gettext("When the post was published, as an ISO 8601 date.")
      ),
      var(
        "post.modified_at",
        gettext("Post modified"),
        gettext("When the post last changed, as an ISO 8601 date.")
      ),
      var("post.url", gettext("Post address"), gettext("The post's canonical address.")),
      var(
        "post.collection",
        gettext("Post category"),
        gettext("The first category the post is filed under.")
      ),
      var("post.tags", gettext("Post tags"), gettext("The post's tags, comma separated.")),
      var(
        "post.rating",
        gettext("Post rating"),
        gettext("The readers' average rating, out of 5. Empty before the first rating.")
      ),
      var(
        "post.rating_count",
        gettext("Post ratings"),
        gettext("How many readers rated the post. Empty before the first rating.")
      )
    ]
  end

  defp tag_docs do
    [
      var("tag.name", gettext("Tag name"), gettext("The name of the tag this address shows.")),
      var("tag.description", gettext("Tag description"), gettext("The tag's description.")),
      var("tag.url", gettext("Tag address"), gettext("The tag's canonical address."))
    ]
  end

  defp collection_docs do
    [
      var(
        "collection.name",
        gettext("Category name"),
        gettext("The name of the category this address shows.")
      ),
      var(
        "collection.description",
        gettext("Category description"),
        gettext("The category's description.")
      ),
      var(
        "collection.url",
        gettext("Category address"),
        gettext("The category's canonical address.")
      )
    ]
  end

  defp author_docs do
    [
      var(
        "author.name",
        gettext("Blogger name"),
        gettext("The name of the blogger this address shows.")
      ),
      var("author.bio", gettext("Blogger bio"), gettext("The blogger's bio, as plain text.")),
      var(
        "author.image",
        gettext("Blogger photo"),
        gettext("The blogger's avatar, as a full address.")
      ),
      var("author.url", gettext("Blogger address"), gettext("The blogger's canonical address."))
    ]
  end

  defp team_docs do
    [
      var("team.name", gettext("Team name"), gettext("The name of the team this address shows.")),
      var("team.description", gettext("Team description"), gettext("The team's description.")),
      var("team.url", gettext("Team address"), gettext("The team's canonical address."))
    ]
  end

  defp var(key, label, help), do: %{key: key, label: label, help: help}
end
