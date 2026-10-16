# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.BloggerMasterProfileTest do
  @moduledoc """
  A master who writes on a site has a blogger profile there, as any of the site's own authors does.

  A profile belongs to one site and names a user of that site or a master. Only a master, or the
  system, links a profile to a master's account; a site's admin, even one holding `*`, links
  profiles only to its own site's users. A master has one profile per site, on as many sites as it
  writes for.

  The profile is the site's record: its name, bio and pictures show on the site's posts, the site's
  admin reads it and credits it on the site's other posts, and another site sees none of it. The
  account behind it is not the site's: its email, permissions, site and confirmation answer masters
  only, the master itself included, and never a site's admin or a visitor.

  `MishkaBlogWeb.Test.BloggerMasterProfileLiveTest` walks the same rules through the admin pages.
  """
  use MishkaBlog.ConnCase

  import MishkaBlog.Test.Factory

  alias MishkaBlog.{BlogPost, Blogger, PostBlogger, Team}
  alias MishkaCmsCore.Accounts.User
  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @refused "That user is not one this site can use."
  @account_fields [:email, :confirmed_at, :site_id, :permission_values]
  @sign_in "/api/json/v1/auth/user/sign-in"
  @tenant_blogger "/api/json/v1/tenant/admin/mishka-blog/blogger"
  @tenant_post "/api/json/v1/tenant/admin/mishka-blog/post"
  @tenant_team "/api/json/v1/tenant/admin/mishka-blog/team"
  @public_blogger "/api/json/v1/user/mishka-blog/blogger"
  @public_post "/api/json/v1/user/mishka-blog/post/published"
  @public_team "/api/json/v1/user/mishka-blog/team"

  setup do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()
    Application.put_env(:ash_json_api, MishkaBlog, router: MishkaBlog.TestRouter)

    site_a = create_site!(name: "localhost", host: "localhost", active: true, priority: 50)
    site_b = create_site!(name: "site-b", host: "site-b.test", active: true, priority: 40)

    for site <- [site_a, site_b] do
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active
      })
    end

    on_exit(fn -> SiteState.clear() end)

    {:ok,
     site_a: site_a,
     site_b: site_b,
     master: create_user_with_permissions!(["*"], email: "the.master@example.com"),
     other_master: create_user!(email: "other.master@example.com"),
     admin_a:
       create_user_with_permissions!(["*"], email: "admin.a@example.com", site_id: site_a.id),
     admin_b:
       create_user_with_permissions!(["*"], email: "admin.b@example.com", site_id: site_b.id),
     writer_a: create_user!(email: "writer.a@example.com", site_id: site_a.id)}
  end

  defp profile_attrs(user, extra \\ %{}) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{user_id: user.id, display_name: "Writer #{n}", slug: "writer-#{n}", bio: "Bio #{n}"},
      extra
    )
  end

  defp master_create(actor, site, user) do
    Blogger
    |> Ash.Changeset.for_create(:master_create, profile_attrs(user, %{site_id: site.id}),
      actor: actor
    )
    |> Ash.create()
  end

  defp site_create(actor, site, user) do
    Blogger
    |> Ash.Changeset.for_create(:create, profile_attrs(user), actor: actor, tenant: site.id)
    |> Ash.create()
  end

  defp site_update(profile, actor, params) do
    profile
    |> Ash.Changeset.for_update(:update, params, actor: actor, tenant: profile.site_id)
    |> Ash.update()
  end

  defp master_profile!(ctx, site), do: ok!(master_create(ctx.master, site, ctx.master))

  defp ok!({:ok, record}), do: record

  defp reload(profile),
    do: Ash.get!(Blogger, profile.id, action: :master_get, authorize?: false)

  defp profiles_of(user) do
    Blogger
    |> Ash.Query.for_read(:master_read, %{}, authorize?: false)
    |> Ash.Query.filter(user_id == ^user.id)
    |> Ash.read!(authorize?: false, page: false)
  end

  defp assert_refused(result) do
    assert {:error, error} = result
    assert Exception.message(error) =~ @refused
  end

  defp sign_in(user, host) do
    response =
      make_api_request(
        @sign_in,
        %{
          "type" => "user",
          "attributes" => %{"email" => to_string(user.email), "password" => "Password123!"}
        },
        host: host
      )

    assert response.status == 201, response.resp_body
    Jason.decode!(response.resp_body)["meta"]["token"]
  end

  describe "who may link a profile to a master's account" do
    test "a master links a profile on any site to itself or to another master", ctx do
      assert {:ok, own} = master_create(ctx.master, ctx.site_a, ctx.master)
      assert own.user_id == ctx.master.id

      assert {:ok, other} = master_create(ctx.master, ctx.site_b, ctx.other_master)
      assert other.user_id == ctx.other_master.id

      assert {:ok, on_site} = site_create(ctx.master, ctx.site_b, ctx.master)
      assert on_site.site_id == ctx.site_b.id

      third_master = create_user!()

      assert {:ok, moved} =
               own
               |> reload()
               |> Ash.Changeset.for_update(:master_update, %{user_id: third_master.id},
                 actor: ctx.master
               )
               |> Ash.update()

      assert moved.user_id == third_master.id

      assert {:ok, back} = site_update(moved, ctx.master, %{user_id: ctx.master.id})
      assert back.user_id == ctx.master.id
    end

    test "the system links one too", ctx do
      assert {:ok, profile} =
               Blogger
               |> Ash.Changeset.for_create(:create, profile_attrs(ctx.other_master),
                 tenant: ctx.site_a.id,
                 authorize?: false
               )
               |> Ash.create()

      assert profile.user_id == ctx.other_master.id
    end

    test "a site's admin holding * cannot make a profile for a master", ctx do
      for master <- [ctx.master, ctx.other_master] do
        assert_refused(site_create(ctx.admin_a, ctx.site_a, master))
        assert profiles_of(master) == []
      end
    end

    test "nor point an existing profile at a master", ctx do
      profile = ok!(site_create(ctx.admin_a, ctx.site_a, ctx.writer_a))

      assert_refused(site_update(profile, ctx.admin_a, %{user_id: ctx.master.id}))
      assert reload(profile).user_id == ctx.writer_a.id
    end

    test "nor through a call it makes with authorization turned off", ctx do
      profile = ok!(site_create(ctx.admin_a, ctx.site_a, ctx.writer_a))

      assert_refused(
        Blogger
        |> Ash.Changeset.for_create(:create, profile_attrs(ctx.master),
          actor: ctx.admin_a,
          tenant: ctx.site_a.id,
          authorize?: false
        )
        |> Ash.create()
      )

      assert_refused(
        profile
        |> Ash.Changeset.for_update(:update, %{user_id: ctx.master.id},
          actor: ctx.admin_a,
          tenant: ctx.site_a.id,
          authorize?: false
        )
        |> Ash.update()
      )

      assert profiles_of(ctx.master) == []
    end

    test "the one asked is whoever runs the call, not whoever built it", ctx do
      built_as_system =
        Blogger
        |> Ash.Changeset.for_create(:create, profile_attrs(ctx.master),
          tenant: ctx.site_a.id,
          authorize?: false
        )

      assert_refused(Ash.create(built_as_system, actor: ctx.admin_a, authorize?: true))
      assert profiles_of(ctx.master) == []

      profile = ok!(site_create(ctx.admin_a, ctx.site_a, ctx.writer_a))

      assert_refused(
        profile
        |> Ash.Changeset.for_update(:update, %{user_id: ctx.master.id},
          tenant: ctx.site_a.id,
          authorize?: false
        )
        |> Ash.update(actor: ctx.admin_a, authorize?: true)
      )

      assert reload(profile).user_id == ctx.writer_a.id

      built_bare =
        Blogger
        |> Ash.Changeset.for_create(:create, profile_attrs(ctx.other_master),
          tenant: ctx.site_a.id
        )

      assert {:ok, by_system} = Ash.create(built_bare, authorize?: false)
      assert by_system.user_id == ctx.other_master.id

      assert {:ok, moved_by_system} =
               profile
               |> Ash.Changeset.for_update(:update, %{user_id: ctx.master.id},
                 tenant: ctx.site_a.id
               )
               |> Ash.update(authorize?: false)

      assert moved_by_system.user_id == ctx.master.id
    end

    test "nor through a bulk create or a bulk update", ctx do
      assert %Ash.BulkResult{status: :error, errors: [error]} =
               Ash.bulk_create([profile_attrs(ctx.master)], Blogger, :create,
                 actor: ctx.admin_a,
                 tenant: ctx.site_a.id,
                 return_errors?: true
               )

      assert Exception.message(error) =~ @refused

      profile = ok!(site_create(ctx.admin_a, ctx.site_a, ctx.writer_a))

      assert %Ash.BulkResult{status: :error, errors: [error]} =
               Blogger
               |> Ash.Query.filter(id == ^profile.id)
               |> Ash.bulk_update(:update, %{user_id: ctx.master.id},
                 actor: ctx.admin_a,
                 tenant: ctx.site_a.id,
                 strategy: [:atomic, :stream],
                 return_errors?: true
               )

      assert Exception.message(error) =~ @refused
      assert reload(profile).user_id == ctx.writer_a.id
      assert profiles_of(ctx.master) == []
    end

    test "nor over the JSON:API, where the refusal reads the same", ctx do
      token = sign_in(ctx.admin_a, ctx.site_a.host)

      response =
        make_api_request(
          @tenant_blogger,
          %{
            "type" => "blogger",
            "attributes" => Map.new(profile_attrs(ctx.master), fn {k, v} -> {to_string(k), v} end)
          },
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 400
      assert [%{"detail" => @refused}] = Jason.decode!(response.resp_body)["errors"]
      assert profiles_of(ctx.master) == []

      profile = ok!(site_create(ctx.admin_a, ctx.site_a, ctx.writer_a))

      response =
        make_api_request(
          "#{@tenant_blogger}/#{profile.id}",
          %{
            "type" => "blogger",
            "id" => profile.id,
            "attributes" => %{"user_id" => ctx.master.id}
          },
          method: "PATCH",
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 400
      assert reload(profile).user_id == ctx.writer_a.id
    end

    test "nor by restoring a version of the profile that named a master", ctx do
      profile = master_profile!(ctx, ctx.site_a)

      named_master =
        Blogger.Version
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
        |> Ash.Query.filter(version_source_id == ^profile.id)
        |> Ash.read_one!(authorize?: false)

      moved = ok!(site_update(profile, ctx.admin_a, %{user_id: ctx.writer_a.id}))

      assert_refused(
        Blogger
        |> Ash.ActionInput.for_action(
          :restore_version_api,
          %{id: profile.id, version_id: named_master.id},
          actor: ctx.admin_a,
          tenant: ctx.site_a.id
        )
        |> Ash.run_action()
      )

      assert_refused(
        moved
        |> Ash.Changeset.for_update(:restore_version, %{version_id: named_master.id},
          actor: ctx.admin_a,
          tenant: ctx.site_a.id
        )
        |> Ash.update()
      )

      assert reload(profile).user_id == ctx.writer_a.id

      assert {:ok, restored} =
               Blogger
               |> Ash.ActionInput.for_action(
                 :master_restore_version_api,
                 %{id: profile.id, version_id: named_master.id},
                 actor: ctx.master
               )
               |> Ash.run_action()

      assert restored.user_id == ctx.master.id
    end

    test "a site's admin still links profiles to its own site's users", ctx do
      assert {:ok, profile} = site_create(ctx.admin_a, ctx.site_a, ctx.writer_a)
      other = create_user!(site_id: ctx.site_a.id)

      assert {:ok, moved} = site_update(profile, ctx.admin_a, %{user_id: other.id})
      assert moved.user_id == other.id
    end

    test "and edits a master's profile on its site, leaving the account it names alone", ctx do
      profile = master_profile!(ctx, ctx.site_a)

      assert {:ok, edited} =
               site_update(profile, ctx.admin_a, %{display_name: "Edited by the site", bio: "New"})

      assert edited.display_name == "Edited by the site"
      assert reload(profile).user_id == ctx.master.id
    end
  end

  describe "a master's profiles" do
    test "a master has a profile of its own on each site it writes for", ctx do
      assert {:ok, on_a} = master_create(ctx.master, ctx.site_a, ctx.master)
      assert {:ok, on_b} = master_create(ctx.master, ctx.site_b, ctx.master)

      assert Enum.sort([on_a.site_id, on_b.site_id]) ==
               Enum.sort([ctx.site_a.id, ctx.site_b.id])

      assert Enum.map(profiles_of(ctx.master), & &1.id) |> Enum.sort() ==
               Enum.sort([on_a.id, on_b.id])
    end

    test "and one only on each", ctx do
      master_profile!(ctx, ctx.site_a)

      assert {:error, error} = master_create(ctx.master, ctx.site_a, ctx.master)
      assert Exception.message(error) =~ "User already has a blogger profile in this site"

      assert {:error, _} = site_create(ctx.master, ctx.site_a, ctx.master)
      assert length(profiles_of(ctx.master)) == 1
    end
  end

  describe "an account a profile names, moved by a master" do
    defp move_account(user, site_id, master) do
      User
      |> Ash.ActionInput.for_action(:master_update, %{id: user.id, site_id: site_id},
        actor: master
      )
      |> Ash.run_action()
    end

    defp move_account_by_form(user, site_id, master) do
      User
      |> Ash.get!(user.id, action: :master_get, authorize?: false)
      |> Ash.Changeset.for_update(:master_form_update, %{site_id: site_id}, actor: master)
      |> Ash.update()
    end

    defp account_site(user),
      do: Ash.get!(User, user.id, action: :master_get, authorize?: false).site_id

    test "a site's writer with a profile there becomes a master, and keeps the profile", ctx do
      profile = ok!(site_create(ctx.admin_a, ctx.site_a, ctx.writer_a))

      assert {:ok, _made_master} = move_account(ctx.writer_a, nil, ctx.master)
      assert account_site(ctx.writer_a) == nil
      assert reload(profile).user_id == ctx.writer_a.id

      by_form = create_user!(site_id: ctx.site_a.id)
      ok!(site_create(ctx.admin_a, ctx.site_a, by_form))

      assert {:ok, _made_master} = move_account_by_form(by_form, nil, ctx.master)
      assert account_site(by_form) == nil
    end

    test "a master with a profile on two sites moves onto neither", ctx do
      ok!(master_create(ctx.master, ctx.site_a, ctx.other_master))
      ok!(master_create(ctx.master, ctx.site_b, ctx.other_master))

      assert {:error, error} = move_account(ctx.other_master, ctx.site_a.id, ctx.master)
      assert Exception.message(error) =~ "Records outside that site still use this account"

      assert {:error, _refused} =
               move_account_by_form(ctx.other_master, ctx.site_b.id, ctx.master)

      assert account_site(ctx.other_master) == nil
    end
  end

  describe "the account behind a master's profile" do
    setup ctx do
      profile = master_profile!(ctx, ctx.site_a)
      post = create_blog_post!(site_id: ctx.site_a.id, status: :published)
      create_post_blogger!(post_id: post.id, blogger_id: profile.id)
      team = create_team!(site_id: ctx.site_a.id, status: :active)
      create_team_member!(team_id: team.id, blogger_id: profile.id)

      {:ok, profile: profile, post: post, team: team}
    end

    defp withheld?(%User{} = user),
      do: Enum.all?(@account_fields, &match?(%Ash.ForbiddenField{}, Map.get(user, &1)))

    defp withheld?(nil), do: true

    defp read_profile(profile, action, actor, tenant, load) do
      Blogger
      |> Ash.Query.for_read(action, %{}, actor: actor, tenant: tenant)
      |> Ash.Query.filter(id == ^profile.id)
      |> Ash.Query.load(load)
      |> Ash.read_one!(actor: actor, tenant: tenant)
    end

    test "a site's admin reads the profile, and none of the account", ctx do
      seen = read_profile(ctx.profile, :read, ctx.admin_a, ctx.site_a.id, [:user, :author_email])

      assert seen.display_name == ctx.profile.display_name
      assert seen.bio == ctx.profile.bio
      assert seen.user_id == ctx.master.id
      assert withheld?(seen.user)
      refute seen.author_email == to_string(ctx.master.email)
    end

    test "a visitor reads the profile, and none of the account", ctx do
      seen = read_profile(ctx.profile, :public_get, nil, ctx.site_a.id, [:user, :author_email])

      assert seen.display_name == ctx.profile.display_name
      assert withheld?(seen.user)
      assert %Ash.ForbiddenField{} = seen.author_email
    end

    test "nor through the site's post or team that credits the profile", ctx do
      post =
        BlogPost
        |> Ash.Query.for_read(:read, %{}, actor: ctx.admin_a, tenant: ctx.site_a.id)
        |> Ash.Query.filter(id == ^ctx.post.id)
        |> Ash.Query.load(tenant_bloggers: [:user, :author_email], bloggers: [:user])
        |> Ash.read_one!(actor: ctx.admin_a, tenant: ctx.site_a.id)

      assert [credited] = post.tenant_bloggers
      assert credited.display_name == ctx.profile.display_name
      assert withheld?(credited.user)
      refute credited.author_email == to_string(ctx.master.email)
      assert Enum.all?(post.bloggers, &withheld?(&1.user))

      team =
        Team
        |> Ash.Query.for_read(:read, %{}, actor: ctx.admin_a, tenant: ctx.site_a.id)
        |> Ash.Query.filter(id == ^ctx.team.id)
        |> Ash.Query.load(tenant_members: [:user, :author_email], members: [:user])
        |> Ash.read_one!(actor: ctx.admin_a, tenant: ctx.site_a.id)

      assert [member] = team.tenant_members
      assert withheld?(member.user)
      refute member.author_email == to_string(ctx.master.email)
      assert Enum.all?(team.members, &withheld?(&1.user))
    end

    test "a site's admin never receives the master's email over the JSON:API", ctx do
      token = sign_in(ctx.admin_a, ctx.site_a.host)
      email = to_string(ctx.master.email)

      for url <- [
            "#{@tenant_blogger}?fields[blogger]=display_name,author_email",
            "#{@tenant_blogger}/#{ctx.profile.id}?fields[blogger]=display_name,author_email",
            "#{@tenant_blogger}/by-user/#{ctx.master.id}?fields[blogger]=author_email",
            "#{@tenant_post}/#{ctx.post.id}?include=tenant_bloggers.user,bloggers.user",
            "#{@tenant_post}/#{ctx.post.id}?include=tenant_bloggers&fields[blogger]=author_email",
            "#{@tenant_team}/#{ctx.team.id}?include=tenant_members.user,members.user",
            "#{@tenant_team}/#{ctx.team.id}?include=tenant_members&fields[blogger]=author_email"
          ] do
        response =
          make_api_request(url, nil,
            method: "GET",
            headers: [{"authorization", "Bearer #{token}"}]
          )

        assert response.status in [200, 400], "#{url}: #{response.status}"
        refute response.resp_body =~ email, "#{url} gave a site's admin the master's email"
      end
    end

    test "nor can it tell the address by filtering on it", ctx do
      token = sign_in(ctx.admin_a, ctx.site_a.host)

      answer = fn email ->
        response =
          make_api_request("#{@tenant_blogger}?filter[author_email]=#{email}", nil,
            method: "GET",
            headers: [{"authorization", "Bearer #{token}"}]
          )

        {response.status,
         response.resp_body
         |> Jason.decode!()
         |> Map.get("data", [])
         |> List.wrap()
         |> Enum.map(& &1["id"])}
      end

      assert answer.(to_string(ctx.master.email)) == answer.("nobody@example.com")
    end

    test "a visitor never receives it either", ctx do
      email = to_string(ctx.master.email)

      for url <- [
            "#{@public_blogger}?fields[blogger]=display_name,author_email",
            "#{@public_blogger}/#{ctx.profile.id}?fields[blogger]=author_email",
            "#{@public_post}?include=bloggers.user",
            "#{@public_post}/#{ctx.post.id}?include=bloggers.user",
            "#{@public_team}/#{ctx.team.id}?include=members.user"
          ] do
        response = make_api_request(url, nil, method: "GET")
        refute response.resp_body =~ email, "#{url} gave a visitor the master's email"
      end

      response = make_api_request("#{@public_blogger}/#{ctx.profile.id}", nil, method: "GET")
      assert response.status == 200

      assert Jason.decode!(response.resp_body)["data"]["attributes"]["display_name"] ==
               ctx.profile.display_name
    end

    test "the master itself and another master read the whole account", ctx do
      other = create_user_with_permissions!(["*"], email: "another.master@example.com")

      for reader <- [ctx.master, other] do
        seen = read_profile(ctx.profile, :master_read, reader, nil, [:user, :author_email])

        assert to_string(seen.user.email) == to_string(ctx.master.email)
        assert seen.user.site_id == nil
        assert seen.author_email == to_string(ctx.master.email)
      end
    end
  end

  describe "a master's profile on a site's other posts" do
    setup ctx do
      {:ok, profile: master_profile!(ctx, ctx.site_a)}
    end

    defp credited?(post, profile) do
      PostBlogger
      |> Ash.Query.filter(post_id == ^post.id and blogger_id == ^profile.id)
      |> Ash.exists?(authorize?: false)
    end

    test "the site's admin credits it on the site's posts, every way a post takes an author",
         ctx do
      post = create_blog_post!(site_id: ctx.site_a.id)

      assert {:ok, _} =
               post
               |> Ash.Changeset.for_update(:assign_bloggers, %{blogger_ids: [ctx.profile.id]},
                 actor: ctx.admin_a,
                 tenant: ctx.site_a.id
               )
               |> Ash.update()

      assert credited?(post, ctx.profile)

      other = create_blog_post!(site_id: ctx.site_a.id)

      assert {:ok, _} =
               PostBlogger
               |> Ash.Changeset.for_create(
                 :assign,
                 %{post_id: other.id, blogger_id: ctx.profile.id},
                 actor: ctx.admin_a,
                 tenant: ctx.site_a.id
               )
               |> Ash.create()

      assert credited?(other, ctx.profile)

      n = System.unique_integer([:positive])

      assert {:ok, written} =
               BlogPost
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   title: "Credited #{n}",
                   slug: "credited-#{n}",
                   content: "<p>Credited</p>",
                   status: :draft,
                   blogger_ids: [ctx.profile.id]
                 },
                 actor: ctx.admin_a,
                 tenant: ctx.site_a.id
               )
               |> Ash.create()

      assert credited?(written, ctx.profile)
    end

    test "another site's admin neither sees it nor credits it", ctx do
      assert {:error, _} =
               Ash.get(Blogger, ctx.profile.id, actor: ctx.admin_b, tenant: ctx.site_b.id)

      refute Blogger
             |> Ash.Query.for_read(:read, %{}, actor: ctx.admin_b, tenant: ctx.site_b.id)
             |> Ash.read!(actor: ctx.admin_b, tenant: ctx.site_b.id)
             |> Enum.any?(&(&1.id == ctx.profile.id))

      post_b = create_blog_post!(site_id: ctx.site_b.id)

      assert {:error, _} =
               post_b
               |> Ash.Changeset.for_update(:assign_bloggers, %{blogger_ids: [ctx.profile.id]},
                 actor: ctx.admin_b,
                 tenant: ctx.site_b.id
               )
               |> Ash.update()

      refute credited?(post_b, ctx.profile)
    end
  end
end
