# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.PostAddressTest do
  @moduledoc """
  `MishkaBlog.Plugins.PostAddress`: a site's Post address setting puts its post page at
  `/:lang/blog/:category/:slug`, above the slug page, and back; the setting is on the Settings
  page's Blog tab, and saving it is what moves the page. An admin who may not edit pages changes
  nothing.

  `async: false`: the installer's plugins and the settings cache are process-global.
  """
  use MishkaBlog.DataCase, async: false

  require Ash.Query

  alias MishkaBlog.Plugins.{BlogSettings, PostAddress}
  alias MishkaBlog.Provision
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings

  @slug_page "/:lang/blog/:slug"
  @category_page "/:lang/blog/:category/:slug"

  setup do
    site = create_site!(active: true)
    Provision.ensure!(site)
    on_exit(fn -> SettingsState.delete(site.id, "blog.post_address") end)
    {:ok, site: site}
  end

  defp post_pages(site) do
    Page
    |> Ash.Query.filter(path in ^[@slug_page, @category_page])
    |> Ash.read!(tenant: site.id, authorize?: false)
    |> Map.new(&{&1.path, &1})
  end

  test "the Post address setting is on the Blog tab, a site's own, by the slug by default" do
    {:reply, %{definitions: definitions}} = BlogSettings.call(%{definitions: []})

    assert %{category: "blog", scope: :site, type: :select, default: "slug"} =
             Enum.find(definitions, &(&1.key == "blog.post_address"))
  end

  test "by category puts a post page there above the slug page, and by slug takes it away", %{
    site: site
  } do
    assert :ok = PostAddress.put(site.id, "category", nil)

    %{@slug_page => slug, @category_page => category} = post_pages(site)
    assert category.active
    assert category.priority > slug.priority
    assert category.extra["record"] == "blog:post"
    assert slug.active

    assert :ok = PostAddress.put(site.id, "slug", nil)
    %{@slug_page => slug, @category_page => category} = post_pages(site)
    refute category.active
    assert slug.active

    assert :ok = PostAddress.put(site.id, "category", nil)
    assert %{@category_page => %{active: true}} = post_pages(site)

    assert Page
           |> Ash.Query.filter(path == ^@category_page)
           |> Ash.count!(tenant: site.id, authorize?: false) == 1
  end

  test "saving the setting moves the page", %{site: site} do
    register_plugin!(PostAddress)

    {:ok, _} = Settings.put("blog.post_address", "category", site_id: site.id)
    assert %{@category_page => %{active: true}} = post_pages(site)

    {:ok, _} = Settings.put("blog.post_address", "slug", site_id: site.id)
    assert %{@category_page => %{active: false}} = post_pages(site)
  end

  test "an admin who may not edit pages moves nothing", %{site: site} do
    admin = create_user_with_permissions!(["admin:dashboard:setting"], site_id: site.id)

    assert {:error, _refused} = PostAddress.put(site.id, "category", admin)
    refute Map.has_key?(post_pages(site), @category_page)
  end
end
