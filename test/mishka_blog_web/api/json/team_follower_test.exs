# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Api.Json.TeamFollowerTest do
  @moduledoc """
  Comprehensive tests for TeamFollower JSON API endpoints.
  """
  use MishkaBlog.ConnCase
  import MishkaBlog.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaBlog) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @api_team_follow_path "/api/json/v1/user/mishka-blog/team-follow"
    @api_my_following_path "/api/json/v1/user/mishka-blog/team-follow/my-following"

    setup do
      MishkaCmsCore.Runtime.States.SiteState.clear()
      :ok = Swoosh.TestAssertions.set_swoosh_global()

      Application.put_env(:ash_json_api, MishkaBlog, router: MishkaBlog.TestRouter)

      # Create site for testing
      site = create_site!(name: "localhost", host: "localhost", active: true, priority: 50)

      MishkaCmsCore.Runtime.States.SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active
      })

      # Create users for testing
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

      {:ok, site: site, user1: user1, user2: user2}
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

    describe "POST /team-follow - Create follow" do
      test "user can follow a team", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        team = create_team!(site_id: site.id, status: :active)

        response =
          make_api_request(
            @api_team_follow_path,
            %{
              "type" => "team_follower",
              "attributes" => %{
                "team_id" => team.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"]
        assert body["data"]["type"] == "team_follower"
        assert body["data"]["attributes"]["team_id"] == team.id
      end

      test "follow includes timestamps and notification settings", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        team = create_team!(site_id: site.id, status: :active)

        response =
          make_api_request(
            @api_team_follow_path,
            %{
              "type" => "team_follower",
              "attributes" => %{
                "team_id" => team.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)

        assert {:ok, %DateTime{}, _offset} =
                 DateTime.from_iso8601(body["data"]["attributes"]["followed_at"])

        assert body["data"]["attributes"]["notification_enabled"] == true

        assert {:ok, %DateTime{}, _offset} =
                 DateTime.from_iso8601(body["data"]["attributes"]["inserted_at"])

        assert {:ok, %DateTime{}, _offset} =
                 DateTime.from_iso8601(body["data"]["attributes"]["updated_at"])
      end

      test "user can follow with notifications disabled", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        team = create_team!(site_id: site.id, status: :active)

        response =
          make_api_request(
            @api_team_follow_path,
            %{
              "type" => "team_follower",
              "attributes" => %{
                "team_id" => team.id,
                "notification_enabled" => false
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["notification_enabled"] == false
      end

      test "unauthenticated user cannot follow team", %{site: site} do
        team = create_team!(site_id: site.id, status: :active)

        response =
          make_api_request(
            @api_team_follow_path,
            %{
              "type" => "team_follower",
              "attributes" => %{
                "team_id" => team.id
              }
            },
            method: :post
          )

        # Returns 403 because actor_present() check fails
        assert response.status == 403
      end
    end

    describe "POST /team-follow - Upsert behavior" do
      test "following same team twice returns existing follow", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        team = create_team!(site_id: site.id, status: :active)

        # First follow
        response1 =
          make_api_request(
            @api_team_follow_path,
            %{
              "type" => "team_follower",
              "attributes" => %{
                "team_id" => team.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response1.status == 201
        body1 = Jason.decode!(response1.resp_body)
        assert body1["data"]["id"]

        # Second follow of same team - should upsert
        response2 =
          make_api_request(
            @api_team_follow_path,
            %{
              "type" => "team_follower",
              "attributes" => %{
                "team_id" => team.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        # Upsert may return 200 or 201 depending on implementation
        assert response2.status in [200, 201]
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["id"]
      end
    end

    describe "GET /my-following - List user's following" do
      test "user can list teams they follow", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        # Create teams and follow them
        team1 = create_team!(site_id: site.id, status: :active, name: "Team 1")
        team2 = create_team!(site_id: site.id, status: :active, name: "Team 2")
        team3 = create_team!(site_id: site.id, status: :active, name: "Team 3")

        create_team_follower!(team_id: team1.id, follower_user_id: user1.id)
        create_team_follower!(team_id: team2.id, follower_user_id: user1.id)
        create_team_follower!(team_id: team3.id, follower_user_id: user1.id)

        response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 3
      end

      test "user only sees their own following, not other users' following", %{
        site: site,
        user1: user1,
        user2: user2
      } do
        token = sign_in_user(user1)

        team1 = create_team!(site_id: site.id, status: :active)
        team2 = create_team!(site_id: site.id, status: :active)

        # User1 follows team1
        create_team_follower!(team_id: team1.id, follower_user_id: user1.id)

        # User2 follows team2
        create_team_follower!(team_id: team2.id, follower_user_id: user2.id)

        response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 1
      end

      test "returns empty list when user follows no teams", %{user1: user1} do
        token = sign_in_user(user1)

        response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"] == []
      end

      test "supports pagination", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        # Create 25 teams and follow them
        for i <- 1..25 do
          team = create_team!(site_id: site.id, status: :active, name: "Team #{i}")
          create_team_follower!(team_id: team.id, follower_user_id: user1.id)
        end

        # Request first page with limit 10
        response =
          make_api_request(
            "#{@api_my_following_path}?page[limit]=10",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 10
      end

      test "unauthenticated user cannot list following", %{} do
        response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get
          )

        # Returns 403 because authorization fails without actor
        assert response.status == 403
      end

      test "only shows active teams in my_following", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        # Create active and inactive teams
        active_team = create_team!(site_id: site.id, status: :active, name: "Active Team")
        inactive_team = create_team!(site_id: site.id, status: :inactive, name: "Inactive Team")

        # Follow both teams
        create_team_follower!(team_id: active_team.id, follower_user_id: user1.id)
        create_team_follower!(team_id: inactive_team.id, follower_user_id: user1.id)

        response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)

        # Should only see the active team
        assert length(body["data"]) == 1
        team_ids = Enum.map(body["data"], & &1["attributes"]["team_id"])
        assert active_team.id in team_ids
        refute inactive_team.id in team_ids
      end
    end

    describe "PATCH /team-follow/:id - Toggle notifications" do
      test "user can enable notifications for a follow", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        team = create_team!(site_id: site.id, status: :active)

        # Create follow with notifications disabled
        follow =
          create_team_follower!(
            team_id: team.id,
            follower_user_id: user1.id,
            notification_enabled: false
          )

        response =
          make_api_request(
            "#{@api_team_follow_path}/#{follow.id}",
            %{
              "type" => "team_follower",
              "attributes" => %{
                "notification_enabled" => true
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["notification_enabled"] == true
      end

      test "user can disable notifications for a follow", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        team = create_team!(site_id: site.id, status: :active)

        # Create follow with notifications enabled
        follow =
          create_team_follower!(
            team_id: team.id,
            follower_user_id: user1.id,
            notification_enabled: true
          )

        response =
          make_api_request(
            "#{@api_team_follow_path}/#{follow.id}",
            %{
              "type" => "team_follower",
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
      end

      test "user cannot update another user's follow", %{site: site, user1: user1, user2: user2} do
        token1 = sign_in_user(user1)
        team = create_team!(site_id: site.id, status: :active)

        # User2 follows team
        follow = create_team_follower!(team_id: team.id, follower_user_id: user2.id)

        # User1 tries to update user2's follow
        response =
          make_api_request(
            "#{@api_team_follow_path}/#{follow.id}",
            %{
              "type" => "team_follower",
              "attributes" => %{
                "notification_enabled" => false
              }
            },
            method: :patch,
            headers: [{"authorization", "Bearer #{token1}"}]
          )

        assert response.status in [403, 404]
      end

      test "unauthenticated user cannot toggle notifications", %{site: site, user1: user1} do
        team = create_team!(site_id: site.id, status: :active)
        follow = create_team_follower!(team_id: team.id, follower_user_id: user1.id)

        response =
          make_api_request(
            "#{@api_team_follow_path}/#{follow.id}",
            %{
              "type" => "team_follower",
              "attributes" => %{
                "notification_enabled" => false
              }
            },
            method: :patch
          )

        # Returns 403 because no actor present
        assert response.status == 403
      end
    end

    describe "DELETE /team-follow/:id - Unfollow" do
      test "user can unfollow a team", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        team = create_team!(site_id: site.id, status: :active)

        follow = create_team_follower!(team_id: team.id, follower_user_id: user1.id)

        response =
          make_api_request(
            "#{@api_team_follow_path}/#{follow.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        # DELETE with unfollow action returns 200 OK
        assert response.status == 200

        # Verify follow was removed
        list_response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        list_body = Jason.decode!(list_response.resp_body)
        assert list_body["data"] == []
      end

      test "user cannot unfollow another user's follow", %{
        site: site,
        user1: user1,
        user2: user2
      } do
        token1 = sign_in_user(user1)
        team = create_team!(site_id: site.id, status: :active)

        # User2 follows team
        follow = create_team_follower!(team_id: team.id, follower_user_id: user2.id)

        # User1 tries to unfollow user2's follow
        response =
          make_api_request(
            "#{@api_team_follow_path}/#{follow.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token1}"}]
          )

        assert response.status in [403, 404]
      end

      test "unauthenticated user cannot unfollow", %{site: site, user1: user1} do
        team = create_team!(site_id: site.id, status: :active)
        follow = create_team_follower!(team_id: team.id, follower_user_id: user1.id)

        response =
          make_api_request(
            "#{@api_team_follow_path}/#{follow.id}",
            %{},
            method: :delete
          )

        # Returns 403 because no actor present
        assert response.status == 403
      end
    end

    describe "Multiple users following same team" do
      test "different users can follow the same team", %{site: site, user1: user1, user2: user2} do
        token1 = sign_in_user(user1)
        token2 = sign_in_user(user2)
        team = create_team!(site_id: site.id, status: :active)

        # User1 follows
        response1 =
          make_api_request(
            @api_team_follow_path,
            %{
              "type" => "team_follower",
              "attributes" => %{
                "team_id" => team.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token1}"}]
          )

        assert response1.status == 201

        # User2 follows the same team
        response2 =
          make_api_request(
            @api_team_follow_path,
            %{
              "type" => "team_follower",
              "attributes" => %{
                "team_id" => team.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token2}"}]
          )

        assert response2.status == 201

        # Verify both follows exist and are different
        body1 = Jason.decode!(response1.resp_body)
        body2 = Jason.decode!(response2.resp_body)
        assert body1["data"]["id"] != body2["data"]["id"]
      end
    end

    describe "Team status filtering" do
      test "user can see follow but team becomes inactive", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        # Create an active team and follow it
        team = create_team!(site_id: site.id, status: :active, name: "Active Team")

        response1 =
          make_api_request(
            @api_team_follow_path,
            %{
              "type" => "team_follower",
              "attributes" => %{
                "team_id" => team.id
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response1.status == 201

        # Verify follow appears in user's list
        list_response1 =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert list_response1.status == 200
        body1 = Jason.decode!(list_response1.resp_body)
        assert length(body1["data"]) == 1

        # Change team status to inactive
        Ash.update!(team, %{status: :inactive}, action: :update, authorize?: false)

        # Get following again - should not see the inactive team
        list_response2 =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert list_response2.status == 200
        body2 = Jason.decode!(list_response2.resp_body)

        # Inactive teams should be filtered out from my_following
        assert body2["data"] == []
      end

      test "user can see multiple follows with only active teams visible", %{
        site: site,
        user1: user1
      } do
        token = sign_in_user(user1)

        # Create and follow three active teams
        team1 = create_team!(site_id: site.id, status: :active, name: "Team 1")
        team2 = create_team!(site_id: site.id, status: :active, name: "Team 2")
        team3 = create_team!(site_id: site.id, status: :active, name: "Team 3")

        create_team_follower!(team_id: team1.id, follower_user_id: user1.id)
        create_team_follower!(team_id: team2.id, follower_user_id: user1.id)
        create_team_follower!(team_id: team3.id, follower_user_id: user1.id)

        # Verify all 3 follows appear
        list_response1 =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert list_response1.status == 200
        body1 = Jason.decode!(list_response1.resp_body)
        assert length(body1["data"]) == 3

        # Change team2 to inactive
        Ash.update!(team2, %{status: :inactive}, action: :update, authorize?: false)

        # Get following again - should only see 2 (team1 and team3)
        list_response2 =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert list_response2.status == 200
        body2 = Jason.decode!(list_response2.resp_body)
        assert length(body2["data"]) == 2
      end
    end

    describe "Follow ordering and metadata" do
      test "follows include followed_at timestamp", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        # Create follow
        team = create_team!(site_id: site.id, status: :active)
        create_team_follower!(team_id: team.id, follower_user_id: user1.id)

        response =
          make_api_request(
            @api_my_following_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 1

        follow = hd(body["data"])

        assert {:ok, %DateTime{}, _offset} =
                 DateTime.from_iso8601(follow["attributes"]["followed_at"])
      end
    end
  end
end
