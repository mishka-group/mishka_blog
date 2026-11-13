# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.PostPublishedEventTest do
  @moduledoc """
  A post that becomes published fires `blog:post:published` once its write is committed, and a
  post saved while already published fires nothing (`MishkaBlog.Resources.Changes.PublishLifecycle`).
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.Test.Plugins.BlogPostPublishedProbe
  alias MishkaInstaller.Event.{Event, EventHandler}

  setup do
    Process.register(self(), :__blog_hook_probe__)

    {:ok, _} =
      Event.write(%{
        name: BlogPostPublishedProbe,
        event: "blog:post:published",
        extension: :mishka_installer,
        status: :started
      })

    :ok = EventHandler.do_compile("blog:post:published", :start, false)
    on_exit(fn -> Event.unregister(:name, BlogPostPublishedProbe, false) end)

    site = create_site!()
    %{site: site, post: create_blog_post!(site_id: site.id, status: :draft)}
  end

  test "publishing a draft fires it once, with the post and its site", %{site: site, post: post} do
    published =
      post
      |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
      |> Ash.update!()

    post_id = post.id
    site_id = site.id
    assert_receive {:blog_post_published, ^post_id, ^site_id}

    published
    |> Ash.Changeset.for_update(:update, %{title: "Still published"},
      tenant: site.id,
      authorize?: false
    )
    |> Ash.update!()

    refute_received {:blog_post_published, ^post_id, _site_id}
  end

  test "a draft saved as a draft fires nothing", %{site: site, post: post} do
    post
    |> Ash.Changeset.for_update(:update, %{title: "Still a draft"},
      tenant: site.id,
      authorize?: false
    )
    |> Ash.update!()

    refute_received {:blog_post_published, _post_id, _site_id}
  end

  test "a post created as published fires it", %{site: site} do
    post = create_blog_post!(site_id: site.id, status: :published)

    post_id = post.id
    assert_receive {:blog_post_published, ^post_id, _site_id}
  end
end
