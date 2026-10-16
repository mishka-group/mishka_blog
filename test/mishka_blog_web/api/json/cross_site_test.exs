# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Api.Json.CrossSiteTest do
  @moduledoc """
  A bookmark, a rating, a vote and a follow made on one site may only name a record of that site.

  A user of site A, signed in on site A's host, names site B's post, comment, blogger and team: each
  write is refused the way a missing record is, and nothing is written, while the same write naming
  site A's own record goes through. Without a site at all, only a master names any site's record. A
  blogger's followers are listed only on the blogger's own site. A request without a site is made on
  the master site's address, the only one that takes `x-no-tenant`.

  One file rather than a test in each resource's own, because all five share this two-site setup.
  `async: false` — `SiteState` and the event registry are process-global.
  """
  use MishkaBlog.ConnCase, async: false
  import MishkaBlog.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  if Code.ensure_loaded?(MishkaBlog) do
    alias MishkaBlog.{BloggerFollower, CommentVote, PostBookmark, PostRating, TeamFollower}
    alias MishkaBlog.Test.Plugins.TenantCrossSiteRefused
    alias MishkaCmsCore.Runtime.States.SiteState
    alias MishkaInstaller.Event.{Event, EventHandler}

    @password "Password123!"
    @api "/api/json/v1/user/mishka-blog"
    @no_tenant [{"x-no-tenant", "true"}]

    setup do
      SiteState.clear()
      :ok = Swoosh.TestAssertions.set_swoosh_global()
      Application.put_env(:ash_json_api, MishkaBlog, router: MishkaBlog.TestRouter)

      site_a = create_site!(name: "site-a", host: "a.localhost", active: true)
      site_b = create_site!(name: "site-b", host: "b.localhost", active: true)

      master_site =
        create_site!(name: "master", host: "master.localhost", active: true, master: true)

      Enum.each([site_a, site_b, master_site], &cache_site/1)
      on_exit(fn -> SiteState.clear() end)

      user =
        create_user!(
          email: "reader@site-a.test",
          password: @password,
          password_confirmation: @password,
          site_id: site_a.id
        )

      {:ok,
       site_a: site_a,
       site_b: site_b,
       master_site: master_site,
       user: user,
       token: sign_in(user, site_a.host)}
    end

    defp cache_site(site) do
      SiteState.save(%{
        id: site.id,
        name: site.name,
        host: site.host,
        priority: site.priority,
        active: site.active,
        master: site.master
      })
    end

    defp sign_in(user, host, headers \\ []) do
      response =
        make_api_request(
          "/api/json/v1/auth/user/sign-in",
          %{
            "type" => "user",
            "attributes" => %{"email" => to_string(user.email), "password" => @password}
          },
          host: host,
          headers: headers
        )

      assert response.status == 201
      Jason.decode!(response.resp_body)["meta"]["token"]
    end

    defp write(ctx, route, type, attributes, headers \\ []) do
      make_api_request(
        "#{@api}/#{route}",
        %{"type" => type, "attributes" => attributes},
        headers: [{"authorization", "Bearer #{ctx.token}"} | headers],
        host: Map.get(ctx, :host, ctx.site_a.host)
      )
    end

    defp global_user!(permissions, email) do
      create_user_with_permissions!(permissions,
        email: email,
        password: @password,
        password_confirmation: @password
      )
    end

    defp site_b_writes(ctx) do
      post = create_blog_post!(site_id: ctx.site_b.id, status: :published)
      comment = create_comment!(site_id: ctx.site_b.id)

      [
        {"bookmark", "post_bookmark", %{"post_id" => post.id}},
        {"post-rating", "post_rating", %{"post_id" => post.id, "rating" => 5}},
        {"comment-vote", "comment_vote", %{"comment_id" => comment.id, "vote_type" => "up"}},
        {"blogger-follow", "blogger_follower",
         %{"blogger_id" => create_blogger!(site_id: ctx.site_b.id).id}},
        {"team-follow", "team_follower", %{"team_id" => create_team!(site_id: ctx.site_b.id).id}}
      ]
    end

    defp written_rows do
      Enum.flat_map(
        [PostBookmark, PostRating, CommentVote, BloggerFollower, TeamFollower],
        &Ash.read!(&1, authorize?: false)
      )
    end

    defp listen_for_refusals do
      Process.register(self(), :__blog_hook_probe__)

      {:ok, _} =
        Event.write(%{
          name: TenantCrossSiteRefused,
          event: "runtime:tenant:cross_site_refused",
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile("runtime:tenant:cross_site_refused", :start, false)
      on_exit(fn -> Event.unregister(:name, TenantCrossSiteRefused, false) end)
    end

    defp written(resource, field),
      do: resource |> Ash.read!(authorize?: false) |> Enum.map(&Map.fetch!(&1, field))

    defp errors(response) do
      response.resp_body
      |> Jason.decode!()
      |> Map.fetch!("errors")
      |> Enum.map(&Map.take(&1, ["code", "detail", "source", "status", "title"]))
    end

    defp followers(blogger, host, headers \\ []) do
      "#{@api}/blogger-follow/followers?blogger_id=#{blogger.id}"
      |> make_api_request(%{}, method: "GET", host: host, headers: headers)
      |> Map.fetch!(:resp_body)
      |> Jason.decode!()
      |> Map.fetch!("data")
      |> Enum.map(& &1["id"])
    end

    test "a bookmark names only a post of its own site", ctx do
      own = create_blog_post!(site_id: ctx.site_a.id, status: :published)
      other = create_blog_post!(site_id: ctx.site_b.id, status: :published)

      assert write(ctx, "bookmark", "post_bookmark", %{"post_id" => other.id}).status == 400
      assert write(ctx, "bookmark", "post_bookmark", %{"post_id" => own.id}).status == 201
      assert written(PostBookmark, :post_id) == [own.id]
    end

    test "a rating names only a post of its own site", ctx do
      own = create_blog_post!(site_id: ctx.site_a.id, status: :published)
      other = create_blog_post!(site_id: ctx.site_b.id, status: :published)

      rate = &write(ctx, "post-rating", "post_rating", %{"post_id" => &1.id, "rating" => 5})

      assert rate.(other).status == 400
      assert rate.(own).status == 201
      assert written(PostRating, :post_id) == [own.id]
    end

    test "a vote names only a comment of its own site", ctx do
      own = create_comment!(site_id: ctx.site_a.id)
      other = create_comment!(site_id: ctx.site_b.id)

      vote =
        &write(ctx, "comment-vote", "comment_vote", %{"comment_id" => &1.id, "vote_type" => "up"})

      assert vote.(other).status == 400
      assert vote.(own).status == 201
      assert written(CommentVote, :comment_id) == [own.id]
    end

    test "a vote an admin casts for a user names only a comment of the admin's site", ctx do
      admin =
        create_user_with_permissions!(["admin:dashboard:blog:comment"], site_id: ctx.site_a.id)

      own = create_comment!(site_id: ctx.site_a.id)
      other = create_comment!(site_id: ctx.site_b.id)

      vote_for = fn comment ->
        CommentVote
        |> Ash.Changeset.for_create(
          :create_for_user,
          %{comment_id: comment.id, user_id: ctx.user.id, vote_type: :up},
          actor: admin,
          tenant: ctx.site_a.id
        )
        |> Ash.create()
      end

      assert {:error, %Ash.Error.Invalid{}} = vote_for.(other)
      assert {:ok, _vote} = vote_for.(own)
      assert written(CommentVote, :comment_id) == [own.id]
    end

    test "a vote an admin casts for a user names only a user of the admin's site", ctx do
      admin =
        create_user_with_permissions!(["admin:dashboard:blog:comment"], site_id: ctx.site_a.id)

      comment = create_comment!(site_id: ctx.site_a.id)
      elsewhere = create_user!(site_id: ctx.site_b.id)

      vote_for = fn user ->
        CommentVote
        |> Ash.Changeset.for_create(
          :create_for_user,
          %{comment_id: comment.id, user_id: user.id, vote_type: :up},
          actor: admin,
          tenant: ctx.site_a.id
        )
        |> Ash.create()
      end

      assert {:error, %Ash.Error.Invalid{}} = vote_for.(elsewhere)
      assert written(CommentVote, :user_id) == []
      assert {:ok, _vote} = vote_for.(ctx.user)
      assert written(CommentVote, :user_id) == [ctx.user.id]
    end

    test "a follow names only a blogger of its own site", ctx do
      own = create_blogger!(site_id: ctx.site_a.id)
      other = create_blogger!(site_id: ctx.site_b.id)

      follow = &write(ctx, "blogger-follow", "blogger_follower", %{"blogger_id" => &1.id})

      assert follow.(other).status == 400
      assert follow.(own).status == 201
      assert written(BloggerFollower, :blogger_id) == [own.id]
    end

    test "a follow names only a team of its own site", ctx do
      own = create_team!(site_id: ctx.site_a.id)
      other = create_team!(site_id: ctx.site_b.id)

      assert write(ctx, "team-follow", "team_follower", %{"team_id" => other.id}).status == 400
      assert write(ctx, "team-follow", "team_follower", %{"team_id" => own.id}).status == 201
      assert written(TeamFollower, :team_id) == [own.id]
    end

    test "a site's user who names another site as the tenant names none of its records", ctx do
      listen_for_refusals()
      other = create_blog_post!(site_id: ctx.site_b.id, status: :published)

      assert {:error, %Ash.Error.Invalid{}} =
               PostBookmark
               |> Ash.Changeset.for_create(:create, %{post_id: other.id},
                 actor: ctx.user,
                 tenant: ctx.site_b.id
               )
               |> Ash.create()

      assert_receive {:cross_site_refused, %{tenant: tenant, actor_id: actor_id}}
      assert {tenant, actor_id} == {ctx.site_b.id, ctx.user.id}
      assert written(PostBookmark, :post_id) == []
    end

    test "another site's record is refused exactly as one that does not exist", ctx do
      other = create_blog_post!(site_id: ctx.site_b.id, status: :published)

      elsewhere = write(ctx, "bookmark", "post_bookmark", %{"post_id" => other.id})
      missing = write(ctx, "bookmark", "post_bookmark", %{"post_id" => Ecto.UUID.generate()})

      assert elsewhere.status == missing.status
      assert errors(elsewhere) == errors(missing)
    end

    test "without a site, only a master names another site's record", ctx do
      listen_for_refusals()
      global = global_user!([], "global@nowhere.test")
      master = global_user!(["admin:api:*"], "master@nowhere.test")
      host = ctx.master_site.host
      as_global = Map.merge(ctx, %{token: sign_in(global, host, @no_tenant), host: host})
      as_master = Map.merge(ctx, %{token: sign_in(master, host, @no_tenant), host: host})

      for {route, type, attributes} <- site_b_writes(ctx) do
        assert write(as_global, route, type, attributes, @no_tenant).status == 400
        assert_receive {:cross_site_refused, %{tenant: nil, actor_id: actor_id}}
        assert actor_id == global.id
        assert write(as_master, route, type, attributes, @no_tenant).status == 201
      end

      assert length(written_rows()) == 5
    end

    test "a blogger's followers are listed only on the blogger's own site", ctx do
      blogger = create_blogger!(site_id: ctx.site_b.id)
      follow = create_blogger_follower!(blogger_id: blogger.id)

      assert followers(blogger, ctx.site_b.host) == [follow.id]
      assert followers(blogger, ctx.site_a.host) == []
      assert followers(blogger, ctx.master_site.host, [{"x-no-tenant", "true"}]) == []
      assert followers(blogger, ctx.site_b.host, [{"x-no-tenant", "true"}]) == [follow.id]
    end

    test "a refused write is announced on runtime:tenant:cross_site_refused", ctx do
      listen_for_refusals()
      other = create_blogger!(site_id: ctx.site_b.id)
      write(ctx, "blogger-follow", "blogger_follower", %{"blogger_id" => other.id})

      assert_receive {:cross_site_refused, refused}

      assert refused == %{
               resource: BloggerFollower,
               field: :blogger_id,
               id: other.id,
               tenant: ctx.site_a.id,
               actor_id: ctx.user.id
             }
    end
  end
end
