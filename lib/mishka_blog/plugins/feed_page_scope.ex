# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.FeedPageScope do
  @moduledoc """
  Names the term a blog page shows to the `feeds:page:scope` hook of
  `MishkaCmsCore.Feeds.HeadLinks`, so the head of a category's, a tag's or a blogger's page links
  that term's feeds beside the site's.

  The term is the record the page already read (`MishkaBlog.PageSource`, the `@page_source` of the
  page), so nothing is read for it. A category is named by its own slug, a nested one by its last
  segment, which is how `MishkaBlog.Plugins.FeedEntries` finds it; the title is its name, and a
  blogger's their display name. Any other page, and a page whose record was not found, is left as
  it is. Registered in `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "feeds:page:scope", initial: %{priority: 50}

  alias MishkaBlog.PageSource

  @kinds %{
    "blog:category" => {"category", :name},
    "blog:tag" => {"tag", :name},
    "blog:author" => {"author", :display_name}
  }

  @impl true
  def call(
        %{assigns: %{page_source: %PageSource{kind: kind, record: %{slug: slug} = record}}} = data
      )
      when is_map_key(@kinds, kind) and is_binary(slug) do
    {term, name} = Map.fetch!(@kinds, kind)

    case Map.get(record, name) do
      title when is_binary(title) -> {:reply, %{data | scope: {term, slug}, title: title}}
      _unnamed -> {:reply, data}
    end
  end

  def call(data), do: {:reply, data}
end
