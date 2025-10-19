defmodule MishkaBlogWeb.Api.Json.AutoPostingTest do
  @moduledoc """
  Comprehensive tests for AutoPosting JSON API endpoints.
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
    @api_master_path "/api/json/v1/master/admin/mishka-blog/auto-posting"
    @api_tenant_path "/api/json/v1/tenant/admin/mishka-blog/auto-posting"

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

      # Create regular user without admin permissions
      regular_user =
        create_user!(
          email: "regular@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )

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
        site2_admin: site2_admin,
        regular_user: regular_user
      }
    end

    # Helper function to sign in and get token
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

    defp sign_in_tenant(tenant_user) do
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(tenant_user.email),
              "password" => @password
            }
          }
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)
      token
    end

    describe "CREATE - POST /auto-posting" do
      test "master admin can create auto posting for any site", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        # Create auto posting for site1
        response =
          make_api_request(
            @api_master_path,
            %{
              "type" => "auto_posting",
              "attributes" => %{
                "name" => "Twitter Auto Post Site1",
                "plugin" => "twitter_plugin",
                "description" => "Auto post to Twitter for site1",
                "is_active" => false,
                "config" => %{
                  "api_key" => %{"type" => "string", "value" => "secret123"},
                  "interval" => %{"type" => "integer", "value" => 3600}
                },
                "site_id" => site.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Twitter Auto Post Site1"
        assert body["data"]["attributes"]["plugin"] == "twitter_plugin"
        assert body["data"]["attributes"]["is_active"] == false
        assert body["data"]["attributes"]["site_id"] == site.id

        # Create auto posting for site2
        response2 =
          make_api_request(
            @api_master_path,
            %{
              "type" => "auto_posting",
              "attributes" => %{
                "name" => "LinkedIn Auto Post Site2",
                "plugin" => "linkedin_plugin",
                "description" => "Auto post to LinkedIn for site2",
                "is_active" => true,
                "config" => %{},
                "site_id" => site2.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 201
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["attributes"]["plugin"] == "linkedin_plugin"
        assert body2["data"]["attributes"]["site_id"] == site2.id
      end

      test "tenant admin can create auto posting only for their own site", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        # Successfully create auto posting for their own site (site_id auto-assigned from tenant)
        response =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "auto_posting",
              "attributes" => %{
                "name" => "Facebook Auto Post",
                "plugin" => "facebook_plugin",
                "description" => "Auto post to Facebook",
                "is_active" => false,
                "config" => %{}
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Facebook Auto Post"
        assert body["data"]["attributes"]["site_id"] == site.id

        # Tenant users cannot send site_id - it's auto-assigned from their user
        # Attempting to send site_id should fail with validation error
        response2 =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "auto_posting",
              "attributes" => %{
                "name" => "Invalid Request",
                "plugin" => "invalid_plugin",
                "is_active" => false,
                "config" => %{},
                "site_id" => site2.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        # Should fail because tenant users cannot provide site_id
        assert response2.status == 400
        body2 = Jason.decode!(response2.resp_body)
        assert body2["errors"]
      end
    end

    describe "READ - GET /auto-posting (list and get)" do
      test "master admin can list auto postings from all sites", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        # Create auto postings for different sites
        auto_posting1 = create_auto_posting!(site_id: site.id, plugin: "plugin1", name: "AP1")
        auto_posting2 = create_auto_posting!(site_id: site2.id, plugin: "plugin2", name: "AP2")

        response =
          make_api_request(
            @api_master_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])
        assert length(body["data"]) >= 2

        ids = Enum.map(body["data"], & &1["id"])
        assert auto_posting1.id in ids
        assert auto_posting2.id in ids
      end

      test "tenant admin can list only their own site's auto postings", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        # Create auto postings for different sites
        auto_posting1 = create_auto_posting!(site_id: site.id, plugin: "plugin1", name: "AP1")
        auto_posting2 = create_auto_posting!(site_id: site2.id, plugin: "plugin2", name: "AP2")

        response =
          make_api_request(
            @api_tenant_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])

        ids = Enum.map(body["data"], & &1["id"])
        assert auto_posting1.id in ids
        refute auto_posting2.id in ids
      end

      test "master admin can get any auto posting by id", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        auto_posting = create_auto_posting!(site_id: site.id, plugin: "test_plugin")

        response =
          make_api_request(
            "#{@api_master_path}/#{auto_posting.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == auto_posting.id
        assert body["data"]["attributes"]["plugin"] == "test_plugin"
      end

      test "tenant admin can get only their own site's auto posting", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting1 = create_auto_posting!(site_id: site.id, plugin: "plugin1")
        auto_posting2 = create_auto_posting!(site_id: site2.id, plugin: "plugin2")

        # Can get own site's auto posting
        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting1.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == auto_posting1.id

        # Cannot get another site's auto posting
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting2.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end

      test "master admin can get auto posting by plugin from any site", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        create_auto_posting!(site_id: site.id, plugin: "twitter_plugin", name: "Site1 Twitter")
        create_auto_posting!(site_id: site2.id, plugin: "facebook_plugin", name: "Site2 Facebook")

        response =
          make_api_request(
            "#{@api_master_path}/by-plugin/twitter_plugin",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["plugin"] == "twitter_plugin"
        assert body["data"]["attributes"]["name"] == "Site1 Twitter"
      end

      test "tenant admin can get auto posting by plugin for their site", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        create_auto_posting!(site_id: site.id, plugin: "instagram_plugin", name: "Instagram AP")

        response =
          make_api_request(
            "#{@api_tenant_path}/by-plugin/instagram_plugin",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["plugin"] == "instagram_plugin"
      end

      test "master admin can list all active auto postings from all sites", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        active1 =
          create_auto_posting!(
            site_id: site.id,
            plugin: "plugin1",
            is_active: true,
            name: "Active1"
          )

        _inactive =
          create_auto_posting!(
            site_id: site.id,
            plugin: "plugin2",
            is_active: false,
            name: "Inactive"
          )

        active2 =
          create_auto_posting!(
            site_id: site2.id,
            plugin: "plugin3",
            is_active: true,
            name: "Active2"
          )

        response =
          make_api_request(
            "#{@api_master_path}/active",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])

        ids = Enum.map(body["data"], & &1["id"])
        assert active1.id in ids
        assert active2.id in ids

        # All should be active
        Enum.each(body["data"], fn auto_posting ->
          assert auto_posting["attributes"]["is_active"] == true
        end)
      end

      test "tenant admin can list active auto postings for their site only", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        active_own =
          create_auto_posting!(
            site_id: site.id,
            plugin: "plugin1",
            is_active: true,
            name: "Active"
          )

        _active_other =
          create_auto_posting!(
            site_id: site2.id,
            plugin: "plugin2",
            is_active: true,
            name: "ActiveOther"
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/active",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert active_own.id in ids
        # Should not include site2's active auto posting
      end
    end

    describe "UPDATE - PATCH /auto-posting" do
      test "master admin can update any auto posting", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        auto_posting =
          create_auto_posting!(site_id: site.id, plugin: "test_plugin", name: "Old Name")

        response =
          make_api_request(
            "#{@api_master_path}/#{auto_posting.id}",
            %{
              "type" => "auto_posting",
              "attributes" => %{
                "name" => "Updated Name",
                "description" => "Updated description"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Updated Name"
        assert body["data"]["attributes"]["description"] == "Updated description"
      end

      test "tenant admin can update only their own site's auto posting", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting_own = create_auto_posting!(site_id: site.id, plugin: "plugin1", name: "Own")

        auto_posting_other =
          create_auto_posting!(site_id: site2.id, plugin: "plugin2", name: "Other")

        # Can update own site's auto posting
        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting_own.id}",
            %{
              "type" => "auto_posting",
              "attributes" => %{
                "name" => "Updated Own"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Updated Own"

        # Cannot update another site's auto posting
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting_other.id}",
            %{
              "type" => "auto_posting",
              "attributes" => %{
                "name" => "Hacked"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end

      test "master admin can activate any auto posting", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        auto_posting =
          create_auto_posting!(site_id: site.id, plugin: "test_plugin", is_active: false)

        response =
          make_api_request(
            "#{@api_master_path}/#{auto_posting.id}/activate",
            %{
              "type" => "auto_posting",
              "attributes" => %{}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["is_active"] == true
      end

      test "tenant admin can activate their own site's auto posting", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting =
          create_auto_posting!(site_id: site.id, plugin: "test_plugin", is_active: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting.id}/activate",
            %{
              "type" => "auto_posting",
              "attributes" => %{}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["is_active"] == true
      end

      test "master admin can deactivate any auto posting", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        auto_posting =
          create_auto_posting!(site_id: site.id, plugin: "test_plugin", is_active: true)

        response =
          make_api_request(
            "#{@api_master_path}/#{auto_posting.id}/deactivate",
            %{
              "type" => "auto_posting",
              "attributes" => %{}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["is_active"] == false
      end

      test "tenant admin can deactivate their own site's auto posting", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting =
          create_auto_posting!(site_id: site.id, plugin: "test_plugin", is_active: true)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting.id}/deactivate",
            %{
              "type" => "auto_posting",
              "attributes" => %{}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["is_active"] == false
      end
    end

    describe "DELETE - Soft delete (archive)" do
      test "master admin can archive any auto posting", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        auto_posting = create_auto_posting!(site_id: site.id, plugin: "test_plugin")

        response =
          make_api_request(
            "#{@api_master_path}/#{auto_posting.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200

        # Verify it's archived (not in regular list)
        list_response =
          make_api_request(
            @api_master_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        list_body = Jason.decode!(list_response.resp_body)
        ids = Enum.map(list_body["data"], & &1["id"])
        refute auto_posting.id in ids
      end

      test "tenant admin can archive their own site's auto posting", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting_own = create_auto_posting!(site_id: site.id, plugin: "plugin1")
        auto_posting_other = create_auto_posting!(site_id: site2.id, plugin: "plugin2")

        # Can archive own site's auto posting
        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting_own.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot archive another site's auto posting
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting_other.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "ARCHIVED - Working with archived records" do
      test "master admin can list archived auto postings from all sites", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        # Create and archive auto postings
        auto_posting1 = create_auto_posting!(site_id: site.id, plugin: "plugin1")
        auto_posting2 = create_auto_posting!(site_id: site2.id, plugin: "plugin2")

        # Archive them
        auto_posting1
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        auto_posting2
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site2.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_master_path}/archived",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])

        ids = Enum.map(body["data"], & &1["id"])
        assert auto_posting1.id in ids
        assert auto_posting2.id in ids
      end

      test "tenant admin can list archived auto postings for their site only", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        # Create and archive auto postings
        auto_posting_own = create_auto_posting!(site_id: site.id, plugin: "plugin1")
        auto_posting_other = create_auto_posting!(site_id: site2.id, plugin: "plugin2")

        auto_posting_own
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        auto_posting_other
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site2.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_tenant_path}/archived",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert auto_posting_own.id in ids
        refute auto_posting_other.id in ids
      end

      test "master admin can get archived auto posting from any site", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        auto_posting = create_auto_posting!(site_id: site.id, plugin: "test_plugin")

        # Archive it
        auto_posting
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_master_path}/archived/#{auto_posting.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == auto_posting.id
      end

      test "tenant admin can get archived auto posting from their site", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        auto_posting = create_auto_posting!(site_id: site.id, plugin: "test_plugin")

        # Archive it
        auto_posting
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_tenant_path}/archived/#{auto_posting.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == auto_posting.id
      end

      test "master admin can unarchive any auto posting", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        auto_posting = create_auto_posting!(site_id: site.id, plugin: "test_plugin")

        # Archive it first
        auto_posting
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Unarchive it
        response =
          make_api_request(
            "#{@api_master_path}/#{auto_posting.id}/unarchive",
            %{
              "type" => "auto_posting",
              "attributes" => %{}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == auto_posting.id

        # Verify it's back in regular list
        list_response =
          make_api_request(
            @api_master_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        list_body = Jason.decode!(list_response.resp_body)
        ids = Enum.map(list_body["data"], & &1["id"])
        assert auto_posting.id in ids
      end

      test "tenant admin can unarchive their own site's auto posting", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        auto_posting = create_auto_posting!(site_id: site.id, plugin: "test_plugin")

        # Archive it first
        auto_posting
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Unarchive it
        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting.id}/unarchive",
            %{
              "type" => "auto_posting",
              "attributes" => %{}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == auto_posting.id
      end
    end

    describe "DELETE - Permanent deletion" do
      test "master admin can permanently delete any auto posting", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        auto_posting = create_auto_posting!(site_id: site.id, plugin: "test_plugin")
        auto_posting_id = auto_posting.id

        response =
          make_api_request(
            "#{@api_master_path}/#{auto_posting_id}/permanent",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200

        # Verify it's completely gone (not even in archived)
        archived_response =
          make_api_request(
            "#{@api_master_path}/archived",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        archived_body = Jason.decode!(archived_response.resp_body)
        archived_ids = Enum.map(archived_body["data"], & &1["id"])
        refute auto_posting_id in archived_ids
      end

      test "tenant admin can permanently delete their own site's auto posting", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting_own = create_auto_posting!(site_id: site.id, plugin: "plugin1")
        auto_posting_other = create_auto_posting!(site_id: site2.id, plugin: "plugin2")

        # Can permanently delete own site's auto posting
        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting_own.id}/permanent",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot permanently delete another site's auto posting
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting_other.id}/permanent",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "VERSION MANAGEMENT - GET /auto-posting/:id/with-versions" do
      test "tenant admin can get auto-posting with paginated versions", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Create auto-posting and some versions
        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Original",
            plugin: "twitter",
            description: "Original"
          )

        # Update to create versions
        auto_posting
        |> Ash.Changeset.for_update(:update, %{description: "Version 1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        auto_posting
        |> Ash.Changeset.for_update(:update, %{description: "Version 2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 2 updates = 3 versions)
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 3)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting.id}/with-versions?fields[auto_posting]=name,description,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == auto_posting.id
        assert body["data"]["attributes"]["name"] == "Original"

        # Check sorted_versions in attributes
        sorted_versions = body["data"]["attributes"]["sorted_versions"]
        assert is_list(sorted_versions)
        assert length(sorted_versions) == 3
      end

      test "tenant admin cannot get auto-posting with versions from another site", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting =
          create_auto_posting!(
            site_id: site2.id,
            name: "Other Site",
            plugin: "twitter"
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting.id}/with-versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can get any auto-posting with versions", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        auto_posting1 =
          create_auto_posting!(
            site_id: site.id,
            name: "Site1 Config",
            plugin: "twitter"
          )

        auto_posting2 =
          create_auto_posting!(
            site_id: site2.id,
            name: "Site2 Config",
            plugin: "facebook"
          )

        # Create version for auto_posting1
        auto_posting1
        |> Ash.Changeset.for_update(:update, %{description: "Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions (auto_posting1: 1 create + 1 update = 2, auto_posting2: 1 create = 1)
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting1.id, 2)
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting2.id, 1)

        # Get site1 auto-posting with versions
        response1 =
          make_api_request(
            "#{@api_master_path}/#{auto_posting1.id}/with-versions?fields[auto_posting]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response1.status == 200
        body1 = Jason.decode!(response1.resp_body)
        sorted_versions1 = body1["data"]["attributes"]["sorted_versions"]
        assert is_list(sorted_versions1)
        assert length(sorted_versions1) == 2

        # Get site2 auto-posting with versions
        response2 =
          make_api_request(
            "#{@api_master_path}/#{auto_posting2.id}/with-versions?fields[auto_posting]=name,sorted_versions",
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
      test "tenant admin can load version calculations", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Original",
            plugin: "twitter"
          )

        # Create additional versions
        Enum.each(1..3, fn i ->
          auto_posting
          |> Ash.Changeset.for_update(:update, %{description: "Update #{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end)

        # Wait for versions (1 create + 3 updates = 4 versions)
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 4)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting.id}?fields[auto_posting]=name,version_count,latest_version,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        attrs = body["data"]["attributes"]

        # Check version_count
        assert attrs["version_count"] == 4

        # Check latest_version
        assert is_map(attrs["latest_version"])
        assert attrs["latest_version"]["changes"]["description"] == "Update 3"

        # Check recent_versions
        assert is_list(attrs["recent_versions"])
        assert length(attrs["recent_versions"]) == 4
      end

      test "tenant admin cannot load calculations for another site's auto-posting", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting =
          create_auto_posting!(
            site_id: site2.id,
            name: "Other Site",
            plugin: "twitter"
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting.id}?fields[auto_posting]=version_count",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can load calculations for any auto-posting", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        auto_posting1 =
          create_auto_posting!(
            site_id: site.id,
            name: "Site1",
            plugin: "twitter"
          )

        auto_posting2 =
          create_auto_posting!(
            site_id: site2.id,
            name: "Site2",
            plugin: "facebook"
          )

        # Create versions
        auto_posting1
        |> Ash.Changeset.for_update(:update, %{description: "Updated 1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        auto_posting2
        |> Ash.Changeset.for_update(:update, %{description: "Updated 2"},
          tenant: site2.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting1.id, 2)
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting2.id, 2)

        # Get site1 auto-posting
        response1 =
          make_api_request(
            "#{@api_master_path}/#{auto_posting1.id}?fields[auto_posting]=version_count,latest_version",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response1.status == 200
        body1 = Jason.decode!(response1.resp_body)
        assert body1["data"]["attributes"]["version_count"] == 2

        assert body1["data"]["attributes"]["latest_version"]["changes"]["description"] ==
                 "Updated 1"

        # Get site2 auto-posting
        response2 =
          make_api_request(
            "#{@api_master_path}/#{auto_posting2.id}?fields[auto_posting]=version_count,latest_version",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["attributes"]["version_count"] == 2

        assert body2["data"]["attributes"]["latest_version"]["changes"]["description"] ==
                 "Updated 2"
      end
    end

    describe "VERSION MANAGEMENT - GET /auto-posting/:auto_posting_id/versions" do
      test "tenant admin can list versions for their auto-posting", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Test",
            plugin: "twitter"
          )

        # Create versions
        Enum.each(1..5, fn i ->
          auto_posting
          |> Ash.Changeset.for_update(:update, %{description: "Version #{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end)

        # Wait for versions (1 create + 5 updates = 6 versions)
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 6)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting.id}/versions?fields[auto_posting]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Returns 1 auto_posting with versions loaded
        assert is_list(body["data"])
        assert length(body["data"]) == 1

        # Check the versions inside the auto_posting
        auto_posting_data = List.first(body["data"])
        sorted_versions = auto_posting_data["attributes"]["sorted_versions"]
        assert is_list(sorted_versions)
        assert length(sorted_versions) == 6
      end

      test "tenant admin cannot list versions for another site's auto-posting", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting =
          create_auto_posting!(
            site_id: site2.id,
            name: "Other",
            plugin: "twitter"
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting.id}/versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can list versions for any auto-posting", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        auto_posting1 =
          create_auto_posting!(
            site_id: site.id,
            name: "Site1",
            plugin: "twitter"
          )

        auto_posting2 =
          create_auto_posting!(
            site_id: site2.id,
            name: "Site2",
            plugin: "facebook"
          )

        # Create versions
        auto_posting1
        |> Ash.Changeset.for_update(:update, %{description: "Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting1.id, 2)
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting2.id, 1)

        # List site1 versions
        response1 =
          make_api_request(
            "#{@api_master_path}/#{auto_posting1.id}/versions?fields[auto_posting]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response1.status == 200
        body1 = Jason.decode!(response1.resp_body)
        assert length(body1["data"]) == 1
        auto_posting1_data = List.first(body1["data"])
        sorted_versions1 = auto_posting1_data["attributes"]["sorted_versions"]
        assert length(sorted_versions1) == 2

        # List site2 versions
        response2 =
          make_api_request(
            "#{@api_master_path}/#{auto_posting2.id}/versions?fields[auto_posting]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)
        assert length(body2["data"]) == 1
        auto_posting2_data = List.first(body2["data"])
        sorted_versions2 = auto_posting2_data["attributes"]["sorted_versions"]
        assert length(sorted_versions2) == 1
      end
    end

    describe "VERSION MANAGEMENT - PATCH /auto-posting/:id/version/:version_id/restore" do
      test "tenant admin can restore their auto-posting to a previous version", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Original",
            plugin: "twitter",
            description: "Original desc"
          )

        # Create a version
        updated =
          auto_posting
          |> Ash.Changeset.for_update(:update, %{name: "Updated", description: "Updated desc"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 2)

        # Get the version
        version =
          MishkaBlog.AutoPosting.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^auto_posting.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{updated.id}/version/#{version.id}/restore",
            %{"type" => "auto_posting", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Original"
        assert body["data"]["attributes"]["description"] == "Original desc"
      end

      test "tenant admin cannot restore another site's auto-posting version", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting =
          create_auto_posting!(
            site_id: site2.id,
            name: "Other",
            plugin: "twitter"
          )

        # Create version
        auto_posting
        |> Ash.Changeset.for_update(:update, %{name: "Updated"},
          tenant: site2.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 2)

        # Get version
        version =
          MishkaBlog.AutoPosting.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^auto_posting.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting.id}/version/#{version.id}/restore",
            %{"type" => "auto_posting", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can restore any auto-posting version", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Original",
            plugin: "twitter",
            description: "Original desc"
          )

        # Create version
        updated =
          auto_posting
          |> Ash.Changeset.for_update(:update, %{name: "Updated", description: "Updated desc"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 2)

        # Get version
        version =
          MishkaBlog.AutoPosting.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^auto_posting.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_master_path}/#{updated.id}/version/#{version.id}/restore",
            %{"type" => "auto_posting", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Original"
        assert body["data"]["attributes"]["description"] == "Original desc"
      end
    end

    describe "VERSION MANAGEMENT - GET /auto-posting/:auto_posting_id/version/:version_id/preview" do
      test "tenant admin can preview a version without restoring", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Original",
            plugin: "twitter",
            description: "Original desc"
          )

        # Create version
        updated =
          auto_posting
          |> Ash.Changeset.for_update(:update, %{name: "Updated", description: "Updated desc"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 2)

        # Get version
        version =
          MishkaBlog.AutoPosting.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^auto_posting.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting.id}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Original"
        assert body["data"]["attributes"]["description"] == "Original desc"

        # Verify actual auto-posting is unchanged
        current_response =
          make_api_request(
            "#{@api_tenant_path}/#{updated.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        current_body = Jason.decode!(current_response.resp_body)
        assert current_body["data"]["attributes"]["name"] == "Updated"
      end

      test "tenant admin cannot preview version from another site", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        auto_posting =
          create_auto_posting!(
            site_id: site2.id,
            name: "Other",
            plugin: "twitter"
          )

        # Create version
        auto_posting
        |> Ash.Changeset.for_update(:update, %{name: "Updated"},
          tenant: site2.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 2)

        # Get version
        version =
          MishkaBlog.AutoPosting.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^auto_posting.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{auto_posting.id}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can preview any version", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        auto_posting =
          create_auto_posting!(
            site_id: site.id,
            name: "Original",
            plugin: "twitter",
            description: "Original desc"
          )

        # Create version
        updated =
          auto_posting
          |> Ash.Changeset.for_update(:update, %{name: "Updated", description: "Updated desc"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_auto_posting_versions", auto_posting.id, 2)

        # Get version
        version =
          MishkaBlog.AutoPosting.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^auto_posting.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_master_path}/#{auto_posting.id}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Original"
        assert body["data"]["attributes"]["description"] == "Original desc"

        # Verify actual auto-posting is unchanged
        current_response =
          make_api_request(
            "#{@api_master_path}/#{updated.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        current_body = Jason.decode!(current_response.resp_body)
        assert current_body["data"]["attributes"]["name"] == "Updated"
      end
    end
  end
end
