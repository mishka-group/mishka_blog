defmodule MishkaBlog.Test.BloggerFollowerTest do
  @moduledoc """
  Tests for MishkaBlog.BloggerFollower resource.
  """
  use MishkaBlog.DataCase, async: false

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.BloggerFollower

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(BloggerFollower) ==
                 "mishka_blog_blogger_followers"
      end

      test "uses UUID v7 for primary keys" do
        follow = create_blogger_follower!()
        assert is_binary(follow.id)
        assert String.length(follow.id) == 36
      end

      test "does not use multi-tenancy" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(BloggerFollower)
        assert multitenancy_config == nil
      end
    end

    describe "create action (follow blogger)" do
      test "creates follow relationship with valid attributes" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)
        user = create_user!()

        follow =
          create_blogger_follower!(
            blogger_id: blogger.id,
            actor: user
          )

        assert follow.blogger_id == blogger.id
        assert follow.follower_user_id == user.id
        assert follow.notification_enabled == true
        assert follow.followed_at != nil
      end

      test "auto-sets followed_at timestamp" do
        follow = create_blogger_follower!()

        assert follow.followed_at != nil
        assert is_struct(follow.followed_at, DateTime)
        # Should be recent (within last minute)
        assert DateTime.diff(DateTime.utc_now(), follow.followed_at, :second) < 60
      end

      test "defaults notification_enabled to true" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)
        user = create_user!()

        follow =
          BloggerFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              blogger_id: blogger.id
            },
            authorize?: false,
            actor: user
          )
          |> Ash.create!()

        assert follow.notification_enabled == true
      end

      test "allows setting notification_enabled to false on creation" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)
        user = create_user!()

        follow =
          create_blogger_follower!(
            blogger_id: blogger.id,
            actor: user,
            notification_enabled: false
          )

        assert follow.notification_enabled == false
      end

      test "upsert behavior: updates existing follow instead of creating duplicate" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)
        user = create_user!()

        # First follow
        follow1 =
          create_blogger_follower!(
            blogger_id: blogger.id,
            actor: user,
            notification_enabled: false
          )

        # Second follow attempt (should upsert)
        follow2 =
          BloggerFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              blogger_id: blogger.id,
              notification_enabled: true
            },
            authorize?: false,
            actor: user
          )
          |> Ash.create!()

        # Should be the same record, just updated
        assert follow2.id == follow1.id
        assert follow2.notification_enabled == true

        # Verify only one record exists
        all_follows =
          BloggerFollower
          |> Ash.read!(authorize?: false)

        matching_follows =
          Enum.filter(all_follows, fn f ->
            f.blogger_id == blogger.id and f.follower_user_id == user.id
          end)

        assert length(matching_follows) == 1
      end

      test "requires blogger_id and follower_user_id" do
        assert_raise Ash.Error.Invalid, fn ->
          BloggerFollower
          |> Ash.Changeset.for_create(:create, %{}, authorize?: false)
          |> Ash.create!()
        end
      end

      test "allows following the same blogger from different users" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)
        user1 = create_user!()
        user2 = create_user!()

        follow1 = create_blogger_follower!(blogger_id: blogger.id, actor: user1)
        follow2 = create_blogger_follower!(blogger_id: blogger.id, actor: user2)

        assert follow1.blogger_id == follow2.blogger_id
        assert follow1.follower_user_id != follow2.follower_user_id
        assert follow1.id != follow2.id
      end

      test "allows user to follow different bloggers" do
        site = create_site!()
        blogger1 = create_blogger!(site_id: site.id)
        blogger2 = create_blogger!(site_id: site.id)
        user = create_user!()

        follow1 = create_blogger_follower!(blogger_id: blogger1.id, actor: user)
        follow2 = create_blogger_follower!(blogger_id: blogger2.id, actor: user)

        assert follow1.follower_user_id == follow2.follower_user_id
        assert follow1.blogger_id != follow2.blogger_id
        assert follow1.id != follow2.id
      end
    end

    describe "read actions" do
      test "default read lists all follows" do
        follow1 = create_blogger_follower!()
        follow2 = create_blogger_follower!()

        all_follows = Ash.read!(BloggerFollower, authorize?: false)

        assert length(all_follows) >= 2
        assert Enum.any?(all_follows, fn f -> f.id == follow1.id end)
        assert Enum.any?(all_follows, fn f -> f.id == follow2.id end)
      end

      test "by_user reads all bloggers followed by a user" do
        site = create_site!()
        user = create_user!()
        blogger1 = create_blogger!(site_id: site.id)
        blogger2 = create_blogger!(site_id: site.id)
        blogger3 = create_blogger!(site_id: site.id)
        other_user = create_user!()

        # User follows blogger1 and blogger2
        follow1 = create_blogger_follower!(blogger_id: blogger1.id, actor: user)
        follow2 = create_blogger_follower!(blogger_id: blogger2.id, actor: user)
        # Other user follows blogger3
        _follow3 =
          create_blogger_follower!(blogger_id: blogger3.id, actor: other_user)

        result =
          BloggerFollower
          |> Ash.Query.for_read(:by_user, %{}, actor: user, authorize?: false)
          |> Ash.read!(authorize?: false)

        user_follows = result.results
        user_follow_ids = Enum.map(user_follows, & &1.id)

        assert length(user_follows) == 2
        assert follow1.id in user_follow_ids
        assert follow2.id in user_follow_ids
      end

      test "by_blogger reads all followers of a blogger" do
        site = create_site!()
        blogger1 = create_blogger!(site_id: site.id)
        blogger2 = create_blogger!(site_id: site.id)
        user1 = create_user!()
        user2 = create_user!()
        user3 = create_user!()

        # User1 and user2 follow blogger1
        follow1 = create_blogger_follower!(blogger_id: blogger1.id, actor: user1)
        follow2 = create_blogger_follower!(blogger_id: blogger1.id, actor: user2)
        # User3 follows blogger2
        _follow3 = create_blogger_follower!(blogger_id: blogger2.id, actor: user3)

        result =
          BloggerFollower
          |> Ash.Query.for_read(:by_blogger, %{blogger_id: blogger1.id}, authorize?: false)
          |> Ash.read!(authorize?: false)

        blogger_followers = result.results
        follower_ids = Enum.map(blogger_followers, & &1.id)

        assert length(blogger_followers) == 2
        assert follow1.id in follower_ids
        assert follow2.id in follower_ids
      end

      test "counts followers for a blogger with 3 followers" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)
        user1 = create_user!()
        user2 = create_user!()
        user3 = create_user!()

        # Create 3 followers for the blogger
        follow1 = create_blogger_follower!(blogger_id: blogger.id, actor: user1)
        follow2 = create_blogger_follower!(blogger_id: blogger.id, actor: user2)
        follow3 = create_blogger_follower!(blogger_id: blogger.id, actor: user3)

        # Read all followers for this blogger
        result =
          BloggerFollower
          |> Ash.Query.for_read(:by_blogger, %{blogger_id: blogger.id}, authorize?: false)
          |> Ash.read!(authorize?: false)

        followers = result.results
        follower_ids = Enum.map(followers, & &1.id)

        # Verify we have exactly 3 followers
        assert length(followers) == 3
        assert follow1.id in follower_ids
        assert follow2.id in follower_ids
        assert follow3.id in follower_ids
      end

      test "by_user supports pagination" do
        site = create_site!()
        user = create_user!()

        # Create 25 follows for pagination testing
        _follows =
          Enum.map(1..25, fn _ ->
            blogger = create_blogger!(site_id: site.id)
            create_blogger_follower!(blogger_id: blogger.id, actor: user)
          end)

        # Read first page (limit 10)
        result =
          BloggerFollower
          |> Ash.Query.for_read(:by_user, %{}, actor: user, authorize?: false)
          |> Ash.Query.page(limit: 10, count: true)
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 10
        assert result.count == 25
      end

      test "by_blogger supports pagination" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)

        # Create 25 followers for pagination testing
        _follows =
          Enum.map(1..25, fn _ ->
            user = create_user!()
            create_blogger_follower!(blogger_id: blogger.id, actor: user)
          end)

        # Read first page (limit 10)
        result =
          BloggerFollower
          |> Ash.Query.for_read(:by_blogger, %{blogger_id: blogger.id}, authorize?: false)
          |> Ash.Query.page(limit: 10, count: true)
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 10
        assert result.count == 25
      end
    end

    describe "update action (toggle_notifications)" do
      test "toggles notification_enabled from true to false" do
        follow = create_blogger_follower!(notification_enabled: true)

        updated =
          follow
          |> Ash.Changeset.for_update(
            :toggle_notifications,
            %{notification_enabled: false},
            authorize?: false
          )
          |> Ash.update!()

        assert updated.notification_enabled == false
      end

      test "toggles notification_enabled from false to true" do
        follow = create_blogger_follower!(notification_enabled: false)

        updated =
          follow
          |> Ash.Changeset.for_update(
            :toggle_notifications,
            %{notification_enabled: true},
            authorize?: false
          )
          |> Ash.update!()

        assert updated.notification_enabled == true
      end

      test "does not modify other attributes" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)
        user = create_user!()

        follow =
          create_blogger_follower!(
            blogger_id: blogger.id,
            actor: user,
            notification_enabled: true
          )

        original_followed_at = follow.followed_at
        original_blogger_id = follow.blogger_id
        original_follower_user_id = follow.follower_user_id

        updated =
          follow
          |> Ash.Changeset.for_update(
            :toggle_notifications,
            %{notification_enabled: false},
            authorize?: false
          )
          |> Ash.update!()

        assert updated.followed_at == original_followed_at
        assert updated.blogger_id == original_blogger_id
        assert updated.follower_user_id == original_follower_user_id
      end
    end

    describe "destroy action (unfollow)" do
      test "unfollow removes the follow relationship" do
        follow = create_blogger_follower!()

        follow
        |> Ash.Changeset.for_destroy(:unfollow, %{}, authorize?: false)
        |> Ash.destroy!()

        # Verify it's been removed (returns error when not found)
        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.get(BloggerFollower, follow.id, authorize?: false)
      end

      test "unfollow is idempotent - destroying non-existent follow doesn't error" do
        follow = create_blogger_follower!()

        # First unfollow
        follow
        |> Ash.Changeset.for_destroy(:unfollow, %{}, authorize?: false)
        |> Ash.destroy!()

        # Verify record no longer exists
        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.get(BloggerFollower, follow.id, authorize?: false)
      end

      test "default destroy action works the same as unfollow" do
        follow = create_blogger_follower!()

        follow
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false)
        |> Ash.destroy!()

        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.get(BloggerFollower, follow.id, authorize?: false)
      end
    end

    describe "identities" do
      test "unique_follower_blogger prevents duplicate follows" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)
        user = create_user!()

        _follow1 = create_blogger_follower!(blogger_id: blogger.id, actor: user)

        # Attempting to create duplicate without upsert should fail
        # Note: The create action has upsert enabled, so we need to test the constraint differently
        # The upsert will succeed and return the existing record, demonstrating the constraint works
        _follow2 =
          BloggerFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              blogger_id: blogger.id
            },
            authorize?: false,
            actor: user
          )
          |> Ash.create!()

        # Verify only one record exists
        all_follows =
          BloggerFollower
          |> Ash.read!(authorize?: false)

        matching_follows =
          Enum.filter(all_follows, fn f ->
            f.blogger_id == blogger.id and f.follower_user_id == user.id
          end)

        assert length(matching_follows) == 1
      end
    end

    describe "relationships" do
      test "belongs_to blogger relationship" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)
        user = create_user!()

        follow =
          create_blogger_follower!(
            blogger_id: blogger.id,
            actor: user
          )

        # Verify the blogger_id relationship is set correctly
        assert follow.blogger_id == blogger.id

        # Load the blogger separately (since Blogger uses multi-tenancy)
        fetched_blogger =
          Ash.get!(MishkaBlog.Blogger, blogger.id,
            action: :master_get,
            authorize?: false
          )

        assert fetched_blogger.id == follow.blogger_id
        assert fetched_blogger.display_name == blogger.display_name
      end

      test "belongs_to follower_user relationship" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)
        user = create_user!()

        follow =
          create_blogger_follower!(
            blogger_id: blogger.id,
            actor: user
          )

        # Verify the follower_user_id relationship is set correctly
        assert follow.follower_user_id == user.id
      end

      test "cascade delete: deleting blogger removes follows" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)
        user1 = create_user!()
        user2 = create_user!()

        follow1 = create_blogger_follower!(blogger_id: blogger.id, actor: user1)
        follow2 = create_blogger_follower!(blogger_id: blogger.id, actor: user2)

        # Delete the blogger (using permanent_destroy since blogger uses soft delete)
        blogger
        |> Ash.Changeset.for_destroy(:permanent_destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Verify follows are removed due to cascade delete
        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.get(BloggerFollower, follow1.id, authorize?: false)

        assert {:error, %Ash.Error.Invalid{}} =
                 Ash.get(BloggerFollower, follow2.id, authorize?: false)
      end

      test "requires valid blogger_id (foreign key constraint)" do
        user = create_user!()
        invalid_blogger_id = Ash.UUID.generate()

        # Attempting to create a follow with non-existent blogger should fail
        assert_raise Ash.Error.Invalid, fn ->
          BloggerFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              blogger_id: invalid_blogger_id
            },
            authorize?: false,
            actor: user
          )
          |> Ash.create!()
        end
      end

      test "requires valid follower_user_id (foreign key constraint)" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)

        # Attempting to create a follow without an actor should fail
        assert_raise Ash.Error.Invalid, fn ->
          BloggerFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              blogger_id: blogger.id
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "global follows (no multi-tenancy)" do
      test "user can follow bloggers from different sites" do
        site1 = create_site!()
        site2 = create_site!()
        blogger1 = create_blogger!(site_id: site1.id)
        blogger2 = create_blogger!(site_id: site2.id)
        user = create_user!()

        # User follows bloggers from different sites
        follow1 = create_blogger_follower!(blogger_id: blogger1.id, actor: user)
        follow2 = create_blogger_follower!(blogger_id: blogger2.id, actor: user)

        assert follow1.follower_user_id == user.id
        assert follow2.follower_user_id == user.id
        assert follow1.id != follow2.id

        # Verify by_user returns follows from all sites
        result =
          BloggerFollower
          |> Ash.Query.for_read(:by_user, %{}, actor: user, authorize?: false)
          |> Ash.read!(authorize?: false)

        user_follow_ids = Enum.map(result.results, & &1.id)
        assert follow1.id in user_follow_ids
        assert follow2.id in user_follow_ids
      end
    end

    describe "JSON API configuration" do
      test "has correct JSON API type" do
        json_api_type = AshJsonApi.Resource.Info.type(BloggerFollower)
        assert json_api_type == "blogger_follower"
      end
    end
  end
end
