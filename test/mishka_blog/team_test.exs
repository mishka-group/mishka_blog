# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.TeamTest do
  @moduledoc """
  Tests for MishkaBlog.Team resource focusing on status attribute and public actions.
  """
  use MishkaBlog.DataCase, async: false

  if Code.ensure_loaded?(MishkaBlog) do
    require Ash.Query
    alias MishkaBlog.Team

    describe "status attribute" do
      test "defaults status to draft" do
        site = create_site!()

        team =
          Team
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Test Team",
              slug: "test-team"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert team.status == :draft
      end

      test "accepts active status" do
        site = create_site!()

        team = create_team!(name: "Active Team", status: :active, site_id: site.id)

        assert team.status == :active
      end

      test "accepts inactive status" do
        site = create_site!()

        team = create_team!(name: "Inactive Team", status: :inactive, site_id: site.id)

        assert team.status == :inactive
      end

      test "only accepts valid status values" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          create_team!(name: "Invalid Status", status: :invalid_status, site_id: site.id)
        end
      end

      test "destroy sets status to inactive" do
        site = create_site!()
        team = create_team!(name: "To Archive", status: :active, site_id: site.id)

        archived =
          team
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        assert archived.status == :inactive
        assert archived.archived_at != nil
      end

      test "unarchive sets status to active" do
        site = create_site!()

        team =
          create_team!(name: "To Restore", status: :active, site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        restored =
          team
          |> Ash.Changeset.for_update(:unarchive, %{}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        assert restored.status == :active
        assert restored.archived_at == nil
      end
    end

    describe "public_list action" do
      test "lists active teams without authentication" do
        site = create_site!()

        # Create teams with different statuses
        active1 = create_team!(name: "Active 1", status: :active, site_id: site.id)
        active2 = create_team!(name: "Active 2", status: :active, site_id: site.id)
        _draft = create_team!(name: "Draft", status: :draft, site_id: site.id)
        _inactive = create_team!(name: "Inactive", status: :inactive, site_id: site.id)

        # Archived team
        _archived =
          create_team!(name: "Archived", status: :active, site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Query public_list action without actor (no authentication)
        result =
          Team
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        teams = result.results
        team_ids = Enum.map(teams, & &1.id) |> Enum.sort()

        # Should only return active teams
        assert length(teams) == 2
        assert Enum.sort([active1.id, active2.id]) == team_ids
      end

      test "supports pagination" do
        site = create_site!()

        # Create 25 active teams
        _teams =
          Enum.map(1..25, fn i ->
            create_team!(name: "Team #{i}", status: :active, site_id: site.id)
          end)

        # Query with default pagination (20 per page)
        result =
          Team
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        assert length(result.results) == 20

        # Query second page
        result_page2 =
          Team
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
          |> Ash.Query.page(offset: 20, limit: 10)
          |> Ash.read!()

        assert length(result_page2.results) == 5
      end

      test "respects tenant context" do
        site1 = create_site!()
        site2 = create_site!()

        # Create active teams in different sites
        site1_team = create_team!(name: "Site 1", status: :active, site_id: site1.id)
        _site2_team = create_team!(name: "Site 2", status: :active, site_id: site2.id)

        # Query as site1 tenant
        result =
          Team
          |> Ash.Query.for_read(:public_list, %{}, tenant: site1.id, authorize?: false)
          |> Ash.read!()

        teams = result.results

        # Should only see site1 teams
        assert length(teams) == 1
        assert Enum.at(teams, 0).id == site1_team.id
      end

      test "allows public access without authorization" do
        site = create_site!()
        _team = create_team!(name: "Public", status: :active, site_id: site.id)

        # This should not raise an authorization error
        result =
          Team
          |> Ash.Query.for_read(:public_list, %{}, tenant: site.id)
          |> Ash.read!()

        assert length(result.results) == 1
      end
    end

    describe "public_get action" do
      test "gets a single active team without authentication" do
        site = create_site!()
        team = create_team!(name: "Active Team", status: :active, site_id: site.id)

        # Query without actor (no authentication)
        fetched =
          Ash.get!(
            Team,
            team.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert fetched.id == team.id
        assert fetched.name == "Active Team"
      end

      test "returns error when team is not active (draft status)" do
        site = create_site!()
        draft_team = create_team!(name: "Draft", status: :draft, site_id: site.id)

        # Should not find draft team
        result =
          Ash.get(
            Team,
            draft_team.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "returns error when team is inactive" do
        site = create_site!()
        inactive_team = create_team!(name: "Inactive", status: :inactive, site_id: site.id)

        # Should not find inactive team
        result =
          Ash.get(
            Team,
            inactive_team.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "returns error when team is archived" do
        site = create_site!()

        archived_team =
          create_team!(name: "To Archive", status: :active, site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Should not find archived team
        result =
          Ash.get(
            Team,
            archived_team.id,
            action: :public_get,
            tenant: site.id,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "respects tenant context" do
        site1 = create_site!()
        site2 = create_site!()

        team = create_team!(name: "Site 1", status: :active, site_id: site1.id)

        # Should find in correct tenant
        fetched =
          Ash.get!(
            Team,
            team.id,
            action: :public_get,
            tenant: site1.id,
            authorize?: false
          )

        assert fetched.id == team.id

        # Should not find in wrong tenant
        result =
          Ash.get(
            Team,
            team.id,
            action: :public_get,
            tenant: site2.id,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "allows public access without authorization" do
        site = create_site!()
        team = create_team!(name: "Public", status: :active, site_id: site.id)

        # This should not raise an authorization error
        fetched =
          Ash.get!(
            Team,
            team.id,
            action: :public_get,
            tenant: site.id
          )

        assert fetched.id == team.id
      end
    end

    describe "create action" do
      test "creates team with valid attributes" do
        site = create_site!()

        team =
          Team
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Engineering Team",
              slug: "engineering-team",
              description: "Our engineering team",
              status: :active
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert team.name == "Engineering Team"
        assert team.slug == "engineering-team"
        assert team.description == "Our engineering team"
        assert team.status == :active
        assert team.site_id == site.id
      end

      test "auto-generates slug from slug field" do
        site = create_site!()

        team =
          Team
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "My Awesome Team",
              slug: "My Awesome Team"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert team.slug == "my-awesome-team"
      end

      test "requires name and slug" do
        site = create_site!()

        assert_raise Ash.Error.Invalid, fn ->
          Team
          |> Ash.Changeset.for_create(:create, %{}, tenant: site.id, authorize?: false)
          |> Ash.create!()
        end
      end

      test "auto-assigns site_id from tenant context" do
        site = create_site!()

        team =
          Team
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Tenant Team",
              slug: "tenant-team"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert team.site_id == site.id
      end

      test "accepts optional fields" do
        site = create_site!()

        team =
          Team
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Team with Extras",
              slug: "team-with-extras",
              description: "A detailed description",
              avatar_url: "https://example.com/avatar.png",
              cover_image_url: "https://example.com/cover.png"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        assert team.description == "A detailed description"
        assert team.avatar_url == "https://example.com/avatar.png"
        assert team.cover_image_url == "https://example.com/cover.png"
      end
    end

    describe "master_create action" do
      test "creates team with explicit site_id" do
        site = create_site!()

        team =
          Team
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              name: "Master Team",
              slug: "master-team",
              site_id: site.id
            },
            authorize?: false
          )
          |> Ash.create!()

        assert team.name == "Master Team"
        assert team.site_id == site.id
      end

      test "requires explicit site_id" do
        assert_raise Ash.Error.Invalid, fn ->
          Team
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              name: "Missing Site",
              slug: "missing-site"
            },
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "update action" do
      test "updates team attributes" do
        site = create_site!()
        team = create_team!(name: "Original Name", site_id: site.id)

        updated =
          team
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated Name", description: "New description"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated.name == "Updated Name"
        assert updated.description == "New description"
      end

      test "updates status" do
        site = create_site!()
        team = create_team!(name: "Draft Team", status: :draft, site_id: site.id)

        updated =
          team
          |> Ash.Changeset.for_update(
            :update,
            %{status: :active},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert updated.status == :active
      end

      test "prevents updating archived team" do
        site = create_site!()
        team = create_team!(site_id: site.id)

        # Archive the team
        archived =
          team
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Try to update archived team
        assert_raise Ash.Error.Invalid, fn ->
          archived
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Should Fail"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end
      end

      test "prevents site_id changes" do
        site1 = create_site!()
        site2 = create_site!()
        team = create_team!(site_id: site1.id)

        # site_id is not in the accepted fields for update
        updated =
          team
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated"},
            tenant: site1.id,
            authorize?: false
          )
          |> Ash.update!()

        # site_id should remain unchanged
        assert updated.site_id == site1.id
        assert updated.site_id != site2.id
      end
    end

    describe "master_update action" do
      test "updates team for master users" do
        site = create_site!()
        team = create_team!(name: "Original", site_id: site.id)

        {:ok, updated} =
          team
          |> Ash.Changeset.for_update(
            :master_update,
            %{name: "Master Updated"},
            authorize?: false
          )
          |> Ash.update()

        assert updated.name == "Master Updated"
      end

      test "can update status via master_update" do
        site = create_site!()
        team = create_team!(name: "Team", status: :draft, site_id: site.id)

        {:ok, updated} =
          team
          |> Ash.Changeset.for_update(
            :master_update,
            %{status: :active},
            authorize?: false
          )
          |> Ash.update()

        assert updated.status == :active
      end
    end

    describe "by_slug action" do
      test "finds team by slug within tenant context" do
        site = create_site!()
        team = create_team!(name: "Slug Team", slug: "slug-team", site_id: site.id)

        fetched =
          Team
          |> Ash.Query.for_read(:by_slug, %{slug: "slug-team"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read_one!()

        assert fetched.id == team.id
      end

      test "returns nil when slug not found in tenant" do
        site = create_site!()

        result =
          Team
          |> Ash.Query.for_read(:by_slug, %{slug: "nonexistent"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read_one()

        assert result == {:ok, nil}
      end
    end

    describe "master_by_slug action" do
      test "finds team by slug system-wide" do
        site = create_site!()
        team = create_team!(slug: "master-slug-team", site_id: site.id)

        fetched =
          Team
          |> Ash.Query.for_read(:master_by_slug, %{slug: "master-slug-team"}, authorize?: false)
          |> Ash.read_one!()

        assert fetched.id == team.id
      end
    end

    describe "read actions with multitenancy" do
      test "tenant read only shows teams for that tenant" do
        site1 = create_site!()
        site2 = create_site!()

        team1 = create_team!(name: "Site 1 Team", site_id: site1.id)
        _team2 = create_team!(name: "Site 2 Team", site_id: site2.id)

        # Query as site1 tenant
        teams =
          Team
          |> Ash.Query.set_tenant(site1.id)
          |> Ash.read!(authorize?: false)

        assert length(teams) == 1
        assert Enum.at(teams, 0).id == team1.id
      end

      test "master_read shows all teams system-wide" do
        site1 = create_site!()
        site2 = create_site!()

        _team1 = create_team!(name: "Site 1", site_id: site1.id)
        _team2 = create_team!(name: "Site 2", site_id: site2.id)

        result =
          Team
          |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
          |> Ash.read!(page: [limit: 100])

        teams = result.results
        assert length(teams) >= 2
      end

      test "master_get retrieves team by ID bypassing tenant" do
        site = create_site!()
        team = create_team!(site_id: site.id)

        fetched = Ash.get!(Team, team.id, action: :master_get, authorize?: false)

        assert fetched.id == team.id
      end
    end

    describe "archive/unarchive actions" do
      test "archived action lists only archived teams" do
        site = create_site!()
        active_team = create_team!(name: "Active", site_id: site.id)

        archived_team =
          create_team!(name: "To Archive", site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        result =
          Team
          |> Ash.Query.for_read(:archived, %{}, tenant: site.id, authorize?: false)
          |> Ash.read!()

        archived_list = result.results
        archived_ids = Enum.map(archived_list, & &1.id)
        assert archived_team.id in archived_ids
        refute active_team.id in archived_ids
      end

      test "get_archived retrieves single archived team" do
        site = create_site!()

        team =
          create_team!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        fetched =
          Ash.get!(
            Team,
            team.id,
            action: :get_archived,
            tenant: site.id,
            authorize?: false
          )

        assert fetched.id == team.id
        assert fetched.archived_at != nil
      end

      test "master_unarchive restores team" do
        site = create_site!()

        team =
          create_team!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        {:ok, unarchived} =
          team
          |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
          |> Ash.update()

        assert unarchived.archived_at == nil
        assert unarchived.status == :active
      end

      test "prevents archiving already archived team" do
        site = create_site!()

        team =
          create_team!(site_id: site.id)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        assert_raise Ash.Error.Invalid, fn ->
          team
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!()
        end
      end

      test "prevents unarchiving non-archived team" do
        site = create_site!()
        team = create_team!(site_id: site.id)

        {:error, error} =
          team
          |> Ash.Changeset.for_update(:master_unarchive, %{}, authorize?: false)
          |> Ash.update()

        assert %Ash.Error.Invalid{} = error
      end
    end

    describe "permanent_destroy action" do
      test "permanently deletes team and cannot be recovered" do
        site = create_site!()
        team = create_team!(site_id: site.id)
        team_id = team.id

        team
        |> Ash.Changeset.for_destroy(
          :permanent_destroy,
          %{},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.destroy!()

        # Should not exist in any query
        result =
          Ash.get(
            Team,
            team_id,
            action: :master_get,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end

      test "master_permanent_destroy permanently deletes team" do
        site = create_site!()
        team = create_team!(site_id: site.id)
        team_id = team.id

        :ok =
          team
          |> Ash.Changeset.for_destroy(:master_permanent_destroy, %{}, authorize?: false)
          |> Ash.destroy()

        result =
          Ash.get(
            Team,
            team_id,
            action: :master_get,
            authorize?: false
          )

        assert match?({:error, _}, result)
      end
    end

    describe "database constraints" do
      test "enforces slug length constraints" do
        site = create_site!()

        # Empty slug should fail
        assert_raise Ash.Error.Invalid, fn ->
          create_team!(slug: "", site_id: site.id)
        end

        # Slug too long (> 255) should fail
        long_slug = String.duplicate("a", 256)

        assert_raise Ash.Error.Invalid, fn ->
          create_team!(slug: long_slug, site_id: site.id)
        end
      end

      test "enforces name length constraints" do
        site = create_site!()

        # Empty name should fail
        assert_raise Ash.Error.Invalid, fn ->
          Team
          |> Ash.Changeset.for_create(
            :create,
            %{name: "", slug: "test"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end
      end
    end

    describe "identities" do
      test "unique_slug_per_site prevents duplicate slugs within a site" do
        site = create_site!()
        _team1 = create_team!(slug: "unique-slug", site_id: site.id)

        # The unique constraint raises Ash.Error.Unknown which includes constraint error
        assert_raise Ash.Error.Invalid, fn ->
          create_team!(slug: "unique-slug", site_id: site.id)
        end
      end

      test "allows same slug across different sites" do
        site1 = create_site!()
        site2 = create_site!()

        team1 = create_team!(slug: "same-slug", site_id: site1.id)
        team2 = create_team!(slug: "same-slug", site_id: site2.id)

        assert team1.slug == team2.slug
        assert team1.site_id != team2.site_id
      end
    end

    describe "resource configuration" do
      test "uses correct table name" do
        assert AshPostgres.DataLayer.Info.table(Team) == "mishka_blog_teams"
      end

      test "uses UUID v7 for primary keys" do
        team = create_team!()
        assert is_binary(team.id)
        assert String.length(team.id) == 36
      end

      test "is always site-specific (not global)" do
        multitenancy_config = Ash.Resource.Info.multitenancy_strategy(Team)
        assert multitenancy_config == :attribute
        assert Ash.Resource.Info.multitenancy_global?(Team) == false
      end
    end

    describe "relationships" do
      test "belongs_to site" do
        site = create_site!()
        team = create_team!(site_id: site.id)

        team_with_site = Ash.load!(team, :site, authorize?: false)

        assert team_with_site.site.id == site.id
        assert team_with_site.site.host == site.host
      end
    end

    describe "JSON API configuration" do
      test "has correct JSON API type" do
        json_api_type = AshJsonApi.Resource.Info.type(Team)
        assert json_api_type == "team"
      end
    end

    describe "Team with permissions management" do
      test "creates team with permissions" do
        site = create_site!()
        permission1 = create_permission!()
        permission2 = create_permission!()

        team =
          Team
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Test Team",
              slug: "test-team",
              permission_ids: [permission1.id, permission2.id]
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Load permissions
        team_with_perms = Ash.load!(team, :permissions, tenant: site.id, authorize?: false)

        permission_ids = Enum.map(team_with_perms.permissions, & &1.id)
        assert permission1.id in permission_ids
        assert permission2.id in permission_ids
        assert length(permission_ids) == 2
      end

      test "updates team permissions" do
        site = create_site!()
        permission1 = create_permission!()
        permission2 = create_permission!()
        permission3 = create_permission!()

        # Create team with initial permissions
        team = create_team!(site_id: site.id, permission_ids: [permission1.id, permission2.id])

        # Update to different permissions
        updated_team =
          team
          |> Ash.Changeset.for_update(
            :update,
            %{permission_ids: [permission2.id, permission3.id]},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Load permissions
        team_with_perms =
          Ash.load!(updated_team, :permissions, tenant: site.id, authorize?: false)

        permission_ids = Enum.map(team_with_perms.permissions, & &1.id)
        assert permission2.id in permission_ids
        assert permission3.id in permission_ids
        assert permission1.id not in permission_ids
        assert length(permission_ids) == 2
      end

      test "removes all permissions when empty array provided" do
        site = create_site!()
        permission1 = create_permission!()
        permission2 = create_permission!()

        team = create_team!(site_id: site.id, permission_ids: [permission1.id, permission2.id])

        # Remove all permissions
        updated_team =
          team
          |> Ash.Changeset.for_update(
            :update,
            %{permission_ids: []},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        team_with_perms =
          Ash.load!(updated_team, :permissions, tenant: site.id, authorize?: false)

        assert team_with_perms.permissions == []
      end

      test "master_create creates team with permissions" do
        site = create_site!()
        permission1 = create_permission!()
        permission2 = create_permission!()

        team =
          Team
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              name: "Master Team",
              slug: "master-team",
              site_id: site.id,
              permission_ids: [permission1.id, permission2.id]
            },
            authorize?: false
          )
          |> Ash.create!()

        team_with_perms = Ash.load!(team, :permissions, tenant: site.id, authorize?: false)

        permission_ids = Enum.map(team_with_perms.permissions, & &1.id)
        assert permission1.id in permission_ids
        assert permission2.id in permission_ids
      end

      test "master_update updates team permissions" do
        site = create_site!()
        permission1 = create_permission!()
        permission2 = create_permission!()
        permission3 = create_permission!()

        team = create_team!(site_id: site.id, permission_ids: [permission1.id])

        {:ok, updated_team} =
          team
          |> Ash.Changeset.for_update(
            :master_update,
            %{
              permission_ids: [permission2.id, permission3.id]
            },
            authorize?: false
          )
          |> Ash.update()

        team_with_perms =
          Ash.load!(updated_team, :permissions, tenant: site.id, authorize?: false)

        permission_ids = Enum.map(team_with_perms.permissions, & &1.id)
        assert permission2.id in permission_ids
        assert permission3.id in permission_ids
        assert permission1.id not in permission_ids
      end
    end

    describe "Team with members management" do
      test "creates team with members" do
        site = create_site!()
        blogger1 = create_blogger!(site_id: site.id)
        blogger2 = create_blogger!(site_id: site.id)

        team =
          Team
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Test Team",
              slug: "test-team",
              member_ids: [blogger1.id, blogger2.id]
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Load members
        members_query =
          MishkaBlog.Blogger
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        team_with_members = Ash.load!(team, [members: members_query], authorize?: false)

        member_ids = Enum.map(team_with_members.members.results, & &1.id)
        assert blogger1.id in member_ids
        assert blogger2.id in member_ids
        assert length(member_ids) == 2
      end

      test "updates team members" do
        site = create_site!()
        blogger1 = create_blogger!(site_id: site.id)
        blogger2 = create_blogger!(site_id: site.id)
        blogger3 = create_blogger!(site_id: site.id)

        # Create team with initial members
        team = create_team!(site_id: site.id, member_ids: [blogger1.id, blogger2.id])

        # Update to different members
        # Note: May fail with PaperTrail FK constraint if migrations not run
        result =
          team
          |> Ash.Changeset.for_update(
            :update,
            %{member_ids: [blogger2.id, blogger3.id]},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update()

        assert {:ok, updated_team} = result

        # Load members
        members_query =
          MishkaBlog.Blogger
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        team_with_members =
          Ash.load!(updated_team, [members: members_query], authorize?: false)

        member_ids = Enum.map(team_with_members.members.results, & &1.id)
        assert blogger2.id in member_ids
        assert blogger3.id in member_ids
        assert blogger1.id not in member_ids
        assert length(member_ids) == 2
      end

      test "removes all members when empty array provided" do
        site = create_site!()
        blogger1 = create_blogger!(site_id: site.id)
        blogger2 = create_blogger!(site_id: site.id)

        team = create_team!(site_id: site.id, member_ids: [blogger1.id, blogger2.id])

        # Remove all members
        result =
          team
          |> Ash.Changeset.for_update(
            :update,
            %{member_ids: []},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update()

        assert {:ok, updated_team} = result

        # Verify all members removed
        members_query =
          MishkaBlog.Blogger
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        team_with_members =
          Ash.load!(updated_team, [members: members_query], authorize?: false)

        assert team_with_members.members.results == []
      end

      test "master_create creates team with members" do
        site = create_site!()
        blogger1 = create_blogger!(site_id: site.id)
        blogger2 = create_blogger!(site_id: site.id)

        team =
          Team
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              name: "Master Team",
              slug: "master-team",
              site_id: site.id,
              member_ids: [blogger1.id, blogger2.id]
            },
            authorize?: false
          )
          |> Ash.create!()

        members_query =
          MishkaBlog.Blogger
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        team_with_members = Ash.load!(team, [members: members_query], authorize?: false)

        member_ids = Enum.map(team_with_members.members.results, & &1.id)
        assert blogger1.id in member_ids
        assert blogger2.id in member_ids
      end

      test "master_update updates team members" do
        site = create_site!()
        blogger1 = create_blogger!(site_id: site.id)
        blogger2 = create_blogger!(site_id: site.id)
        blogger3 = create_blogger!(site_id: site.id)

        team = create_team!(site_id: site.id, member_ids: [blogger1.id])

        result =
          team
          |> Ash.Changeset.for_update(
            :master_update,
            %{
              member_ids: [blogger2.id, blogger3.id]
            },
            authorize?: false
          )
          |> Ash.update()

        assert {:ok, updated_team} = result

        # Verify members updated correctly
        members_query =
          MishkaBlog.Blogger
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        team_with_members =
          Ash.load!(updated_team, [members: members_query], authorize?: false)

        member_ids = Enum.map(team_with_members.members.results, & &1.id)
        assert blogger2.id in member_ids
        assert blogger3.id in member_ids
        assert blogger1.id not in member_ids
        assert length(member_ids) == 2
      end

      test "can add both permissions and members in same operation" do
        site = create_site!()
        permission1 = create_permission!()
        permission2 = create_permission!()
        blogger1 = create_blogger!(site_id: site.id)
        blogger2 = create_blogger!(site_id: site.id)

        team =
          Team
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "Full Team",
              slug: "full-team",
              permission_ids: [permission1.id, permission2.id],
              member_ids: [blogger1.id, blogger2.id]
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        members_query =
          MishkaBlog.Blogger
          |> Ash.Query.set_tenant(site.id)
          |> Ash.Query.page(limit: 10)

        team_loaded =
          Ash.load!(team, [:permissions, members: members_query], authorize?: false)

        permission_ids = Enum.map(team_loaded.permissions, & &1.id)
        member_ids = Enum.map(team_loaded.members.results, & &1.id)

        assert permission1.id in permission_ids
        assert permission2.id in permission_ids
        assert blogger1.id in member_ids
        assert blogger2.id in member_ids
      end
    end

    describe "version management - get_with_versions" do
      test "gets team with paginated versions (tenant)" do
        site = create_site!()

        team = create_team!(name: "Team1", site_id: site.id)

        # Update to create versions
        team
        |> Ash.Changeset.for_update(:update, %{name: "Team1V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        team
        |> Ash.Changeset.for_update(:update, %{name: "Team1V2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        result =
          Team
          |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 10}, tenant: site.id)
          |> Ash.Query.filter(id: team.id)
          |> Ash.read_one!(authorize?: false)

        assert result.id == team.id
        assert is_list(result.sorted_versions)
        assert length(result.sorted_versions) > 0
      end

      test "respects versions_limit argument" do
        site = create_site!()

        team = create_team!(name: "Team2", site_id: site.id)

        # Create multiple versions
        for i <- 1..5 do
          team
          |> Ash.Changeset.for_update(:update, %{name: "Team2V#{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end

        result =
          Team
          |> Ash.Query.for_read(:get_with_versions, %{versions_limit: 2}, tenant: site.id)
          |> Ash.Query.filter(id: team.id)
          |> Ash.read_one!(authorize?: false)

        assert length(result.sorted_versions) <= 2
      end
    end

    describe "version management - master_get_with_versions" do
      test "gets team with versions bypassing tenant (master)" do
        site = create_site!()

        team = create_team!(name: "Team3", site_id: site.id)

        # Update to create a version
        team
        |> Ash.Changeset.for_update(:update, %{name: "Team3Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        result =
          Team
          |> Ash.Query.for_read(:master_get_with_versions, %{versions_limit: 10},
            authorize?: false
          )
          |> Ash.Query.filter(id: team.id)
          |> Ash.read_one!(authorize?: false)

        assert result.id == team.id
        assert is_list(result.sorted_versions)
      end
    end

    describe "version management - list_versions" do
      test "lists all versions for a team (tenant)" do
        site = create_site!()

        team = create_team!(name: "Team4", site_id: site.id)

        # Create versions
        team
        |> Ash.Changeset.for_update(:update, %{name: "Team4V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        team
        |> Ash.Changeset.for_update(:update, %{name: "Team4V2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        result =
          Team
          |> Ash.Query.for_read(:list_versions, %{team_id: team.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.read!()

        teams = result.results
        assert length(teams) == 1

        first_team = List.first(teams)
        assert first_team.id == team.id
        assert is_list(first_team.sorted_versions)
        assert length(first_team.sorted_versions) > 0
      end

      test "returns error for team from different tenant" do
        site1 = create_site!()
        site2 = create_site!()

        team = create_team!(site_id: site1.id)

        result =
          Team
          |> Ash.Query.for_read(:list_versions, %{team_id: team.id},
            tenant: site2.id,
            authorize?: false
          )
          |> Ash.read()

        assert {:error, %Ash.Error.Invalid{}} = result
      end
    end

    describe "version management - master_list_versions" do
      test "lists all versions bypassing tenant (master)" do
        site = create_site!()

        team = create_team!(name: "Team5", site_id: site.id)

        # Create version
        team
        |> Ash.Changeset.for_update(:update, %{name: "Team5Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        result =
          Team
          |> Ash.Query.for_read(:master_list_versions, %{team_id: team.id}, authorize?: false)
          |> Ash.read!(authorize?: false)

        teams = result.results
        assert length(teams) == 1

        first_team = List.first(teams)
        assert first_team.id == team.id
        assert is_list(first_team.sorted_versions)
      end
    end

    describe "version management - restore_version" do
      test "restores team to a previous version (tenant)" do
        site = create_site!()

        team =
          create_team!(
            name: "Team6",
            description: "Original desc",
            site_id: site.id
          )

        # Update to create a version
        updated =
          team
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Team6Updated", description: "Updated desc"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Get the first version
        versions =
          Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: team.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.read!(authorize?: false)

        first_version = List.first(versions)
        assert not is_nil(first_version)

        # Restore to first version
        restored =
          updated
          |> Ash.Changeset.for_update(:restore_version, %{version_id: first_version.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        assert restored.name == "Team6"
        assert restored.description == "Original desc"
      end

      test "cannot restore version of archived team" do
        site = create_site!()

        team = create_team!(name: "Team7", site_id: site.id)

        # Create a version
        team
        |> Ash.Changeset.for_update(:update, %{name: "Team7Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Archive the team
        archived =
          team
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)

        # Get a version
        version =
          Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: team.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Try to restore archived team
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
      test "restores team to a previous version (master)" do
        site = create_site!()

        team = create_team!(name: "Team8", site_id: site.id)

        # Update to create a version
        updated =
          team
          |> Ash.Changeset.for_update(:update, %{name: "Team8Updated"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Get the first version
        version =
          Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: team.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Restore using master action
        {:ok, restored} =
          updated
          |> Ash.Changeset.for_update(
            :master_restore_version,
            %{
              version_id: version.id
            },
            authorize?: false
          )
          |> Ash.update()

        assert restored.name == "Team8"
      end

      test "returns error if version doesn't belong to team" do
        site = create_site!()

        team1 = create_team!(name: "Team9", site_id: site.id)
        team2 = create_team!(name: "Team10", site_id: site.id)

        # Create a version for team2
        team2
        |> Ash.Changeset.for_update(:update, %{name: "Team10Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Get version from team2
        version =
          Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: team2.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Try to restore team1 with team2's version
        result =
          team1
          |> Ash.Changeset.for_update(
            :master_restore_version,
            %{
              version_id: version.id
            },
            authorize?: false
          )
          |> Ash.update()

        assert match?({:error, _}, result)
      end

      test "cannot restore archived team" do
        site = create_site!()

        team = create_team!(name: "Team11", site_id: site.id)

        # Create a version
        team
        |> Ash.Changeset.for_update(:update, %{name: "Team11Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Archive the team
        team
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Get a version
        version =
          Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: team.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Fetch the archived team
        archived_team =
          Ash.get!(Team, team.id, action: :master_get_archived, authorize?: false)

        # Try to restore - should fail because team is archived
        result =
          archived_team
          |> Ash.Changeset.for_update(
            :master_restore_version,
            %{
              version_id: version.id
            },
            authorize?: false
          )
          |> Ash.update()

        assert match?({:error, _}, result)
      end
    end

    describe "version management - preview_version" do
      test "previews a version without restoring (tenant)" do
        site = create_site!()

        team =
          create_team!(
            name: "Team12",
            description: "Original desc",
            site_id: site.id
          )

        # Update to create a version
        team
        |> Ash.Changeset.for_update(
          :update,
          %{name: "Team12Updated", description: "Updated desc"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Get the first version
        version =
          Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: team.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Preview the version
        {:ok, preview} =
          Team
          |> Ash.ActionInput.for_action(
            :preview_version,
            %{team_id: team.id, version_id: version.id},
            tenant: site.id
          )
          |> Ash.run_action(authorize?: false)

        assert preview.name == "Team12"
        assert preview.description == "Original desc"

        # Verify original is unchanged
        current = Ash.get!(Team, team.id, tenant: site.id, authorize?: false)
        assert current.name == "Team12Updated"
      end

      test "returns error for version from wrong team" do
        site = create_site!()
        team1 = create_team!(site_id: site.id)
        team2 = create_team!(site_id: site.id)

        # Create version for team2
        team2
        |> Ash.Changeset.for_update(:update, %{name: "Team13Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Get version from team2
        version =
          Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: team2.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Try to preview with team1
        result =
          Team
          |> Ash.ActionInput.for_action(
            :preview_version,
            %{team_id: team1.id, version_id: version.id},
            tenant: site.id
          )
          |> Ash.run_action(authorize?: false)

        assert match?({:error, _}, result)
      end
    end

    describe "version management - master_preview_version" do
      test "previews a version without restoring (master)" do
        site = create_site!()

        team = create_team!(name: "Team14", site_id: site.id)

        # Update to create a version
        team
        |> Ash.Changeset.for_update(:update, %{name: "Team14Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Get the first version
        version =
          Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: team.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Preview using master action
        {:ok, preview} =
          Team
          |> Ash.ActionInput.for_action(
            :master_preview_version,
            %{
              team_id: team.id,
              version_id: version.id
            },
            authorize?: false
          )
          |> Ash.run_action(authorize?: false)

        assert preview.name == "Team14"
      end
    end

    describe "version calculations" do
      test "version_count returns correct count" do
        site = create_site!()

        team = create_team!(name: "Team15", site_id: site.id)

        # Create some versions
        team
        |> Ash.Changeset.for_update(:update, %{name: "Team15V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        team
        |> Ash.Changeset.for_update(:update, %{name: "Team15V2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        loaded =
          Team
          |> Ash.get!(team.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:version_count, authorize?: false)

        assert loaded.version_count >= 2
      end

      test "latest_version returns most recent version" do
        site = create_site!()

        team = create_team!(name: "Team16", site_id: site.id)

        # Create versions
        team
        |> Ash.Changeset.for_update(:update, %{name: "Team16V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        team
        |> Ash.Changeset.for_update(:update, %{name: "Team16V2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        loaded =
          Team
          |> Ash.get!(team.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:latest_version, authorize?: false)

        assert not is_nil(loaded.latest_version)
        assert is_struct(loaded.latest_version, Team.Version)
      end

      test "recent_versions returns up to 10 versions" do
        site = create_site!()

        team = create_team!(name: "Team17", site_id: site.id)

        # Create multiple versions
        for i <- 1..5 do
          team
          |> Ash.Changeset.for_update(:update, %{name: "Team17V#{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end

        loaded =
          Team
          |> Ash.get!(team.id, tenant: site.id, authorize?: false)
          |> Ash.load!(:recent_versions, authorize?: false)

        assert is_list(loaded.recent_versions)
        assert length(loaded.recent_versions) <= 10
        assert length(loaded.recent_versions) >= 5
      end
    end
  end
end
