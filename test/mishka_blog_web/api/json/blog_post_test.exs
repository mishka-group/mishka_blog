# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Api.Json.BlogPostTest do
  @moduledoc """
  Comprehensive tests for BlogPost JSON API endpoints.
  """

  use MishkaBlog.ConnCase
  import MishkaBlog.Test.Factory
  import MishkaCmsCore.Test.VersionHelpers
  require Ash.Query

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaBlog) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @api_master_path "/api/json/v1/master/admin/mishka-blog/post"
    @api_tenant_path "/api/json/v1/tenant/admin/mishka-blog/post"
    @api_public_path "/api/json/v1/user/mishka-blog/post"

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

    defp comment_statuses(response) do
      response
      |> included("comment")
      |> Enum.map(& &1["attributes"]["status"])
      |> Enum.sort()
    end

    defp assert_no_hidden_comment(response) do
      for body <- ["PENDING-BODY", "FLAGGED-BODY", "SPAM-BODY", "ARCHIVED-BODY"] do
        refute response.resp_body =~ body, "#{body} reached a caller who is not an admin"
      end

      assert Enum.all?(comment_statuses(response), &(&1 == "approved"))
    end

    describe "CREATE - POST /post" do
      test "master admin can create post for any site", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        # Create post for site1
        response =
          make_api_request(
            @api_master_path,
            %{
              "type" => "blog_post",
              "attributes" => %{
                "title" => "Master Post Site1",
                "slug" => "master-post-site1",
                "content" => "<p>Content for site 1</p>",
                "excerpt" => "Excerpt for site 1",
                "status" => "draft",
                "site_id" => site.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Master Post Site1"
        assert body["data"]["attributes"]["slug"] == "master-post-site1"
        assert body["data"]["attributes"]["status"] == "draft"
        assert body["data"]["attributes"]["site_id"] == site.id

        # Create post for site2
        response2 =
          make_api_request(
            @api_master_path,
            %{
              "type" => "blog_post",
              "attributes" => %{
                "title" => "Master Post Site2",
                "slug" => "master-post-site2",
                "content" => "<p>Content for site 2</p>",
                "status" => "published",
                "site_id" => site2.id
              }
            },
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 201
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["attributes"]["title"] == "Master Post Site2"
        assert body2["data"]["attributes"]["site_id"] == site2.id
      end

      test "tenant admin can create post only for their own site", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Successfully create post for their own site
        response =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "blog_post",
              "attributes" => %{
                "title" => "Tenant Post",
                "slug" => "tenant-post",
                "content" => "<p>Tenant content</p>",
                "status" => "draft"
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Tenant Post"
        assert body["data"]["attributes"]["site_id"] == site.id
      end
    end

    describe "READ - GET /post (list and get)" do
      test "master admin can list posts from all sites", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        # Create posts for different sites
        post1 =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Post 1",
              slug: "post-1",
              content: "Content 1",
              status: :published,
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        post2 =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Post 2",
              slug: "post-2",
              content: "Content 2",
              status: :published,
              site_id: site2.id
            },
            tenant: site2.id,
            authorize?: false
          )
          |> Ash.create!()

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

        ids = Enum.map(body["data"], & &1["id"])
        assert post1.id in ids
        assert post2.id in ids
      end

      test "tenant admin can list only their own site's posts", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        # Create posts for different sites
        post1 =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Own Post", slug: "own-post", content: "Content", status: :published},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        post2 =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Other Post", slug: "other-post", content: "Content", status: :published},
            tenant: site2.id,
            authorize?: false
          )
          |> Ash.create!()

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
        assert post1.id in ids
        refute post2.id in ids
      end

      test "master admin can get any post by id", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Test Post",
              slug: "test-post",
              content: "Test content",
              status: :published,
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        response =
          make_api_request(
            "#{@api_master_path}/#{post.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == post.id
        assert body["data"]["attributes"]["title"] == "Test Post"
      end

      test "tenant admin can get only their own site's post", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        post1 =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Own", slug: "own", content: "Content", status: :published},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        post2 =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Other", slug: "other", content: "Content", status: :published},
            tenant: site2.id,
            authorize?: false
          )
          |> Ash.create!()

        # Can get own site's post
        response =
          make_api_request(
            "#{@api_tenant_path}/#{post1.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == post1.id

        # Cannot get another site's post
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{post2.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "UPDATE - PATCH /post" do
      test "master admin can update any post", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Old Title",
              slug: "old-title",
              content: "Old content",
              status: :draft,
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        response =
          make_api_request(
            "#{@api_master_path}/#{post.id}",
            %{
              "type" => "blog_post",
              "attributes" => %{
                "title" => "Updated Title",
                "content" => "Updated content"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Updated Title"
        assert body["data"]["attributes"]["content"] == "Updated content"
      end

      test "tenant admin can update only their own site's post", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        post_own =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Own", slug: "own", content: "Content", status: :draft},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        post_other =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Other", slug: "other", content: "Content", status: :draft},
            tenant: site2.id,
            authorize?: false
          )
          |> Ash.create!()

        # Can update own site's post
        response =
          make_api_request(
            "#{@api_tenant_path}/#{post_own.id}",
            %{
              "type" => "blog_post",
              "attributes" => %{
                "title" => "Updated Own"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Updated Own"

        # Cannot update another site's post
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{post_other.id}",
            %{
              "type" => "blog_post",
              "attributes" => %{
                "title" => "Hacked"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "PUBLISH/UNPUBLISH - Status management" do
      test "master admin can publish and unpublish posts", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Draft Post",
              slug: "draft-post",
              content: "Content",
              status: :draft,
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Publish the post
        response =
          make_api_request(
            "#{@api_master_path}/#{post.id}/publish",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["status"] == "published"

        # Unpublish the post
        response2 =
          make_api_request(
            "#{@api_master_path}/#{post.id}/unpublish",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["attributes"]["status"] == "draft"
      end

      test "tenant admin can publish and unpublish their own posts", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Draft", slug: "draft", content: "Content", status: :draft},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Publish
        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}/publish",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["status"] == "published"

        # Unpublish
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}/unpublish",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["attributes"]["status"] == "draft"
      end
    end

    describe "DELETE - Soft delete (archive)" do
      test "master admin can archive any post", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "To Archive",
              slug: "to-archive",
              content: "Content",
              status: :published,
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        response =
          make_api_request(
            "#{@api_master_path}/#{post.id}/archive",
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
        refute post.id in ids
      end

      test "tenant admin can archive their own site's post", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        post_own =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Own", slug: "own", content: "Content", status: :published},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        post_other =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Other", slug: "other", content: "Content", status: :published},
            tenant: site2.id,
            authorize?: false
          )
          |> Ash.create!()

        # Can archive own site's post
        response =
          make_api_request(
            "#{@api_tenant_path}/#{post_own.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Cannot archive another site's post
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{post_other.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "ARCHIVED - Working with archived records" do
      test "master admin can list and restore archived posts", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create and archive post
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Archived Post",
              slug: "archived-post",
              content: "Content",
              status: :published,
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        post
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

        # List archived posts
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
        assert post.id in ids

        # Unarchive it
        response2 =
          make_api_request(
            "#{@api_master_path}/#{post.id}/unarchive",
            %{
              "type" => "blog_post",
              "attributes" => %{}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 200
      end
    end

    describe "PUBLIC - Unauthenticated access" do
      test "anyone can list published posts", %{site: site} do
        # Create published and draft posts
        published =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Published Post",
              slug: "published-post",
              content: "Content",
              status: :published
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        draft =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Draft Post", slug: "draft-post", content: "Content", status: :draft},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        response =
          make_api_request(
            "#{@api_public_path}/published",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert published.id in ids
        # Draft post should not be in the list
        refute draft.id in ids
      end

      test "anyone can get published post by id", %{site: site} do
        published_post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Public Post",
              slug: "public-post",
              content: "<p>Public content</p>",
              excerpt: "Public excerpt",
              status: :published
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        response =
          make_api_request(
            "#{@api_public_path}/published/#{published_post.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == published_post.id
        assert body["data"]["attributes"]["title"] == "Public Post"
      end

      test "draft posts are not accessible via public endpoints", %{site: site} do
        draft_post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Draft", slug: "draft", content: "Content", status: :draft},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        response =
          make_api_request(
            "#{@api_public_path}/published/#{draft_post.id}",
            %{},
            method: :get,
            headers: []
          )

        # Should return 404 or 403 because it's not published
        assert response.status in [403, 404]
      end
    end

    describe "Paginated relationships - BlogPost with collections" do
      test "public can include post collections with pagination", %{site: site} do
        # Create post
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Post with Collections",
              slug: "post-with-collections",
              content: "Content",
              status: :published
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 15 collections and add post to them
        collection_ids =
          Enum.map(1..15, fn i ->
            collection =
              MishkaBlog.Collection
              |> Ash.Changeset.for_create(
                :create,
                %{
                  name: "Collection #{i}",
                  slug: "collection-#{i}",
                  description: "Desc #{i}",
                  status: :active
                },
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            MishkaBlog.PostCollection
            |> Ash.Changeset.for_create(
              :assign,
              %{post_id: post.id, collection_id: collection.id},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

            collection.id
          end)

        # Fetch post with paginated collections (limit 10)
        response =
          make_api_request(
            "#{@api_public_path}/published/#{post.id}?include=collections&included_page[collections][limit]=10&included_page[collections][offset]=0",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify post data
        assert body["data"]["id"] == post.id

        # Verify included collections (should be limited to 10)

        collection_records =
          Enum.filter(body["included"], fn inc -> inc["type"] == "collection" end)

        assert length(collection_records) == 10

        # Verify all included collections are from our created list
        included_collection_ids = Enum.map(collection_records, & &1["id"])
        Enum.each(included_collection_ids, fn id -> assert id in collection_ids end)
      end

      test "tenant admin can include tenant_collections with pagination", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Tenant Post", slug: "tenant-post", content: "Content", status: :draft},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 12 collections
        _collection_ids =
          Enum.map(1..12, fn i ->
            collection =
              MishkaBlog.Collection
              |> Ash.Changeset.for_create(
                :create,
                %{name: "Col #{i}", slug: "col-#{i}", status: :active},
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            MishkaBlog.PostCollection
            |> Ash.Changeset.for_create(
              :assign,
              %{post_id: post.id, collection_id: collection.id},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

            collection.id
          end)

        # Fetch post with paginated tenant_collections
        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}?include=tenant_collections&included_page[tenant_collections][limit]=8",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        collection_records =
          Enum.filter(body["included"], fn inc -> inc["type"] == "collection" end)

        assert length(collection_records) == 8
      end

      test "master admin can include master_collections with pagination", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Master Post",
              slug: "master-post",
              content: "Content",
              status: :published,
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 20 collections
        _collection_ids =
          Enum.map(1..20, fn i ->
            collection =
              MishkaBlog.Collection
              |> Ash.Changeset.for_create(
                :create,
                %{name: "MC #{i}", slug: "mc-#{i}", status: :active},
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            MishkaBlog.PostCollection
            |> Ash.Changeset.for_create(
              :assign,
              %{post_id: post.id, collection_id: collection.id},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

            collection.id
          end)

        # Fetch post with paginated master_collections
        response =
          make_api_request(
            "#{@api_master_path}/#{post.id}?include=master_collections&included_page[master_collections][limit]=15",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        collection_records =
          Enum.filter(body["included"], fn inc -> inc["type"] == "collection" end)

        assert length(collection_records) == 15
      end
    end

    describe "Paginated relationships - BlogPost with tags" do
      test "public can include post tags with pagination", %{site: site} do
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Tagged Post", slug: "tagged-post", content: "Content", status: :published},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 18 tags
        tag_ids =
          Enum.map(1..18, fn i ->
            tag =
              MishkaBlog.Tag
              |> Ash.Changeset.for_create(
                :create,
                %{name: "Tag #{i}", slug: "tag-#{i}"},
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            MishkaBlog.PostTag
            |> Ash.Changeset.for_create(
              :assign,
              %{post_id: post.id, tag_id: tag.id},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

            tag.id
          end)

        # Fetch post with paginated tags
        response =
          make_api_request(
            "#{@api_public_path}/published/#{post.id}?include=tags&included_page[tags][limit]=10",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        tag_records = Enum.filter(body["included"], fn inc -> inc["type"] == "tag" end)
        assert length(tag_records) == 10

        included_tag_ids = Enum.map(tag_records, & &1["id"])
        Enum.each(included_tag_ids, fn id -> assert id in tag_ids end)
      end

      test "tenant admin can include tenant_tags with pagination", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Post", slug: "post", content: "Content", status: :draft},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 25 tags
        _tag_ids =
          Enum.map(1..25, fn i ->
            tag =
              MishkaBlog.Tag
              |> Ash.Changeset.for_create(
                :create,
                %{name: "TTag #{i}", slug: "ttag-#{i}"},
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            MishkaBlog.PostTag
            |> Ash.Changeset.for_create(
              :assign,
              %{post_id: post.id, tag_id: tag.id},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

            tag.id
          end)

        # Fetch with pagination
        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}?include=tenant_tags&included_page[tenant_tags][limit]=15",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        tag_records = Enum.filter(body["included"], fn inc -> inc["type"] == "tag" end)
        assert length(tag_records) == 15
      end
    end

    describe "Paginated relationships - BlogPost with comments and authors" do
      test "public can include comments.author with pagination", %{site: site} do
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Commented Post",
              slug: "commented-post",
              content: "Content",
              status: :published
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 20 approved comments with users
        comment_data =
          Enum.map(1..20, fn i ->
            user = create_user!(site_id: site.id, email: "commenter#{i}@example.com")

            comment =
              MishkaBlog.Comment
              |> Ash.Changeset.for_create(
                :create,
                %{
                  post_id: post.id,
                  content: "Comment #{i}",
                  author_id: user.id,
                  status: :approved
                },
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            %{comment_id: comment.id, user_id: user.id}
          end)

        # Fetch post with paginated comments.author
        response =
          make_api_request(
            "#{@api_public_path}/published/#{post.id}?include=comments.author&included_page[comments][limit]=10",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify comments are included (limited to 10)
        comment_records = Enum.filter(body["included"], fn inc -> inc["type"] == "comment" end)
        assert length(comment_records) == 10

        # Verify users are included (should be 10 users for 10 comments)
        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)
        assert length(user_records) == 10

        # Verify all users are from our created list
        included_user_ids = Enum.map(user_records, & &1["id"])
        all_user_ids = Enum.map(comment_data, & &1.user_id)
        Enum.each(included_user_ids, fn id -> assert id in all_user_ids end)

        # A visitor gets who wrote each comment, never the account behind it.
        assert Enum.all?(user_records, &(account_fields(&1) == %{}))
        refute response.resp_body =~ "@example.com"
      end

      test "tenant admin can include tenant_comments.author with pagination", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Post", slug: "post-t", content: "Content", status: :draft},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 15 comments with different statuses
        _comment_data =
          Enum.map(1..15, fn i ->
            user = create_user!(site_id: site.id, email: "tcommenter#{i}@example.com")
            status = if rem(i, 2) == 0, do: :approved, else: :pending

            comment =
              MishkaBlog.Comment
              |> Ash.Changeset.for_create(
                :create,
                %{
                  post_id: post.id,
                  content: "TComment #{i}",
                  author_id: user.id,
                  status: status
                },
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            %{comment_id: comment.id, user_id: user.id}
          end)

        # Fetch with pagination - tenant admin should see all comments (not just approved)
        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}?include=tenant_comments.author&included_page[tenant_comments][limit]=10",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        comment_records = Enum.filter(body["included"], fn inc -> inc["type"] == "comment" end)
        assert length(comment_records) == 10

        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)
        assert length(user_records) == 10
      end

      test "master admin can include master_comments.author with pagination", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Master Post",
              slug: "master-post-c",
              content: "Content",
              status: :published,
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 30 comments
        _comment_data =
          Enum.map(1..30, fn i ->
            user = create_user!(site_id: site.id, email: "mcommenter#{i}@example.com")

            comment =
              MishkaBlog.Comment
              |> Ash.Changeset.for_create(
                :create,
                %{
                  post_id: post.id,
                  content: "MComment #{i}",
                  author_id: user.id,
                  status: :approved
                },
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            %{comment_id: comment.id, user_id: user.id}
          end)

        # Fetch with pagination
        response =
          make_api_request(
            "#{@api_master_path}/#{post.id}?include=master_comments.author&included_page[master_comments][limit]=20",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        comment_records = Enum.filter(body["included"], fn inc -> inc["type"] == "comment" end)
        assert length(comment_records) == 20

        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)
        assert length(user_records) == 20
      end

      test "public only sees approved comments", %{site: site} do
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Post", slug: "post-status", content: "Content", status: :published},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 5 approved and 5 pending comments
        approved_count = 5

        Enum.each(1..5, fn i ->
          user = create_user!(site_id: site.id, email: "approved#{i}@example.com")

          MishkaBlog.Comment
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              content: "Approved #{i}",
              author_id: user.id,
              status: :approved
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end)

        Enum.each(1..5, fn i ->
          user = create_user!(site_id: site.id, email: "pending#{i}@example.com")

          MishkaBlog.Comment
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              content: "Pending #{i}",
              author_id: user.id,
              status: :pending
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end)

        # Public should only see approved comments
        response =
          make_api_request(
            "#{@api_public_path}/published/#{post.id}?include=comments&included_page[comments][limit]=20",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        comment_records = Enum.filter(body["included"], fn inc -> inc["type"] == "comment" end)
        # Should only get approved comments
        assert length(comment_records) == approved_count
      end
    end

    describe "Comments a visitor can reach through a published post" do
      setup %{site: site} do
        post = create_blog_post!(site_id: site.id, status: :published)
        pending_author = create_user!(site_id: site.id, email: "pending-author@example.com")

        for {status, content} <- [
              approved: "APPROVED-BODY",
              pending: "PENDING-BODY",
              flagged: "FLAGGED-BODY",
              spam: "SPAM-BODY"
            ] do
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            status: status,
            content: content,
            author_id: pending_author.id
          )
        end

        create_comment!(
          site_id: site.id,
          post_id: post.id,
          status: :approved,
          content: "ARCHIVED-BODY"
        )
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false, tenant: site.id)
        |> Ash.destroy!()

        %{post: post, pending_author: pending_author}
      end

      test "an anonymous include=tenant_comments on one post is refused", %{post: post} do
        response =
          make_api_request(
            "#{@api_public_path}/published/#{post.id}?include=tenant_comments",
            %{},
            method: :get
          )

        assert response.status == 403
        assert_no_hidden_comment(response)
      end

      test "an anonymous include=tenant_comments on the listing is refused", %{post: _post} do
        response =
          make_api_request("#{@api_public_path}/published?include=tenant_comments", %{},
            method: :get
          )

        assert response.status == 403
        assert_no_hidden_comment(response)
      end

      test "an anonymous include=tenant_comments.author names no hidden comment's author", %{
        post: post,
        pending_author: pending_author
      } do
        response =
          make_api_request(
            "#{@api_public_path}/published/#{post.id}?include=tenant_comments.author",
            %{},
            method: :get
          )

        assert response.status == 403
        assert_no_hidden_comment(response)
        refute response.resp_body =~ to_string(pending_author.email)
      end

      test "a signed-in user who is not an admin is refused the same include", %{
        post: post,
        site: site
      } do
        reader =
          create_user!(
            email: "reader@example.com",
            password: @password,
            password_confirmation: @password,
            site_id: site.id
          )

        token = sign_in_tenant(reader)

        for path <- [
              "#{@api_public_path}/published/#{post.id}?include=tenant_comments",
              "#{@api_public_path}/published?include=tenant_comments"
            ] do
          response =
            make_api_request(path, %{},
              method: :get,
              headers: [{"authorization", "Bearer #{token}"}]
            )

          assert response.status == 403, "#{path} answered #{response.status}"
          assert_no_hidden_comment(response)
        end
      end

      test "loading tenant_comments through the public read with no actor never returns a hidden comment",
           %{post: post, site: site} do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Ash.get(MishkaBlog.BlogPost, post.id,
                   action: :public_get,
                   load: [:tenant_comments],
                   actor: nil,
                   tenant: site.id
                 )
      end

      test "include=comments still returns the approved comment, and only it", %{post: post} do
        response =
          make_api_request(
            "#{@api_public_path}/published/#{post.id}?include=comments",
            %{},
            method: :get
          )

        assert response.status == 200

        assert Enum.map(included(response, "comment"), & &1["attributes"]["content"]) == [
                 "APPROVED-BODY"
               ]
      end

      test "comment_count no longer counts hidden comments for a visitor; approved_comment_count does the public job",
           %{post: post} do
        response =
          make_api_request(
            "#{@api_public_path}/published/#{post.id}?fields[blog_post]=comment_count,approved_comment_count",
            %{},
            method: :get
          )

        assert response.status == 200
        attributes = Jason.decode!(response.resp_body)["data"]["attributes"]

        refute Map.has_key?(attributes, "comment_count")
        assert attributes["approved_comment_count"] == 1
      end

      test "a visitor cannot find posts with hidden comments by filtering on them", %{post: post} do
        for query <- ["filter[tenant_comments][status]=pending", "filter[comment_count]=4"] do
          response =
            make_api_request("#{@api_public_path}/published?#{query}", %{}, method: :get)

          assert response.status == 200, "#{query} answered #{response.status}"
          ids = Enum.map(Jason.decode!(response.resp_body)["data"], & &1["id"])
          refute post.id in ids, "#{query} picked out the post that has hidden comments"
        end
      end

      test "a tenant admin still moderates every status through include=tenant_comments", %{
        post: post,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}?include=tenant_comments&fields[blog_post]=comment_count,approved_comment_count",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        assert comment_statuses(response) == ["approved", "flagged", "pending", "spam"]
        refute response.resp_body =~ "ARCHIVED-BODY"

        attributes = Jason.decode!(response.resp_body)["data"]["attributes"]
        assert attributes["comment_count"] == 4
        assert attributes["approved_comment_count"] == 1
      end

      test "a master admin still moderates every status through include=master_comments", %{
        post: post,
        master_user: master_user
      } do
        token = sign_in_master(master_user)

        response =
          make_api_request("#{@api_master_path}/#{post.id}?include=master_comments", %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        assert comment_statuses(response) == ["approved", "flagged", "pending", "spam"]
      end
    end

    describe "Accounts a visitor can reach through a published post" do
      setup %{site: site} do
        post = create_blog_post!(site_id: site.id, status: :published)

        # The account holds a site and a permission, so an empty answer for either is it withheld.
        author =
          create_user_with_permissions!(["admin:dashboard:blog:comment"],
            site_id: site.id,
            email: "commenter@example.com"
          )

        create_blogger!(
          site_id: site.id,
          user_id: author.id,
          display_name: "Commenter Profile",
          slug: "commenter-profile"
        )

        create_comment!(
          site_id: site.id,
          post_id: post.id,
          status: :approved,
          content: "Visible",
          author_id: author.id
        )

        %{post: post, author: author}
      end

      test "include=comments.author gives a visitor the author's id and no account field", %{
        post: post,
        author: author
      } do
        response =
          make_api_request(
            "#{@api_public_path}/published/#{post.id}?include=comments.author",
            %{},
            method: :get
          )

        assert response.status == 200
        assert [user] = included(response, "user")
        assert user["id"] == author.id
        assert account_fields(user) == %{}
        assert included(response, "site") == []
        refute response.resp_body =~ to_string(author.email)
      end

      test "a visitor naming the account's fields and relationships outright still gets none", %{
        post: post,
        author: author
      } do
        response =
          make_api_request(
            "#{@api_public_path}/published/#{post.id}?include=comments.author&fields[user]=email,confirmed_at,site_id,site,permissions,permission_values",
            %{},
            method: :get
          )

        assert response.status == 200
        assert [user] = included(response, "user")
        assert account_fields(user) == %{}
        assert included(response, "site") == []
        assert included(response, "permission") == []
        refute response.resp_body =~ to_string(author.email)
      end

      test "include=comments.author_profile gives a visitor the author's public profile", %{
        post: post,
        author: author
      } do
        response =
          make_api_request(
            "#{@api_public_path}/published/#{post.id}?include=comments.author_profile",
            %{},
            method: :get
          )

        assert response.status == 200
        assert [profile] = included(response, "blogger")
        assert profile["attributes"]["display_name"] == "Commenter Profile"
        refute response.resp_body =~ to_string(author.email)
      end

      test "a tenant admin gets the full account through include=tenant_comments.author", %{
        post: post,
        author: author,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)

        response =
          make_api_request("#{@api_tenant_path}/#{post.id}?include=tenant_comments.author", %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        assert [user] = included(response, "user")
        assert user["attributes"]["email"] == to_string(author.email)
        assert user["attributes"]["site_id"] == author.site_id
        assert user["attributes"]["site"]["id"] == author.site_id
        assert user["attributes"]["permission_values"] == ["admin:dashboard:blog:comment"]
      end

      test "a master admin gets the full account through include=master_comments.author", %{
        post: post,
        author: author,
        master_user: master_user
      } do
        token = sign_in_master(master_user)

        response =
          make_api_request("#{@api_master_path}/#{post.id}?include=master_comments.author", %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        assert [user] = included(response, "user")
        assert user["attributes"]["email"] == to_string(author.email)
      end
    end

    describe "Paginated relationships - BlogPost with bloggers and users" do
      test "public can include bloggers.user with pagination", %{site: site} do
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Multi-author Post",
              slug: "multi-author-post",
              content: "Content",
              status: :published
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 12 bloggers with users
        blogger_data =
          Enum.map(1..12, fn i ->
            user = create_user!(site_id: site.id, email: "author#{i}@example.com")

            blogger =
              MishkaBlog.Blogger
              |> Ash.Changeset.for_create(
                :create,
                %{user_id: user.id, display_name: "Author #{i}", slug: "author-#{i}"},
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

            %{blogger_id: blogger.id, user_id: user.id}
          end)

        # Fetch post with paginated bloggers.user
        response =
          make_api_request(
            "#{@api_public_path}/published/#{post.id}?include=bloggers.user&included_page[bloggers][limit]=8",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify bloggers are included (limited to 8)
        blogger_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)
        assert length(blogger_records) == 8

        # Verify users are included (should be 8 users for 8 bloggers)
        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)
        assert length(user_records) == 8

        # Verify all users are from our created list
        included_user_ids = Enum.map(user_records, & &1["id"])
        all_user_ids = Enum.map(blogger_data, & &1.user_id)
        Enum.each(included_user_ids, fn id -> assert id in all_user_ids end)

        # The blogger is the public profile; the account behind it stays with its owner and admins.
        assert Enum.all?(
                 blogger_records,
                 &String.starts_with?(&1["attributes"]["display_name"], "Author ")
               )

        assert Enum.all?(user_records, &(account_fields(&1) == %{}))
        refute response.resp_body =~ "@example.com"
      end

      test "tenant admin can include tenant_bloggers.user with pagination", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Post", slug: "post-b", content: "Content", status: :draft},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 20 bloggers
        _blogger_data =
          Enum.map(1..20, fn i ->
            user = create_user!(site_id: site.id, email: "tblogger#{i}@example.com")

            blogger =
              MishkaBlog.Blogger
              |> Ash.Changeset.for_create(
                :create,
                %{user_id: user.id, display_name: "TBlogger #{i}", slug: "tblogger-#{i}"},
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

            %{blogger_id: blogger.id, user_id: user.id}
          end)

        # Fetch with pagination
        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}?include=tenant_bloggers.user&included_page[tenant_bloggers][limit]=12",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        blogger_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)
        assert length(blogger_records) == 12

        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)
        assert length(user_records) == 12
      end

      test "master admin can include master_bloggers.user with pagination", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Master Post",
              slug: "master-post-b",
              content: "Content",
              status: :published,
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 25 bloggers
        _blogger_data =
          Enum.map(1..25, fn i ->
            user = create_user!(site_id: site.id, email: "mblogger#{i}@example.com")

            blogger =
              MishkaBlog.Blogger
              |> Ash.Changeset.for_create(
                :create,
                %{user_id: user.id, display_name: "MBlogger #{i}", slug: "mblogger-#{i}"},
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

            %{blogger_id: blogger.id, user_id: user.id}
          end)

        # Fetch with pagination
        response =
          make_api_request(
            "#{@api_master_path}/#{post.id}?include=master_bloggers.user&included_page[master_bloggers][limit]=15",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        blogger_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)
        assert length(blogger_records) == 15

        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)
        assert length(user_records) == 15
      end
    end

    describe "Paginated relationships - Combined includes" do
      test "can combine multiple paginated relationships in one request", %{site: site} do
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Rich Post", slug: "rich-post", content: "Content", status: :published},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 10 collections
        Enum.each(1..10, fn i ->
          collection =
            MishkaBlog.Collection
            |> Ash.Changeset.for_create(
              :create,
              %{name: "Col #{i}", slug: "col-c-#{i}", status: :active},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

          MishkaBlog.PostCollection
          |> Ash.Changeset.for_create(
            :assign,
            %{post_id: post.id, collection_id: collection.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end)

        # Create 15 tags
        Enum.each(1..15, fn i ->
          tag =
            MishkaBlog.Tag
            |> Ash.Changeset.for_create(
              :create,
              %{name: "Tag #{i}", slug: "tag-c-#{i}"},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

          MishkaBlog.PostTag
          |> Ash.Changeset.for_create(
            :assign,
            %{post_id: post.id, tag_id: tag.id},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end)

        # Create 20 comments
        Enum.each(1..20, fn i ->
          user = create_user!(site_id: site.id, email: "combo#{i}@example.com")

          MishkaBlog.Comment
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              content: "Comment #{i}",
              author_id: user.id,
              status: :approved
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end)

        # Fetch post with multiple paginated relationships
        response =
          make_api_request(
            "#{@api_public_path}/published/#{post.id}?include=collections,tags,comments.author&included_page[collections][limit]=5&included_page[tags][limit]=8&included_page[comments][limit]=12",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        collection_records =
          Enum.filter(body["included"], fn inc -> inc["type"] == "collection" end)

        tag_records = Enum.filter(body["included"], fn inc -> inc["type"] == "tag" end)
        comment_records = Enum.filter(body["included"], fn inc -> inc["type"] == "comment" end)
        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)

        # Verify each relationship respects its own pagination limit
        assert length(collection_records) == 5
        assert length(tag_records) == 8
        assert length(comment_records) == 12
        assert length(user_records) == 12
        assert Enum.all?(user_records, &(account_fields(&1) == %{}))
      end
    end

    describe "STATUS-SPECIFIC LISTINGS - Tenant Admin" do
      test "tenant admin can list published posts", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin)

        # Create posts with different statuses
        published1 =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Published 1",
              slug: "published-1",
              content: "Content",
              status: :published
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        published2 =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Published 2",
              slug: "published-2",
              content: "Content",
              status: :published
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        draft =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Draft", slug: "draft-1", content: "Content", status: :draft},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        response =
          make_api_request(
            "#{@api_tenant_path}/published",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert published1.id in ids
        assert published2.id in ids
        # Draft should not be in published list
        refute draft.id in ids
      end

      test "tenant admin can list draft posts", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin)

        # Create posts with different statuses
        draft1 =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Draft 1", slug: "draft-1-t", content: "Content", status: :draft},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        draft2 =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Draft 2", slug: "draft-2-t", content: "Content", status: :draft},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        _published =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Published",
              slug: "published-t",
              content: "Content",
              status: :published
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        response =
          make_api_request(
            "#{@api_tenant_path}/drafts",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert draft1.id in ids
        assert draft2.id in ids
      end

      test "tenant admin can list scheduled posts", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin)

        future_time = DateTime.utc_now() |> DateTime.add(3600, :second)

        # Create scheduled post
        scheduled =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Scheduled Post",
              slug: "scheduled-post",
              content: "Content",
              status: :scheduled,
              scheduled_publish_at: future_time
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        draft =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "Draft", slug: "draft-sch", content: "Content", status: :draft},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        response =
          make_api_request(
            "#{@api_tenant_path}/scheduled",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert scheduled.id in ids
        refute draft.id in ids
      end

      test "tenant admin can list featured posts", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin)

        # Create featured post
        featured =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Featured Post",
              slug: "featured-post",
              content: "Content",
              status: :published,
              featured: true
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        _not_featured =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Not Featured",
              slug: "not-featured",
              content: "Content",
              status: :published,
              featured: false
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        response =
          make_api_request(
            "#{@api_tenant_path}/featured",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert featured.id in ids
      end

      test "tenant admin can list archived posts", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin)

        # Create and archive post
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "To Archive",
              slug: "to-archive-t",
              content: "Content",
              status: :published
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        post
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
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
        assert post.id in ids
      end

      test "tenant admin can get individual archived post", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Create and archive post
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Archived Post",
              slug: "archived-post-t",
              content: "Archived content",
              status: :published
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        post
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        response =
          make_api_request(
            "#{@api_tenant_path}/archived/#{post.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == post.id
        assert body["data"]["attributes"]["title"] == "Archived Post"
      end
    end

    describe "SCHEDULE - Scheduling posts" do
      test "tenant admin can schedule a post", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin)

        # Create draft post
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{title: "To Schedule", slug: "to-schedule-t", content: "Content", status: :draft},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        future_time = DateTime.utc_now() |> DateTime.add(7200, :second)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}/schedule",
            %{
              "type" => "blog_post",
              "attributes" => %{
                "scheduled_publish_at" => DateTime.to_iso8601(future_time)
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["status"] == "scheduled"

        assert {:ok, %DateTime{}, _offset} =
                 DateTime.from_iso8601(body["data"]["attributes"]["scheduled_publish_at"])
      end

      test "master admin can schedule a post", %{master_user: master_user, site: site} do
        token = sign_in_master(master_user)

        # Create draft post
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "To Schedule Master",
              slug: "to-schedule-m",
              content: "Content",
              status: :draft,
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        future_time = DateTime.utc_now() |> DateTime.add(7200, :second)

        response =
          make_api_request(
            "#{@api_master_path}/#{post.id}/schedule",
            %{
              "type" => "blog_post",
              "attributes" => %{
                "scheduled_publish_at" => DateTime.to_iso8601(future_time)
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["status"] == "scheduled"
      end
    end

    describe "UNARCHIVE - Restoring archived posts" do
      test "tenant admin can unarchive their own post", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Create and archive post
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "To Unarchive",
              slug: "to-unarchive-t",
              content: "Content",
              status: :published
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        post
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Unarchive it
        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}/unarchive",
            %{
              "type" => "blog_post",
              "attributes" => %{}
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == post.id
        # Should be visible in regular list now
      end
    end

    describe "PERMANENT DELETE" do
      test "tenant admin can permanently delete their own post", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Create post (do not archive first - permanent delete works on active records)
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "To Delete Permanently",
              slug: "to-delete-perm-t",
              content: "Content",
              status: :draft
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        post_id = post.id

        # Permanently delete it
        response =
          make_api_request(
            "#{@api_tenant_path}/#{post_id}/permanent",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Verify it's completely gone (not even in archived)
        archived_response =
          make_api_request(
            "#{@api_tenant_path}/archived",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        archived_body = Jason.decode!(archived_response.resp_body)
        archived_ids = Enum.map(archived_body["data"], & &1["id"])
        refute post_id in archived_ids
      end

      test "master admin can permanently delete any post", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create post (do not archive first - permanent delete works on active records)
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "To Delete Permanently Master",
              slug: "to-delete-perm-m",
              content: "Content",
              status: :draft,
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        post_id = post.id

        # Permanently delete it
        response =
          make_api_request(
            "#{@api_master_path}/#{post_id}/permanent",
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
        refute post_id in archived_ids
      end
    end

    describe "LANGUAGE VARIANTS - Multilingual posts" do
      test "tenant admin can list language variants", %{tenant_admin: tenant_admin, site: site} do
        token = sign_in_tenant(tenant_admin)

        # Create posts in same language group: the first post's own group, which the second joins
        post_en =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "English Post",
              slug: "english-post",
              content: "English content",
              status: :published,
              language: "en"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        language_group_id = post_en.language_group_id

        post_es =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Spanish Post",
              slug: "spanish-post",
              content: "Spanish content",
              status: :published,
              language: "es",
              language_group_id: language_group_id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Different language group
        _other_post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Other Post",
              slug: "other-post",
              content: "Content",
              status: :published,
              language: "en"
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        response =
          make_api_request(
            "#{@api_tenant_path}/language-variants?language_group_id=#{language_group_id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert post_en.id in ids
        assert post_es.id in ids
        # Should only contain posts from same language group
        assert length(ids) == 2
      end

      test "master admin can list language variants across all sites", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        post_en =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Master English",
              slug: "master-english",
              content: "Content",
              status: :published,
              language: "en",
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        language_group_id = post_en.language_group_id

        post_fr =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Master French",
              slug: "master-french",
              content: "Content",
              status: :published,
              language: "fr",
              language_group_id: language_group_id,
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        response =
          make_api_request(
            "#{@api_master_path}/language-variants?language_group_id=#{language_group_id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        ids = Enum.map(body["data"], & &1["id"])
        assert post_en.id in ids
        assert post_fr.id in ids
      end
    end

    describe "ARCHIVED - Individual archived post retrieval" do
      test "master admin can get individual archived post", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create and archive post
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Archived Master Post",
              slug: "archived-master-post",
              content: "Archived content",
              status: :published,
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        post
        |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
        |> Ash.destroy!(return_destroyed?: true)

        response =
          make_api_request(
            "#{@api_master_path}/archived/#{post.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == post.id
        assert body["data"]["attributes"]["title"] == "Archived Master Post"
      end
    end

    describe "Pagination with relationships - Status-specific listings" do
      test "tenant admin can list published posts with paginated collections", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Create published post with collections
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Published with Collections",
              slug: "pub-with-coll",
              content: "Content",
              status: :published
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 15 collections
        _collection_ids =
          Enum.map(1..15, fn i ->
            collection =
              MishkaBlog.Collection
              |> Ash.Changeset.for_create(
                :create,
                %{name: "PC #{i}", slug: "pc-#{i}", status: :active},
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            MishkaBlog.PostCollection
            |> Ash.Changeset.for_create(
              :assign,
              %{post_id: post.id, collection_id: collection.id},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

            collection.id
          end)

        # Fetch published posts with paginated collections
        response =
          make_api_request(
            "#{@api_tenant_path}/published?include=tenant_collections&included_page[tenant_collections][limit]=10",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Find our post in the list
        post_data = Enum.find(body["data"], fn p -> p["id"] == post.id end)
        assert %{"type" => "blog_post"} = post_data

        # Verify collections are paginated
        if body["included"] do
          collection_records =
            Enum.filter(body["included"], fn inc -> inc["type"] == "collection" end)

          # Should have collections (up to 10 per post)
          assert collection_records != []
          assert length(collection_records) <= 10
        end
      end

      test "tenant admin can list drafts with paginated bloggers", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Create draft post with bloggers
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Draft with Authors",
              slug: "draft-authors",
              content: "Content",
              status: :draft
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 8 bloggers
        _blogger_ids =
          Enum.map(1..8, fn i ->
            user = create_user!(site_id: site.id, email: "draftauthor#{i}@example.com")

            blogger =
              MishkaBlog.Blogger
              |> Ash.Changeset.for_create(
                :create,
                %{user_id: user.id, display_name: "Draft Author #{i}", slug: "draft-author-#{i}"},
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

            blogger.id
          end)

        # Fetch drafts with paginated bloggers
        response =
          make_api_request(
            "#{@api_tenant_path}/drafts?include=tenant_bloggers.user&included_page[tenant_bloggers][limit]=5",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        post_data = Enum.find(body["data"], fn p -> p["id"] == post.id end)
        assert %{"type" => "blog_post"} = post_data

        if body["included"] do
          blogger_records = Enum.filter(body["included"], fn inc -> inc["type"] == "blogger" end)
          assert blogger_records != []
          assert length(blogger_records) <= 5
        end
      end

      test "tenant admin can list featured posts with paginated tags", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Create featured post with tags
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :create,
            %{
              title: "Featured with Tags",
              slug: "featured-tags",
              content: "Content",
              status: :published,
              featured: true
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        # Create 12 tags
        _tag_ids =
          Enum.map(1..12, fn i ->
            tag =
              MishkaBlog.Tag
              |> Ash.Changeset.for_create(
                :create,
                %{name: "FTag #{i}", slug: "ftag-#{i}"},
                tenant: site.id,
                authorize?: false
              )
              |> Ash.create!()

            MishkaBlog.PostTag
            |> Ash.Changeset.for_create(
              :assign,
              %{post_id: post.id, tag_id: tag.id},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.create!()

            tag.id
          end)

        # Fetch featured posts with paginated tags
        response =
          make_api_request(
            "#{@api_tenant_path}/featured?include=tenant_tags&included_page[tenant_tags][limit]=8",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        post_data = Enum.find(body["data"], fn p -> p["id"] == post.id end)
        assert %{"type" => "blog_post"} = post_data

        if body["included"] do
          tag_records = Enum.filter(body["included"], fn inc -> inc["type"] == "tag" end)
          assert tag_records != []
          assert length(tag_records) <= 8
        end
      end

      test "master admin can list language variants with paginated comments", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create post with comments
        post =
          MishkaBlog.BlogPost
          |> Ash.Changeset.for_create(
            :master_create,
            %{
              title: "Lang Variant with Comments",
              slug: "lang-comments",
              content: "Content",
              status: :published,
              language: "en",
              site_id: site.id
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()

        language_group_id = post.language_group_id

        # Create 10 comments
        Enum.each(1..10, fn i ->
          user = create_user!(site_id: site.id, email: "langcomment#{i}@example.com")

          MishkaBlog.Comment
          |> Ash.Changeset.for_create(
            :create,
            %{
              post_id: post.id,
              content: "Lang Comment #{i}",
              author_id: user.id,
              status: :approved
            },
            tenant: site.id,
            authorize?: false
          )
          |> Ash.create!()
        end)

        # Fetch language variants with paginated comments
        response =
          make_api_request(
            "#{@api_master_path}/language-variants?language_group_id=#{language_group_id}&include=master_comments.author&included_page[master_comments][limit]=6",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        post_data = Enum.find(body["data"], fn p -> p["id"] == post.id end)
        assert %{"type" => "blog_post"} = post_data

        if body["included"] do
          comment_records = Enum.filter(body["included"], fn inc -> inc["type"] == "comment" end)
          assert comment_records != []
          assert length(comment_records) <= 6
        end
      end
    end

    describe "VERSION MANAGEMENT - GET /post/:id/with-versions" do
      test "tenant admin can get blog post with paginated versions", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        # Create post and some versions
        post =
          create_blog_post!(
            site_id: site.id,
            title: "Original Post",
            slug: "original-post",
            content: "Original content",
            status: :published,
            language: "en"
          )

        # Update to create versions
        post
        |> Ash.Changeset.for_update(:update, %{content: "Version 1"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        post
        |> Ash.Changeset.for_update(:update, %{content: "Version 2"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 2 updates = 3 versions)
        wait_for_version_count("mishka_blog_post_versions", post.id, 3)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}/with-versions?fields[blog_post]=title,content,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == post.id
        assert body["data"]["attributes"]["title"] == "Original Post"

        # Check sorted_versions in attributes
        sorted_versions = body["data"]["attributes"]["sorted_versions"]
        assert length(sorted_versions) >= 3
      end

      test "tenant admin cannot get post with versions from another site", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          create_blog_post!(
            site_id: site2.id,
            title: "Other Site Post",
            slug: "other-post",
            content: "Content",
            status: :published,
            language: "en"
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}/with-versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can get any post with versions", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        post1 =
          create_blog_post!(
            site_id: site.id,
            title: "Site 1 Post",
            slug: "site1-post",
            content: "Content 1",
            status: :published,
            language: "en"
          )

        post2 =
          create_blog_post!(
            site_id: site2.id,
            title: "Site 2 Post",
            slug: "site2-post",
            content: "Content 2",
            status: :published,
            language: "en"
          )

        # Create version for post1
        post1
        |> Ash.Changeset.for_update(:update, %{content: "Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions (post1: 1 create + 1 update = 2, post2: 1 create = 1)
        wait_for_version_count("mishka_blog_post_versions", post1.id, 2)
        wait_for_version_count("mishka_blog_post_versions", post2.id, 1)

        # Get site1 post with versions
        response1 =
          make_api_request(
            "#{@api_master_path}/#{post1.id}/with-versions?fields[blog_post]=title,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response1.status == 200
        body1 = Jason.decode!(response1.resp_body)
        sorted_versions1 = body1["data"]["attributes"]["sorted_versions"]
        assert length(sorted_versions1) >= 2

        # Get site2 post with versions
        response2 =
          make_api_request(
            "#{@api_master_path}/#{post2.id}/with-versions?fields[blog_post]=title,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)
        sorted_versions2 = body2["data"]["attributes"]["sorted_versions"]
        assert sorted_versions2 != []
      end
    end

    describe "VERSION MANAGEMENT - Calculations (version_count, latest_version, recent_versions)" do
      test "tenant admin can get version calculations for their post", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          create_blog_post!(
            site_id: site.id,
            title: "Version Test Post",
            slug: "version-test",
            content: "Content 1",
            status: :published,
            language: "en"
          )

        # Create multiple versions
        updated1 =
          post
          |> Ash.Changeset.for_update(:update, %{content: "Content 2"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        updated2 =
          updated1
          |> Ash.Changeset.for_update(:update, %{content: "Content 3"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        updated3 =
          updated2
          |> Ash.Changeset.for_update(:update, %{content: "Content 4"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        _updated4 =
          updated3
          |> Ash.Changeset.for_update(:update, %{content: "Content 5"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 4 updates = 5 versions)
        wait_for_version_count("mishka_blog_post_versions", post.id, 5)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}?fields[blog_post]=title,content,version_count,latest_version,recent_versions",
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
        assert latest_version["changes"]["content"] == "Content 5"

        # Check recent_versions calculation (should return up to 10)
        recent_versions = body["data"]["attributes"]["recent_versions"]
        assert length(recent_versions) >= 5

        # Verify they're sorted descending (newest first)
        contents = Enum.map(recent_versions, & &1["changes"]["content"])
        assert Enum.at(contents, 0) == "Content 5"
        assert Enum.at(contents, 4) == "Content 1"
      end

      test "master admin can get version calculations for any post", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        post =
          create_blog_post!(
            site_id: site.id,
            title: "Master Version Test",
            slug: "master-version-test",
            content: "V1",
            status: :published,
            language: "en"
          )

        # Create versions
        updated1 =
          post
          |> Ash.Changeset.for_update(:update, %{content: "V2"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        _updated2 =
          updated1
          |> Ash.Changeset.for_update(:update, %{content: "V3"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions (1 create + 2 updates = 3 versions)
        wait_for_version_count("mishka_blog_post_versions", post.id, 3)

        response =
          make_api_request(
            "#{@api_master_path}/#{post.id}?fields[blog_post]=title,version_count,latest_version,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert body["data"]["attributes"]["version_count"] >= 3

        latest = body["data"]["attributes"]["latest_version"]
        assert latest["changes"]["content"] == "V3"

        recent = body["data"]["attributes"]["recent_versions"]
        assert length(recent) >= 3
      end

      test "recent_versions limits to 10 versions when more exist", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          create_blog_post!(
            site_id: site.id,
            title: "Many Versions Post",
            slug: "many-versions",
            content: "Initial",
            status: :published,
            language: "en"
          )

        # Create 12 versions
        updated = post

        updated =
          Enum.reduce(1..12, updated, fn i, acc ->
            acc
            |> Ash.Changeset.for_update(:update, %{content: "Version #{i}"},
              tenant: site.id,
              authorize?: false
            )
            |> Ash.update!()
          end)

        # Wait for versions (1 create + 12 updates = 13 versions)
        wait_for_version_count("mishka_blog_post_versions", post.id, 13)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{updated.id}?fields[blog_post]=version_count,recent_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # version_count should be 13
        assert body["data"]["attributes"]["version_count"] >= 13

        # recent_versions should be limited to 10
        recent = body["data"]["attributes"]["recent_versions"]
        assert length(recent) == 10

        # Should be newest 10 (sorted descending)
        contents = Enum.map(recent, & &1["changes"]["content"])
        assert Enum.at(contents, 0) == "Version 12"
        assert Enum.at(contents, 9) == "Version 3"
      end
    end

    describe "VERSION MANAGEMENT - GET /post/:post_id/versions" do
      test "tenant admin can list versions for their post", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          create_blog_post!(
            site_id: site.id,
            title: "List Versions Post",
            slug: "list-versions",
            content: "Original",
            status: :published,
            language: "en"
          )

        # Create multiple versions - capture updated results
        updated1 =
          post
          |> Ash.Changeset.for_update(:update, %{title: "V1"}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        updated2 =
          updated1
          |> Ash.Changeset.for_update(:update, %{title: "V2"}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        _updated3 =
          updated2
          |> Ash.Changeset.for_update(:update, %{title: "V3"}, tenant: site.id, authorize?: false)
          |> Ash.update!()

        # Wait for versions to be created (1 create + 3 updates = 4 versions)
        wait_for_version_count("mishka_blog_post_versions", post.id, 4)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}/versions?fields[blog_post]=title,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Returns 1 post with versions loaded
        assert length(body["data"]) == 1

        # Check the versions inside the post
        post_data = List.first(body["data"])
        sorted_versions = post_data["attributes"]["sorted_versions"]
        assert length(sorted_versions) >= 4
      end

      test "tenant admin cannot list versions for post from another site", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          create_blog_post!(
            site_id: site2.id,
            title: "Other Site Post",
            slug: "other-site",
            content: "Content",
            status: :published,
            language: "en"
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}/versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can list versions for any post", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        post =
          create_blog_post!(
            site_id: site.id,
            title: "Master List Post",
            slug: "master-list",
            content: "Content",
            status: :published,
            language: "en"
          )

        # Create versions
        post
        |> Ash.Changeset.for_update(:update, %{title: "Updated Title"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_post_versions", post.id, 2)

        response =
          make_api_request(
            "#{@api_master_path}/#{post.id}/versions?fields[blog_post]=title,sorted_versions",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        assert length(body["data"]) == 1

        post_data = List.first(body["data"])
        sorted_versions = post_data["attributes"]["sorted_versions"]
        assert length(sorted_versions) >= 2
      end
    end

    describe "VERSION MANAGEMENT - PATCH /post/:id/version/:version_id/restore" do
      test "tenant admin can restore their post to a previous version", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          create_blog_post!(
            site_id: site.id,
            title: "Original Title",
            slug: "restore-test",
            content: "Original content",
            status: :published,
            language: "en"
          )

        # Create a version
        updated =
          post
          |> Ash.Changeset.for_update(
            :update,
            %{title: "Updated Title", content: "Updated content"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_post_versions", post.id, 2)

        # Get the version
        version =
          MishkaBlog.BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^post.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{updated.id}/version/#{version.id}/restore",
            %{"type" => "blog_post", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Original Title"
        assert body["data"]["attributes"]["content"] == "Original content"
      end

      test "tenant admin cannot restore another site's post version", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          create_blog_post!(
            site_id: site2.id,
            title: "Other Site",
            slug: "other-site",
            content: "Content",
            status: :published,
            language: "en"
          )

        # Create version
        post
        |> Ash.Changeset.for_update(:update, %{title: "Updated"},
          tenant: site2.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_post_versions", post.id, 2)

        # Get version
        version =
          MishkaBlog.BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^post.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}/version/#{version.id}/restore",
            %{"type" => "blog_post", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 404
      end

      test "master admin can restore any post version", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        post =
          create_blog_post!(
            site_id: site.id,
            title: "Original",
            slug: "master-restore",
            content: "Original",
            status: :published,
            language: "en"
          )

        # Create version
        updated =
          post
          |> Ash.Changeset.for_update(:update, %{title: "Updated"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_post_versions", post.id, 2)

        # Get version
        version =
          MishkaBlog.BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^post.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_master_path}/#{updated.id}/version/#{version.id}/restore",
            %{"type" => "blog_post", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Original"
      end

      test "cannot restore version of archived post", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          create_blog_post!(
            site_id: site.id,
            title: "To Archive",
            slug: "to-archive",
            content: "Content",
            status: :published,
            language: "en"
          )

        # Create version
        post
        |> Ash.Changeset.for_update(:update, %{title: "Updated"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_post_versions", post.id, 2)

        # Archive post
        post
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()

        # Get version
        version =
          MishkaBlog.BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^post.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}/version/#{version.id}/restore",
            %{"type" => "blog_post", "attributes" => %{}},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status in [400, 404, 422]
      end
    end

    describe "VERSION MANAGEMENT - GET /post/:post_id/version/:version_id/preview" do
      test "tenant admin can preview a version without restoring", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          create_blog_post!(
            site_id: site.id,
            title: "Original",
            slug: "preview-test",
            content: "Original content",
            status: :published,
            language: "en"
          )

        # Create version
        updated =
          post
          |> Ash.Changeset.for_update(:update, %{title: "Updated", content: "Updated content"},
            tenant: site.id,
            authorize?: false
          )
          |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_post_versions", post.id, 2)

        # Get version
        version =
          MishkaBlog.BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^post.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Original"
        assert body["data"]["attributes"]["content"] == "Original content"

        # Verify actual post is unchanged
        current_response =
          make_api_request(
            "#{@api_tenant_path}/#{updated.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert current_response.status == 200
        current_body = Jason.decode!(current_response.resp_body)
        assert current_body["data"]["attributes"]["title"] == "Updated"
        assert current_body["data"]["attributes"]["content"] == "Updated content"
      end

      test "tenant admin cannot preview version from another site", %{
        tenant_admin: tenant_admin,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        post =
          create_blog_post!(
            site_id: site2.id,
            title: "Other Site",
            slug: "other-preview",
            content: "Content",
            status: :published,
            language: "en"
          )

        # Create version
        post
        |> Ash.Changeset.for_update(:update, %{title: "Updated"},
          tenant: site2.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_post_versions", post.id, 2)

        # Get version
        version =
          MishkaBlog.BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^post.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_tenant_path}/#{post.id}/version/#{version.id}/preview",
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

        post =
          create_blog_post!(
            site_id: site.id,
            title: "Original",
            slug: "master-preview",
            content: "Original content",
            status: :published,
            language: "en"
          )

        # Create version
        post
        |> Ash.Changeset.for_update(:update, %{title: "Updated", content: "Updated content"},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

        # Wait for versions to be created (1 create + 1 update = 2 versions)
        wait_for_version_count("mishka_blog_post_versions", post.id, 2)

        # Get version
        version =
          MishkaBlog.BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id == ^post.id)
          |> Ash.Query.sort(version_inserted_at: :asc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        response =
          make_api_request(
            "#{@api_master_path}/#{post.id}/version/#{version.id}/preview",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["title"] == "Original"
        assert body["data"]["attributes"]["content"] == "Original content"
      end
    end
  end
end
