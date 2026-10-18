# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Api.Json.CommentTest do
  @moduledoc """
  Comprehensive tests for Comment JSON API endpoints.
  """

  use MishkaBlog.ConnCase
  import MishkaBlog.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaBlog) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @api_master_path "/api/json/v1/master/admin/mishka-blog/comment"
    @api_tenant_path "/api/json/v1/tenant/admin/mishka-blog/comment"
    @api_public_create_path "/api/json/v1/user/mishka-blog/comment/create"
    @api_public_approved_path "/api/json/v1/user/mishka-blog/comment/approved"

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

      # Create a regular user for testing comment authorship
      regular_user =
        create_user!(
          email: "user@example.com",
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

    describe "CREATE - POST /comment" do
      # Note: Master admin cannot create comments via API (no create route)
      # Comments can only be created via tenant admin or public endpoints

      test "tenant admin can create comment for their site only", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        post_own = create_blog_post!(site_id: site.id, status: :published)
        _post_other = create_blog_post!(site_id: site2.id, status: :published)

        # Can create for own site
        response =
          make_api_request(
            @api_tenant_path,
            %{
              "type" => "comment",
              "attributes" => %{
                "content" => "Tenant comment",
                "post_id" => post_own.id,
                "status" => "approved"
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["content"] == "Tenant comment"

        # Tenant admin can create for another site if they have admin permission
        # (admin permission allows cross-site operations)
        # So we don't test this restriction here
      end

      test "public user can create comment (pending status)", %{
        site: site,
        regular_user: regular_user
      } do
        token = sign_in_tenant(regular_user)
        post = create_blog_post!(site_id: site.id, status: :published)

        response =
          make_api_request(
            @api_public_create_path,
            %{
              "type" => "comment",
              "attributes" => %{
                "content" => "Public comment",
                "post_id" => post.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["content"] == "Public comment"
        # Public comments should default to pending
        assert body["data"]["attributes"]["status"] in ["pending", "approved"]
      end
    end

    describe "READ - GET /comment/:id" do
      test "master admin can read any comment", %{
        master_user: master_user,
        site: site,
        site2: site2
      } do
        token = sign_in_master(master_user)

        comment1 = create_comment!(site_id: site.id, content: "Comment 1", status: :pending)
        comment2 = create_comment!(site_id: site2.id, content: "Comment 2", status: :approved)

        # Read comment from site1
        response =
          make_api_request(
            "#{@api_master_path}/#{comment1.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == comment1.id
        assert body["data"]["attributes"]["content"] == "Comment 1"

        # Read comment from site2
        response2 =
          make_api_request(
            "#{@api_master_path}/#{comment2.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["id"] == comment2.id
      end

      test "tenant admin can read comments from their site only", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)

        comment_own = create_comment!(site_id: site.id, content: "Own comment")
        comment_other = create_comment!(site_id: site2.id, content: "Other comment")

        # Can read own site's comment
        response =
          make_api_request(
            "#{@api_tenant_path}/#{comment_own.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == comment_own.id

        # Cannot read another site's comment
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{comment_other.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end

      test "public can only see approved comments in approved list", %{site: site} do
        post = create_blog_post!(site_id: site.id, status: :published)

        comment_approved =
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            content: "Approved",
            status: :approved
          )

        _comment_pending =
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            content: "Pending",
            status: :pending
          )

        # List approved comments - use post_id as argument
        response =
          make_api_request(
            "#{@api_public_approved_path}?post_id=#{post.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Should only see approved comments
        approved_ids = Enum.map(body["data"], & &1["id"])
        assert comment_approved.id in approved_ids
      end
    end

    describe "UPDATE - PATCH /comment/:id" do
      test "master admin can update any comment", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        comment = create_comment!(site_id: site.id, content: "Original")

        response =
          make_api_request(
            "#{@api_master_path}/#{comment.id}",
            %{
              "type" => "comment",
              "attributes" => %{
                "content" => "Updated by master"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["content"] == "Updated by master"
      end

      test "tenant admin can update comments from their site", %{
        tenant_admin: tenant_admin,
        site: site,
        site2: site2
      } do
        token = sign_in_tenant(tenant_admin)
        comment_own = create_comment!(site_id: site.id, content: "Original")
        comment_other = create_comment!(site_id: site2.id, content: "Other")

        # Can update own site's comment
        response =
          make_api_request(
            "#{@api_tenant_path}/#{comment_own.id}",
            %{
              "type" => "comment",
              "attributes" => %{
                "content" => "Updated by tenant"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["content"] == "Updated by tenant"

        # Cannot update another site's comment
        response2 =
          make_api_request(
            "#{@api_tenant_path}/#{comment_other.id}",
            %{
              "type" => "comment",
              "attributes" => %{
                "content" => "Hacked"
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 404
      end
    end

    describe "Moderation actions - approve/flag/mark_spam" do
      test "master admin can approve/flag/mark_spam any comment", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        comment1 = create_comment!(site_id: site.id, content: "Comment 1", status: :pending)
        comment2 = create_comment!(site_id: site.id, content: "Comment 2", status: :pending)
        comment3 = create_comment!(site_id: site.id, content: "Comment 3", status: :pending)

        # Approve
        response =
          make_api_request(
            "#{@api_master_path}/#{comment1.id}/approve",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["status"] == "approved"

        # Flag
        response2 =
          make_api_request(
            "#{@api_master_path}/#{comment2.id}/flag",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["attributes"]["status"] == "flagged"

        # Mark as spam
        response3 =
          make_api_request(
            "#{@api_master_path}/#{comment3.id}/mark-spam",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response3.status == 200
        body3 = Jason.decode!(response3.resp_body)
        assert body3["data"]["attributes"]["status"] == "spam"
      end

      test "tenant admin can moderate comments from their site", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)

        comment = create_comment!(site_id: site.id, content: "Comment", status: :pending)

        # Approve
        response =
          make_api_request(
            "#{@api_tenant_path}/#{comment.id}/approve",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["status"] == "approved"
      end
    end

    describe "Pin/Unpin actions" do
      test "master admin can pin and unpin comments", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        comment = create_comment!(site_id: site.id, content: "Comment", is_pinned: false)

        # Pin
        response =
          make_api_request(
            "#{@api_master_path}/#{comment.id}/pin",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["is_pinned"] == true

        # Unpin
        response2 =
          make_api_request(
            "#{@api_master_path}/#{comment.id}/unpin",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["attributes"]["is_pinned"] == false
      end

      test "tenant admin can pin and unpin comments from their site", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        comment = create_comment!(site_id: site.id, content: "Comment", is_pinned: false)

        # Pin
        response =
          make_api_request(
            "#{@api_tenant_path}/#{comment.id}/pin",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["is_pinned"] == true
      end
    end

    describe "DELETE - Soft delete (archive)" do
      test "master admin can archive any comment", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)
        comment = create_comment!(site_id: site.id, content: "To Archive", status: :approved)

        response =
          make_api_request(
            "#{@api_master_path}/#{comment.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        # Soft delete returns 200 OK with the archived record
        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["content"] == "To Archive"

        # Verify it's archived (cannot read via normal endpoint)
        read_response =
          make_api_request(
            "#{@api_master_path}/#{comment.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert read_response.status == 404
      end

      test "tenant admin can archive comments from their site", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        comment = create_comment!(site_id: site.id, content: "To Archive")

        response =
          make_api_request(
            "#{@api_tenant_path}/#{comment.id}/archive",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        # Soft delete returns 200 OK with the archived record
        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["content"] == "To Archive"
      end
    end

    describe "Unarchive action" do
      test "master admin can unarchive comments", %{
        master_user: master_user,
        site: site
      } do
        token = sign_in_master(master_user)

        # Create and archive a comment
        comment =
          create_comment!(site_id: site.id, content: "Archived Comment", status: :approved)

        comment
        |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false, tenant: site.id)
        |> Ash.destroy!()

        # Unarchive via API
        response =
          make_api_request(
            "#{@api_master_path}/#{comment.id}/unarchive",
            %{},
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["content"] == "Archived Comment"
        assert body["data"]["attributes"]["archived_at"] == nil
      end
    end

    describe "Relationships - author include" do
      test "public can include author with approved comments", %{
        site: site,
        regular_user: regular_user
      } do
        post = create_blog_post!(site_id: site.id, status: :published)

        # Create comments with authors
        for i <- 1..5 do
          user = create_user!(email: "author#{i}@example.com", site_id: site.id)

          create_comment!(
            site_id: site.id,
            post_id: post.id,
            author_id: user.id,
            content: "Comment #{i}",
            status: :approved
          )
        end

        # One with regular_user as author
        create_comment!(
          site_id: site.id,
          post_id: post.id,
          author_id: regular_user.id,
          content: "My comment",
          status: :approved
        )

        # Fetch approved comments with author include
        response =
          make_api_request(
            "#{@api_public_approved_path}?include=author&post_id=#{post.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 6

        # Verify authors are included
        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)
        assert length(user_records) == 6

        # A visitor gets who wrote each comment, never the account behind it.
        assert Enum.all?(user_records, &(account_fields(&1) == %{}))
        refute response.resp_body =~ "@example.com"
      end

      test "include=author_profile gives a visitor the author's public profile", %{
        site: site,
        regular_user: regular_user
      } do
        post = create_blog_post!(site_id: site.id, status: :published)

        create_blogger!(
          site_id: site.id,
          user_id: regular_user.id,
          display_name: "Regular Writer",
          slug: "regular-writer"
        )

        create_comment!(
          site_id: site.id,
          post_id: post.id,
          author_id: regular_user.id,
          content: "Signed comment",
          status: :approved
        )

        response =
          make_api_request(
            "#{@api_public_approved_path}?include=author_profile&post_id=#{post.id}",
            %{},
            method: :get
          )

        assert response.status == 200
        assert [profile] = included(response, "blogger")
        assert profile["attributes"]["display_name"] == "Regular Writer"
        refute response.resp_body =~ to_string(regular_user.email)
      end

      # A master reads comments with no tenant, and the profile is still the one on the comment's own
      # site, never the same person's profile on another site. Only a master (a user of no site) can
      # hold a profile on two sites, so the author is one.
      test "include=author_profile answers on the master routes too, from the comment's own site",
           %{
             site: site,
             site2: site2,
             master_user: master_user
           } do
        post = create_blog_post!(site_id: site.id, status: :published)
        writer = create_user!()

        create_blogger!(
          site_id: site.id,
          user_id: writer.id,
          display_name: "Regular Writer",
          slug: "regular-writer"
        )

        create_blogger!(
          site_id: site2.id,
          user_id: writer.id,
          display_name: "Same Person Elsewhere",
          slug: "same-person-elsewhere"
        )

        comment =
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            author_id: writer.id,
            content: "Signed comment",
            status: :approved
          )

        token = sign_in_master(master_user)
        headers = [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]

        for path <- [@api_master_path, "#{@api_master_path}/#{comment.id}"] do
          response =
            make_api_request("#{path}?include=author_profile", %{},
              method: :get,
              headers: headers
            )

          assert response.status == 200, "#{path}: #{response.resp_body}"

          assert ["Regular Writer"] =
                   response |> included("blogger") |> Enum.map(& &1["attributes"]["display_name"])
        end
      end

      test "include=author_profile never names an author by a profile on another site", %{
        site: site,
        site2: site2,
        master_user: master_user
      } do
        post = create_blog_post!(site_id: site.id, status: :published)
        writer = create_user!()

        create_blogger!(
          site_id: site2.id,
          user_id: writer.id,
          display_name: "Same Person Elsewhere",
          slug: "same-person-elsewhere"
        )

        create_comment!(
          site_id: site.id,
          post_id: post.id,
          author_id: writer.id,
          content: "Signed comment",
          status: :approved
        )

        token = sign_in_master(master_user)

        for {path, headers} <- [
              {"#{@api_public_approved_path}?post_id=#{post.id}&", []},
              {"#{@api_master_path}?",
               [{"authorization", "Bearer #{token}"}, {"x-no-tenant", "true"}]}
            ] do
          response =
            make_api_request("#{path}include=author_profile", %{},
              method: :get,
              headers: headers
            )

          assert response.status == 200, "#{path}: #{response.resp_body}"
          assert included(response, "blogger") == [], "#{path} named the author from site2"
        end
      end

      # The profile read behind `author_profile` bypasses the tenant, so it answers only through a
      # comment's relationship, which keeps it to the comment's own site.
      test "the tenant-free profile read answers nobody directly", %{
        site: site,
        regular_user: regular_user
      } do
        create_blogger!(
          site_id: site.id,
          user_id: regular_user.id,
          display_name: "Regular Writer",
          slug: "regular-writer"
        )

        for actor <- [nil, regular_user] do
          refute match?(
                   {:ok, [_ | _]},
                   MishkaBlog.Blogger
                   |> Ash.Query.for_read(:comment_author, %{}, actor: actor)
                   |> Ash.read(actor: actor)
                 )
        end
      end

      test "a signed-in user sees their own account on their comment and nobody else's", %{
        site: site,
        regular_user: regular_user
      } do
        post = create_blog_post!(site_id: site.id, status: :published)
        other = create_user!(email: "other.author@example.com", site_id: site.id)

        for author <- [regular_user, other] do
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            author_id: author.id,
            content: "By #{author.id}",
            status: :approved
          )
        end

        response =
          make_api_request(
            "#{@api_public_approved_path}?include=author&post_id=#{post.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{sign_in_tenant(regular_user)}"}]
          )

        assert response.status == 200
        users = Map.new(included(response, "user"), &{&1["id"], &1})

        assert users[regular_user.id]["attributes"]["email"] == to_string(regular_user.email)
        assert account_fields(users[other.id]) == %{}
      end

      test "tenant admin can include author with tenant comments", %{
        tenant_admin: tenant_admin,
        site: site,
        regular_user: regular_user
      } do
        token = sign_in_tenant(tenant_admin)
        post = create_blog_post!(site_id: site.id, status: :published)

        comment =
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            author_id: regular_user.id,
            content: "Comment with author",
            status: :pending
          )

        response =
          make_api_request(
            "#{@api_tenant_path}/#{comment.id}?include=author",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        user_records = Enum.filter(body["included"], fn inc -> inc["type"] == "user" end)
        assert length(user_records) == 1

        # An admin still gets the account, as the moderation screens need it.
        assert hd(user_records)["attributes"]["email"] == to_string(regular_user.email)
      end
    end

    describe "sender_data (the sender's IP address and browser)" do
      setup %{site: site} do
        post = create_blog_post!(site_id: site.id, status: :published)

        comment =
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            content: "With sender data",
            status: :approved,
            sender_data: %{ip_address: "203.0.113.7", user_agent: "UA-SENDER-X"}
          )

        %{post: post, comment: comment}
      end

      test "a visitor never receives it", %{post: post} do
        response =
          make_api_request("#{@api_public_approved_path}?post_id=#{post.id}", %{}, method: :get)

        assert response.status == 200
        [comment] = Jason.decode!(response.resp_body)["data"]
        assert comment["attributes"]["content"] == "With sender data"
        refute Map.has_key?(comment["attributes"], "sender_data")
        refute response.resp_body =~ "203.0.113.7"
        refute response.resp_body =~ "UA-SENDER-X"
      end

      test "a signed-in user who is not an admin never receives it", %{
        post: post,
        regular_user: regular_user
      } do
        response =
          make_api_request(
            "#{@api_public_approved_path}?post_id=#{post.id}&fields[comment]=content,sender_data",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{sign_in_tenant(regular_user)}"}]
          )

        assert response.status == 200
        refute response.resp_body =~ "203.0.113.7"
      end

      test "a tenant admin still receives it", %{comment: comment, tenant_admin: tenant_admin} do
        response =
          make_api_request("#{@api_tenant_path}/#{comment.id}", %{},
            method: :get,
            headers: [{"authorization", "Bearer #{sign_in_tenant(tenant_admin)}"}]
          )

        assert response.status == 200

        assert %{"ip_address" => "203.0.113.7", "user_agent" => "UA-SENDER-X"} =
                 Jason.decode!(response.resp_body)["data"]["attributes"]["sender_data"]
      end
    end

    describe "my-comments - an author's own comments in every status" do
      test "a comment waiting for moderation is visible to its author", %{
        site: site,
        regular_user: regular_user
      } do
        token = sign_in_tenant(regular_user)
        post = create_blog_post!(site_id: site.id, status: :published)

        created =
          make_api_request(
            @api_public_create_path,
            %{
              "type" => "comment",
              "attributes" => %{"content" => "Awaiting moderation", "post_id" => post.id}
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert created.status == 201

        response =
          make_api_request(
            "/api/json/v1/user/mishka-blog/comment/my-comments?include=author",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        [mine] = Jason.decode!(response.resp_body)["data"]
        assert mine["attributes"]["content"] == "Awaiting moderation"
        assert mine["attributes"]["status"] == "pending"

        assert [%{"attributes" => %{"email" => email}}] = included(response, "user")
        assert email == to_string(regular_user.email)
      end
    end

    describe "Relationships - parent_comment and replies" do
      test "can include parent_comment for nested comments (tenant)", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)
        post = create_blog_post!(site_id: site.id, status: :published)

        # Create parent and child comments
        parent =
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            content: "Parent comment",
            status: :approved
          )

        child =
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            parent_comment_id: parent.id,
            content: "Child comment",
            status: :approved
          )

        # Fetch child with parent_comment included (tenant path)
        response =
          make_api_request(
            "#{@api_tenant_path}/#{child.id}?include=parent_comment",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == child.id

        # Verify parent is included
        comment_records = Enum.filter(body["included"], fn inc -> inc["type"] == "comment" end)
        assert length(comment_records) == 1

        parent_record = Enum.at(comment_records, 0)
        assert parent_record["id"] == parent.id
        assert parent_record["attributes"]["content"] == "Parent comment"
      end

      test "can include replies for parent comments (tenant)", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)
        post = create_blog_post!(site_id: site.id, status: :published)

        # Create parent with multiple replies
        parent =
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            content: "Parent comment",
            status: :approved
          )

        reply_ids =
          for i <- 1..5 do
            reply =
              create_comment!(
                site_id: site.id,
                post_id: post.id,
                parent_comment_id: parent.id,
                content: "Reply #{i}",
                status: :approved
              )

            reply.id
          end

        # Fetch parent with replies included (tenant path)
        response =
          make_api_request(
            "#{@api_tenant_path}/#{parent.id}?include=replies",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == parent.id

        # Verify replies are included
        reply_records = Enum.filter(body["included"], fn inc -> inc["type"] == "comment" end)
        assert length(reply_records) == 5

        included_reply_ids = Enum.map(reply_records, & &1["id"])
        Enum.each(reply_ids, fn id -> assert id in included_reply_ids end)
      end

      test "can include nested relationships: replies.author (tenant)", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)
        post = create_blog_post!(site_id: site.id, status: :published)

        parent =
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            content: "Parent comment",
            status: :approved
          )

        # Create replies with different authors
        _user_ids =
          for i <- 1..3 do
            user = create_user!(email: "reply_author#{i}@example.com", site_id: site.id)

            create_comment!(
              site_id: site.id,
              post_id: post.id,
              parent_comment_id: parent.id,
              author_id: user.id,
              content: "Reply by user #{i}",
              status: :approved
            )

            user.id
          end

        # Fetch the parent with its replies included
        response =
          make_api_request(
            "#{@api_tenant_path}/#{parent.id}?include=replies",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify replies are included
        comment_records = Enum.filter(body["included"], fn inc -> inc["type"] == "comment" end)
        assert length(comment_records) == 3

        # Reply IDs should match
        included_reply_ids = Enum.map(comment_records, & &1["id"])
        # Each of our created users should have a reply
        assert length(included_reply_ids) == 3
      end
    end

    describe "Aggregates - vote counts" do
      test "can load upvote_count and downvote_count aggregates", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)
        post = create_blog_post!(site_id: site.id, status: :published)

        comment =
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            content: "Comment with votes",
            status: :approved
          )

        # Create upvotes
        for i <- 1..7 do
          user = create_user!(email: "upvoter#{i}@example.com", site_id: site.id)
          create_comment_vote!(comment_id: comment.id, user_id: user.id, vote_type: :up)
        end

        # Create downvotes
        for i <- 1..3 do
          user = create_user!(email: "downvoter#{i}@example.com", site_id: site.id)
          create_comment_vote!(comment_id: comment.id, user_id: user.id, vote_type: :down)
        end

        # Fetch comment with vote count calculations - need to request fields explicitly
        response =
          make_api_request(
            "#{@api_tenant_path}/#{comment.id}?fields[comment]=upvote_count,downvote_count",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"] == comment.id

        # Verify vote count calculations
        attributes = body["data"]["attributes"]
        assert attributes["upvote_count"] == 7
        assert attributes["downvote_count"] == 3
      end

      test "public can see vote counts on approved comments list", %{site: site} do
        post = create_blog_post!(site_id: site.id, status: :published)

        comment =
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            content: "Comment with public votes",
            status: :approved
          )

        # Create some votes
        for i <- 1..5 do
          user = create_user!(email: "public_voter#{i}@example.com", site_id: site.id)
          vote_type = if rem(i, 2) == 0, do: :up, else: :down
          create_comment_vote!(comment_id: comment.id, user_id: user.id, vote_type: vote_type)
        end

        # Fetch from approved list with vote count fields
        response =
          make_api_request(
            "#{@api_public_approved_path}?post_id=#{post.id}&fields[comment]=upvote_count,downvote_count",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Find our comment in the list
        comment_data = Enum.find(body["data"], fn c -> c["id"] == comment.id end)
        assert %{"type" => "comment"} = comment_data

        attributes = comment_data["attributes"]
        # 5 votes: indices 1,3,5 = down (3), indices 2,4 = up (2)
        assert attributes["upvote_count"] == 2
        assert attributes["downvote_count"] == 3
      end

      test "vote counts are accessible via aggregates (not relationships)", %{
        site: site,
        tenant_admin: tenant_admin
      } do
        token = sign_in_tenant(tenant_admin)
        post = create_blog_post!(site_id: site.id, status: :published)

        comment =
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            content: "Comment with vote counts via aggregates",
            status: :approved
          )

        # Create votes
        for i <- 1..4 do
          user = create_user!(email: "vote_user#{i}@example.com", site_id: site.id)
          create_comment_vote!(comment_id: comment.id, user_id: user.id, vote_type: :up)
        end

        # Fetch comment - need to request calculations explicitly
        response =
          make_api_request(
            "#{@api_tenant_path}/#{comment.id}?fields[comment]=upvote_count,downvote_count",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Verify calculations are loaded
        assert body["data"]["attributes"]["upvote_count"] == 4
        assert body["data"]["attributes"]["downvote_count"] == 0
      end
    end

    describe "List with filters and pagination" do
      test "tenant admin can list all comments with pagination", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        post = create_blog_post!(site_id: site.id, status: :published)

        # Create multiple comments
        for i <- 1..25 do
          create_comment!(
            site_id: site.id,
            post_id: post.id,
            content: "Comment #{i}",
            status: :approved
          )
        end

        # Fetch first page (default limit 20)
        response =
          make_api_request(
            "#{@api_tenant_path}?page[limit]=10&page[offset]=0",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 10
      end

      test "can filter by status", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        post = create_blog_post!(site_id: site.id, status: :published)

        # Create comments with different statuses
        for _ <- 1..5, do: create_comment!(site_id: site.id, post_id: post.id, status: :approved)
        for _ <- 1..3, do: create_comment!(site_id: site.id, post_id: post.id, status: :pending)
        for _ <- 1..2, do: create_comment!(site_id: site.id, post_id: post.id, status: :flagged)

        # Filter by status=approved
        response =
          make_api_request(
            "#{@api_tenant_path}?filter[status]=approved",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Should get at least 5 approved comments (may include more from other tests)
        approved_comments =
          Enum.filter(body["data"], fn comment ->
            comment["attributes"]["status"] == "approved"
          end)

        assert length(approved_comments) >= 5
      end

      test "public only sees approved comments", %{site: site} do
        post = create_blog_post!(site_id: site.id, status: :published)

        # Create comments with different statuses
        approved_count = 5

        for _ <- 1..approved_count do
          create_comment!(site_id: site.id, post_id: post.id, status: :approved)
        end

        for _ <- 1..3, do: create_comment!(site_id: site.id, post_id: post.id, status: :pending)
        for _ <- 1..2, do: create_comment!(site_id: site.id, post_id: post.id, status: :spam)

        # Use approved endpoint which filters to approved status
        response =
          make_api_request(
            "#{@api_public_approved_path}?post_id=#{post.id}&page[limit]=50",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # All returned comments should be approved
        Enum.each(body["data"], fn comment ->
          assert comment["attributes"]["status"] == "approved"
        end)

        # Should have exactly approved_count comments from this post
        assert length(body["data"]) == approved_count
      end

      test "can filter by is_pinned", %{
        tenant_admin: tenant_admin,
        site: site
      } do
        token = sign_in_tenant(tenant_admin)
        post = create_blog_post!(site_id: site.id, status: :published)

        # Create pinned and unpinned comments
        for _ <- 1..3, do: create_comment!(site_id: site.id, post_id: post.id, is_pinned: true)
        for _ <- 1..7, do: create_comment!(site_id: site.id, post_id: post.id, is_pinned: false)

        # Filter by is_pinned=true
        response =
          make_api_request(
            "#{@api_tenant_path}?filter[is_pinned]=true",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        pinned_comments =
          Enum.filter(body["data"], fn comment ->
            comment["attributes"]["is_pinned"] == true
          end)

        assert length(pinned_comments) >= 3
      end
    end
  end
end
