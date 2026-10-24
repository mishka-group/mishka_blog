# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.PageFrame do
  @moduledoc """
  What the blog tells the site's layout about each of its pages, through the `runtime:page:frame`
  mishka_installer hook `MishkaCmsCore.Runtime.SiteLayout` fires in `handle_params/3`: the bar under
  the header, and the languages the record a page shows is written in. The layout draws both, so no
  page of the blog draws a bar or a language switcher of its own.

  A page is the blog's by its section, `"blog"`, which `MishkaBlog.Provision` files every page under.
  A page of another section that shows one of the blog's records, as `MishkaBlog.Plugins.PageRecords`
  names them, gets its languages and no bar. Every other page is handed back untouched, before
  anything is read.

  ## The bar

  The blog's name in the home design's italic serif, leading to its front page, and its four places
  as the design draws them: Posts, Categories, Tags and People (`MishkaBlog.Provision.places/0`).
  The one the reader is in is marked: a post, a category and a tag are in Posts, a blogger and a team
  are in People, and every other page is in the place whose page it is. That is the design's own
  rule: it has no page of a category or a tag, only the Posts screen narrowed to one (opening a
  category from Categories, or a tag from Tags, lands on it), and its bar marks the screen, so
  Posts, whatever the reader came from. The search box is the list pages' own, beside their title,
  as the design draws it; the bar has no trailing part, and nothing that needs a class in the site's
  stylesheet.

  The words are the site's own translations (`MishkaCmsCore.Runtime.Translations`), in the language of
  the response, and the key itself where nobody has written one. `MishkaBlog.Provision` registers
  them (`words/0`) when it sets a site up.

  ## The languages

  The languages THIS record is written in, each at that edition's own slug, address and title:

    * a post, a category and a tag are one row per language, joined by `language_group_id` (the
      master's own id, which the master itself may not carry). Every published edition of the one the
      slug names is offered, the one being read included, at the page's own path with the edition's
      language and slug filled in (`MishkaCmsCore.Runtime.Languages.url/3`). A language the record
      has no edition in is not offered, and a record with a single edition offers none;
    * a blogger and a team are one row in every language, so each language the site publishes in is
      offered, at the same slug;
    * a list page, `/:lang/blog` or the archive, keeps what the layout would offer without a
      plugin: the same path in each language.

  The other editions are read as the visitor the frame names (`current_user`, `nil` for a guest),
  through `:public_list`, as the blog's components read for the page: an edition the visitor may
  open, by its own lock or the one it inherits, is offered, and a guest is offered only what a
  guest can read. An edition the visitor may not open is not offered, so its address and its title
  are not shown to a reader the blog keeps it from.

  The edition being read is read as the system, as `MishkaBlog.Plugins.PageSeo` reads: the lock is
  the page's gate, not a reason for the record to be missing from its own page's frame.

  ## The words

  `words/0` is what the bar asks the site's translations for. No template holds them, so the
  plugin names them on `runtime:translations:used_keys` (`MishkaBlog.Plugins.TranslationKeys`),
  where "Remove unused" would otherwise delete them.

  Registered in `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "runtime:page:frame", initial: %{priority: 50}

  require Ash.Query

  alias MishkaBlog.{Blogger, BlogPost, Collection, Provision, Tag, Team}
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.States.TranslationsState

  @section "blog"

  # The kinds of record the blog's pages show, `MishkaBlog.Plugins.PageRecords`' ids.
  @records ~w(blog:post blog:category blog:tag blog:author blog:team)

  # The place of the bar a page showing a record is in, whatever path it was given. A category's page
  # and a tag's are the design's Posts screen narrowed, which its bar marks as Posts.
  @record_places %{
    "blog:post" => :posts,
    "blog:category" => :posts,
    "blog:tag" => :posts,
    "blog:author" => :people,
    "blog:team" => :people
  }

  # What the bar calls the blog and each of its places: keys of the site's translations.
  @title "Blog"
  @labels [posts: "Posts", categories: "Categories", tags: "Tags", people: "People"]

  # More than a site has languages; a group is one row per language.
  @editions 50

  # A read made as the system: the lock is the page's gate, not a reason for the record to be
  # missing from its own page's frame.
  @system [authorize?: false]

  @doc """
  The words the bar asks the site's translations for, for `MishkaBlog.Provision` to register and
  `MishkaBlog.Plugins.TranslationKeys` to keep: the blog's name, then the name of each place.
  """
  @spec words() :: [String.t()]
  def words, do: [@title | Keyword.values(@labels)]

  @impl true
  def call(%{section: @section} = frame),
    do:
      {:reply, :halt,
       Map.merge(frame, %{translations: translations(frame), section_bar: bar(frame)})}

  def call(%{record: record} = frame) when record in @records,
    do: {:reply, :halt, Map.put(frame, :translations, translations(frame))}

  def call(frame), do: {:reply, frame}

  # ---------------------------------------------------------------------------
  # The bar
  # ---------------------------------------------------------------------------

  defp bar(frame) do
    place = place(frame)
    url = &address(frame, &1)

    %{
      title: word(frame, @title),
      title_path: url.(Keyword.fetch!(Provision.places(), :posts)),
      links:
        for {id, path} <- Provision.places() do
          %{
            label: word(frame, Keyword.fetch!(@labels, id)),
            path: url.(path),
            current: id == place
          }
        end
    }
  end

  # The place the reader is in: the one the record a page shows belongs to, else the one whose page
  # this is.
  defp place(%{record: record, page: page}) do
    Map.get(@record_places, record) ||
      Enum.find_value(Provision.places(), fn {id, path} -> page[:path] == path && id end)
  end

  defp address(%{language: language, site_id: site_id}, path),
    do: Languages.url(path, %{Languages.capture() => language}, site_id)

  defp word(%{site_id: site_id, language: language}, key),
    do: TranslationsState.lookup(site_id, language, key) || key

  # ---------------------------------------------------------------------------
  # The languages
  # ---------------------------------------------------------------------------

  defp translations(%{record: "blog:post"} = frame), do: editions(frame, BlogPost, :title)
  defp translations(%{record: "blog:category"} = frame), do: editions(frame, Collection, :name)
  defp translations(%{record: "blog:tag"} = frame), do: editions(frame, Tag, :name)

  defp translations(%{record: "blog:author"} = frame), do: person(frame, Blogger, :display_name)
  defp translations(%{record: "blog:team"} = frame), do: person(frame, Team, :name)

  # A list page, or one whose record kind is not the blog's: what the layout would offer.
  defp translations(frame), do: frame.translations

  # Every edition of the record the slug names in this response's language: its own row, then the
  # rows of its group the visitor may open. The group's key is the master's own id, and the master
  # itself may carry no `language_group_id` (`MishkaCmsCore.LanguageEditions`), so a row without one
  # is its group's key.
  defp editions(
         %{params: params, site_id: site_id, language: language} = frame,
         resource,
         title
       )
       when is_binary(site_id) and is_binary(language) do
    fields = [:id, :slug, :language, :language_group_id, title]

    with slug when is_binary(slug) and slug != "" <- Map.get(params, "slug"),
         [read | _rest] <- current(resource, fields, site_id, slug, language) do
      others = siblings(resource, fields, site_id, Map.get(frame, :current_user), group(read))

      [read | others]
      |> Enum.uniq_by(& &1.id)
      |> Enum.flat_map(&translation(frame, &1, Map.fetch!(&1, title)))
    else
      _not_here -> []
    end
  end

  defp editions(_frame, _resource, _title), do: []

  defp group(row), do: row.language_group_id || row.id

  # THE EDITION BEING READ, as the system.
  defp current(resource, fields, site_id, slug, language) do
    resource
    |> published(fields, site_id, @system)
    |> Ash.Query.filter(slug == ^slug and language == ^language)
    |> rows(site_id, @system)
  end

  # THE REST OF ITS GROUP, as the visitor: `:public_list` keeps the rows they may not open out of
  # the read, by the lock of the row or the one it inherits and by the page that shows it.
  defp siblings(resource, fields, site_id, visitor, group) do
    as = [actor: visitor]

    resource
    |> published(fields, site_id, as)
    |> Ash.Query.filter(language_group_id == ^group or id == ^group)
    |> Ash.Query.sort(language: :asc)
    |> rows(site_id, as)
  end

  # `:public_list` keeps a post to the published and a category to the active ones.
  defp published(resource, fields, site_id, as) do
    resource
    |> Ash.Query.for_read(:public_list, %{}, [tenant: site_id] ++ as)
    |> Ash.Query.select(fields)
  end

  defp rows(query, site_id, as) do
    case Ash.read(query, [tenant: site_id, page: [limit: @editions]] ++ as) do
      {:ok, %{results: rows}} -> rows
      _unreadable -> []
    end
  end

  # A blogger or a team is one row in every language: each language the site publishes in, at the
  # same slug.
  defp person(%{params: params, site_id: site_id, language: language} = frame, resource, name)
       when is_binary(site_id) and is_binary(language) do
    with slug when is_binary(slug) and slug != "" <- Map.get(params, "slug"),
         [person | _rest] <- people(resource, name, site_id, slug) do
      Enum.flat_map(
        Languages.site(site_id),
        &translation(frame, &1, slug, Map.fetch!(person, name))
      )
    else
      _not_here -> []
    end
  end

  defp person(_frame, _resource, _name), do: []

  defp people(resource, name, site_id, slug) do
    resource
    |> published([:id, :slug, name], site_id, @system)
    |> Ash.Query.filter(slug == ^slug)
    |> rows(site_id, @system)
  end

  defp translation(frame, %{language: language, slug: slug}, title),
    do: translation(frame, language, slug, title)

  defp translation(%{page: %{path: path}, site_id: site_id}, language, slug, title)
       when is_binary(path) do
    case Languages.url(path, %{Languages.capture() => language, "slug" => slug}, site_id) do
      address when is_binary(address) -> [%{language: language, path: address, title: title}]
      nil -> []
    end
  end

  defp translation(_frame, _language, _slug, _title), do: []
end
