# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Api.Json.OwnParentTest do
  @moduledoc """
  A tag or a collection cannot be made its own parent through the JSON:API, for a site's admin and
  for a master, and naming another record as the parent still works.
  """
  use MishkaBlog.ConnCase

  @moduletag :capture_log

  @password "Password123!"
  @api_user_path "/api/json/v1/auth/user"

  @resources [
    {"tag", "/api/json/v1/%s/admin/mishka-blog/tag", :create_blog_tag!, "parent_tag_id"},
    {"collection", "/api/json/v1/%s/admin/mishka-blog/collection", :create_collection!,
     "parent_collection_id"}
  ]

  setup do
    MishkaCmsCore.Runtime.States.SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()
    Application.put_env(:ash_json_api, MishkaBlog, router: MishkaBlog.TestRouter)

    site =
      create_site!(name: "localhost", host: "localhost", active: true, priority: 50, master: true)

    MishkaCmsCore.Runtime.States.SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    permission =
      Ash.create!(
        MishkaCmsCore.Accounts.Permission,
        %{name: "admin:api:*", description: "Full API access"},
        authorize?: false
      )

    master_user =
      MishkaCmsCore.Accounts.User
      |> Ash.Changeset.for_create(:create, %{
        email: "master-own-parent@example.com",
        hashed_password: Bcrypt.hash_pwd_salt(@password)
      })
      |> Ash.create!(authorize?: false, tenant: nil)
      |> Ash.Changeset.for_update(
        :assign_permissions,
        %{permission_ids: [permission.id]},
        authorize?: false
      )
      |> Ash.update!()

    tenant_admin =
      create_user!(
        email: "admin-own-parent@example.com",
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

    {:ok, site: site, master_user: master_user, tenant_admin: tenant_admin}
  end

  defp sign_in(user, headers) do
    response =
      make_api_request(
        "#{@api_user_path}/sign-in",
        %{
          "type" => "user",
          "attributes" => %{"email" => to_string(user.email), "password" => @password}
        },
        method: :post,
        headers: headers
      )

    assert response.status in [200, 201]
    Jason.decode!(response.resp_body)["meta"]["token"]
  end

  defp patch(path, type, attributes, headers) do
    make_api_request(path, %{"type" => type, "attributes" => attributes},
      method: :patch,
      headers: headers
    )
  end

  for {type, path, factory, field} <- @resources do
    test "a #{type} cannot be made its own parent by a site's admin", %{
      site: site,
      tenant_admin: tenant_admin
    } do
      record = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: site.id]])

      headers = [
        {"authorization", "Bearer #{sign_in(tenant_admin, [])}"},
        {"x-tenant-id", site.id}
      ]

      url = "#{String.replace(unquote(path), "%s", "tenant")}/#{record.id}"

      response = patch(url, unquote(type), %{unquote(field) => record.id}, headers)

      assert response.status in [400, 422]
      body = Jason.decode!(response.resp_body)
      assert [%{"source" => %{"pointer" => pointer}} | _] = body["errors"]
      assert pointer =~ unquote(field)
      assert Enum.any?(body["errors"], &(&1["detail"] =~ "cannot be its own parent"))
    end

    test "a #{type} cannot be made its own parent by a master", %{
      site: site,
      master_user: master_user
    } do
      record = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: site.id]])

      headers = [
        {"authorization", "Bearer #{sign_in(master_user, [{"x-no-tenant", "true"}])}"},
        {"x-no-tenant", "true"}
      ]

      url = "#{String.replace(unquote(path), "%s", "master")}/#{record.id}"

      response = patch(url, unquote(type), %{unquote(field) => record.id}, headers)

      assert response.status in [400, 422]
      body = Jason.decode!(response.resp_body)
      assert Enum.any?(body["errors"], &(&1["detail"] =~ "cannot be its own parent"))
    end

    test "a #{type} takes another #{type} as its parent", %{
      site: site,
      tenant_admin: tenant_admin
    } do
      record = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: site.id]])
      parent = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: site.id]])

      headers = [
        {"authorization", "Bearer #{sign_in(tenant_admin, [])}"},
        {"x-tenant-id", site.id}
      ]

      url = "#{String.replace(unquote(path), "%s", "tenant")}/#{record.id}"

      response = patch(url, unquote(type), %{unquote(field) => parent.id}, headers)

      assert response.status == 200
      body = Jason.decode!(response.resp_body)
      assert body["data"]["attributes"][unquote(field)] == parent.id
    end
  end
end
