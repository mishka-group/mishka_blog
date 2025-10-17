defmodule MishkaBlog.Test.PostRatingTest do
  @moduledoc """
  Tests for MishkaBlog.PostRating resource - join table for posts and user ratings.
  """
  use MishkaBlog.DataCase, async: false

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.PostRating
    import Ash.Expr
    require Ash.Query

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(PostRating) == "mishka_blog_post_ratings"
      end

      test "uses UUID primary key with unique identity on user_id and post_id" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        rating = create_post_rating!(post_id: post.id, user_id: user.id, rating: 5)

        # Has UUID primary key
        assert rating.id != nil
        # And foreign keys to post and user
        assert rating.post_id == post.id
        assert rating.user_id == user.id
      end

      test "is a global resource (not multi-tenant)" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(PostRating)
        assert multitenancy_config == nil
        assert Ash.Resource.Info.multitenancy_global?(PostRating) == nil
      end
    end

    describe "create action (upsert)" do
      test "creates rating for user" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        rating = create_post_rating!(post_id: post.id, user_id: user.id, rating: 5)

        assert rating.post_id == post.id
        assert rating.user_id == user.id
        assert rating.rating == 5
        assert rating.inserted_at != nil
        assert rating.updated_at != nil
      end

      test "accepts rating values from 1 to 5" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        for rating_value <- 1..5 do
          user = create_user!()
          rating = create_post_rating!(post_id: post.id, user_id: user.id, rating: rating_value)
          assert rating.rating == rating_value
        end
      end

      test "upsert updates existing rating" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        # First rating
        rating1 = create_post_rating!(post_id: post.id, user_id: user.id, rating: 3)
        assert rating1.rating == 3

        # Update rating (upsert)
        rating2 = create_post_rating!(post_id: post.id, user_id: user.id, rating: 5)

        # Should be same record with updated rating
        assert rating2.post_id == rating1.post_id
        assert rating2.user_id == rating1.user_id
        assert rating2.rating == 5
      end

      test "allows same user to rate different posts" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id)
        post2 = create_blog_post!(site_id: site.id)
        user = create_user!()

        rating1 = create_post_rating!(post_id: post1.id, user_id: user.id, rating: 4)
        rating2 = create_post_rating!(post_id: post2.id, user_id: user.id, rating: 5)

        assert rating1.user_id == rating2.user_id
        assert rating1.post_id != rating2.post_id
        assert rating1.rating == 4
        assert rating2.rating == 5
      end

      test "allows different users to rate same post" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user1 = create_user!()
        user2 = create_user!()

        rating1 = create_post_rating!(post_id: post.id, user_id: user1.id, rating: 3)
        rating2 = create_post_rating!(post_id: post.id, user_id: user2.id, rating: 5)

        assert rating1.post_id == rating2.post_id
        assert rating1.user_id != rating2.user_id
        assert rating1.rating == 3
        assert rating2.rating == 5
      end

      test "sets inserted_at and updated_at timestamps" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        rating = create_post_rating!(post_id: post.id, user_id: user.id, rating: 4)

        assert rating.inserted_at != nil
        assert is_struct(rating.inserted_at, DateTime)
        assert rating.updated_at != nil
        assert is_struct(rating.updated_at, DateTime)
      end
    end

    describe "destroy action" do
      test "removes rating" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        rating = create_post_rating!(post_id: post.id, user_id: user.id, rating: 4)

        rating
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Verify it's removed
        all_ratings = Ash.read!(PostRating, authorize?: false)

        refute Enum.any?(all_ratings, fn r ->
                 r.post_id == post.id and r.user_id == user.id
               end)
      end

      test "does not delete related post when rating is removed" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        rating = create_post_rating!(post_id: post.id, user_id: user.id, rating: 4)

        rating
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        # Post should still exist
        fetched_post = Ash.get!(MishkaBlog.BlogPost, post.id, authorize?: false, tenant: site.id)
        assert fetched_post.id == post.id
      end
    end

    describe "read actions" do
      test "my_ratings finds all ratings for a user" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id, status: :published)
        post2 = create_blog_post!(site_id: site.id, status: :published)
        user = create_user!()

        rating1 = create_post_rating!(post_id: post1.id, user_id: user.id, rating: 3)
        rating2 = create_post_rating!(post_id: post2.id, user_id: user.id, rating: 5)

        result =
          PostRating
          |> Ash.Query.for_read(:my_ratings, %{}, actor: user, authorize?: false)
          |> Ash.read!(authorize?: false)

        rating_post_ids = Enum.map(result.results, & &1.post_id)

        assert rating1.post_id in rating_post_ids
        assert rating2.post_id in rating_post_ids
        assert length(result.results) == 2
      end

      test "by_post finds all ratings for a post" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user1 = create_user!()
        user2 = create_user!()

        rating1 = create_post_rating!(post_id: post.id, user_id: user1.id, rating: 4)
        rating2 = create_post_rating!(post_id: post.id, user_id: user2.id, rating: 5)

        result =
          PostRating
          |> Ash.Query.for_read(:by_post, %{post_id: post.id}, authorize?: false)
          |> Ash.read!(authorize?: false)

        user_ids = Enum.map(result.results, & &1.user_id)

        assert rating1.user_id in user_ids
        assert rating2.user_id in user_ids
        assert length(result.results) == 2
      end

      test "my_ratings with pagination" do
        site = create_site!()
        user = create_user!()

        # Create 5 ratings for published posts
        _posts =
          for _ <- 1..5 do
            post = create_blog_post!(site_id: site.id, status: :published)
            create_post_rating!(post_id: post.id, user_id: user.id, rating: 4)
            post
          end

        result =
          PostRating
          |> Ash.Query.for_read(:my_ratings, %{}, actor: user, authorize?: false)
          |> Ash.Query.page(limit: 3, count: true)
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 3
        assert result.count == 5
      end

      test "my_ratings only shows ratings for published posts" do
        site = create_site!()
        user = create_user!()

        # Create published and draft posts
        published_post = create_blog_post!(site_id: site.id, status: :published)
        draft_post = create_blog_post!(site_id: site.id, status: :draft)

        # Rate both
        create_post_rating!(post_id: published_post.id, user_id: user.id, rating: 5)
        create_post_rating!(post_id: draft_post.id, user_id: user.id, rating: 4)

        result =
          PostRating
          |> Ash.Query.for_read(:my_ratings, %{}, actor: user, authorize?: false)
          |> Ash.read!(authorize?: false)

        # Should only see rating for published post
        assert length(result.results) == 1
        assert hd(result.results).post_id == published_post.id
      end

      test "read action (without filtering) shows all ratings" do
        site = create_site!()
        post1 = create_blog_post!(site_id: site.id)
        post2 = create_blog_post!(site_id: site.id)
        user = create_user!()

        rating1 = create_post_rating!(post_id: post1.id, user_id: user.id, rating: 3)
        rating2 = create_post_rating!(post_id: post2.id, user_id: user.id, rating: 5)

        # Use read action with manual filter
        user_uuid = user.id

        result =
          PostRating
          |> Ash.Query.for_read(:read, %{}, authorize?: false)
          |> Ash.Query.filter(expr(user_id == ^user_uuid))
          |> Ash.read!(authorize?: false)

        rating_post_ids = Enum.map(result, & &1.post_id)

        assert rating1.post_id in rating_post_ids
        assert rating2.post_id in rating_post_ids
        assert length(result) == 2
      end
    end

    describe "database references" do
      test "rating references valid post and user" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        rating = create_post_rating!(post_id: post.id, user_id: user.id, rating: 5)

        # Verify rating has valid foreign keys
        assert rating.post_id == post.id
        assert rating.user_id == user.id

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

        _rating = create_post_rating!(post_id: post.id, user_id: user.id, rating: 4)

        # Load ratings, find our rating, then load the post with tenant
        rating =
          PostRating
          |> Ash.read!(authorize?: false)
          |> Enum.find(fn r -> r.post_id == post.id and r.user_id == user.id end)

        # Load the post relationship - need to reload the rating with the post loaded
        loaded_rating = Ash.load!(rating, [:post], tenant: site.id, authorize?: false)
        assert loaded_rating.post.id == post.id
      end

      test "loads user relationship" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        _rating = create_post_rating!(post_id: post.id, user_id: user.id, rating: 4)

        loaded_rating =
          PostRating
          |> Ash.Query.load(:user)
          |> Ash.read!(authorize?: false)
          |> Enum.find(fn r -> r.post_id == post.id and r.user_id == user.id end)

        assert loaded_rating.user.id == user.id
      end
    end

    describe "rating calculations" do
      test "calculates average rating for a post" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        # Create ratings: 2, 3, 4, 5 (average = 3.5)
        user1 = create_user!()
        user2 = create_user!()
        user3 = create_user!()
        user4 = create_user!()

        create_post_rating!(post_id: post.id, user_id: user1.id, rating: 2)
        create_post_rating!(post_id: post.id, user_id: user2.id, rating: 3)
        create_post_rating!(post_id: post.id, user_id: user3.id, rating: 4)
        create_post_rating!(post_id: post.id, user_id: user4.id, rating: 5)

        ratings =
          PostRating
          |> Ash.Query.for_read(:by_post, %{post_id: post.id}, authorize?: false)
          |> Ash.read!(authorize?: false)

        rating_values = Enum.map(ratings.results, & &1.rating)
        average = Enum.sum(rating_values) / length(rating_values)

        assert average == 3.5
      end
    end

    describe "identities" do
      test "unique_user_post_rating prevents duplicate ratings" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        # First rating
        create_post_rating!(post_id: post.id, user_id: user.id, rating: 3)

        # Second rating should upsert (not error)
        _rating2 = create_post_rating!(post_id: post.id, user_id: user.id, rating: 5)

        # Should only have 1 rating for this user+post combination
        all_ratings = Ash.read!(PostRating, authorize?: false)

        matching_ratings =
          Enum.filter(all_ratings, fn r ->
            r.post_id == post.id and r.user_id == user.id
          end)

        assert length(matching_ratings) == 1
        # Should have the updated rating
        assert List.first(matching_ratings).rating == 5
      end
    end
  end
end
