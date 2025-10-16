defmodule MishkaBlogWeb.Api.Json.BlogPostTest do
  @moduledoc """
  Comprehensive tests for BlogPost JSON API endpoints.
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
        assert is_list(body["data"])
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
        assert is_list(body["data"])

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
        assert is_list(body["data"])

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
        assert is_list(body["data"])

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
        assert is_list(body["data"])

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
        assert is_list(body["data"])

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
        assert is_list(body["data"])

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
        assert is_list(body["data"])

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
        assert is_list(body["data"])

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
        assert body["data"]["attributes"]["scheduled_publish_at"] != nil
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
        assert is_list(body["data"])

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
        assert is_list(body["data"])

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
        assert is_list(sorted_versions)
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
        assert is_list(sorted_versions1)
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
        assert is_list(sorted_versions2)
        assert length(sorted_versions2) >= 1
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
        assert is_map(latest_version)
        assert latest_version["changes"]["content"] == "Content 5"

        # Check recent_versions calculation (should return up to 10)
        recent_versions = body["data"]["attributes"]["recent_versions"]
        assert is_list(recent_versions)
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
        assert is_list(body["data"])
        assert length(body["data"]) == 1

        # Check the versions inside the post
        post_data = List.first(body["data"])
        sorted_versions = post_data["attributes"]["sorted_versions"]
        assert is_list(sorted_versions)
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

        assert is_list(body["data"])
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
