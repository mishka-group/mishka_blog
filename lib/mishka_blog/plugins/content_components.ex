defmodule MishkaBlog.Plugins.ContentComponents do
  @moduledoc """
  Tells a site's stylesheet which components its posts draw, through the
  `runtime:compile:content_components` hook
  `MishkaCmsCore.Runtime.Compilers.TailwindCompiler.content_components/1` fires while it builds a
  site's stylesheet: the names the site's published posts list in `content_components`, which
  `MishkaBlog.Resources.Changes.ContentFacts` stores when a post is written. A template that draws a
  post's body — the kit's `blog-post-detail` — then reaches those components and no others
  (`MishkaCmsCore.Runtime.Compilers.CssClosure`).

  Read as the system, as the sitemap reads them (`MishkaBlog.Plugins.SitemapUrls`): a post locked to
  some readers draws its components for them, so it counts. Only the posts that name a component are
  read, and only that column. Registered in `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook,
    event: "runtime:compile:content_components",
    initial: %{priority: 50}

  require Ash.Query

  alias MishkaCmsCore.Runtime.Compilers.SitemapCompiler

  @impl true
  def call(%{site_id: site_id, components: names} = data)
      when is_binary(site_id) and is_list(names),
      do: {:reply, %{data | components: names ++ named(site_id)}}

  def call(data), do: {:reply, data}

  defp named(site_id) do
    MishkaBlog.BlogPost
    |> Ash.Query.for_read(:public_list, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.filter(not is_nil(content_components))
    |> Ash.Query.select([:content_components])
    |> SitemapCompiler.stream_rows(tenant: site_id, authorize?: false)
    |> Stream.flat_map(& &1.content_components)
    |> Enum.uniq()
  end
end
