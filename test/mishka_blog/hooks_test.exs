# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.HooksTest do
  @moduledoc """
  Confirms the global plugin hooks on the MishkaBlog resources dispatch to a registered
  MishkaInstaller plugin when the real Ash actions run — i.e. the `blog:<resource>:*` events
  we wired actually fire end-to-end.

  The MishkaInstaller event engine already runs app-wide, so we register a probe plugin per
  event, run the real action via the factory, and assert the plugin received the record + meta.
  """
  use MishkaBlog.DataCase, async: false

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaInstaller.Event.{Event, EventHandler}

    alias MishkaBlog.Test.Plugins.{
      BlogBloggerAfterCreate,
      BlogCommentAfterCreate,
      BlogPostAfterCreate,
      BlogPostRatingAfterCreate,
      BlogPostRatingAfterRemove,
      BlogTeamAfterCreate
    }

    @probes [
      {BlogPostAfterCreate, "blog:blog_post:after_create"},
      {BlogCommentAfterCreate, "blog:comment:after_create"},
      {BlogBloggerAfterCreate, "blog:blogger:after_create"},
      {BlogPostRatingAfterCreate, "blog:post_rating:after_create"},
      {BlogTeamAfterCreate, "blog:team:after_create"},
      {BlogPostRatingAfterRemove, "blog:post_rating:after_remove"}
    ]

    setup do
      Process.register(self(), :__blog_hook_probe__)

      for {module, event} <- @probes, do: register_plugin(module, event)

      on_exit(fn ->
        for {module, _event} <- @probes, do: Event.unregister(:name, module, false)
      end)

      :ok
    end

    test "blog post :create dispatches blog:blog_post:after_create with the record and meta" do
      site = create_site!()
      post = create_blog_post!(site_id: site.id)
      post_id = post.id

      assert_receive {:blog_post_after_create, ^post_id, meta}
      assert meta.site_id == site.id
    end

    test "comment :create dispatches blog:comment:after_create with the record and meta" do
      site = create_site!()
      post = create_blog_post!(site_id: site.id)
      comment = create_comment!(site_id: site.id, post_id: post.id)
      comment_id = comment.id

      assert_receive {:blog_comment_after_create, ^comment_id, meta}
      assert meta.site_id == site.id
    end

    test "blogger :create dispatches blog:blogger:after_create with the record and meta" do
      site = create_site!()
      blogger = create_blogger!(site_id: site.id)
      blogger_id = blogger.id

      assert_receive {:blog_blogger_after_create, ^blogger_id, meta}
      assert meta.site_id == site.id
    end

    test "team :create dispatches blog:team:after_create with the record and meta" do
      site = create_site!()
      team = create_team!(site_id: site.id)
      team_id = team.id

      assert_receive {:blog_team_after_create, ^team_id, meta}
      assert meta.site_id == site.id
    end

    test "post rating :create dispatches blog:post_rating:after_create with the record" do
      rating = create_post_rating!()
      rating_id = rating.id

      assert_receive {:blog_post_rating_after_create, ^rating_id, _meta}
    end

    test "post rating DESTROY (:remove) dispatches blog:post_rating:after_remove — destroys are hooked" do
      rating = create_post_rating!()
      rating_id = rating.id

      Ash.destroy!(rating, action: :remove, authorize?: false)

      assert_receive {:blog_post_rating_after_remove, ^rating_id, _meta}
    end

    defp register_plugin(module, event) do
      {:ok, _} =
        Event.write(%{
          name: module,
          event: event,
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(event, :start, false)
    end
  end
end
