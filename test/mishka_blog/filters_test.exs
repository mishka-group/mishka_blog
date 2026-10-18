# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.FiltersTest do
  @moduledoc """
  Confirms the three "filter" plugin seams added to the blog resources actually take effect:
  the content render filter (calculation), the query filter (preparation), and the before/reject seam
  (change) — the WordPress `the_content` / `pre_get_posts` / `pre_comment_approved` equivalents. The
  query filter is on the public reads of bloggers and teams too, which the blog's people pages run.
  """
  use MishkaBlog.DataCase, async: false

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.Test.Plugins.{
      BlogBloggerQueryPublicBySlug,
      BlogCommentBeforeCreatePublic,
      BlogPostQueryPublished,
      BlogPostRenderContent,
      BlogTeamQueryPublicList
    }

    setup do
      Process.register(self(), :__blog_hook_probe__)
      :ok
    end

    test "RENDER filter: a plugin transforms :rendered_content (the_content seam)" do
      with_plugin(BlogPostRenderContent, "blog:blog_post:render_content", fn ->
        site = create_site!()
        post = create_blog_post!(site_id: site.id, content: "<p>hello</p>")

        loaded = Ash.load!(post, [:rendered_content], tenant: site.id, authorize?: false)

        assert loaded.rendered_content == "<p>hello</p> [rendered by plugin]"
      end)
    end

    test "QUERY filter: a plugin's prepare hook fires on read :published (pre_get_posts seam)" do
      with_plugin(BlogPostQueryPublished, "blog:blog_post:query_published", fn ->
        site = create_site!()
        create_blog_post!(site_id: site.id, status: :published)

        Ash.read!(MishkaBlog.BlogPost, action: :published, tenant: site.id, authorize?: false)

        assert_receive {:query_hook_fired, :published}
      end)
    end

    test "QUERY filter: a blogger's public read by slug hands the plugin the visitor it reads for" do
      with_plugin(BlogBloggerQueryPublicBySlug, "blog:blogger:query_public_by_slug", fn ->
        site = create_site!()
        create_blogger!(site_id: site.id, slug: "mona")
        visitor = create_user!(site_id: site.id)

        MishkaBlog.Blogger
        |> Ash.Query.for_read(:public_by_slug, %{slug: "mona"}, actor: visitor, tenant: site.id)
        |> Ash.read_one!()

        assert_receive {:query_hook_fired, :public_by_slug, %{id: id}}
        assert id == visitor.id
      end)
    end

    test "QUERY filter: a plugin's prepare hook fires on a team's public list" do
      with_plugin(BlogTeamQueryPublicList, "blog:team:query_public_list", fn ->
        site = create_site!()
        create_team!(site_id: site.id, status: :active)

        MishkaBlog.Team
        |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site.id)
        |> Ash.read!()

        assert_receive {:query_hook_fired, :public_list}
      end)
    end

    test "BEFORE filter: a plugin can reject a comment via :create_public (pre_comment_approved seam)" do
      with_plugin(BlogCommentBeforeCreatePublic, "blog:comment:before_create_public", fn ->
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        result =
          MishkaBlog.Comment
          |> Ash.Changeset.for_create(
            :create_public,
            %{post_id: post.id, content: "REJECT_THIS_COMMENT please"},
            tenant: site.id,
            actor: user,
            authorize?: false
          )
          |> Ash.create()

        assert {:error, _} = result
      end)
    end
  end
end
