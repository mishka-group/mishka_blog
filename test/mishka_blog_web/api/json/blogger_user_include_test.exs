# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Api.Json.BloggerUserIncludeTest do
  @moduledoc """
  The public blogger endpoints are anonymous by design — author pages are public — and they used to
  declare `:user` among their JSON:API includes, which published the account behind each profile.

  The include is gone from Blogger: a public author page renders the blogger's own `display_name`,
  `slug`, `bio` and `avatar_url`. Other resources still include accounts — a post's `bloggers.user`,
  a comment's `author`, a team's `members.user` — and those are answered on the User side: an
  account reached through another resource shows its id to everyone, and its email, permissions,
  site and confirmation time only to its owner and to admins. That rule is scoped to relationship
  loads, because the sign-in response, `/me` and the signed-in actor itself read the User directly
  and must keep the whole account.

  `author_email` below is the admin way to the address from a blogger, gated by Blogger's own field
  policy.
  """
  use MishkaBlog.ConnCase

  import MishkaBlog.Test.Factory

  alias MishkaCmsCore.Runtime.States.SiteState

  require Ash.Query

  @password "Password123!"
  @public "/api/json/v1/user/mishka-blog/blogger"
  @tenant_admin "/api/json/v1/tenant/admin/mishka-blog/blogger"
  @sign_in "/api/json/v1/auth/user/sign-in"

  setup do
    SiteState.clear()
    :ok = Swoosh.TestAssertions.set_swoosh_global()
    Application.put_env(:ash_json_api, MishkaBlog, router: MishkaBlog.TestRouter)

    site = create_site!(name: "localhost", host: "localhost", active: true, priority: 50)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active
    })

    user = create_user!(email: "author@example.com", site_id: site.id)

    admin =
      create_user_with_permissions!(["admin:dashboard:*", "admin:api:*"],
        email: "editor@example.com",
        password: @password,
        password_confirmation: @password,
        site_id: site.id
      )

    blogger =
      create_blogger!(
        site_id: site.id,
        user_id: user.id,
        display_name: "Jane Author",
        status: :active
      )

    {:ok, site: site, user: user, blogger: blogger, admin: admin}
  end

  test "the public endpoint does not offer :user as an include at all" do
    response = make_api_request("#{@public}?include=user", nil, method: "GET")

    refute response.status == 200,
           "`?include=user` is answered, so the account is reachable from a public page again"
  end

  test "no account field reaches an anonymous caller by any route through this endpoint", %{
    user: user
  } do
    response = make_api_request(@public, nil, method: "GET")

    assert response.status == 200

    refute response.resp_body =~ to_string(user.email),
           "the account's email is in a public response"

    refute response.resp_body =~ "permission_values"
  end

  test "the blogger's own public fields still render — the page keeps working", %{
    blogger: blogger
  } do
    response = make_api_request(@public, nil, method: "GET")

    assert response.status == 200
    body = Jason.decode!(response.resp_body)

    assert Enum.any?(body["data"], &(&1["attributes"]["display_name"] == blogger.display_name)),
           "display_name is what a public author page shows and it must survive"
  end

  describe "the profile itself" do
    # A profile is the public face of an account: name, slug, bio, pictures, links, the contact
    # address its owner chose to publish. Whether the account may publish without review is a
    # moderation setting, and the history and the account's own address are for admins.
    @withheld_from_visitors [
      "can_publish_directly",
      "author_email",
      "version_count",
      "latest_version",
      "recent_versions"
    ]

    defp fields_query do
      "fields[blogger]=display_name,slug,bio,avatar_url,social_links,contact_email," <>
        Enum.join(@withheld_from_visitors, ",")
    end

    test "a visitor gets the public profile and none of the rest", %{blogger: blogger} do
      response =
        make_api_request("#{@public}/#{blogger.id}?#{fields_query()}", nil, method: "GET")

      assert response.status == 200
      attributes = Jason.decode!(response.resp_body)["data"]["attributes"]

      assert attributes["display_name"] == "Jane Author"
      assert Map.take(attributes, @withheld_from_visitors) == %{}
    end

    test "an admin gets the moderation setting", %{blogger: blogger, admin: admin} do
      response =
        make_api_request("#{@tenant_admin}/#{blogger.id}?#{fields_query()}", nil,
          method: "GET",
          headers: [{"authorization", "Bearer #{sign_in(admin)}"}]
        )

      assert response.status == 200
      attributes = Jason.decode!(response.resp_body)["data"]["attributes"]
      assert attributes["can_publish_directly"] == false
    end
  end

  describe "author_email — the admin way to reach the account" do
    test "an anonymous caller asking for it gets it withheld", %{user: user, site: site} do
      blogger =
        MishkaBlog.Blogger
        |> Ash.Query.for_read(:public_list, %{})
        |> Ash.Query.load(:author_email)
        |> Ash.read!(actor: nil, tenant: site.id)
        |> List.first()

      assert %Ash.ForbiddenField{} = blogger.author_email
      refute blogger.author_email == to_string(user.email)
    end

    test "the rest of the author page is untouched by the field policy", %{
      blogger: expected,
      site: site
    } do
      blogger =
        MishkaBlog.Blogger
        |> Ash.Query.for_read(:public_list, %{})
        |> Ash.read!(actor: nil, tenant: site.id)
        |> List.first()

      assert blogger.display_name == expected.display_name
      assert blogger.slug == expected.slug
    end

    # The blog's post area on the request's surface: the dashboard unless the shared context names
    # the API.
    for {permission, surface} <- [
          {"admin:dashboard:blog:post", :dashboard},
          {"admin:dashboard:*", :dashboard},
          {"admin:api:blog:post", :api},
          {"admin:api:*", :api},
          {"*", :dashboard}
        ] do
      test "an admin holding #{permission} reads it on the #{surface}", %{user: user, site: site} do
        admin = create_user_with_permissions!([unquote(permission)], site_id: site.id)

        blogger =
          MishkaBlog.Blogger
          |> Ash.Query.for_read(:public_list, %{},
            context: %{shared: %{admin_surface: unquote(surface)}}
          )
          |> Ash.Query.load(:author_email)
          |> Ash.read!(actor: admin, tenant: site.id)
          |> List.first()

        assert blogger.author_email == to_string(user.email)
      end
    end

    test "the post area on the API does not read it on the dashboard", %{site: site} do
      admin = create_user_with_permissions!(["admin:api:blog:post"], site_id: site.id)

      blogger =
        MishkaBlog.Blogger
        |> Ash.Query.for_read(:public_list, %{})
        |> Ash.Query.load(:author_email)
        |> Ash.read!(actor: admin, tenant: site.id)
        |> List.first()

      assert %Ash.ForbiddenField{} = blogger.author_email
    end

    test "a signed-in user without the post area does not", %{site: site} do
      reader = create_user_with_permissions!(["admin:dashboard:blog:comment"], site_id: site.id)

      blogger =
        MishkaBlog.Blogger
        |> Ash.Query.for_read(:public_list, %{})
        |> Ash.Query.load(:author_email)
        |> Ash.read!(actor: reader, tenant: site.id)
        |> List.first()

      assert %Ash.ForbiddenField{} = blogger.author_email
    end

    test "an anonymous JSON:API response never carries the address, however it is requested", %{
      user: user
    } do
      for query <- ["", "?fields[blogger]=author_email", "?include=user"] do
        body = make_api_request("#{@public}#{query}", nil, method: "GET").resp_body

        refute body =~ to_string(user.email), "#{query} leaked the account email"
      end
    end
  end

  describe "author_email over the JSON:API, not just through Ash" do
    defp sign_in(user) do
      response =
        make_api_request(@sign_in, %{
          "type" => "user",
          "attributes" => %{"email" => to_string(user.email), "password" => @password}
        })

      assert response.status == 201
      %{"meta" => %{"token" => token}} = Jason.decode!(response.resp_body)
      token
    end

    test "an admin over the wire receives it", %{admin: admin, user: author} do
      token = sign_in(admin)

      response =
        make_api_request("#{@tenant_admin}?fields[blogger]=author_email", nil,
          method: "GET",
          headers: [{"authorization", "Bearer #{token}"}]
        )

      assert response.status == 200
      assert response.resp_body =~ to_string(author.email)
    end

    test "a star-permission admin over the wire receives it too", %{site: site, user: author} do
      star =
        create_user_with_permissions!(["*"],
          email: "owner@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )

      response =
        make_api_request("#{@tenant_admin}?fields[blogger]=author_email", nil,
          method: "GET",
          headers: [{"authorization", "Bearer #{sign_in(star)}"}]
        )

      assert response.status == 200
      assert response.resp_body =~ to_string(author.email)
    end

    test "the same request without a token does not", %{user: author} do
      response =
        make_api_request("#{@tenant_admin}?fields[blogger]=author_email", nil, method: "GET")

      refute response.resp_body =~ to_string(author.email)
    end
  end

  describe "every include path that ends at an account" do
    # A routed resource may carry includes that end at a User: `comments.author`, `bloggers.user`,
    # `members.user`. The include is kept, so the caller learns WHO; the account itself answers only
    # its owner and admins, so the caller never learns the address, the permissions or the site.
    # Admin-only routes are walked too: a route that is admin-only today can be opened tomorrow
    # without anyone looking at its includes.
    @user MishkaCmsCore.Accounts.User
    @account_fields [:email, :confirmed_at, :site_id, :permission_values]

    # The account holds a site and a permission, so an empty answer for either is it withheld.
    setup %{user: user, site: site} do
      permission = create_permission!(name: "admin:dashboard:blog:comment")

      user =
        user
        |> Ash.Changeset.for_update(:assign_permissions, %{permission_ids: [permission.id]},
          authorize?: false,
          tenant: site.id
        )
        |> Ash.update!()

      {:ok, user: user}
    end

    # A relationship held back carries nothing: no site, no permissions. The fixtures give the account
    # both, so an empty answer here is the account's own being held back.
    defp withheld?(nil), do: true
    defp withheld?([]), do: true
    defp withheld?(%Ash.NotLoaded{}), do: true
    defp withheld?(%Ash.ForbiddenField{}), do: true
    defp withheld?(_loaded), do: false

    defp routed do
      :mishka_blog
      |> Application.fetch_env!(:ash_domains)
      |> Enum.flat_map(&AshJsonApi.Domain.Info.routes/1)
      |> Enum.map(& &1.resource)
      |> Enum.uniq()
    end

    defp account_paths(resource) do
      resource
      |> AshJsonApi.Resource.Info.includes()
      |> List.wrap()
      |> walk(resource, [])
    end

    defp walk(includes, resource, prefix) do
      Enum.flat_map(includes, fn
        {name, nested} ->
          relationship = Ash.Resource.Info.relationship(resource, name)

          hop(relationship, prefix ++ [name], List.wrap(nested)) ++
            walk(List.wrap(nested), relationship.destination, prefix ++ [name])

        name ->
          hop(Ash.Resource.Info.relationship(resource, name), prefix ++ [name], [])
      end)
    end

    defp hop(%{destination: @user} = relationship, path, nested),
      do: [%{relationship: relationship, path: path, beyond: nested}]

    defp hop(_relationship, _path, _nested), do: []

    # Exactly the read an include runs for that last hop: the relationship's own read action, with
    # the context Ash puts on a relationship load — marked as one, and naming where it came from —
    # and the account's site and permissions asked for, as `fields[user]=site,permissions` asks.
    # THE SURFACE A REQUEST CAME FROM: the API sets it on every request, and an area is asked of the
    # surface the read is on.
    defp read_through(relationship, user, actor, tenant \\ :account, surface \\ :dashboard)

    defp read_through(relationship, user, actor, :account, surface),
      do: read_through(relationship, user, actor, user.site_id, surface)

    defp read_through(
           %{source: source, name: name, read_action: read_action},
           user,
           actor,
           tenant,
           surface
         ) do
      @user
      |> Ash.Query.set_context(%{
        private: %{loading_relationships?: true},
        shared: %{admin_surface: surface}
      })
      |> Ash.Query.load([:permission_values, :site, :permissions])
      |> Ash.Query.for_read(read_action || :read, %{}, actor: actor)
      |> Ash.Query.set_context(%{accessing_from: %{source: source, name: name}})
      |> Ash.Query.filter(id == ^user.id)
      |> Ash.read_one(actor: actor, tenant: tenant)
    end

    defp all_paths do
      for resource <- routed(), path <- account_paths(resource), do: {resource, path}
    end

    defp describe_paths(paths) do
      Enum.map_join(paths, "\n", fn {resource, %{path: path}} ->
        "  * #{inspect(resource)}: include=#{Enum.join(path, ".")}"
      end)
    end

    # An include is one way through a relationship; a filter and a sort are others, and they need no
    # include. Every public relationship into an account, routed or not, reads through User's
    # `:related`, where the account's fields answer only its owner and admins, and cannot be sorted
    # through, because Ash checks no field policy on a sort.
    test "every public relationship into an account reads through :related and sorts through nothing" do
      offenders =
        for domain <- Application.fetch_env!(:mishka_blog, :ash_domains),
            resource <- Ash.Domain.Info.resources(domain),
            %{destination: @user, public?: true} = relationship <-
              Ash.Resource.Info.relationships(resource),
            relationship.read_action != :related or relationship.sortable?,
            do: "#{inspect(resource)}.#{relationship.name}"

      assert offenders == [],
             "these reach an account without `read_action :related` and `sortable? false`: " <>
               Enum.join(offenders, ", ")
    end

    test "the walk finds the paths it is meant to guard" do
      found = MapSet.new(all_paths(), fn {resource, %{path: path}} -> {resource, path} end)

      for expected <- [
            {MishkaBlog.BlogPost, [:comments, :author]},
            {MishkaBlog.BlogPost, [:bloggers, :user]},
            {MishkaBlog.Comment, [:author]},
            {MishkaBlog.Team, [:members, :user]}
          ] do
        assert expected in found, "#{inspect(expected)} is no longer found by the walk"
      end
    end

    test "no path goes on past the account to what the account holds" do
      offenders = Enum.filter(all_paths(), fn {_resource, %{beyond: beyond}} -> beyond != [] end)

      assert offenders == [],
             """
             These includes continue past a User into the account's own relationships, such as its
             permissions or its site. Stop the include at the User:

             #{describe_paths(offenders)}
             """
    end

    test "a visitor loading through any of them gets no account field", %{user: user} do
      offenders =
        Enum.reject(all_paths(), fn {_resource, %{relationship: relationship}} ->
          case read_through(relationship, user, nil) do
            {:ok, %{} = seen} ->
              Enum.all?(@account_fields, &match?(%Ash.ForbiddenField{}, Map.get(seen, &1))) and
                withheld?(seen.site) and withheld?(seen.permissions)

            _refused_or_missing ->
              true
          end
        end)

      assert offenders == [],
             """
             A visitor reaching a User through these includes is given the account's email,
             permissions, site or confirmation time, or its site or permission records:

             #{describe_paths(offenders)}

             The fields belong to the account's owner and to admins only; see the field policies on
             MishkaCmsCore.Accounts.User.
             """
    end

    test "a signed-in user who is not an admin gets no one else's account field", %{
      user: user,
      site: site
    } do
      reader = create_user_with_permissions!(["admin:dashboard:blog:post"], site_id: site.id)

      for {resource, %{relationship: relationship, path: path}} <- all_paths() do
        assert {:ok, seen} = read_through(relationship, user, reader)

        for field <- @account_fields do
          assert %Ash.ForbiddenField{} = Map.get(seen, field),
                 "#{inspect(resource)} include=#{Enum.join(path, ".")} gave #{field} to a reader"
        end

        assert withheld?(seen.site)
        assert withheld?(seen.permissions)
      end
    end

    # A master who writes on a site is credited there — a post's blogger, a team's member, a
    # comment's author — and the site's admin, whatever it holds, reaches the account's id and none
    # of its own fields, from the site or from no site at all.
    test "a site's admin gets no master's account field through any of them", %{site: site} do
      master = create_user_with_permissions!(["*"], email: "path.master@example.com")
      admin = create_user_with_permissions!(["*"], site_id: site.id)

      for {resource, %{relationship: relationship, path: path}} <- all_paths(),
          tenant <- [nil, site.id] do
        where =
          "#{inspect(resource)} include=#{Enum.join(path, ".")} under tenant #{inspect(tenant)}"

        case read_through(relationship, master, admin, tenant) do
          {:ok, nil} ->
            assert tenant == site.id, "#{where} lost the account's id"

          {:ok, seen} ->
            for field <- @account_fields do
              assert %Ash.ForbiddenField{} = Map.get(seen, field),
                     "#{where} gave a site's admin the master's #{field}"
            end

            assert withheld?(seen.site), "#{where} gave a site's admin the master's site"
            assert withheld?(seen.permissions), "#{where} gave a site's admin the permissions"
        end
      end
    end

    test "a master reading through them sees another master's whole account", %{site: site} do
      master = create_user_with_permissions!(["*"], email: "path.master@example.com")
      reader = create_user_with_permissions!(["*"], email: "path.reader@example.com")

      for {resource, %{relationship: relationship, path: path}} <- all_paths() do
        assert {:ok, seen} = read_through(relationship, master, reader, nil)

        assert to_string(seen.email) == "path.master@example.com",
               "#{inspect(resource)} include=#{Enum.join(path, ".")} hid it from a master"
      end

      refute site.id == master.site_id
    end

    test "the owner of the account still sees their own through every path", %{user: user} do
      for {resource, %{relationship: relationship, path: path}} <- all_paths() do
        assert {:ok, seen} = read_through(relationship, user, user)

        assert to_string(seen.email) == to_string(user.email),
               "#{inspect(resource)} include=#{Enum.join(path, ".")} hid the owner's own email"
      end
    end

    for {permission, surface} <- [
          {"admin:dashboard:*", :dashboard},
          {"admin:api:*", :api},
          {"*", :dashboard},
          {"*", :api}
        ] do
      test "an admin holding #{permission} still sees the whole account through every path on the #{surface}",
           %{user: user, site: site} do
        admin = create_user_with_permissions!([unquote(permission)], site_id: site.id)

        for {resource, %{relationship: relationship, path: path}} <- all_paths() do
          assert {:ok, seen} = read_through(relationship, user, admin, :account, unquote(surface))
          where = "#{inspect(resource)} include=#{Enum.join(path, ".")}"

          assert to_string(seen.email) == to_string(user.email), "#{where} hid the email"
          assert seen.site_id == user.site_id, "#{where} hid the site"
          assert seen.site.id == user.site_id, "#{where} held back the site record"

          assert seen.permission_values == ["admin:dashboard:blog:comment"],
                 "#{where} hid the permissions"

          assert Enum.map(seen.permissions, & &1.name) == ["admin:dashboard:blog:comment"],
                 "#{where} held back the permission records"
        end
      end
    end

    test "Blogger itself still offers no :user include and keeps its public reads" do
      refute Enum.any?(account_paths(MishkaBlog.Blogger), &(&1.path == [:user]))

      assert Enum.any?(
               Ash.Resource.Info.actions(MishkaBlog.Blogger),
               &String.starts_with?(to_string(&1.name), "public_")
             ),
             "the public reads are the point; keep them"
    end
  end

  describe "every filter or sort a caller sends through an account" do
    # A filter or a sort on a public route may name a field of an account reached through a
    # relationship: `filter[author][email]=...`, `sort=author.email`. Nothing is included, yet the
    # rows that come back — or their order — answer the question, one guess at a time. Each probe
    # below is a pair: the right guess and a wrong one. A visitor and a signed-in user without an
    # admin permission get the same answer for both; an admin's right guess matches.
    @victim_email "victim.secret@example.com"
    @post_route "/api/json/v1/user/mishka-blog/post/published"
    @team_route "/api/json/v1/user/mishka-blog/team"
    @approved "/api/json/v1/user/mishka-blog/comment/approved"
    @followers "/api/json/v1/user/mishka-blog/blogger-follow/followers"
    @admin_comments "/api/json/v1/tenant/admin/mishka-blog/comment"

    setup %{site: site, admin: admin} do
      victim =
        create_user_with_permissions!(["admin:api:*"], email: @victim_email, site_id: site.id)

      post = create_blog_post!(site_id: site.id, status: :published)

      create_comment!(
        site_id: site.id,
        post_id: post.id,
        author_id: victim.id,
        content: "APPROVED-BY-VICTIM",
        status: :approved
      )

      blogger =
        create_blogger!(
          site_id: site.id,
          user_id: victim.id,
          display_name: "Victim Writer",
          slug: "victim-writer",
          status: :active
        )

      first =
        create_user!(email: "aaa.first@example.com", site_id: site.id)
        |> Ash.Changeset.for_update(:update, %{}, authorize?: false, tenant: site.id)
        |> Ash.Changeset.force_change_attribute(:confirmed_at, DateTime.utc_now())
        |> Ash.update!()

      create_comment!(
        site_id: site.id,
        post_id: post.id,
        author_id: first.id,
        content: "APPROVED-BY-FIRST",
        status: :approved
      )

      # Named so that the display names sort the other way round from the addresses.
      first_blogger =
        create_blogger!(
          site_id: site.id,
          user_id: first.id,
          display_name: "Zed First",
          slug: "zed-first",
          status: :active
        )

      team = create_team!(site_id: site.id, status: :active)

      for writer <- [blogger, first_blogger] do
        create_post_blogger!(site_id: site.id, post_id: post.id, blogger_id: writer.id)
        create_team_member!(site_id: site.id, team_id: team.id, blogger_id: writer.id)
      end

      follower = create_user!(email: "quiet.follower@example.com", site_id: site.id)
      create_blogger_follower!(site_id: site.id, blogger_id: blogger.id, actor: follower)

      reader =
        create_user_with_permissions!(["admin:dashboard:blog:post"],
          email: "reader@example.com",
          password: @password,
          password_confirmation: @password,
          site_id: site.id
        )

      refute victim.confirmed_at

      {:ok,
       victim: victim,
       post: post,
       team: team,
       blogger: blogger,
       reader_token: sign_in(reader),
       admin_token: sign_in(admin)}
    end

    # {what is asked, the right guess, a wrong guess}
    defp probes(%{post: post, blogger: blogger, site: site}) do
      comments = "#{@approved}?post_id=#{post.id}&"

      [
        {"a comment author's email", "#{comments}filter[author][email]=#{@victim_email}",
         "#{comments}filter[author][email]=nobody@example.com"},
        {"a comment author's email, a letter at a time",
         "#{comments}filter[author][email][less_than]=victim.t",
         "#{comments}filter[author][email][less_than]=victim.r"},
        {"a comment author's email, in part", "#{comments}filter[author][email][contains]=secret",
         "#{comments}filter[author][email][contains]=nothing-like-it"},
        {"a comment author's site", "#{comments}filter[author][site_id]=#{site.id}",
         "#{comments}filter[author][site_id]=#{Ash.UUID.generate()}"},
        {"a comment author's permissions",
         "#{comments}filter[author][permissions][name]=admin:api:*",
         "#{comments}filter[author][permissions][name]=nope:nope"},
        {"a comment author's site record", "#{comments}filter[author][site][host]=localhost",
         "#{comments}filter[author][site][host]=elsewhere.example.com"},
        {"a blogger's account email", "#{@public}?filter[user][email]=#{@victim_email}",
         "#{@public}?filter[user][email]=nobody@example.com"},
        {"a post's commenter", "#{@post_route}?filter[comments][author][email]=#{@victim_email}",
         "#{@post_route}?filter[comments][author][email]=nobody@example.com"},
        {"a post's blogger", "#{@post_route}?filter[bloggers][user][email]=#{@victim_email}",
         "#{@post_route}?filter[bloggers][user][email]=nobody@example.com"},
        {"a team member", "#{@team_route}?filter[members][user][email]=#{@victim_email}",
         "#{@team_route}?filter[members][user][email]=nobody@example.com"},
        {"a follower who never wrote anything",
         "#{@followers}?blogger_id=#{blogger.id}&filter[follower_user][email]=quiet.follower@example.com",
         "#{@followers}?blogger_id=#{blogger.id}&filter[follower_user][email]=nobody@example.com"}
      ]
    end

    defp answer(url, token) do
      headers = if token, do: [{"authorization", "Bearer #{token}"}], else: []
      response = make_api_request(url, nil, method: "GET", headers: headers)

      ids =
        case Jason.decode(response.resp_body) do
          {:ok, %{"data" => data}} -> data |> List.wrap() |> Enum.map(& &1["id"]) |> Enum.sort()
          _other -> nil
        end

      {response.status, ids}
    end

    for {who, token_key} <- [
          {"a visitor", nil},
          {"a signed-in user without an admin permission", :reader_token}
        ] do
      test "#{who} gets the same answer for the right guess and a wrong one", context do
        token = unquote(token_key) && context[unquote(token_key)]

        offenders =
          for {asked, hit, miss} <- probes(context),
              answer(hit, token) != answer(miss, token),
              do: asked

        assert offenders == [], "#{unquote(who)} can tell #{Enum.join(offenders, ", ")}"
      end
    end

    # A withheld field reads as nil, so `is_nil` holds of every account alike: the victim never
    # confirmed, the other commenter did, and the filter cannot tell them apart.
    for {who, token_key} <- [
          {"a visitor", nil},
          {"a signed-in user without an admin permission", :reader_token}
        ] do
      test "#{who} cannot tell a commenter who confirmed from one who did not", context do
        token = unquote(token_key) && context[unquote(token_key)]
        route = "#{@approved}?post_id=#{context.post.id}&filter[author][confirmed_at][is_nil]="

        {200, everyone} =
          answer(String.trim_trailing(route, "&filter[author][confirmed_at][is_nil]="), token)

        for is_nil? <- ["true", "false"] do
          assert {200, ids} = answer(route <> is_nil?, token)
          assert ids in [[], everyone], "is_nil=#{is_nil?} picked out #{inspect(ids)}"
        end
      end
    end

    test "an admin's right guess matches, so the probes above ask what they claim", %{
      admin_token: token,
      site: site
    } do
      for filter <- [
            "filter[author][email]=#{@victim_email}",
            "filter[author][email][contains]=secret",
            "filter[author][site_id]=#{site.id}",
            "filter[author][confirmed_at][is_nil]=true"
          ] do
        assert {200, [_ | _]} = answer("#{@admin_comments}?#{filter}", token), filter
      end

      assert {200, []} =
               answer("#{@admin_comments}?filter[author][email]=nobody@example.com", token)

      assert {200, []} =
               answer("#{@admin_comments}?filter[author][site_id]=#{Ash.UUID.generate()}", token)
    end

    # The victim and a writer whose address sorts first: their comments, their post bylines and their
    # team places sorted on the account's address would come back in the order of the addresses.
    # JSON:API refuses a top-level sort through a relationship; `sort_included` sorts an included
    # relationship with whatever it is given, and Ash checks no field policy on a sort through a
    # relationship, so the relationship itself refuses to be sorted through.
    defp sorted_includes(%{post: post, team: team}, token) do
      headers = if token, do: [{"authorization", "Bearer #{token}"}], else: []

      for {route, include, sort} <- [
            {"#{@post_route}/#{post.id}", "comments", "author.email"},
            {"#{@post_route}/#{post.id}", "bloggers", "user.email"},
            {"#{@team_route}/#{team.id}", "members", "user.email"}
          ],
          direction <- ["", "-"] do
        response =
          make_api_request(
            "#{route}?include=#{include}&sort_included[#{include}]=#{direction}#{sort}",
            nil,
            method: "GET",
            headers: headers
          )

        ids =
          case Jason.decode(response.resp_body) do
            {:ok, %{"data" => %{"relationships" => %{^include => %{"data" => data}}}}} ->
              Enum.map(data, & &1["id"])

            _refused ->
              nil
          end

        {include, direction, response.status, ids}
      end
    end

    defp same_order_both_ways?(answers) do
      answers
      |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(Tuple.delete_at(&1, 0), 0))
      |> Enum.all?(fn {_include, [ascending, descending]} -> ascending == descending end)
    end

    test "a visitor learns nothing from sorting what a route includes on an account's address",
         context do
      answers = sorted_includes(context, nil)
      assert same_order_both_ways?(answers), inspect(answers)
    end

    test "a refused sort says so in plain words", %{post: post} do
      response =
        make_api_request(
          "#{@post_route}/#{post.id}?include=comments&sort_included[comments]=author.email",
          nil,
          method: "GET"
        )

      assert response.status == 400

      assert [%{"code" => "invalid_sort", "detail" => "The results cannot be sorted by author."}] =
               Jason.decode!(response.resp_body)["errors"]
    end

    test "a signed-in user without an admin permission learns nothing from it either", context do
      answers = sorted_includes(context, context.reader_token)
      assert same_order_both_ways?(answers), inspect(answers)
    end

    # The victim and a commenter whose address sorts first: their comments sorted on the author's
    # address would come back in the order of the addresses. JSON:API refuses a sort through a
    # relationship today; if it ever takes one, the order still says nothing.
    defp commenters_sorted(%{post: post}, sort, token) do
      headers = if token, do: [{"authorization", "Bearer #{token}"}], else: []

      response =
        make_api_request("#{@approved}?post_id=#{post.id}&sort=#{sort}", nil,
          method: "GET",
          headers: headers
        )

      {response.status,
       response.resp_body
       |> Jason.decode!()
       |> Map.get("data", [])
       |> List.wrap()
       |> Enum.map(& &1["attributes"]["content"])}
    end

    test "a visitor learns nothing from sorting on a comment author's address", context do
      assert commenters_sorted(context, "author.email", nil) ==
               commenters_sorted(context, "-author.email", nil)
    end

    test "a signed-in user without an admin permission learns nothing from that sort either",
         context do
      assert commenters_sorted(context, "author.email", context.reader_token) ==
               commenters_sorted(context, "-author.email", context.reader_token)
    end
  end
end
