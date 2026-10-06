defmodule MishkaBlogWeb.Api.Json.AreaPermissionsTest do
  @moduledoc """
  The admin JSON:API is its own surface: a blog route asks for `admin:api:blog:post` or
  `admin:api:blog:comment`, so a bearer holding the area on the API is let in, and one holding the
  same area on the dashboard only, or the blog's other area, is refused. A team's permissions over
  the API also need `admin:api:permission`.
  """
  use MishkaBlog.ConnCase
  import MishkaBlog.Test.Factory

  require Ash.Query

  alias MishkaCmsCore.Accounts.Permission
  alias MishkaCmsCore.Runtime.States.SiteState

  @moduletag :capture_log

  @password "Password123!"
  @tenant "/api/json/v1/tenant/admin/mishka-blog"

  setup do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()
    Application.put_env(:ash_json_api, MishkaBlog, router: MishkaBlog.TestRouter)

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    on_exit(fn -> SiteState.clear() end)

    %{site: site}
  end

  defp bearer(site, names) do
    user =
      create_user_with_permissions!(names,
        site_id: site.id,
        email: "admin#{System.unique_integer([:positive])}@example.com",
        password: @password,
        password_confirmation: @password
      )

    response =
      make_api_request(
        "/api/json/v1/auth/user/sign-in",
        %{
          "type" => "user",
          "attributes" => %{"email" => to_string(user.email), "password" => @password}
        }
      )

    assert response.status == 201
    [{"authorization", "Bearer " <> Jason.decode!(response.resp_body)["meta"]["token"]}]
  end

  defp list(route, headers),
    do: make_api_request("#{@tenant}/#{route}", %{}, method: :get, headers: headers)

  describe "posts" do
    setup %{site: site} do
      %{post: create_blog_post!(site_id: site.id)}
    end

    test "are listed for the post area on the API", %{site: site, post: post} do
      response = list("post", bearer(site, ["admin:api:blog:post"]))

      assert response.status == 200
      assert [%{"id" => id}] = Jason.decode!(response.resp_body)["data"]
      assert id == post.id
    end

    test "are refused to the same area on the dashboard, and to the comment area", %{site: site} do
      for names <- [
            ["admin:dashboard:blog:post"],
            ["admin:api:blog:comment"],
            ["admin:api:runtime:page"]
          ] do
        assert list("post", bearer(site, names)).status == 403, inspect(names)
      end
    end

    test "are written with the post area on the API only", %{site: site} do
      create = fn headers ->
        make_api_request(
          "#{@tenant}/post",
          %{
            "type" => "blog_post",
            "attributes" => %{
              "title" => "Over the API",
              "slug" => "over-the-api-#{System.unique_integer([:positive])}",
              "content" => "<p>Body</p>"
            }
          },
          headers: headers
        )
      end

      assert create.(bearer(site, ["admin:dashboard:blog:post"])).status == 403
      assert create.(bearer(site, ["admin:api:blog:post"])).status == 201
    end
  end

  describe "comments" do
    setup %{site: site} do
      %{comment: create_comment!(site_id: site.id)}
    end

    test "are listed for the comment area on the API", %{site: site, comment: comment} do
      response = list("comment", bearer(site, ["admin:api:blog:comment"]))

      assert response.status == 200
      assert [%{"id" => id}] = Jason.decode!(response.resp_body)["data"]
      assert id == comment.id
    end

    test "are refused to the same area on the dashboard, and to the post area", %{site: site} do
      for names <- [["admin:dashboard:blog:comment"], ["admin:api:blog:post"]] do
        assert list("comment", bearer(site, names)).status == 403, inspect(names)
      end
    end
  end

  describe "a team's permissions" do
    setup %{site: site} do
      %{team: create_team!(site_id: site.id), held: permission_id("admin:api:blog:post")}
    end

    defp permission_id(name) do
      case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
        {:ok, nil} -> create_permission!(name: name).id
        {:ok, permission} -> permission.id
      end
    end

    defp attach(team, permission_id, headers) do
      make_api_request(
        "#{@tenant}/team/#{team.id}",
        %{
          "type" => "team",
          "id" => team.id,
          "attributes" => %{"permission_ids" => [permission_id]}
        },
        method: :patch,
        headers: headers
      )
    end

    # Attaching reads the permission from the catalogue as the bearer, which asks the catalogue's
    # own read policy; a full admin of one surface reads it however that policy is written.
    test "are attached by an API admin, the row written for it asked on the API too", ctx do
      headers = bearer(ctx.site, ["admin:api:*"])

      assert attach(ctx.team, ctx.held, headers).status == 200
    end

    test "are refused to the permission area on the dashboard only", %{site: site} = ctx do
      headers = bearer(site, ["admin:api:blog:post", "admin:dashboard:*"])

      assert attach(ctx.team, ctx.held, headers).status == 403
    end
  end
end
