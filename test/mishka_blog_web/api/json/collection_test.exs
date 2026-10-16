# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Api.Json.CollectionTest do
  @moduledoc """
  Comprehensive tests for Collection JSON API endpoints.
  """

  use MishkaBlog.ConnCase
  import MishkaBlog.Test.Factory
  import MishkaBlog.Test.VersionHelpers

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaBlog) do
    @password "Password123!"
    # The admins here are API admins, so what they write outside a request says so.
    @api_surface %{shared: %{admin_surface: :api}}
    @api_user_path "/api/json/v1/auth/user"
    @api_master_path "/api/json/v1/master/admin/mishka-blog/collection"
    @api_tenant_path "/api/json/v1/tenant/admin/mishka-blog/collection"
    @api_public_path "/api/json/v1/user/mishka-blog/collection"

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

    describe "CREATE - POST /collection" do
      test "master admin can create collection for any site", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        # Create collection for site1
        response =
          make_api_request(
            @api_master_path,
            %{
              "type" => "collection",
              "attributes" => %{
                "name" => "Tech Articles",
                "slug" => "tech-articles",
                "description" => "Technology related articles",
                "status" => "active",
                "language" => "en",
                "site_id" => site.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Tech Articles"
        assert body["data"]["attributes"]["slug"] == "tech-articles"
        assert body["data"]["attributes"]["status"] == "active"
        assert body["data"]["attributes"]["site_id"] == site.id

        # Create collection for site2
        response2 =
          make_api_request(
            @api_master_path,
            %{
              "type" => "collection",
              "attributes" => %{
                "name" => "Business Articles",
                "slug" => "business-articles",
                "status" => "draft",
                "language" => "en",
                "site_id" => site2.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 201
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["attributes"]["name"] == "Business Articles"
        assert body2["data"]["attributes"]["site_id"] == site2.id
      end

      test "tenant admin can create collection only for their own site", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        # Successfully create collection for their own site
        response =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "collection",
              "attributes" => %{
                "name" => "My Collection",
                "slug" => "my-collection",
                "description" => "Test collection",
                "status" => "active",
                "language" => "en"
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "My Collection"
        assert body["data"]["attributes"]["site_id"] == site.id

        # Tenant users cannot send site_id
        response2 =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "collection",
              "attributes" => %{
                "name" => "Invalid",
                "slug" => "invalid",
                "status" => "active",
                "site_id" => site2.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 400
      end
    end

    describe "READ - GET /collection (list and get)" do
      test "master admin can list collections from all sites", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        collection1 = create_collection!(site_id: site.id, name: "Collection 1")
        collection2 = create_collection!(site_id: site2.id, name: "Collection 2")

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

        ids = Enum.map(body["data"], & &1["id"])
        assert collection1.id in ids
        assert collection2.id in ids
      end

      test "tenant admin can list only their own site's collections", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        collection1 = create_collection!(site_id: site.id, name: "Own Collection")
        collection2 = create_collection!(site_id: site2.id, name: "Other Collection")

        response =
          make_api_request(
            @api_tenant_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert collection1.id in ids
        refute collection2.id in ids
      end

      test "master admin can get any collection by id", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        collection = create_collection!(site_id: site.id, name: "Test Collection")

        response =
          make_api_request(
            "#{@api_master_path}/#{collection.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == collection.id
        assert body["data"]["attributes"]["name"] == "Test Collection"
      end

      test "tenant admin can get only their own site's collection", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        collection1 = create_collection!(site_id: site.id, name: "Own")
        collection2 = create_collection!(site_id: site2.id, name: "Other")

        # Can get own site's collection
        response =
          make_api_request(
            "#{@api_tenant_path}/#{collection1.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot get another site's collection
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{collection2.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end

      test "master admin can list language variants", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create master collection (English) - language_group_id will be auto-set to its own id
        master_collection =
          create_collection!(
            site_id: site.id,
            name: "English Version",
            language: "en"
          )

        # Create translation collection (French) using master's id as language_group_id
        create_collection!(
          site_id: site.id,
          name: "French Version",
          language: "fr",
          language_group_id: master_collection.id
        )

        response =
          make_api_request(
            "#{@api_master_path}/language-variants?language_group_id=#{master_collection.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])
        assert length(body["data"]) == 2
      end

      test "tenant admin can list language variants for their site", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Create master collection (English) - language_group_id will be auto-set to its own id
        master_collection =
          create_collection!(
            site_id: site.id,
            name: "English",
            language: "en"
          )

        # Create translation collection (Spanish) using master's id as language_group_id
        create_collection!(
          site_id: site.id,
          name: "Spanish",
          language: "es",
          language_group_id: master_collection.id
        )

        response =
          make_api_request(
            "#{@api_tenant_path}/language-variants?language_group_id=#{master_collection.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])
        assert length(body["data"]) == 2
      end
    end

    describe "UPDATE - PATCH /collection" do
      test "master admin can update any collection", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        collection = create_collection!(site_id: site.id, name: "Old Name")

        response =
          make_api_request(
            "#{@api_master_path}/#{collection.id}",
            %{
              "type" => "collection",
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
      end

      test "tenant admin can update only their own site's collection", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        collection_own = create_collection!(site_id: site.id, name: "Own")
        collection_other = create_collection!(site_id: site2.id, name: "Other")

        # Can update own
        response =
          make_api_request(
            "#{@api_tenant_path}/#{collection_own.id}",
            %{
              "type" => "collection",
              "attributes" => %{"name" => "Updated Own"}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot update other site's
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{collection_other.id}",
            %{
              "type" => "collection",
              "attributes" => %{"name" => "Hacked"}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "DELETE - Soft delete (archive)" do
      test "master admin can archive any collection", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        collection = create_collection!(site_id: site.id)

        response =
          make_api_request(
            "#{@api_master_path}/#{collection.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200

        # Verify archived
        list_response =
          make_api_request(
            @api_master_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        list_body = Jason.decode!(list_response.resp_body)
        ids = Enum.map(list_body["data"], & &1["id"])
        refute collection.id in ids
      end

      test "tenant admin can archive their own site's collection", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        collection_own = create_collection!(site_id: site.id)
        collection_other = create_collection!(site_id: site2.id)

        # Can archive own
        response =
          make_api_request(
            "#{@api_tenant_path}/#{collection_own.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot archive other
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{collection_other.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end

      test "an original whose translation is live is refused, naming the languages", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        original = create_collection!(site_id: site.id)

        create_collection!(
          site_id: site.id,
          slug: "#{original.slug}-fa",
          language: "fa",
          language_group_id: original.id
        )

        response =
          make_api_request(
            "#{@api_master_path}/#{original.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 400
        %{"errors" => errors} = Jason.decode!(response.resp_body)

        assert %{"code" => "invalid_attribute"} =
                 error = Enum.find(errors, &(&1["code"] == "invalid_attribute"))

        assert error["detail"] ==
                 "This is the original English version. Its Persian translation is still live, " <>
                   "so it can't be deleted yet. Archive or delete that translation first, then " <>
                   "this one."

        assert Ash.get!(MishkaBlog.Collection, original.id,
                 action: :master_get,
                 authorize?: false
               ).archived_at ==
                 nil
      end
    end

    describe "ARCHIVED - Working with archived records" do
      test "master admin can list archived collections from all sites", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        collection1 = create_collection!(site_id: site.id)
        collection2 = create_collection!(site_id: site2.id)

        # Archive them
        collection1
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        collection2
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

        ids = Enum.map(body["data"], & &1["id"])
        assert collection1.id in ids
        assert collection2.id in ids
      end

      test "tenant admin can list archived collections for their site only", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        collection_own = create_collection!(site_id: site.id)
        collection_other = create_collection!(site_id: site2.id)

        collection_own
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        collection_other
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
        assert collection_own.id in ids
        refute collection_other.id in ids
      end

      test "master admin can get archived collection by id", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        collection = create_collection!(site_id: site.id)

        collection
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_master_path}/archived/#{collection.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == collection.id
      end

      test "tenant admin can get archived collection from their site", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        collection = create_collection!(site_id: site.id)

        collection
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_tenant_path}/archived/#{collection.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
      end

      test "master admin can unarchive any collection", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        collection = create_collection!(site_id: site.id)

        collection
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_master_path}/#{collection.id}/unarchive",
            %{"type" => "collection", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
      end

      test "tenant admin can unarchive their own site's collection", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        collection = create_collection!(site_id: site.id)

        collection
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_tenant_path}/#{collection.id}/unarchive",
            %{"type" => "collection", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
      end
    end

    describe "DELETE - Permanent deletion" do
      test "master admin can permanently delete any collection", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        collection = create_collection!(site_id: site.id)
        collection_id = collection.id

        response =
          make_api_request(
            "#{@api_master_path}/#{collection_id}/permanent",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200

        # Verify completely gone
        archived_response =
          make_api_request(
            "#{@api_master_path}/archived",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        archived_body = Jason.decode!(archived_response.resp_body)
        archived_ids = Enum.map(archived_body["data"], & &1["id"])
        refute collection_id in archived_ids
      end

      test "tenant admin can permanently delete their own site's collection", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        collection_own = create_collection!(site_id: site.id)
        collection_other = create_collection!(site_id: site2.id)

        # Can permanently delete own
        response =
          make_api_request(
            "#{@api_tenant_path}/#{collection_own.id}/permanent",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot permanently delete other
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{collection_other.id}/permanent",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "PUBLIC - Unauthenticated access" do
      test "anyone can list active collections", %{site: site} do
        # Create active and draft collections in the same site
        active1 =
          create_collection!(site_id: site.id, name: "Active1", status: :active)

        active2 =
          create_collection!(site_id: site.id, name: "Active2", status: :active)

        _draft =
          create_collection!(site_id: site.id, name: "Draft", status: :draft)

        response =
          make_api_request(
            "#{@api_public_path}/active",
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

        # All should be active status
        Enum.each(body["data"], fn collection ->
          assert collection["attributes"]["status"] == "active"
        end)
      end

      test "anyone can get active collection by id", %{site: site} do
        active_collection =
          create_collection!(site_id: site.id, name: "Public Collection", status: :active)

        response =
          make_api_request(
            "#{@api_public_path}/active/#{active_collection.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == active_collection.id
        assert body["data"]["attributes"]["status"] == "active"
      end
    end

    describe "PAGINATED INCLUDES - Fetching related posts with pagination" do
      test "tenant user can fetch collection with paginated posts", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Create two collections
        collection_large =
          create_collection!(
            site_id: site.id,
            name: "Large Collection",
            status: :active
          )

        collection_small =
          create_collection!(
            site_id: site.id,
            name: "Small Collection",
            status: :active
          )

        # Create 30 blog posts for the large collection
        large_post_ids =
          Enum.map(1..30, fn i ->
            post =
              Ash.create!(
                MishkaBlog.BlogPost,
                %{
                  title: "Post #{i}",
                  slug: "post-#{i}",
                  content: "Content #{i}",
                  status: :published,
                  language: "en",
                  published_at: DateTime.utc_now()
                },
                actor: tenant_admin,
                tenant: site.id,
                context: @api_surface
              )

            # Link post to collection via PostCollection join table
            MishkaBlog.PostCollection
            |> Ash.Changeset.for_create(
              :assign,
              %{
                post_id: post.id,
                collection_id: collection_large.id
              },
              actor: tenant_admin,
              context: @api_surface
            )
            |> Ash.create!()

            post.id
          end)

        # Create 3 blog posts for the small collection
        small_post_ids =
          Enum.map(1..3, fn i ->
            post =
              Ash.create!(
                MishkaBlog.BlogPost,
                %{
                  title: "Small Post #{i}",
                  slug: "small-post-#{i}",
                  content: "Content #{i}",
                  status: :published,
                  language: "en",
                  published_at: DateTime.utc_now()
                },
                actor: tenant_admin,
                tenant: site.id,
                context: @api_surface
              )

            MishkaBlog.PostCollection
            |> Ash.Changeset.for_create(
              :assign,
              %{
                post_id: post.id,
                collection_id: collection_small.id
              },
              actor: tenant_admin,
              context: @api_surface
            )
            |> Ash.create!()

            post.id
          end)

        # Fetch large collection with first page of posts (limit 10)
        response =
          make_api_request(
            "#{@api_tenant_path}/#{collection_large.id}?include=tenant_posts&included_page[tenant_posts][limit]=30&included_page[tenant_posts][offset]=0",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify collection data
        assert body["data"]["id"] == collection_large.id
        assert body["data"]["attributes"]["name"] == "Large Collection"
        assert body["data"]["relationships"]["tenant_posts"]["links"]["first"] |> is_binary()
        assert body["data"]["relationships"]["tenant_posts"]["links"]["next"] |> is_binary()
        assert body["data"]["relationships"]["tenant_posts"]["links"]["prev"] |> is_nil()

        # Verify posts relationship data is present
        # Note: With include=posts, the relationship should be loaded
        relationship_posts = body["data"]["relationships"]["tenant_posts"]["data"] || []
        assert length(relationship_posts) == 30, "All 30 posts should be in relationships"

        # Verify the relationship post IDs match what we created
        relationship_post_ids = Enum.map(relationship_posts, & &1["id"])
        assert Enum.all?(large_post_ids, &(&1 in relationship_post_ids))

        # Fetch small collection with all posts
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{collection_small.id}?include=tenant_posts",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)

        # Verify small collection has 3 posts
        relationship_posts2 = body2["data"]["relationships"]["tenant_posts"]["data"] || []
        assert length(relationship_posts2) == 3

        # Verify the posts belong to the small collection
        relationship_post_ids2 = Enum.map(relationship_posts2, & &1["id"])
        assert Enum.all?(small_post_ids, &(&1 in relationship_post_ids2))
      end

      test "master user can fetch collection with paginated posts using all_posts", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create a collection
        collection =
          create_collection!(
            site_id: site.id,
            name: "Master Collection",
            status: :active
          )

        # Create 25 blog posts using master_create action
        post_ids =
          Enum.map(1..25, fn i ->
            post =
              MishkaBlog.BlogPost
              |> Ash.Changeset.for_create(
                :master_create,
                %{
                  title: "Master Post #{i}",
                  slug: "master-post-#{i}",
                  content: "Content #{i}",
                  status: :published,
                  language: "en",
                  published_at: DateTime.utc_now(),
                  site_id: site.id
                },
                actor: master_user,
                tenant: nil,
                context: @api_surface
              )
              |> Ash.create!()

            MishkaBlog.PostCollection
            |> Ash.Changeset.for_create(
              :assign,
              %{
                post_id: post.id,
                collection_id: collection.id
              },
              actor: master_user,
              tenant: site.id,
              context: @api_surface
            )
            |> Ash.create!()

            post.id
          end)

        # Fetch collection with all_posts relationship (bypassing tenant)
        response =
          make_api_request(
            "#{@api_master_path}/#{collection.id}?include=master_posts&included_page[master_posts][limit]=25",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify collection data
        assert body["data"]["id"] == collection.id

        # Verify all_posts relationship data is present
        relationship_posts = body["data"]["relationships"]["master_posts"]["data"] || []

        assert length(relationship_posts) == 25, "All 25 posts should be in relationships"

        # Verify the posts belong to the collection
        relationship_post_ids = Enum.map(relationship_posts, & &1["id"])
        assert Enum.all?(post_ids, &(&1 in relationship_post_ids))
      end

      test "any user can fetch collection with paginated posts", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        # Create two collections
        collection_large =
          create_collection!(
            site_id: site.id,
            name: "Large Collection",
            status: :active
          )

        # Create 30 blog posts for the large collection
        large_post_ids =
          Enum.map(1..30, fn i ->
            post =
              Ash.create!(
                MishkaBlog.BlogPost,
                %{
                  title: "Post #{i}",
                  slug: "post-#{i}",
                  content: "Content #{i}",
                  status: :published,
                  language: "en",
                  published_at: DateTime.utc_now()
                },
                actor: tenant_admin,
                tenant: site.id,
                context: @api_surface
              )

            # Link post to collection via PostCollection join table
            MishkaBlog.PostCollection
            |> Ash.Changeset.for_create(
              :assign,
              %{
                post_id: post.id,
                collection_id: collection_large.id
              },
              actor: tenant_admin,
              context: @api_surface
            )
            |> Ash.create!()

            post.id
          end)

        response =
          make_api_request(
            "#{@api_public_path}/active/#{collection_large.id}?include=posts&included_page[posts][limit]=30&included_page[posts][offset]=0",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        # Verify collection data
        assert body["data"]["id"] == collection_large.id
        assert body["data"]["attributes"]["name"] == "Large Collection"
        assert body["data"]["relationships"]["posts"]["links"]["first"] |> is_binary()
        assert body["data"]["relationships"]["posts"]["links"]["next"] |> is_binary()
        assert body["data"]["relationships"]["posts"]["links"]["prev"] |> is_nil()

        # Verify posts relationship data is present
        # Note: With include=posts, the relationship should be loaded
        relationship_posts = body["data"]["relationships"]["posts"]["data"] || []
        assert length(relationship_posts) == 30, "All 30 posts should be in relationships"

        # Verify the relationship post IDs match what we created
        relationship_post_ids = Enum.map(relationship_posts, & &1["id"])
        assert Enum.all?(large_post_ids, &(&1 in relationship_post_ids))
      end
    end

    describe "VERSION MANAGEMENT - GET /collection/:id/with-versions" do
      test "master admin can get collection with versions", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        collection =
          create_collection!(
            site_id: site.id,
            name: "Original Name",
            description: "Original description"
          )

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "Desc 1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "Desc 2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 4)

        response =
          make_api_request(
            "#{@api_master_path}/#{collection.id}/with-versions?fields[collection]=name,description,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == collection.id
        assert body["data"]["attributes"]["name"] == "Original Name"

        sorted_versions = body["data"]["attributes"]["sorted_versions"]
        assert is_list(sorted_versions)
        assert length(sorted_versions) == 4
      end

      test "tenant admin can get their collection with versions", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        collection =
          create_collection!(site_id: site.id, name: "ORIGINAL", description: "Original desc")

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "Updated 1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 3)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{collection.id}/with-versions?fields[collection]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == collection.id

        sorted_versions = body["data"]["attributes"]["sorted_versions"]
        assert is_list(sorted_versions)
        assert length(sorted_versions) == 3
      end

      test "tenant admin cannot get another site's collection with versions", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)
        collection = create_collection!(site_id: site2.id, name: "Other Site Collection")

        response =
          make_api_request(
            "#{@api_tenant_path}/#{collection.id}/with-versions?fields[collection]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end
    end

    describe "VERSION MANAGEMENT - Calculations (version_count, latest_version, recent_versions)" do
      test "master admin can get version calculations", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)

        collection = create_collection!(site_id: site.id, name: "Test Collection")

        # Create 4 more versions
        Enum.each(1..4, fn i ->
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{description: "Version #{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end)

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 6)

        response =
          make_api_request(
            "#{@api_master_path}/#{collection.id}?fields[collection]=name,version_count,latest_version,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert body["data"]["attributes"]["version_count"] == 6

        latest_version = body["data"]["attributes"]["latest_version"]
        assert is_map(latest_version)
        assert latest_version["changes"]["description"] == "Version 4"

        recent_versions = body["data"]["attributes"]["recent_versions"]
        assert is_list(recent_versions)
        assert length(recent_versions) == 6

        descriptions = Enum.map(recent_versions, & &1["changes"]["description"])
        assert Enum.at(descriptions, 0) == "Version 4"
        assert Enum.at(descriptions, 3) == "Version 1"
      end

      test "tenant admin can get version calculations", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin)
        collection = create_collection!(site_id: site.id, name: "Tenant Collection")

        Enum.each(1..3, fn i ->
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{description: "Desc #{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end)

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 5)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{collection.id}?fields[collection]=name,version_count,latest_version,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert body["data"]["attributes"]["version_count"] == 5

        recent_versions = body["data"]["attributes"]["recent_versions"]
        assert length(recent_versions) == 5
      end

      test "recent_versions limits to 10 when more exist", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)
        collection = create_collection!(site_id: site.id)

        # Create 12 more versions (13 total with create)
        Enum.each(1..12, fn i ->
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{description: "Version #{i}"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()
        end)

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 14)

        response =
          make_api_request(
            "#{@api_master_path}/#{collection.id}?fields[collection]=name,version_count,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["version_count"] == 14

        recent = body["data"]["attributes"]["recent_versions"]
        assert length(recent) == 10

        descriptions = Enum.map(recent, & &1["changes"]["description"])
        assert Enum.at(descriptions, 0) == "Version 12"
        assert Enum.at(descriptions, 9) == "Version 3"
      end
    end

    describe "VERSION MANAGEMENT - GET /collection/:id/versions" do
      test "master admin can list versions", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)
        collection = create_collection!(site_id: site.id, name: "Master Collection")

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "V2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 4)

        response =
          make_api_request(
            "#{@api_master_path}/#{collection.id}/versions?fields[collection]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])
        assert length(body["data"]) == 1

        collection_data = List.first(body["data"])
        sorted_versions = collection_data["attributes"]["sorted_versions"]
        assert is_list(sorted_versions)
        assert length(sorted_versions) == 4
      end

      test "tenant admin can list versions for their collection", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        collection = create_collection!(site_id: site.id)

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "Update 1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 3)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{collection.id}/versions?fields[collection]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_list(body["data"])
        assert length(body["data"]) == 1

        collection_data = List.first(body["data"])
        sorted_versions = collection_data["attributes"]["sorted_versions"]
        assert length(sorted_versions) == 3
      end

      test "tenant admin cannot list versions from another site's collection", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)
        collection = create_collection!(site_id: site2.id)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{collection.id}/versions?fields[collection]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"] == []
      end
    end

    describe "VERSION MANAGEMENT - PATCH /collection/:id/version/:version_id/restore" do
      test "master admin can restore collection to previous version", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        collection =
          create_collection!(site_id: site.id, name: "V0", description: "Description V0")

        updated =
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{description: "Description V1"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        updated2 =
          updated
          |> Ash.Changeset.for_update(
            :update,
            %{description: "Description V2"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 4)

        versions = versions(MishkaBlog.Collection.Version, collection.id)

        version_1 = Enum.at(versions, 2)

        response =
          make_api_request(
            "#{@api_master_path}/#{updated2.id}/version/#{version_1.id}/restore",
            %{"type" => "collection", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["description"] == "Description V1"
      end

      test "tenant admin can restore their collection", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin)

        collection = create_collection!(site_id: site.id, description: "Original")

        updated =
          collection
          |> Ash.Changeset.for_update(
            :update,
            %{description: "Modified"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 3)

        versions = versions(MishkaBlog.Collection.Version, collection.id)

        original_version = List.first(versions)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{updated.id}/version/#{original_version.id}/restore",
            %{"type" => "collection", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["description"] == "Original"
      end

      test "tenant admin cannot restore another site's collection", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)
        collection = create_collection!(site_id: site2.id)

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "Updated"},
          tenant: site2.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 3)

        versions = versions(MishkaBlog.Collection.Version, collection.id)

        version = List.first(versions)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{collection.id}/version/#{version.id}/restore",
            %{"type" => "collection", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end
    end

    describe "VERSION MANAGEMENT - GET /collection/:id/version/:version_id/preview" do
      test "master admin can preview a version", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)

        collection = create_collection!(site_id: site.id, description: "V0")

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "V1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 3)

        versions = versions(MishkaBlog.Collection.Version, collection.id)

        old_version = List.first(versions)

        response =
          make_api_request(
            "#{@api_master_path}/#{collection.id}/version/#{old_version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        # Preview returns the version's data
        assert is_map(body["data"])
      end

      test "tenant admin can preview their collection's version", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        collection = create_collection!(site_id: site.id, description: "Orig")

        collection
        |> Ash.Changeset.for_update(
          :update,
          %{description: "Mod"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        wait_for_version_count("mishka_blog_collection_versions", collection.id, 3)

        versions = versions(MishkaBlog.Collection.Version, collection.id)

        old_version = List.first(versions)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{collection.id}/version/#{old_version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert is_map(body["data"])
      end
    end
  end
end
