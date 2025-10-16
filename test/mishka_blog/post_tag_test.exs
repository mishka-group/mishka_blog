defmodule MishkaBlog.Test.PostTagTest do
  @moduledoc """
  Tests for MishkaBlog.PostTag resource - join table for posts and tags.
  """
  use MishkaBlog.DataCase, async: false

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.PostTag

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(PostTag) == "mishka_blog_post_tags"
      end

      test "uses composite primary key (post_id, tag_id)" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        tag = create_blog_tag!(site_id: site.id)

        assignment = create_post_tag!(post_id: post.id, tag_id: tag.id)

        # Composite key means both IDs together form the primary key
        assert assignment.post_id == post.id
        assert assignment.tag_id == tag.id
      end

      test "is a global resource (not multi-tenant)" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(PostTag)
        assert multitenancy_config == nil
        assert Ash.Resource.Info.multitenancy_global?(PostTag) == nil
      end
    end

    describe "assign action (upsert)" do
      test "assigns tag to post" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        tag = create_blog_tag!(site_id: site.id)

        assignment = create_post_tag!(post_id: post.id, tag_id: tag.id)

        assert assignment.post_id == post.id
        assert assignment.tag_id == tag.id
        assert assignment.inserted_at != nil
      end

      test "upsert prevents duplicate assignments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        tag = create_blog_tag!(site_id: site.id)

        # First assignment
        assignment1 = create_post_tag!(post_id: post.id, tag_id: tag.id)

        # Second assignment (upsert)
        assignment2 = create_post_tag!(post_id: post.id, tag_id: tag.id)

        # Should be same record
        assert assignment1.post_id == assignment2.post_id
        assert assignment1.tag_id == assignment2.tag_id
      end

      test "allows same post to have different tags" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        tag1 = create_blog_tag!(site_id: site.id)
        tag2 = create_blog_tag!(site_id: site.id)

        assignment1 = create_post_tag!(post_id: post.id, tag_id: tag1.id)
        assignment2 = create_post_tag!(post_id: post.id, tag_id: tag2.id)

        assert assignment1.post_id == assignment2.post_id
        assert assignment1.tag_id != assignment2.tag_id
      end

      test "allows multiple posts to have same tag" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id)
        post2 = create_blog_post!(site_id: site.id)
        tag = create_blog_tag!(site_id: site.id)

        assignment1 = create_post_tag!(post_id: post1.id, tag_id: tag.id)
        assignment2 = create_post_tag!(post_id: post2.id, tag_id: tag.id)

        assert assignment1.tag_id == assignment2.tag_id
        assert assignment1.post_id != assignment2.post_id
      end

      test "sets inserted_at timestamp" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        tag = create_blog_tag!(site_id: site.id)

        assignment = create_post_tag!(post_id: post.id, tag_id: tag.id)

        assert assignment.inserted_at != nil
        assert is_struct(assignment.inserted_at, DateTime)
      end
    end

    describe "destroy action" do
      test "removes tag from post" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        tag = create_blog_tag!(site_id: site.id)

        assignment = create_post_tag!(post_id: post.id, tag_id: tag.id)

        assignment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Verify it's removed
        all_assignments = Ash.read!(PostTag, authorize?: false)

        refute Enum.any?(all_assignments, fn a ->
                 a.post_id == post.id and a.tag_id == tag.id
               end)
      end

      test "does not delete related post when assignment is removed" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        tag = create_blog_tag!(site_id: site.id)

        assignment = create_post_tag!(post_id: post.id, tag_id: tag.id)

        assignment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Post should still exist
        fetched_post = Ash.get!(MishkaBlog.BlogPost, post.id, authorize?: false, tenant: site.id)
        assert fetched_post.id == post.id
      end

      test "does not delete related tag when assignment is removed" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        tag = create_blog_tag!(site_id: site.id)

        assignment = create_post_tag!(post_id: post.id, tag_id: tag.id)

        assignment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Tag should still exist
        fetched_tag = Ash.get!(MishkaBlog.Tag, tag.id, authorize?: false, tenant: site.id)
        assert fetched_tag.id == tag.id
      end
    end

    describe "read actions" do
      test "lists all post-tag assignments" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id)
        post2 = create_blog_post!(site_id: site.id)
        tag = create_blog_tag!(site_id: site.id)

        _assignment1 = create_post_tag!(post_id: post1.id, tag_id: tag.id)
        _assignment2 = create_post_tag!(post_id: post2.id, tag_id: tag.id)

        all_assignments = Ash.read!(PostTag, authorize?: false)

        assert Enum.any?(all_assignments, fn a -> a.post_id == post1.id and a.tag_id == tag.id end)

        assert Enum.any?(all_assignments, fn a -> a.post_id == post2.id and a.tag_id == tag.id end)
      end

      test "pagination works on read action" do
        site = create_site!()
        tag = create_blog_tag!(site_id: site.id)

        # Create 5 post assignments
        _posts =
          for _ <- 1..5 do
            post = create_blog_post!(site_id: site.id)
            create_post_tag!(post_id: post.id, tag_id: tag.id)
            post
          end

        result =
          PostTag
          |> Ash.Query.page(limit: 3, count: true)
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 3
        assert result.count >= 5
      end
    end

    describe "database references" do
      test "assignment references valid post and tag" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        tag = create_blog_tag!(site_id: site.id)

        assignment = create_post_tag!(post_id: post.id, tag_id: tag.id)

        # Verify assignment has valid foreign keys
        assert assignment.post_id == post.id
        assert assignment.tag_id == tag.id

        # Note: Both BlogPost and Tag use soft deletion (archival),
        # so cascade deletes only trigger on permanent_destroy
      end
    end

    describe "relationships" do
      test "loads post relationship" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        tag = create_blog_tag!(site_id: site.id)

        _assignment = create_post_tag!(post_id: post.id, tag_id: tag.id)

        # Load assignments, find ours, then load the post with tenant
        assignment =
          PostTag
          |> Ash.read!(authorize?: false)
          |> Enum.find(fn a -> a.post_id == post.id and a.tag_id == tag.id end)

        # Load the post relationship
        loaded_assignment = Ash.load!(assignment, [:post], tenant: site.id, authorize?: false)
        assert loaded_assignment.post.id == post.id
      end

      test "loads tag relationship" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        tag = create_blog_tag!(site_id: site.id)

        _assignment = create_post_tag!(post_id: post.id, tag_id: tag.id)

        # Load assignments, find ours, then load the tag with tenant
        assignment =
          PostTag
          |> Ash.read!(authorize?: false)
          |> Enum.find(fn a -> a.post_id == post.id and a.tag_id == tag.id end)

        # Load the tag relationship
        loaded_assignment = Ash.load!(assignment, [:tag], tenant: site.id, authorize?: false)
        assert loaded_assignment.tag.id == tag.id
      end
    end

    describe "tag management" do
      test "post can have multiple tags (tagging system)" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        # Create multiple tags for categorization
        tag_elixir = create_blog_tag!(name: "Elixir", slug: "elixir", site_id: site.id)

        tag_programming =
          create_blog_tag!(name: "Programming", slug: "programming", site_id: site.id)

        tag_tutorial = create_blog_tag!(name: "Tutorial", slug: "tutorial", site_id: site.id)

        # Tag the post
        create_post_tag!(post_id: post.id, tag_id: tag_elixir.id)
        create_post_tag!(post_id: post.id, tag_id: tag_programming.id)
        create_post_tag!(post_id: post.id, tag_id: tag_tutorial.id)

        # Verify post has 3 tags
        all_assignments = Ash.read!(PostTag, authorize?: false)
        post_tags = Enum.filter(all_assignments, fn a -> a.post_id == post.id end)

        assert length(post_tags) == 3
      end

      test "tag can be used across multiple posts" do
        site = create_site!()
        tag = create_blog_tag!(name: "Featured", slug: "featured", site_id: site.id)

        # Create multiple posts with the same tag
        post1 = create_blog_post!(title: "Post 1", site_id: site.id)
        post2 = create_blog_post!(title: "Post 2", site_id: site.id)
        post3 = create_blog_post!(title: "Post 3", site_id: site.id)

        create_post_tag!(post_id: post1.id, tag_id: tag.id)
        create_post_tag!(post_id: post2.id, tag_id: tag.id)
        create_post_tag!(post_id: post3.id, tag_id: tag.id)

        # Verify tag is used on 3 posts
        all_assignments = Ash.read!(PostTag, authorize?: false)
        tag_posts = Enum.filter(all_assignments, fn a -> a.tag_id == tag.id end)

        assert length(tag_posts) >= 3
      end
    end

    describe "identities" do
      test "unique_post_tag prevents duplicate assignments" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        tag = create_blog_tag!(site_id: site.id)

        # First assignment
        create_post_tag!(post_id: post.id, tag_id: tag.id)

        # Second assignment should upsert (not error)
        _assignment2 = create_post_tag!(post_id: post.id, tag_id: tag.id)

        # Should only have 1 assignment for this post+tag combination
        all_assignments = Ash.read!(PostTag, authorize?: false)

        matching_assignments =
          Enum.filter(all_assignments, fn a ->
            a.post_id == post.id and a.tag_id == tag.id
          end)

        assert length(matching_assignments) == 1
      end
    end
  end
end
