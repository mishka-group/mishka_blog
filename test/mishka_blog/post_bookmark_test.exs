defmodule MishkaBlog.Test.PostBookmarkTest do
  @moduledoc """
  Tests for MishkaBlog.PostBookmark resource - join table for posts and user bookmarks.
  """
  use MishkaBlog.DataCase, async: false

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.PostBookmark
    import Ash.Expr
    require Ash.Query

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(PostBookmark) == "mishka_blog_post_bookmarks"
      end

      test "uses UUID primary key with unique identity on user_id and post_id" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        bookmark = create_post_bookmark!(post_id: post.id, user_id: user.id)

        # Has UUID primary key
        assert bookmark.id != nil
        # And foreign keys to post and user
        assert bookmark.post_id == post.id
        assert bookmark.user_id == user.id
      end

      test "is a global resource (not multi-tenant)" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(PostBookmark)
        assert multitenancy_config == nil
        assert Ash.Resource.Info.multitenancy_global?(PostBookmark) == nil
      end
    end

    describe "create action (upsert)" do
      test "creates bookmark for user" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        bookmark = create_post_bookmark!(post_id: post.id, user_id: user.id)

        assert bookmark.post_id == post.id
        assert bookmark.user_id == user.id
        assert bookmark.inserted_at != nil
      end

      test "upsert prevents duplicate bookmarks" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        # First bookmark
        bookmark1 = create_post_bookmark!(post_id: post.id, user_id: user.id)

        # Second bookmark (upsert)
        bookmark2 = create_post_bookmark!(post_id: post.id, user_id: user.id)

        # Should be same record
        assert bookmark1.post_id == bookmark2.post_id
        assert bookmark1.user_id == bookmark2.user_id
        assert bookmark1.id == bookmark2.id
      end

      test "allows same user to bookmark different posts" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id)
        post2 = create_blog_post!(site_id: site.id)
        user = create_user!()

        bookmark1 = create_post_bookmark!(post_id: post1.id, user_id: user.id)
        bookmark2 = create_post_bookmark!(post_id: post2.id, user_id: user.id)

        assert bookmark1.user_id == bookmark2.user_id
        assert bookmark1.post_id != bookmark2.post_id
      end

      test "allows different users to bookmark same post" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user1 = create_user!()
        user2 = create_user!()

        bookmark1 = create_post_bookmark!(post_id: post.id, user_id: user1.id)
        bookmark2 = create_post_bookmark!(post_id: post.id, user_id: user2.id)

        assert bookmark1.post_id == bookmark2.post_id
        assert bookmark1.user_id != bookmark2.user_id
      end

      test "sets inserted_at timestamp" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        bookmark = create_post_bookmark!(post_id: post.id, user_id: user.id)

        assert bookmark.inserted_at != nil
        assert is_struct(bookmark.inserted_at, DateTime)
      end
    end

    describe "destroy action" do
      test "removes bookmark" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        bookmark = create_post_bookmark!(post_id: post.id, user_id: user.id)

        bookmark
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Verify it's removed
        all_bookmarks = Ash.read!(PostBookmark, authorize?: false)

        refute Enum.any?(all_bookmarks, fn b ->
                 b.post_id == post.id and b.user_id == user.id
               end)
      end

      test "does not delete related post when bookmark is removed" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        bookmark = create_post_bookmark!(post_id: post.id, user_id: user.id)

        bookmark
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Post should still exist
        fetched_post = Ash.get!(MishkaBlog.BlogPost, post.id, authorize?: false, tenant: site.id)
        assert fetched_post.id == post.id
      end
    end

    describe "read actions" do
      test "my_bookmarks finds all bookmarks for a user" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id, status: :published)
        post2 = create_blog_post!(site_id: site.id, status: :published)
        user = create_user!()

        bookmark1 = create_post_bookmark!(post_id: post1.id, user_id: user.id)
        bookmark2 = create_post_bookmark!(post_id: post2.id, user_id: user.id)

        result =
          PostBookmark
          |> Ash.Query.for_read(:my_bookmarks, %{}, actor: user, authorize?: false)
          |> Ash.read!(authorize?: false)

        bookmark_ids = Enum.map(result.results, & &1.post_id)

        assert bookmark1.post_id in bookmark_ids
        assert bookmark2.post_id in bookmark_ids
        assert length(result.results) == 2
      end

      test "my_bookmarks with pagination" do
        site = create_site!()
        user = create_user!()

        # Create 5 bookmarks for published posts
        _posts =
          for _ <- 1..5 do
            post = create_blog_post!(site_id: site.id, status: :published)
            create_post_bookmark!(post_id: post.id, user_id: user.id)
            post
          end

        result =
          PostBookmark
          |> Ash.Query.for_read(:my_bookmarks, %{}, actor: user, authorize?: false)
          |> Ash.Query.page(limit: 3, count: true)
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 3
        assert result.count == 5
      end

      test "my_bookmarks only shows bookmarks for published posts" do
        site = create_site!()
        user = create_user!()

        # Create published and draft posts
        published_post = create_blog_post!(site_id: site.id, status: :published)
        draft_post = create_blog_post!(site_id: site.id, status: :draft)

        # Bookmark both
        create_post_bookmark!(post_id: published_post.id, user_id: user.id)
        create_post_bookmark!(post_id: draft_post.id, user_id: user.id)

        result =
          PostBookmark
          |> Ash.Query.for_read(:my_bookmarks, %{}, actor: user, authorize?: false)
          |> Ash.read!(authorize?: false)

        # Should only see bookmark for published post
        assert length(result.results) == 1
        assert hd(result.results).post_id == published_post.id
      end

      test "read action (without filtering) shows all bookmarks" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id)
        post2 = create_blog_post!(site_id: site.id)
        user = create_user!()

        bookmark1 = create_post_bookmark!(post_id: post1.id, user_id: user.id)
        bookmark2 = create_post_bookmark!(post_id: post2.id, user_id: user.id)

        # Use read action with manual filter
        user_uuid = user.id

        result =
          PostBookmark
          |> Ash.Query.for_read(:read, %{}, authorize?: false)
          |> Ash.Query.filter(expr(user_id == ^user_uuid))
          |> Ash.read!(authorize?: false)

        bookmark_ids = Enum.map(result, & &1.post_id)

        assert bookmark1.post_id in bookmark_ids
        assert bookmark2.post_id in bookmark_ids
        assert length(result) == 2
      end
    end

    describe "database references" do
      test "bookmark references valid post and user" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        bookmark = create_post_bookmark!(post_id: post.id, user_id: user.id)

        # Verify bookmark has valid foreign keys
        assert bookmark.post_id == post.id
        assert bookmark.user_id == user.id

        # Note: BlogPost uses soft deletion (archival), so cascade deletes
        # only trigger on permanent_destroy, not regular destroy (soft delete)
      end
    end

    describe "relationships" do
      test "loads post relationship" do
        site = create_site!()
        # Create published post so it can be loaded with read_action :public_list
        post = create_blog_post!(site_id: site.id, status: :published)
        user = create_user!()

        _bookmark = create_post_bookmark!(post_id: post.id, user_id: user.id)

        # Load bookmarks, find our bookmark, then load the post with tenant
        bookmark =
          PostBookmark
          |> Ash.read!(authorize?: false)
          |> Enum.find(fn b -> b.post_id == post.id and b.user_id == user.id end)

        # Load the post relationship - need to reload the bookmark with the post loaded
        loaded_bookmark = Ash.load!(bookmark, [:post], tenant: site.id, authorize?: false)
        assert loaded_bookmark.post.id == post.id
      end

      test "loads user relationship" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        _bookmark = create_post_bookmark!(post_id: post.id, user_id: user.id)

        loaded_bookmark =
          PostBookmark
          |> Ash.Query.load(:user)
          |> Ash.read!(authorize?: false)
          |> Enum.find(fn b -> b.post_id == post.id and b.user_id == user.id end)

        assert loaded_bookmark.user.id == user.id
      end
    end

    describe "identities" do
      test "unique_user_post_bookmark prevents duplicate bookmarks" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        # First bookmark
        create_post_bookmark!(post_id: post.id, user_id: user.id)

        # Second bookmark should upsert (not error)
        _bookmark2 = create_post_bookmark!(post_id: post.id, user_id: user.id)

        # Should only have 1 bookmark for this user+post combination
        all_bookmarks = Ash.read!(PostBookmark, authorize?: false)

        matching_bookmarks =
          Enum.filter(all_bookmarks, fn b ->
            b.post_id == post.id and b.user_id == user.id
          end)

        assert length(matching_bookmarks) == 1
      end
    end
  end
end
