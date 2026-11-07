# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Changes.PublicSlug do
  @moduledoc """
  The `MishkaSlug.Change` options every public slug of the Blog is made with: a blog post, tag,
  collection, blogger and team slug is the `MishkaSlug.slugify/2` slug of what was typed in `slug`,
  written back into `slug`.

  A slug keeps the scripts of the site's languages
  (`MishkaCmsCore.Runtime.Languages.slug_locales/1`) and drops the rest; a title with nothing left
  is an error on `slug`. A resource with a language reads it from that attribute so Arabic `ي` and
  `ك` fold to Persian `ی` and `ک` on a Persian record.

      change {MishkaSlug.Change, MishkaBlog.Resources.Changes.PublicSlug.options(:language)}
  """

  @doc """
  The change options. `language` is the attribute holding the record's language, or `nil` for a
  resource that has none.
  """
  @spec options(atom() | nil) :: keyword()
  def options(language \\ nil) do
    [
      from: :slug,
      into: :slug,
      language: language,
      locales: {MishkaCmsCore.Runtime.Languages, :slug_locales, []}
    ]
  end
end
