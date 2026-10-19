# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlogWeb.Api.Json.LockedRecordsTest do
  @moduledoc """
  The public JSON API keeps a locked post, category or tag, and the comments of a locked post, to
  whoever its page opens for (`MishkaBlog.Resources.Preparations.OpenToActor`): a list leaves out
  what its caller may not open, and asking for one of them is answered as an id nothing is stored
  at is: a 404 `not_found`, never a 403. A locked post
  takes a comment, a rating or a bookmark, and its comments a vote, from no one else
  (`MishkaBlog.Resources.Validations.OpenToActor`). A post opens
  with its own permissions, else its categories'; a category with its own, else its nearest parent
  category's; a tag with its own.

  members (locked) → guides (names nothing); open names nothing.
  """
  use MishkaBlog.ConnCase
  import MishkaBlog.Test.Factory

  @moduletag :unit
  @moduletag :capture_log

  @password "Password123!"
  @posts "/api/json/v1/user/mishka-blog/post/published"
  @categories "/api/json/v1/user/mishka-blog/collection/active"
  @tags "/api/json/v1/user/mishka-blog/tag"
  @comments "/api/json/v1/user/mishka-blog/comment"

  setup do
    MishkaCmsCore.Runtime.States.SiteState.clear()
    Application.put_env(:ash_json_api, MishkaBlog, router: MishkaBlog.TestRouter)

    site = create_site!(name: "localhost", host: "localhost", active: true, master: true)

    MishkaCmsCore.Runtime.States.SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    on_exit(fn -> MishkaCmsCore.Runtime.States.SiteState.clear() end)

    members = category!(site, ["members:read"])
    guides = category!(site, [], parent_collection_id: members.id)
    open = category!(site, [])

    posts = %{
      open: post!(site, [], [open]),
      own: post!(site, ["members:read"], []),
      in_members: post!(site, [], [members]),
      in_guides: post!(site, [], [guides]),
      own_wins: post!(site, ["staff:read"], [members])
    }

    %{
      site: site,
      members: members,
      guides: guides,
      open: open,
      posts: posts,
      member: token(site, "member@example.com", ["members:read"]),
      nobody: token(site, "nobody@example.com", [])
    }
  end

  describe "posts" do
    test "the list leaves out each post its caller may not open", %{posts: posts} = ctx do
      assert ids(fetch(@posts, nil)) == ids_of([posts.open])
      assert ids(fetch(@posts, ctx.nobody)) == ids_of([posts.open])

      assert ids(fetch(@posts, ctx.member)) ==
               ids_of([posts.open, posts.own, posts.in_members, posts.in_guides])
    end

    test "one post by itself is not found to whoever may not open it", %{posts: posts} = ctx do
      for post <- [posts.own, posts.in_members, posts.in_guides, posts.own_wins] do
        assert_not_found(@posts, post.id, nil)
        assert_not_found(@posts, post.id, ctx.nobody)
      end

      assert fetch("#{@posts}/#{posts.in_guides.id}", ctx.member).status == 200
      assert_not_found(@posts, posts.own_wins.id, ctx.member)
      assert fetch("#{@posts}/#{posts.open.id}", nil).status == 200
    end
  end

  describe "categories and tags" do
    test "a locked category, and one under it, are left out and not found alone", ctx do
      assert ids(fetch(@categories, nil)) == ids_of([ctx.open])
      assert ids(fetch(@categories, ctx.member)) == ids_of([ctx.members, ctx.guides, ctx.open])

      assert_not_found(@categories, ctx.guides.id, nil)
      assert fetch("#{@categories}/#{ctx.guides.id}", ctx.member).status == 200
    end

    test "a locked tag is left out and not found alone, and locks no post", %{site: site} = ctx do
      locked = create_blog_tag!(site_id: site.id, language: "en", permissions: ["members:read"])
      open = create_blog_tag!(site_id: site.id, language: "en")
      create_post_tag!(post_id: ctx.posts.open.id, tag_id: locked.id)

      assert ids(fetch(@tags, nil)) == ids_of([open])
      assert_not_found(@tags, locked.id, nil)
      assert fetch("#{@tags}/#{locked.id}", ctx.member).status == 200
      assert fetch("#{@posts}/#{ctx.posts.open.id}", nil).status == 200
    end
  end

  describe "a category's and a tag's post count" do
    test "is of the posts its caller may open, in the list, alone and sorted by", ctx do
      tag = create_blog_tag!(site_id: ctx.site.id, language: "en")
      for post <- Map.values(ctx.posts), do: create_post_tag!(post_id: post.id, tag_id: tag.id)
      fields = "fields[tag]=name,published_post_count"

      assert counts(fetch("#{@tags}?#{fields}", nil)) == %{tag.id => 1}
      assert counts(fetch("#{@tags}?#{fields}", ctx.nobody)) == %{tag.id => 1}
      assert counts(fetch("#{@tags}?#{fields}", ctx.member)) == %{tag.id => 4}

      assert counts(fetch("#{@tags}?#{fields}&sort=-published_post_count", ctx.member)) ==
               %{tag.id => 4}

      assert count(fetch("#{@tags}/#{tag.id}?#{fields}", nil)) == 1
      assert count(fetch("#{@tags}/#{tag.id}?#{fields}", ctx.member)) == 4

      fields = "fields[collection]=name,published_post_count"
      assert counts(fetch("#{@categories}?#{fields}", nil)) == %{ctx.open.id => 1}

      assert counts(fetch("#{@categories}?#{fields}", ctx.member)) ==
               %{ctx.members.id => 1, ctx.guides.id => 1, ctx.open.id => 1}
    end

    test "cannot be filtered by, which would count past what the caller is shown", ctx do
      tag = create_blog_tag!(site_id: ctx.site.id, language: "en")
      create_post_tag!(post_id: ctx.posts.own.id, tag_id: tag.id)

      assert fetch("#{@tags}?filter[published_post_count][gt]=0", nil).status == 400
    end
  end

  describe "comments" do
    test "a locked post's approved comments reach only whoever may open it",
         %{site: site} = ctx do
      post = ctx.posts.in_members
      comment = create_comment!(site_id: site.id, post_id: post.id, status: :approved)

      assert ids(fetch("#{@comments}/approved?post_id=#{post.id}", nil)) == []
      assert ids(fetch("#{@comments}/approved?post_id=#{post.id}", ctx.nobody)) == []
      assert ids(fetch("#{@comments}/approved?post_id=#{post.id}", ctx.member)) == [comment.id]
    end

    test "a comment of a locked post takes a vote only from whoever may open the post",
         %{site: site} = ctx do
      locked =
        create_comment!(site_id: site.id, post_id: ctx.posts.in_members.id, status: :approved)

      open = create_comment!(site_id: site.id, post_id: ctx.posts.open.id, status: :approved)

      vote = fn comment, token ->
        make_api_request(
          "#{@comments}-vote",
          %{
            "type" => "comment_vote",
            "attributes" => %{"comment_id" => comment.id, "vote_type" => "up"}
          },
          method: :post,
          headers: bearer(token)
        )
      end

      refused = vote.(locked, ctx.nobody)
      assert refused.status == 400

      assert [%{"detail" => "Comment not found or does not belong to your site."}] =
               Jason.decode!(refused.resp_body)["errors"]

      assert vote.(locked, ctx.member).status == 201
      assert vote.(open, ctx.nobody).status == 201
    end

    test "a locked post takes a comment only from whoever may open it", ctx do
      post = ctx.posts.in_members

      assert comment(post, ctx.nobody).status == 400
      assert comment(post, ctx.member).status == 201
      assert comment(ctx.posts.open, ctx.nobody).status == 201
    end
  end

  describe "ratings and bookmarks" do
    test "a locked post takes a rating or a bookmark only from whoever may open it", ctx do
      post = ctx.posts.in_members

      for {path, type, attributes} <- [
            {"/api/json/v1/user/mishka-blog/post-rating", "post_rating", %{"rating" => 5}},
            {"/api/json/v1/user/mishka-blog/bookmark", "post_bookmark", %{}}
          ] do
        write = fn post, token ->
          make_api_request(
            path,
            %{"type" => type, "attributes" => Map.put(attributes, "post_id", post.id)},
            method: :post,
            headers: bearer(token)
          )
        end

        refused = write.(post, ctx.nobody)
        assert refused.status == 400

        assert [%{"detail" => "Post not found or does not belong to your site."}] =
                 Jason.decode!(refused.resp_body)["errors"]

        assert write.(post, ctx.member).status == 201
        assert write.(ctx.posts.open, ctx.nobody).status == 201
      end
    end
  end

  # A request no site is chosen for — `x-no-tenant`, a master's switch — is told it needs one.
  describe "a request with no site" do
    test "is told the route needs one, on the list, the item, the tag and the comments", ctx do
      for path <- [
            @posts,
            "#{@posts}/#{ctx.posts.open.id}",
            @tags,
            "#{@comments}/approved?post_id=#{ctx.posts.open.id}"
          ] do
        response = make_api_request(path, %{}, method: :get, headers: [{"x-no-tenant", "true"}])

        assert response.status == 400, path
        assert [%{"code" => "tenant_required"}] = Jason.decode!(response.resp_body)["errors"]
      end
    end
  end

  defp category!(site, permissions, overrides \\ []) do
    create_collection!(
      [site_id: site.id, status: :active, language: "en", permissions: permissions] ++ overrides
    )
  end

  defp post!(site, permissions, categories) do
    post =
      create_blog_post!(
        site_id: site.id,
        status: :published,
        language: "en",
        permissions: permissions
      )

    for category <- categories,
        do: create_post_collection!(post_id: post.id, collection_id: category.id)

    post
  end

  # A user of `site` holding `permissions`, signed in to the API: its bearer token.
  defp token(site, email, permissions) do
    create_user_with_permissions!(permissions,
      site_id: site.id,
      email: email,
      password: @password,
      password_confirmation: @password
    )

    response =
      make_api_request("/api/json/v1/auth/user/sign-in", %{
        "type" => "user",
        "attributes" => %{"email" => email, "password" => @password}
      })

    assert response.status == 201
    Jason.decode!(response.resp_body)["meta"]["token"]
  end

  defp fetch(path, token), do: make_api_request(path, %{}, method: :get, headers: bearer(token))

  # A record the reader may not open answers what an id nothing is stored at answers: a 404
  # `not_found`, with nothing to tell the two apart.
  defp assert_not_found(collection, id, token) do
    refused = fetch("#{collection}/#{id}", token)
    missing = fetch("#{collection}/#{Ash.UUID.generate()}", token)

    assert error_of(refused) == error_of(missing)
    assert error_of(refused)["code"] == "not_found"
  end

  defp error_of(%{status: 404, resp_body: body}) do
    assert [error] = Jason.decode!(body)["errors"]
    Map.take(error, ["status", "code", "title"])
  end

  defp comment(post, token) do
    make_api_request(
      "#{@comments}/create",
      %{"type" => "comment", "attributes" => %{"content" => "Hello", "post_id" => post.id}},
      method: :post,
      headers: bearer(token)
    )
  end

  defp counts(%{status: 200, resp_body: body}) do
    body
    |> Jason.decode!()
    |> Map.fetch!("data")
    |> Map.new(&{&1["id"], &1["attributes"]["published_post_count"]})
  end

  defp count(%{status: 200, resp_body: body}),
    do: Jason.decode!(body)["data"]["attributes"]["published_post_count"]

  defp bearer(nil), do: []
  defp bearer(token), do: [{"authorization", "Bearer #{token}"}]

  defp ids(%{status: 200, resp_body: body}),
    do: body |> Jason.decode!() |> Map.fetch!("data") |> Enum.map(& &1["id"]) |> Enum.sort()

  defp ids_of(records), do: records |> Enum.map(& &1.id) |> Enum.sort()
end
