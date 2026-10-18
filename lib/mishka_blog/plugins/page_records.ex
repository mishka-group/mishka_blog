# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.PageRecords do
  @moduledoc """
  Names the kinds of record the blog's pages show — a post, a collection, a tag, a blogger, a team —
  on the `runtime:page:records` mishka_installer hook, for a page's "This page shows each" choice
  (see `MishkaCmsCore.Runtime.Seo.record_types/1`), each with a few of the site's own to preview a
  page with. Each is labelled as the blog's admin names it, where its Permissions and SEO Tags are set.
  `MishkaBlog.Plugins.PageSeo` answers for the same kinds.

  A module because a mishka_installer hook is one. Registered in `MishkaBlog.Application`.
  """

  use Gettext, backend: MishkaCmsCore.Gettext
  use MishkaInstaller.Event.Hook, event: "runtime:page:records", initial: %{priority: 50}

  alias MishkaBlog.{Blogger, BlogPost, Collection, Tag, Team}
  alias MishkaCmsCore.Runtime.Languages

  @samples 8

  @impl true
  def call(%{records: records} = state) when is_list(records),
    do: {:reply, %{state | records: records ++ types(Map.get(state, :site_id))}}

  def call(state), do: {:reply, state}

  @doc "The blog's kinds of record for `site_id`, with its latest of each as samples."
  @spec types(String.t() | nil) :: [map()]
  def types(site_id) do
    [
      type("blog:post", gettext("Post"), samples(BlogPost, :title, :published_at, site_id)),
      type(
        "blog:category",
        gettext("Collection"),
        samples(Collection, :name, :updated_at, site_id)
      ),
      type("blog:tag", gettext("Tag"), samples(Tag, :name, :updated_at, site_id)),
      type("blog:author", gettext("Blogger"), people(Blogger, :display_name, site_id)),
      type("blog:team", gettext("Team"), people(Team, :name, site_id))
    ]
  end

  defp type(id, label, samples),
    do: %{id: id, group: gettext("Blog"), label: label, captures: ["slug"], samples: samples}

  # The latest a guest may open, each with the captures that open it. The hook names no reader, and
  # a preview is of the page a visitor is served.
  defp samples(resource, name, newest, site_id) when is_binary(site_id) do
    resource
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.select([name, :slug, :language])
    |> Ash.Query.sort([{newest, :desc}])
    |> Ash.read(page: [limit: @samples])
    |> case do
      {:ok, %{results: rows}} ->
        for %{slug: slug, language: language} = row <- rows,
            is_binary(slug),
            do: %{
              label: "#{Map.get(row, name)} · #{language}",
              params: %{"slug" => slug, Languages.capture() => language}
            }

      _unreadable ->
        []
    end
  end

  defp samples(_resource, _name, _newest, _no_site), do: []

  # A blogger or a team is one row in every language, so its sample names the slug alone.
  defp people(resource, name, site_id) when is_binary(site_id) do
    resource
    |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site_id)
    |> Ash.Query.select([name, :slug])
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read(page: [limit: @samples])
    |> case do
      {:ok, %{results: rows}} ->
        for %{slug: slug} = row <- rows,
            is_binary(slug),
            do: %{label: Map.get(row, name), params: %{"slug" => slug}}

      _unreadable ->
        []
    end
  end

  defp people(_resource, _name, _no_site), do: []
end
