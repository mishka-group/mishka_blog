# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Notify.BlogProducerTest do
  @moduledoc """
  The blog "post published" producer: notifies the holders of the blog's post area on the dashboard
  (`admin:dashboard:blog:post`, or a wildcard covering it), on the post's site and among the
  masters, and no one else — not a comment moderator, not an admin of another area, not an API
  admin.

  Calling `call/2` directly proves who is told; it cannot prove anything is ever told, because it
  skips the event the plugin listens on. The real-action cases publish through `:publish` and
  `:master_publish`, so the notification only arrives when each plugin's event is the one the action
  fires.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.Notifiers.{PostMasterPublished, PostPublished}
  alias MishkaCmsCore.Notify.Notification
  alias MishkaCmsCore.PluginRegistrations
  alias MishkaInstaller.Event.{Event, EventHandler}

  defp with_permission(user, permission) do
    user
    |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [permission.id]},
      authorize?: false
    )
    |> Ash.update!()
  end

  defp feed(user) do
    Notification
    |> Ash.Query.for_read(:feed)
    |> Ash.read!(actor: user, tenant: user.site_id, page: false)
  end

  # Granting a permission notifies admins too, so only the post notifications are counted.
  defp published(user), do: Enum.filter(feed(user), &(&1.type == "blog:post:published"))

  # THE APPLICATION'S PLUGIN PROCESSES ARE NOT RUNNING IN THIS SUITE, so nothing registers these two
  # on its own. Each is registered the way the CMS boot registers it — a registration left under an
  # older event is moved first, then the plugin registers on the event it declares — and its chain
  # is rebuilt before the action runs.
  #
  # Unregistered when the test exits: Mnesia is on disk, so a registration left behind would make
  # every later `:publish` in any blog suite notify — but only on runs after this file first ran.
  defp register(plugin) do
    PluginRegistrations.reconcile(false)
    {:ok, _} = plugin.register()
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
    :ok = EventHandler.do_compile(plugin.config(:__event__), :start, false)
  end

  test "publishing a post notifies tenant blog admins and master admins, not others" do
    site = create_site!()

    blog_edit = create_permission!(name: "admin:dashboard:blog:post")
    star = create_permission!(name: "*")

    tenant_blog_admin = with_permission(create_user!(site_id: site.id), blog_edit)
    tenant_plain = create_user!(site_id: site.id)
    master_admin = with_permission(create_user!(), star)
    master_plain = create_user!()

    post = create_blog_post!(site_id: site.id)

    assert {:reply, _} = PostPublished.call(post, %{})

    # Tenant blog editor (the post area) is notified.
    assert [n] = feed(tenant_blog_admin)
    assert n.type == "blog:post:published"
    assert n.metadata["title"] == to_string(post.title)

    # Master admin (holds "*") is notified — cross-site — and the row carries the originating site.
    assert [m] = feed(master_admin)
    assert m.site_id == site.id

    # Non-admins get nothing.
    assert feed(tenant_plain) == []
    assert feed(master_plain) == []
  end

  test "a moderator, an admin of another area and an API admin are not told" do
    site = create_site!()

    others =
      for name <- ["admin:dashboard:blog:comment", "admin:dashboard:runtime:page", "admin:api:*"] do
        with_permission(create_user!(site_id: site.id), create_permission!(name: name))
      end

    editor =
      with_permission(
        create_user!(site_id: site.id),
        create_permission!(name: "admin:dashboard:blog:post")
      )

    assert {:reply, _} = PostPublished.call(create_blog_post!(site_id: site.id), %{})

    assert [_told] = published(editor)
    assert Enum.all?(others, &(published(&1) == []))
  end

  test "the publisher (meta.actor) is not notified about their own post" do
    site = create_site!()
    star = create_permission!(name: "*")

    publisher = with_permission(create_user!(site_id: site.id), star)
    other_admin = with_permission(create_user!(site_id: site.id), star)

    post = create_blog_post!(site_id: site.id)

    assert {:reply, _} = PostPublished.call(post, %{actor: publisher})

    # The publisher holds "*" (would normally match) but is excluded via `except:` — no post row.
    # (They may hold unrelated notifications, e.g. another user's registration, so filter by type.)
    refute Enum.any?(feed(publisher), &(&1.type == "blog:post:published"))
    # Another admin still gets the post notification.
    assert Enum.any?(feed(other_admin), &(&1.type == "blog:post:published"))
  end

  describe "publishing through the real actions" do
    setup do
      site = create_site!()
      star = create_permission!(name: "*")

      %{
        site: site,
        star: star,
        post: create_blog_post!(site_id: site.id, status: :draft),
        tenant_blog_admin:
          with_permission(
            create_user!(site_id: site.id),
            create_permission!(name: "admin:dashboard:blog:post")
          ),
        tenant_plain: create_user!(site_id: site.id),
        master_admin: with_permission(create_user!(), star)
      }
    end

    test "a tenant :publish notifies blog and master admins, not the publisher", ctx do
      register(PostPublished)
      publisher = with_permission(create_user!(site_id: ctx.site.id), ctx.star)

      ctx.post
      |> Ash.Changeset.for_update(:publish, %{},
        actor: publisher,
        tenant: ctx.site.id,
        authorize?: false
      )
      |> Ash.update!()

      assert [n] = published(ctx.tenant_blog_admin)
      assert n.metadata["slug"] == to_string(ctx.post.slug)
      assert [%{site_id: site_id}] = published(ctx.master_admin)
      assert site_id == ctx.site.id
      assert published(publisher) == []
      assert published(ctx.tenant_plain) == []
    end

    test "a master :master_publish notifies blog and master admins, not the publisher", ctx do
      register(PostMasterPublished)
      publisher = with_permission(create_user!(), ctx.star)

      ctx.post
      |> Ash.Changeset.for_update(:master_publish, %{}, actor: publisher, authorize?: false)
      |> Ash.update!()

      assert [n] = published(ctx.tenant_blog_admin)
      assert n.metadata["slug"] == to_string(ctx.post.slug)
      assert [%{site_id: site_id}] = published(ctx.master_admin)
      assert site_id == ctx.site.id
      assert published(publisher) == []
      assert published(ctx.tenant_plain) == []
    end
  end
end
