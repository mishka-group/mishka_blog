# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.ShareCards do
  @moduledoc """
  Which share card (`MishkaCmsCore.Runtime.ShareCard`) a blog record shows: the kind of record its
  page shows (`MishkaBlog.Plugins.PageRecords`) and the captures that name it — what a page of that
  kind answers for (`MishkaBlog.Plugins.PageSeo`).

  The after-save plugins (`MishkaBlog.Plugins.PostShareCard` and its siblings) hand it to
  `ShareCard.refresh/3`, and each record's edit modal to its Share image field
  (`ui do extra %{share_card: &MishkaBlog.ShareCards.target/1} end`). A record a visitor cannot
  open — a post not published, a category or a team not active — shows none: `nil`.

  `targets/1` names every card of a site, for `MishkaBlog.Plugins.ShareCardTargets`.
  """

  require Ash.Query

  alias MishkaBlog.{BlogPost, Blogger, Collection, Tag, Team}
  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler
  alias MishkaCmsCore.Runtime.Languages

  # Each kind of record and the fields `target/1` reads off it: one row in one language.
  @records [
    {BlogPost, [:slug, :language, :status]},
    {Collection, [:slug, :language, :status]},
    {Tag, [:slug, :language, :archived_at]}
  ]

  # A blogger or a team is one row in every language.
  @people [{Blogger, [:slug, :archived_at]}, {Team, [:slug, :status]}]

  @spec target(struct()) :: MishkaCmsCore.Runtime.ShareCard.target() | nil
  def target(%BlogPost{status: :published, slug: slug, language: language})
      when is_binary(slug),
      do: {:record, "blog:post", captures(slug, language)}

  def target(%Collection{status: :active, slug: slug, language: language}) when is_binary(slug),
    do: {:record, "blog:category", captures(slug, language)}

  def target(%Tag{archived_at: nil, slug: slug, language: language}) when is_binary(slug),
    do: {:record, "blog:tag", captures(slug, language)}

  def target(%Blogger{archived_at: nil, slug: slug}) when is_binary(slug),
    do: {:record, "blog:author", %{"slug" => slug}}

  def target(%Team{status: :active, slug: slug}) when is_binary(slug),
    do: {:record, "blog:team", %{"slug" => slug}}

  def target(_not_shown), do: nil

  @doc """
  Every share card the blog shows on the site `site_id`, as `target/1` names it: each published
  post, active category and tag in its own language, and each blogger and active team once in each
  language the site publishes in (`MishkaCmsCore.Runtime.Languages.site/1`), the language in its
  captures. Only a record in one of those languages is named.

  A stream: the rows are read through `:public_list` as a visitor reads them, a hundred at a time
  (`MishkaCmsCore.Runtime.Compilers.SitemapCompiler.stream_rows/2`), so a record a visitor may not
  open names none. `[]` for no site.
  """
  @spec targets(String.t() | nil) :: Enumerable.t()
  def targets(site_id) when is_binary(site_id) do
    languages = Languages.site(site_id)

    records =
      Stream.flat_map(@records, fn {resource, fields} ->
        resource
        |> public_rows(fields, site_id)
        |> Ash.Query.filter(language in ^languages)
        |> SitemapCompiler.stream_rows(actor: nil, tenant: site_id)
        |> Stream.map(&target/1)
      end)

    people =
      Stream.flat_map(@people, fn {resource, fields} ->
        resource
        |> public_rows(fields, site_id)
        |> SitemapCompiler.stream_rows(actor: nil, tenant: site_id)
        |> Stream.flat_map(&in_languages(target(&1), languages))
      end)

    records
    |> Stream.concat(people)
    |> Stream.reject(&is_nil/1)
  end

  def targets(_no_site), do: []

  defp public_rows(resource, fields, site_id) do
    resource
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.select(fields)
  end

  defp in_languages({:record, kind, captures}, languages),
    do: for(language <- languages, do: {:record, kind, captures(captures["slug"], language)})

  defp in_languages(nil, _languages), do: []

  defp captures(slug, language) when is_binary(language),
    do: %{"slug" => slug, Languages.capture() => language}

  defp captures(slug, _no_language), do: %{"slug" => slug}
end
