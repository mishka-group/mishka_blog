# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Api.Json.BloggerFollowerTest do
  @moduledoc """
  Comprehensive tests for BloggerFollower JSON API endpoints.
  """

  use MishkaBlog.ConnCase
  import MishkaBlog.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaBlog) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @api_follow_path "/api/json/v1/user/mishka-blog/blogger-follow"

    setup do
      MishkaCmsCore.Runtime.States.SiteState.clear()
      :ok = Swoosh.TestAssertions.set_swoosh_global()

      Application.put_env(:ash_json_api, MishkaBlog, router: MishkaBlog.TestRouter)

      # Create initial site for testing
      site = create_site!(name: "localhost", host: "localhost", active: true, priority: 50)

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active
      })

      # Create users
      user1 =
        create_user!(
          email: "user1@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )

      user2 =
        create_user!(
          email: "user2@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )

      user3 =
        create_user!(
          email: "user3@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )

      # Create bloggers
      blogger1 =
        create_blogger!(
          site_id: site.id,
          user_id: user1.id,
          display_name: "Blogger 1",
          slug: "blogger-1"
        )

      blogger2 =
        create_blogger!(
          site_id: site.id,
          user_id: user2.id,
          display_name: "Blogger 2",
          slug: "blogger-2"
        )

      on_exit(fn ->
        MishkaCmsCore.Runtime.States.SiteState.delete(site.id)
        MishkaCmsCore.Runtime.States.SiteState.clear()
      end)

      %{
        site: site,
        user1: user1,
        user2: user2,
        user3: user3,
        blogger1: blogger1,
        blogger2: blogger2
      }
    end

    # Helper function to sign in and get token
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
          }
        )

      assert sign_in_response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(sign_in_response.resp_body)
      token
    end

    describe "CREATE - POST /blogger-follow (Follow a blogger)" do
      test "authenticated user can follow a blogger", %{user3: user3, blogger1: blogger1} do
        token = sign_in_user(user3)

        response =
          make_api_request(
            @api_follow_path,
            %{
              "type" => "blogger_follower",
              "attributes" => %{
                "blogger_id" => blogger1.id,
                "notification_enabled" => true
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["blogger_id"] == blogger1.id
        assert body["data"]["attributes"]["notification_enabled"] == true
      end

      test "following same blogger twice uses upsert (no duplicate)", %{
        user3: user3,
        blogger1: blogger1
      } do
        token = sign_in_user(user3)

        # First follow
        response1 =
          make_api_request(
            @api_follow_path,
            %{
              "type" => "blogger_follower",
              "attributes" => %{
                "blogger_id" => blogger1.id,
                "notification_enabled" => true
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response1.status == 201
        first_id = Jason.decode!(response1.resp_body)["data"]["id"]

        # Second follow (should upsert, not create duplicate)
        response2 =
          make_api_request(
            @api_follow_path,
            %{
              "type" => "blogger_follower",
              "attributes" => %{
                "blogger_id" => blogger1.id,
                # follower_user_id automatically set from actor
                "notification_enabled" => false
              }
            },
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 201
        body2 = Jason.decode!(response2.resp_body)
        # Should be same ID (upserted, not new record)
        assert body2["data"]["id"] == first_id
        # Notification should be updated
        assert body2["data"]["attributes"]["notification_enabled"] == false
      end

      test "unauthenticated user cannot follow a blogger", %{blogger1: blogger1} do
        response =
          make_api_request(
            @api_follow_path,
            %{
              "type" => "blogger_follower",
              "attributes" => %{
                "blogger_id" => blogger1.id
              }
            },
            headers: []
          )

        assert response.status in [401, 403]
      end
    end

    describe "READ - GET /my-follows (User's followed bloggers)" do
      test "authenticated user can see their own follows", %{
        user3: user3,
        blogger1: blogger1,
        blogger2: blogger2
      } do
        token = sign_in_user(user3)

        # Create follows (no tenant - BloggerFollower doesn't use multitenancy)
        MishkaBlog.BloggerFollower
        |> Ash.Changeset.for_create(
          :create,
          %{
            blogger_id: blogger1.id,
            notification_enabled: true
          },
          authorize?: false,
          actor: user3
        )
        |> Ash.create!()

        MishkaBlog.BloggerFollower
        |> Ash.Changeset.for_create(
          :create,
          %{
            blogger_id: blogger2.id,
            notification_enabled: false
          },
          authorize?: false,
          actor: user3
        )
        |> Ash.create!()

        response =
          make_api_request(
            "#{@api_follow_path}/my-follows?follower_user_id=#{user3.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 2

        blogger_ids = Enum.map(body["data"], fn follow -> follow["attributes"]["blogger_id"] end)

        assert blogger1.id in blogger_ids
        assert blogger2.id in blogger_ids
      end

      test "user cannot see other users' follows", %{
        user3: user3,
        user2: user2,
        blogger1: blogger1
      } do
        token = sign_in_user(user3)

        # Create follow for user2
        MishkaBlog.BloggerFollower
        |> Ash.Changeset.for_create(
          :create,
          %{
            blogger_id: blogger1.id
          },
          authorize?: false,
          actor: user2
        )
        |> Ash.create!()

        # User3 tries to see user2's follows
        response =
          make_api_request(
            "#{@api_follow_path}/my-follows?follower_user_id=#{user2.id}",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        # Should return empty or 403
        if response.status == 200 do
          body = Jason.decode!(response.resp_body)
          # Should be empty because authorization filters to own follows
          assert body["data"] == []
        else
          assert response.status == 403
        end
      end

      test "unauthenticated user cannot access my-follows" do
        response =
          make_api_request(
            "#{@api_follow_path}/my-follows",
            %{},
            method: :get,
            headers: []
          )

        # Without authentication, should return empty list or require auth
        # Current behavior returns 200 with empty list (filtered by authorization)
        assert response.status in [403]

        if response.status == 200 do
          body = Jason.decode!(response.resp_body)
          # Should be empty due to authorization filtering
          assert body["data"] == []
        end
      end
    end

    describe "READ - GET /followers (Blogger's followers - Public)" do
      test "anyone can see followers of a blogger (public access)", %{
        blogger1: blogger1,
        user2: user2,
        user3: user3
      } do
        # Create followers (no tenant - BloggerFollower doesn't use multitenancy)
        MishkaBlog.BloggerFollower
        |> Ash.Changeset.for_create(
          :create,
          %{
            blogger_id: blogger1.id
          },
          authorize?: false,
          actor: user2
        )
        |> Ash.create!()

        MishkaBlog.BloggerFollower
        |> Ash.Changeset.for_create(
          :create,
          %{
            blogger_id: blogger1.id
          },
          authorize?: false,
          actor: user3
        )
        |> Ash.create!()

        # No authentication required
        response =
          make_api_request(
            "#{@api_follow_path}/followers?blogger_id=#{blogger1.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        # Verify we get 2 follow records for blogger1
        assert length(body["data"]) == 2
        # Verify each record is a blogger_follower type
        Enum.each(body["data"], fn follow ->
          assert follow["type"] == "blogger_follower"
        end)
      end

      test "returns empty list for blogger with no followers", %{blogger2: blogger2} do
        response =
          make_api_request(
            "#{@api_follow_path}/followers?blogger_id=#{blogger2.id}",
            %{},
            method: :get,
            headers: []
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"] == []
      end
    end

    describe "UPDATE - PATCH /toggle_notifications" do
      test "user can toggle notifications for their own follow", %{
        user3: user3,
        blogger1: blogger1
      } do
        token = sign_in_user(user3)

        # Create follow
        follow =
          MishkaBlog.BloggerFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              blogger_id: blogger1.id,
              notification_enabled: true
            },
            authorize?: false,
            actor: user3
          )
          |> Ash.create!()

        # Toggle notifications
        response =
          make_api_request(
            "#{@api_follow_path}/#{follow.id}",
            %{
              "type" => "blogger_follower",
              "attributes" => %{
                "notification_enabled" => false
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["notification_enabled"] == false

        # Toggle back
        response2 =
          make_api_request(
            "#{@api_follow_path}/#{follow.id}",
            %{
              "type" => "blogger_follower",
              "attributes" => %{
                "notification_enabled" => true
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status == 200
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["attributes"]["notification_enabled"] == true
      end

      test "user cannot toggle notifications for another user's follow", %{
        user3: user3,
        user2: user2,
        blogger1: blogger1
      } do
        token = sign_in_user(user3)

        # Create follow for user2
        follow =
          MishkaBlog.BloggerFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              blogger_id: blogger1.id,
              notification_enabled: true
            },
            authorize?: false,
            actor: user2
          )
          |> Ash.create!()

        # User3 tries to toggle user2's follow notifications
        response =
          make_api_request(
            "#{@api_follow_path}/#{follow.id}",
            %{
              "type" => "blogger_follower",
              "attributes" => %{
                "notification_enabled" => false
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        # Should fail with 403 Forbidden or 404 Not Found
        assert response.status in [403, 404]
      end
    end

    describe "DELETE - DELETE /unfollow" do
      test "user can unfollow a blogger", %{user3: user3, blogger1: blogger1} do
        token = sign_in_user(user3)

        # Create follow
        follow =
          MishkaBlog.BloggerFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              blogger_id: blogger1.id
            },
            authorize?: false,
            actor: user3
          )
          |> Ash.create!()

        # Unfollow
        response =
          make_api_request(
            "#{@api_follow_path}/#{follow.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200

        # Verify follow is deleted
        list_response =
          make_api_request(
            "#{@api_follow_path}/my-follows",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert list_response.status == 200
        list_body = Jason.decode!(list_response.resp_body)
        assert list_body["data"] == []
      end

      test "user cannot unfollow for another user", %{
        user3: user3,
        user2: user2,
        blogger1: blogger1
      } do
        token = sign_in_user(user3)

        # Create follow for user2
        follow =
          MishkaBlog.BloggerFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              blogger_id: blogger1.id
            },
            authorize?: false,
            actor: user2
          )
          |> Ash.create!()

        # User3 tries to delete user2's follow
        response =
          make_api_request(
            "#{@api_follow_path}/#{follow.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        # Should fail with 403 or 404
        assert response.status in [403, 404]

        # Verify follow still exists
        check_follow =
          MishkaBlog.BloggerFollower
          |> Ash.get!(follow.id, authorize?: false)

        assert check_follow.id == follow.id
      end

      test "unauthenticated user cannot unfollow", %{
        user3: user3,
        blogger1: blogger1,
        site: _site
      } do
        # Create follow
        follow =
          MishkaBlog.BloggerFollower
          |> Ash.Changeset.for_create(
            :create,
            %{
              blogger_id: blogger1.id
            },
            authorize?: false,
            actor: user3
          )
          |> Ash.create!()

        # Try to unfollow without authentication
        response =
          make_api_request(
            "#{@api_follow_path}/#{follow.id}",
            %{},
            method: :delete,
            headers: []
          )

        # Should fail with 401 Unauthorized or 403 Forbidden
        assert response.status in [401, 403]
      end
    end
  end
end
