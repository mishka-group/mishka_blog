# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Test.SidebarMenuTest do
  @moduledoc """
  The blog's `"sidebar:menus"` plugin: that it contributes its entry to the admin nav, and that the
  entry and each page are gated by the blog's areas — `admin:dashboard:blog:post` for the editorial
  pages and Analytics, `admin:dashboard:blog:comment` for Comments, either for the link and Home.

  The plugin registers asynchronously (it retries until mnesia is up), so the hook-level test polls
  the way `MishkaBlog.Dashboard.CoreWidgetsTest` does. `call/1` is also exercised directly, which
  needs no running GenServer at all.
  """
  use MishkaBlog.DataCase

  alias MishkaBlogWeb.SidebarMenu
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions
  alias MishkaCmsCore.Sidebar

  @path "/admin/dashboard/blog"

  defp blog_item(user) do
    user
    |> Sidebar.menu()
    |> Map.fetch!(:main)
    |> Enum.find_value(fn entry ->
      entry
      |> Map.get(:items, [])
      |> Enum.find(&(&1.key == "blog"))
    end)
  end

  defp blog_entry, do: Enum.find(SidebarMenu.items(), &(&1.key == "blog"))

  defp plugins_group, do: Enum.find(Sidebar.core_menu().groups, &(&1.key == "plugins"))

  # Registration is asynchronous — the plugin retries until mnesia is ready — so there is no signal
  # to wait on but the registry itself. Same bounded poll the widget-registration tests use.
  defp wait_for_registration(remaining \\ 5_000) do
    cond do
      Enum.any?(Sidebar.collect().items, &(&1.key == "blog")) ->
        :ok

      remaining <= 0 ->
        flunk("MishkaBlogWeb.SidebarMenu never registered on #{Sidebar.event()}")

      true ->
        Process.sleep(100)
        wait_for_registration(remaining - 100)
    end
  end

  describe "credit — the blog's own name and page, under every page it owns" do
    test "names the blog and its page for its link and for a page that is not a link" do
      wait_for_registration()

      assert Sidebar.credit(MishkaBlogWeb.Live.Admin.Dashboard.Home.Index) ==
               %{name: "Mishka Blog", url: "https://mishka.tools/cms/extensions/blog"}

      assert Sidebar.credit(MishkaBlogWeb.Live.Admin.Dashboard.Tag.Index) ==
               %{name: "Mishka Blog", url: "https://mishka.tools/cms/extensions/blog"}
    end

    test "names none for a core page" do
      wait_for_registration()

      assert Sidebar.credit(MishkaCmsCoreWeb.Live.Admin.Dashboard.Home.Index) == nil
    end
  end

  describe "the plugin" do
    test "appends its item to the payload without touching what is already there" do
      seeded = Sidebar.core_menu()

      assert {:reply, %{items: items, groups: groups}} = SidebarMenu.call(seeded)
      assert groups == seeded.groups

      assert Enum.map(items, & &1.key) -- Enum.map(seeded.items, & &1.key) ==
               Enum.map(SidebarMenu.items(), & &1.key)
    end

    test "declares an entry the core never names, in the core's Plugins section" do
      item = Enum.find(SidebarMenu.items(), &(&1.key == "blog"))

      assert item.group == "plugins"
      assert item.path == @path
      assert item.nav
      refute Enum.any?(Sidebar.core_menu().items, &(&1.key == "blog"))
    end

    test "is registered on the event once the plugin engine is up" do
      wait_for_registration()

      assert Enum.any?(Sidebar.collect().items, &(&1.path == @path))
    end
  end

  describe "who sees it" do
    setup do
      wait_for_registration()
      :ok
    end

    @link SidebarMenu.permissions("blog")

    test "a blog editor and a comment moderator are each let see the entry, and are shown it" do
      for name <- ["admin:dashboard:blog:post", "admin:dashboard:blog:comment"] do
        user = create_user_with_permissions!([name])

        assert AccessPermissions.match?(user, %{}, permissions: @link), name
        assert Sidebar.visible_to?(blog_entry(), user), name
        assert %{label: "Blog"} = blog_item(user), name
      end
    end

    test "a full dashboard admin sees it in the menu" do
      assert %{label: "Blog"} = blog_item(create_user_with_permissions!(["admin:dashboard:*"]))
    end

    test "an admin of another area is not let see it, and is not shown it" do
      user = create_user_with_permissions!(["admin:dashboard:runtime:page"])

      refute AccessPermissions.match?(user, %{}, permissions: @link)
      refute Sidebar.visible_to?(blog_entry(), user)
      refute blog_item(user)
    end

    # THE SECTION ITSELF IS OPEN to this admin, so it is the blog's own gate that empties it.
    test "the Plugins section disappears with its last visible item" do
      user = create_user_with_permissions!(["admin:dashboard:runtime:page"])

      assert Sidebar.visible_to?(plugins_group(), user),
             "the Plugins section is closed to this admin on its own"

      refute Enum.any?(Sidebar.menu(user).main, &(Map.get(&1, :key) == "plugins"))
    end
  end

  describe "pages, not just the link" do
    test "only the entry itself is a link; every other page is nav: false" do
      assert Enum.filter(SidebarMenu.items(), & &1.nav) |> Enum.map(& &1.key) == ["blog"]
    end

    test "every routed admin page has a declaration, so none is left without a gate" do
      declared = MapSet.new(SidebarMenu.items(), & &1.path)

      for {:live, path, _module, _action} <- MishkaBlogWeb.Routes.routes(:admin) do
        full = Path.join("/admin/dashboard", path)
        assert MapSet.member?(declared, full), "#{full} has no declaration, so no gate"
      end
    end

    test "a moderator's gate is not an editor's — the whole reason pages are declared apart" do
      assert SidebarMenu.permissions("blog.comments") == ["admin:dashboard:blog:comment"]

      for key <- ~w(blog.posts blog.collections blog.tags blog.bloggers blog.teams
                    blog.auto_posting blog.analytics) do
        assert SidebarMenu.permissions(key) == ["admin:dashboard:blog:post"], key
      end
    end

    test "the LINK carries the union, since holding either is reason to see the section" do
      assert SidebarMenu.permissions("blog") ==
               ["admin:dashboard:blog:post", "admin:dashboard:blog:comment"]
    end

    test "an unknown key raises instead of quietly gating nothing" do
      assert_raise ArgumentError, ~r/no sidebar item declares the key/, fn ->
        SidebarMenu.permissions("blog.nope")
      end
    end
  end

  describe "PageGuard sees these declarations" do
    setup do
      wait_for_registration()
      :ok
    end

    test "EVERY routed admin page is declared — an omission would LOCK the page" do
      declared = MapSet.new(SidebarMenu.items(), & &1.module)

      for {:live, path, module, _action} <- MishkaBlogWeb.Routes.routes(:admin) do
        assert MapSet.member?(declared, module),
               "#{path} (#{inspect(module)}) has no declaration, so PageGuard would refuse it"
      end
    end

    test "an undeclared module is refused, never waved through" do
      assert Sidebar.permissions_for_module(Some.Undeclared.Page) == []
    end

    test "the split is real: Comments and Posts answer differently" do
      assert Sidebar.permissions_for_module(MishkaBlogWeb.Live.Admin.Dashboard.Comment.Index) ==
               ["admin:dashboard:blog:comment"]

      assert Sidebar.permissions_for_module(MishkaBlogWeb.Live.Admin.Dashboard.Post.Index) ==
               ["admin:dashboard:blog:post"]
    end

    test "a moderator's permission does not satisfy the Posts page" do
      moderator = create_user_with_permissions!(["admin:dashboard:blog:comment"])
      posts = Sidebar.permissions_for_module(MishkaBlogWeb.Live.Admin.Dashboard.Post.Index)
      comments = Sidebar.permissions_for_module(MishkaBlogWeb.Live.Admin.Dashboard.Comment.Index)

      assert AccessPermissions.match?(moderator, %{}, permissions: comments)
      refute AccessPermissions.match?(moderator, %{}, permissions: posts)
    end

    test "and an editor's does not satisfy the Comments page" do
      editor = create_user_with_permissions!(["admin:dashboard:blog:post"])
      posts = Sidebar.permissions_for_module(MishkaBlogWeb.Live.Admin.Dashboard.Post.Index)
      comments = Sidebar.permissions_for_module(MishkaBlogWeb.Live.Admin.Dashboard.Comment.Index)

      assert AccessPermissions.match?(editor, %{}, permissions: posts)
      refute AccessPermissions.match?(editor, %{}, permissions: comments)
    end
  end
end
