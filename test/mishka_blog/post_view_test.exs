# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.PostViewTest do
  @moduledoc """
  Tests for MishkaBlog.PostView resource - tracks unique post views using upsert.
  """
  use MishkaBlog.DataCase, async: false

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.PostView

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(PostView) == "mishka_blog_post_views"
      end

      test "uses UUID primary key" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        view = create_post_view!(post_id: post.id, user_id: user.id)

        assert is_binary(view.id)
        assert String.length(view.id) == 36
      end

      test "is a global resource (not multi-tenant)" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(PostView)
        assert multitenancy_config == nil
        assert Ash.Resource.Info.multitenancy_global?(PostView) == nil
      end
    end

    describe "create action (upsert)" do
      test "creates view for authenticated user" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        view =
          create_post_view!(
            post_id: post.id,
            user_id: user.id,
            ip_address: "192.168.1.100",
            user_agent: "Mozilla/5.0"
          )

        assert view.post_id == post.id
        assert view.user_id == user.id
        assert view.ip_address == "192.168.1.100"
        assert view.user_agent == "Mozilla/5.0"
        assert view.inserted_at != nil
      end

      test "creates view for guest user (null user_id)" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        view =
          PostView
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              user_id: nil,
              ip_address: "192.168.1.100",
              user_agent: "Mozilla/5.0"
            },
            authorize?: false
          )
          |> Ash.create!()

        assert view.post_id == post.id
        assert view.user_id == nil
        assert view.ip_address == "192.168.1.100"
        assert view.inserted_at != nil
      end

      test "upsert prevents duplicate authenticated user views" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        # First view
        view1 =
          PostView
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              user_id: user.id,
              ip_address: "192.168.1.100",
              user_agent: "Mozilla/5.0"
            },
            authorize?: false
          )
          |> Ash.create!()

        # Second view from same user with same IP (upsert - should not create duplicate)
        view2 =
          PostView
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              user_id: user.id,
              ip_address: "192.168.1.100",
              user_agent: "Mozilla/5.0"
            },
            authorize?: false
          )
          |> Ash.create!()

        # Should be same record (upserted)
        assert view1.id == view2.id
        assert view1.post_id == view2.post_id
        assert view1.user_id == view2.user_id
      end

      test "upsert prevents duplicate guest views from same IP" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        # First guest view
        view1 =
          PostView
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              user_id: nil,
              ip_address: "192.168.1.100",
              user_agent: "Mozilla/5.0"
            },
            authorize?: false
          )
          |> Ash.create!()

        # Second view from same IP (should upsert)
        view2 =
          PostView
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              user_id: nil,
              ip_address: "192.168.1.100",
              user_agent: "Chrome/91.0"
            },
            authorize?: false
          )
          |> Ash.create!()

        # Should be same record (upserted)
        assert view1.id == view2.id
      end

      test "allows different users to view same post" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user1 = create_user!()
        user2 = create_user!()

        view1 = create_post_view!(post_id: post.id, user_id: user1.id)
        view2 = create_post_view!(post_id: post.id, user_id: user2.id)

        assert view1.post_id == view2.post_id
        assert view1.user_id != view2.user_id
        assert view1.id != view2.id
      end

      test "allows different guest IPs to view same post" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        view1 =
          PostView
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              user_id: nil,
              ip_address: "192.168.1.100",
              user_agent: "Mozilla/5.0"
            },
            authorize?: false
          )
          |> Ash.create!()

        view2 =
          PostView
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              user_id: nil,
              ip_address: "192.168.1.101",
              user_agent: "Chrome/91.0"
            },
            authorize?: false
          )
          |> Ash.create!()

        assert view1.post_id == view2.post_id
        assert view1.ip_address != view2.ip_address
        assert view1.id != view2.id
      end

      test "tracks referer URL" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        view =
          PostView
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              user_id: user.id,
              ip_address: "192.168.1.100",
              user_agent: "Mozilla/5.0",
              referer: "https://google.com/search?q=elixir"
            },
            authorize?: false
          )
          |> Ash.create!()

        assert view.referer == "https://google.com/search?q=elixir"
      end

      test "sets inserted_at timestamp automatically" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        view = create_post_view!(post_id: post.id, user_id: user.id)

        assert view.inserted_at != nil
        assert is_struct(view.inserted_at, DateTime)
      end

      test "requires ip_address for all views" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        # ip_address is required
        assert_raise Ash.Error.Invalid, fn ->
          PostView
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              user_id: user.id,
              user_agent: "Mozilla/5.0"
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "read actions" do
      test "lists all views" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user1 = create_user!()
        user2 = create_user!()

        create_post_view!(post_id: post.id, user_id: user1.id)
        create_post_view!(post_id: post.id, user_id: user2.id)

        views = Ash.read!(PostView, authorize?: false)

        assert length(views) >= 2
      end
    end

    describe "database references" do
      test "view references valid post and user" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        view = create_post_view!(post_id: post.id, user_id: user.id)

        # Verify view has valid foreign keys
        assert view.post_id == post.id
        assert view.user_id == user.id

        # Note: BlogPost uses soft deletion (archival), but PostView has
        # on_delete: :delete configured, so views are deleted when post is soft-deleted
      end
    end

    describe "relationships" do
      test "loads post relationship" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        _view = create_post_view!(post_id: post.id, user_id: user.id)

        # Load views, find ours, then load the post with tenant
        view =
          PostView
          |> Ash.read!(authorize?: false)
          |> Enum.find(fn v -> v.post_id == post.id and v.user_id == user.id end)

        # Load the post relationship
        loaded_view = Ash.load!(view, [:post], tenant: site.id, authorize?: false)
        assert loaded_view.post.id == post.id
      end

      test "loads user relationship" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        _view = create_post_view!(post_id: post.id, user_id: user.id)

        loaded_view =
          PostView
          |> Ash.Query.load(:user)
          |> Ash.read!(authorize?: false)
          |> Enum.find(fn v -> v.post_id == post.id and v.user_id == user.id end)

        assert loaded_view.user.id == user.id
      end
    end

    describe "identities" do
      test "unique_user_view prevents duplicate authenticated user views" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)
        user = create_user!()

        # Create first view
        PostView
        |> Ash.Changeset.for_create(
          :create,
          %{
            post_id: post.id,
            user_id: user.id,
            ip_address: "192.168.1.100"
          },
          authorize?: false
        )
        |> Ash.create!()

        # Try to create duplicate - should upsert instead
        PostView
        |> Ash.Changeset.for_create(
          :create,
          %{
            post_id: post.id,
            user_id: user.id,
            ip_address: "192.168.1.100"
          },
          authorize?: false
        )
        |> Ash.create!()

        # Should only have 1 view for this user+post combination
        views = Ash.read!(PostView, authorize?: false)

        matching_views =
          Enum.filter(views, fn v ->
            v.post_id == post.id and v.user_id == user.id
          end)

        assert length(matching_views) == 1
      end

      test "unique_guest_view prevents duplicate guest IP views" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        # Create first guest view
        PostView
        |> Ash.Changeset.for_create(
          :create,
          %{
            post_id: post.id,
            user_id: nil,
            ip_address: "192.168.1.100"
          },
          authorize?: false
        )
        |> Ash.create!()

        # Try to create duplicate from same IP - should upsert
        PostView
        |> Ash.Changeset.for_create(
          :create,
          %{
            post_id: post.id,
            user_id: nil,
            ip_address: "192.168.1.100"
          },
          authorize?: false
        )
        |> Ash.create!()

        # Should only have 1 view for this IP+post combination
        views = Ash.read!(PostView, authorize?: false)

        matching_views =
          Enum.filter(views, fn v ->
            v.post_id == post.id and v.ip_address == "192.168.1.100" and is_nil(v.user_id)
          end)

        assert length(matching_views) == 1
      end
    end

    describe "view counting" do
      test "counts unique views for a post" do
        site = create_site!()
        post = create_blog_post!(site_id: site.id)

        # Create mix of authenticated and guest views
        user1 = create_user!()
        user2 = create_user!()

        create_post_view!(post_id: post.id, user_id: user1.id)
        create_post_view!(post_id: post.id, user_id: user2.id)

        PostView
        |> Ash.Changeset.for_create(
          :create,
          %{
            post_id: post.id,
            user_id: nil,
            ip_address: "192.168.1.100"
          },
          authorize?: false
        )
        |> Ash.create!()

        # Count views for this post
        views = Ash.read!(PostView, authorize?: false)
        post_views = Enum.filter(views, fn v -> v.post_id == post.id end)
        total_views = length(post_views)

        assert total_views == 3
      end
    end
  end
end
