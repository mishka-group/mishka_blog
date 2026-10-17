# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.SiteBoundaryTest do
  @moduledoc """
  A site user acts only on its own site, even one holding `"*"`. A master is a user whose `site_id`
  is nil, never a missing actor. A call made with `authorize?: false` is the system and stays exempt.

  The cases span every blog resource and share one two-site fixture, so they live in one file instead
  of repeating that fixture in each resource's own test file.
  """
  use MishkaBlog.DataCase, async: false

  require Ash.Query

  alias MishkaBlog.Resources.Changes.RestoreVersion

  alias MishkaBlog.{
    AutoPosting,
    BlogPost,
    Blogger,
    Collection,
    Comment,
    CommentVote,
    PostBlogger,
    PostBookmark,
    PostCollection,
    PostRating,
    PostTag,
    PostView,
    Tag,
    Team,
    TeamFollower,
    TeamMember,
    TeamPermission
  }

  setup do
    site_a = create_site!()
    site_b = create_site!()

    %{
      site_a: site_a,
      site_b: site_b,
      master: create_user_with_permissions!(["*"]),
      admin_a: create_user_with_permissions!(["*"], site_id: site_a.id)
    }
  end

  defp ids({:ok, %{results: results}}), do: ids(results)
  defp ids({:ok, results}) when is_list(results), do: ids(results)
  defp ids({:ok, nil}), do: []
  defp ids({:ok, record}), do: ids([record])
  defp ids({:error, _}), do: []
  defp ids(nil), do: []
  defp ids(%{id: _} = record), do: ids([record])
  defp ids(records) when is_list(records), do: Enum.map(records, &Map.get(&1, :id))

  defp key(%PostTag{} = row), do: {row.post_id, row.tag_id}
  defp key(%PostBlogger{} = row), do: {row.post_id, row.blogger_id}
  defp key(%PostCollection{} = row), do: {row.post_id, row.collection_id}
  defp key(row), do: row.id

  @version_fields [:latest_version, :recent_versions, :version_count]

  # A public list read of one record, as `actor` on `tenant`. A site user naming another site as the
  # tenant may be refused outright rather than answered.
  defp public_read(resource, record, actor, tenant, load) do
    resource
    |> Ash.Query.for_read(:public_list, %{}, actor: actor, tenant: tenant)
    |> Ash.Query.filter(id == ^record.id)
    |> Ash.Query.load(load)
    |> Ash.read(page: [limit: 5])
    |> case do
      {:ok, %{results: results}} -> {:ok, results}
      {:error, error} -> {:error, error}
    end
  end

  # The record's first version, the one its creation made.
  defp version_of(version_resource, record) do
    version_resource
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(version_source_id == ^record.id)
    |> Ash.Query.sort(version_inserted_at: :asc)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  # A snapshot carries the unique values its record had, so the record moves them aside first; a
  # restore that is let through then shows as the copied values instead of a unique-key error.
  defp move_aside(record) do
    unique = System.unique_integer([:positive])

    params =
      case record do
        %Blogger{} -> %{slug: "aside-#{unique}", user_id: create_user!().id}
        %Team{} -> %{slug: "aside-#{unique}"}
        %AutoPosting{} -> %{plugin: "aside_#{unique}"}
        _with_language_group -> %{slug: "aside-#{unique}", language: "de"}
      end

    record
    |> Ash.Changeset.for_update(:master_update, params, authorize?: false)
    |> Ash.update!()
  end

  defp reload(resource, record),
    do: Ash.get!(resource, record.id, action: :master_get, authorize?: false)

  describe "Collection :read_archived_api" do
    test "is gone, so no action picks the master path from a missing tenant" do
      assert is_nil(Ash.Resource.Info.action(Collection, :read_archived_api))
    end
  end

  describe ":read_any is for masters and the system" do
    for {resource, factory} <- [
          {BlogPost, :create_blog_post!},
          {Collection, :create_collection!}
        ] do
      test "#{inspect(resource)}: a site user holding * reads no other site's rows", ctx do
        row_b = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_b.id]])

        result =
          unquote(resource)
          |> Ash.Query.for_read(:read_any, %{}, actor: ctx.admin_a)
          |> Ash.read()

        refute row_b.id in ids(result)
      end

      test "#{inspect(resource)}: a master reads every site's rows", ctx do
        row_b = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_b.id]])

        result =
          unquote(resource)
          |> Ash.Query.for_read(:read_any, %{}, actor: ctx.master)
          |> Ash.read()

        assert row_b.id in ids(result)
      end

      test "#{inspect(resource)}: no actor reads nothing", ctx do
        row_b = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_b.id]])

        result = unquote(resource) |> Ash.Query.for_read(:read_any, %{}) |> Ash.read()

        refute row_b.id in ids(result)
      end

      test "#{inspect(resource)}: a system read still reads every site", ctx do
        row_b = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_b.id]])

        result =
          unquote(resource)
          |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
          |> Ash.read(authorize?: false)

        assert row_b.id in ids(result)
      end
    end
  end

  describe "master_* relationships answer only a master" do
    setup ctx do
      b = ctx.site_b.id
      post = create_blog_post!(site_id: b)
      tag = create_blog_tag!(site_id: b)
      create_post_tag!(post_id: post.id, tag_id: tag.id)
      blogger = create_blogger!(site_id: b)
      create_post_blogger!(post_id: post.id, blogger_id: blogger.id)
      parent = create_collection!(site_id: b)
      collection = create_collection!(site_id: b, parent_collection_id: parent.id)
      create_post_collection!(post_id: post.id, collection_id: collection.id)
      comment = create_comment!(site_id: b, post_id: post.id)
      team = create_team!(site_id: b)
      create_team_member!(team_id: team.id, blogger_id: blogger.id)

      %{
        loads: [
          {post, :master_bloggers},
          {post, :master_collections},
          {post, :master_tags},
          {post, :master_comments},
          {tag, :master_posts},
          {blogger, :master_teams},
          {blogger, :master_posts},
          {team, :master_members},
          {collection, :master_posts},
          {collection, :master_parent_collection},
          {collection, :master_language_variants},
          {comment, :master_post}
        ]
      }
    end

    test "a missing actor loads none of them, even on a system read", %{loads: loads} do
      for {record, relationship} <- loads do
        loaded = Ash.load!(record, [relationship], authorize?: false)

        assert ids(Map.fetch!(loaded, relationship)) == [],
               "#{inspect(record.__struct__)}.#{relationship} answered a missing actor"
      end
    end

    test "a site user holding * loads none of them", %{loads: loads, admin_a: admin_a} do
      for {record, relationship} <- loads do
        loaded = Ash.load!(record, [relationship], actor: admin_a, authorize?: false)

        assert ids(Map.fetch!(loaded, relationship)) == [],
               "#{inspect(record.__struct__)}.#{relationship} answered a site user"
      end
    end

    test "a master loads every one of them", %{loads: loads, master: master} do
      for {record, relationship} <- loads do
        loaded = Ash.load!(record, [relationship], actor: master, authorize?: false)

        refute ids(Map.fetch!(loaded, relationship)) == [],
               "#{inspect(record.__struct__)}.#{relationship} refused a master"
      end
    end
  end

  describe "a tenant write names only its own site's records" do
    test "Comment :create refuses another site's post", ctx do
      post_b = create_blog_post!(site_id: ctx.site_b.id)

      result =
        Comment
        |> Ash.Changeset.for_create(
          :create,
          %{post_id: post_b.id, content: "Hello there", status: :approved},
          actor: ctx.admin_a,
          tenant: ctx.site_a.id
        )
        |> Ash.create()

      assert {:error, _} = result
    end

    test "Comment :create_public refuses another site's post", ctx do
      post_b = create_blog_post!(site_id: ctx.site_b.id, status: :published)
      visitor = create_user!(site_id: ctx.site_a.id)

      result =
        Comment
        |> Ash.Changeset.for_create(
          :create_public,
          %{post_id: post_b.id, content: "Hello there"},
          actor: visitor,
          tenant: ctx.site_a.id
        )
        |> Ash.create()

      assert {:error, _} = result
    end

    test "Comment :create refuses another site's parent comment", ctx do
      post_a = create_blog_post!(site_id: ctx.site_a.id)
      comment_b = create_comment!(site_id: ctx.site_b.id)

      result =
        Comment
        |> Ash.Changeset.for_create(
          :create,
          %{
            post_id: post_a.id,
            parent_comment_id: comment_b.id,
            content: "Hello there",
            status: :approved
          },
          actor: ctx.admin_a,
          tenant: ctx.site_a.id
        )
        |> Ash.create()

      assert {:error, _} = result
    end

    test "Comment :update refuses another site's post and never takes a site", ctx do
      comment = create_comment!(site_id: ctx.site_a.id)
      post_b = create_blog_post!(site_id: ctx.site_b.id)
      comment_b = create_comment!(site_id: ctx.site_b.id, post_id: post_b.id)

      for params <- [
            %{post_id: post_b.id},
            %{parent_comment_id: comment_b.id},
            %{site_id: ctx.site_b.id}
          ] do
        result =
          comment
          |> Ash.Changeset.for_update(:update, params,
            actor: ctx.admin_a,
            tenant: ctx.site_a.id
          )
          |> Ash.update()

        assert {:error, _} = result
      end

      reloaded = Ash.get!(Comment, comment.id, action: :master_get, authorize?: false)
      assert reloaded.site_id == ctx.site_a.id
      assert reloaded.post_id == comment.post_id
    end

    test "Collection :create and :update refuse another site's parent and language group", ctx do
      collection_b = create_collection!(site_id: ctx.site_b.id)
      own = create_collection!(site_id: ctx.site_a.id)

      for field <- [:parent_collection_id, :language_group_id] do
        created =
          Collection
          |> Ash.Changeset.for_create(
            :create,
            %{name: "A", slug: "a-#{field}", status: :active, language: "fa"}
            |> Map.put(field, collection_b.id),
            actor: ctx.admin_a,
            tenant: ctx.site_a.id
          )
          |> Ash.create()

        assert {:error, _} = created

        updated =
          own
          |> Ash.Changeset.for_update(:update, %{field => collection_b.id},
            actor: ctx.admin_a,
            tenant: ctx.site_a.id
          )
          |> Ash.update()

        assert {:error, _} = updated
      end
    end

    test "Collection :create still takes its own site's parent", ctx do
      parent = create_collection!(site_id: ctx.site_a.id)

      assert {:ok, child} =
               Collection
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "Child",
                   slug: "child",
                   status: :active,
                   language: "en",
                   parent_collection_id: parent.id
                 },
                 actor: ctx.admin_a,
                 tenant: ctx.site_a.id
               )
               |> Ash.create()

      assert child.parent_collection_id == parent.id
    end

    test "Tag :create and :update refuse another site's parent and language group", ctx do
      tag_b = create_blog_tag!(site_id: ctx.site_b.id)
      own = create_blog_tag!(site_id: ctx.site_a.id)

      for field <- [:parent_tag_id, :language_group_id] do
        created =
          Tag
          |> Ash.Changeset.for_create(
            :create,
            %{name: "A", slug: "a-#{field}", language: "fa"} |> Map.put(field, tag_b.id),
            actor: ctx.admin_a,
            tenant: ctx.site_a.id
          )
          |> Ash.create()

        assert {:error, _} = created

        updated =
          own
          |> Ash.Changeset.for_update(:update, %{field => tag_b.id},
            actor: ctx.admin_a,
            tenant: ctx.site_a.id
          )
          |> Ash.update()

        assert {:error, _} = updated
      end
    end

    test "BlogPost :create and :update refuse another site's language group", ctx do
      post_b = create_blog_post!(site_id: ctx.site_b.id)
      own = create_blog_post!(site_id: ctx.site_a.id)

      created =
        BlogPost
        |> Ash.Changeset.for_create(
          :create,
          %{
            title: "A",
            slug: "a-post",
            content: "<p>A</p>",
            status: :draft,
            language: "fa",
            language_group_id: post_b.id
          },
          actor: ctx.admin_a,
          tenant: ctx.site_a.id
        )
        |> Ash.create()

      assert {:error, _} = created

      updated =
        own
        |> Ash.Changeset.for_update(:update, %{language_group_id: post_b.id},
          actor: ctx.admin_a,
          tenant: ctx.site_a.id
        )
        |> Ash.update()

      assert {:error, _} = updated
    end

    test "Blogger :create and :update refuse another site's user", ctx do
      user_b = create_user!(site_id: ctx.site_b.id)
      own = create_blogger!(site_id: ctx.site_a.id)

      created =
        Blogger
        |> Ash.Changeset.for_create(
          :create,
          %{user_id: user_b.id, display_name: "Borrowed", slug: "borrowed"},
          actor: ctx.admin_a,
          tenant: ctx.site_a.id
        )
        |> Ash.create()

      assert {:error, _} = created

      updated =
        own
        |> Ash.Changeset.for_update(:update, %{user_id: user_b.id},
          actor: ctx.admin_a,
          tenant: ctx.site_a.id
        )
        |> Ash.update()

      assert {:error, _} = updated
    end

    test "Comment :update refuses another site's user as the author", ctx do
      comment = create_comment!(site_id: ctx.site_a.id)
      user_b = create_user!(site_id: ctx.site_b.id)

      result =
        comment
        |> Ash.Changeset.for_update(:update, %{author_id: user_b.id},
          actor: ctx.admin_a,
          tenant: ctx.site_a.id
        )
        |> Ash.update()

      assert {:error, _} = result
      assert reload(Comment, comment).author_id == comment.author_id
    end

    test "Comment :update takes its own site's user as the author", ctx do
      comment = create_comment!(site_id: ctx.site_a.id)
      user_a = create_user!(site_id: ctx.site_a.id)

      assert {:ok, updated} =
               comment
               |> Ash.Changeset.for_update(:update, %{author_id: user_a.id},
                 actor: ctx.admin_a,
                 tenant: ctx.site_a.id
               )
               |> Ash.update()

      assert updated.author_id == user_a.id
    end

    test "PostView :create refuses another site's user as the viewer", ctx do
      post_a = create_blog_post!(site_id: ctx.site_a.id, status: :published)
      user_b = create_user!(site_id: ctx.site_b.id)
      user_a = create_user!(site_id: ctx.site_a.id)

      refused =
        PostView
        |> Ash.Changeset.for_create(
          :create,
          %{post_id: post_a.id, user_id: user_b.id, ip_address: "10.2.2.2"},
          tenant: ctx.site_a.id
        )
        |> Ash.create()

      assert {:error, _} = refused

      assert {:ok, _} =
               PostView
               |> Ash.Changeset.for_create(
                 :create,
                 %{post_id: post_a.id, user_id: user_a.id, ip_address: "10.2.2.3"},
                 tenant: ctx.site_a.id
               )
               |> Ash.create()
    end
  end

  describe "a site admin keeps its own site's rows whatever state their parent is in" do
    setup ctx do
      a = ctx.site_a.id
      visitor = create_user!(site_id: a)
      admin = create_user_with_permissions!(["admin:dashboard:*"], site_id: a)
      post = create_blog_post!(site_id: a, status: :published)
      tag = create_blog_tag!(site_id: a)
      blogger = create_blogger!(site_id: a)
      collection = create_collection!(site_id: a)
      team = create_team!(site_id: a, status: :active)
      comment = create_comment!(site_id: a, post_id: post.id)

      rows = %{
        PostTag => create_post_tag!(post_id: post.id, tag_id: tag.id),
        PostBlogger => create_post_blogger!(post_id: post.id, blogger_id: blogger.id),
        PostCollection => create_post_collection!(post_id: post.id, collection_id: collection.id),
        TeamPermission => create_team_permission!(team_id: team.id),
        TeamMember => create_team_member!(team_id: team.id, blogger_id: blogger.id),
        PostView => create_post_view!(post_id: post.id),
        TeamFollower => create_team_follower!(team_id: team.id, actor: visitor),
        PostBookmark => create_post_bookmark!(post_id: post.id, actor: visitor),
        PostRating => create_post_rating!(post_id: post.id, actor: visitor),
        CommentVote => create_comment_vote!(comment_id: comment.id, actor: visitor)
      }

      %{
        admin: admin,
        visitor: visitor,
        own_rows: rows,
        own_post: post,
        own_team: team,
        own_comment: comment
      }
    end

    defp archive!(resource, record) do
      resource
      |> Ash.get!(record.id, action: :master_get, authorize?: false)
      |> Ash.Changeset.for_destroy(:master_destroy, %{}, authorize?: false)
      |> Ash.destroy!()
    end

    defp keys_seen(resource, opts) do
      case Ash.read(resource, opts) do
        {:ok, rows} -> Enum.map(rows, &key/1)
        {:error, error} -> flunk("#{inspect(resource)} refused the read: #{inspect(error)}")
      end
    end

    test "after their post, team and comment are archived", ctx do
      archive!(BlogPost, ctx.own_post)
      archive!(Team, ctx.own_team)
      archive!(Comment, ctx.own_comment)
      opts = [actor: ctx.admin, tenant: ctx.site_a.id]

      for {resource, row} <- ctx.own_rows do
        assert key(row) in keys_seen(resource, opts),
               "#{inspect(resource)} hid a site admin's own row once its parent was archived"
      end

      for {resource, row} <- ctx.own_rows, resource != PostView do
        assert :ok = Ash.destroy(row, opts),
               "#{inspect(resource)} refused a site admin its own row once its parent was archived"
      end
    end

    test "while their post is a draft and their team is inactive", ctx do
      a = ctx.site_a.id
      post = create_blog_post!(site_id: a, status: :draft)
      team = create_team!(site_id: a, status: :inactive)
      opts = [actor: ctx.admin, tenant: a]

      rows = %{
        TeamFollower => create_team_follower!(team_id: team.id, actor: ctx.visitor),
        PostBookmark => create_post_bookmark!(post_id: post.id, actor: ctx.visitor),
        PostRating => create_post_rating!(post_id: post.id, actor: ctx.visitor)
      }

      for {resource, row} <- rows do
        assert key(row) in keys_seen(resource, opts),
               "#{inspect(resource)} hid a site admin's own row of an unpublished parent"

        assert :ok = Ash.destroy(row, opts),
               "#{inspect(resource)} refused a site admin its own row of an unpublished parent"
      end
    end

    test "with no tenant named", ctx do
      for {resource, row} <- ctx.own_rows do
        assert key(row) in keys_seen(resource, actor: ctx.admin),
               "#{inspect(resource)} hid a site admin's own row when no tenant was named"
      end
    end

    test "an archived post still counts its views, bookmarks and ratings", ctx do
      archive!(BlogPost, ctx.own_post)
      opts = [actor: ctx.admin, tenant: ctx.site_a.id]

      post =
        BlogPost
        |> Ash.Query.for_read(:get_archived, %{}, opts)
        |> Ash.Query.filter(id == ^ctx.own_post.id)
        |> Ash.Query.load([:view_count, :bookmark_count, :rating_count])
        |> Ash.read_one!()

      assert {post.view_count, post.bookmark_count, post.rating_count} == {1, 1, 1}
    end
  end

  describe "a site user who names another site as the tenant" do
    setup ctx do
      b = ctx.site_b.id
      user_b = create_user!(site_id: b)
      team_b = create_team!(site_id: b, status: :active)
      post_b = create_blog_post!(site_id: b, status: :published)
      blogger_b = create_blogger!(site_id: b)

      %{
        team_b: team_b,
        post_b: post_b,
        blogger_b: blogger_b,
        follow_b: create_team_follower!(team_id: team_b.id, actor: user_b),
        rating_b: create_post_rating!(post_id: post_b.id, actor: user_b),
        blogger_follow_b: create_blogger_follower!(blogger_id: blogger_b.id, actor: user_b)
      }
    end

    defp site_lists(ctx, actor, tenant) do
      opts = [actor: actor, tenant: tenant]

      [
        TeamFollower
        |> Ash.Query.for_read(:by_team, %{team_id: ctx.team_b.id}, opts)
        |> Ash.read(),
        PostRating
        |> Ash.Query.for_read(:by_post, %{post_id: ctx.post_b.id}, opts)
        |> Ash.read(),
        MishkaBlog.BloggerFollower
        |> Ash.Query.for_read(:by_blogger, %{blogger_id: ctx.blogger_b.id}, opts)
        |> Ash.read()
      ]
      |> Enum.map(&ids/1)
    end

    test "lists none of that site's team followers, ratings or blogger followers", ctx do
      assert site_lists(ctx, ctx.admin_a, ctx.site_b.id) == [[], [], []]
    end

    test "leaves those lists to that site's visitors and to a master", ctx do
      expected = [[ctx.follow_b.id], [ctx.rating_b.id], [ctx.blogger_follow_b.id]]

      assert site_lists(ctx, nil, ctx.site_b.id) == expected
      assert site_lists(ctx, ctx.master, ctx.site_b.id) == expected
    end

    test "those lists are empty when no site is named", ctx do
      assert site_lists(ctx, ctx.master, nil) == [[], [], []]
    end

    test "reads none of that site's records", ctx do
      b = ctx.site_b.id
      comment_b = create_comment!(site_id: b, post_id: ctx.post_b.id)

      records = %{
        AutoPosting => create_auto_posting!(site_id: b),
        BlogPost => create_blog_post!(site_id: b, status: :draft),
        Blogger => ctx.blogger_b,
        Collection => create_collection!(site_id: b),
        Comment => comment_b,
        Tag => create_blog_tag!(site_id: b),
        Team => ctx.team_b
      }

      for {resource, record_b} <- records do
        read =
          resource
          |> Ash.Query.for_read(:read, %{}, actor: ctx.admin_a, tenant: b)
          |> Ash.read()
          |> ids()

        refute record_b.id in read, "#{inspect(resource)} :read showed another site's row"
      end

      :ok = Ash.destroy(comment_b, action: :destroy, tenant: b, authorize?: false)

      archived =
        Comment
        |> Ash.Query.for_read(:get_archived, %{}, actor: ctx.admin_a, tenant: b)
        |> Ash.Query.filter(id == ^comment_b.id)
        |> Ash.read_one()
        |> ids()

      assert archived == []
    end

    test "changes none of that site's records", ctx do
      b = ctx.site_b.id

      records = %{
        AutoPosting => create_auto_posting!(site_id: b),
        BlogPost => create_blog_post!(site_id: b, status: :draft),
        Blogger => ctx.blogger_b,
        Collection => create_collection!(site_id: b),
        Comment => create_comment!(site_id: b, post_id: ctx.post_b.id),
        Tag => create_blog_tag!(site_id: b),
        Team => ctx.team_b
      }

      for {resource, record_b} <- records do
        opts = [actor: ctx.admin_a, tenant: b]

        assert {:error, _} =
                 record_b |> Ash.Changeset.for_update(:update, %{}, opts) |> Ash.update(),
               "#{inspect(resource)} :update changed another site's row"

        assert {:error, _} = Ash.destroy(record_b, [action: :destroy] ++ opts),
               "#{inspect(resource)} :destroy archived another site's row"

        assert is_nil(reload(resource, record_b).archived_at)
      end
    end
  end

  describe "join, follow, bookmark, rating, vote and view rows stay on their site" do
    setup ctx do
      a = ctx.site_a.id
      b = ctx.site_b.id
      post_a = create_blog_post!(site_id: a)
      post_b = create_blog_post!(site_id: b, status: :published)
      tag_a = create_blog_tag!(site_id: a)
      blogger_a = create_blogger!(site_id: a)
      collection_a = create_collection!(site_id: a)
      tag_b = create_blog_tag!(site_id: b)
      blogger_b = create_blogger!(site_id: b)
      collection_b = create_collection!(site_id: b)
      team_a = create_team!(site_id: a)
      team_b = create_team!(site_id: b)
      comment_b = create_comment!(site_id: b, post_id: post_b.id)
      user_b = create_user!(site_id: b)

      rows_b = %{
        PostTag => create_post_tag!(post_id: post_b.id, tag_id: tag_b.id),
        PostBlogger => create_post_blogger!(post_id: post_b.id, blogger_id: blogger_b.id),
        PostCollection =>
          create_post_collection!(post_id: post_b.id, collection_id: collection_b.id),
        TeamPermission => create_team_permission!(team_id: team_b.id),
        TeamMember => create_team_member!(team_id: team_b.id, blogger_id: blogger_b.id),
        PostView => create_post_view!(post_id: post_b.id, ip_address: "10.9.8.7"),
        TeamFollower => create_team_follower!(team_id: team_b.id, actor: user_b),
        PostBookmark => create_post_bookmark!(post_id: post_b.id, actor: user_b),
        PostRating => create_post_rating!(post_id: post_b.id, actor: user_b),
        CommentVote => create_comment_vote!(comment_id: comment_b.id, actor: user_b)
      }

      %{
        rows_b: rows_b,
        post_a: post_a,
        post_b: post_b,
        tag_a: tag_a,
        blogger_a: blogger_a,
        collection_a: collection_a,
        tag_b: tag_b,
        blogger_b: blogger_b,
        collection_b: collection_b,
        team_a: team_a,
        team_b: team_b
      }
    end

    test "a site user holding * reads none of another site's rows", ctx do
      for {resource, row_b} <- ctx.rows_b do
        keys =
          resource
          |> Ash.read(actor: ctx.admin_a)
          |> case do
            {:ok, rows} -> Enum.map(rows, &key/1)
            {:error, _} -> []
          end

        refute key(row_b) in keys, "#{inspect(resource)} showed a site user another site's row"
      end
    end

    test "a master reads every site's rows", ctx do
      for {resource, row_b} <- ctx.rows_b do
        keys = resource |> Ash.read!(actor: ctx.master) |> Enum.map(&key/1)

        assert key(row_b) in keys, "#{inspect(resource)} hid a row from a master"
      end
    end

    test "a site user holding * destroys none of another site's rows", ctx do
      for {resource, row_b} <- ctx.rows_b, resource != PostView do
        assert {:error, _} = Ash.destroy(row_b, actor: ctx.admin_a),
               "#{inspect(resource)} let a site user destroy another site's row"
      end
    end

    test "a site user holding * joins nothing of another site", ctx do
      tenant = [actor: ctx.admin_a, tenant: ctx.site_a.id]

      writes = [
        {PostTag, :assign, %{post_id: ctx.post_a.id, tag_id: ctx.tag_b.id}},
        {PostTag, :assign, %{post_id: ctx.post_b.id, tag_id: ctx.tag_a.id}},
        {PostBlogger, :assign, %{post_id: ctx.post_a.id, blogger_id: ctx.blogger_b.id}},
        {PostBlogger, :assign, %{post_id: ctx.post_b.id, blogger_id: ctx.blogger_a.id}},
        {PostCollection, :assign, %{post_id: ctx.post_a.id, collection_id: ctx.collection_b.id}},
        {PostCollection, :assign, %{post_id: ctx.post_b.id, collection_id: ctx.collection_a.id}},
        {TeamPermission, :assign,
         %{team_id: ctx.team_b.id, permission_id: create_permission!().id}},
        {TeamMember, :assign, %{team_id: ctx.team_a.id, blogger_id: ctx.blogger_b.id}},
        {TeamMember, :assign, %{team_id: ctx.team_b.id, blogger_id: ctx.blogger_a.id}},
        {PostView, :create, %{post_id: ctx.post_b.id, ip_address: "10.1.1.1"}}
      ]

      for {resource, action, params} <- writes do
        result =
          resource
          |> Ash.Changeset.for_create(action, params, tenant)
          |> Ash.create()

        assert {:error, _} = result, "#{inspect(resource)} #{inspect(params)} was accepted"
      end
    end

    test "a site user with no tenant joins nothing of another site", ctx do
      result =
        PostTag
        |> Ash.Changeset.for_create(:assign, %{post_id: ctx.post_b.id, tag_id: ctx.tag_b.id},
          actor: ctx.admin_a
        )
        |> Ash.create()

      assert {:error, _} = result
    end

    test "a follower list and a rating list answer only their own site", ctx do
      user_a = create_user!(site_id: ctx.site_a.id)

      followers =
        TeamFollower
        |> Ash.Query.for_read(:by_team, %{team_id: ctx.team_b.id},
          actor: user_a,
          tenant: ctx.site_a.id
        )
        |> Ash.read()

      ratings =
        PostRating
        |> Ash.Query.for_read(:by_post, %{post_id: ctx.post_b.id},
          actor: user_a,
          tenant: ctx.site_a.id
        )
        |> Ash.read()

      assert ids(followers) == []
      assert ids(ratings) == []
    end

    test "a system read still reads every site's rows", ctx do
      for {resource, row_b} <- ctx.rows_b do
        keys = resource |> Ash.read!(authorize?: false) |> Enum.map(&key/1)

        assert key(row_b) in keys
      end
    end
  end

  describe "restoring a version" do
    for {resource, version, factory, field} <- [
          {Tag, Tag.Version, :create_blog_tag!, :name},
          {Collection, Collection.Version, :create_collection!, :name},
          {Blogger, Blogger.Version, :create_blogger!, :display_name},
          {Team, Team.Version, :create_team!, :name},
          {AutoPosting, AutoPosting.Version, :create_auto_posting!, :name},
          {BlogPost, BlogPost.Version, :create_blog_post!, :title}
        ] do
      test "#{inspect(resource)}: a site user cannot restore another site's version", ctx do
        own = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_a.id]])
        theirs = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_b.id]])
        version = version_of(unquote(version), theirs)
        move_aside(theirs)

        result =
          unquote(resource)
          |> Ash.ActionInput.for_action(
            :restore_version_api,
            %{id: own.id, version_id: version.id},
            actor: ctx.admin_a,
            tenant: ctx.site_a.id
          )
          |> Ash.run_action()

        assert {:error, _} = result

        reloaded = reload(unquote(resource), own)
        assert Map.fetch!(reloaded, unquote(field)) == Map.fetch!(own, unquote(field))
        assert reloaded.site_id == ctx.site_a.id
      end

      test "#{inspect(resource)}: a restore takes only the record's own version", ctx do
        own = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_a.id]])
        sibling = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_a.id]])
        version = version_of(unquote(version), sibling)
        move_aside(sibling)

        for {action, opts} <- [
              restore_version: [tenant: ctx.site_a.id, authorize?: false],
              master_restore_version: [authorize?: false]
            ] do
          result =
            own
            |> Ash.Changeset.for_update(action, %{version_id: version.id}, opts)
            |> Ash.update()

          assert {:error, _} = result, "#{action} took another record's version"
        end

        reloaded = reload(unquote(resource), own)
        assert Map.fetch!(reloaded, unquote(field)) == Map.fetch!(own, unquote(field))
      end

      test "#{inspect(resource)}: a restore takes no attributes of its own", ctx do
        own = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_a.id]])
        version = version_of(unquote(version), own)

        result =
          own
          |> Ash.Changeset.for_update(
            :restore_version,
            %{version_id: version.id, site_id: ctx.site_b.id},
            tenant: ctx.site_a.id,
            authorize?: false
          )
          |> Ash.update()

        assert {:error, _} = result
        assert reload(unquote(resource), own).site_id == ctx.site_a.id
      end
    end
  end

  describe "version actions run as the caller" do
    for {resource, version, factory, field, preview} <- [
          {Tag, Tag.Version, :create_blog_tag!, :name, {:read, :tag_id}},
          {Collection, Collection.Version, :create_collection!, :name, {:read, :collection_id}},
          {Blogger, Blogger.Version, :create_blogger!, :display_name, {:action, :blogger_id}},
          {Team, Team.Version, :create_team!, :name, {:action, :team_id}},
          {AutoPosting, AutoPosting.Version, :create_auto_posting!, :name,
           {:action, :auto_posting_id}},
          {BlogPost, BlogPost.Version, :create_blog_post!, :title, {:action, :post_id}}
        ] do
      test "#{inspect(resource)}: a site user naming another site cannot preview its version",
           ctx do
        theirs = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_b.id]])
        version = version_of(unquote(version), theirs)
        {kind, record_argument} = unquote(preview)

        result =
          preview_as(
            kind,
            unquote(resource),
            :preview_version,
            %{record_argument => theirs.id, version_id: version.id},
            actor: ctx.admin_a,
            tenant: ctx.site_b.id
          )

        refute match?({:ok, %{id: _}}, result), "a site A user previewed a site B record"
      end

      test "#{inspect(resource)}: a site user naming another site cannot restore its version",
           ctx do
        theirs = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_b.id]])
        version = version_of(unquote(version), theirs)
        changed = change_field(theirs, unquote(field))

        result =
          unquote(resource)
          |> Ash.ActionInput.for_action(
            :restore_version_api,
            %{id: theirs.id, version_id: version.id},
            actor: ctx.admin_a,
            tenant: ctx.site_b.id
          )
          |> Ash.run_action()

        assert {:error, _} = result

        assert Map.fetch!(reload(unquote(resource), theirs), unquote(field)) ==
                 Map.fetch!(changed, unquote(field))
      end

      test "#{inspect(resource)}: a site user previews and restores its own site's version",
           ctx do
        own = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_a.id]])
        version = version_of(unquote(version), own)
        changed = change_field(own, unquote(field))
        {kind, record_argument} = unquote(preview)

        assert {:ok, %{} = previewed} =
                 preview_as(
                   kind,
                   unquote(resource),
                   :preview_version,
                   %{record_argument => own.id, version_id: version.id},
                   actor: ctx.admin_a,
                   tenant: ctx.site_a.id
                 )

        assert Map.fetch!(previewed, unquote(field)) == Map.fetch!(own, unquote(field))

        assert {:ok, restored} =
                 unquote(resource)
                 |> Ash.ActionInput.for_action(
                   :restore_version_api,
                   %{id: own.id, version_id: version.id},
                   actor: ctx.admin_a,
                   tenant: ctx.site_a.id
                 )
                 |> Ash.run_action()

        assert Map.fetch!(restored, unquote(field)) == Map.fetch!(own, unquote(field))
        refute Map.fetch!(restored, unquote(field)) == Map.fetch!(changed, unquote(field))
      end

      test "#{inspect(resource)}: a master previews and restores any site's version", ctx do
        theirs = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_b.id]])
        version = version_of(unquote(version), theirs)
        changed = change_field(theirs, unquote(field))
        {kind, record_argument} = unquote(preview)

        assert {:ok, %{} = previewed} =
                 preview_as(
                   kind,
                   unquote(resource),
                   :master_preview_version,
                   %{record_argument => theirs.id, version_id: version.id},
                   actor: ctx.master
                 )

        assert Map.fetch!(previewed, unquote(field)) == Map.fetch!(theirs, unquote(field))

        assert {:ok, restored} =
                 unquote(resource)
                 |> Ash.ActionInput.for_action(
                   :master_restore_version_api,
                   %{id: theirs.id, version_id: version.id},
                   actor: ctx.master
                 )
                 |> Ash.run_action()

        assert Map.fetch!(restored, unquote(field)) == Map.fetch!(theirs, unquote(field))
        refute Map.fetch!(restored, unquote(field)) == Map.fetch!(changed, unquote(field))
        assert restored.site_id == ctx.site_b.id
      end
    end

    defp change_field(record, field) do
      record
      |> Ash.Changeset.for_update(
        :master_update,
        %{field => "Changed #{System.unique_integer([:positive])}"},
        authorize?: false
      )
      |> Ash.update!()
    end

    defp preview_as(:read, resource, action, arguments, opts) do
      resource
      |> Ash.Query.for_read(action, arguments, opts)
      |> Ash.read_one()
    end

    defp preview_as(:action, resource, action, arguments, opts) do
      resource
      |> Ash.ActionInput.for_action(action, arguments, opts)
      |> Ash.run_action()
    end
  end

  describe "a version with no snapshot to restore" do
    for {resource, version, factory, field, preview} <- [
          {Tag, Tag.Version, :create_blog_tag!, :name, {:read, :tag_id}},
          {Collection, Collection.Version, :create_collection!, :name, {:read, :collection_id}},
          {Blogger, Blogger.Version, :create_blogger!, :display_name, {:action, :blogger_id}},
          {Team, Team.Version, :create_team!, :name, {:action, :team_id}},
          {AutoPosting, AutoPosting.Version, :create_auto_posting!, :name,
           {:action, :auto_posting_id}},
          {BlogPost, BlogPost.Version, :create_blog_post!, :title, {:action, :post_id}}
        ] do
      test "#{inspect(resource)}: its preview shows the record as it is and its restore changes nothing",
           ctx do
        record = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_a.id]])
        version = version_of(unquote(version), record)
        changed = change_field(record, unquote(field))

        version
        |> Ash.Changeset.for_update(:update, %{changes: nil}, authorize?: false)
        |> Ash.update!()

        {kind, record_argument} = unquote(preview)

        assert {:ok, %{} = previewed} =
                 preview_as(
                   kind,
                   unquote(resource),
                   :master_preview_version,
                   %{record_argument => record.id, version_id: version.id},
                   actor: ctx.master
                 )

        assert Map.fetch!(previewed, unquote(field)) == Map.fetch!(changed, unquote(field))

        assert {:ok, restored} =
                 unquote(resource)
                 |> Ash.ActionInput.for_action(
                   :master_restore_version_api,
                   %{id: record.id, version_id: version.id},
                   actor: ctx.master
                 )
                 |> Ash.run_action()

        assert Map.fetch!(restored, unquote(field)) == Map.fetch!(changed, unquote(field))
      end
    end
  end

  describe "a tag's and a collection's version preview" do
    for {resource, version, factory, field, record_argument, label} <- [
          {Tag, Tag.Version, :create_blog_tag!, :name, :tag_id, "tag"},
          {Collection, Collection.Version, :create_collection!, :name, :collection_id,
           "collection"}
        ],
        {action, scope} <- [
          {:preview_version, :site},
          {:master_preview_version, :master}
        ] do
      test "#{inspect(resource)} #{action}: another record's version is returned as the refusal",
           ctx do
        {opts, site} = preview_scope(unquote(scope), ctx)
        own = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: site.id]])
        sibling = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: site.id]])
        version = version_of(unquote(version), sibling)

        assert {:error, %Ash.Error.Invalid{} = error} =
                 unquote(resource)
                 |> Ash.Query.for_read(
                   unquote(action),
                   %{unquote(record_argument) => own.id, version_id: version.id},
                   opts
                 )
                 |> Ash.read_one()

        assert RestoreVersion.refusal(unquote(label)) in Enum.map(error.errors, & &1.message)
      end

      test "#{inspect(resource)} #{action}: a version that does not exist is an error", ctx do
        {opts, site} = preview_scope(unquote(scope), ctx)
        own = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: site.id]])

        assert {:error, %Ash.Error.Invalid{}} =
                 unquote(resource)
                 |> Ash.Query.for_read(
                   unquote(action),
                   %{unquote(record_argument) => own.id, version_id: Ash.UUID.generate()},
                   opts
                 )
                 |> Ash.read_one()
      end

      test "#{inspect(resource)} #{action}: the record's own version still previews", ctx do
        {opts, site} = preview_scope(unquote(scope), ctx)
        own = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: site.id]])
        version = version_of(unquote(version), own)
        changed = change_field(own, unquote(field))

        assert {:ok, previewed} =
                 unquote(resource)
                 |> Ash.Query.for_read(
                   unquote(action),
                   %{unquote(record_argument) => own.id, version_id: version.id},
                   opts
                 )
                 |> Ash.read_one()

        assert Map.fetch!(previewed, unquote(field)) == Map.fetch!(own, unquote(field))
        refute Map.fetch!(previewed, unquote(field)) == Map.fetch!(changed, unquote(field))
      end
    end

    defp preview_scope(:site, ctx), do: {[actor: ctx.admin_a, tenant: ctx.site_a.id], ctx.site_a}
    defp preview_scope(:master, ctx), do: {[actor: ctx.master], ctx.site_a}
  end

  describe "another record's version, in the admin's language" do
    setup do
      Gettext.put_locale(MishkaCmsCore.Gettext, "fa")
      :ok
    end

    for {resource, version, factory, preview, record_name} <- [
          {Tag, Tag.Version, :create_blog_tag!, {:read, :tag_id}, "tag"},
          {Collection, Collection.Version, :create_collection!, {:read, :collection_id},
           "collection"},
          {Blogger, Blogger.Version, :create_blogger!, {:action, :blogger_id}, "blogger profile"},
          {Team, Team.Version, :create_team!, {:action, :team_id}, "team"},
          {AutoPosting, AutoPosting.Version, :create_auto_posting!, {:action, :auto_posting_id},
           "auto-posting configuration"},
          {BlogPost, BlogPost.Version, :create_blog_post!, {:action, :post_id}, "blog post"}
        ] do
      test "#{inspect(resource)}: a restore through the API and a preview name the record", ctx do
        own = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_a.id]])
        sibling = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_a.id]])
        version = version_of(unquote(version), sibling)
        refusal = "[fa] Version does not belong to this [fa] #{unquote(record_name)}."

        restored =
          unquote(resource)
          |> Ash.ActionInput.for_action(
            :restore_version_api,
            %{id: own.id, version_id: version.id},
            actor: ctx.admin_a,
            tenant: ctx.site_a.id
          )
          |> Ash.run_action()

        assert refusal in messages(restored)

        {kind, record_argument} = unquote(preview)
        arguments = %{record_argument => own.id, version_id: version.id}
        assert refusal in messages(preview(kind, unquote(resource), arguments, ctx.site_a.id))
      end
    end

    defp preview(:read, resource, arguments, tenant) do
      resource
      |> Ash.Query.for_read(:preview_version, arguments, tenant: tenant, authorize?: false)
      |> Ash.read_one(authorize?: false)
    end

    defp preview(:action, resource, arguments, tenant) do
      resource
      |> Ash.ActionInput.for_action(:preview_version, arguments,
        tenant: tenant,
        authorize?: false
      )
      |> Ash.run_action()
    end

    defp messages({:error, error}) do
      error
      |> Ash.Error.to_error_class()
      |> Map.fetch!(:errors)
      |> Enum.map(&Map.get(&1, :message))
    end
  end

  describe "Blogger :comment_author" do
    test "a site user holding * cannot read it directly", ctx do
      blogger_b = create_blogger!(site_id: ctx.site_b.id)

      result =
        Blogger
        |> Ash.Query.for_read(:comment_author, %{}, actor: ctx.admin_a)
        |> Ash.read()

      refute blogger_b.id in ids(result)
    end

    test "a master reads it directly", ctx do
      blogger_b = create_blogger!(site_id: ctx.site_b.id)

      result =
        Blogger
        |> Ash.Query.for_read(:comment_author, %{}, actor: ctx.master)
        |> Ash.read()

      assert blogger_b.id in ids(result)
    end

    test "a comment still names its author on its own site", ctx do
      author = create_user!(site_id: ctx.site_a.id)
      blogger = create_blogger!(site_id: ctx.site_a.id, user_id: author.id)
      post = create_blog_post!(site_id: ctx.site_a.id)
      comment = create_comment!(site_id: ctx.site_a.id, post_id: post.id, author_id: author.id)

      loaded =
        Ash.load!(comment, [:author_profile], actor: ctx.admin_a, tenant: ctx.site_a.id)

      assert loaded.author_profile.id == blogger.id
    end
  end

  describe "version history" do
    for {version, factory} <- [
          {Tag.Version, :create_blog_tag!},
          {Collection.Version, :create_collection!},
          {Blogger.Version, :create_blogger!},
          {Team.Version, :create_team!},
          {AutoPosting.Version, :create_auto_posting!},
          {BlogPost.Version, :create_blog_post!}
        ] do
      test "#{inspect(version)}: a site user reads its own site's versions only", ctx do
        own = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_a.id]])
        theirs = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_b.id]])

        read =
          unquote(version)
          |> Ash.Query.for_read(:read_any, %{}, actor: ctx.admin_a)
          |> Ash.read()
          |> ids()

        assert version_of(unquote(version), own).id in read
        refute version_of(unquote(version), theirs).id in read
      end

      test "#{inspect(version)}: a master reads every site's versions", ctx do
        theirs = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_b.id]])

        read =
          unquote(version)
          |> Ash.Query.for_read(:read_any, %{}, actor: ctx.master)
          |> Ash.read()
          |> ids()

        assert version_of(unquote(version), theirs).id in read
      end

      test "#{inspect(version)}: no actor reads none", ctx do
        theirs = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_b.id]])

        read = unquote(version) |> Ash.Query.for_read(:read_any, %{}) |> Ash.read() |> ids()

        refute version_of(unquote(version), theirs).id in read
      end
    end

    for {resource, version, factory} <- [
          {Tag, Tag.Version, :create_blog_tag!},
          {Collection, Collection.Version, :create_collection!},
          {Blogger, Blogger.Version, :create_blogger!},
          {Team, Team.Version, :create_team!},
          {AutoPosting, AutoPosting.Version, :create_auto_posting!},
          {BlogPost, BlogPost.Version, :create_blog_post!}
        ] do
      test "#{inspect(resource)}: a site admin and a master read a record's own history", ctx do
        own = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_a.id]])
        version = version_of(unquote(version), own)
        move_aside(own)

        for {action, opts} <- [
              get_with_versions: [actor: ctx.admin_a, tenant: ctx.site_a.id],
              master_get_with_versions: [actor: ctx.master]
            ] do
          loaded =
            unquote(resource)
            |> Ash.Query.for_read(action, %{}, opts)
            |> Ash.Query.filter(id == ^own.id)
            |> Ash.read_one!()

          assert version.id in ids(loaded.sorted_versions), "#{action} hid the record's history"

          assert List.last(ids(loaded.sorted_versions)) == version.id,
                 "#{action} did not list the newest version first"
        end
      end
    end

    for {resource, version, factory, argument} <- [
          {Tag, Tag.Version, :create_blog_tag!, :tag_id},
          {Collection, Collection.Version, :create_collection!, :collection_id},
          {Blogger, Blogger.Version, :create_blogger!, :blogger_id},
          {Team, Team.Version, :create_team!, :team_id},
          {AutoPosting, AutoPosting.Version, :create_auto_posting!, :auto_posting_id},
          {BlogPost, BlogPost.Version, :create_blog_post!, :post_id}
        ] do
      test "#{inspect(resource)}: a site admin and a master list a record's own history", ctx do
        own = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_a.id]])
        version = version_of(unquote(version), own)

        for {action, opts} <- [
              list_versions: [actor: ctx.admin_a, tenant: ctx.site_a.id],
              master_list_versions: [actor: ctx.master]
            ] do
          [listed] =
            unquote(resource)
            |> Ash.Query.for_read(action, %{unquote(argument) => own.id}, opts)
            |> Ash.read!(page: [limit: 5])
            |> Map.fetch!(:results)

          assert version.id in ids(listed.sorted_versions), "#{action} hid the record's history"
        end
      end

      test "#{inspect(resource)}: another site's record loaded directly shows a site user none of its history",
           ctx do
        record_b = apply(MishkaBlog.Test.Factory, unquote(factory), [[site_id: ctx.site_b.id]])
        version = version_of(unquote(version), record_b)

        loaded =
          Ash.load!(
            record_b,
            [:sorted_versions, :latest_version, :recent_versions, :version_count],
            actor: ctx.admin_a,
            tenant: ctx.site_b.id,
            reuse_values?: true
          )

        refute version.id in ids(loaded.sorted_versions)

        # Under another site's tenant a site user holds no permission, so it gets what a visitor
        # gets: the history fields withheld.
        assert %Ash.ForbiddenField{} = loaded.latest_version
        assert %Ash.ForbiddenField{} = loaded.recent_versions
        assert %Ash.ForbiddenField{} = loaded.version_count
      end
    end

    for {resource, version, factory, params} <- [
          {Tag, Tag.Version, :create_blog_tag!, []},
          {Collection, Collection.Version, :create_collection!, [status: :active]},
          {Blogger, Blogger.Version, :create_blogger!, []},
          {Team, Team.Version, :create_team!, [status: :active]},
          {BlogPost, BlogPost.Version, :create_blog_post!, [status: :published]}
        ] do
      test "#{inspect(resource)}: a public record's history is not read through it", ctx do
        b = ctx.site_b.id
        params = Keyword.put(unquote(params), :site_id, b)
        record_b = apply(MishkaBlog.Test.Factory, unquote(factory), [params])
        version = version_of(unquote(version), record_b)

        for actor <- [nil, ctx.admin_a] do
          case public_read(unquote(resource), record_b, actor, b, [:sorted_versions]) do
            {:ok, [loaded]} ->
              refute version.id in ids(loaded.sorted_versions),
                     "#{inspect(actor && actor.id)} read another site's history"

            {:error, %Ash.Error.Forbidden{}} ->
              :refused_outright
          end
        end

        case public_read(unquote(resource), record_b, ctx.admin_a, b, @version_fields) do
          {:ok, [loaded]} ->
            assert %Ash.ForbiddenField{} = loaded.latest_version
            assert %Ash.ForbiddenField{} = loaded.recent_versions
            assert %Ash.ForbiddenField{} = loaded.version_count

          {:error, %Ash.Error.Forbidden{}} ->
            :refused_outright
        end

        assert {:ok, [hidden]} = public_read(unquote(resource), record_b, nil, b, @version_fields)
        assert %Ash.ForbiddenField{} = hidden.recent_versions
      end
    end
  end

  describe "Comment :permanent_destroy" do
    test "a site admin deletes its own archived comment for good", ctx do
      comment = create_comment!(site_id: ctx.site_a.id)
      opts = [actor: ctx.admin_a, tenant: ctx.site_a.id]

      :ok = Ash.destroy(comment, [action: :destroy] ++ opts)

      archived =
        Comment
        |> Ash.Query.for_read(:get_archived, %{}, opts)
        |> Ash.Query.filter(id == ^comment.id)
        |> Ash.read_one!()

      assert :ok = Ash.destroy(archived, [action: :permanent_destroy] ++ opts)
      assert {:error, _} = Ash.get(Comment, comment.id, action: :master_get, authorize?: false)
    end

    test "a master deletes any site's comment for good through master_permanent_destroy", ctx do
      created = create_comment!(site_id: ctx.site_b.id)
      comment = Ash.get!(Comment, created.id, action: :master_get, actor: ctx.master)

      assert :ok =
               Ash.destroy(comment, action: :master_permanent_destroy, actor: ctx.master)

      assert {:error, _} = Ash.get(Comment, created.id, action: :master_get, authorize?: false)
    end
  end
end
