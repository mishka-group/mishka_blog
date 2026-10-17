# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Api.Json.TeamTest do
  @moduledoc """
  Comprehensive tests for Team JSON API endpoints.
  """

  use MishkaBlog.ConnCase
  import MishkaBlog.Test.Factory
  import MishkaBlog.Test.VersionHelpers
  require Ash.Query

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaBlog) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @api_master_path "/api/json/v1/master/admin/mishka-blog/team"
    @api_tenant_path "/api/json/v1/tenant/admin/mishka-blog/team"
    @api_public_path "/api/json/v1/user/mishka-blog/team"

    setup do
      MishkaCmsCore.Runtime.States.SiteState.clear()
      :ok = Swoosh.TestAssertions.set_swoosh_global()

      Application.put_env(:ash_json_api, MishkaBlog, router: MishkaBlog.TestRouter)

      # Create initial site for testing
      site =
        create_site!(
          name: "localhost",
          host: "localhost",
          active: true,
          priority: 50,
          master: true
        )

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })

      # Create a second site for cross-tenant testing
      site2 = create_site!(name: "site2", host: "site2.com", active: true, priority: 40)

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: site2.id,
        name: site2.name,
        host: site2.host,
        priority: site2.priority,
        active: site2.active
      })

      # Create admin permission
      admin_permission = create_permission!(name: "admin:api:*")

      # Create master user with admin permissions (no site_id)
      master_user =
        MishkaCmsCore.Accounts.User
        |> Ash.Changeset.for_create(:create, %{
          email: "master@example.com",
          hashed_password: Bcrypt.hash_pwd_salt(@password)
        })
        |> Ash.create!(authorize?: false, tenant: nil)
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: [admin_permission.id]},
          authorize?: false
        )
        |> Ash.update!()

      # Create tenant admin user for site1
      tenant_admin =
        create_user!(
          email: "tenant.admin@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: [admin_permission.id]},
          authorize?: false,
          tenant: site.id
        )
        |> Ash.update!()

      # Create regular tenant user without admin permissions
      tenant_user =
        create_user!(
          email: "tenant.user@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: []},
          authorize?: false,
          tenant: site.id
        )
        |> Ash.update!()

      # Create tenant admin user for site2
      site2_admin =
        create_user!(
          email: "site2.admin@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site2.id
        )
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: [admin_permission.id]},
          authorize?: false,
          tenant: site2.id
        )
        |> Ash.update!()

      on_exit(fn ->
        MishkaCmsCore.Runtime.States.SiteState.delete(site.id)
        MishkaCmsCore.Runtime.States.SiteState.delete(site2.id)
        MishkaCmsCore.Runtime.States.SiteState.clear()
      end)

      %{
        site: site,
        site2: site2,
        admin_permission: admin_permission,
        master_user: master_user,
        tenant_admin: tenant_admin,
        tenant_user: tenant_user,
        site2_admin: site2_admin
      }
    end

    # Helper functions
    defp sign_in_master(master_user) do
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(master_user.email),
              "password" => @password
            }
          },
          headers: [{"x-no-tenant", "true"}]
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)
      token
    end

    defp sign_in_tenant(tenant_user, site) do
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(tenant_user.email),
              "password" => @password
            }
          },
          headers: [{"x-no-tenant", "false"}],
          host: site.host
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)
      token
    end

    defp assert_no_account_fields(response) do
      for user <- included(response, "user") do
        assert account_fields(user) == %{},
               "user #{user["id"]} reached a visitor with its account fields"
      end

      assert included(response, "site") == [] and included(response, "permission") == [],
             "a member's site or permissions reached a visitor"

      refute response.resp_body =~ "@example.com"
    end

    describe "CREATE - POST /team (master admin)" do
      test "master admin can create team for any site", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        response =
          make_api_request(
            @api_master_path,
            %{
              "type" => "team",
              "attributes" => %{
                "name" => "Tech Team",
                "slug" => "tech-team",
                "description" => "Technology content team",
                "status" => "active",
                "site_id" => site.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Tech Team"
        assert body["data"]["attributes"]["slug"] == "tech-team"
        assert body["data"]["attributes"]["status"] == "active"
        assert body["data"]["attributes"]["site_id"] == site.id
      end

      test "master admin can create team for multiple sites", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        # Create for site1
        response1 =
          make_api_request(
            @api_master_path,
            %{
              "type" => "team",
              "attributes" => %{
                "name" => "Site 1 Team",
                "slug" => "site1-team",
                "status" => "active",
                "site_id" => site.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response1.status == 201

        # Create for site2
        response2 =
          make_api_request(
            @api_master_path,
            %{
              "type" => "team",
              "attributes" => %{
                "name" => "Site 2 Team",
                "slug" => "site2-team",
                "status" => "active",
                "site_id" => site2.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 201
      end

      test "master admin cannot create team without site_id", %{master_user: master_user} do
        token = sign_in_master(master_user)

        response =
          make_api_request(
            @api_master_path,
            %{
              "type" => "team",
              "attributes" => %{
                "name" => "No Site Team",
                "slug" => "no-site-team"
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status in [400, 422]
      end
    end

    describe "CREATE - POST /team (tenant admin)" do
      test "tenant admin can create team for their site", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        response =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "team",
              "attributes" => %{
                "name" => "Tenant Team",
                "slug" => "tenant-team",
                "description" => "Team for tenant",
                "status" => "active"
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Tenant Team"
        assert body["data"]["attributes"]["slug"] == "tenant-team"
        assert body["data"]["attributes"]["site_id"] == site.id
      end

      test "tenant admin cannot create team without proper permissions", %{
        tenant_user: tenant_user,
        site: site
      } do
        token = sign_in_tenant(tenant_user, site)

        response =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "team",
              "attributes" => %{
                "name" => "Unauthorized Team",
                "slug" => "unauthorized-team"
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 403
      end

      test "teams are isolated per site", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin, site)

        # Create two teams with same slug on same site should fail
        response1 =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "team",
              "attributes" => %{
                "name" => "Team 1",
                "slug" => "duplicate-slug",
                "status" => "active"
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response1.status == 201

        response2 =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "team",
              "attributes" => %{
                "name" => "Team 2",
                "slug" => "duplicate-slug",
                "status" => "active"
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response2.status == 400
      end
    end

    describe "READ - GET /team (master admin)" do
      test "master admin can list all teams across all sites", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        # Create teams for both sites
        create_team!(site_id: site.id, name: "Site1 Team", slug: "site1-team")
        create_team!(site_id: site2.id, name: "Site2 Team", slug: "site2-team")

        response =
          make_api_request(
            @api_master_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) >= 2
      end

      test "master admin can get single team by ID", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)
        team = create_team!(site_id: site.id, name: "Test Team", slug: "test-team")

        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == team.id
        assert body["data"]["attributes"]["name"] == "Test Team"
      end

      test "master admin can get team by slug", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)
        create_team!(site_id: site.id, name: "Slug Team", slug: "slug-team")

        response =
          make_api_request(
            "#{@api_master_path}/by-slug/slug-team",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["slug"] == "slug-team"
      end

      test "master admin can list archived teams", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)

        {:ok, team} =
          create_team!(site_id: site.id, name: "Archived Team", slug: "archived-team")
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy(return_destroyed?: true)

        response =
          make_api_request(
            "#{@api_master_path}/archived",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert Enum.any?(body["data"], fn t -> t["id"] == team.id end)
      end
    end

    describe "READ - GET /team (tenant admin)" do
      test "tenant admin can only list teams from their site", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin, site)

        # Create teams for both sites
        team1 = create_team!(site_id: site.id, name: "Site1 Team", slug: "site1-team")
        _team2 = create_team!(site_id: site2.id, name: "Site2 Team", slug: "site2-team")

        response =
          make_api_request(
            @api_tenant_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        team_ids = Enum.map(body["data"], fn t -> t["id"] end)
        assert team1.id in team_ids
        # site2 team should not be visible
        refute Enum.any?(body["data"], fn t -> t["attributes"]["name"] == "Site2 Team" end)
      end

      test "tenant admin can get team by ID within their tenant", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)
        team = create_team!(site_id: site.id, name: "Test Team", slug: "test-team")

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == team.id
      end

      test "tenant admin cannot access team from another site", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin, site)
        team2 = create_team!(site_id: site2.id, name: "Site2 Team", slug: "site2-team")

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team2.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 404
      end

      test "tenant admin can get team by slug", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin, site)
        create_team!(site_id: site.id, name: "Slug Team", slug: "slug-team")

        response =
          make_api_request(
            "#{@api_tenant_path}/by-slug/slug-team",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["slug"] == "slug-team"
      end

      test "tenant admin can list archived teams", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin, site)

        {:ok, team} =
          create_team!(site_id: site.id, name: "Archived Team", slug: "archived-team")
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy(return_destroyed?: true)

        response =
          make_api_request(
            "#{@api_tenant_path}/archived",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert Enum.any?(body["data"], fn t -> t["id"] == team.id end)
      end
    end

    describe "UPDATE - PATCH /team (master admin)" do
      test "master admin can update team", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)
        team = create_team!(site_id: site.id, name: "Old Name", slug: "old-name")

        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}",
            %{
              "type" => "team",
              "attributes" => %{
                "name" => "New Name",
                "description" => "Updated description"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "New Name"
        assert body["data"]["attributes"]["description"] == "Updated description"
      end

      test "master admin can update team status", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)
        team = create_team!(site_id: site.id, name: "Team", slug: "team", status: :draft)

        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}",
            %{
              "type" => "team",
              "attributes" => %{
                "status" => "active"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["status"] == "active"
      end

      test "master admin cannot update archived team", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)

        {:ok, team} =
          create_team!(site_id: site.id, name: "Team", slug: "team")
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy(return_destroyed?: true)

        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}",
            %{
              "type" => "team",
              "attributes" => %{
                "name" => "Should Fail"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status in [400, 422]
      end
    end

    describe "UPDATE - PATCH /team (tenant admin)" do
      test "tenant admin can update their team", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin, site)
        team = create_team!(site_id: site.id, name: "Old Name", slug: "old-name")

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}",
            %{
              "type" => "team",
              "attributes" => %{
                "name" => "New Name",
                "description" => "Updated"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "New Name"
      end

      test "tenant admin cannot update team from another site", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin, site)
        team2 = create_team!(site_id: site2.id, name: "Site2 Team", slug: "site2-team")

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team2.id}",
            %{
              "type" => "team",
              "attributes" => %{
                "name" => "Should Fail"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 404
      end

      test "regular user cannot update team", %{tenant_user: tenant_user, site: site} do
        token = sign_in_tenant(tenant_user, site)
        team = create_team!(site_id: site.id, name: "Team", slug: "team")

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}",
            %{
              "type" => "team",
              "attributes" => %{
                "name" => "Should Fail"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 403
      end
    end

    describe "DELETE - DELETE /team/archive (master admin)" do
      test "master admin can archive team", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)
        team = create_team!(site_id: site.id, name: "Team", slug: "team", status: :active)

        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status in [200, 204]

        # Verify team is archived
        get_response =
          make_api_request(
            "#{@api_master_path}/archived/#{team.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert get_response.status == 200
        body = Jason.decode!(get_response.resp_body)
        assert body["data"]["attributes"]["status"] == "inactive"
      end

      test "master admin cannot archive already archived team", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        {:ok, team} =
          create_team!(site_id: site.id, name: "Team", slug: "team")
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy(return_destroyed?: true)

        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status in [400, 404, 422]
      end
    end

    describe "DELETE - DELETE /team/archive (tenant admin)" do
      test "tenant admin can archive their team", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin, site)
        team = create_team!(site_id: site.id, name: "Team", slug: "team")

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status in [200, 204]

        # Verify team is archived
        get_response =
          make_api_request(
            "#{@api_tenant_path}/archived/#{team.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert get_response.status == 200
      end

      test "tenant admin cannot archive team from another site", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin, site)
        team2 = create_team!(site_id: site2.id, name: "Site2 Team", slug: "site2-team")

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team2.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 404
      end
    end

    describe "PATCH /team/unarchive (master admin)" do
      test "master admin can unarchive team", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)

        {:ok, team} =
          create_team!(site_id: site.id, name: "Team", slug: "team")
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy(return_destroyed?: true)

        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}/unarchive",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["status"] == "active"

        # Verify team appears in active list
        list_response =
          make_api_request(
            @api_master_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert list_response.status == 200
        list_body = Jason.decode!(list_response.resp_body)
        assert Enum.any?(list_body["data"], fn t -> t["id"] == team.id end)
      end

      test "master admin cannot unarchive non-archived team", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        team = create_team!(site_id: site.id, name: "Team", slug: "team")

        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}/unarchive",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status in [400, 404, 422]
      end
    end

    describe "PATCH /team/unarchive (tenant admin)" do
      test "tenant admin can unarchive their team", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin, site)

        {:ok, team} =
          create_team!(site_id: site.id, name: "Team", slug: "team")
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy(return_destroyed?: true)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}/unarchive",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["status"] == "active"
      end

      test "tenant admin cannot unarchive team from another site", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin, site)

        {:ok, team2} =
          create_team!(site_id: site2.id, name: "Site2 Team", slug: "site2-team")
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site2.id, authorize?: false)
          |> Ash.destroy(return_destroyed?: true)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team2.id}/unarchive",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 404
      end
    end

    describe "DELETE - DELETE /team/permanent (master admin)" do
      test "master admin can permanently delete team", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)
        team = create_team!(site_id: site.id, name: "Team", slug: "team")

        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}/permanent",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status in [200, 204]

        # Verify team no longer exists
        get_response =
          make_api_request(
            "#{@api_master_path}/#{team.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert get_response.status == 404
      end
    end

    describe "DELETE - DELETE /team/permanent (tenant admin)" do
      test "tenant admin can permanently delete their team", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)
        team = create_team!(site_id: site.id, name: "Team", slug: "team")

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}/permanent",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status in [200, 204]

        # Verify team no longer exists
        get_response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert get_response.status == 404
      end
    end

    describe "READ - GET /team (public)" do
      test "anyone can list active teams without authentication", %{site: site} do
        create_team!(site_id: site.id, name: "Active Team", slug: "active-team", status: :active)

        create_team!(
          site_id: site.id,
          name: "Draft Team",
          slug: "draft-team",
          status: :draft
        )

        response =
          make_api_request(
            "#{@api_public_path}",
            %{},
            method: :get,
            headers: [],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Should only see active teams
        assert Enum.all?(body["data"], fn t -> t["attributes"]["status"] == "active" end)
        refute Enum.any?(body["data"], fn t -> t["attributes"]["name"] == "Draft Team" end)
      end

      test "anyone can get single active team without authentication", %{site: site} do
        team =
          create_team!(
            site_id: site.id,
            name: "Active Team",
            slug: "active-team",
            status: :active
          )

        response =
          make_api_request(
            "#{@api_public_path}/#{team.id}",
            %{},
            method: :get,
            headers: [],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == team.id
        assert body["data"]["attributes"]["name"] == "Active Team"
      end

      test "public cannot access draft or inactive teams", %{site: site} do
        team =
          create_team!(site_id: site.id, name: "Draft Team", slug: "draft-team", status: :draft)

        response =
          make_api_request(
            "#{@api_public_path}/#{team.id}",
            %{},
            method: :get,
            headers: [],
            host: site.host
          )

        assert response.status == 404
      end

      test "public cannot access archived teams", %{site: site} do
        {:ok, team} =
          create_team!(site_id: site.id, name: "Team", slug: "team")
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy(return_destroyed?: true)

        response =
          make_api_request(
            "#{@api_public_path}/active/#{team.id}",
            %{},
            method: :get,
            headers: [],
            host: site.host
          )

        assert response.status == 404
      end
    end

    describe "Pagination" do
      test "master admin can paginate teams", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)

        # Create multiple teams
        for i <- 1..25 do
          create_team!(site_id: site.id, name: "Team #{i}", slug: "team-#{i}")
        end

        # Get first page
        response =
          make_api_request(
            "#{@api_master_path}?page[limit]=10&page[offset]=0",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 10
      end

      test "tenant admin can paginate teams", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin, site)

        # Create multiple teams
        for i <- 1..25 do
          create_team!(site_id: site.id, name: "Team #{i}", slug: "team-#{i}")
        end

        response =
          make_api_request(
            "#{@api_tenant_path}?page[limit]=10&page[offset]=0",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 10
      end
    end

    describe "Calculations - member_count and follower_count" do
      test "master admin can get team with member_count", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create team
        team = create_team!(site_id: site.id, name: "Test Team", slug: "test-team")

        # Create bloggers
        blogger1 = create_blogger!(site_id: site.id, name: "Blogger 1", slug: "blogger-1")
        blogger2 = create_blogger!(site_id: site.id, name: "Blogger 2", slug: "blogger-2")
        blogger3 = create_blogger!(site_id: site.id, name: "Blogger 3", slug: "blogger-3")

        # Add members to team
        create_team_member!(team_id: team.id, blogger_id: blogger1.id)
        create_team_member!(team_id: team.id, blogger_id: blogger2.id)
        create_team_member!(team_id: team.id, blogger_id: blogger3.id)

        # Get team with member_count calculation
        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}?fields[team]=name,slug,member_count",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["member_count"] == 3
      end

      test "master admin can get team with follower_count", %{
        master_user: master_user,
        site: site,
        tenant_admin: tenant_admin,
        tenant_user: tenant_user
      } do
        token = sign_in_master(master_user)

        # Create team
        team = create_team!(site_id: site.id, name: "Test Team", slug: "test-team")

        # Add followers to team
        create_team_follower!(team_id: team.id, follower_user_id: tenant_admin.id)
        create_team_follower!(team_id: team.id, follower_user_id: tenant_user.id)

        # Get team with follower_count calculation
        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}?fields[team]=name,slug,follower_count",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["follower_count"] == 2
      end

      test "master admin can get team with both member_count and follower_count", %{
        master_user: master_user,
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_master(master_user)

        # Create team
        team = create_team!(site_id: site.id, name: "Test Team", slug: "test-team")

        # Create bloggers and add as members
        blogger1 = create_blogger!(site_id: site.id, name: "Blogger 1", slug: "blogger-1")
        blogger2 = create_blogger!(site_id: site.id, name: "Blogger 2", slug: "blogger-2")
        create_team_member!(team_id: team.id, blogger_id: blogger1.id)
        create_team_member!(team_id: team.id, blogger_id: blogger2.id)

        # Add followers
        create_team_follower!(team_id: team.id, follower_user_id: tenant_admin.id)

        # Get team with both calculations
        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}?fields[team]=name,slug,member_count,follower_count",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["member_count"] == 2
        assert body["data"]["attributes"]["follower_count"] == 1
      end

      test "tenant admin can get team with member_count", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        # Create team
        team = create_team!(site_id: site.id, name: "Test Team", slug: "test-team")

        # Create bloggers and add as members
        blogger1 = create_blogger!(site_id: site.id, name: "Blogger 1", slug: "blogger-1")
        blogger2 = create_blogger!(site_id: site.id, name: "Blogger 2", slug: "blogger-2")
        create_team_member!(team_id: team.id, blogger_id: blogger1.id)
        create_team_member!(team_id: team.id, blogger_id: blogger2.id)

        # Get team with member_count calculation
        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}?fields[team]=name,slug,member_count",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["member_count"] == 2
      end

      test "tenant admin can get team with follower_count", %{
        tenant_admin: tenant_admin,
        tenant_user: tenant_user,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        # Create team
        team = create_team!(site_id: site.id, name: "Test Team", slug: "test-team")

        # Add followers
        create_team_follower!(team_id: team.id, follower_user_id: tenant_admin.id)
        create_team_follower!(team_id: team.id, follower_user_id: tenant_user.id)

        # Get team with follower_count calculation
        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}?fields[team]=name,slug,follower_count",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["follower_count"] == 2
      end

      test "public can get team with member_count and follower_count", %{site: site} do
        # Create active team
        team =
          create_team!(
            site_id: site.id,
            name: "Public Team",
            slug: "public-team",
            status: :active
          )

        # Create bloggers and add as members
        blogger1 = create_blogger!(site_id: site.id, display_name: "Blogger 1", slug: "blogger-1")
        create_team_member!(team_id: team.id, blogger_id: blogger1.id)

        # Get team with both calculations (no auth)
        response =
          make_api_request(
            "#{@api_public_path}/#{team.id}?fields[team]=name,slug,member_count,follower_count",
            %{},
            method: :get,
            headers: [],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["member_count"] == 1
        assert body["data"]["attributes"]["follower_count"] == 0
      end

      test "member_count returns 0 when team has no members", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create team without members
        team = create_team!(site_id: site.id, name: "Empty Team", slug: "empty-team")

        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}?fields[team]=name,slug,member_count",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["member_count"] == 0
      end

      test "follower_count returns 0 when team has no followers", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create team without followers
        team = create_team!(site_id: site.id, name: "No Followers Team", slug: "no-followers")

        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}?fields[team]=name,slug,follower_count",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["follower_count"] == 0
      end
    end

    describe "Public API - Team routes" do
      test "anyone can list all active teams", %{site: site} do
        # Create active teams
        active1 =
          create_team!(site_id: site.id, name: "Active Team 1", slug: "active-1", status: :active)

        active2 =
          create_team!(site_id: site.id, name: "Active Team 2", slug: "active-2", status: :active)

        # Create non-active teams (should not appear)
        _draft = create_team!(site_id: site.id, name: "Draft Team", slug: "draft", status: :draft)

        response =
          make_api_request(
            "#{@api_public_path}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])

        ids = Enum.map(body["data"], & &1["id"])
        assert active1.id in ids
        assert active2.id in ids

        # Verify all returned teams are active
        Enum.each(body["data"], fn team ->
          assert team["attributes"]["status"] == "active"
        end)
      end

      test "anyone can get active team by id", %{site: site} do
        active_team =
          create_team!(
            site_id: site.id,
            name: "Public Team",
            slug: "public-team",
            status: :active
          )

        response =
          make_api_request(
            "#{@api_public_path}/#{active_team.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == active_team.id
        assert body["data"]["attributes"]["name"] == "Public Team"
        assert body["data"]["attributes"]["status"] == "active"
      end

      test "cannot get draft team by id on public endpoint", %{site: site} do
        draft_team =
          create_team!(site_id: site.id, name: "Draft Team", slug: "draft", status: :draft)

        response =
          make_api_request(
            "#{@api_public_path}/#{draft_team.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 404
      end

      test "anyone can get active team by slug", %{site: site} do
        active_team =
          create_team!(
            site_id: site.id,
            name: "Slugged Team",
            slug: "slugged-team",
            status: :active
          )

        response =
          make_api_request(
            "#{@api_public_path}/by-slug/slugged-team",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == active_team.id
        assert body["data"]["attributes"]["slug"] == "slugged-team"
        assert body["data"]["attributes"]["status"] == "active"
      end

      test "cannot get draft team by slug on public endpoint", %{site: site} do
        _draft_team =
          create_team!(site_id: site.id, name: "Draft Team", slug: "draft-slug", status: :draft)

        response =
          make_api_request(
            "#{@api_public_path}/by-slug/draft-slug",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 404
      end

      test "returns 404 for non-existent slug on public endpoint", %{site: _site} do
        response =
          make_api_request(
            "#{@api_public_path}/by-slug/non-existent-slug",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 404
      end

      test "public list respects pagination", %{site: site} do
        # Create multiple active teams
        _teams =
          Enum.map(1..15, fn i ->
            create_team!(
              site_id: site.id,
              name: "Team #{i}",
              slug: "team-#{i}",
              status: :active
            )
          end)

        # Request first page with limit 5
        response =
          make_api_request(
            "#{@api_public_path}?page[limit]=5&page[offset]=0",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 5
      end
    end

    describe "Paginated included relationships - Team with members" do
      test "tenant admin can include paginated members", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        # Create team
        team = create_team!(site_id: site.id, name: "Team with Members", status: :active)

        # Create multiple bloggers and add them as members
        blogger_ids =
          Enum.map(1..20, fn i ->
            blogger =
              create_blogger!(
                site_id: site.id,
                display_name: "Member #{i}",
                slug: "member-#{i}"
              )

            create_team_member!(team_id: team.id, blogger_id: blogger.id)
            blogger.id
          end)

        # Fetch team with paginated members (limit 10)
        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}?include=tenant_members&included_page[tenant_members][limit]=10&included_page[tenant_members][offset]=0",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify team data
        assert body["data"]["id"] == team.id
        assert body["data"]["attributes"]["name"] == "Team with Members"

        # Verify included members (should be limited to 10)
        assert is_list(body["included"])
        member_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)
        assert length(member_records) == 10

        # Verify all included members are from our created list
        included_ids = Enum.map(member_records, & &1["id"])
        Enum.each(included_ids, fn id -> assert id in blogger_ids end)
      end

      test "tenant admin can paginate through members using offset", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        # Create team with many members
        team = create_team!(site_id: site.id, name: "Large Team", status: :active)

        # Create 25 bloggers as members
        _blogger_ids =
          Enum.map(1..25, fn i ->
            blogger =
              create_blogger!(
                site_id: site.id,
                display_name: "Member #{i}",
                slug: "large-member-#{i}"
              )

            create_team_member!(team_id: team.id, blogger_id: blogger.id)
            blogger.id
          end)

        # Fetch second page (offset 10, limit 10)
        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}?include=tenant_members&included_page[tenant_members][limit]=10&included_page[tenant_members][offset]=10",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify included members (should be 10 members from offset 10)
        member_records =
          Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)

        assert length(member_records) == 10
      end

      test "master admin can include paginated master_members", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create team
        team = create_team!(site_id: site.id, name: "Master Team", status: :active)

        # Create multiple bloggers as members
        _blogger_ids =
          Enum.map(1..15, fn i ->
            blogger =
              create_blogger!(
                site_id: site.id,
                display_name: "Master Member #{i}",
                slug: "master-member-#{i}"
              )

            create_team_member!(team_id: team.id, blogger_id: blogger.id)
            blogger.id
          end)

        # Fetch team with paginated master_members
        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}?include=master_members&included_page[master_members][limit]=10",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify included members
        member_records =
          Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)

        assert length(member_records) == 10
      end

      test "public can include paginated members (public relationship)", %{site: site} do
        # Create team
        team = create_team!(site_id: site.id, name: "Public Team Members", status: :active)

        # Create multiple bloggers as members
        blogger_ids =
          Enum.map(1..30, fn i ->
            blogger =
              create_blogger!(
                site_id: site.id,
                display_name: "Public Member #{i}",
                slug: "public-member-#{i}"
              )

            create_team_member!(team_id: team.id, blogger_id: blogger.id)
            blogger.id
          end)

        # Fetch team with paginated members (public endpoint)
        response =
          make_api_request(
            "#{@api_public_path}/#{team.id}?include=members&included_page[members][limit]=15&included_page[members][offset]=0",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify team data
        assert body["data"]["id"] == team.id

        # Verify included members (limited to 15)
        member_records =
          Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)

        assert length(member_records) == 15

        # Verify all included members are from our created list
        included_ids = Enum.map(member_records, & &1["id"])
        Enum.each(included_ids, fn id -> assert id in blogger_ids end)
      end

      test "pagination without include parameter does not error", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        team = create_team!(site_id: site.id, name: "Team", status: :active)

        # Request with pagination params but no include
        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}?included_page[tenant_members][limit]=10",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == team.id
        # No included data expected
        assert is_nil(body["included"]) or body["included"] == []
      end

      test "can include nested relationships with pagination", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        # Create team with members
        team = create_team!(site_id: site.id, name: "Team Nested", status: :active)
        user1 = create_user!(site_id: site.id)
        user2 = create_user!(site_id: site.id)

        blogger1 = create_blogger!(site_id: site.id, user_id: user1.id, slug: "nested-1")
        blogger2 = create_blogger!(site_id: site.id, user_id: user2.id, slug: "nested-2")

        create_team_member!(team_id: team.id, blogger_id: blogger1.id)
        create_team_member!(team_id: team.id, blogger_id: blogger2.id)

        # Fetch team with members and their users
        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}?include=tenant_members.user&included_page[tenant_members][limit]=10",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify included data contains both bloggers and users
        assert is_list(body["included"])
        blogger_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)
        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)

        assert length(blogger_records) == 2
        assert length(user_records) == 2
      end
    end

    describe "Paginated nested relationships - Team with members.user" do
      test "public can include members.user with pagination", %{site: site} do
        # Create active team
        team =
          create_team!(
            site_id: site.id,
            name: "Public Team",
            slug: "public-team",
            status: :active
          )

        # Create multiple users and bloggers
        members_data =
          Enum.map(1..20, fn i ->
            user = create_user!(site_id: site.id, email: "member#{i}@example.com")

            blogger =
              create_blogger!(
                site_id: site.id,
                user_id: user.id,
                display_name: "Member #{i}",
                slug: "public-member-#{i}"
              )

            create_team_member!(team_id: team.id, blogger_id: blogger.id, role: "member")
            %{user_id: user.id, blogger_id: blogger.id}
          end)

        # Fetch team with paginated members and their users (limit 10)
        response =
          make_api_request(
            "#{@api_public_path}/#{team.id}?include=members.user&included_page[members][limit]=10&included_page[members][offset]=0",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify team data
        assert body["data"]["id"] == team.id
        assert body["data"]["attributes"]["name"] == "Public Team"

        # Verify included data contains both bloggers and users
        assert is_list(body["included"])
        blogger_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)
        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)

        # Should have 10 bloggers (due to pagination limit) and 10 corresponding users
        assert length(blogger_records) == 10
        assert length(user_records) == 10

        # Verify that each blogger has a corresponding user in the included data
        blogger_user_ids =
          Enum.map(blogger_records, fn b ->
            b["relationships"]["user"]["data"]["id"]
          end)

        included_user_ids = Enum.map(user_records, & &1["id"])

        Enum.each(blogger_user_ids, fn user_id ->
          assert user_id in included_user_ids,
                 "Blogger's user #{user_id} should be in included users"
        end)

        # Verify all included users are from our created list
        created_user_ids = Enum.map(members_data, & &1.user_id)

        Enum.each(included_user_ids, fn id ->
          assert id in created_user_ids, "Included user #{id} should be from created users"
        end)

        # Members are public profiles; the accounts behind them stay with their owners and admins.
        assert_no_account_fields(response)
      end

      test "public can paginate through members.user using offset", %{site: site} do
        # Create active team
        team =
          create_team!(site_id: site.id, name: "Large Team", slug: "large-team", status: :active)

        # Create 25 members
        _members_data =
          Enum.map(1..25, fn i ->
            user = create_user!(site_id: site.id, email: "large#{i}@example.com")

            blogger =
              create_blogger!(
                site_id: site.id,
                user_id: user.id,
                display_name: "Large Member #{i}",
                slug: "large-member-#{i}"
              )

            create_team_member!(team_id: team.id, blogger_id: blogger.id)
            %{user_id: user.id, blogger_id: blogger.id}
          end)

        # Fetch second page (offset 10, limit 10)
        response =
          make_api_request(
            "#{@api_public_path}/#{team.id}?include=members.user&included_page[members][limit]=10&included_page[members][offset]=10",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify included data
        blogger_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)
        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)

        # Should have 10 bloggers and 10 users from offset 10
        assert length(blogger_records) == 10
        assert length(user_records) == 10

        # Members are public profiles; the accounts behind them stay with their owners and admins.
        assert_no_account_fields(response)
      end

      test "public members.user includes respect team status filter", %{site: site} do
        # Create draft team (should not be accessible)
        draft_team =
          create_team!(site_id: site.id, name: "Draft Team", slug: "draft", status: :draft)

        user = create_user!(site_id: site.id)
        blogger = create_blogger!(site_id: site.id, user_id: user.id, slug: "draft-member")
        create_team_member!(team_id: draft_team.id, blogger_id: blogger.id)

        # Try to fetch draft team with members
        response =
          make_api_request(
            "#{@api_public_path}/#{draft_team.id}?include=members.user&included_page[members][limit]=10",
            %{},
            method: :get,
            headers: []
          )

        # Should get 404 because team is draft
        assert response.status == 404
      end

      test "tenant admin can include tenant_members.user with pagination", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        # Create team
        team = create_team!(site_id: site.id, name: "Tenant Team", status: :active)

        # Create 15 members
        _members_data =
          Enum.map(1..15, fn i ->
            user = create_user!(site_id: site.id, email: "tenant#{i}@example.com")

            blogger =
              create_blogger!(
                site_id: site.id,
                user_id: user.id,
                display_name: "Tenant Member #{i}",
                slug: "tenant-member-#{i}"
              )

            create_team_member!(team_id: team.id, blogger_id: blogger.id, role: "editor")
            %{user_id: user.id, blogger_id: blogger.id}
          end)

        # Fetch team with paginated tenant_members and users (limit 10)
        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}?include=tenant_members.user&included_page[tenant_members][limit]=10",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify team data
        assert body["data"]["id"] == team.id

        # Verify included data
        blogger_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)
        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)

        # Should have 10 bloggers and 10 users
        assert length(blogger_records) == 10
        assert length(user_records) == 10

        # Verify relationships are properly linked
        blogger_user_ids =
          Enum.map(blogger_records, fn b ->
            b["relationships"]["user"]["data"]["id"]
          end)

        included_user_ids = Enum.map(user_records, & &1["id"])

        Enum.each(blogger_user_ids, fn user_id ->
          assert user_id in included_user_ids
        end)

        # An admin still gets the accounts behind the profiles.
        assert Enum.all?(user_records, &(&1["attributes"]["email"] =~ "@example.com"))
      end

      test "master admin can include master_members.user with pagination bypassing tenant", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create team
        team = create_team!(site_id: site.id, name: "Master Team", status: :active)

        # Create 12 members
        members_data =
          Enum.map(1..12, fn i ->
            user = create_user!(site_id: site.id, email: "master#{i}@example.com")

            blogger =
              create_blogger!(
                site_id: site.id,
                user_id: user.id,
                display_name: "Master Member #{i}",
                slug: "master-member-#{i}"
              )

            create_team_member!(team_id: team.id, blogger_id: blogger.id)
            %{user_id: user.id, blogger_id: blogger.id}
          end)

        # Fetch team with paginated master_members and users
        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}?include=master_members.user&included_page[master_members][limit]=10",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify included data
        blogger_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)
        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)

        # Should have 10 bloggers and 10 users (limited by pagination)
        assert length(blogger_records) == 10
        assert length(user_records) == 10

        # Verify all users are properly linked
        created_user_ids = Enum.map(members_data, & &1.user_id)
        included_user_ids = Enum.map(user_records, & &1["id"])

        Enum.each(included_user_ids, fn id ->
          assert id in created_user_ids
        end)
      end

      test "pagination limit applies to members, users auto-included", %{site: site} do
        # Create active team
        team = create_team!(site_id: site.id, name: "Limit Test", status: :active)

        # Create 8 members
        Enum.each(1..8, fn i ->
          user = create_user!(site_id: site.id, email: "limit#{i}@example.com")

          blogger =
            create_blogger!(
              site_id: site.id,
              user_id: user.id,
              display_name: "Limit Member #{i}",
              slug: "limit-member-#{i}"
            )

          create_team_member!(team_id: team.id, blogger_id: blogger.id)
        end)

        # Fetch with limit 5 on members
        response =
          make_api_request(
            "#{@api_public_path}/#{team.id}?include=members.user&included_page[members][limit]=5",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        blogger_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)
        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)

        # Limit of 5 should apply to members (bloggers), and automatically include their 5 users
        assert length(blogger_records) == 5
        assert length(user_records) == 5

        # Members are public profiles; the accounts behind them stay with their owners and admins.
        assert_no_account_fields(response)
      end

      test "can fetch members.user with different page sizes", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        # Create team with 30 members
        team = create_team!(site_id: site.id, name: "Page Size Test", status: :active)

        Enum.each(1..30, fn i ->
          user = create_user!(site_id: site.id, email: "pagesize#{i}@example.com")

          blogger =
            create_blogger!(
              site_id: site.id,
              user_id: user.id,
              display_name: "Page Member #{i}",
              slug: "page-member-#{i}"
            )

          create_team_member!(team_id: team.id, blogger_id: blogger.id)
        end)

        # Test with limit 25
        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}?include=tenant_members.user&included_page[tenant_members][limit]=25",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        blogger_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)
        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)

        assert length(blogger_records) == 25
        assert length(user_records) == 25
      end

      test "supports nested path notation for pagination (doc pattern)", %{site: site} do
        # Create active team
        team = create_team!(site_id: site.id, name: "Nested Path Team", status: :active)

        # Create 18 members
        Enum.each(1..18, fn i ->
          user = create_user!(site_id: site.id, email: "nested#{i}@example.com")

          blogger =
            create_blogger!(
              site_id: site.id,
              user_id: user.id,
              display_name: "Nested Member #{i}",
              slug: "nested-path-#{i}"
            )

          create_team_member!(team_id: team.id, blogger_id: blogger.id)
        end)

        # Using nested path notation: included_page[members.user][limit]=12
        # This is equivalent to included_page[members][limit]=12 in this case
        # since user is a belongs_to relationship (1-to-1)
        response =
          make_api_request(
            "#{@api_public_path}/#{team.id}?include=members.user&included_page[members][limit]=12",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        blogger_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)
        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)

        # Should respect the limit
        assert length(blogger_records) == 12
        assert length(user_records) == 12

        # Verify each blogger has their user included
        Enum.each(blogger_records, fn blogger ->
          user_id = blogger["relationships"]["user"]["data"]["id"]

          assert Enum.any?(user_records, fn user -> user["id"] == user_id end),
                 "Blogger #{blogger["id"]} should have their user #{user_id} in included data"
        end)

        # Members are public profiles; the accounts behind them stay with their owners and admins.
        assert_no_account_fields(response)
      end

      test "can combine pagination with offset using nested relationships", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        # Create team with 40 members
        team = create_team!(site_id: site.id, name: "Combined Test", status: :active)

        _created_data =
          Enum.map(1..40, fn i ->
            user = create_user!(site_id: site.id, email: "combined#{i}@example.com")

            blogger =
              create_blogger!(
                site_id: site.id,
                user_id: user.id,
                display_name: "Combined #{i}",
                slug: "combined-#{i}"
              )

            create_team_member!(team_id: team.id, blogger_id: blogger.id)
            %{user_id: user.id, blogger_id: blogger.id}
          end)

        # Fetch page 1: offset 0, limit 15
        response1 =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}?include=tenant_members.user&included_page[tenant_members][limit]=15&included_page[tenant_members][offset]=0",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response1.status == 200
        body1 = Jason.decode!(response1.resp_body)

        blogger_records1 = Enum.filter(body1["included"], fn inc -> inc["type"] == "blogger" end)
        user_records1 = Enum.filter(body1["included"], fn inc -> inc["type"] == "user" end)
        assert length(blogger_records1) == 15
        assert length(user_records1) == 15

        # Fetch page 2: offset 15, limit 15
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}?include=tenant_members.user&included_page[tenant_members][limit]=15&included_page[tenant_members][offset]=15",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)

        blogger_records2 = Enum.filter(body2["included"], fn inc -> inc["type"] == "blogger" end)
        user_records2 = Enum.filter(body2["included"], fn inc -> inc["type"] == "user" end)
        assert length(blogger_records2) == 15
        assert length(user_records2) == 15

        # Verify no overlap between pages
        blogger_ids1 = Enum.map(blogger_records1, & &1["id"])
        blogger_ids2 = Enum.map(blogger_records2, & &1["id"])

        overlap = Enum.filter(blogger_ids1, fn id -> id in blogger_ids2 end)
        assert overlap == [], "Pages should not have overlapping bloggers"

        # Fetch page 3: offset 30, limit 15 (should get remaining 10)
        response3 =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}?include=tenant_members.user&included_page[tenant_members][limit]=15&included_page[tenant_members][offset]=30",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response3.status == 200
        body3 = Jason.decode!(response3.resp_body)

        blogger_records3 = Enum.filter(body3["included"], fn inc -> inc["type"] == "blogger" end)
        user_records3 = Enum.filter(body3["included"], fn inc -> inc["type"] == "user" end)
        assert length(blogger_records3) == 10
        assert length(user_records3) == 10
      end
    end

    describe "VERSION MANAGEMENT - GET /team/:id/with-versions" do
      test "tenant admin can get team with paginated versions", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        # Create team and some versions
        team =
          create_team!(
            site_id: site.id,
            name: "Original Team",
            slug: "original-team",
            description: "Original"
          )

        # Update to create versions
        team
        |> Ash.Changeset.for_update(:update, %{description: "Version 1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        team
        |> Ash.Changeset.for_update(:update, %{description: "Version 2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 2 updates = 3 versions)
        wait_for_version_count("mishka_blog_team_versions", team.id, 3)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}/with-versions?fields[team]=name,description,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == team.id
        assert body["data"]["attributes"]["name"] == "Original Team"

        # Check sorted_versions in attributes
        sorted_versions = body["data"]["attributes"]["sorted_versions"]
        assert is_list(sorted_versions)
        assert length(sorted_versions) == 3
      end

      test "tenant admin cannot get team with versions from another site", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin, site)

        team =
          create_team!(
            site_id: site2.id,
            name: "Other Site Team",
            slug: "other-site-team"
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}/with-versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 404
      end

      test "master admin can get any team with versions", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        team1 =
          create_team!(
            site_id: site.id,
            name: "Site1 Team",
            slug: "site1-team"
          )

        team2 =
          create_team!(
            site_id: site2.id,
            name: "Site2 Team",
            slug: "site2-team"
          )

        # Create version for team1
        team1
        |> Ash.Changeset.for_update(:update, %{description: "Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions (team1: 1 create + 1 update = 2, team2: 1 create = 1)
        wait_for_version_count("mishka_blog_team_versions", team1.id, 2)
        wait_for_version_count("mishka_blog_team_versions", team2.id, 1)

        # Get site1 team with versions
        response1 =
          make_api_request(
            "#{@api_master_path}/#{team1.id}/with-versions?fields[team]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response1.status == 200
        body1 = Jason.decode!(response1.resp_body)
        sorted_versions1 = body1["data"]["attributes"]["sorted_versions"]
        assert is_list(sorted_versions1)
        assert length(sorted_versions1) == 2

        # Get site2 team with versions
        response2 =
          make_api_request(
            "#{@api_master_path}/#{team2.id}/with-versions?fields[team]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)
        sorted_versions2 = body2["data"]["attributes"]["sorted_versions"]
        assert is_list(sorted_versions2)
        assert length(sorted_versions2) == 1
      end
    end

    describe "VERSION MANAGEMENT - Calculations (version_count, latest_version, recent_versions)" do
      test "tenant admin can get version calculations for their team", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        team =
          create_team!(
            site_id: site.id,
            name: "Original Team",
            slug: "original-team",
            description: "Desc 1"
          )

        # Create multiple versions
        updated1 =
          team
          |> Ash.Changeset.for_update(:update, %{description: "Desc 2"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        updated2 =
          updated1
          |> Ash.Changeset.for_update(:update, %{description: "Desc 3"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        updated3 =
          updated2
          |> Ash.Changeset.for_update(:update, %{description: "Desc 4"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        _updated4 =
          updated3
          |> Ash.Changeset.for_update(:update, %{description: "Desc 5"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 4 updates = 5 versions)
        wait_for_version_count("mishka_blog_team_versions", team.id, 5)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}?fields[team]=name,description,version_count,latest_version,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Check version_count calculation
        assert body["data"]["attributes"]["version_count"] == 5

        # Check latest_version calculation
        latest_version = body["data"]["attributes"]["latest_version"]
        assert is_map(latest_version)
        assert latest_version["changes"]["description"] == "Desc 5"

        # Check recent_versions calculation (should return up to 10)
        recent_versions = body["data"]["attributes"]["recent_versions"]
        assert is_list(recent_versions)
        assert length(recent_versions) == 5

        # Verify they're sorted descending (newest first)
        descriptions = Enum.map(recent_versions, & &1["changes"]["description"])
        assert Enum.at(descriptions, 0) == "Desc 5"
        assert Enum.at(descriptions, 4) == "Desc 1"
      end

      test "master admin can get version calculations for any team", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        team =
          create_team!(
            site_id: site.id,
            name: "Test Team",
            slug: "test-team",
            description: "V1"
          )

        # Create versions
        updated1 =
          team
          |> Ash.Changeset.for_update(:update, %{description: "V2"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        _updated2 =
          updated1
          |> Ash.Changeset.for_update(:update, %{description: "V3"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions (1 create + 2 updates = 3 versions)
        wait_for_version_count("mishka_blog_team_versions", team.id, 3)

        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}?fields[team]=name,version_count,latest_version,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert body["data"]["attributes"]["version_count"] == 3

        latest = body["data"]["attributes"]["latest_version"]
        assert latest["changes"]["description"] == "V3"

        recent = body["data"]["attributes"]["recent_versions"]
        assert length(recent) == 3
      end

      test "recent_versions limits to 10 versions when more exist", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        team =
          create_team!(
            site_id: site.id,
            name: "Many Versions Team",
            slug: "many-versions-team"
          )

        # Create 12 versions
        updated = team

        updated =
          Enum.reduce(1..12, updated, fn i, acc ->
            acc
            |> Ash.Changeset.for_update(:update, %{description: "Version #{i}"},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.update!()
          end)

        # Wait for versions (1 create + 12 updates = 13 versions)
        wait_for_version_count("mishka_blog_team_versions", team.id, 13)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{updated.id}?fields[team]=version_count,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # version_count should be 13
        assert body["data"]["attributes"]["version_count"] == 13

        # recent_versions should be limited to 10
        recent = body["data"]["attributes"]["recent_versions"]
        assert length(recent) == 10

        # Should be newest 10 (sorted descending)
        descriptions = Enum.map(recent, & &1["changes"]["description"])
        assert Enum.at(descriptions, 0) == "Version 12"
        assert Enum.at(descriptions, 9) == "Version 3"
      end
    end

    describe "VERSION MANAGEMENT - GET /team/:id/versions" do
      test "tenant admin can list versions for their team", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        team =
          create_team!(
            site_id: site.id,
            name: "Original Team",
            slug: "original-team"
          )

        # Create multiple versions - capture updated results
        updated1 =
          team
          |> Ash.Changeset.for_update(:update, %{name: "Team V1"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        updated2 =
          updated1
          |> Ash.Changeset.for_update(:update, %{name: "Team V2"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        _updated3 =
          updated2
          |> Ash.Changeset.for_update(:update, %{name: "Team V3"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 3 updates = 4 versions)
        wait_for_version_count("mishka_blog_team_versions", team.id, 4)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}/versions?fields[team]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Returns 1 team with versions loaded
        assert is_list(body["data"])
        assert length(body["data"]) == 1

        # Check the versions inside the team
        team_data = List.first(body["data"])
        sorted_versions = team_data["attributes"]["sorted_versions"]
        assert is_list(sorted_versions)
        assert length(sorted_versions) == 4
      end

      test "tenant admin cannot list versions from another site's team", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin, site)

        team =
          create_team!(
            site_id: site2.id,
            name: "Other Site Team",
            slug: "other-site-team"
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}/versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 404
      end

      test "master admin can list versions for any team", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        team =
          create_team!(
            site_id: site.id,
            name: "Test Team",
            slug: "test-team"
          )

        # Create versions
        team
        |> Ash.Changeset.for_update(:update, %{name: "Updated Team"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_team_versions", team.id, 2)

        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}/versions?fields[team]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])
        assert length(body["data"]) == 1

        # Check the versions inside the team
        team_data = List.first(body["data"])
        sorted_versions = team_data["attributes"]["sorted_versions"]
        assert is_list(sorted_versions)
        assert length(sorted_versions) == 2
      end
    end

    describe "VERSION MANAGEMENT - PATCH /team/:id/version/:version_id/restore" do
      test "tenant admin can restore their team to a previous version", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        team =
          create_team!(
            site_id: site.id,
            name: "Original Team",
            slug: "original-team",
            description: "Original desc"
          )

        # Create a version
        updated =
          team
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated Team", description: "Updated desc"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_team_versions", team.id, 2)

        # Get the version
        version =
          MishkaBlog.Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^team.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{updated.id}/version/#{version.id}/restore",
            %{"type" => "team", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Original Team"
        assert body["data"]["attributes"]["description"] == "Original desc"
      end

      test "tenant admin cannot restore another site's team version", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin, site)

        team =
          create_team!(
            site_id: site2.id,
            name: "Other Team",
            slug: "other-team"
          )

        # Create version
        team
        |> Ash.Changeset.for_update(:update, %{name: "Updated"},
          tenant: site2.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_team_versions", team.id, 2)

        # Get version
        version =
          MishkaBlog.Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^team.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}/version/#{version.id}/restore",
            %{"type" => "team", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 404
      end

      test "master admin can restore any team version", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        team =
          create_team!(
            site_id: site.id,
            name: "Original Team",
            slug: "original-team"
          )

        # Create version
        updated =
          team
          |> Ash.Changeset.for_update(:update, %{name: "Updated Team"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_team_versions", team.id, 2)

        # Get version
        version =
          MishkaBlog.Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^team.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_master_path}/#{updated.id}/version/#{version.id}/restore",
            %{"type" => "team", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Original Team"
      end

      test "cannot restore version of archived team", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        team =
          create_team!(
            site_id: site.id,
            name: "Original Team",
            slug: "original-team"
          )

        # Create version
        team
        |> Ash.Changeset.for_update(:update, %{name: "Updated Team"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_team_versions", team.id, 2)

        # Archive team
        team
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Get version
        version =
          MishkaBlog.Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^team.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}/version/#{version.id}/restore",
            %{"type" => "team", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status in [400, 404, 422]
      end
    end

    describe "VERSION MANAGEMENT - GET /team/:id/version/:version_id/preview" do
      test "tenant admin can preview a version without restoring", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        team =
          create_team!(
            site_id: site.id,
            name: "Original Team",
            slug: "original-team",
            description: "Original desc"
          )

        # Create version
        updated =
          team
          |> Ash.Changeset.for_update(
            :update,
            %{name: "Updated Team", description: "Updated desc"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_team_versions", team.id, 2)

        # Get version
        version =
          MishkaBlog.Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^team.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Original Team"
        assert body["data"]["attributes"]["description"] == "Original desc"

        # Verify actual team is unchanged
        current_response =
          make_api_request(
            "#{@api_tenant_path}/#{updated.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        current_body = Jason.decode!(current_response.resp_body)
        assert current_body["data"]["attributes"]["name"] == "Updated Team"
      end

      test "tenant admin cannot preview version from another site", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin, site)

        team =
          create_team!(
            site_id: site2.id,
            name: "Other Team",
            slug: "other-team"
          )

        # Create version
        team
        |> Ash.Changeset.for_update(:update, %{name: "Updated"},
          tenant: site2.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_team_versions", team.id, 2)

        # Get version
        version =
          MishkaBlog.Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^team.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{team.id}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status == 404
      end

      test "master admin can preview any team version", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        team =
          create_team!(
            site_id: site.id,
            name: "Original Team",
            slug: "original-team"
          )

        # Create version
        team
        |> Ash.Changeset.for_update(:update, %{name: "Updated Team"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_team_versions", team.id, 2)

        # Get version
        version =
          MishkaBlog.Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^team.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_master_path}/#{team.id}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Original Team"
      end

      test "returns error when version doesn't belong to team", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin, site)

        team1 =
          create_team!(
            site_id: site.id,
            name: "Team 1",
            slug: "team-1"
          )

        team2 =
          create_team!(
            site_id: site.id,
            name: "Team 2",
            slug: "team-2"
          )

        # Create version for team1
        team1
        |> Ash.Changeset.for_update(:update, %{name: "Updated Team 1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions
        wait_for_version_count("mishka_blog_team_versions", team1.id, 2)

        # Get version for team1
        version_team1 =
          MishkaBlog.Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^team1.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        # Try to preview team1's version on team2
        response =
          make_api_request(
            "#{@api_tenant_path}/#{team2.id}/version/#{version_team1.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "false"}],
            host: site.host
          )

        assert response.status in [400, 404, 422]
      end

      test "a team that does not exist is not found, for a tenant admin and a master", %{
        tenant_admin: tenant_admin,
        master_user: master_user,
        site: site
      } do
        team = create_team!(site_id: site.id, name: "Real Team", slug: "real-team")

        team
        |> Ash.Changeset.for_update(:update, %{name: "Real Team 2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_team_versions", team.id, 2)

        version =
          MishkaBlog.Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^team.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        missing = Ash.UUID.generate()

        tenant_response =
          make_api_request(
            "#{@api_tenant_path}/#{missing}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{sign_in_tenant(tenant_admin, site)}"},
              {"x-no-tenant", "false"}
            ],
            host: site.host
          )

        master_response =
          make_api_request(
            "#{@api_master_path}/#{missing}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{sign_in_master(master_user)}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert tenant_response.status == 404
        assert master_response.status == 404
      end
    end
  end
end
