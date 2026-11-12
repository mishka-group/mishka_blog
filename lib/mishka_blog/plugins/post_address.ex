# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.PostAddress do
  @moduledoc """
  Puts a site's post page where its **Post address** setting says, after the setting is saved
  (`cms_core:setting:after_save`). The setting, `blog.post_address`, is in an **Addresses** group
  under the **Blog** tab of the Settings page (`definition/0`, registered by
  `MishkaBlog.Plugins.BlogSettings`), and each site sets its own:

    * `"slug"` (the default): posts at `/blog/<post>`, the page the blog provisions;
    * `"category"`: posts at `/blog/<category>/<post>`, as WordPress's `/%category%/%postname%/`.

  Choosing `"category"` gives the site a post page at `/:lang/blog/:category/:slug`: the one it
  has is made active, else the blog's post page is written there (`MishkaBlog.Provision.ensure_pages!/3`).
  Its priority is one above the slug page's, so it is the post page every link and canonical names
  (`MishkaBlog.Address`). The slug page stays: it serves a post filed under nothing, and sends a
  post with a category on to its own address (`MishkaBlog.Plugins.PostMoved`). Choosing `"slug"`
  again makes the category page inactive.

  The pages are written through the Page resource's own `:update`, as the admin who saved the
  setting, so one who may not edit pages changes the setting and nothing else; the refusal is
  logged. A save with no actor (`MishkaCmsCore.Settings.put/3`, the seeds) writes them as the
  system. Each page write is compiled into the site's routing as any page edit is. A page that
  already is as asked is not written.

  Registered in `MishkaBlog.Application`.
  """

  alias MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook

  use MishkaInstaller.Event.Hook,
    event: PluginHook.save_event_name(MishkaCmsCore.Runtime.Setting),
    initial: %{priority: 50}

  use Gettext, backend: MishkaCmsCore.Gettext

  require Ash.Query
  require Logger

  alias MishkaBlog.Provision
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Settings

  @key "blog.post_address"
  @category_page "/:lang/blog/:category/:slug"

  @impl true
  def call(%{key: @key, site_id: site_id, value: %{"value" => value}} = setting, meta)
      when is_binary(site_id) do
    with {:error, error} <- put(site_id, value, Map.get(meta, :actor)) do
      Logger.warning("The post page of site #{site_id} was not moved: #{inspect(error)}")
    end

    {:reply, setting}
  end

  def call(setting, _meta), do: {:reply, setting}

  @doc "The Post address setting, as the Settings page draws it."
  @spec definition() :: map()
  def definition do
    Settings.define(@key, :select,
      default: "slug",
      category: "blog",
      group: gettext_noop("Addresses"),
      scope: :site,
      source: :plugin,
      options: [
        {gettext_noop("/blog/post"), "slug"},
        {gettext_noop("/blog/category/post, the post's first category"), "category"}
      ],
      label: gettext_noop("Post address"),
      description:
        gettext_noop(
          "Where a post is read. With its category, a post filed under none stays at /blog/post, and the old address of every other post is sent to the new one."
        )
    )
  end

  @doc """
  Puts the post pages of `site_id` where `address` (`"slug"` or `"category"`) says, as `actor`, or
  as the system for `nil` (see the module doc).
  """
  @spec put(String.t(), String.t(), map() | nil) :: :ok | {:error, term()}
  def put(site_id, address, actor) do
    with {:ok, pages} <- pages(site_id, actor) do
      slug = Enum.find(pages, &(&1.path == Provision.item_paths().post))
      category = Enum.find(pages, &(&1.path == @category_page))
      placed(address, slug, category, site_id, actor)
    end
  end

  defp placed("category", slug, nil, site_id, actor) do
    Provision.ensure_pages!(site_id, %{Provision.item_paths().post => @category_page},
      actor: actor
    )

    with {:ok, pages} <- pages(site_id, actor) do
      case Enum.find(pages, &(&1.path == @category_page)) do
        nil -> {:error, :not_written}
        category -> placed("category", slug, category, site_id, actor)
      end
    end
  rescue
    error -> {:error, error}
  end

  defp placed("category", slug, category, site_id, actor),
    do: write(category, %{active: true, priority: above(slug)}, site_id, actor)

  defp placed("slug", _slug, nil, _site_id, _actor), do: :ok

  defp placed("slug", _slug, category, site_id, actor),
    do: write(category, %{active: false}, site_id, actor)

  defp placed(_unknown, _slug, _category, _site_id, _actor), do: :ok

  defp above(%{priority: priority}), do: min(priority + 1, 100)
  defp above(nil), do: 1

  defp write(page, changes, site_id, actor) do
    if Enum.all?(changes, fn {field, value} -> Map.get(page, field) == value end) do
      :ok
    else
      page
      |> Ash.Changeset.for_update(:update, changes, as(site_id, actor))
      |> Ash.update()
      |> case do
        {:ok, _page} -> :ok
        {:error, error} -> {:error, error}
      end
    end
  end

  # The site's post pages, active or not, in one read.
  defp pages(site_id, actor) do
    Page
    |> Ash.Query.for_read(:read, %{}, as(site_id, actor))
    |> Ash.Query.filter(path in ^[Provision.item_paths().post, @category_page])
    |> Ash.read()
  end

  defp as(site_id, nil), do: [tenant: site_id, authorize?: false]
  defp as(site_id, actor), do: [actor: actor, tenant: site_id]
end
