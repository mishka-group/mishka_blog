defmodule MishkaBlog.Plugins.ContentComponents do
  @moduledoc """
  Tells a site's stylesheet which components its posts draw, which icons they name and which
  classes they write, through the `runtime:compile:content_components` hook
  `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.content_components/1` fires while it builds a
  site's stylesheet: the names the site's published posts list in `content_components`, the icon
  classes they list in `content_icons` and the classes they list in `content_classes`, which
  `MishkaBlog.Resources.Changes.ContentFacts` stores when a post is written. A template that draws a
  post's body — the kit's `blog-post-detail` — then reaches those components and no others
  (`MishkaCmsCore.Runtime.Compilers.CssClosure`), the stylesheet carries a rule for each icon, and
  it is built with each class.

  Read as the system, as the sitemap reads them (`MishkaBlog.Plugins.SitemapUrls`): a post locked to
  some readers draws its components, icons and classes for them, so it counts. Only the posts that
  name a component, an icon or a class are read, and only those columns. Registered in
  `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook,
    event: "runtime:compile:content_components",
    initial: %{priority: 50}

  require Ash.Query

  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler

  @impl true
  def call(%{site_id: site_id, components: names, icons: icons} = data)
      when is_binary(site_id) and is_list(names) and is_list(icons) do
    found = stored(site_id)

    {:reply,
     data
     |> Map.merge(%{components: names ++ found.components, icons: icons ++ found.icons})
     |> with_classes(found.classes)}
  end

  def call(data), do: {:reply, data}

  defp with_classes(%{classes: classes} = data, found) when is_list(classes),
    do: %{data | classes: classes ++ found}

  defp with_classes(data, _found), do: data

  # The component names, the icons and the classes, each once, in one read.
  defp stored(site_id) do
    MishkaBlog.BlogPost
    |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.filter(
      not is_nil(content_components) or not is_nil(content_icons) or not is_nil(content_classes)
    )
    |> Ash.Query.select([:content_components, :content_icons, :content_classes])
    |> SitemapCompiler.stream_rows(tenant: site_id, authorize?: false)
    |> Enum.reduce({MapSet.new(), MapSet.new(), MapSet.new()}, fn post, {named, shown, written} ->
      {Enum.into(post.content_components || [], named),
       Enum.into(post.content_icons || [], shown), Enum.into(post.content_classes || [], written)}
    end)
    |> then(fn {named, shown, written} ->
      %{
        components: MapSet.to_list(named),
        icons: MapSet.to_list(shown),
        classes: MapSet.to_list(written)
      }
    end)
  end
end
