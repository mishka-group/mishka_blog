# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Validations.FreeAddress do
  @moduledoc """
  Refuses a post whose address is already a page of its site: on a site whose post page is
  `/:slug`, a post slugged `about` would sit at `/about`, where the site's own About page wins
  and the post could never be read. The refusal is `:message` on `slug`, with the address as
  `%{address}`.

      validate {MishkaBlog.Resources.Validations.FreeAddress,
                message: dgettext_noop("errors", "This post's address, %{address}, is already a page of this site.")}

  The address is the one the post's page makes of it (`MishkaBlog.Address`), and the page that
  answers it is found in memory (`MishkaCmsCore.Runtime.States.WebRunTimeMetaDataState.resolve/2`),
  so this reads nothing. A page counts when it is the one that answers the address and names nothing
  in it but the language: `/about`, or `/:lang/about` beside a post page `/:lang/:slug`. The post's
  own page, or another page of posts, does not.

  It is checked when the slug, the language, the publication date or the number is written. A post
  whose address needs what the write does not hold — its category, its number before it is given
  one — is not checked.

  ## Options

  * `:message` - Required. The refusal.
  """
  use Ash.Resource.Validation

  alias MishkaBlog.{Address, BlogPost}
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.States.{SiteState, WebRunTimeMetaDataState}

  @addressed [:slug, :language, :published_at, :number]

  @impl true
  def init(opts) do
    if Keyword.has_key?(opts, :message),
      do: {:ok, opts},
      else: {:error, "message is required"}
  end

  @impl true
  def validate(changeset, opts, _context) do
    site_id = changeset.tenant || Ash.Changeset.get_attribute(changeset, :site_id)

    with true <- Enum.any?(@addressed, &Ash.Changeset.changing_attribute?(changeset, &1)),
         address when is_binary(address) <- Address.of(post(changeset), site_id),
         {:ok, %{name: site}} <- SiteState.get(site_id),
         {:ok, %{section: "Page"} = page, captured} <-
           WebRunTimeMetaDataState.resolve(address, site),
         true <- literal?(page, captured) do
      {:error, field: :slug, message: opts[:message], address: address}
    else
      _free -> :ok
    end
  end

  # A page that answers the address before the post's own would: stored at that path, or at it under
  # a `:lang` prefix, and not a page of posts.
  defp literal?(%{record: "blog:post"}, _captured), do: false
  defp literal?(_page, captured), do: Map.keys(captured) -- [Languages.capture()] == []

  defp post(changeset) do
    struct(BlogPost, Map.new(@addressed, &{&1, Ash.Changeset.get_attribute(changeset, &1)}))
  end
end
