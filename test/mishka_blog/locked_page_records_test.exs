# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.LockedPageRecordsTest do
  @moduledoc """
  A record whose page is locked is not listed for a reader who may not open that page
  (`MishkaBlog.Resources.Preparations.OpenToActor`): the page that shows posts, `/blog/:slug`, names
  permissions, and a guest and a user without them are shown no post in a list, in a count or in a
  comment — the user who holds them is shown all of them.

  The pages are the site's `pages` rows, and the check is part of the statement that reads the
  records: a locked page adds no read, and the JSON:API is asked of it as a page of the site is.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.{Blogger, BlogPost, Collection, Comment, Tag, Team}
  alias MishkaBlog.Plugins.SitemapUrls

  require Ash.Query

  @members ["members:read"]
  @page [limit: 50, count: true]

  setup do
    site = create_site!(active: true)

    %{
      site: site,
      member: create_user_with_permissions!(@members, site_id: site.id),
      reader: create_user_with_permissions!([], site_id: site.id)
    }
  end

  defp page!(site, path, record, permissions, overrides \\ []) do
    create_page!(
      [
        site_id: site.id,
        path: path,
        extra: %{"record" => record},
        permissions: permissions
      ] ++ overrides
    )
  end

  defp post!(site, overrides \\ []) do
    [site_id: site.id, status: :published, language: "en", permissions: []]
    |> Keyword.merge(overrides)
    |> create_blog_post!()
  end

  defp read(resource, action, site, actor, args \\ %{}) do
    resource
    |> Ash.Query.for_read(action, args, actor: actor, tenant: site.id)
    |> Ash.read!(page: @page)
    |> Map.fetch!(:results)
  end

  defp ids(rows), do: rows |> Enum.map(& &1.id) |> Enum.sort()

  defp asked(fun), do: fun |> queries_while() |> length()

  describe "the page that shows posts is locked" do
    setup %{site: site} = ctx do
      first = post!(site)
      second = post!(site)
      page!(site, "/blog/:slug", "blog:post", @members)
      Map.put(ctx, :posts, ids([first, second]))
    end

    test "no post is listed for a guest or a user without the permission", ctx do
      %{site: site, reader: reader} = ctx

      for actor <- [nil, reader] do
        assert read(BlogPost, :public_list, site, actor) == []
      end
    end

    test "every post is listed for the user who holds the permission", ctx do
      %{site: site, member: member, posts: posts} = ctx
      assert ids(read(BlogPost, :public_list, site, member)) == posts
    end

    test "a count and the pages are of what the reader is shown", ctx do
      %{site: site, member: member, posts: posts} = ctx

      query = fn actor ->
        BlogPost |> Ash.Query.for_read(:public_list, %{}, actor: actor, tenant: site.id)
      end

      assert %{count: 0, results: []} = Ash.read!(query.(nil), page: @page)
      assert %{count: 2} = Ash.read!(query.(member), page: @page)
      assert ids(Ash.read!(query.(member), page: @page).results) == posts
    end

    test "a post asked for alone is not found for a guest, and found for the member", ctx do
      %{site: site, member: member, posts: [id | _]} = ctx

      get = fn actor ->
        BlogPost
        |> Ash.Query.for_read(:public_get, %{}, actor: actor, tenant: site.id)
        |> Ash.Query.filter(id == ^id)
        |> Ash.read_one()
      end

      assert {:ok, nil} = get.(nil)
      assert {:ok, %BlogPost{id: ^id}} = get.(member)
    end

    test "the API is asked of the page as the site is", ctx do
      %{site: site, member: member, reader: reader, posts: posts} = ctx

      api = fn actor ->
        BlogPost
        |> Ash.Query.for_read(:public_list, %{},
          actor: actor,
          tenant: site.id,
          context: %{shared: %{admin_surface: :api}}
        )
        |> Ash.read!(page: @page)
        |> Map.fetch!(:results)
        |> ids()
      end

      assert api.(nil) == []
      assert api.(reader) == []
      assert api.(member) == posts
    end

    test "the system is not asked", ctx do
      %{site: site, posts: posts} = ctx

      system =
        BlogPost
        |> Ash.Query.for_read(:public_list, %{}, authorize?: false, tenant: site.id)
        |> Ash.read!(page: @page)

      assert ids(system.results) == posts
    end

    test "a comment of a post is not listed either", ctx do
      %{site: site, member: member} = ctx
      post = post!(site)
      create_comment!(site_id: site.id, post_id: post.id, status: :approved)

      comments = fn actor ->
        read(Comment, :approved_by_post, site, actor, %{post_id: post.id})
      end

      assert comments.(nil) == []
      assert length(comments.(member)) == 1
    end

    test "the posts a category or a tag counts are the ones the reader is shown", ctx do
      %{site: site, member: member, posts: posts} = ctx
      category = create_collection!(site_id: site.id, status: :active, permissions: [])
      tag = create_blog_tag!(site_id: site.id, language: "en", permissions: [])

      for id <- posts do
        create_post_collection!(post_id: id, collection_id: category.id)
        create_post_tag!(post_id: id, tag_id: tag.id)
      end

      counted = fn resource, actor ->
        resource
        |> Ash.Query.for_read(:public_list, %{}, actor: actor, tenant: site.id)
        |> Ash.Query.load(:published_post_count)
        |> Ash.read!(page: @page)
        |> Map.fetch!(:results)
        |> Enum.map(& &1.published_post_count)
      end

      assert counted.(Collection, nil) == [0]
      assert counted.(Collection, member) == [2]
      assert counted.(Tag, nil) == [0]
      assert counted.(Tag, member) == [2]
    end

    test "the sitemap lists none of them for the guest it reads as", ctx do
      %{site: site} = ctx
      pages = [%{path: "/blog/:slug", language: nil, extra: %{"record" => "blog:post"}}]

      {:reply, %{urls: urls}} =
        SitemapUrls.call(%{site: %{id: site.id}, pages: pages, urls: []})

      assert Enum.to_list(urls) == []
    end
  end

  describe "a page that shows another kind of record is locked" do
    test "a category, a tag, a blogger and a team are each left out by their own page", ctx do
      %{site: site, member: member} = ctx
      post!(site)
      create_collection!(site_id: site.id, status: :active, permissions: [])
      create_blog_tag!(site_id: site.id, language: "en", permissions: [])
      create_blogger!(site_id: site.id)
      create_team!(site_id: site.id, status: :active)

      for {path, record} <- [
            {"/blog/category/:slug", "blog:category"},
            {"/blog/tag/:slug", "blog:tag"},
            {"/blog/author/:slug", "blog:author"},
            {"/blog/team/:slug", "blog:team"}
          ] do
        page!(site, path, record, @members)
      end

      assert length(read(BlogPost, :public_list, site, nil)) == 1

      for resource <- [Collection, Tag, Blogger, Team] do
        assert read(resource, :public_list, site, nil) == [], "#{inspect(resource)} for a guest"

        assert length(read(resource, :public_list, site, member)) == 1,
               "#{inspect(resource)} for a member"
      end
    end
  end

  describe "nothing is locked" do
    test "a page that shows posts and names no permission hides nothing", ctx do
      %{site: site, reader: reader} = ctx
      posts = ids([post!(site), post!(site)])
      page!(site, "/blog/:slug", "blog:post", [])

      for actor <- [nil, reader] do
        assert ids(read(BlogPost, :public_list, site, actor)) == posts
      end
    end

    test "no page at all hides nothing", ctx do
      %{site: site} = ctx
      posts = ids([post!(site)])
      assert ids(read(BlogPost, :public_list, site, nil)) == posts
    end

    test "one page open to the reader among the pages that show posts keeps them", ctx do
      %{site: site, reader: reader} = ctx
      posts = ids([post!(site)])
      page!(site, "/blog/:slug", "blog:post", @members)
      page!(site, "/members/:slug", "blog:post", [])

      assert ids(read(BlogPost, :public_list, site, reader)) == posts
    end

    test "a locked page of another site hides nothing", ctx do
      %{site: site} = ctx
      other = create_site!(name: "other#{System.unique_integer([:positive])}", active: true)
      posts = ids([post!(site)])
      page!(other, "/blog/:slug", "blog:post", @members)

      assert ids(read(BlogPost, :public_list, site, nil)) == posts
    end
  end

  describe "what a read costs" do
    test "a locked page adds no statement to a list, a count or a record asked for alone", ctx do
      %{site: site, reader: reader, member: member} = ctx
      post = post!(site)

      reads = fn actor ->
        asked(fn ->
          Ash.read!(
            Ash.Query.for_read(BlogPost, :public_list, %{}, actor: actor, tenant: site.id),
            page: @page
          )

          BlogPost
          |> Ash.Query.for_read(:public_get, %{}, actor: actor, tenant: site.id)
          |> Ash.Query.filter(id == ^post.id)
          |> Ash.read_one()
        end)
      end

      open = for actor <- [nil, reader, member], do: reads.(actor)
      page!(site, "/blog/:slug", "blog:post", @members)
      closed = for actor <- [nil, reader, member], do: reads.(actor)

      # The list and its count, then the one record: the same statements with the page locked.
      assert closed == open
      assert Enum.uniq(open) == [3]
    end

    test "a site with no page showing posts reads the same statement as before", ctx do
      %{site: site} = ctx
      post!(site)

      statements =
        queries_while(fn ->
          BlogPost
          |> Ash.Query.for_read(:public_list, %{}, actor: nil, tenant: site.id)
          |> Ash.read!(page: [limit: 5])
        end)

      assert length(statements) == 1
    end
  end
end
