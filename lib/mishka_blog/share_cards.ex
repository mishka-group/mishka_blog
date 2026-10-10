defmodule MishkaBlog.ShareCards do
  @moduledoc """
  Which share card (`MishkaCmsCore.Runtime.ShareCard`) a blog record shows: the kind of record its
  page shows (`MishkaBlog.Plugins.PageRecords`) and the captures that name it — what a page of that
  kind answers for (`MishkaBlog.Plugins.PageSeo`).

  The after-save plugins (`MishkaBlog.Plugins.PostShareCard` and its siblings) hand it to
  `ShareCard.refresh/3`, and each record's edit modal to its Share image field
  (`ui do extra %{share_card: &MishkaBlog.ShareCards.target/1} end`). A record a visitor cannot
  open — a post not published, a category or a team not active — shows none: `nil`.
  """

  alias MishkaBlog.{BlogPost, Blogger, Collection, Tag, Team}
  alias MishkaCmsCore.Runtime.Languages

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

  defp captures(slug, language) when is_binary(language),
    do: %{"slug" => slug, Languages.capture() => language}

  defp captures(slug, _no_language), do: %{"slug" => slug}
end
