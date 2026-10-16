# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Api.Json.PostRatingTest do
  @moduledoc """
  Comprehensive tests for PostRating JSON API endpoints.
  """
  use MishkaBlog.ConnCase
  import MishkaBlog.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaBlog) do
    @password "Password123!"
    @api_user_path "/api/json/v1/auth/user"
    @api_rating_path "/api/json/v1/user/mishka-blog/post-rating"
    @api_my_ratings_path "/api/json/v1/user/mishka-blog/post-rating/my-ratings"

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

    describe "POST /post-rating - Create rating" do
      test "user can rate a blog post with 5 stars", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        post = create_blog_post!(site_id: site.id, status: :published)

        response =
          make_api_request(
            @api_rating_path,
            %{
              "type" => "post_rating",
              "attributes" => %{
                "post_id" => post.id,
                "rating" => 5
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["id"]
        assert body["data"]["type"] == "post_rating"
        assert body["data"]["attributes"]["rating"] == 5
      end

      test "user can rate a blog post with 1 star", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        post = create_blog_post!(site_id: site.id, status: :published)

        response =
          make_api_request(
            @api_rating_path,
            %{
              "type" => "post_rating",
              "attributes" => %{
                "post_id" => post.id,
                "rating" => 1
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["rating"] == 1
      end

      test "rating includes timestamps", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        post = create_blog_post!(site_id: site.id, status: :published)

        response =
          make_api_request(
            @api_rating_path,
            %{
              "type" => "post_rating",
              "attributes" => %{
                "post_id" => post.id,
                "rating" => 4
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 201
        body = Jason.decode!(response.resp_body)
        assert body["data"]["attributes"]["inserted_at"] != nil
        assert body["data"]["attributes"]["updated_at"] != nil
      end

      test "rating must be between 1 and 5", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        post = create_blog_post!(site_id: site.id, status: :published)

        # Try rating 0 - should fail
        response0 =
          make_api_request(
            @api_rating_path,
            %{
              "type" => "post_rating",
              "attributes" => %{
                "post_id" => post.id,
                "rating" => 0
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response0.status == 400

        # Try rating 6 - should fail
        response6 =
          make_api_request(
            @api_rating_path,
            %{
              "type" => "post_rating",
              "attributes" => %{
                "post_id" => post.id,
                "rating" => 6
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response6.status == 400
      end

      test "unauthenticated user cannot create rating", %{site: site} do
        post = create_blog_post!(site_id: site.id, status: :published)

        response =
          make_api_request(
            @api_rating_path,
            %{
              "type" => "post_rating",
              "attributes" => %{
                "post_id" => post.id,
                "rating" => 5
              }
            },
            method: :post
          )

        # Returns 403 because actor_present() check fails
        assert response.status == 403
      end
    end

    describe "POST /post-rating - Upsert behavior" do
      test "user can update their rating on same post", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        post = create_blog_post!(site_id: site.id, status: :published)

        # First rating: 3 stars
        response1 =
          make_api_request(
            @api_rating_path,
            %{
              "type" => "post_rating",
              "attributes" => %{
                "post_id" => post.id,
                "rating" => 3
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response1.status == 201
        body1 = Jason.decode!(response1.resp_body)
        assert body1["data"]["attributes"]["rating"] == 3
        assert body1["data"]["id"]

        # Change to 5 stars - should upsert
        response2 =
          make_api_request(
            @api_rating_path,
            %{
              "type" => "post_rating",
              "attributes" => %{
                "post_id" => post.id,
                "rating" => 5
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response2.status in [200, 201]
        body2 = Jason.decode!(response2.resp_body)
        assert body2["data"]["attributes"]["rating"] == 5

        # Verify still only one rating exists
        list_response =
          make_api_request(
            @api_my_ratings_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        list_body = Jason.decode!(list_response.resp_body)
        assert length(list_body["data"]) == 1
      end
    end

    describe "GET /my-ratings - List user's ratings" do
      test "user can list their ratings", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        # Create some posts and rate them
        post1 = create_blog_post!(site_id: site.id, status: :published, title: "Post 1")
        post2 = create_blog_post!(site_id: site.id, status: :published, title: "Post 2")
        post3 = create_blog_post!(site_id: site.id, status: :published, title: "Post 3")

        create_post_rating!(post_id: post1.id, user_id: user1.id, rating: 5)
        create_post_rating!(post_id: post2.id, user_id: user1.id, rating: 4)
        create_post_rating!(post_id: post3.id, user_id: user1.id, rating: 3)

        response =
          make_api_request(
            @api_my_ratings_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 3

        ratings = Enum.map(body["data"], & &1["attributes"]["rating"])
        assert 5 in ratings
        assert 4 in ratings
        assert 3 in ratings
      end

      test "user only sees their own ratings, not other users' ratings", %{
        site: site,
        user1: user1,
        user2: user2
      } do
        token = sign_in_user(user1)

        post1 = create_blog_post!(site_id: site.id, status: :published)
        post2 = create_blog_post!(site_id: site.id, status: :published)

        # User1 rates post1
        create_post_rating!(post_id: post1.id, user_id: user1.id, rating: 5)

        # User2 rates post2
        create_post_rating!(post_id: post2.id, user_id: user2.id, rating: 3)

        response =
          make_api_request(
            @api_my_ratings_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 1
        assert hd(body["data"])["attributes"]["rating"] == 5
      end

      test "returns empty list when user has no ratings", %{user1: user1} do
        token = sign_in_user(user1)

        response =
          make_api_request(
            @api_my_ratings_path,
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

        # Create 25 posts and rate them
        for i <- 1..25 do
          post = create_blog_post!(site_id: site.id, status: :published, title: "Post #{i}")
          # Ratings 1-5
          rating = rem(i, 5) + 1
          create_post_rating!(post_id: post.id, user_id: user1.id, rating: rating)
        end

        # Request first page with limit 10
        response =
          make_api_request(
            "#{@api_my_ratings_path}?page[limit]=10",
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status == 200
        body = Jason.decode!(response.resp_body)
        assert length(body["data"]) == 10
      end

      test "unauthenticated user cannot list ratings", %{} do
        response =
          make_api_request(
            @api_my_ratings_path,
            %{},
            method: :get
          )

        # Returns 403 because authorization fails without actor
        assert response.status == 403
      end
    end

    describe "DELETE /post-rating/:id - Remove rating" do
      test "user can remove their own rating", %{site: site, user1: user1} do
        token = sign_in_user(user1)
        post = create_blog_post!(site_id: site.id, status: :published)

        rating = create_post_rating!(post_id: post.id, user_id: user1.id, rating: 5)

        response =
          make_api_request(
            "#{@api_rating_path}/#{rating.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        # DELETE with default destroy action returns 200 OK
        assert response.status == 200

        # Verify rating was removed
        list_response =
          make_api_request(
            @api_my_ratings_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        list_body = Jason.decode!(list_response.resp_body)
        assert list_body["data"] == []
      end

      test "user cannot remove another user's rating", %{site: site, user1: user1, user2: user2} do
        token1 = sign_in_user(user1)
        post = create_blog_post!(site_id: site.id, status: :published)

        # User2 creates a rating
        rating = create_post_rating!(post_id: post.id, user_id: user2.id, rating: 5)

        # User1 tries to delete user2's rating
        response =
          make_api_request(
            "#{@api_rating_path}/#{rating.id}",
            %{},
            method: :delete,
            headers: [{"authorization", "Bearer #{token1}"}]
          )

        assert response.status in [403, 404]
      end

      test "unauthenticated user cannot remove rating", %{site: site, user1: user1} do
        post = create_blog_post!(site_id: site.id, status: :published)

        rating = create_post_rating!(post_id: post.id, user_id: user1.id, rating: 5)

        response =
          make_api_request(
            "#{@api_rating_path}/#{rating.id}",
            %{},
            method: :delete
          )

        # Returns 403 because no actor present
        assert response.status == 403
      end
    end

    describe "Multiple users rating same post" do
      test "different users can rate the same post", %{site: site, user1: user1, user2: user2} do
        token1 = sign_in_user(user1)
        token2 = sign_in_user(user2)
        post = create_blog_post!(site_id: site.id, status: :published)

        # User1 gives 5 stars
        response1 =
          make_api_request(
            @api_rating_path,
            %{
              "type" => "post_rating",
              "attributes" => %{
                "post_id" => post.id,
                "rating" => 5
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token1}"}]
          )

        assert response1.status == 201

        # User2 gives 3 stars to the same post
        response2 =
          make_api_request(
            @api_rating_path,
            %{
              "type" => "post_rating",
              "attributes" => %{
                "post_id" => post.id,
                "rating" => 3
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token2}"}]
          )

        assert response2.status == 201

        # Verify both ratings exist and are different
        body1 = Jason.decode!(response1.resp_body)
        body2 = Jason.decode!(response2.resp_body)
        assert body1["data"]["id"] != body2["data"]["id"]
        assert body1["data"]["attributes"]["rating"] == 5
        assert body2["data"]["attributes"]["rating"] == 3
      end
    end

    describe "Post status filtering" do
      test "user cannot see ratings for non-published posts", %{site: site, user1: user1} do
        token = sign_in_user(user1)

        # Create a published post and rate it
        post = create_blog_post!(site_id: site.id, status: :published, title: "Published Post")

        response1 =
          make_api_request(
            @api_rating_path,
            %{
              "type" => "post_rating",
              "attributes" => %{
                "post_id" => post.id,
                "rating" => 5
              }
            },
            method: :post,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response1.status == 201

        # Verify rating appears in user's list
        list_response1 =
          make_api_request(
            @api_my_ratings_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert list_response1.status == 200
        body1 = Jason.decode!(list_response1.resp_body)
        assert length(body1["data"]) == 1

        # Change post status to draft
        Ash.update!(post, %{status: :draft}, action: :update, authorize?: false)

        # Get ratings again - should not see the rating for draft post
        list_response2 =
          make_api_request(
            @api_my_ratings_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert list_response2.status == 200
        body2 = Jason.decode!(list_response2.resp_body)

        # Ratings for non-published posts should be filtered out
        assert length(body2["data"]) == 0
      end

      test "user can see multiple ratings with only published posts visible", %{
        site: site,
        user1: user1
      } do
        token = sign_in_user(user1)

        # Create and rate three published posts
        post1 = create_blog_post!(site_id: site.id, status: :published, title: "Post 1")
        post2 = create_blog_post!(site_id: site.id, status: :published, title: "Post 2")
        post3 = create_blog_post!(site_id: site.id, status: :published, title: "Post 3")

        create_post_rating!(post_id: post1.id, user_id: user1.id, rating: 5)
        create_post_rating!(post_id: post2.id, user_id: user1.id, rating: 4)
        create_post_rating!(post_id: post3.id, user_id: user1.id, rating: 3)

        # Verify all 3 ratings appear
        list_response1 =
          make_api_request(
            @api_my_ratings_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert list_response1.status == 200
        body1 = Jason.decode!(list_response1.resp_body)
        assert length(body1["data"]) == 3

        # Change post2 to draft
        Ash.update!(post2, %{status: :draft}, action: :update, authorize?: false)

        # Get ratings again - should only see 2 (post1 and post3)
        list_response2 =
          make_api_request(
            @api_my_ratings_path,
            %{},
            method: :get,
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert list_response2.status == 200
        body2 = Jason.decode!(list_response2.resp_body)
        assert length(body2["data"]) == 2
      end
    end
  end
end
