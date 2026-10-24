# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.PageSource do
  @moduledoc """
  The rows a page of the blog is made of, read once for the request and handed to everything that
  draws them: the head (`MishkaBlog.Plugins.PageSeo`), the frame (`MishkaBlog.Plugins.PageFrame`)
  and the page's blocks.

  ## Read once, for everything that draws them

  A post's page was drawn by the head, the frame, `blog-post-detail`, `blog-post-comments` and
  `blog-related-posts`, and each of them read the post the `:slug` capture names on its own; a
  category's, a tag's, a blogger's and a team's the same, and the blog's front page read its
  featured posts twice and counted its posts twice. `read/1` reads them once, in `handle_params/3`,
  through the `runtime:page:source` event (`MishkaBlog.Plugins.PageSource`,
  `MishkaCmsCore.Runtime.PageSource`), and every reader is handed what it read: the two plugins as
  `source`, the blocks as `page_source`.

  What is read, in ONE read of the record and what that read loads with it:

    * a post (`"blog:post"`) — with its text as the site draws it, what it opens with, its readers'
      rating, how many approved comments it has, the categories it is filed under, its tags, its
      authors with their teams, and its other editions;
    * a category (`"blog:category"`) and a tag (`"blog:tag"`) — with what it opens with, how many of
      its posts its own page lists (`listed_post_count`), and its other editions; then the page of
      those posts its list draws first, with what each card is drawn from;
    * a blogger (`"blog:author"`) — with their teams; a team (`"blog:team"`) — with its members and
      how many posts each has;
    * the blog's front page (`"blog:home"`, the Posts place, `MishkaBlog.Provision.places/0`) — the
      featured posts its strip draws, which its list leaves out, and the page of the other posts its
      list draws first, each with what its card is drawn from, and how many posts there are in its
      language, which its search box says.

  The page of a list is the page the address names (`?page=`), of `MishkaBlog.Provision.list_page/0`
  posts, newest first, as the provisioned list reads it; nothing is read for it while the reader's
  search (`?q=`), or on the front page a tag (`?tag=`), narrows the list. The strip's posts and the
  list's are drawn from what one read loads for both of them.

  A post's, a category's and a tag's other editions are the rows of its group of translations,
  joined by `language_group_id` (the master's own id, which the master itself may not carry), each
  with its language, its slug and its title or name, and nothing else: what the frame offers and
  the head's `hreflang` links name. A blogger and a team are one row in every language, and have
  none.

  ## As the visitor

  Every row is read as the visitor, `current_user`, through the public actions and the policies
  the blocks read with (`MishkaBlog.Resources.Preparations.OpenToActor`, `ReaderLocks`), and every
  relationship and aggregate loaded with it is read through the public read of what it reaches,
  as the same visitor: a draft, a post locked to permissions they do not hold by its own lock or by
  a category it is filed under, a locked category, a locked tag, and a record whose page on the
  site is closed to them are not among them, and are not counted.

  A record the visitor's read does not find is `nil` here. Its lock, which the head hands
  `MishkaCmsWeb.RuntimeLive` to refuse them with, is read by the head alone, as the system, and
  nothing else of that read reaches the visitor.

  ## Keyed to its visitor, and to what it was read for

  A source names the site, the visitor (`MishkaCmsCore.Runtime.PageSource.visitor_id/1`), the
  language, the kind and the slug it was read for. A block takes nothing from one read for another
  site or another visitor, and takes a row only for exactly the read it would make itself;
  anything else it reads for itself, so a block an author placed on a page of their own reads as it
  always did.

  ## What a block reads of it

  A block's code calls nothing of this extension's (`MishkaBlog.KitTest`), so it reads a source by
  its shape, which is therefore part of what the kit relies on:

    * `rows_of` — `"mishka_blog"`, which a block asks before anything else;
    * `site_id`, `visitor`, `language`, `kind`, `slug` — whom and for what it was read;
    * `record` — the row, every field a block draws of it and the relationships above loaded;
    * `featured` — on the front page, `%{limit: limit, rows: posts}`, the newest featured posts;
    * `total` — on the front page, how many posts the visitor may open in its language;
    * `listed` — on the front page, a category's and a tag's, `%{per_page: n, page: p, rows: posts}`,
      the page of posts the list draws, newest first: of the category or the tag, and on the front
      page of the posts other than `featured`'s.

  ## Another page of the same record

  A live patch that stays on the same record — another page of a list — reads nothing of it again:
  the event hands back the source the address before read for the same visitor (`held`).
  """

  require Ash.Query
  require Ash.Sort

  alias MishkaBlog.{Blogger, BlogPost, Collection, Provision, Tag, Team}
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.PageSource, as: CorePageSource

  @enforce_keys [:site_id, :visitor, :language, :kind]
  defstruct [
    :site_id,
    :visitor,
    :language,
    :kind,
    :slug,
    :record,
    :featured,
    :total,
    :listed,
    rows_of: "mishka_blog"
  ]

  @type t :: %__MODULE__{
          rows_of: String.t(),
          site_id: String.t(),
          visitor: term(),
          language: String.t() | nil,
          kind: String.t(),
          slug: String.t() | nil,
          record: struct() | nil,
          featured: %{limit: pos_integer(), rows: [struct()]} | nil,
          total: non_neg_integer() | nil,
          listed: %{per_page: pos_integer(), page: pos_integer(), rows: [struct()]} | nil
        }

  @records ~w(blog:post blog:category blog:tag blog:author blog:team)

  # EVERYTHING ANY READER DRAWS OF A POST: the article, its head and its card.
  @post_fields [
    :id,
    :title,
    :subtitle,
    :slug,
    :excerpt,
    :content,
    :published_at,
    :updated_at,
    :featured_image_url,
    :featured,
    :language,
    :language_group_id,
    :reading_time_minutes,
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
    :language_group_id,
    :seo_tags,
    :schema,
    :permissions
  ]

  @tag_fields [
    :id,
    :name,
    :slug,
    :description,
    :language,
    :language_group_id,
    :seo_tags,
    :permissions
  ]

  @blogger_fields [
    :id,
    :display_name,
    :slug,
    :bio,
    :avatar_url,
    :social_links,
    :expertise_areas
  ]

  @team_fields [:id, :name, :slug, :description, :avatar_url, :cover_image_url]

  # What a card of a post is drawn from, as `blog-featured-posts` and `blog-post-list` read it.
  @card_fields [
    :id,
    :title,
    :slug,
    :language,
    :excerpt,
    :published_at,
    :featured_image_url,
    :featured,
    :reading_time_minutes
  ]

  # More than a site has languages; a group is one row per language.
  @editions 50

  @doc """
  The rows of the blog page `request` asks for, read as its `current_user`; `nil` for a page that is
  not one of the blog's, or that names no row.
  """
  @spec read(map()) :: t() | nil
  def read(%{site_id: site_id} = request) when is_binary(site_id) do
    case kind(request) do
      nil -> nil
      {kind, slug} -> request |> blank(kind, slug) |> rows(request)
    end
  end

  def read(_request), do: nil

  @doc """
  The source the page read for `request`, when it was handed one for this site, visitor, language
  and page; else the rows read here, once (`read/1`). For the plugins on the frame and the head,
  which are handed core's `source`.
  """
  @spec of(map()) :: t() | nil
  def of(%{source: %__MODULE__{} = source} = request) do
    visitor = CorePageSource.visitor_id(Map.get(request, :current_user))

    if for_page?(source, request) and source.visitor == visitor,
      do: source,
      else: read(request)
  end

  def of(request), do: read(request)

  @doc """
  Whether `source` was read for the page `request` asks for: the same site, language, kind and
  slug. The head is handed no visitor to ask the rest of, and takes the source core hands it for
  the request when this holds.
  """
  @spec for_page?(t(), map()) :: boolean()
  def for_page?(%__MODULE__{} = source, request) do
    source.site_id == Map.get(request, :site_id) and
      source.language == Map.get(request, :language) and
      kind(request) == {source.kind, source.slug}
  end

  # THE PAGE'S KIND: the record its `extra` names, with the slug its `:slug` capture holds; or the
  # blog's front page, the page of the Posts place.
  defp kind(%{record: record, params: %{"slug" => slug}})
       when record in @records and is_binary(slug) and slug != "",
       do: {record, slug}

  defp kind(%{record: record}) when record in @records, do: nil

  defp kind(%{section: "blog", page: %{path: path}}) do
    if path == Keyword.fetch!(Provision.places(), :posts), do: {"blog:home", nil}
  end

  defp kind(_not_the_blogs), do: nil

  defp blank(request, kind, slug) do
    %__MODULE__{
      site_id: request.site_id,
      visitor: CorePageSource.visitor_id(Map.get(request, :current_user)),
      language: Map.get(request, :language),
      kind: kind,
      slug: slug
    }
  end

  # The source the address before read, when it is for this site, this visitor, this language and
  # this page.
  defp held(%{held: %__MODULE__{} = held}, source) do
    same? =
      held.site_id == source.site_id and held.visitor == source.visitor and
        held.language == source.language and held.kind == source.kind and
        held.slug == source.slug

    if same?, do: held
  end

  defp held(_request, _source), do: nil

  defp rows(%{kind: "blog:home"} = source, request) do
    case held(request, source) do
      %__MODULE__{featured: %{} = featured, total: total} = held when is_integer(total) ->
        %{source | featured: featured, total: total}
        |> listed(
          request,
          held,
          &list_query(&1, request, Enum.map(featured.rows, fn row -> row.id end))
        )

      _not_held ->
        front(source, request)
    end
  end

  defp rows(source, request) do
    case held(request, source) do
      %__MODULE__{record: record} = held when record != nil ->
        listed(%{source | record: record}, request, held, &list_query(&1, request, []))

      _not_held ->
        source = %{source | record: record(source, request)}
        listed(source, request, nil, &list_query(&1, request, []))
    end
  end

  defp as(source, request),
    do: [actor: Map.get(request, :current_user), tenant: source.site_id]

  # ---------------------------------------------------------------------------
  # A record
  # ---------------------------------------------------------------------------

  defp record(%{kind: "blog:post"} = source, request) do
    BlogPost
    |> by_slug(source, request)
    |> Ash.Query.select(@post_fields)
    |> Ash.Query.load(post_loads(source))
    |> first(source, request)
  end

  defp record(%{kind: "blog:category"} = source, request) do
    Collection
    |> by_slug(source, request)
    |> Ash.Query.select(@collection_fields)
    |> Ash.Query.load(
      [:effective_permissions, :listed_post_count] ++
        editions(source, Collection, :name)
    )
    |> first(source, request)
  end

  defp record(%{kind: "blog:tag"} = source, request) do
    Tag
    |> by_slug(source, request)
    |> Ash.Query.select(@tag_fields)
    |> Ash.Query.load([:listed_post_count] ++ editions(source, Tag, :name))
    |> first(source, request)
  end

  # A BLOGGER AND A TEAM ARE ONE ROW IN EVERY LANGUAGE: the slug alone names them, through the read
  # their own pages' blocks make.
  defp record(%{kind: "blog:author"} = source, request) do
    Blogger
    |> Ash.Query.for_read(:public_by_slug, %{slug: source.slug}, as(source, request))
    |> Ash.Query.select(@blogger_fields)
    |> Ash.Query.load(
      teams:
        Team
        |> Ash.Query.select([:id, :name, :slug, :avatar_url])
        |> Ash.Query.sort(name: :asc)
        |> Ash.Query.page(limit: 50)
    )
    |> one(source, request)
  end

  defp record(%{kind: "blog:team"} = source, request) do
    Team
    |> Ash.Query.for_read(:public_by_slug, %{slug: source.slug}, as(source, request))
    |> Ash.Query.select(@team_fields)
    |> Ash.Query.load(
      members:
        Blogger
        |> Ash.Query.select([:id, :display_name, :slug, :avatar_url, :bio])
        |> Ash.Query.sort(display_name: :asc)
        |> Ash.Query.limit(100)
        |> Ash.Query.load(:post_count)
    )
    |> one(source, request)
  end

  defp by_slug(resource, source, request) do
    resource
    |> Ash.Query.for_read(:public_list, %{}, as(source, request))
    |> Ash.Query.filter(slug == ^source.slug)
    |> in_language(source.language)
  end

  defp in_language(query, language) when is_binary(language) and language != "",
    do: Ash.Query.filter(query, language == ^language)

  defp in_language(query, _no_language), do: query

  defp first(query, source, request) do
    case Ash.read(query, as(source, request) ++ [page: [limit: 1]]) do
      {:ok, %{results: [row | _rest]}} -> unpaged(row)
      _none -> nil
    end
  end

  defp one(query, source, request) do
    case Ash.read_one(query, as(source, request)) do
      {:ok, %{} = row} -> unpaged(row)
      _none -> nil
    end
  end

  # A RELATIONSHIP READ THROUGH AN ACTION THAT ONLY READS IN PAGES — a tag's, a team's — arrives as a
  # page, and is handed on as its rows, so every reader reads a list.
  defp unpaged(%{__struct__: _resource} = row) do
    Enum.reduce(~w(tags teams editions bloggers members collections)a, row, fn key, row ->
      case Map.get(row, key) do
        %Ash.Page.Offset{results: rows} -> Map.put(row, key, Enum.map(rows, &unpaged/1))
        rows when is_list(rows) -> Map.put(row, key, Enum.map(rows, &unpaged/1))
        _absent_or_not_loaded -> row
      end
    end)
  end

  # WHAT THE POST'S READERS DRAW OF IT, loaded with it as the same visitor: the article's text and
  # its lock, the head's rating and the conversation's count, the categories, tags and authors the
  # article, the head and the next reads name, and the editions the frame and the head offer.
  defp post_loads(source) do
    [
      :rendered_content,
      :effective_permissions,
      :rating_average,
      :rating_count,
      :approved_comment_count,
      collections:
        Collection
        |> Ash.Query.select([:id, :name, :slug, :language])
        |> Ash.Query.sort(display_order: :asc, name: :asc)
        |> Ash.Query.limit(50),
      tags:
        Tag
        |> Ash.Query.select([:id, :name, :slug, :language])
        |> Ash.Query.sort(name: :asc)
        |> Ash.Query.page(limit: 50),
      bloggers:
        Blogger
        |> Ash.Query.select([:id, :display_name, :slug, :bio, :avatar_url, :social_links])
        |> Ash.Query.sort(display_name: :asc)
        |> Ash.Query.limit(20)
        |> Ash.Query.load(
          teams:
            Team
            |> Ash.Query.select([:id, :name])
            |> Ash.Query.sort(name: :asc)
            |> Ash.Query.page(limit: 5)
        )
    ] ++ editions(source, BlogPost, :title)
  end

  # THE OTHER EDITIONS, on a site that publishes in more than one language: one that publishes in one
  # has nothing to offer. Each with what the frame and the head name of it, and nothing more.
  defp editions(%{site_id: site_id}, resource, title) do
    case Languages.site(site_id) do
      [_, _ | _] ->
        [
          editions:
            resource
            |> Ash.Query.select([:id, :slug, :language, title])
            |> Ash.Query.sort(language: :asc)
            |> Ash.Query.page(limit: @editions)
        ]

      _one_or_none ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # The page of a list
  # ---------------------------------------------------------------------------

  # THE PAGE OF POSTS A LIST DRAWS FIRST, on a category's and a tag's page and, under its strip, on
  # the front page: the one the address before read for the same page, else read here with what each
  # card is drawn from. Nothing for a record the visitor may not open, and nothing while the reader's
  # own search or tag narrows the list, which then reads for itself.
  defp listed(%{kind: kind} = source, _request, _held, _query)
       when kind not in ["blog:home", "blog:category", "blog:tag"],
       do: source

  defp listed(%{kind: kind, record: nil} = source, _request, _held, _query)
       when kind != "blog:home",
       do: source

  defp listed(source, request, held, query) do
    page = asked_page(request)

    cond do
      not plain?(source, request) ->
        source

      match?(%__MODULE__{listed: %{page: ^page}}, held) ->
        %{source | listed: held.listed}

      true ->
        source
        |> query.()
        |> Ash.Query.sort(published_at: :desc, id: :asc)
        |> Ash.Query.select(@card_fields)
        |> Ash.Query.load(card_loads())
        |> Ash.read(as(source, request) ++ [page: paged(page)])
        |> case do
          {:ok, %{results: rows}} ->
            %{source | listed: %{per_page: Provision.list_page(), page: page, rows: rows}}

          _unreadable ->
            source
        end
    end
  end

  # The posts the list holds, as `blog-post-list` narrows them: the visitor's in the page's language,
  # filed under the category or carrying the tag the page is of, or on the front page every one but
  # the strip's.
  defp list_query(%{kind: kind, slug: slug, language: language} = source, request, left_out) do
    query =
      BlogPost
      |> Ash.Query.for_read(:public_list, %{}, as(source, request))
      |> in_language(language)

    query =
      case kind do
        "blog:category" -> in_category(query, slug, language)
        "blog:tag" -> with_tag(query, slug, language)
        "blog:home" -> query
      end

    case left_out do
      [] -> query
      ids -> Ash.Query.filter(query, id not in ^ids)
    end
  end

  defp in_category(query, slug, language) when is_binary(language) and language != "",
    do:
      Ash.Query.filter(
        query,
        exists(collections, slug == ^slug and status == :active and language == ^language)
      )

  defp in_category(query, slug, _no_language),
    do: Ash.Query.filter(query, exists(collections, slug == ^slug and status == :active))

  defp with_tag(query, slug, language) when is_binary(language) and language != "",
    do: Ash.Query.filter(query, exists(tags, slug == ^slug and language == ^language))

  defp with_tag(query, slug, _no_language),
    do: Ash.Query.filter(query, exists(tags, slug == ^slug))

  # NOTHING THE READER ASKED NARROWS THE LIST: no search, and on the front page no tag. A value that
  # is not text is nothing asked, as the list reads it.
  defp plain?(%{kind: kind}, request) do
    params = Map.get(request, :params) || %{}
    asked = if kind == "blog:home", do: ["q", "tag"], else: ["q"]

    Enum.all?(asked, fn key ->
      case Map.get(params, key) do
        words when is_binary(words) -> String.trim(words) == ""
        _nothing_asked -> true
      end
    end)
  end

  # The page the address names, as the list reads its `page` key; the first when it names none.
  defp asked_page(request) do
    case request |> Map.get(:params, %{}) |> Kernel.||(%{}) |> Map.get("page") do
      page when is_integer(page) and page > 0 ->
        page

      page when is_binary(page) ->
        case Integer.parse(page) do
          {number, _rest} when number > 0 -> number
          _not_a_page -> 1
        end

      _none ->
        1
    end
  end

  defp paged(page) do
    per_page = Provision.list_page()
    [limit: per_page, offset: (page - 1) * per_page, count: false]
  end

  # ---------------------------------------------------------------------------
  # The front page
  # ---------------------------------------------------------------------------

  # WHICH POSTS THE STRIP DRAWS AND THE COUNT OF ALL OF THEM, IN ONE READ: the posts the visitor may
  # open in the page's language, featured first and newest first, as many as the strip draws,
  # counted beside the page Ash reads. The featured ones among them are the newest featured posts —
  # the strip's, which the list under it leaves out — and the count is the number the page's search
  # box says, which the list's own total is that count less the strip's. A plain count would not do:
  # the visitor's locks are a filter `OpenToActor` puts on the read as it runs, and a count of its
  # own runs none of it, so it would count the posts it keeps from them.
  #
  # THE STRIP'S CARDS AND THE LIST'S ARE THEN READ AS ONE, so what each card is drawn from is loaded
  # once for both (`cards/4`).
  defp front(source, request) do
    limit = Provision.featured_strip()

    BlogPost
    |> Ash.Query.for_read(:public_list, %{}, as(source, request))
    |> in_language(source.language)
    |> Ash.Query.sort(featured: :desc_nils_last, published_at: :desc, id: :asc)
    |> Ash.Query.select([:id, :featured])
    |> Ash.read(as(source, request) ++ [page: [limit: limit, count: true]])
    |> case do
      {:ok, %{results: found, count: count}} ->
        strip = for %{featured: true, id: id} <- found, do: id

        case cards(source, request, strip, count) do
          {:ok, featured, listed} ->
            %{source | featured: %{limit: limit, rows: featured}, total: count, listed: listed}

          :error ->
            source
        end

      _unreadable ->
        source
    end
  end

  # THE STRIP'S POSTS AND THE PAGE OF THE LIST, read as one with what their cards are drawn from, so
  # that is loaded once for both: the strip's first, then the list's, newest first. On the list's
  # first page that is the head of one list. On another its posts are found first, by their ids, and
  # read with the strip's. Where the reader's search or tag narrows the list, which then reads for
  # itself, the strip's alone are read, and there is no page of the list (`nil`). A read that fails
  # hands the blocks nothing, and they read for themselves.
  defp cards(source, request, strip, count) do
    page = asked_page(request)
    plain? = plain?(source, request)

    asked =
      cond do
        count == 0 ->
          nil

        not plain? ->
          {strip, length(strip)}

        page == 1 ->
          {:head, length(strip) + Provision.list_page()}

        true ->
          with {:ok, ids} <- listed_ids(source, request, strip, page),
               do: {strip ++ ids, length(strip) + length(ids)}
      end

    with {:ok, rows} <- card_rows(source, request, strip, asked) do
      {featured, others} = Enum.split_with(rows, &(&1.id in strip))
      listed = if plain?, do: %{per_page: Provision.list_page(), page: page, rows: others}
      {:ok, featured, listed}
    end
  end

  defp card_rows(_source, _request, _strip, :error), do: :error
  defp card_rows(_source, _request, _strip, nil), do: {:ok, []}
  defp card_rows(_source, _request, _strip, {[], _none}), do: {:ok, []}

  defp card_rows(source, request, strip, {asked, window}) do
    source
    |> list_query(request, [])
    |> only(asked)
    |> Ash.Query.sort([
      {Ash.Sort.expr_sort(id in ^strip, :boolean), :desc},
      published_at: :desc,
      id: :asc
    ])
    |> Ash.Query.select(@card_fields)
    |> Ash.Query.load(card_loads())
    |> Ash.read(as(source, request) ++ [page: [limit: window, count: false]])
    |> case do
      {:ok, %{results: rows}} -> {:ok, rows}
      _unreadable -> :error
    end
  end

  defp only(query, :head), do: query
  defp only(query, ids), do: Ash.Query.filter(query, id in ^ids)

  # The ids of the list's posts on `page`, other than the strip's.
  defp listed_ids(source, request, strip, page) do
    source
    |> list_query(request, strip)
    |> Ash.Query.sort(published_at: :desc, id: :asc)
    |> Ash.Query.select([:id])
    |> Ash.read(as(source, request) ++ [page: paged(page)])
    |> case do
      {:ok, %{results: rows}} -> {:ok, Enum.map(rows, & &1.id)}
      _unreadable -> :error
    end
  end

  # WHAT A CARD IS DRAWN FROM: what the post opens with, which puts the lock on it; the name of the
  # first category it is filed under, the word before its date, in the statement that reads the
  # posts; and its people.
  defp card_loads do
    [
      :effective_permissions,
      :first_category_name,
      bloggers:
        Blogger
        |> Ash.Query.select([:id, :display_name, :slug, :avatar_url])
        |> Ash.Query.sort(display_name: :asc)
    ]
  end
end
