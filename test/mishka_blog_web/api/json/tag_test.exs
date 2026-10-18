# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Api.Json.TagTest do
  @moduledoc """
  Comprehensive tests for MishkaBlog.Tag JSON API endpoints.

  Tests cover three route types:
  - Master admin routes: System-wide tag management (bypass multitenancy)
  - Tenant admin routes: Site-specific tag management (with tenant context)
  - User public routes: Public read-only tag access
  """
  use MishkaBlog.ConnCase
  import MishkaBlog.Test.Factory
  import MishkaBlog.Test.VersionHelpers
  require Ash.Query

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaBlog) do
    @password "Password123!"
    # The admins here are API admins, so what they write outside a request says so.
    @api_surface %{shared: %{admin_surface: :api}}
    @master_base_url "/api/json/v1/master/admin/mishka-blog/tag"
    @tenant_base_url "/api/json/v1/tenant/admin/mishka-blog/tag"
    @user_base_url "/api/json/v1/user/mishka-blog/tag"
    @api_user_path "/api/json/v1/auth/user"

    setup do
      MishkaCmsCore.Runtime.States.SiteState.clear()
      :ok = Swoosh.TestAssertions.set_swoosh_global()

      Application.put_env(:ash_json_api, MishkaBlog, router: MishkaBlog.TestRouter)

      # Create site for testing
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
      permission =
        Ash.create!(
          MishkaCmsCore.Accounts.Permission,
          %{
            name: "admin:api:*",
            description: "Full API access"
          },
          authorize?: false
        )

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
          %{permission_ids: [permission.id]},
          authorize?: false
        )
        |> Ash.update!()

      # Create tenant admin user for site
      tenant_admin =
        create_user!(
          email: "admin@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )
        |> Ash.Changeset.for_update(
          :assign_permissions,
          %{permission_ids: [permission.id]},
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
          %{permission_ids: [permission.id]},
          authorize?: false,
          tenant: site2.id
        )
        |> Ash.update!()

      {:ok,
       site: site,
       site2: site2,
       master_user: master_user,
       tenant_admin: tenant_admin,
       site2_admin: site2_admin}
    end

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
          method: :post,
          headers: [{"x-no-tenant", "true"}]
        )

      assert sign_in_response.status in [200, 201]

      body = Jason.decode!(sign_in_response.resp_body)
      body["meta"]["token"]
    end

    defp sign_in_tenant(tenant_admin) do
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(tenant_admin.email),
              "password" => @password
            }
          },
          method: :post
        )

      assert sign_in_response.status in [200, 201]

      body = Jason.decode!(sign_in_response.resp_body)
      body["meta"]["token"]
    end

    defp sign_in_user(user) do
      sign_in_response =
        make_api_request(
          "#{@api_user_path}/sign-in",
          %{
            "type" => "user",
            "attributes" => %{
              "email" => to_string(user.email),
              "password" => @password
            }
          },
          method: :post
        )

      assert sign_in_response.status in [200, 201]

      body = Jason.decode!(sign_in_response.resp_body)
      body["meta"]["token"]
    end

    describe "/api/json/v1/master/admin/mishka-blog/tag - master admin routes" do
      test "POST / - creates tag for specific site (master_create)", %{
        site: site,
        master_user: master_user
      } do
        token = sign_in_master(master_user)

        response =
          make_api_request(
            @master_base_url,
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Master Tag",
                "slug" => "master-tag",
                "description" => "A tag created by master admin",
                "language" => "en",
                "site_id" => site.id
              }
            },
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status in [200, 201]

        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Master Tag"
        assert body["data"]["attributes"]["slug"] == "master-tag"
        assert body["data"]["attributes"]["language"] == "en"
        assert body["data"]["attributes"]["site_id"] == site.id
      end

      test "GET / - lists all tags system-wide (master_read)", %{
        site: site,
        master_user: master_user
      } do
        # Create tags
        tag1 = create_blog_tag!(site_id: site.id, name: "Tag 1")
        tag2 = create_blog_tag!(site_id: site.id, name: "Tag 2")

        token = sign_in_master(master_user)

        response =
          make_api_request(
            @master_base_url,
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        tag_ids = Enum.map(body["data"], & &1["id"])

        assert tag1.id in tag_ids
        assert tag2.id in tag_ids
      end

      test "GET /:id - retrieves single tag (master_read)", %{
        site: site,
        master_user: master_user
      } do
        tag = create_blog_tag!(site_id: site.id, name: "Specific Tag")

        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_base_url}/#{tag.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "Specific Tag"
      end

      test "PATCH /:id - updates tag (master_update)", %{
        site: site,
        master_user: master_user
      } do
        tag = create_blog_tag!(site_id: site.id, name: "Original Name")

        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_base_url}/#{tag.id}",
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Updated Name",
                "description" => "Updated description"
              }
            },
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Updated Name"
        assert body["data"]["attributes"]["description"] == "Updated description"
      end

      test "DELETE /:id/archive - archives tag (master_destroy)", %{
        site: site,
        master_user: master_user
      } do
        tag = create_blog_tag!(site_id: site.id, name: "Tag to Archive")

        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_base_url}/#{tag.id}/archive",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status in [200, 204]

        # Verify tag is archived
        archived_tag = Ash.get!(MishkaBlog.Tag, tag.id, action: :master_get, authorize?: false)
        assert %DateTime{} = archived_tag.archived_at
      end

      test "GET /archived - lists archived tags (master_archived)", %{
        site: site,
        master_user: master_user
      } do
        # Create and archive a tag
        tag = create_blog_tag!(site_id: site.id, name: "Archived Tag")
        Ash.destroy!(tag, tenant: site.id, authorize?: false)

        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_base_url}/archived",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        tag_ids = Enum.map(body["data"], & &1["id"])

        assert tag.id in tag_ids
      end

      test "PATCH /:id/unarchive - restores archived tag (master_unarchive)", %{
        site: site,
        master_user: master_user
      } do
        tag = create_blog_tag!(site_id: site.id, name: "Tag to Unarchive")
        Ash.destroy!(tag, tenant: site.id, authorize?: false)

        token = sign_in_master(master_user)

        response =
          make_api_request(
            "#{@master_base_url}/#{tag.id}/unarchive",
            %{},
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == tag.id
        assert is_nil(body["data"]["attributes"]["archived_at"])
      end

      test "requires authentication for master routes", %{site: site} do
        response =
          make_api_request(
            @master_base_url,
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Test",
                "slug" => "test",
                "language" => "en",
                "site_id" => site.id
              }
            },
            method: :post,
            headers: [{"x-no-tenant", "true"}]
          )

        assert response.status == 403
      end
    end

    describe "/api/json/v1/tenant/admin/mishka-blog/tag - tenant admin routes" do
      test "POST / - creates tag in tenant context (create)", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_user(tenant_admin)

        response =
          make_api_request(
            @tenant_base_url,
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Tenant Tag",
                "slug" => "tenant-tag",
                "description" => "A tag created in tenant context",
                "language" => "en"
              }
            },
            method: :post,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status in [200, 201]

        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Tenant Tag"
        assert body["data"]["attributes"]["site_id"] == site.id
      end

      test "GET / - lists tags for current tenant only (read)", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        # Create tag in site
        tag = create_blog_tag!(site_id: site.id, name: "Site Tag")

        token = sign_in_user(tenant_admin)

        response =
          make_api_request(
            @tenant_base_url,
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        tag_ids = Enum.map(body["data"], & &1["id"])

        assert tag.id in tag_ids
      end

      test "GET /:id - retrieves single tag in tenant context (read)", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        tag = create_blog_tag!(site_id: site.id, name: "Specific Tag")

        token = sign_in_user(tenant_admin)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "Specific Tag"
      end

      test "PATCH /:id - updates tag in tenant context (update)", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        tag = create_blog_tag!(site_id: site.id, name: "Original Name")

        token = sign_in_user(tenant_admin)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}",
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Updated Name"
              }
            },
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "Updated Name"
      end

      test "DELETE /:id/archive - archives tag in tenant (destroy)", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        tag = create_blog_tag!(site_id: site.id, name: "Tag to Archive")

        token = sign_in_user(tenant_admin)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}/archive",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status in [200, 204]

        # Verify tag is archived
        archived_tag =
          Ash.get!(MishkaBlog.Tag, tag.id, tenant: site.id, action: :archived, authorize?: false)

        assert %DateTime{} = archived_tag.archived_at
      end

      test "requires authentication for tenant routes", %{site: site} do
        response =
          make_api_request(
            @tenant_base_url,
            %{
              "type" => "tag",
              "attributes" => %{
                "name" => "Test",
                "slug" => "test",
                "language" => "en"
              }
            },
            method: :post,
            headers: [{"x-tenant-id", site.id}]
          )

        assert response.status == 403
      end

      test "tenant admin cannot access another tenant's tags (GET)", %{
        site: site,
        site2: site2,
        tenant_admin: tenant_admin
      } do
        # Create tag in site2
        tag_site2 = create_blog_tag!(site_id: site2.id, name: "Site2 Tag")

        token = sign_in_user(tenant_admin)

        # Try to get site2's tag as site1 admin
        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag_site2.id}",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        # Should return 404 (not found in this tenant context)
        assert response.status == 404
      end

      test "tenant admin cannot update another tenant's tags (PATCH)", %{
        site: site,
        site2: site2,
        tenant_admin: tenant_admin
      } do
        # Create tag in site2
        tag_site2 = create_blog_tag!(site_id: site2.id, name: "Site2 Tag")

        token = sign_in_user(tenant_admin)

        # Try to update site2's tag as site1 admin
        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag_site2.id}",
            %{
              "type" => "tag",
              "attributes" => %{"name" => "Hacked"}
            },
            method: :patch,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        # Should return 404 (not found in this tenant context)
        assert response.status == 404
      end

      test "tenant admin cannot archive another tenant's tags (DELETE)", %{
        site: site,
        site2: site2,
        tenant_admin: tenant_admin
      } do
        # Create tag in site2
        tag_site2 = create_blog_tag!(site_id: site2.id, name: "Site2 Tag")

        token = sign_in_user(tenant_admin)

        # Try to archive site2's tag as site1 admin
        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag_site2.id}/archive",
            %{},
            method: :delete,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        # Should return 404 (not found in this tenant context)
        assert response.status == 404
      end
    end

    describe "/api/json/v1/user/mishka-blog/tag - user public routes" do
      test "GET / - lists all tags (public_list)", %{site: site} do
        # Create some tags
        tag1 = create_blog_tag!(site_id: site.id, name: "Public Tag 1")
        tag2 = create_blog_tag!(site_id: site.id, name: "Public Tag 2")

        response =
          make_api_request(
            @user_base_url,
            %{},
            method: :get,
            headers: [{"x-tenant-id", site.id}]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        tag_ids = Enum.map(body["data"], & &1["id"])

        assert tag1.id in tag_ids
        assert tag2.id in tag_ids
      end

      test "GET /:id - retrieves single tag (public_get)", %{site: site} do
        tag = create_blog_tag!(site_id: site.id, name: "Specific Public Tag")

        response =
          make_api_request(
            "#{@user_base_url}/#{tag.id}",
            %{},
            method: :get,
            headers: [{"x-tenant-id", site.id}]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "Specific Public Tag"
      end

      test "GET / - does not show archived tags (public_list)", %{site: site} do
        active_tag = create_blog_tag!(site_id: site.id, name: "Active Tag")
        archived_tag = create_blog_tag!(site_id: site.id, name: "Archived Tag")
        Ash.destroy!(archived_tag, tenant: site.id, authorize?: false)

        response =
          make_api_request(
            @user_base_url,
            %{},
            method: :get,
            headers: [{"x-tenant-id", site.id}]
          )

        assert response.status == 200

        body = Jason.decode!(response.resp_body)
        tag_ids = Enum.map(body["data"], & &1["id"])

        # Should only see active tag
        assert active_tag.id in tag_ids
        refute archived_tag.id in tag_ids
      end
    end

    describe "PAGINATED INCLUDES - Fetching related posts with pagination" do
      test "master admin can fetch tag with paginated master_posts", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create a tag
        tag = create_blog_tag!(site_id: site.id, name: "Tech Tag")

        # Create 25 blog posts and link them to the tag
        post_ids =
          Enum.map(1..25, fn i ->
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
                authorize?: false,
                tenant: site.id
              )

            # Link post to tag via PostTag join table
            MishkaBlog.PostTag
            |> Ash.Changeset.for_create(
              :assign,
              %{
                post_id: post.id,
                tag_id: tag.id
              },
              authorize?: false
            )
            |> Ash.create!()

            post.id
          end)

        # Fetch tag with paginated master_posts (limit 30 to get all)
        response =
          make_api_request(
            "#{@master_base_url}/#{tag.id}?include=master_posts&included_page[master_posts][limit]=30&included_page[master_posts][offset]=0",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-no-tenant", "true"}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify tag data
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "Tech Tag"

        # Verify master_posts relationship data is present
        relationship_posts = body["data"]["relationships"]["master_posts"]["data"] || []
        assert length(relationship_posts) == 25, "All 25 posts should be in relationships"

        # Verify the relationship post IDs match what we created
        relationship_post_ids = Enum.map(relationship_posts, & &1["id"])
        assert Enum.all?(post_ids, &(&1 in relationship_post_ids))

        # Verify pagination links exist
        assert body["data"]["relationships"]["master_posts"]["links"]["first"] |> is_binary()
        # No "next" link since we fetched all posts with high limit
      end

      test "tenant admin can fetch tag with paginated tenant_posts", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_user(tenant_admin)

        # Create a tag
        tag = create_blog_tag!(site_id: site.id, name: "Tutorial Tag")

        # Create 15 blog posts and link them to the tag
        post_ids =
          Enum.map(1..15, fn i ->
            post =
              Ash.create!(
                MishkaBlog.BlogPost,
                %{
                  title: "Tutorial #{i}",
                  slug: "tutorial-#{i}",
                  content: "Content #{i}",
                  status: :published,
                  language: "en",
                  published_at: DateTime.utc_now()
                },
                actor: tenant_admin,
                tenant: site.id,
                context: @api_surface
              )

            # Link post to tag
            MishkaBlog.PostTag
            |> Ash.Changeset.for_create(
              :assign,
              %{
                post_id: post.id,
                tag_id: tag.id
              },
              actor: tenant_admin,
              context: @api_surface
            )
            |> Ash.create!()

            post.id
          end)

        # Fetch tag with paginated tenant_posts (limit 20 to get all)
        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}?include=tenant_posts&included_page[tenant_posts][limit]=20&included_page[tenant_posts][offset]=0",
            %{},
            method: :get,
            headers: [
              {"authorization", "Bearer #{token}"},
              {"x-tenant-id", site.id}
            ]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify tag data
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "Tutorial Tag"

        # Verify tenant_posts relationship data is present
        relationship_posts = body["data"]["relationships"]["tenant_posts"]["data"] || []
        assert length(relationship_posts) == 15, "All 15 posts should be in relationships"

        # Verify the relationship post IDs match what we created
        relationship_post_ids = Enum.map(relationship_posts, & &1["id"])
        assert Enum.all?(post_ids, &(&1 in relationship_post_ids))

        # Verify pagination links exist
        assert body["data"]["relationships"]["tenant_posts"]["links"]["first"] |> is_binary()
        # No "next" link since we fetched all posts with high limit
      end

      test "public user can fetch tag with paginated posts", %{site: site} do
        # Create a tag
        tag = create_blog_tag!(site_id: site.id, name: "News Tag")

        # Create 20 published blog posts and link them to the tag
        post_ids =
          Enum.map(1..20, fn i ->
            post =
              Ash.create!(
                MishkaBlog.BlogPost,
                %{
                  title: "News #{i}",
                  slug: "news-#{i}",
                  content: "Content #{i}",
                  status: :published,
                  language: "en",
                  published_at: DateTime.utc_now()
                },
                authorize?: false,
                tenant: site.id
              )

            # Link post to tag
            MishkaBlog.PostTag
            |> Ash.Changeset.for_create(
              :assign,
              %{
                post_id: post.id,
                tag_id: tag.id
              },
              authorize?: false
            )
            |> Ash.create!()

            post.id
          end)

        # Fetch tag with paginated posts (no authentication, limit 25 to get all)
        response =
          make_api_request(
            "#{@user_base_url}/#{tag.id}?include=posts&included_page[posts][limit]=25&included_page[posts][offset]=0",
            %{},
            method: :get,
            headers: [{"x-tenant-id", site.id}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify tag data
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "News Tag"

        # Verify posts relationship data is present
        relationship_posts = body["data"]["relationships"]["posts"]["data"] || []

        assert length(relationship_posts) == 20,
               "All 20 published posts should be in relationships"

        # Verify the relationship post IDs match what we created
        relationship_post_ids = Enum.map(relationship_posts, & &1["id"])
        assert Enum.all?(post_ids, &(&1 in relationship_post_ids))

        # Verify pagination links exist
        assert body["data"]["relationships"]["posts"]["links"]["first"] |> is_binary()
        # No "next" link since we fetched all posts with high limit
      end

      test "public user only sees published posts in tag relationships", %{site: site} do
        # Create a tag
        tag = create_blog_tag!(site_id: site.id, name: "Mixed Tag")

        # Create published posts
        published_post =
          Ash.create!(
            MishkaBlog.BlogPost,
            %{
              title: "Published Post",
              slug: "published-post",
              content: "Content",
              status: :published,
              language: "en",
              published_at: DateTime.utc_now()
            },
            authorize?: false,
            tenant: site.id
          )

        # Create draft post
        draft_post =
          Ash.create!(
            MishkaBlog.BlogPost,
            %{
              title: "Draft Post",
              slug: "draft-post",
              content: "Content",
              status: :draft,
              language: "en"
            },
            authorize?: false,
            tenant: site.id
          )

        # Link both posts to tag
        for post <- [published_post, draft_post] do
          MishkaBlog.PostTag
          |> Ash.Changeset.for_create(
            :assign,
            %{
              post_id: post.id,
              tag_id: tag.id
            },
            authorize?: false
          )
          |> Ash.create!()
        end

        # Fetch tag with posts as public user (must specify limit for pagination)
        response =
          make_api_request(
            "#{@user_base_url}/#{tag.id}?include=posts&included_page[posts][limit]=100",
            %{},
            method: :get,
            headers: [{"x-tenant-id", site.id}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify only published post is returned
        relationship_posts = body["data"]["relationships"]["posts"]["data"] || []
        relationship_post_ids = Enum.map(relationship_posts, & &1["id"])

        # Should only see published post, not draft
        assert published_post.id in relationship_post_ids
        refute draft_post.id in relationship_post_ids
      end
    end

    describe "VERSION MANAGEMENT - GET /tag/:id/with-versions" do
      test "tenant admin can get tag with paginated versions", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Create tag and some versions
        tag =
          create_blog_tag!(
            site_id: site.id,
            name: "ORIGINAL",
            description: "Original"
          )

        # Update to create versions
        tag
        |> Ash.Changeset.for_update(:update, %{description: "Version 1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        tag
        |> Ash.Changeset.for_update(:update, %{description: "Version 2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created
        wait_for_version_count("mishka_blog_tag_versions", tag.id, 4)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}/with-versions?fields[tag]=name,description,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == tag.id
        assert body["data"]["attributes"]["name"] == "ORIGINAL"

        # Check sorted_versions in attributes
        sorted_versions = body["data"]["attributes"]["sorted_versions"]
        assert length(sorted_versions) >= 3
      end

      test "tenant admin cannot get tag with versions from another site", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        tag =
          create_blog_tag!(
            site_id: site2.id,
            name: "OTHERSITE"
          )

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}/with-versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can get any tag with versions", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        tag1 = create_blog_tag!(site_id: site.id, name: "SITE1TAG")
        tag2 = create_blog_tag!(site_id: site2.id, name: "SITE2TAG")

        # Create version for tag1
        tag1
        |> Ash.Changeset.for_update(:update, %{description: "Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions
        wait_for_version_count("mishka_blog_tag_versions", tag1.id, 3)
        wait_for_version_count("mishka_blog_tag_versions", tag2.id, 2)

        # Get site1 tag with versions
        response1 =
          make_api_request(
            "#{@master_base_url}/#{tag1.id}/with-versions?fields[tag]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response1.status == 200
        body1 = Jason.decode!(response1.resp_body)
        sorted_versions1 = body1["data"]["attributes"]["sorted_versions"]
        assert length(sorted_versions1) >= 2

        # Get site2 tag with versions
        response2 =
          make_api_request(
            "#{@master_base_url}/#{tag2.id}/with-versions?fields[tag]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)
        sorted_versions2 = body2["data"]["attributes"]["sorted_versions"]
        assert [_ | _] = sorted_versions2
      end
    end

    describe "VERSION MANAGEMENT - Calculations (version_count, latest_version, recent_versions)" do
      test "tenant admin can get version calculations for their tag", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        tag =
          create_blog_tag!(
            site_id: site.id,
            name: "ORIGINAL",
            description: "Desc 1"
          )

        # Create multiple versions
        updated1 =
          tag
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

        # Wait for versions to be created
        wait_for_version_count("mishka_blog_tag_versions", tag.id, 6)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}?fields[tag]=name,description,version_count,latest_version,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Check version_count calculation
        assert body["data"]["attributes"]["version_count"] >= 5

        # Check latest_version calculation
        latest_version = body["data"]["attributes"]["latest_version"]
        assert %{"changes" => %{"description" => "Desc 5"}} = latest_version

        # Check recent_versions calculation (should return up to 10)
        recent_versions = body["data"]["attributes"]["recent_versions"]
        assert length(recent_versions) >= 5

        # Verify they're sorted descending (newest first)
        descriptions = Enum.map(recent_versions, & &1["changes"]["description"])
        assert Enum.at(descriptions, 0) == "Desc 5"
      end

      test "master admin can get version calculations for any tag", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        tag =
          create_blog_tag!(
            site_id: site.id,
            name: "TEST",
            description: "V1"
          )

        # Create versions
        updated1 =
          tag
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

        # Wait for versions
        wait_for_version_count("mishka_blog_tag_versions", tag.id, 4)

        response =
          make_api_request(
            "#{@master_base_url}/#{tag.id}?fields[tag]=name,version_count,latest_version,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert body["data"]["attributes"]["version_count"] >= 3

        latest = body["data"]["attributes"]["latest_version"]
        assert latest["changes"]["description"] == "V3"

        recent = body["data"]["attributes"]["recent_versions"]
        assert length(recent) >= 3
      end

      test "recent_versions limits to 10 versions when more exist", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        tag =
          create_blog_tag!(
            site_id: site.id,
            name: "MANYVERS"
          )

        # Create 12 versions
        updated = tag

        updated =
          Enum.reduce(1..12, updated, fn i, acc ->
            acc
            |> Ash.Changeset.for_update(:update, %{description: "Version #{i}"},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.update!()
          end)

        # Wait for versions
        wait_for_version_count("mishka_blog_tag_versions", tag.id, 14)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{updated.id}?fields[tag]=version_count,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # version_count should be at least 13
        assert body["data"]["attributes"]["version_count"] >= 13

        # recent_versions should be limited to 10
        recent = body["data"]["attributes"]["recent_versions"]
        assert length(recent) == 10

        # Should be newest 10 (sorted descending)
        descriptions = Enum.map(recent, & &1["changes"]["description"])
        assert Enum.at(descriptions, 0) == "Version 12"
      end
    end

    describe "VERSION MANAGEMENT - GET /tag/:id/versions" do
      test "tenant admin can list versions for their tag", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        tag = create_blog_tag!(site_id: site.id, name: "ORIGINAL")

        # Create multiple versions - capture updated results
        updated1 =
          tag
          |> Ash.Changeset.for_update(:update, %{name: "V1"}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        updated2 =
          updated1
          |> Ash.Changeset.for_update(:update, %{name: "V2"}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        _updated3 =
          updated2
          |> Ash.Changeset.for_update(:update, %{name: "V3"}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        # Wait for versions to be created
        wait_for_version_count("mishka_blog_tag_versions", tag.id, 5)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}/versions?fields[tag]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Returns 1 tag with versions loaded
        assert length(body["data"]) == 1

        # Check the versions inside the tag
        tag_data = List.first(body["data"])
        sorted_versions = tag_data["attributes"]["sorted_versions"]
        assert length(sorted_versions) >= 4
      end

      test "tenant admin cannot list versions from another site's tag", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        tag =
          create_blog_tag!(
            site_id: site2.id,
            name: "OTHERSITE"
          )

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}/versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can list versions for any tag", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        tag =
          create_blog_tag!(
            site_id: site.id,
            name: "TEST"
          )

        # Create versions
        tag
        |> Ash.Changeset.for_update(:update, %{name: "UPDATED"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created
        wait_for_version_count("mishka_blog_tag_versions", tag.id, 3)

        response =
          make_api_request(
            "#{@master_base_url}/#{tag.id}/versions?fields[tag]=name,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 1

        # Check the versions inside the tag
        tag_data = List.first(body["data"])
        sorted_versions = tag_data["attributes"]["sorted_versions"]
        assert length(sorted_versions) >= 2
      end
    end

    describe "VERSION MANAGEMENT - PATCH /tag/:id/version/:version_id/restore" do
      test "tenant admin can restore their tag to a previous version", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        tag =
          create_blog_tag!(
            site_id: site.id,
            name: "ORIGINAL",
            description: "Original desc"
          )

        # Create a version
        updated =
          tag
          |> Ash.Changeset.for_update(:update, %{name: "UPDATED", description: "Updated desc"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_tag_versions", tag.id, 2)

        # Get the version
        version =
          MishkaBlog.Tag.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^tag.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{updated.id}/version/#{version.id}/restore",
            %{"type" => "tag", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "ORIGINAL"
        assert body["data"]["attributes"]["description"] == "Original desc"
      end

      test "tenant admin cannot restore another site's tag version", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        tag =
          create_blog_tag!(
            site_id: site2.id,
            name: "OTHER"
          )

        # Create version
        tag
        |> Ash.Changeset.for_update(:update, %{name: "UPDATED"},
          tenant: site2.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_tag_versions", tag.id, 2)

        # Get version
        version =
          MishkaBlog.Tag.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^tag.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}/version/#{version.id}/restore",
            %{"type" => "tag", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can restore any tag version", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        tag =
          create_blog_tag!(
            site_id: site.id,
            name: "ORIGINAL"
          )

        # Create version
        updated =
          tag
          |> Ash.Changeset.for_update(:update, %{name: "UPDATED"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_tag_versions", tag.id, 2)

        # Get version
        version =
          MishkaBlog.Tag.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^tag.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@master_base_url}/#{updated.id}/version/#{version.id}/restore",
            %{"type" => "tag", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "ORIGINAL"
      end

      test "cannot restore version of archived tag", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        tag =
          create_blog_tag!(
            site_id: site.id,
            name: "ORIGINAL"
          )

        # Create version
        tag
        |> Ash.Changeset.for_update(:update, %{name: "UPDATED"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_tag_versions", tag.id, 2)

        # Archive tag
        tag
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Get version
        version =
          MishkaBlog.Tag.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^tag.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}/version/#{version.id}/restore",
            %{"type" => "tag", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status in [400, 404, 422]
      end
    end

    describe "VERSION MANAGEMENT - GET /tag/:id/version/:version_id/preview" do
      test "tenant admin can preview a version without restoring", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        tag =
          create_blog_tag!(
            site_id: site.id,
            name: "ORIGINAL",
            description: "Original desc"
          )

        # Create version
        updated =
          tag
          |> Ash.Changeset.for_update(:update, %{name: "UPDATED", description: "Updated desc"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_tag_versions", tag.id, 2)

        # Get version
        version =
          MishkaBlog.Tag.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^tag.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "ORIGINAL"
        assert body["data"]["attributes"]["description"] == "Original desc"

        # Verify actual tag is unchanged
        current_response =
          make_api_request(
            "#{@tenant_base_url}/#{updated.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        current_body = Jason.decode!(current_response.resp_body)
        assert current_body["data"]["attributes"]["name"] == "UPDATED"
      end

      test "tenant admin cannot preview version from another site", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        tag =
          create_blog_tag!(
            site_id: site2.id,
            name: "OTHER"
          )

        # Create version
        tag
        |> Ash.Changeset.for_update(:update, %{name: "UPDATED"},
          tenant: site2.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_tag_versions", tag.id, 2)

        # Get version
        version =
          MishkaBlog.Tag.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^tag.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@tenant_base_url}/#{tag.id}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can preview any tag version", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        tag =
          create_blog_tag!(
            site_id: site.id,
            name: "ORIGINAL"
          )

        # Create version
        tag
        |> Ash.Changeset.for_update(:update, %{name: "UPDATED"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_tag_versions", tag.id, 2)

        # Get version
        version =
          MishkaBlog.Tag.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^tag.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@master_base_url}/#{tag.id}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["name"] == "ORIGINAL"
      end
    end
  end
end
