# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.VisitorListsTest do
  @moduledoc """
  What a page's read of posts, categories and tags keeps to for its visitor
  (`MishkaBlog.Resources.Preparations.OpenToActor`): a read with the visitor as its actor — what the
  blog's components pass, `nil` for a guest — leaves out, in its own query, what that visitor may not
  open, so its count and its pages are of what the visitor sees. A category's and a tag's
  `published_post_count`, loaded or sorted by, counts the posts that visitor may open, and so does a
  blogger's `post_count`, and a check of a row's posts (`exists(tenant_posts, …)`) finds only those. A read of the system's,
  `authorize?: false`, sees everything. A lock written is kept to by the next read.

  members (locked) → guides (names nothing); open names nothing.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.{Blogger, BlogPost, Collection, Tag}

  require Ash.Query

  setup do
    site = create_site!(active: true)

    members =
      create_collection!(site_id: site.id, status: :active, permissions: ["members:read"])

    guides =
      create_collection!(site_id: site.id, status: :active, parent_collection_id: members.id)

    open = create_collection!(site_id: site.id, status: :active)

    posts = %{
      open: post!(site, [], [open]),
      own: post!(site, ["members:read"], []),
      in_guides: post!(site, [], [guides]),
      own_wins: post!(site, ["staff:read"], [members])
    }

    member = create_user_with_permissions!(["members:read"], site_id: site.id)

    %{site: site, members: members, guides: guides, open: open, posts: posts, member: member}
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

  # A read the way the blog's components read: through the public action, as the visitor.
  defp visible(resource, site, visitor, opts \\ []) do
    resource
    |> Ash.Query.for_read(:public_list, %{}, actor: visitor, tenant: site.id)
    |> Ash.read!(opts)
  end

  defp counts(resource, site, visitor) do
    resource
    |> read_as(site, visitor)
    |> Ash.Query.load(:published_post_count)
    |> Ash.read!(tenant: site.id)
    |> rows()
    |> Map.new(&{&1.id, &1.published_post_count})
  end

  defp one_count(resource, record, site, visitor) do
    resource
    |> Ash.Query.for_read(:public_get, %{}, actor: visitor, tenant: site.id)
    |> Ash.Query.filter(id == ^record.id)
    |> Ash.Query.load(:published_post_count)
    |> Ash.read_one!(tenant: site.id)
    |> Map.fetch!(:published_post_count)
  end

  defp by_count(resource, site, visitor) do
    resource
    |> read_as(site, visitor)
    |> Ash.Query.load(:published_post_count)
    |> Ash.Query.sort(published_post_count: :desc, name: :asc)
    |> Ash.read!(tenant: site.id)
    |> rows()
    |> Enum.map(&{&1.id, &1.published_post_count})
  end

  # The rows with a published post, as a block leaving out the ones with nothing to read asks.
  defp with_post(resource, site, visitor) do
    resource
    |> read_as(site, visitor)
    |> Ash.Query.filter(exists(tenant_posts, status == :published))
    |> Ash.read!(tenant: site.id)
  end

  defp read_as(resource, site, visitor) do
    Ash.Query.for_read(resource, :public_list, %{}, actor: visitor, tenant: site.id)
  end

  defp ids(read), do: read |> rows() |> Enum.map(& &1.id) |> Enum.sort()

  defp rows(%{results: rows}), do: rows
  defp rows(rows), do: rows
  defp ids_of(records), do: records |> Enum.map(& &1.id) |> Enum.sort()

  test "a page's list of posts holds what its visitor may open, counted as it is shown", ctx do
    %{posts: posts} = ctx

    assert ids(visible(BlogPost, ctx.site, nil)) == ids_of([posts.open])

    assert ids(visible(BlogPost, ctx.site, ctx.member)) ==
             ids_of([posts.open, posts.own, posts.in_guides])

    assert visible(BlogPost, ctx.site, nil, page: [limit: 10, count: true]).count == 1
    assert visible(BlogPost, ctx.site, ctx.member, page: [limit: 10, count: true]).count == 3
  end

  # A COUNT IS OF WHAT THE LIST HOLDS. `Ash.count/2` runs none of a read's `before_action` hooks, so a
  # list narrowed to its visitor only there counted the posts and the categories they may not open.
  test "a count of a list counts what its visitor may open, as the list lists it", ctx do
    for {visitor, posts, categories} <- [{nil, 1, 1}, {ctx.member, 3, 3}] do
      assert BlogPost |> read_as(ctx.site, visitor) |> Ash.count!(tenant: ctx.site.id) == posts

      assert Collection |> read_as(ctx.site, visitor) |> Ash.count!(tenant: ctx.site.id) ==
               categories
    end
  end

  test "a page's lists of categories and tags hold what its visitor may open", ctx do
    locked =
      create_blog_tag!(site_id: ctx.site.id, language: "en", permissions: ["members:read"])

    tag = create_blog_tag!(site_id: ctx.site.id, language: "en")

    assert ids(visible(Collection, ctx.site, nil)) == ids_of([ctx.open])

    assert ids(visible(Collection, ctx.site, ctx.member)) ==
             ids_of([ctx.members, ctx.guides, ctx.open])

    assert ids(visible(Tag, ctx.site, nil)) == ids_of([tag])
    assert ids(visible(Tag, ctx.site, ctx.member)) == ids_of([locked, tag])
  end

  test "a category's and a tag's count is of the posts its visitor may open", ctx do
    shared = create_blog_tag!(site_id: ctx.site.id, language: "en")

    for post <- [ctx.posts.open, ctx.posts.own],
        do: create_post_tag!(post_id: post.id, tag_id: shared.id)

    create_post_collection!(post_id: ctx.posts.own.id, collection_id: ctx.open.id)

    assert counts(Tag, ctx.site, nil) == %{shared.id => 1}
    assert counts(Tag, ctx.site, ctx.member) == %{shared.id => 2}
    assert counts(Collection, ctx.site, nil) == %{ctx.open.id => 1}

    assert counts(Collection, ctx.site, ctx.member) ==
             %{ctx.members.id => 0, ctx.guides.id => 1, ctx.open.id => 2}

    assert one_count(Tag, shared, ctx.site, nil) == 1
    assert one_count(Tag, shared, ctx.site, ctx.member) == 2
    assert one_count(Collection, ctx.open, ctx.site, nil) == 1
    assert one_count(Collection, ctx.open, ctx.site, ctx.member) == 2
  end

  test "a check of a row's posts finds only those its visitor may open", ctx do
    behind = create_blog_tag!(site_id: ctx.site.id, language: "en")
    empty = create_blog_tag!(site_id: ctx.site.id, language: "en")
    create_post_tag!(post_id: ctx.posts.own.id, tag_id: behind.id)

    only_closed = create_collection!(site_id: ctx.site.id, status: :active)
    create_post_collection!(post_id: ctx.posts.own.id, collection_id: only_closed.id)

    assert counts(Tag, ctx.site, nil) == %{behind.id => 0, empty.id => 0}
    assert ids(with_post(Tag, ctx.site, nil)) == []
    assert ids(with_post(Tag, ctx.site, ctx.member)) == ids_of([behind])

    refute only_closed.id in ids(with_post(Collection, ctx.site, nil))
    assert only_closed.id in ids(with_post(Collection, ctx.site, ctx.member))
  end

  test "a sort by the count orders by what the visitor may open", ctx do
    many_closed = create_blog_tag!(site_id: ctx.site.id, language: "en", name: "many closed")
    few_open = create_blog_tag!(site_id: ctx.site.id, language: "en", name: "few open")

    for _closed <- 1..3 do
      post = post!(ctx.site, ["members:read"], [])
      create_post_tag!(post_id: post.id, tag_id: many_closed.id)
    end

    create_post_tag!(post_id: ctx.posts.open.id, tag_id: many_closed.id)

    for _open <- 1..2 do
      post = post!(ctx.site, [], [])
      create_post_tag!(post_id: post.id, tag_id: few_open.id)
    end

    assert by_count(Tag, ctx.site, nil) == [{few_open.id, 2}, {many_closed.id, 1}]
    assert by_count(Tag, ctx.site, ctx.member) == [{many_closed.id, 4}, {few_open.id, 2}]
  end

  # THE NUMBER A PEOPLE PAGE PUTS ON A BLOGGER'S CARD is the number of posts behind it for the reader:
  # the one open to everybody for a guest, those a member's permissions open for a member, and every
  # published one for the system.
  test "a blogger's post_count counts the posts that visitor may open", ctx do
    writer = create_blogger!(site_id: ctx.site.id)

    for post <- Map.values(ctx.posts),
        do: create_post_blogger!(post_id: post.id, blogger_id: writer.id)

    create_post_blogger!(
      post_id: create_blog_post!(site_id: ctx.site.id, status: :draft).id,
      blogger_id: writer.id
    )

    count = fn read ->
      read
      |> Ash.Query.load(:post_count)
      |> Ash.read!(tenant: ctx.site.id)
      |> rows()
      |> Enum.find(&(&1.id == writer.id))
      |> Map.fetch!(:post_count)
    end

    assert count.(read_as(Blogger, ctx.site, nil)) == 1
    assert count.(read_as(Blogger, ctx.site, ctx.member)) == 3

    assert count.(Ash.Query.for_read(Blogger, :public_list, %{}, authorize?: false)) == 4
  end

  # THE WORD BEFORE THE DATE ON A CARD names no category the visitor may not open: the first of the
  # post's categories is read through the categories' public read, as the visitor.
  test "a post's first category is the first one its visitor may open", %{
    site: site,
    member: member
  } do
    staff =
      create_collection!(
        site_id: site.id,
        status: :active,
        name: "Alpha staff",
        display_order: 0,
        permissions: ["staff:read"]
      )

    members =
      create_collection!(
        site_id: site.id,
        status: :active,
        name: "Zeta members",
        display_order: 1,
        permissions: ["members:read"]
      )

    post = post!(site, [], [staff, members])

    first_category = fn opts ->
      BlogPost
      |> Ash.Query.for_read(:public_list, %{}, Keyword.put(opts, :tenant, site.id))
      |> Ash.Query.filter(id == ^post.id)
      |> Ash.Query.load(:first_category_name)
      |> Ash.read!(page: [limit: 1])
      |> rows()
      |> Enum.map(& &1.first_category_name)
    end

    assert first_category.(actor: member) == ["Zeta members"]
    assert first_category.(actor: nil) == []
    assert first_category.(authorize?: false) == ["Alpha staff"]
  end

  test "a read of the system's sees every record", %{site: site, posts: posts} do
    all =
      BlogPost
      |> Ash.Query.for_read(:public_list, %{}, authorize?: false)
      |> Ash.read!(tenant: site.id)

    assert ids(all) == ids_of(Map.values(posts))
  end

  test "a read of the system's counts every published post", ctx do
    create_post_collection!(post_id: ctx.posts.own.id, collection_id: ctx.open.id)

    counted =
      Collection
      |> Ash.Query.for_read(:public_list, %{}, authorize?: false)
      |> Ash.Query.load(:published_post_count)
      |> Ash.read!(tenant: ctx.site.id)
      |> rows()
      |> Map.new(&{&1.id, &1.published_post_count})

    assert counted[ctx.open.id] == 2
    assert counted[ctx.members.id] == 1
  end

  test "a lock written is kept to by the next read, and one taken off too", ctx do
    assert ctx.posts.open.id in ids(visible(BlogPost, ctx.site, nil))

    locked =
      ctx.open
      |> Ash.Changeset.for_update(:update, %{permissions: ["members:read"]},
        tenant: ctx.site.id,
        authorize?: false
      )
      |> Ash.update!()

    refute ctx.posts.open.id in ids(visible(BlogPost, ctx.site, nil))
    refute ctx.open.id in ids(visible(Collection, ctx.site, nil))

    locked
    |> Ash.Changeset.for_update(:update, %{permissions: []},
      tenant: ctx.site.id,
      authorize?: false
    )
    |> Ash.update!()

    assert ctx.posts.open.id in ids(visible(BlogPost, ctx.site, nil))
  end
end
