# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Address do
  @moduledoc """
  Where a post, a category, a tag, a blogger and a team are read on a site, and whether an address
  names the row it found.

  ## The page is the address

  A site shows each kind of row on the page whose `extra` names that kind (`"blog:post"`,
  `"blog:category"`, `"blog:tag"`, `"blog:author"`, `"blog:team"`), and that page's path is the
  only place its address is written. `MishkaBlog.Provision` writes `/:lang/blog/:slug` and the rest
  as the defaults; a site moved from WordPress gives its post page `/:year/:monthnum/:slug`,
  `/archives/:post_id`, `/:category/:slug` or `/:slug`, and every link the blog builds follows. The
  page is found in memory (`MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState.path_for_record/3`)
  and filled from the row the caller already holds, so building an address reads nothing.

  ## The captures a row fills

    * `lang` — the row's language, or the one the caller builds in (a blogger and a team are one
      row in every language); dropped for the primary language as the site's URL mode says
      (`MishkaCmsCore.Runtime.Languages.url/3`);
    * `slug` — the row's slug;
    * for a post: `year`, `monthnum` and `day` from `published_at` (UTC, two-digit month and
      day as WordPress writes them), `post_id` from `number`, and `category` from the slug of the
      first category it is filed under (`first_category_slug`, or the first of its loaded
      `collections`).

  A capture the row cannot fill makes no address (`nil`): an unpublished post has no date, and a
  post filed under nothing has no `:category`.

  A `:category` is one segment, the category's own slug. WordPress writes the whole chain,
  `/tutorials/wordpress/slug`, and a page path can capture several segments only at its end
  (`*name`), so a chain is not an address here.
  """

  alias MishkaBlog.{Blogger, BlogPost, Collection, Tag, Team}
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}
  alias MishkaCmsCore.Runtime.Translations

  @kinds %{
    BlogPost => "blog:post",
    Collection => "blog:category",
    Tag => "blog:tag",
    Blogger => "blog:author",
    Team => "blog:team"
  }

  # The captures of a post's address that are not its slug, which a request must agree with.
  @post_captures ~w(year monthnum day post_id category)

  @doc """
  The public address of `row` on the site `site_id`, at the page that shows its kind, in its own
  language or in `language`; `nil` when the site has no such page or the row cannot fill it.

      Address.of(post, site.id) #=> "/2024/05/hello" on a site whose post page is /:year/:monthnum/:slug
  """
  @spec of(struct(), String.t() | nil, String.t() | nil) :: String.t() | nil
  def of(row, site_id, language \\ nil) do
    language = language || Map.get(row, :language)

    case path(site_id, kind(row), language) do
      {:ok, path} -> fill(path, row, site_id, language)
      :error -> nil
    end
  end

  @doc """
  The stored path of the page of `site_id` that shows `kind` in `language`, captures unfilled.
  Read from memory.
  """
  @spec path(String.t() | nil, String.t() | nil, String.t() | nil) :: {:ok, String.t()} | :error
  def path(site_id, kind, language) when is_binary(site_id) and is_binary(kind) do
    with {:ok, %{name: site}} <- SiteState.get(site_id),
         {:ok, path} <- WebRunTimeMetaDataState.path_for_record(site, kind, language) do
      {:ok, path}
    else
      _no_page -> :error
    end
  end

  def path(_site_id, _kind, _language), do: :error

  @doc """
  The address of the site's page for a kind that shows no row, `"blog:home"` (the list of posts)
  or `"blog:people"`, in `language`, at the address the site's URL mode gives it; `nil` when the
  site has no such page. The site is the one the calling process renders for, which is what a
  template calls this from.
  """
  @spec page_url(String.t(), String.t() | nil) :: String.t() | nil
  def page_url(kind, language) do
    site_id = Translations.site()

    case path(site_id, kind, language) do
      {:ok, path} -> Languages.url(path, %{Languages.capture() => language}, site_id)
      :error -> nil
    end
  end

  @doc """
  `path` filled from `row`, in its own language or in `language`, at the address the site's URL
  mode gives it; `nil` when `row` cannot fill a capture `path` names.
  """
  @spec fill(String.t(), struct(), String.t() | nil, String.t() | nil) :: String.t() | nil
  def fill(path, row, site_id, language \\ nil),
    do: Languages.url(path, captures(row, language), site_id)

  @doc "The record kind `row` is shown as: `\"blog:post\"` for a post, and so on; `nil` for another row."
  @spec kind(term()) :: String.t() | nil
  def kind(%{__struct__: resource}), do: Map.get(@kinds, resource)
  def kind(_not_a_row), do: nil

  @doc "What `row` fills a page path with, by capture name. See the module doc."
  @spec captures(struct(), String.t() | nil) :: %{String.t() => String.t()}
  def captures(row, language \\ nil)

  def captures(%BlogPost{} = post, language) do
    post
    |> base(language || post.language)
    |> Map.merge(dated(post.published_at))
    |> put_present("post_id", numbered(post.number))
    |> put_present("category", category_slug(post))
  end

  def captures(row, language), do: base(row, language || Map.get(row, :language))

  @doc """
  Whether the captures of a request agree with the post it found: every one of `year`, `monthnum`,
  `day`, `post_id` and `category` the request holds names the post — the date it was published on,
  its number, and one of the categories it is filed under. A request that names none of them agrees.
  """
  @spec agrees?(struct(), map()) :: boolean()
  def agrees?(%BlogPost{} = post, params) when is_map(params) do
    own = captures(post)

    params
    |> Map.take(@post_captures)
    |> Enum.all?(fn
      {"category", slug} -> slug in category_slugs(post)
      {key, asked} -> same_number?(asked, Map.get(own, key))
    end)
  end

  def agrees?(_row, _params), do: true

  @doc "The captures a request names a post by, besides its slug."
  @spec post_captures() :: [String.t()]
  def post_captures, do: @post_captures

  defp base(row, language) do
    %{"slug" => Map.get(row, :slug)}
    |> put_present(Languages.capture(), language)
  end

  defp dated(%DateTime{year: year, month: month, day: day}),
    do: %{"year" => Integer.to_string(year), "monthnum" => two(month), "day" => two(day)}

  defp dated(_unpublished), do: %{}

  defp numbered(number) when is_integer(number), do: Integer.to_string(number)
  defp numbered(_none), do: nil

  defp two(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  defp category_slug(%{first_category_slug: slug}) when is_binary(slug), do: slug
  defp category_slug(post), do: post |> category_slugs() |> List.first()

  defp category_slugs(%{collections: collections}) when is_list(collections),
    do: for(%{slug: slug} when is_binary(slug) <- collections, do: slug)

  defp category_slugs(%{first_category_slug: slug}) when is_binary(slug), do: [slug]
  defp category_slugs(_not_loaded), do: []

  defp same_number?(asked, own) when is_binary(asked) and is_binary(own) do
    case {Integer.parse(asked), Integer.parse(own)} do
      {{number, ""}, {number, ""}} -> true
      _different -> false
    end
  end

  defp same_number?(_asked, _own), do: false

  defp put_present(map, key, value) when is_binary(value) and value != "",
    do: Map.put(map, key, value)

  defp put_present(map, _key, _absent), do: map
end
