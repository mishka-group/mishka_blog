# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.LockFreeReadsTest do
  @moduledoc """
  What a public read costs, and that it answers by the lock rules whether or not anything is locked
  (`MishkaBlog.Resources.Preparations.OpenToActor`,
  `MishkaBlog.Resources.Preparations.ReaderLocks`,
  `MishkaBlog.Resources.Calculations.EffectivePermissions`).

  A visitor, a signed-in reader and the system read the same thing for the same price: one read, plus
  its count when the page asks for one. The price is the same on a site that locks nothing and on one
  that locks a post, a category or both, because the check is part of the read. Every list, count,
  record asked for by itself, comment and sitemap entry is what the lock rules say; the last describe
  holds that over sites of every shape the generator draws — trees of categories, posts filed under
  several, locks at any level — against a reading of the rules written out here, not against the
  code.

  members:read (locked) → team (names nothing, a child of it); open names nothing.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.{BlogPost, Collection, Comment, Tag}
  alias MishkaBlog.Plugins.SitemapUrls
  alias MishkaBlog.Provision
  alias MishkaBlog.Resources.Preparations.OpenToActor
  alias MishkaCmsCore.Runtime.PageEditions

  require Ash.Query

  @members ["members:read"]

  setup do
    site = create_site!(active: true)

    %{
      site: site,
      member: create_user_with_permissions!(@members, site_id: site.id),
      reader: create_user_with_permissions!([], site_id: site.id)
    }
  end

  defp post!(site, permissions \\ [], categories \\ [], overrides \\ []) do
    post =
      [site_id: site.id, status: :published, language: "en", permissions: permissions]
      |> Keyword.merge(overrides)
      |> create_blog_post!()

    for category <- categories,
        do: create_post_collection!(post_id: post.id, collection_id: category.id)

    post
  end

  defp category!(site, permissions \\ [], overrides \\ []) do
    [site_id: site.id, status: :active, permissions: permissions]
    |> Keyword.merge(overrides)
    |> create_collection!()
  end

  defp tag!(site, permissions \\ [], posts \\ []) do
    tag = create_blog_tag!(site_id: site.id, language: "en", permissions: permissions)
    for post <- posts, do: create_post_tag!(post_id: post.id, tag_id: tag.id)
    tag
  end

  # A site with a tree of categories two deep, posts in each, and tags and a comment on them.
  defp unlocked!(site) do
    parent = category!(site)
    child = category!(site, [], parent_collection_id: parent.id)
    posts = [post!(site, [], [parent]), post!(site, [], [child]), post!(site)]
    tag = tag!(site, [], posts)
    comment = create_comment!(site_id: site.id, post_id: hd(posts).id, status: :approved)

    %{parent: parent, child: child, posts: posts, tag: tag, comment: comment}
  end

  defp read_query(resource, action, site, actor, args \\ %{}) do
    Ash.Query.for_read(resource, action, args, actor: actor, tenant: site.id)
  end

  # The same read as the system makes it: nobody is left out, nothing is checked.
  defp as_system(resource, action, site, args \\ %{}) do
    Ash.Query.for_read(resource, action, args, authorize?: false, tenant: site.id)
  end

  defp asked(fun), do: fun |> queries_while() |> length()

  defp ids(%{results: rows}), do: ids(rows)
  defp ids(rows) when is_list(rows), do: rows |> Enum.map(& &1.id) |> Enum.sort()
  defp ids(%{id: id}), do: [id]

  defp ids_of(records), do: records |> Enum.map(& &1.id) |> Enum.sort()

  @page [limit: 50, count: true]

  defp assert_same(actual, expected, label) do
    if actual != expected,
      do: flunk("#{label}: got #{inspect(actual)}, the rules say #{inspect(expected)}")
  end

  describe "a site where nothing is locked" do
    test "a list is one read and its count, for whoever reads it", ctx do
      %{site: site} = ctx
      unlocked!(site)

      for resource <- [BlogPost, Collection, Tag], actor <- [nil, ctx.reader, ctx.member] do
        system = asked(fn -> Ash.read!(as_system(resource, :public_list, site), page: @page) end)

        reader =
          asked(fn -> Ash.read!(read_query(resource, :public_list, site, actor), page: @page) end)

        assert system == 2
        assert reader == system, "#{inspect(resource)} cost a reader more than the system"
      end
    end

    test "what a reader is shown is what the system is shown", ctx do
      %{site: site} = ctx
      unlocked!(site)

      for resource <- [BlogPost, Collection, Tag], actor <- [nil, ctx.reader, ctx.member] do
        assert ids(Ash.read!(read_query(resource, :public_list, site, actor), page: @page)) ==
                 ids(Ash.read!(as_system(resource, :public_list, site), page: @page))
      end
    end

    test "a count of the posts of a category or a tag adds no read", ctx do
      %{site: site} = ctx
      unlocked!(site)

      for resource <- [Collection, Tag], actor <- [nil, ctx.member] do
        counted = fn query ->
          Ash.read!(Ash.Query.load(query, :published_post_count), page: @page)
        end

        system = asked(fn -> counted.(as_system(resource, :public_list, site)) end)
        reader = asked(fn -> counted.(read_query(resource, :public_list, site, actor)) end)

        assert reader == system

        assert Enum.map(
                 counted.(read_query(resource, :public_list, site, actor)).results,
                 & &1.published_post_count
               ) ==
                 Enum.map(
                   counted.(as_system(resource, :public_list, site)).results,
                   & &1.published_post_count
                 )
      end
    end

    test "a record asked for by itself is one read", ctx do
      %{site: site, parent: parent, posts: [post | _], tag: tag} =
        Map.merge(ctx, unlocked!(ctx.site))

      for {resource, record} <- [{BlogPost, post}, {Collection, parent}, {Tag, tag}],
          actor <- [nil, ctx.reader, ctx.member] do
        get = fn query -> query |> Ash.Query.filter(id == ^record.id) |> Ash.read_one!() end

        assert asked(fn -> get.(read_query(resource, :public_get, site, actor)) end) == 1
        assert get.(read_query(resource, :public_get, site, actor)).id == record.id
      end
    end

    test "the approved comments of a post are one read and its count", ctx do
      %{site: site, posts: [post | _], comment: comment} = Map.merge(ctx, unlocked!(ctx.site))

      for actor <- [nil, ctx.reader, ctx.member] do
        query = read_query(Comment, :approved_by_post, site, actor, %{post_id: post.id})

        assert asked(fn -> Ash.read!(query, page: @page) end) == 2
        assert ids(Ash.read!(query, page: @page)) == [comment.id]
      end
    end

    test "the permissions a record opens with are read with the record", ctx do
      %{site: site, comment: comment} = Map.merge(ctx, unlocked!(ctx.site))

      for resource <- [BlogPost, Collection, Comment] do
        query =
          resource
          |> Ash.Query.for_read(:read, %{}, authorize?: false, tenant: site.id)
          |> Ash.Query.load(:effective_permissions)

        assert asked(fn -> Ash.read!(query, page: false) end) == 1

        assert query
               |> Ash.read!(page: false)
               |> Enum.all?(&(&1.effective_permissions == []))
      end

      assert comment.id
    end

    test "a post's page keeps its permissions without reading its categories", ctx do
      %{site: site, posts: [post | _]} = Map.merge(ctx, unlocked!(ctx.site))

      read = fn ->
        BlogPost
        |> Ash.Query.for_read(:public_list, %{}, tenant: site.id, authorize?: false)
        |> Ash.Query.filter(id == ^post.id)
        |> Ash.Query.load(:effective_permissions)
        |> Ash.read!(page: [limit: 1])
      end

      assert asked(read) == 1
      assert [%{effective_permissions: []}] = read.().results
    end

    test "the sitemap reads each kind once and nothing else", ctx do
      %{site: site} = ctx
      unlocked!(site)

      create_page!(
        site_id: site.id,
        path: Provision.item_paths().post,
        extra: %{"record" => "blog:post", "serves_all_languages" => true},
        active: true,
        permissions: []
      )

      create_page!(
        site_id: site.id,
        path: Provision.item_paths().category,
        extra: %{"record" => "blog:category", "serves_all_languages" => true},
        active: true,
        permissions: []
      )

      queries =
        queries_while(fn ->
          {pages, _hidden} = PageEditions.indexable(site.id)

          {:reply, %{urls: urls}} =
            SitemapUrls.call(%{site: site, pages: pages, urls: Stream.map([], & &1)})

          assert length(Enum.to_list(urls)) == 5
        end)

      for table <- ["mishka_blog_posts", "mishka_blog_collections"] do
        assert Enum.count(queries, &String.contains?(&1, ~s(FROM "#{table}" AS m0))) == 1,
               "the sitemap read #{table} more than once"
      end
    end

    test "a read that finds nothing costs what the system's costs, and finds nothing", ctx do
      %{site: site} = ctx
      unlocked!(site)

      nothing = fn query ->
        query
        |> Ash.Query.filter(slug == "nothing-has-this-slug")
        |> Ash.read!(page: @page)
      end

      for resource <- [BlogPost, Collection, Tag], actor <- [nil, ctx.member] do
        assert asked(fn -> nothing.(read_query(resource, :public_list, site, actor)) end) ==
                 asked(fn -> nothing.(as_system(resource, :public_list, site)) end)

        assert nothing.(read_query(resource, :public_list, site, actor)).results == []
      end

      missing = fn opts ->
        Ash.get(BlogPost, Ash.UUID.generate(), [action: :public_get, tenant: site.id] ++ opts)
      end

      assert asked(fn -> missing.(actor: nil) end) == asked(fn -> missing.(authorize?: false) end)
      assert {:error, %Ash.Error.Invalid{}} = missing.(actor: nil)
    end
  end

  describe "a site where something is locked" do
    test "a locked category keeps its posts, and its child's, to whoever may open it", ctx do
      %{site: site, member: member, reader: reader} = ctx
      members = category!(site, @members)
      team = category!(site, [], parent_collection_id: members.id)
      open = category!(site)

      in_members = post!(site, [], [members])
      in_team = post!(site, [], [team])
      in_open = post!(site, [], [open])
      in_both = post!(site, [], [members, open])

      assert ids(Ash.read!(read_query(BlogPost, :public_list, site, nil), page: @page)) ==
               ids_of([in_open])

      assert ids(Ash.read!(read_query(BlogPost, :public_list, site, reader), page: @page)) ==
               ids_of([in_open])

      all = [in_members, in_team, in_open, in_both]

      assert ids(Ash.read!(read_query(BlogPost, :public_list, site, member), page: @page)) ==
               ids_of(all)

      assert Ash.read!(read_query(BlogPost, :public_list, site, nil), page: @page).count == 1
      assert Ash.read!(read_query(BlogPost, :public_list, site, member), page: @page).count == 4

      assert ids(Ash.read!(read_query(Collection, :public_list, site, nil), page: @page)) ==
               ids_of([open])

      for post <- [in_members, in_team] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 BlogPost
                 |> read_query(:public_get, site, nil)
                 |> Ash.Query.filter(id == ^post.id)
                 |> Ash.read_one()

        assert {:ok, %{id: id}} =
                 BlogPost
                 |> read_query(:public_get, site, member)
                 |> Ash.Query.filter(id == ^post.id)
                 |> Ash.read_one()

        assert id == post.id
      end
    end

    test "a page past the last one counts only what the reader may open", ctx do
      %{site: site, member: member} = ctx
      for _open <- 1..2, do: post!(site)
      for _locked <- 1..3, do: post!(site, @members)

      for {actor, count} <- [{nil, 2}, {member, 5}] do
        page =
          Ash.read!(read_query(BlogPost, :public_list, site, actor),
            page: [limit: 10, offset: 40, count: true]
          )

        assert page.results == []
        assert page.count == count
      end
    end

    test "a locked post is hidden from a visitor and a reader without the permission", ctx do
      %{site: site, member: member, reader: reader} = ctx
      open = post!(site)
      locked = post!(site, @members)

      for actor <- [nil, reader] do
        assert ids(Ash.read!(read_query(BlogPost, :public_list, site, actor), page: @page)) ==
                 ids_of([open])

        assert Ash.read!(read_query(BlogPost, :public_list, site, actor), page: @page).count == 1

        assert {:error, %Ash.Error.Forbidden{}} =
                 BlogPost
                 |> read_query(:public_get, site, actor)
                 |> Ash.Query.filter(id == ^locked.id)
                 |> Ash.read_one()
      end

      assert ids(Ash.read!(read_query(BlogPost, :public_list, site, member), page: @page)) ==
               ids_of([open, locked])
    end

    test "one locked post in an unlocked category leaves the rest of it open", ctx do
      %{site: site, member: member} = ctx
      shelf = category!(site)
      kept = for _ <- 1..3, do: post!(site, [], [shelf])
      locked = post!(site, @members, [shelf])
      tag = tag!(site, [], kept ++ [locked])

      assert ids(Ash.read!(read_query(BlogPost, :public_list, site, nil), page: @page)) ==
               ids_of(kept)

      assert ids(Ash.read!(read_query(BlogPost, :public_list, site, member), page: @page)) ==
               ids_of([locked | kept])

      counted = fn resource, record, actor ->
        resource
        |> read_query(:public_list, site, actor)
        |> Ash.Query.filter(id == ^record.id)
        |> Ash.Query.load(:published_post_count)
        |> Ash.read!(page: @page)
        |> Map.fetch!(:results)
        |> Enum.map(& &1.published_post_count)
      end

      assert counted.(Collection, shelf, nil) == [3]
      assert counted.(Collection, shelf, member) == [4]
      assert counted.(Tag, tag, nil) == [3]
      assert counted.(Tag, tag, member) == [4]
    end

    test "a locked tag is hidden from a visitor, shown to a reader with the permission", ctx do
      %{site: site, member: member} = ctx
      open = tag!(site)
      locked = tag!(site, @members)

      assert ids(Ash.read!(read_query(Tag, :public_list, site, nil), page: @page)) ==
               ids_of([open])

      assert ids(Ash.read!(read_query(Tag, :public_list, site, member), page: @page)) ==
               ids_of([open, locked])

      assert {:error, %Ash.Error.Forbidden{}} =
               Tag
               |> read_query(:public_get, site, nil)
               |> Ash.Query.filter(id == ^locked.id)
               |> Ash.read_one()
    end

    test "the comments of a locked post are left out for whoever may not open it", ctx do
      %{site: site, member: member} = ctx
      locked = post!(site, @members)
      comment = create_comment!(site_id: site.id, post_id: locked.id, status: :approved)

      query = fn actor ->
        read_query(Comment, :approved_by_post, site, actor, %{post_id: locked.id})
      end

      assert ids(Ash.read!(query.(nil), page: @page)) == []
      assert ids(Ash.read!(query.(member), page: @page)) == [comment.id]
    end

    test "a locked category and a locked post are left out of the sitemap", ctx do
      %{site: site} = ctx

      for kind <- [:post, :category] do
        create_page!(
          site_id: site.id,
          path: Provision.item_paths()[kind],
          extra: %{"record" => "blog:#{kind}", "serves_all_languages" => true},
          active: true,
          permissions: []
        )
      end

      members = category!(site, @members)
      open = category!(site)
      kept = post!(site, [], [open])
      _in_locked_category = post!(site, [], [members])
      _locked_post = post!(site, @members, [])

      {pages, _hidden} = PageEditions.indexable(site.id)

      {:reply, %{urls: urls}} =
        SitemapUrls.call(%{site: site, pages: pages, urls: Stream.map([], & &1)})

      paths = urls |> Enum.map(& &1.path) |> Enum.sort()
      assert Enum.any?(paths, &String.ends_with?(&1, kept.slug))
      assert Enum.any?(paths, &String.ends_with?(&1, open.slug))
      refute Enum.any?(paths, &String.ends_with?(&1, members.slug))
      assert length(paths) == 2
    end

    test "a site that locks a post, a category and a tag costs a reader what it costs the system",
         ctx do
      %{site: site, member: member, reader: reader} = ctx
      members = category!(site, @members)
      team = category!(site, [], parent_collection_id: members.id)
      open = category!(site)
      locked = post!(site, @members)
      in_team = post!(site, [], [team])
      in_open = post!(site, [], [open])
      locked_tag = tag!(site, @members, [in_open])
      create_comment!(site_id: site.id, post_id: locked.id, status: :approved)
      comment = create_comment!(site_id: site.id, post_id: in_open.id, status: :approved)

      for resource <- [BlogPost, Collection, Tag], actor <- [nil, reader, member] do
        system = asked(fn -> Ash.read!(as_system(resource, :public_list, site), page: @page) end)

        reader_cost =
          asked(fn -> Ash.read!(read_query(resource, :public_list, site, actor), page: @page) end)

        assert system == 2
        assert reader_cost == system
      end

      for {resource, record} <- [{BlogPost, in_team}, {Collection, team}, {Tag, locked_tag}],
          actor <- [nil, reader, member] do
        get = fn query -> query |> Ash.Query.filter(id == ^record.id) |> Ash.read_one() end

        assert asked(fn -> get.(read_query(resource, :public_get, site, actor)) end) == 1
      end

      for actor <- [nil, member] do
        query = read_query(Comment, :approved_by_post, site, actor, %{post_id: in_open.id})

        assert asked(fn -> Ash.read!(query, page: @page) end) == 2
        assert ids(Ash.read!(query, page: @page)) == [comment.id]
      end
    end

    test "another site's lock neither hides nor costs this site anything", ctx do
      %{site: site, member: member} = ctx
      other = create_site!(active: true)
      unlocked!(site)
      post!(other, @members)
      category!(other, @members)

      for resource <- [BlogPost, Collection, Tag] do
        system = asked(fn -> Ash.read!(as_system(resource, :public_list, site), page: @page) end)

        reader =
          asked(fn ->
            Ash.read!(read_query(resource, :public_list, site, member), page: @page)
          end)

        assert reader == system
      end

      assert Ash.read!(read_query(BlogPost, :public_list, other, nil), page: @page).results == []
    end

    test "a lock taken off, or written, changes the answer on the next read and not the cost",
         ctx do
      %{site: site} = ctx
      unlocked!(site)
      locked = post!(site, @members)
      read = fn -> Ash.read!(read_query(BlogPost, :public_list, site, nil), page: @page) end

      assert locked.id not in ids(read.())
      assert asked(read) == 2

      opened =
        locked
        |> Ash.Changeset.for_update(:update, %{permissions: []},
          tenant: site.id,
          authorize?: false
        )
        |> Ash.update!()

      assert locked.id in ids(read.())
      assert asked(read) == 2

      opened
      |> Ash.Changeset.for_update(:update, %{permissions: @members},
        tenant: site.id,
        authorize?: false
      )
      |> Ash.update!()

      assert locked.id not in ids(read.())
    end

    test "an archived record that names permissions locks nothing", ctx do
      %{site: site} = ctx
      data = unlocked!(site)
      locked_category = category!(site, @members)
      under_it = post!(site, [], [locked_category])
      archived_post = post!(site, @members)

      for record <- [locked_category, archived_post] do
        record
        |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
        |> Ash.destroy!()
      end

      read = fn -> Ash.read!(read_query(BlogPost, :public_list, site, nil), page: @page) end

      assert under_it.id in ids(read.())
      assert length(ids(read.())) == length(data.posts) + 1
      assert asked(read) == 2
    end

    test "the permissions of a record are those of its categories, wherever the query's site is",
         ctx do
      %{site: site} = ctx
      other = create_site!(active: true)
      unlocked!(site)
      members = category!(other, @members)
      filed = post!(other, [], [members])

      effective = fn tenant ->
        BlogPost
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false, tenant: tenant)
        |> Ash.Query.filter(id == ^filed.id)
        |> Ash.Query.load(:effective_permissions)
        |> Ash.read_one!()
        |> Map.fetch!(:effective_permissions)
      end

      assert effective.(other.id) == @members
      assert effective.(site.id) == @members
      assert effective.(nil) == @members
    end
  end

  describe "over sites of every shape" do
    @actors [:visitor, :reader, :member, :staff]

    # The rules as the docs state them, read off the records themselves: a category opens with its own
    # permissions, else its nearest parent's; a post with its own, else those of every category it is
    # filed under; a tag with its own; a comment with its post's. A reader opens a record that names
    # none, and one that names some only when it holds one of them.
    defp lock_of_category(categories, id, seen \\ [])

    defp lock_of_category(categories, id, seen) do
      with false <- id in seen, %{permissions: permissions, parent: parent} <- categories[id] do
        if permissions == [],
          do: lock_of_category(categories, parent, [id | seen]),
          else: permissions
      else
        _top -> []
      end
    end

    defp lock_of_post(%{permissions: [_ | _] = own}, _filed, _categories), do: own

    defp lock_of_post(post, filed, categories) do
      filed
      |> Map.get(post.id, [])
      |> Enum.flat_map(&lock_of_category(categories, &1))
      |> Enum.uniq()
    end

    defp opens?(lock, :visitor), do: lock == []
    defp opens?(lock, :reader), do: lock == []
    defp opens?(lock, :member), do: lock == [] or Enum.any?(lock, &(&1 == "members:read"))
    defp opens?(lock, :staff), do: lock == [] or Enum.any?(lock, &(&1 == "staff:read"))

    defp actor(:visitor, _ctx), do: nil
    defp actor(:reader, ctx), do: ctx.reader
    defp actor(:member, ctx), do: ctx.member
    defp actor(:staff, ctx), do: ctx.staff

    # One site drawn from `seed`: up to five categories in a tree, up to six posts filed under none,
    # one or two of them, up to three tags, a comment on each post. `locks` is how many of every
    # ten records name permissions.
    defp draw!(
           site,
           seed,
           locks,
           names \\ fn -> [Enum.random(["members:read", "staff:read"])] end
         ) do
      :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})
      lock = fn -> if :rand.uniform(10) <= locks, do: names.(), else: [] end

      categories =
        Enum.reduce(1..:rand.uniform(5), [], fn _n, made ->
          parent = if made != [] and :rand.uniform(3) > 1, do: Enum.random(made).id, else: nil
          [category!(site, lock.(), parent_collection_id: parent) | made]
        end)

      posts =
        for n <- 1..:rand.uniform(6) do
          filed = categories |> Enum.take_random(:rand.uniform(3) - 1)
          status = if n > 1 and :rand.uniform(6) == 1, do: :draft, else: :published
          {post!(site, lock.(), filed, status: status), filed}
        end

      tags =
        for _n <- 1..:rand.uniform(3) do
          attached = posts |> Enum.map(&elem(&1, 0)) |> Enum.take_random(:rand.uniform(3))
          tag!(site, lock.(), attached)
        end

      comments =
        for {post, _filed} <- posts,
            do: create_comment!(site_id: site.id, post_id: post.id, status: :approved)

      %{categories: categories, posts: posts, tags: tags, comments: comments}
    end

    test "a drawn site costs a read and its count, locked or not, whoever reads" do
      for seed <- 1..12, locks <- [0, 3, 8] do
        site = create_site!(active: true)
        member = create_user_with_permissions!(@members, site_id: site.id)
        draw!(site, seed, locks)

        for resource <- [BlogPost, Collection, Tag], actor <- [nil, member] do
          assert asked(fn ->
                   Ash.read!(read_query(resource, :public_list, site, actor), page: @page)
                 end) == 2,
                 "seed #{seed}, #{locks}/10 locked: #{inspect(resource)} cost a read more"
        end
      end
    end

    test "every read is what the rules say, for each kind of reader" do
      for seed <- 1..40 do
        locks = Enum.at([0, 0, 1, 2, 4, 8], rem(seed, 6))
        site = create_site!(active: true)
        other = create_site!(active: true)

        ctx = %{
          reader: create_user_with_permissions!([], site_id: site.id),
          member: create_user_with_permissions!(@members, site_id: site.id),
          staff: create_user_with_permissions!(["staff:read"], site_id: site.id)
        }

        data = draw!(site, seed, locks)
        draw!(other, seed + 1000, 5)
        rules = rules(data)
        assert rules.published != [], "seed #{seed} drew a site with nothing to read"

        check_effective!(site, data, rules, "seed #{seed}, #{locks}/10 locked")

        for kind <- @actors do
          check_reader!(
            site,
            data,
            rules,
            actor(kind, ctx),
            "seed #{seed}, #{kind}, #{locks}/10 locked",
            &opens?(&1, kind)
          )
        end
      end
    end

    @segments ~w(a b c admin api dashboard *)

    defp name_drawn do
      Enum.map_join(1..:rand.uniform(3), ":", fn _segment -> Enum.random(@segments) end)
    end

    # What the checker, `AccessPermissions`, says, for readers holding names of every shape: what a lock
    # names exactly, what it names with a `*` in its place, the whole `*`, `admin:api:` names, and
    # nothing. A reader is a map of the permissions it holds, which is all the checker asks of one.
    test "every read is what AccessPermissions says, for readers holding any names" do
      for seed <- 1..40 do
        locks = Enum.at([2, 4, 6, 8], rem(seed, 4))
        site = create_site!(active: true)
        other = create_site!(active: true)

        data =
          draw!(site, seed, locks, fn ->
            Enum.map(1..:rand.uniform(2), fn _name -> name_drawn() end)
          end)

        draw!(other, seed + 1000, 5)
        rules = rules(data)
        assert rules.published != [], "seed #{seed} drew a site with nothing to read"
        named = data |> locks_named() |> Enum.shuffle()
        wild = fn -> named |> Enum.take(1) |> Enum.map(&wildcard_of/1) end

        held = [
          [],
          Enum.take(named, 1),
          Enum.take(named, 3),
          wild.(),
          ["*"],
          Enum.map(1..3, fn _name -> name_drawn() end),
          Enum.take(named, 1) ++ wild.() ++ [name_drawn()]
        ]

        check_effective!(site, data, rules, "seed #{seed}, #{locks}/10 locked")

        for names <- Enum.uniq(held) do
          reader = %{permissions: Enum.map(names, &%{name: &1})}

          check_reader!(
            site,
            data,
            rules,
            reader,
            "seed #{seed}, holding #{inspect(names)}, #{locks}/10 locked",
            &OpenToActor.opens?(&1, reader)
          )
        end

        check_reader!(
          site,
          data,
          rules,
          nil,
          "seed #{seed}, a visitor, #{locks}/10 locked",
          &OpenToActor.opens?(&1, nil)
        )
      end
    end

    # The sitemap is read for a visitor who is not signed in, so it lists the posts and categories
    # whose lock the checker opens for nobody holding nothing: the ones that name none.
    test "the sitemap lists what AccessPermissions opens for a visitor" do
      for seed <- 1..20 do
        locks = Enum.at([0, 2, 4, 8], rem(seed, 4))
        site = create_site!(active: true)

        for kind <- [:post, :category] do
          create_page!(
            site_id: site.id,
            path: Provision.item_paths()[kind],
            extra: %{"record" => "blog:#{kind}", "serves_all_languages" => true},
            active: true,
            permissions: []
          )
        end

        data =
          draw!(site, seed, locks, fn ->
            Enum.map(1..:rand.uniform(2), fn _name -> name_drawn() end)
          end)

        rules = rules(data)

        expected =
          for(
            post <- rules.published,
            OpenToActor.opens?(rules.lock_of_post_id[post.id], nil),
            do: post.slug
          ) ++
            for(
              category <- data.categories,
              category.status == :active,
              OpenToActor.opens?(lock_of_category(rules.by_id, category.id), nil),
              do: category.slug
            )

        {pages, _hidden} = PageEditions.indexable(site.id)

        {:reply, %{urls: urls}} =
          SitemapUrls.call(%{site: site, pages: pages, urls: Stream.map([], & &1)})

        listed = urls |> Enum.map(&(&1.path |> String.split("/") |> List.last())) |> Enum.sort()
        assert_same(listed, Enum.sort(expected), "the sitemap, seed #{seed}, #{locks}/10 locked")
      end
    end

    defp locks_named(data) do
      [data.categories, Enum.map(data.posts, &elem(&1, 0)), data.tags]
      |> Enum.concat()
      |> Enum.flat_map(&(&1.permissions || []))
      |> Enum.uniq()
    end

    # A name held with a `*` where its last segment, or a middle one, was.
    defp wildcard_of(name) do
      segments = String.split(name, ":")
      at = :rand.uniform(length(segments)) - 1
      segments |> List.replace_at(at, "*") |> Enum.join(":")
    end

    defp rules(data) do
      by_id =
        Map.new(
          data.categories,
          &{&1.id, %{permissions: &1.permissions || [], parent: &1.parent_collection_id}}
        )

      filed = Map.new(data.posts, fn {post, filed} -> {post.id, Enum.map(filed, & &1.id)} end)

      %{
        by_id: by_id,
        filed: filed,
        lock_of_post_id:
          Map.new(data.posts, fn {post, _} -> {post.id, lock_of_post(post, filed, by_id)} end),
        published: for({post, _} <- data.posts, post.status == :published, do: post)
      }
    end

    defp check_effective!(site, data, rules, where) do
      effective = fn resource ->
        resource
        |> Ash.Query.for_read(:read, %{}, authorize?: false, tenant: site.id)
        |> Ash.Query.load(:effective_permissions)
        |> Ash.read!(page: false)
        |> Map.new(&{&1.id, Enum.sort(&1.effective_permissions)})
      end

      assert_same(
        effective.(BlogPost),
        Map.new(rules.lock_of_post_id, fn {id, lock} -> {id, Enum.sort(lock)} end),
        "the permissions of the posts, #{where}"
      )

      assert_same(
        effective.(Collection),
        Map.new(rules.by_id, fn {id, _} -> {id, Enum.sort(lock_of_category(rules.by_id, id))} end),
        "the permissions of the categories, #{where}"
      )

      assert_same(
        effective.(Comment),
        Map.new(data.comments, &{&1.id, Enum.sort(rules.lock_of_post_id[&1.post_id])}),
        "the permissions of the comments, #{where}"
      )
    end

    # Every read `who` makes of the site, held to `opens?`: whether a lock opens for it.
    defp check_reader!(site, data, rules, who, where, opens?) do
      %{published: published, lock_of_post_id: lock_of_post_id, by_id: by_id} = rules

      expected = %{
        posts: for(post <- published, opens?.(lock_of_post_id[post.id]), do: post),
        categories:
          for(
            category <- data.categories,
            category.status == :active,
            opens?.(lock_of_category(by_id, category.id)),
            do: category
          ),
        tags: for(tag <- data.tags, opens?.(tag.permissions || []), do: tag)
      }

      check_lists!(site, who, where, expected)
      check_records!(site, data, rules, who, where, opens?)
      check_counts!(site, rules, who, where, expected)
      check_comments!(site, data, rules, who, where, opens?)
    end

    defp check_lists!(site, who, where, expected) do
      page = Ash.read!(read_query(BlogPost, :public_list, site, who), page: @page)
      assert_same(ids(page), ids_of(expected.posts), "posts, #{where}")
      assert_same(page.count, length(expected.posts), "post count, #{where}")

      past =
        Ash.read!(read_query(BlogPost, :public_list, site, who),
          page: [limit: 5, offset: 500, count: true]
        )

      assert_same(
        {past.results, past.count},
        {[], length(expected.posts)},
        "past the last page, #{where}"
      )

      assert_same(
        ids(Ash.read!(read_query(Collection, :public_list, site, who), page: @page)),
        ids_of(expected.categories),
        "categories, #{where}"
      )

      assert_same(
        ids(Ash.read!(read_query(Tag, :public_list, site, who), page: @page)),
        ids_of(expected.tags),
        "tags, #{where}"
      )
    end

    # Each record asked for by itself is the record, or forbidden.
    defp check_records!(site, data, rules, who, where, opens?) do
      %{published: published, lock_of_post_id: lock_of_post_id, by_id: by_id} = rules

      asked_for = fn resource, record, lock ->
        outcome =
          resource
          |> read_query(:public_get, site, who)
          |> Ash.Query.filter(id == ^record.id)
          |> Ash.read_one()

        if opens?.(lock),
          do: assert({:ok, %{id: _}} = outcome, "#{inspect(resource)} by itself, #{where}"),
          else:
            assert(
              {:error, %Ash.Error.Forbidden{}} = outcome,
              "#{inspect(resource)} by itself, #{where}"
            )
      end

      for post <- published, do: asked_for.(BlogPost, post, lock_of_post_id[post.id])

      for category <- data.categories,
          category.status == :active,
          do: asked_for.(Collection, category, lock_of_category(by_id, category.id))

      for tag <- data.tags, do: asked_for.(Tag, tag, tag.permissions || [])
    end

    # What a category or a tag counts is the posts of it the reader may open.
    defp check_counts!(site, rules, who, where, expected) do
      counts = fn resource, ids_wanted ->
        resource
        |> read_query(:public_list, site, who)
        |> Ash.Query.load(:published_post_count)
        |> Ash.read!(page: @page)
        |> Map.fetch!(:results)
        |> Enum.filter(&(&1.id in ids_wanted))
        |> Map.new(&{&1.id, &1.published_post_count})
      end

      visible = MapSet.new(ids_of(expected.posts))

      category_counts =
        Map.new(expected.categories, fn category ->
          {category.id,
           Enum.count(rules.published, fn post ->
             category.id in rules.filed[post.id] and MapSet.member?(visible, post.id)
           end)}
        end)

      assert_same(
        counts.(Collection, Map.keys(category_counts)),
        category_counts,
        "category counts, #{where}"
      )

      tag_counts =
        Map.new(expected.tags, fn tag ->
          attached =
            tag
            |> Ash.load!(:tenant_posts, tenant: site.id, authorize?: false)
            |> Map.fetch!(:tenant_posts)
            |> Enum.filter(&(&1.status == :published and MapSet.member?(visible, &1.id)))

          {tag.id, length(attached)}
        end)

      assert_same(counts.(Tag, Map.keys(tag_counts)), tag_counts, "tag counts, #{where}")
    end

    defp check_comments!(site, data, rules, who, where, opens?) do
      for comment <- data.comments do
        seen =
          Comment
          |> read_query(:approved_by_post, site, who, %{post_id: comment.post_id})
          |> Ash.read!(page: @page)
          |> ids()

        expected = if opens?.(rules.lock_of_post_id[comment.post_id]), do: [comment.id], else: []
        assert_same(seen, expected, "comments, #{where}")
      end
    end
  end
end
