# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.PostBloggerTest do
  @moduledoc """
  Tests for MishkaBlog.PostBlogger resource - join table for posts and bloggers.
  """
  use MishkaBlog.DataCase, async: false

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.PostBlogger

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(PostBlogger) == "mishka_blog_post_bloggers"
      end

      test "uses composite primary key (post_id, blogger_id)" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        blogger = create_blogger!(site_id: site.id)

        assignment = create_post_blogger!(post_id: post.id, blogger_id: blogger.id)

        # Composite key means both IDs together form the primary key
        assert assignment.post_id == post.id
        assert assignment.blogger_id == blogger.id
      end
    end

    describe "assign action (upsert)" do
      test "assigns blogger to post" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        blogger = create_blogger!(site_id: site.id)

        assignment = create_post_blogger!(post_id: post.id, blogger_id: blogger.id)

        assert assignment.post_id == post.id
        assert assignment.blogger_id == blogger.id
      end

      test "accepts optional role field" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        blogger = create_blogger!(site_id: site.id)

        assignment =
          create_post_blogger!(
            post_id: post.id,
            blogger_id: blogger.id,
            role: "primary author"
          )

        assert assignment.role == "primary author"
      end

      test "upsert prevents duplicate assignments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        blogger = create_blogger!(site_id: site.id)

        # First assignment
        assignment1 =
          create_post_blogger!(
            post_id: post.id,
            blogger_id: blogger.id,
            role: "author"
          )

        # Second assignment (upsert)
        assignment2 =
          create_post_blogger!(
            post_id: post.id,
            blogger_id: blogger.id,
            role: "primary author"
          )

        # Should be same record with updated role
        assert assignment1.post_id == assignment2.post_id
        assert assignment1.blogger_id == assignment2.blogger_id
        assert assignment2.role == "primary author"
      end

      test "allows same blogger on different posts" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id)
        post2 = create_blog_post!(site_id: site.id)
        blogger = create_blogger!(site_id: site.id)

        assignment1 = create_post_blogger!(post_id: post1.id, blogger_id: blogger.id)
        assignment2 = create_post_blogger!(post_id: post2.id, blogger_id: blogger.id)

        assert assignment1.blogger_id == assignment2.blogger_id
        assert assignment1.post_id != assignment2.post_id
      end

      test "allows multiple bloggers on same post" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        blogger1 = create_blogger!(site_id: site.id)
        blogger2 = create_blogger!(site_id: site.id)

        assignment1 = create_post_blogger!(post_id: post.id, blogger_id: blogger1.id)
        assignment2 = create_post_blogger!(post_id: post.id, blogger_id: blogger2.id)

        assert assignment1.post_id == assignment2.post_id
        assert assignment1.blogger_id != assignment2.blogger_id
      end
    end

    describe "destroy action" do
      test "removes blogger assignment from post" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        blogger = create_blogger!(site_id: site.id)

        assignment = create_post_blogger!(post_id: post.id, blogger_id: blogger.id)

        assignment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Verify it's removed
        all_assignments = Ash.read!(PostBlogger, authorize?: false)

        refute Enum.any?(all_assignments, fn a ->
                 a.post_id == post.id and a.blogger_id == blogger.id
               end)
      end
    end
  end
end
