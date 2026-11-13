# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.PublishDirectlyTest do
  @moduledoc """
  A blogger whose profile lacks Can Publish Directly cannot publish or schedule a post; a blogger
  with it, a holder of the publish permission and a master can, and a plugin on
  `blog:post:can_publish` has the last word (`MishkaBlog.Resources.Validations.PublishDirectly`).
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.Test.Plugins.BlogPostCanPublishRefuse
  alias MishkaInstaller.Event.{Event, EventHandler}

  @post "admin:dashboard:blog:post"
  @publish "admin:dashboard:blog:publish"

  setup do
    site = create_site!()
    %{site: site, post: create_blog_post!(site_id: site.id, status: :draft)}
  end

  defp blogger_user(site, permissions, can_publish_directly) do
    user = create_user_with_permissions!(permissions, site_id: site.id)

    create_blogger!(
      site_id: site.id,
      user_id: user.id,
      can_publish_directly: can_publish_directly
    )

    user
  end

  # A master's write names no tenant, so the post is read the way a master reads it.
  defp as_master(post),
    do: Ash.get!(MishkaBlog.BlogPost, post.id, action: :master_get, authorize?: false)

  defp publish(post, actor) do
    post
    |> Ash.Changeset.for_update(:publish, %{}, actor: actor, tenant: post.site_id)
    |> Ash.update()
  end

  test "a blogger without Can Publish Directly is refused", %{site: site, post: post} do
    user = blogger_user(site, [@post], false)

    assert {:error, %Ash.Error.Invalid{errors: [%{field: :status}]}} = publish(post, user)

    assert {:error, %Ash.Error.Invalid{}} =
             post
             |> Ash.Changeset.for_update(
               :schedule,
               %{scheduled_publish_at: DateTime.add(DateTime.utc_now(), 1, :day)},
               actor: user,
               tenant: site.id
             )
             |> Ash.update()

    assert %{status: :draft} =
             Ash.get!(MishkaBlog.BlogPost, post.id, tenant: site.id, authorize?: false)
  end

  test "a blogger with Can Publish Directly publishes", %{site: site, post: post} do
    assert {:ok, %{status: :published}} = publish(post, blogger_user(site, [@post], true))
  end

  test "a holder of the publish permission is not blocked by their profile", %{
    site: site,
    post: post
  } do
    assert {:ok, %{status: :published}} =
             publish(post, blogger_user(site, [@post, @publish], false))
  end

  test "an editor with no blogger profile publishes", %{site: site, post: post} do
    editor = create_user_with_permissions!([@post], site_id: site.id)
    assert {:ok, %{status: :published}} = publish(post, editor)
  end

  test "a master is not blocked", %{post: post} do
    master = create_user_with_permissions!([@post])

    assert {:ok, %{status: :published}} =
             post
             |> as_master()
             |> Ash.Changeset.for_update(:master_publish, %{}, actor: master)
             |> Ash.update()
  end

  describe "a plugin on blog:post:can_publish" do
    setup do
      {:ok, _} =
        Event.write(%{
          name: BlogPostCanPublishRefuse,
          event: "blog:post:can_publish",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("blog:post:can_publish", :start, false)
      on_exit(fn -> Event.unregister(:name, BlogPostCanPublishRefuse, false) end)
    end

    test "refuses even a master", %{post: post} do
      master = create_user_with_permissions!([@post])

      assert {:error, %Ash.Error.Invalid{}} =
               post
               |> as_master()
               |> Ash.Changeset.for_update(:master_publish, %{}, actor: master)
               |> Ash.update()
    end
  end
end
