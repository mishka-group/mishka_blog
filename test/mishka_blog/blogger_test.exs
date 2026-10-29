# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.BloggerTest do
  @moduledoc """
  Tests for MishkaBlog.Blogger resource.
  """
  use MishkaBlog.DataCase, async: false
  import MishkaCmsCore.Test.VersionHelpers

  if Code.ensure_loaded?(MishkaBlog) do
    require Ash.Query
    alias MishkaBlog.Blogger

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(Blogger) == "mishka_blog_bloggers"
      end

      test "uses UUID v7 for primary keys" do
        blogger = create_blogger!()
        assert {:ok, _} = Ecto.UUID.cast(blogger.id)
        assert String.length(blogger.id) == 36
      end

      test "is always site-specific (not global)" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(Blogger)
        assert multitenancy_config == :attribute
        assert Ash.Resource.Info.multitenancy_global?(Blogger) == false
      end
    end

    describe "create action" do
      test "creates blogger with valid attributes" do
        site = create_site!()
        user = create_user!()

        blogger =
          create_blogger!(
            user_id: user.id,
            display_name: "John Doe",
            slug: "john-doe",
            bio: "A passionate blogger",
            site_id: site.id
          )

        assert blogger.user_id == user.id
        assert blogger.display_name == "John Doe"
        assert blogger.slug == "john-doe"
        assert blogger.bio == "A passionate blogger"
        assert blogger.site_id == site.id
      end

      test "auto-generates slug from slug input" do
        site = create_site!()
        user = create_user!()

        blogger =
          create_blogger!(
            user_id: user.id,
            display_name: "Jane Smith",
            slug: "Jane Smith Blog",
            site_id: site.id
          )

        assert blogger.slug == "jane-smith-blog"
      end

      test "requires user_id, display_name, and slug" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          Blogger
          |> Ash.Changeset.for_create(:create, %{}, tenant: site.id, authorize?: false)
          |> Ash.create!()
        end
      end

      test "auto-assigns site_id from tenant context" do
        site = create_site!()
        user = create_user!()

        blogger =
          Blogger
          |> Ash.Changeset.for_create(
            :create,
            %{
              user_id: user.id,
              display_name: "Tenant Blogger",
              slug: "tenant-blogger"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert blogger.site_id == site.id
      end

      test "defaults can_publish_directly to false" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)
        assert blogger.can_publish_directly == false
      end

      test "accepts optional fields" do
        site = create_site!()
        user = create_user!()

        blogger =
          create_blogger!(
            user_id: user.id,
            display_name: "Full Profile",
            slug: "full-profile",
            bio: "My bio",
            avatar_url: "https://example.com/avatar.jpg",
            cover_image_url: "https://example.com/cover.jpg",
            expertise_areas: ["Tech", "Design"],
            social_links: [%{"platform" => "twitter", "url" => "https://twitter.com/user"}],
            contact_email: "contact@example.com",
            can_publish_directly: true,
            site_id: site.id
          )

        assert blogger.bio == "My bio"
        assert blogger.avatar_url == "https://example.com/avatar.jpg"
        assert blogger.cover_image_url == "https://example.com/cover.jpg"
        assert blogger.expertise_areas == ["Tech", "Design"]
        assert blogger.contact_email == "contact@example.com"
        assert blogger.can_publish_directly == true
      end
    end

    describe "master_create action" do
      test "creates blogger with explicit site_id" do
        site = create_site!()
        user = create_user!()

        blogger =
          Blogger
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              user_id: user.id,
              display_name: "Master Blogger",
              slug: "master-blogger",
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!()

        assert blogger.display_name == "Master Blogger"
        assert blogger.site_id == site.id
      end

      test "requires explicit site_id" do
        user = create_user!()

        assert_raise Ash.Error.Invalid, fn ->
          Blogger
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              user_id: user.id,
              display_name: "Missing Site",
              slug: "missing-site"
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "update action" do
      test "updates blogger attributes" do
        site = create_site!()
        blogger = create_blogger!(display_name: "Original Name", site_id: site.id)

        updated =
          blogger
          |> Ash.Changeset.for_update(
            :update,
            %{display_name: "Updated Name", bio: "New bio"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated.display_name == "Updated Name"
        assert updated.bio == "New bio"
      end

      test "prevents updating archived blogger" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)

        # Archive the blogger
        archived =
          blogger
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Try to update archived blogger
        assert_raise Ash.Error.Invalid, fn ->
          archived
          |> Ash.Changeset.for_update(
            :update,
            %{display_name: "Should Fail"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end

      test "prevents site_id changes" do
        site1 = create_site!()
        blogger = create_blogger!(site_id: site1.id)

        # site_id is not in the accepted fields for update
        updated =
          blogger
          |> Ash.Changeset.for_update(
            :update,
            %{display_name: "Updated"},
            tenant: site1.id,
            authorize?: false
          )
          |> Ash.update!()

        # site_id should remain unchanged
        assert updated.site_id == site1.id
      end
    end

    describe "read actions" do
      test "by_user finds blogger by user_id" do
        site = create_site!()
        user = create_user!()
        blogger = create_blogger!(user_id: user.id, site_id: site.id)

        found =
          Blogger
          |> Ash.Query.for_read(:by_user, %{user_id: user.id}, tenant: site.id, authorize?: false)
          |> Ash.read_one!()

        assert found.id == blogger.id
      end

      test "by_slug finds blogger by slug" do
        site = create_site!()
        blogger = create_blogger!(slug: "unique-slug", site_id: site.id)

        found =
          Blogger
          |> Ash.Query.for_read(:by_slug, %{slug: "unique-slug"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read_one!()

        assert found.id == blogger.id
      end

      test "master_get retrieves blogger by ID bypassing tenant" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)

        fetched = Ash.get!(Blogger, blogger.id, action: :master_get, authorize?: false)

        assert fetched.id == blogger.id
      end
    end

    describe "archive/unarchive actions" do
      test "destroy soft deletes blogger" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)

        archived =
          blogger
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        assert %DateTime{} = archived.archived_at

        # Should not appear in normal reads
        bloggers =
          Blogger
          |> Ash.Query.set_tenant(site.id)
          |> Ash.read!(authorize?: false)

        assert Enum.find(bloggers, fn b -> b.id == blogger.id end) == nil
      end

      test "unarchive restores archived blogger" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)

        # Archive
        archived =
          blogger
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Unarchive
        unarchived =
          archived
          |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert unarchived.archived_at == nil
      end

      test "archived action lists only archived bloggers" do
        site = create_site!()
        active_blogger = create_blogger!(display_name: "Active", site_id: site.id)

        archived_blogger =
          create_blogger!(display_name: "To Archive", site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        result =
          Blogger
          |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        archived_list = result.results
        archived_ids = Enum.map(archived_list, & &1.id)
        assert archived_blogger.id in archived_ids
        refute active_blogger.id in archived_ids
      end
    end

    describe "identities" do
      test "unique_slug_per_site prevents duplicate slugs within a site" do
        site = create_site!()
        _blogger1 = create_blogger!(slug: "unique-slug", site_id: site.id)

        # The unique constraint error comes from database level as Ash.Error.Invalid
        assert_raise Ash.Error.Invalid, fn ->
          create_blogger!(slug: "unique-slug", site_id: site.id)
        end
      end

      test "allows same slug across different sites" do
        site1 = create_site!()
        site2 = create_site!()

        blogger1 = create_blogger!(slug: "same-slug", site_id: site1.id)
        blogger2 = create_blogger!(slug: "same-slug", site_id: site2.id)

        assert blogger1.slug == blogger2.slug
        assert blogger1.site_id != blogger2.site_id
      end

      test "unique_user_per_site prevents duplicate users within a site" do
        site = create_site!()
        user = create_user!()
        _blogger1 = create_blogger!(user_id: user.id, site_id: site.id)

        # Identity validation happens at Ash level, returns Ash.Error.Invalid
        assert_raise Ash.Error.Invalid, fn ->
          create_blogger!(user_id: user.id, site_id: site.id)
        end
      end

      test "allows same user across different sites" do
        site1 = create_site!()
        site2 = create_site!()
        user = create_user!()

        blogger1 = create_blogger!(user_id: user.id, site_id: site1.id)
        blogger2 = create_blogger!(user_id: user.id, site_id: site2.id)

        assert blogger1.user_id == blogger2.user_id
        assert blogger1.site_id != blogger2.site_id
      end
    end

    describe "calculations" do
      test "follower_count returns the number of followers" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)

        # Create 3 followers for this blogger
        user1 = create_user!()
        user2 = create_user!()
        user3 = create_user!()

        create_blogger_follower!(blogger_id: blogger.id, follower_user_id: user1.id)
        create_blogger_follower!(blogger_id: blogger.id, follower_user_id: user2.id)
        create_blogger_follower!(blogger_id: blogger.id, follower_user_id: user3.id)

        # Load the follower_count calculation (no tenant needed for calculation!)
        blogger_with_count =
          Ash.get!(Blogger, blogger.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:follower_count, authorize?: false)

        assert blogger_with_count.follower_count == 3
      end

      test "follower_count returns 0 when blogger has no followers" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)

        # Load the follower_count calculation (no tenant needed for calculation!)
        blogger_with_count =
          Ash.get!(Blogger, blogger.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:follower_count, authorize?: false)

        assert blogger_with_count.follower_count == 0
      end

      test "follower_count updates when followers are added or removed" do
        site = create_site!()
        blogger = create_blogger!(site_id: site.id)
        user1 = create_user!()
        user2 = create_user!()

        # Initially 0 followers
        blogger_with_count =
          Ash.get!(Blogger, blogger.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:follower_count, authorize?: false)

        assert blogger_with_count.follower_count == 0

        # Add first follower
        follow1 = create_blogger_follower!(blogger_id: blogger.id, follower_user_id: user1.id)

        blogger_with_count =
          Ash.get!(Blogger, blogger.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:follower_count, authorize?: false)

        assert blogger_with_count.follower_count == 1

        # Add second follower
        follow2 = create_blogger_follower!(blogger_id: blogger.id, follower_user_id: user2.id)

        blogger_with_count =
          Ash.get!(Blogger, blogger.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:follower_count, authorize?: false)

        assert blogger_with_count.follower_count == 2

        # Remove first follower
        follow1
        |> Ash.Changeset.for_destroy(:unfollow, %{}, authorize?: false)
        |> Ash.destroy!()

        blogger_with_count =
          Ash.get!(Blogger, blogger.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:follower_count, authorize?: false)

        assert blogger_with_count.follower_count == 1

        # Remove second follower
        follow2
        |> Ash.Changeset.for_destroy(:unfollow, %{}, authorize?: false)
        |> Ash.destroy!()

        blogger_with_count =
          Ash.get!(Blogger, blogger.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:follower_count, authorize?: false)

        assert blogger_with_count.follower_count == 0
      end
    end

    describe "Blogger with teams management" do
      test "creates blogger with teams" do
        site = create_site!()
        user = create_user!()
        team1 = create_team!(site_id: site.id, status: :active)
        team2 = create_team!(site_id: site.id, status: :active)

        blogger =
          Blogger
          |> Ash.Changeset.for_create(
            :create,
            %{
              user_id: user.id,
              display_name: "Test Blogger",
              slug: "test-blogger",
              team_ids: [team1.id, team2.id]
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Load teams
        teams_query =
          MishkaBlog.Team
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        blogger_with_teams = Ash.load!(blogger, [teams: teams_query], authorize?: false)

        team_ids = Enum.map(blogger_with_teams.teams.results, & &1.id)
        assert team1.id in team_ids
        assert team2.id in team_ids
        assert length(team_ids) == 2
      end

      test "updates blogger teams" do
        site = create_site!()
        user = create_user!()
        team1 = create_team!(site_id: site.id, status: :active)
        team2 = create_team!(site_id: site.id, status: :active)
        team3 = create_team!(site_id: site.id, status: :active)

        blogger = create_blogger!(site_id: site.id, user_id: user.id, team_ids: [team1.id])

        # Update teams - replace team1 with team2 and team3
        result =
          blogger
          |> Ash.Changeset.for_update(
            :update,
            %{team_ids: [team2.id, team3.id]},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update()

        assert {:ok, updated_blogger} = result

        # Load teams
        teams_query =
          MishkaBlog.Team
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        blogger_with_teams =
          Ash.load!(updated_blogger, [teams: teams_query], authorize?: false)

        team_ids = Enum.map(blogger_with_teams.teams.results, & &1.id)
        assert team2.id in team_ids
        assert team3.id in team_ids
        assert team1.id not in team_ids
        assert length(team_ids) == 2
      end

      test "removes all teams when empty array provided" do
        site = create_site!()
        user = create_user!()
        team1 = create_team!(site_id: site.id, status: :active)
        team2 = create_team!(site_id: site.id, status: :active)

        blogger =
          create_blogger!(site_id: site.id, user_id: user.id, team_ids: [team1.id, team2.id])

        # Remove all teams
        result =
          blogger
          |> Ash.Changeset.for_update(
            :update,
            %{team_ids: []},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update()

        assert {:ok, updated_blogger} = result

        # Verify all teams removed
        teams_query =
          MishkaBlog.Team
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        blogger_with_teams =
          Ash.load!(updated_blogger, [teams: teams_query], authorize?: false)

        assert blogger_with_teams.teams.results == []
      end

      test "master_create creates blogger with teams" do
        site = create_site!()
        user = create_user!()
        team1 = create_team!(site_id: site.id, status: :active)
        team2 = create_team!(site_id: site.id, status: :active)

        blogger =
          Blogger
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              user_id: user.id,
              display_name: "Master Blogger",
              slug: "master-blogger",
              site_id: site.id,
              team_ids: [team1.id, team2.id]
            },
            authorize?: false
          )
          |> Ash.create!()

        teams_query =
          MishkaBlog.Team
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        blogger_with_teams = Ash.load!(blogger, [teams: teams_query], authorize?: false)

        team_ids = Enum.map(blogger_with_teams.teams.results, & &1.id)
        assert team1.id in team_ids
        assert team2.id in team_ids
      end

      test "master_update updates blogger teams" do
        site = create_site!()
        user = create_user!()
        team1 = create_team!(site_id: site.id)
        team2 = create_team!(site_id: site.id)
        team3 = create_team!(site_id: site.id)

        blogger = create_blogger!(site_id: site.id, user_id: user.id, team_ids: [team1.id])

        result =
          blogger
          |> Ash.Changeset.for_update(
            :master_update,
            %{team_ids: [team2.id, team3.id]},
            authorize?: false
          )
          |> Ash.update()

        assert {:ok, updated_blogger} = result

        teams_query =
          MishkaBlog.Team
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        blogger_with_teams =
          Ash.load!(updated_blogger, [tenant_teams: teams_query],
            tenant: site.id,
            authorize?: false
          )

        team_ids = Enum.map(blogger_with_teams.tenant_teams.results, & &1.id)
        assert team2.id in team_ids
        assert team3.id in team_ids
        assert team1.id not in team_ids
        assert length(team_ids) == 2
      end
    end

    describe "JSON API configuration" do
      test "has correct JSON API type" do
        json_api_type = AshJsonApi.Resource.Info.type(Blogger)
        assert json_api_type == "blogger"
      end
    end

    describe "version management - get_with_versions" do
      test "gets blogger with paginated versions (tenant)" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        blogger =
          create_blogger!(
            user_id: user.id,
            display_name: "Original Name",
            bio: "Original bio",
            site_id: site.id
          )

        # Update to create versions
        blogger
        |> Ash.Changeset.for_update(:update, %{bio: "Bio 1"}, tenant: site.id, authorize?: false)
        |> Ash.update!()

        blogger
        |> Ash.Changeset.for_update(:update, %{bio: "Bio 2"}, tenant: site.id, authorize?: false)
        |> Ash.update!()

        # Wait for versions to be created
        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 3)

        result =
          Blogger
          |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 10}, tenant: site.id)
          |> Ash.Query.filter(id == ^blogger.id)
          |> Ash.read_one!(authorize?: false)

        assert result.id == blogger.id
        assert length(result.sorted_versions) >= 3
      end

      test "respects versions_limit argument" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        blogger =
          create_blogger!(
            user_id: user.id,
            display_name: "Test Blogger",
            site_id: site.id
          )

        # Create 5 versions
        Enum.each(1..5, fn i ->
          blogger
          |> Ash.Changeset.for_update(:update, %{bio: "Bio #{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end)

        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 6)

        result =
          Blogger
          |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 2}, tenant: site.id)
          |> Ash.Query.filter(id == ^blogger.id)
          |> Ash.read_one!(authorize?: false)

        assert length(result.sorted_versions) <= 2
      end
    end

    describe "version management - master_get_with_versions" do
      test "gets blogger with versions bypassing tenant (master)" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        blogger =
          create_blogger!(
            user_id: user.id,
            display_name: "Master Test",
            site_id: site.id
          )

        blogger
        |> Ash.Changeset.for_update(:update, %{bio: "Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        result =
          Blogger
          |> Ash.Query.for_read(:master_get_with_versions, %{versions_limit: 10},
            authorize?: false
          )
          |> Ash.Query.filter(id == ^blogger.id)
          |> Ash.read_one!(authorize?: false)

        assert result.id == blogger.id
        assert length(result.sorted_versions) >= 2
      end
    end

    describe "version management - list_versions" do
      test "lists all versions for a blogger (tenant)" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        blogger =
          create_blogger!(
            user_id: user.id,
            display_name: "Version List Test",
            site_id: site.id
          )

        blogger
        |> Ash.Changeset.for_update(:update, %{bio: "V1"}, tenant: site.id, authorize?: false)
        |> Ash.update!()

        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        result =
          Blogger
          |> Ash.Query.for_read(:list_versions, %{blogger_id: blogger.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        assert length(result.results) == 1
        blogger_data = List.first(result.results)
        assert length(blogger_data.sorted_versions) >= 2
      end

      test "returns error for blogger from different tenant" do
        site1 = create_site!()
        site2 = create_site!()
        user = create_user!(site_id: site2.id)

        blogger =
          create_blogger!(
            user_id: user.id,
            display_name: "Cross Tenant",
            site_id: site2.id
          )

        result =
          Blogger
          |> Ash.Query.for_read(:list_versions, %{blogger_id: blogger.id},
            tenant: site1.id,
            authorize?: false
          )
          |> Ash.read!()

        assert result.results == []
      end
    end

    describe "version management - master_list_versions" do
      test "lists all versions bypassing tenant (master)" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        blogger =
          create_blogger!(
            user_id: user.id,
            display_name: "Master List",
            site_id: site.id
          )

        blogger
        |> Ash.Changeset.for_update(:update, %{bio: "Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        result =
          Blogger
          |> Ash.Query.for_read(:master_list_versions, %{blogger_id: blogger.id},
            authorize?: false
          )
          |> Ash.read!(authorize?: false)

        assert length(result.results) == 1
        assert length(List.first(result.results).sorted_versions) >= 2
      end
    end

    describe "version management - restore_version" do
      test "restores blogger to a previous version (tenant)" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        blogger =
          create_blogger!(
            user_id: user.id,
            display_name: "Original",
            bio: "Original bio",
            site_id: site.id
          )

        updated =
          blogger
          |> Ash.Changeset.for_update(:update, %{display_name: "Updated", bio: "Updated bio"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        first_version =
          Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^blogger.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        restored =
          updated
          |> Ash.Changeset.for_update(:restore_version, %{version_id: first_version.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert restored.display_name == "Original"
        assert restored.bio == "Original bio"
      end

      test "cannot restore version of archived blogger" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        blogger =
          create_blogger!(
            user_id: user.id,
            display_name: "To Archive",
            site_id: site.id
          )

        blogger
        |> Ash.Changeset.for_update(:update, %{bio: "Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        archived =
          blogger
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        version =
          Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^blogger.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        assert_raise Ash.Error.Invalid, fn ->
          archived
          |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end
    end

    describe "version management - master_restore_version" do
      test "restores blogger to a previous version (master)" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        blogger =
          create_blogger!(
            user_id: user.id,
            display_name: "Original",
            bio: "Original",
            site_id: site.id
          )

        updated =
          blogger
          |> Ash.Changeset.for_update(:update, %{bio: "Updated"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        version =
          Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^blogger.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        {:ok, restored} =
          updated
          |> Ash.Changeset.for_update(:master_restore_version, %{version_id: version.id},
            authorize?: false
          )
          |> Ash.update()

        assert restored.bio == "Original"
      end

      test "returns error if version doesn't belong to blogger" do
        site = create_site!()
        user1 = create_user!(site_id: site.id, email: "user1@test.com")
        user2 = create_user!(site_id: site.id, email: "user2@test.com")

        blogger1 = create_blogger!(user_id: user1.id, display_name: "Blogger 1", site_id: site.id)
        blogger2 = create_blogger!(user_id: user2.id, display_name: "Blogger 2", site_id: site.id)

        blogger1
        |> Ash.Changeset.for_update(:update, %{bio: "V1"}, tenant: site.id, authorize?: false)
        |> Ash.update!()

        wait_for_version_count("mishka_blog_blogger_versions", blogger1.id, 2)

        version1 =
          Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^blogger1.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        result =
          blogger2
          |> Ash.Changeset.for_update(:master_restore_version, %{version_id: version1.id},
            authorize?: false
          )
          |> Ash.update()

        assert match?({:error, _}, result)
      end

      test "cannot restore archived blogger" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        blogger = create_blogger!(user_id: user.id, display_name: "Test", site_id: site.id)

        blogger
        |> Ash.Changeset.for_update(:update, %{bio: "V1"}, tenant: site.id, authorize?: false)
        |> Ash.update!()

        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        blogger
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        version =
          Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^blogger.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Need to fetch the archived blogger first
        {:ok, archived_blogger} =
          Ash.get(Blogger, blogger.id, action: :master_get_archived, authorize?: false)

        result =
          archived_blogger
          |> Ash.Changeset.for_update(:master_restore_version, %{version_id: version.id},
            authorize?: false
          )
          |> Ash.update()

        assert match?({:error, _}, result)
      end
    end

    describe "version management - preview_version" do
      test "previews a version without restoring (tenant)" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        blogger =
          create_blogger!(
            user_id: user.id,
            display_name: "Original",
            bio: "Original",
            site_id: site.id
          )

        updated =
          blogger
          |> Ash.Changeset.for_update(:update, %{display_name: "Updated", bio: "Updated"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        version =
          Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^blogger.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        {:ok, preview} =
          Blogger
          |> Ash.ActionInput.for_action(
            :preview_version,
            %{blogger_id: blogger.id, version_id: version.id},
            tenant: site.id
          )
          |> Ash.run_action(authorize?: false)

        assert preview.display_name == "Original"
        assert preview.bio == "Original"

        # Verify original unchanged
        current = Ash.get!(Blogger, updated.id, tenant: site.id, authorize?: false)
        assert current.display_name == "Updated"
      end

      test "returns error for blogger from different tenant" do
        site1 = create_site!()
        site2 = create_site!()
        user = create_user!(site_id: site2.id)

        blogger = create_blogger!(user_id: user.id, display_name: "Test", site_id: site2.id)

        blogger
        |> Ash.Changeset.for_update(:update, %{bio: "V1"}, tenant: site2.id, authorize?: false)
        |> Ash.update!()

        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        version =
          Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^blogger.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        result =
          Blogger
          |> Ash.ActionInput.for_action(
            :preview_version,
            %{blogger_id: blogger.id, version_id: version.id},
            tenant: site1.id
          )
          |> Ash.run_action(authorize?: false)

        assert match?({:error, _}, result)
      end
    end

    describe "version management - master_preview_version" do
      test "previews a version bypassing tenant (master)" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        blogger =
          create_blogger!(
            user_id: user.id,
            display_name: "Original",
            bio: "Original",
            site_id: site.id
          )

        blogger
        |> Ash.Changeset.for_update(:update, %{bio: "Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        version =
          Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^blogger.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        {:ok, preview} =
          Blogger
          |> Ash.ActionInput.for_action(
            :master_preview_version,
            %{
              blogger_id: blogger.id,
              version_id: version.id
            },
            authorize?: false
          )
          |> Ash.run_action(authorize?: false)

        assert preview.bio == "Original"
      end
    end

    describe "version calculations" do
      test "version_count returns correct count" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        blogger = create_blogger!(user_id: user.id, display_name: "Test", site_id: site.id)

        blogger
        |> Ash.Changeset.for_update(:update, %{bio: "V1"}, tenant: site.id, authorize?: false)
        |> Ash.update!()

        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        loaded =
          Blogger
          |> Ash.get!(blogger.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:version_count, authorize?: false)

        assert loaded.version_count >= 2
      end

      test "latest_version returns most recent version" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        blogger = create_blogger!(user_id: user.id, display_name: "Test", site_id: site.id)

        blogger
        |> Ash.Changeset.for_update(:update, %{bio: "Latest"}, tenant: site.id, authorize?: false)
        |> Ash.update!()

        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        loaded =
          Blogger
          |> Ash.get!(blogger.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:latest_version, authorize?: false)

        assert is_struct(loaded.latest_version, Blogger.Version)
      end

      test "recent_versions returns up to 10 versions" do
        site = create_site!()
        user = create_user!(site_id: site.id)

        blogger = create_blogger!(user_id: user.id, display_name: "Test", site_id: site.id)

        Enum.each(1..5, fn i ->
          blogger
          |> Ash.Changeset.for_update(:update, %{bio: "V#{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end)

        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 6)

        loaded =
          Blogger
          |> Ash.get!(blogger.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:recent_versions, authorize?: false)

        assert length(loaded.recent_versions) <= 10
        assert length(loaded.recent_versions) >= 5
      end
    end
  end
end
