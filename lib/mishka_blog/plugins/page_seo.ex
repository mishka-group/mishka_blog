defmodule MishkaBlog.Plugins.PageSeo do
  @moduledoc """
  Gives each post, category and tag its own head on the blog page that serves it, through the
  `runtime:page:seo` mishka_installer hook `MishkaCmsWeb.RuntimeLive` fires in `handle_params/3`
  (see `MishkaCmsCore.Runtime.Seo` for the map it is handed and what the head builds from it).

  A page is matched by the kind of record it says it shows (`record`, its `extra`'s `"record"`):
  `"blog:post"`, `"blog:category"` or `"blog:tag"`, the kinds `MishkaBlog.Plugins.PageRecords`
  names. Its path may be anything that captures the `slug`. Every other page is handed back
  untouched before anything is read. A kind has one owner, so the answer for one of these halts the
  chain: no later plugin is asked.

  Everything returned is a default: what the page sets in its own SEO — a title, a description, a
  tag, structured data — wins, and may name the variables below, `{{post.title}} | Blog`.

  ## A post, `"blog:post"`

  The post the `slug` capture names in the page's language, published — read once, through
  `:public_list` as `blog-post-detail` reads it, on the page's site, with its authors, categories,
  tags and published translations:

    * `title`, `description`, `image` — the post's title, excerpt and featured image;
    * `type` — `"article"`;
    * `tags` — `author` (the authors' names), `article:published_time`, `article:modified_time`,
      `article:section` (the first category), one `article:tag` per tag, and a `rel="alternate"`
      link per language the post is published in among the site's languages, with `x-default` at
      the site's primary one, when there are two or more. The post's own `seo_tags` come last and
      replace any of these they name;
    * `schema` — the post's own `schema` when it holds one, else a `BlogPosting`; then a
      `BreadcrumbList`, Home → Blog → the post;
    * `vars` — `post.title`, `post.excerpt`, `post.image`, `post.author`, `post.published_at`,
      `post.modified_at`, `post.url`, `post.collection`, `post.tags`, and `post.rating` (the
      readers' average, one decimal) with `post.rating_count` once a reader has rated it.

  ## A category, `"blog:category"`

  The active category the `slug` capture names in the page's language: its name and description,
  its own `seo_tags`, its own `schema` (else a `CollectionPage`) and a
  `BreadcrumbList`, Home → Blog → the category. `vars` — `collection.name`,
  `collection.description`, `collection.url`.

  ## A tag, `"blog:tag"`

  The tag the `slug` capture names in the page's language: its name and description, its own
  `seo_tags`, a `CollectionPage` and a `BreadcrumbList`, Home → Blog → the tag. `vars` —
  `tag.name`, `tag.description`, `tag.url`.

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

  alias MishkaBlog.{BlogPost, Blogger, Collection, Provision, Tag}
  alias MishkaCmsCore.Runtime.{Languages, PageEditions, Seo}
  alias MishkaCmsCore.Settings

  @post_fields [
    :id,
    :title,
    :slug,
    :excerpt,
    :featured_image_url,
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

  @impl true
  def call(%{record: "blog:post"} = seo), do: {:reply, :halt, post(seo)}
  def call(%{record: "blog:category"} = seo), do: {:reply, :halt, category(seo)}
  def call(%{record: "blog:tag"} = seo), do: {:reply, :halt, tag(seo)}
  def call(seo), do: {:reply, seo}

  defp post(seo) do
    seo = %{seo | var_docs: post_docs()}

    case read(BlogPost, seo, @post_fields, post_loads()) do
      %BlogPost{} = post -> post_seo(seo, post)
      nil -> seo
    end
  end

  defp category(seo) do
    seo = %{seo | var_docs: collection_docs()}

    case read(Collection, seo, @collection_fields, [:effective_permissions]) do
      %Collection{} = collection -> collection_seo(seo, collection)
      nil -> seo
    end
  end

  defp tag(seo) do
    seo = %{seo | var_docs: tag_docs()}

    case read(Tag, seo, @tag_fields, []) do
      %Tag{} = tag -> tag_seo(seo, tag)
      nil -> seo
    end
  end

  # The row the `slug` capture names, in the page's language, on the page's site; `nil` when the
  # request names none or none is shown.
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

  defp in_language(query, language) when is_binary(language) and language != "",
    do: Ash.Query.filter(query, language == ^language)

  defp in_language(query, _no_language), do: query

  defp post_loads do
    [
      :rating_average,
      :rating_count,
      :effective_permissions,
      bloggers:
        Blogger |> Ash.Query.select([:display_name]) |> Ash.Query.sort(display_name: :asc),
      collections:
        Collection
        |> Ash.Query.select([:name])
        |> Ash.Query.sort(display_order: :asc, name: :asc),
      tags:
        Tag
        |> Ash.Query.select([:name])
        |> Ash.Query.sort(name: :asc)
        |> Ash.Query.page(limit: 50),
      language_variants:
        BlogPost
        |> Ash.Query.filter(status == :published)
        |> Ash.Query.select([:slug, :language, :language_group_id])
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
        "author" => Enum.map(authors, &%{"@type" => "Person", "name" => &1}),
        "publisher" => publisher(seo.site_id, base),
        "mainEntityOfPage" => seo.url,
        "inLanguage" => post.language,
        "keywords" => Enum.join(tag_names, ", ")
      })

    generated =
      List.flatten([
        meta("name", "author", Enum.join(authors, ", ")),
        meta("property", "article:published_time", published),
        meta("property", "article:modified_time", modified),
        meta("property", "article:section", section),
        Enum.map(tag_names, &meta("property", "article:tag", &1)),
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
            breadcrumb(seo, base, gettext("Blog"), post.title),
        permissions: post.effective_permissions,
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
            breadcrumb(seo, base, gettext("Blog"), collection.name),
        permissions: collection.effective_permissions,
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
        tags: List.wrap(tag.seo_tags),
        schema: [page | breadcrumb(seo, base, gettext("Blog"), tag.name)],
        permissions: List.wrap(tag.permissions),
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
  # the site's primary language; nothing for a post in one language.
  defp alternates(post, %{page: %{path: path}, site_id: site_id}, base) do
    served = Languages.site(site_id)

    editions =
      for edition <-
            [post | post.language_variants]
            |> Enum.uniq_by(& &1.language)
            |> Enum.sort_by(& &1.language),
          edition.language in served,
          captures = %{Languages.capture() => edition.language, "slug" => edition.slug},
          url = Seo.absolute(PageEditions.path(path, captures), base),
          is_binary(url),
          do: {edition.language, url}

    case editions do
      [_, _ | _] ->
        primary = Languages.primary(site_id)

        Enum.map(editions, fn {language, url} -> alternate(language, url) end) ++
          for {^primary, url} <- editions, do: alternate("x-default", url)

      _one_or_none ->
        []
    end
  end

  # A relationship read through an action that pages arrives as a page.
  defp rows(%Ash.Page.Offset{results: results}), do: results
  defp rows(rows) when is_list(rows), do: rows

  defp alternate(language, url),
    do: %{tag: "link", attrs: %{"rel" => "alternate", "hreflang" => language, "href" => url}}

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

  defp breadcrumb(_seo, nil, _blog, _name), do: []

  defp breadcrumb(%{language: language, url: url}, base, blog, name) do
    blog_url =
      Provision.item_paths().post
      |> Path.dirname()
      |> PageEditions.path(%{Languages.capture() => language})
      |> Seo.absolute(base)

    items =
      Enum.reject(
        [{gettext("Home"), base}, {blog, blog_url}, {name, url}],
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

  defp publisher(site_id, base) do
    case Settings.get("site.title", nil, site_id) do
      name when is_binary(name) and name != "" ->
        compact(%{"@type" => "Organization", "name" => name, "url" => base})

      _no_title ->
        nil
    end
  end

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

  defp var(key, label, help), do: %{key: key, label: label, help: help}
end
