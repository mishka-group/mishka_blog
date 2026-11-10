# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.FeedLinks do
  @moduledoc """
  Lets a feed reader find the blog's feeds from any page of the site. The root layout fires
  `RootHtml.MetaTags` inside `<head>` with `%{html: html, assigns: assigns}`, and this plugin appends
  one `<link rel="alternate">` for the RSS, the Atom and the JSON feed of the site in the page's
  language (`MishkaBlog.Feeds.path/4`), titled with the site's title.

  A category's, a tag's or a blogger's page also names that term's feeds, titled with the term's
  name after the site's. The term is the record the page already read (`MishkaBlog.PageSource`, the
  page's `@page_source`), so nothing is read for it; a nested category is named by its own slug.

  Only a page of the site (`runtime_page`) names them, and only while the site has the blog
  switched on (`MishkaCmsCore.Install.Extensions.active?/2`) and its feeds on; the admin and the
  installer name none. Every attribute is escaped. Registered in `MishkaBlog.Application`.
  """
  use MishkaInstaller.Event.Hook, event: "RootHtml.MetaTags", initial: %{priority: 70}

  alias MishkaBlog.{Feeds, PageSource}
  alias MishkaBlog.Feeds.Renderer
  alias MishkaCmsCore.Helpers
  alias MishkaCmsCore.Install.Extensions
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Settings

  @terms %{
    "blog:category" => {"category", :name},
    "blog:tag" => {"tag", :name},
    "blog:author" => {"author", :display_name}
  }

  @impl true
  def call(
        %{
          html: html,
          assigns: %{runtime_page: true, current_site: %{id: site_id} = site} = assigns
        } = state
      )
      when is_binary(html) and is_binary(site_id) do
    if Extensions.active?(site_id, :mishka_blog) and Feeds.enabled?(site_id),
      do: {:reply, %{state | html: html <> links(site, assigns)}},
      else: {:reply, state}
  end

  def call(state), do: {:reply, state}

  defp links(site, assigns) do
    language = assigns[:site_language]

    language =
      if language in Languages.site(site.id), do: language, else: Languages.primary(site.id)

    title = Settings.get("site.title", "Mishka CMS", site.id)

    tags(site, language, :site, title) <> term_links(site, language, title, assigns)
  end

  defp term_links(site, language, site_title, %{
         page_source: %PageSource{kind: kind, record: %{slug: slug} = record}
       })
       when is_map_key(@terms, kind) and is_binary(slug) do
    {term, name} = Map.fetch!(@terms, kind)

    case Map.get(record, name) do
      name when is_binary(name) -> tags(site, language, {term, slug}, site_title <> " - " <> name)
      _unnamed -> ""
    end
  end

  defp term_links(_site, _language, _site_title, _assigns), do: ""

  defp tags(site, language, scope, title) do
    Enum.map_join(Renderer.formats(), fn format ->
      attrs = [
        rel: "alternate",
        type: Renderer.content_type(format),
        title: title,
        href: Helpers.site_url(site.host, Feeds.path(scope, format, language, site.id))
      ]

      "<link" <>
        (attrs |> Phoenix.HTML.attributes_escape() |> Phoenix.HTML.safe_to_string()) <> ">\n"
    end)
  end
end
