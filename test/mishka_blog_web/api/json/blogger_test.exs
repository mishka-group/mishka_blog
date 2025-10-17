defmodule MishkaBlogWeb.Api.Json.BloggerTest do
  @moduledoc """
  Comprehensive tests for Blogger JSON API endpoints.
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
    @api_master_path "/api/json/v1/master/admin/mishka-blog/blogger"
    @api_tenant_path "/api/json/v1/tenant/admin/mishka-blog/blogger"
    @api_public_path "/api/json/v1/user/mishka-blog/blogger"

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

      # Create regular users for bloggers
      site1_user =
        create_user!(
          email: "site1.user@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )

      site2_user =
        create_user!(
          email: "site2.user@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site2.id
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
        site1_user: site1_user,
        site2_user: site2_user
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

    describe "CREATE - POST /blogger" do
      test "master admin can create blogger for any site", %{
        master_user: master_user,
        site: site,
        site2: site2,
        site1_user: site1_user,
        site2_user: site2_user
      } do
        token = sign_in_master(master_user)

        # Create blogger for site1
        response =
          make_api_request(
            @api_master_path,
            %{
              "type" => "blogger",
              "attributes" => %{
                "user_id" => site1_user.id,
                "display_name" => "John Doe",
                "slug" => "john-doe",
                "bio" => "Tech writer and blogger",
                "avatar_url" => "https://example.com/avatar.jpg",
                "expertise_areas" => ["Technology", "Programming"],
                "can_publish_directly" => true,
                "site_id" => site.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["display_name"] == "John Doe"
        assert body["data"]["attributes"]["slug"] == "john-doe"
        assert body["data"]["attributes"]["can_publish_directly"] == true
        assert body["data"]["attributes"]["site_id"] == site.id

        # Create blogger for site2
        response2 =
          make_api_request(
            @api_master_path,
            %{
              "type" => "blogger",
              "attributes" => %{
                "user_id" => site2_user.id,
                "display_name" => "Jane Smith",
                "slug" => "jane-smith",
                "bio" => "Content creator",
                "can_publish_directly" => false,
                "site_id" => site2.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 201
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["attributes"]["display_name"] == "Jane Smith"
        assert body2["data"]["attributes"]["site_id"] == site2.id
      end

      test "tenant admin can create blogger only for their own site", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2,
        site1_user: site1_user
      } do
        token = sign_in_tenant(tenant_admin)

        # Successfully create blogger for their own site
        response =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "blogger",
              "attributes" => %{
                "user_id" => site1_user.id,
                "display_name" => "Bob Johnson",
                "slug" => "bob-johnson",
                "bio" => "Blogger at site 1",
                "can_publish_directly" => true
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["display_name"] == "Bob Johnson"
        assert body["data"]["attributes"]["site_id"] == site.id

        # Tenant users cannot send site_id - it's auto-assigned from their user
        # Attempting to send site_id should fail with validation error
        response2 =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "blogger",
              "attributes" => %{
                "user_id" => site1_user.id,
                "display_name" => "Invalid Request",
                "slug" => "invalid-slug",
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

    describe "READ - GET /blogger (list and get)" do
      test "master admin can list bloggers from all sites", %{
        master_user: master_user,
        site: site,
        site2: site2,
        site1_user: site1_user,
        site2_user: site2_user
      } do
        token = sign_in_master(master_user)

        # Create bloggers for different sites
        blogger1 =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Blogger 1",
            slug: "blogger-1"
          )

        blogger2 =
          create_blogger!(
            site_id: site2.id,
            user_id: site2_user.id,
            display_name: "Blogger 2",
            slug: "blogger-2"
          )

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
        assert blogger1.id in ids
        assert blogger2.id in ids
      end

      test "tenant admin can list only their own site's bloggers", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2,
        site1_user: site1_user,
        site2_user: site2_user
      } do
        token = sign_in_tenant(tenant_admin)

        # Create bloggers for different sites
        blogger1 =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Own Blogger",
            slug: "own-blogger"
          )

        blogger2 =
          create_blogger!(
            site_id: site2.id,
            user_id: site2_user.id,
            display_name: "Other Blogger",
            slug: "other-blogger"
          )

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
        assert blogger1.id in ids
        refute blogger2.id in ids
      end

      test "master admin can get any blogger by id", %{
        master_user: master_user,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_master(master_user)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Test Blogger",
            slug: "test-blogger"
          )

        response =
          make_api_request(
            "#{@api_master_path}/#{blogger.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == blogger.id
        assert body["data"]["attributes"]["display_name"] == "Test Blogger"
      end

      test "tenant admin can get only their own site's blogger", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2,
        site1_user: site1_user,
        site2_user: site2_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger1 =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Own",
            slug: "own"
          )

        blogger2 =
          create_blogger!(
            site_id: site2.id,
            user_id: site2_user.id,
            display_name: "Other",
            slug: "other"
          )

        # Can get own site's blogger
        response =
          make_api_request(
            "#{@api_tenant_path}/#{blogger1.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == blogger1.id

        # Cannot get another site's blogger
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{blogger2.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end

      test "master admin can get blogger by user_id from any site", %{
        master_user: master_user,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_master(master_user)

        create_blogger!(
          site_id: site.id,
          user_id: site1_user.id,
          display_name: "User Blogger",
          slug: "user-blogger"
        )

        response =
          make_api_request(
            "#{@api_master_path}/by-user/#{site1_user.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["display_name"] == "User Blogger"
        # Verify the blogger is associated with the correct user
        assert body["data"]["relationships"]["user"] != nil
      end

      test "tenant admin can get blogger by user_id for their site", %{
        tenant_admin: tenant_admin,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_tenant(tenant_admin)

        create_blogger!(
          site_id: site.id,
          user_id: site1_user.id,
          display_name: "Site User Blogger",
          slug: "site-user-blogger"
        )

        response =
          make_api_request(
            "#{@api_tenant_path}/by-user/#{site1_user.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["display_name"] == "Site User Blogger"
      end

      test "master admin can get blogger by slug from any site", %{
        master_user: master_user,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_master(master_user)

        create_blogger!(
          site_id: site.id,
          user_id: site1_user.id,
          display_name: "Slug Blogger",
          slug: "slug-blogger"
        )

        response =
          make_api_request(
            "#{@api_master_path}/by-slug/slug-blogger",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["slug"] == "slug-blogger"
        assert body["data"]["attributes"]["display_name"] == "Slug Blogger"
      end

      test "tenant admin can get blogger by slug for their site", %{
        tenant_admin: tenant_admin,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_tenant(tenant_admin)

        create_blogger!(
          site_id: site.id,
          user_id: site1_user.id,
          display_name: "Site Slug Blogger",
          slug: "site-slug-blogger"
        )

        response =
          make_api_request(
            "#{@api_tenant_path}/by-slug/site-slug-blogger",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["slug"] == "site-slug-blogger"
      end
    end

    describe "UPDATE - PATCH /blogger" do
      test "master admin can update any blogger", %{
        master_user: master_user,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_master(master_user)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Old Name",
            slug: "old-name"
          )

        response =
          make_api_request(
            "#{@api_master_path}/#{blogger.id}",
            %{
              "type" => "blogger",
              "attributes" => %{
                "display_name" => "Updated Name",
                "bio" => "Updated biography"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["display_name"] == "Updated Name"
        assert body["data"]["attributes"]["bio"] == "Updated biography"
      end

      test "tenant admin can update only their own site's blogger", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2,
        site1_user: site1_user,
        site2_user: site2_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger_own =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Own",
            slug: "own"
          )

        blogger_other =
          create_blogger!(
            site_id: site2.id,
            user_id: site2_user.id,
            display_name: "Other",
            slug: "other"
          )

        # Can update own site's blogger
        response =
          make_api_request(
            "#{@api_tenant_path}/#{blogger_own.id}",
            %{
              "type" => "blogger",
              "attributes" => %{
                "display_name" => "Updated Own"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["display_name"] == "Updated Own"

        # Cannot update another site's blogger
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{blogger_other.id}",
            %{
              "type" => "blogger",
              "attributes" => %{
                "display_name" => "Hacked"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "DELETE - Soft delete (archive)" do
      test "master admin can archive any blogger", %{
        master_user: master_user,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_master(master_user)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "To Archive",
            slug: "to-archive"
          )

        response =
          make_api_request(
            "#{@api_master_path}/#{blogger.id}/archive",
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
        refute blogger.id in ids
      end

      test "tenant admin can archive their own site's blogger", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2,
        site1_user: site1_user,
        site2_user: site2_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger_own =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Own",
            slug: "own"
          )

        blogger_other =
          create_blogger!(
            site_id: site2.id,
            user_id: site2_user.id,
            display_name: "Other",
            slug: "other"
          )

        # Can archive own site's blogger
        response =
          make_api_request(
            "#{@api_tenant_path}/#{blogger_own.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot archive another site's blogger
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{blogger_other.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "ARCHIVED - Working with archived records" do
      test "master admin can list archived bloggers from all sites", %{
        master_user: master_user,
        site: site,
        site2: site2,
        site1_user: site1_user,
        site2_user: site2_user
      } do
        token = sign_in_master(master_user)

        # Create and archive bloggers
        blogger1 =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Blogger 1",
            slug: "blogger-1"
          )

        blogger2 =
          create_blogger!(
            site_id: site2.id,
            user_id: site2_user.id,
            display_name: "Blogger 2",
            slug: "blogger-2"
          )

        # Archive them
        blogger1
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        blogger2
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
        assert blogger1.id in ids
        assert blogger2.id in ids
      end

      test "tenant admin can list archived bloggers for their site only", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2,
        site1_user: site1_user,
        site2_user: site2_user
      } do
        token = sign_in_tenant(tenant_admin)

        # Create and archive bloggers
        blogger_own =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Own",
            slug: "own"
          )

        blogger_other =
          create_blogger!(
            site_id: site2.id,
            user_id: site2_user.id,
            display_name: "Other",
            slug: "other"
          )

        blogger_own
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        blogger_other
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
        assert blogger_own.id in ids
        refute blogger_other.id in ids
      end

      test "master admin can get archived blogger from any site", %{
        master_user: master_user,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_master(master_user)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Archived",
            slug: "archived"
          )

        # Archive it
        blogger
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_master_path}/archived/#{blogger.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == blogger.id
      end

      test "tenant admin can get archived blogger from their site", %{
        tenant_admin: tenant_admin,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Archived",
            slug: "archived"
          )

        # Archive it
        blogger
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_tenant_path}/archived/#{blogger.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == blogger.id
      end

      test "master admin can unarchive any blogger", %{
        master_user: master_user,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_master(master_user)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "To Unarchive",
            slug: "to-unarchive"
          )

        # Archive it first
        blogger
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Unarchive it
        response =
          make_api_request(
            "#{@api_master_path}/#{blogger.id}/unarchive",
            %{
              "type" => "blogger",
              "attributes" => %{}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == blogger.id

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
        assert blogger.id in ids
      end

      test "tenant admin can unarchive their own site's blogger", %{
        tenant_admin: tenant_admin,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "To Unarchive",
            slug: "to-unarchive"
          )

        # Archive it first
        blogger
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Unarchive it
        response =
          make_api_request(
            "#{@api_tenant_path}/#{blogger.id}/unarchive",
            %{
              "type" => "blogger",
              "attributes" => %{}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == blogger.id
      end
    end

    describe "DELETE - Permanent deletion" do
      test "master admin can permanently delete any blogger", %{
        master_user: master_user,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_master(master_user)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "To Delete",
            slug: "to-delete"
          )

        blogger_id = blogger.id

        response =
          make_api_request(
            "#{@api_master_path}/#{blogger_id}/permanent",
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
        refute blogger_id in archived_ids
      end

      test "tenant admin can permanently delete their own site's blogger", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2,
        site1_user: site1_user,
        site2_user: site2_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger_own =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Own",
            slug: "own"
          )

        blogger_other =
          create_blogger!(
            site_id: site2.id,
            user_id: site2_user.id,
            display_name: "Other",
            slug: "other"
          )

        # Can permanently delete own site's blogger
        response =
          make_api_request(
            "#{@api_tenant_path}/#{blogger_own.id}/permanent",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot permanently delete another site's blogger
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{blogger_other.id}/permanent",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "PUBLIC - Unauthenticated access" do
      test "anyone can list active (non-archived) bloggers", %{
        site: site,
        site1_user: site1_user,
        tenant_admin: tenant_admin
      } do
        # Create active bloggers
        active1 =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Active Blogger 1",
            slug: "active-blogger-1"
          )

        active2 =
          create_blogger!(
            site_id: site.id,
            user_id: create_user!(site_id: site.id).id,
            display_name: "Active Blogger 2",
            slug: "active-blogger-2"
          )

        # Create an archived blogger (should not appear in public list)
        archived =
          create_blogger!(
            site_id: site.id,
            user_id: tenant_admin.id,
            display_name: "Archived Blogger",
            slug: "archived-blogger"
          )

        # Archive it
        archived
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            @api_public_path,
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
        # Archived blogger should not be in the list
        refute archived.id in ids
      end

      test "anyone can get active blogger by id", %{site: site, site1_user: site1_user} do
        active_blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Public Blogger",
            slug: "public-blogger",
            bio: "This is a public bio"
          )

        response =
          make_api_request(
            "#{@api_public_path}/#{active_blogger.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == active_blogger.id
        assert body["data"]["attributes"]["display_name"] == "Public Blogger"
        assert body["data"]["attributes"]["bio"] == "This is a public bio"
      end

      test "anyone can get blogger by slug", %{site: site, site1_user: site1_user} do
        active_blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "Slug Blogger",
            slug: "slug-blogger"
          )

        response =
          make_api_request(
            "#{@api_public_path}/by-slug/slug-blogger",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == active_blogger.id
        assert body["data"]["attributes"]["slug"] == "slug-blogger"
      end

      test "archived bloggers are not accessible via public endpoints", %{
        site: site,
        site1_user: site1_user
      } do
        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "To Be Archived",
            slug: "to-be-archived"
          )

        # Archive it
        blogger
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Try to get by ID
        response =
          make_api_request(
            "#{@api_public_path}/#{blogger.id}",
            %{},
            method: :get,
            headers: []
          )

        # Should return 403 Forbidden because archived
        assert response.status in [403, 404]

        # Try to get by slug
        response2 =
          make_api_request(
            "#{@api_public_path}/by-slug/to-be-archived",
            %{},
            method: :get,
            headers: []
          )

        # Should return 403 Forbidden or 404 because archived
        assert response2.status in [403, 404]
      end
    end

    describe "Paginated relationships - Blogger with posts" do
      test "public can include blogger posts with pagination", %{site: site} do
        user = create_user!(site_id: site.id)
        blogger = create_blogger!(site_id: site.id, user_id: user.id, slug: "post-blogger")

        # Create 20 posts by this blogger
        post_ids =
          Enum.map(1..20, fn i ->
            post =
              MishkaBlog.BlogPost
              |> Ash.Changeset.for_create(
                :create,
                %{
                  title: "Post #{i}",
                  slug: "post-#{i}",
                  content: "Content #{i}",
                  status: :published
                },
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            # Add blogger to post
            MishkaBlog.PostBlogger
            |> Ash.Changeset.for_create(
              :assign,
              %{post_id: post.id, blogger_id: blogger.id},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

            post.id
          end)

        # Fetch blogger with paginated posts (limit 10)
        response =
          make_api_request(
            "#{@api_public_path}/#{blogger.id}?include=posts&included_page[posts][limit]=10&included_page[posts][offset]=0",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify included posts (should be limited to 10)
        assert is_list(body["included"])
        post_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blog_post" end)
        assert length(post_records) == 10

        # Verify all included posts are from our created list
        included_post_ids = Enum.map(post_records, & &1["id"])
        Enum.each(included_post_ids, fn id -> assert id in post_ids end)
      end

      test "public can paginate through blogger posts using offset", %{site: site} do
        user = create_user!(site_id: site.id)
        blogger = create_blogger!(site_id: site.id, user_id: user.id, slug: "offset-post-blogger")

        # Create 30 posts
        _post_ids =
          Enum.map(1..30, fn i ->
            post =
              MishkaBlog.BlogPost
              |> Ash.Changeset.for_create(
                :create,
                %{
                  title: "Offset Post #{i}",
                  slug: "offset-post-#{i}",
                  content: "Content",
                  status: :published
                },
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            MishkaBlog.PostBlogger
            |> Ash.Changeset.for_create(
              :assign,
              %{post_id: post.id, blogger_id: blogger.id},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

            post.id
          end)

        # Fetch second page (offset 15, limit 10)
        response =
          make_api_request(
            "#{@api_public_path}/#{blogger.id}?include=posts&included_page[posts][limit]=10&included_page[posts][offset]=15",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        post_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blog_post" end)
        assert length(post_records) == 10
      end

      test "tenant admin can include tenant_posts with pagination", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        user = create_user!(site_id: site.id)
        blogger = create_blogger!(site_id: site.id, user_id: user.id, slug: "tenant-post-blogger")

        # Create 18 posts
        post_ids =
          Enum.map(1..18, fn i ->
            post =
              MishkaBlog.BlogPost
              |> Ash.Changeset.for_create(
                :create,
                %{
                  title: "Tenant Post #{i}",
                  slug: "tenant-post-#{i}",
                  content: "Content",
                  status: :published
                },
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            MishkaBlog.PostBlogger
            |> Ash.Changeset.for_create(
              :assign,
              %{post_id: post.id, blogger_id: blogger.id},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

            post.id
          end)

        # Fetch blogger with paginated tenant_posts (limit 12)
        response =
          make_api_request(
            "#{@api_tenant_path}/#{blogger.id}?include=tenant_posts&included_page[tenant_posts][limit]=12",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        post_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blog_post" end)
        assert length(post_records) == 12

        included_post_ids = Enum.map(post_records, & &1["id"])
        Enum.each(included_post_ids, fn id -> assert id in post_ids end)
      end

      test "master admin can include master_posts with pagination", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        user = create_user!(site_id: site.id)
        blogger = create_blogger!(site_id: site.id, user_id: user.id, slug: "master-post-blogger")

        # Create 25 posts
        _post_ids =
          Enum.map(1..25, fn i ->
            post =
              MishkaBlog.BlogPost
              |> Ash.Changeset.for_create(
                :create,
                %{
                  title: "Master Post #{i}",
                  slug: "master-post-#{i}",
                  content: "Content",
                  status: :published
                },
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            MishkaBlog.PostBlogger
            |> Ash.Changeset.for_create(
              :assign,
              %{post_id: post.id, blogger_id: blogger.id},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

            post.id
          end)

        # Fetch blogger with paginated master_posts (limit 15)
        response =
          make_api_request(
            "#{@api_master_path}/#{blogger.id}?include=master_posts&included_page[master_posts][limit]=15",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        post_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blog_post" end)
        assert length(post_records) == 15
      end

      test "pagination respects post status (only published)", %{site: site} do
        user = create_user!(site_id: site.id)
        blogger = create_blogger!(site_id: site.id, user_id: user.id, slug: "status-post-blogger")

        # Create 8 published posts
        published_post_ids =
          Enum.map(1..8, fn i ->
            post =
              MishkaBlog.BlogPost
              |> Ash.Changeset.for_create(
                :create,
                %{
                  title: "Published #{i}",
                  slug: "published-#{i}",
                  content: "Content",
                  status: :published
                },
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            MishkaBlog.PostBlogger
            |> Ash.Changeset.for_create(
              :assign,
              %{post_id: post.id, blogger_id: blogger.id},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

            post.id
          end)

        # Create 5 draft posts (should not appear for public)
        Enum.each(1..5, fn i ->
          post =
            MishkaBlog.BlogPost
            |> Ash.Changeset.for_create(
              :create,
              %{
                title: "Draft #{i}",
                slug: "draft-post-#{i}",
                content: "Content",
                status: :draft
              },
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

          MishkaBlog.PostBlogger
          |> Ash.Changeset.for_create(
            :assign,
            %{post_id: post.id, blogger_id: blogger.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end)

        # Fetch blogger with posts (should only get published)
        response =
          make_api_request(
            "#{@api_public_path}/#{blogger.id}?include=posts&included_page[posts][limit]=20",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        post_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blog_post" end)
        # Should only get 8 published posts, not 13 total
        assert length(post_records) == 8

        included_post_ids = Enum.map(post_records, & &1["id"])
        Enum.each(included_post_ids, fn id -> assert id in published_post_ids end)
      end
    end

    describe "VERSION MANAGEMENT - GET /blogger/:id/with-versions" do
      test "tenant admin can get their blogger with versions", %{
        tenant_admin: tenant_admin,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "ORIGINAL",
            slug: "original-blogger",
            bio: "Original bio"
          )

        # Update to create versions
        blogger
        |> Ash.Changeset.for_update(:update, %{bio: "Bio 1"}, tenant: site.id, authorize?: false)
        |> Ash.update!()

        blogger
        |> Ash.Changeset.for_update(:update, %{bio: "Bio 2"}, tenant: site.id, authorize?: false)
        |> Ash.update!()

        # Wait for versions to be created (1 create + 2 updates = 3 versions)
        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 3)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{blogger.id}/with-versions?fields[blogger]=display_name,bio,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == blogger.id
        assert body["data"]["attributes"]["display_name"] == "ORIGINAL"

        # Check sorted_versions in attributes
        sorted_versions = body["data"]["attributes"]["sorted_versions"]
        assert is_list(sorted_versions)
        assert length(sorted_versions) == 3
      end

      test "tenant admin cannot get blogger with versions from another site", %{
        tenant_admin: tenant_admin,
        site2: site2,
        site2_user: site2_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger =
          create_blogger!(
            site_id: site2.id,
            user_id: site2_user.id,
            display_name: "OTHERSITE",
            slug: "other-blogger"
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{blogger.id}/with-versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can get any blogger with versions", %{
        master_user: master_user,
        site: site,
        site2: site2,
        site1_user: site1_user,
        site2_user: site2_user
      } do
        token = sign_in_master(master_user)

        blogger1 =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "SITE1BLOGGER",
            slug: "site1-blogger"
          )

        blogger2 =
          create_blogger!(
            site_id: site2.id,
            user_id: site2_user.id,
            display_name: "SITE2BLOGGER",
            slug: "site2-blogger"
          )

        # Create version for blogger1
        blogger1
        |> Ash.Changeset.for_update(:update, %{bio: "Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions (blogger1: 1 create + 1 update = 2, blogger2: 1 create = 1)
        wait_for_version_count("mishka_blog_blogger_versions", blogger1.id, 2)
        wait_for_version_count("mishka_blog_blogger_versions", blogger2.id, 1)

        # Get site1 blogger with versions
        response1 =
          make_api_request(
            "#{@api_master_path}/#{blogger1.id}/with-versions?fields[blogger]=display_name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response1.status == 200
        body1 = Jason.decode!(response1.resp_body)
        sorted_versions1 = body1["data"]["attributes"]["sorted_versions"]
        assert is_list(sorted_versions1)
        assert length(sorted_versions1) == 2

        # Get site2 blogger with versions
        response2 =
          make_api_request(
            "#{@api_master_path}/#{blogger2.id}/with-versions?fields[blogger]=display_name,sorted_versions",
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
      test "tenant admin can get version calculations for their blogger", %{
        tenant_admin: tenant_admin,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "ORIGINAL",
            slug: "calc-blogger",
            bio: "Bio 1"
          )

        # Create multiple versions
        updated1 =
          blogger
          |> Ash.Changeset.for_update(:update, %{bio: "Bio 2"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        updated2 =
          updated1
          |> Ash.Changeset.for_update(:update, %{bio: "Bio 3"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        updated3 =
          updated2
          |> Ash.Changeset.for_update(:update, %{bio: "Bio 4"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        _updated4 =
          updated3
          |> Ash.Changeset.for_update(:update, %{bio: "Bio 5"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 4 updates = 5 versions)
        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 5)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{blogger.id}?fields[blogger]=display_name,bio,version_count,latest_version,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Check version_count calculation
        assert body["data"]["attributes"]["version_count"] == 5

        # Check latest_version calculation
        latest_version = body["data"]["attributes"]["latest_version"]
        assert is_map(latest_version)
        assert latest_version["changes"]["bio"] == "Bio 5"

        # Check recent_versions calculation (should return up to 10)
        recent_versions = body["data"]["attributes"]["recent_versions"]
        assert is_list(recent_versions)
        assert length(recent_versions) == 5

        # Verify they're sorted descending (newest first)
        bios = Enum.map(recent_versions, & &1["changes"]["bio"])
        assert Enum.at(bios, 0) == "Bio 5"
        assert Enum.at(bios, 4) == "Bio 1"
      end

      test "master admin can get version calculations for any blogger", %{
        master_user: master_user,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_master(master_user)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "TEST",
            slug: "master-calc-blogger",
            bio: "V1"
          )

        # Create versions
        updated1 =
          blogger
          |> Ash.Changeset.for_update(:update, %{bio: "V2"}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        _updated2 =
          updated1
          |> Ash.Changeset.for_update(:update, %{bio: "V3"}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        # Wait for versions (1 create + 2 updates = 3 versions)
        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 3)

        response =
          make_api_request(
            "#{@api_master_path}/#{blogger.id}?fields[blogger]=display_name,version_count,latest_version,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert body["data"]["attributes"]["version_count"] == 3

        latest = body["data"]["attributes"]["latest_version"]
        assert latest["changes"]["bio"] == "V3"

        recent = body["data"]["attributes"]["recent_versions"]
        assert length(recent) == 3
      end

      test "recent_versions limits to 10 versions when more exist", %{
        tenant_admin: tenant_admin,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "MANYVERS",
            slug: "many-versions-blogger"
          )

        # Create 12 versions
        updated = blogger

        updated =
          Enum.reduce(1..12, updated, fn i, acc ->
            acc
            |> Ash.Changeset.for_update(:update, %{bio: "Version #{i}"},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.update!()
          end)

        # Wait for versions (1 create + 12 updates = 13 versions)
        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 13)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{updated.id}?fields[blogger]=version_count,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # version_count should be 13
        assert body["data"]["attributes"]["version_count"] == 13

        # recent_versions should be limited to 10
        recent = body["data"]["attributes"]["recent_versions"]
        assert length(recent) == 10

        # Should be newest 10 (sorted descending)
        bios = Enum.map(recent, & &1["changes"]["bio"])
        assert Enum.at(bios, 0) == "Version 12"
        assert Enum.at(bios, 9) == "Version 3"
      end
    end

    describe "VERSION MANAGEMENT - GET /blogger/:id/versions" do
      test "tenant admin can list versions for their blogger", %{
        tenant_admin: tenant_admin,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "ORIGINAL",
            slug: "list-versions-blogger"
          )

        # Create multiple versions - capture updated results
        updated1 =
          blogger
          |> Ash.Changeset.for_update(:update, %{display_name: "V1"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        updated2 =
          updated1
          |> Ash.Changeset.for_update(:update, %{display_name: "V2"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        _updated3 =
          updated2
          |> Ash.Changeset.for_update(:update, %{display_name: "V3"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 3 updates = 4 versions)
        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 4)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{blogger.id}/versions?fields[blogger]=display_name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Returns 1 blogger with versions loaded
        assert is_list(body["data"])
        assert length(body["data"]) == 1

        # Check the versions inside the blogger
        blogger_data = List.first(body["data"])
        sorted_versions = blogger_data["attributes"]["sorted_versions"]
        assert is_list(sorted_versions)
        assert length(sorted_versions) == 4
      end

      test "tenant admin cannot list versions from another site's blogger", %{
        tenant_admin: tenant_admin,
        site2: site2,
        site2_user: site2_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger =
          create_blogger!(
            site_id: site2.id,
            user_id: site2_user.id,
            display_name: "OTHERSITE",
            slug: "other-list-blogger"
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{blogger.id}/versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        # Should return 200 with empty data (tenant filtering)
        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"] == []
      end

      test "master admin can list versions for any blogger", %{
        master_user: master_user,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_master(master_user)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "TEST",
            slug: "master-list-blogger"
          )

        # Create versions
        blogger
        |> Ash.Changeset.for_update(:update, %{display_name: "UPDATED"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        response =
          make_api_request(
            "#{@api_master_path}/#{blogger.id}/versions?fields[blogger]=display_name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])
        assert length(body["data"]) == 1

        # Check the versions inside the blogger
        blogger_data = List.first(body["data"])
        sorted_versions = blogger_data["attributes"]["sorted_versions"]
        assert is_list(sorted_versions)
        assert length(sorted_versions) == 2
      end
    end

    describe "VERSION MANAGEMENT - PATCH /blogger/:id/version/:version_id/restore" do
      test "tenant admin can restore their blogger to a previous version", %{
        tenant_admin: tenant_admin,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "ORIGINAL",
            slug: "restore-blogger",
            bio: "Original bio"
          )

        # Create a version
        updated =
          blogger
          |> Ash.Changeset.for_update(:update, %{display_name: "UPDATED", bio: "Updated bio"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        # Get the version
        version =
          MishkaBlog.Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: blogger.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{updated.id}/version/#{version.id}/restore",
            %{"type" => "blogger", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["display_name"] == "ORIGINAL"
        assert body["data"]["attributes"]["bio"] == "Original bio"
      end

      test "tenant admin cannot restore another site's blogger version", %{
        tenant_admin: tenant_admin,
        site2: site2,
        site2_user: site2_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger =
          create_blogger!(
            site_id: site2.id,
            user_id: site2_user.id,
            display_name: "OTHER",
            slug: "other-restore-blogger"
          )

        # Create version
        blogger
        |> Ash.Changeset.for_update(:update, %{display_name: "UPDATED"},
          tenant: site2.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        # Get version
        version =
          MishkaBlog.Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: blogger.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{blogger.id}/version/#{version.id}/restore",
            %{"type" => "blogger", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can restore any blogger version", %{
        master_user: master_user,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_master(master_user)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "ORIGINAL",
            slug: "master-restore-blogger"
          )

        # Create version
        updated =
          blogger
          |> Ash.Changeset.for_update(:update, %{display_name: "UPDATED"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        # Get version
        version =
          MishkaBlog.Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: blogger.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_master_path}/#{updated.id}/version/#{version.id}/restore",
            %{"type" => "blogger", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["display_name"] == "ORIGINAL"
      end

      test "cannot restore version of archived blogger", %{
        tenant_admin: tenant_admin,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "ORIGINAL",
            slug: "archive-restore-blogger"
          )

        # Create version
        blogger
        |> Ash.Changeset.for_update(:update, %{display_name: "UPDATED"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        # Archive blogger
        blogger
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Get version
        version =
          MishkaBlog.Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: blogger.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{blogger.id}/version/#{version.id}/restore",
            %{"type" => "blogger", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status in [400, 404, 422]
      end
    end

    describe "VERSION MANAGEMENT - GET /blogger/:id/version/:version_id/preview" do
      test "tenant admin can preview a version without restoring", %{
        tenant_admin: tenant_admin,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_tenant(tenant_admin)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "ORIGINAL",
            slug: "preview-blogger",
            bio: "Original bio"
          )

        # Create version
        updated =
          blogger
          |> Ash.Changeset.for_update(:update, %{display_name: "UPDATED", bio: "Updated bio"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        # Get version
        version =
          MishkaBlog.Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: blogger.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{blogger.id}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["display_name"] == "ORIGINAL"
        assert body["data"]["attributes"]["bio"] == "Original bio"

        # Verify original unchanged (still see updated values)
        current = MishkaBlog.Blogger |> Ash.get!(updated.id, tenant: site.id, authorize?: false)
        assert current.display_name == "UPDATED"
      end

      test "master admin can preview any blogger version", %{
        master_user: master_user,
        site: site,
        site1_user: site1_user
      } do
        token = sign_in_master(master_user)

        blogger =
          create_blogger!(
            site_id: site.id,
            user_id: site1_user.id,
            display_name: "ORIGINAL",
            slug: "master-preview-blogger",
            bio: "Original bio"
          )

        # Create version
        blogger
        |> Ash.Changeset.for_update(:update, %{display_name: "UPDATED", bio: "Updated bio"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_blogger_versions", blogger.id, 2)

        # Get version
        version =
          MishkaBlog.Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id: blogger.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_master_path}/#{blogger.id}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["display_name"] == "ORIGINAL"
        assert body["data"]["attributes"]["bio"] == "Original bio"
      end
    end
  end
end
