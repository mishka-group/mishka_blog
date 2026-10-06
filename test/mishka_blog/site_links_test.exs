defmodule MishkaBlog.SiteLinksTest do
  @moduledoc """
  Which records a blog record may name by id, whoever writes it: a site user, a master or the system.

  A site's record names only records of its own site. A row with no site of its own — a join, a
  follow, a bookmark, a rating, a vote, a view — has the site of the record it hangs on, and joins or
  names only that site's records. A user a record names is one of that site's users or a master.
  Changing anything else on a record leaves its links alone.

  `MishkaBlog.SiteBoundaryTest` holds what an actor may reach; this holds one record to another.
  """
  use MishkaBlog.DataCase, async: false

  require Ash.Query

  alias MishkaBlog.{
    BlogPost,
    Blogger,
    BloggerFollower,
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
    TeamMember
  }

  @refused "is not one this site can use"

  # {resource, field, kind of record the field names}
  @links [
    {Tag, :parent_tag_id, :tag},
    {Tag, :language_group_id, :tag},
    {Collection, :parent_collection_id, :collection},
    {Collection, :language_group_id, :collection},
    {BlogPost, :language_group_id, :post},
    {Comment, :post_id, :post},
    {Comment, :parent_comment_id, :comment},
    {Comment, :author_id, :user},
    {Blogger, :user_id, :user}
  ]

  # The links a site user's `:create` takes from the actor, whatever it sends.
  @from_actor [{Comment, :author_id}]

  # {join resource, parent kind, parent field, other kind, other field}
  @joins [
    {PostTag, :post, :post_id, :tag, :tag_id},
    {PostBlogger, :post, :post_id, :blogger, :blogger_id},
    {PostCollection, :post, :post_id, :collection, :collection_id},
    {TeamMember, :team, :team_id, :blogger, :blogger_id}
  ]

  # {resource, argument, kind of record the ids name, join resource, join field}
  @arguments [
    {BlogPost, :tag_ids, :tag, PostTag, :tag_id},
    {BlogPost, :collection_ids, :collection, PostCollection, :collection_id},
    {BlogPost, :blogger_ids, :blogger, PostBlogger, :blogger_id},
    {Blogger, :team_ids, :team, TeamMember, :team_id},
    {Team, :member_ids, :blogger, TeamMember, :blogger_id}
  ]

  # {resource, parent kind, parent field, user field, other params}
  @user_rows [
    {PostBookmark, :post, :post_id, :user_id, %{}},
    {PostRating, :post, :post_id, :user_id, %{rating: 4}},
    {BloggerFollower, :blogger, :blogger_id, :follower_user_id, %{}},
    {TeamFollower, :team, :team_id, :follower_user_id, %{}},
    {CommentVote, :comment, :comment_id, :user_id, %{vote_type: :up}}
  ]

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

  defp make(:tag, site), do: create_blog_tag!(site_id: site.id)
  defp make(:collection, site), do: create_collection!(site_id: site.id, status: :active)
  defp make(:post, site), do: create_blog_post!(site_id: site.id, status: :published)
  defp make(:comment, site), do: create_comment!(site_id: site.id)
  defp make(:blogger, site), do: create_blogger!(site_id: site.id)
  defp make(:team, site), do: create_team!(site_id: site.id, status: :active)
  defp make(:user, site), do: create_user!(site_id: site.id)

  defp kind(Tag), do: :tag
  defp kind(Collection), do: :collection
  defp kind(BlogPost), do: :post
  defp kind(Comment), do: :comment
  defp kind(Blogger), do: :blogger
  defp kind(Team), do: :team

  # What a new record of `resource` on `site` needs, beside the link under test.
  defp new_attrs(resource, site) do
    n = System.unique_integer([:positive])

    case resource do
      Tag ->
        %{name: "Tag #{n}", slug: "tag-#{n}", language: "de"}

      Collection ->
        %{name: "Collection #{n}", slug: "collection-#{n}", status: :active, language: "de"}

      BlogPost ->
        %{title: "Post #{n}", slug: "post-#{n}", content: "<p>Post</p>", status: :draft}
        |> Map.put(:language, "de")

      Comment ->
        %{post_id: make(:post, site).id, content: "Hello there", status: :approved}

      Blogger ->
        %{user_id: make(:user, site).id, display_name: "Blogger #{n}", slug: "blogger-#{n}"}

      Team ->
        %{name: "Team #{n}", slug: "team-#{n}", status: :active}
    end
  end

  defp master_create(resource, site, params, master) do
    resource
    |> Ash.Changeset.for_create(
      :master_create,
      new_attrs(resource, site) |> Map.merge(params) |> Map.put(:site_id, site.id),
      actor: master
    )
    |> Ash.create()
  end

  @comment_master_update [:content, :status, :sender_data, :is_pinned, :parent_comment_id]

  # A master changes a record of any site: through `:master_update` on the record as a master reads
  # it, or, for a comment's field only the tenant action takes, through that action on the record's
  # own site.
  defp master_update(record, params, master) do
    if match?(%Comment{}, record) and
         Enum.any?(Map.keys(params), &(&1 not in @comment_master_update)) do
      record
      |> Ash.Changeset.for_update(:update, params, actor: master, tenant: record.site_id)
      |> Ash.update()
    else
      record
      |> reload()
      |> Ash.Changeset.for_update(:master_update, params, actor: master)
      |> Ash.update()
    end
  end

  # A record joining another language group takes a language that group has no edition in yet.
  defp relink(:language_group_id, id), do: %{language_group_id: id, language: "de"}
  defp relink(field, id), do: %{field => id}

  defp system_create(resource, site, params) do
    resource
    |> Ash.Changeset.for_create(:create, Map.merge(new_attrs(resource, site), params),
      tenant: site.id,
      authorize?: false
    )
    |> Ash.create()
  end

  defp assert_refused(result, what) do
    assert {:error, error} = result, "#{what} was accepted"
    assert Exception.message(error) =~ @refused, "#{what}: #{Exception.message(error)}"
  end

  # An archived record of the site itself is named as archived, so the admin knows to restore it.
  defp assert_refused_archived(result, what) do
    assert {:error, error} = result, "#{what} was accepted"

    assert Exception.message(error) =~ "is archived. Restore it first",
           "#{what}: #{Exception.message(error)}"
  end

  defp reload(record),
    do: Ash.get!(record.__struct__, record.id, action: :master_get, authorize?: false)

  describe "a site's record names only its own site's records" do
    for {resource, field, target} <- @links do
      @resource resource
      @field field
      @target target

      test "#{inspect(resource)}.#{field}: a master cannot create one naming another site's",
           ctx do
        theirs = make(@target, ctx.site_b)

        @resource
        |> master_create(ctx.site_a, %{@field => theirs.id}, ctx.master)
        |> assert_refused("#{inspect(@resource)}.#{@field} on :master_create")
      end

      test "#{inspect(resource)}.#{field}: a master cannot point one at another site's", ctx do
        record = make(kind(@resource), ctx.site_a)
        theirs = make(@target, ctx.site_b)

        record
        |> master_update(relink(@field, theirs.id), ctx.master)
        |> assert_refused("#{inspect(@resource)}.#{@field} on a master's update")

        assert Map.fetch!(reload(record), @field) == Map.fetch!(record, @field)
      end

      test "#{inspect(resource)}.#{field}: the system cannot write one naming another site's",
           ctx do
        theirs = make(@target, ctx.site_b)

        @resource
        |> system_create(ctx.site_a, %{@field => theirs.id})
        |> assert_refused("#{inspect(@resource)}.#{@field} on a system :create")
      end

      test "#{inspect(resource)}.#{field}: a site user cannot point one at another site's",
           ctx do
        record = make(kind(@resource), ctx.site_a)
        theirs = make(@target, ctx.site_b)

        result =
          record
          |> Ash.Changeset.for_update(:update, relink(@field, theirs.id),
            actor: ctx.admin_a,
            tenant: ctx.site_a.id
          )
          |> Ash.update()

        assert {:error, _} = result
        assert Map.fetch!(reload(record), @field) == Map.fetch!(record, @field)
      end

      test "#{inspect(resource)}.#{field}: a master links one to its own site's", ctx do
        ours = make(@target, ctx.site_a)

        assert {:ok, created} =
                 master_create(@resource, ctx.site_a, %{@field => ours.id}, ctx.master)

        assert Map.fetch!(created, @field) == ours.id

        record = make(kind(@resource), ctx.site_a)
        other = make(@target, ctx.site_a)

        assert {:ok, updated} = master_update(record, relink(@field, other.id), ctx.master)
        assert Map.fetch!(updated, @field) == other.id
      end

      test "#{inspect(resource)}.#{field}: a site user links one to its own site's", ctx do
        ours = make(@target, ctx.site_a)

        assert {:ok, created} =
                 site_create(@resource, ctx.site_a, %{@field => ours.id}, ctx.admin_a)

        assert Map.fetch!(created, @field) ==
                 if({@resource, @field} in @from_actor, do: ctx.admin_a.id, else: ours.id)

        record = make(kind(@resource), ctx.site_a)
        other = make(@target, ctx.site_a)

        assert {:ok, updated} = site_update(record, relink(@field, other.id), ctx.admin_a)
        assert Map.fetch!(updated, @field) == other.id
      end
    end

    for {resource, field} <- [{Comment, :author_id}, {Blogger, :user_id}] do
      @resource resource
      @field field

      test "#{inspect(resource)}.#{field}: a master and the system name a master, who acts on every site",
           ctx do
        master_user = create_user!()

        assert {:ok, created} =
                 master_create(@resource, ctx.site_a, %{@field => master_user.id}, ctx.master)

        assert Map.fetch!(created, @field) == master_user.id

        other_master = create_user!()

        assert {:ok, written} =
                 system_create(@resource, ctx.site_a, %{@field => other_master.id})

        assert Map.fetch!(written, @field) == other_master.id
      end
    end

    test "MishkaBlog.Comment.author_id: a site user names a master too", ctx do
      comment = make(:comment, ctx.site_a)
      master_user = create_user!()

      assert {:ok, updated} =
               comment
               |> Ash.Changeset.for_update(:update, %{author_id: master_user.id},
                 actor: ctx.admin_a,
                 tenant: ctx.site_a.id
               )
               |> Ash.update()

      assert updated.author_id == master_user.id
    end

    # Which account a profile belongs to is a master's to say when the account is a master's; see
    # `MishkaBlog.BloggerMasterProfileTest`.
    test "MishkaBlog.Blogger.user_id: a site user never names a master", ctx do
      profile = make(:blogger, ctx.site_a)
      master_user = create_user!()

      profile
      |> Ash.Changeset.for_update(:update, %{user_id: master_user.id},
        actor: ctx.admin_a,
        tenant: ctx.site_a.id
      )
      |> Ash.update()
      |> assert_refused("a site user pointing a blogger profile at a master")

      assert reload(profile).user_id == profile.user_id
    end

    test "changing anything else leaves a link as it is, one made before this rule included",
         ctx do
      tag = create_blog_tag!(site_id: ctx.site_a.id)
      theirs = create_blog_tag!(site_id: ctx.site_b.id)
      legacy = Ash.Seed.update!(tag, %{parent_tag_id: theirs.id}, tenant: ctx.site_a.id)

      assert {:ok, renamed} = master_update(legacy, %{name: "Renamed"}, ctx.master)
      assert renamed.name == "Renamed"
      assert renamed.parent_tag_id == theirs.id

      comment = create_comment!(site_id: ctx.site_a.id)
      user_b = create_user!(site_id: ctx.site_b.id)
      legacy_comment = Ash.Seed.update!(comment, %{author_id: user_b.id}, tenant: ctx.site_a.id)

      assert {:ok, edited} =
               legacy_comment
               |> Ash.Changeset.for_update(:update, %{content: "Edited content"},
                 actor: ctx.admin_a,
                 tenant: ctx.site_a.id
               )
               |> Ash.update()

      assert edited.author_id == user_b.id
    end

    test "restoring a version that named another site's record is refused", ctx do
      tag = create_blog_tag!(site_id: ctx.site_a.id)
      theirs = create_blog_tag!(site_id: ctx.site_b.id)
      legacy = Ash.Seed.update!(tag, %{parent_tag_id: theirs.id}, tenant: ctx.site_a.id)

      assert {:ok, _} = master_update(legacy, %{name: "Named another site's parent"}, ctx.master)

      version =
        MishkaBlog.Tag.Version
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
        |> Ash.Query.filter(version_source_id == ^tag.id)
        |> Ash.Query.sort(version_inserted_at: :desc)
        |> Ash.read!(authorize?: false)
        |> List.first()

      assert {:ok, _} = master_update(legacy, %{parent_tag_id: nil}, ctx.master)

      Tag
      |> Ash.ActionInput.for_action(
        :master_restore_version_api,
        %{id: tag.id, version_id: version.id},
        actor: ctx.master
      )
      |> Ash.run_action()
      |> assert_refused("a master restoring another site's parent")

      tag
      |> Ash.Changeset.for_update(:restore_version, %{version_id: version.id},
        actor: ctx.admin_a,
        tenant: ctx.site_a.id
      )
      |> Ash.update()
      |> assert_refused("a site user restoring another site's parent")

      assert is_nil(reload(tag).parent_tag_id)
    end

    test "a new record of a language group of its own takes its own id as the group", ctx do
      for resource <- [Tag, Collection, BlogPost] do
        assert {:ok, created} = master_create(resource, ctx.site_a, %{}, ctx.master)
        assert reload(created).language_group_id == created.id
      end
    end
  end

  describe "a join row joins two records of one site" do
    for {join, parent, parent_field, other, other_field} <- @joins do
      @join join
      @parent parent
      @parent_field parent_field
      @other other
      @other_field other_field

      test "#{inspect(join)}: a master with no site named cannot join two sites' records", ctx do
        for {parent_site, other_site} <- [{ctx.site_a, ctx.site_b}, {ctx.site_b, ctx.site_a}] do
          params = %{
            @parent_field => make(@parent, parent_site).id,
            @other_field => make(@other, other_site).id
          }

          @join
          |> Ash.Changeset.for_create(:assign, params, actor: ctx.master)
          |> Ash.create()
          |> assert_refused("#{inspect(@join)} joining two sites as a master")
        end
      end

      test "#{inspect(join)}: the system cannot join two sites' records", ctx do
        params = %{
          @parent_field => make(@parent, ctx.site_a).id,
          @other_field => make(@other, ctx.site_b).id
        }

        @join
        |> Ash.Changeset.for_create(:assign, params, authorize?: false)
        |> Ash.create()
        |> assert_refused("#{inspect(@join)} joining two sites as the system")

        assert %Ash.BulkResult{status: :error, errors: [error]} =
                 Ash.bulk_create([params], @join, :assign,
                   authorize?: false,
                   upsert_fields: :replace_all,
                   return_errors?: true
                 )

        assert Exception.message(error) =~ @refused
      end

      test "#{inspect(join)}: a site user cannot join its site's record to another's", ctx do
        params = %{
          @parent_field => make(@parent, ctx.site_a).id,
          @other_field => make(@other, ctx.site_b).id
        }

        result =
          @join
          |> Ash.Changeset.for_create(:assign, params, actor: ctx.admin_a, tenant: ctx.site_a.id)
          |> Ash.create()

        assert {:error, _} = result
      end

      test "#{inspect(join)}: a master and the system join one site's records", ctx do
        for opts <- [[actor: ctx.master], [authorize?: false]] do
          params = %{
            @parent_field => make(@parent, ctx.site_b).id,
            @other_field => make(@other, ctx.site_b).id
          }

          assert {:ok, row} =
                   @join
                   |> Ash.Changeset.for_create(:assign, params, opts)
                   |> Ash.create()

          assert Map.fetch!(row, @other_field) == params[@other_field]
        end
      end
    end

    for {resource, argument, target, join, join_field} <- @arguments do
      @resource resource
      @argument argument
      @target target
      @join join
      @join_field join_field

      test "#{inspect(resource)}.#{argument}: a master joins only the record's own site's", ctx do
        record = make(kind(@resource), ctx.site_a)
        theirs = make(@target, ctx.site_b)
        ours = make(@target, ctx.site_a)

        assert {:error, _} = master_update(record, %{@argument => [theirs.id]}, ctx.master)
        refute joined?(@join, @join_field, theirs.id)

        assert {:error, _} =
                 master_create(@resource, ctx.site_a, %{@argument => [theirs.id]}, ctx.master)

        refute joined?(@join, @join_field, theirs.id)

        assert {:ok, _} = master_update(record, %{@argument => [ours.id]}, ctx.master)
        assert joined?(@join, @join_field, ours.id)
      end

      test "#{inspect(resource)}.#{argument}: a site user joins only its own site's", ctx do
        record = make(kind(@resource), ctx.site_a)
        theirs = make(@target, ctx.site_b)
        ours = make(@target, ctx.site_a)
        assert {:error, _} = site_update(record, %{@argument => [theirs.id]}, ctx.admin_a)

        assert {:error, _} =
                 site_create(@resource, ctx.site_a, %{@argument => [theirs.id]}, ctx.admin_a)

        refute joined?(@join, @join_field, theirs.id)

        assert {:ok, _} = site_update(record, %{@argument => [ours.id]}, ctx.admin_a)
        assert joined?(@join, @join_field, ours.id)

        other = make(@target, ctx.site_a)

        assert {:ok, _} =
                 site_create(@resource, ctx.site_a, %{@argument => [other.id]}, ctx.admin_a)

        assert joined?(@join, @join_field, other.id)
      end
    end
  end

  # A site user's `:update` of its own site's record.
  defp site_update(record, params, actor) do
    record
    |> Ash.Changeset.for_update(:update, params, actor: actor, tenant: record.site_id)
    |> Ash.update()
  end

  # A site user's `:create` of a record on its own site.
  defp site_create(resource, site, params, actor) do
    resource
    |> Ash.Changeset.for_create(:create, Map.merge(new_attrs(resource, site), params),
      actor: actor,
      tenant: site.id
    )
    |> Ash.create()
  end

  defp joined?(join, field, id) do
    join
    |> Ash.Query.do_filter(%{field => id})
    |> Ash.exists?(authorize?: false)
  end

  # {resource, tenant action, argument, many?, kind of record it names, join resource, join field}
  @relationship_actions [
    {BlogPost, :assign_tags, :tag_ids, true, :tag, PostTag, :tag_id},
    {BlogPost, :add_tag, :tag_id, false, :tag, PostTag, :tag_id},
    {BlogPost, :assign_collections, :collection_ids, true, :collection, PostCollection,
     :collection_id},
    {BlogPost, :add_collection, :collection_id, false, :collection, PostCollection,
     :collection_id},
    {BlogPost, :assign_bloggers, :blogger_ids, true, :blogger, PostBlogger, :blogger_id},
    {BlogPost, :add_blogger, :blogger_id, false, :blogger, PostBlogger, :blogger_id},
    {Tag, :assign_posts, :post_ids, true, :post, PostTag, :post_id},
    {Tag, :add_post, :post_id, false, :post, PostTag, :post_id},
    {Collection, :assign_posts, :post_ids, true, :post, PostCollection, :post_id},
    {Collection, :add_post, :post_id, false, :post, PostCollection, :post_id},
    {Blogger, :assign_teams, :team_ids, true, :team, TeamMember, :team_id},
    {Blogger, :add_team, :team_id, false, :team, TeamMember, :team_id},
    {Team, :assign_members, :blogger_ids, true, :blogger, TeamMember, :blogger_id},
    {Team, :add_member, :blogger_id, false, :blogger, TeamMember, :blogger_id}
  ]

  defp relate(record, action, argument, many?, id, actor, tenant) do
    record
    |> Ash.Changeset.for_update(action, %{argument => if(many?, do: [id], else: id)},
      actor: actor,
      tenant: tenant
    )
    |> Ash.update()
  end

  describe "a record's own relationship actions join only its own site's records" do
    for {resource, action, argument, many?, target, join, join_field} <- @relationship_actions do
      @resource resource
      @action action
      @argument argument
      @many? many?
      @target target
      @join join
      @join_field join_field

      test "#{inspect(resource)} #{inspect(action)} joins no other site's record", ctx do
        record = make(kind(@resource), ctx.site_a)
        theirs = make(@target, ctx.site_b)

        for actor <- [ctx.master, ctx.admin_a] do
          assert {:error, _} =
                   relate(record, @action, @argument, @many?, theirs.id, actor, ctx.site_a.id)

          refute joined?(@join, @join_field, theirs.id)
        end
      end

      test "#{inspect(resource)} #{inspect(action)} joins its own site's record", ctx do
        record = make(kind(@resource), ctx.site_a)

        for actor <- [ctx.master, ctx.admin_a] do
          ours = make(@target, ctx.site_a)

          assert {:ok, _} =
                   relate(record, @action, @argument, @many?, ours.id, actor, ctx.site_a.id)

          assert joined?(@join, @join_field, ours.id)
        end
      end
    end
  end

  describe "a row a user makes names a user of its record's site, or a master" do
    for {resource, parent, parent_field, user_field, params} <- @user_rows do
      @resource resource
      @parent parent
      @parent_field parent_field
      @user_field user_field
      @params params

      test "#{inspect(resource)}: never another site's user, even when the system writes it",
           ctx do
        record = make(@parent, ctx.site_a)
        user_b = create_user!(site_id: ctx.site_b.id)

        @resource
        |> Ash.Changeset.for_create(:create, Map.put(@params, @parent_field, record.id),
          actor: user_b,
          authorize?: false
        )
        |> Ash.create()
        |> assert_refused("#{inspect(@resource)} naming another site's user")
      end

      test "#{inspect(resource)}: its own site's user and a master", ctx do
        record = make(@parent, ctx.site_a)

        for user <- [create_user!(site_id: ctx.site_a.id), ctx.master] do
          assert {:ok, row} =
                   @resource
                   |> Ash.Changeset.for_create(
                     :create,
                     Map.put(@params, @parent_field, record.id),
                     actor: user,
                     authorize?: false
                   )
                   |> Ash.create()

          assert Map.fetch!(row, @user_field) == user.id
        end
      end
    end

    test "CommentVote :create_for_user names no other site's user", ctx do
      comment = create_comment!(site_id: ctx.site_a.id)
      vote = fn user -> %{comment_id: comment.id, user_id: user.id, vote_type: :down} end

      CommentVote
      |> Ash.Changeset.for_create(:create_for_user, vote.(create_user!(site_id: ctx.site_b.id)),
        actor: ctx.master
      )
      |> Ash.create()
      |> assert_refused("CommentVote :create_for_user naming another site's user")

      for user <- [create_user!(site_id: ctx.site_a.id), create_user!()] do
        assert {:ok, _} =
                 CommentVote
                 |> Ash.Changeset.for_create(:create_for_user, vote.(user), actor: ctx.master)
                 |> Ash.create()
      end
    end

    test "PostView names no other site's user, and counts a master's view", ctx do
      post = create_blog_post!(site_id: ctx.site_a.id, status: :published)
      view = fn user, ip -> %{post_id: post.id, user_id: user.id, ip_address: ip} end

      PostView
      |> Ash.Changeset.for_create(
        :create,
        view.(create_user!(site_id: ctx.site_b.id), "10.3.3.1"),
        authorize?: false
      )
      |> Ash.create()
      |> assert_refused("PostView naming another site's user")

      for {user, ip} <- [
            {create_user!(site_id: ctx.site_a.id), "10.3.3.2"},
            {create_user!(), "10.3.3.3"}
          ] do
        assert {:ok, _} =
                 PostView
                 |> Ash.Changeset.for_create(:create, view.(user, ip), tenant: ctx.site_a.id)
                 |> Ash.create()
      end
    end

    test "turning notifications off leaves a follow as it is", ctx do
      follow = create_blogger_follower!(blogger_id: make(:blogger, ctx.site_a).id)

      assert {:ok, updated} =
               follow
               |> Ash.Changeset.for_update(:toggle_notifications, %{notification_enabled: false},
                 authorize?: false
               )
               |> Ash.update()

      assert updated.follower_user_id == follow.follower_user_id
    end
  end

  # A public comment by a user of `site` on `post`, which the relinking plugin rewrites to `relink`.
  defp public_comment(site, post, relink) do
    content = "Relinked #{System.unique_integer([:positive])}"

    result =
      Comment
      |> Ash.Changeset.for_create(:create_public, %{post_id: post.id, content: content},
        tenant: site.id,
        actor: create_user!(site_id: site.id),
        authorize?: false,
        context: %{relink: relink}
      )
      |> Ash.create()

    {result, content}
  end

  defp written?(resource, site, field, value) do
    resource
    |> Ash.Query.do_filter(%{field => value})
    |> Ash.exists?(tenant: site.id, authorize?: false)
  end

  describe "what a plugin writes before a create names only its own site's records" do
    for {field, target} <- [post_id: :post, parent_comment_id: :comment, author_id: :user] do
      @field field
      @target target

      test "a public comment's #{field} a plugin sets", ctx do
        with_plugin(
          MishkaBlog.Test.Plugins.BlogCommentBeforeCreatePublicRelink,
          "blog:comment:before_create_public",
          fn ->
            post = make(:post, ctx.site_a)
            theirs = make(@target, ctx.site_b)

            {result, content} = public_comment(ctx.site_a, post, %{@field => theirs.id})

            assert_refused(result, "a plugin setting a public comment's #{@field}")
            refute written?(Comment, ctx.site_a, :content, content)
          end
        )
      end
    end

    test "a public comment a plugin moves to its own site's post and a master", ctx do
      with_plugin(
        MishkaBlog.Test.Plugins.BlogCommentBeforeCreatePublicRelink,
        "blog:comment:before_create_public",
        fn ->
          other_post = make(:post, ctx.site_a)
          master_user = create_user!()

          {result, _content} =
            public_comment(ctx.site_a, make(:post, ctx.site_a), %{
              post_id: other_post.id,
              author_id: master_user.id
            })

          assert {:ok, comment} = result
          assert {comment.post_id, comment.author_id} == {other_post.id, master_user.id}
        end
      )
    end

    test "a post's language group a plugin sets", ctx do
      with_plugin(
        MishkaBlog.Test.Plugins.BlogPostBeforeCreateRelink,
        "blog:blog_post:before_create",
        fn ->
          # A translation of one of the site's posts, which the plugin moves to `group`.
          create = fn group ->
            attrs =
              BlogPost
              |> new_attrs(ctx.site_a)
              |> Map.put(:language_group_id, make(:post, ctx.site_a).id)

            result =
              BlogPost
              |> Ash.Changeset.for_create(:create, attrs,
                tenant: ctx.site_a.id,
                actor: ctx.admin_a,
                context: %{relink: %{language_group_id: group.id}}
              )
              |> Ash.create()

            {result, attrs.slug}
          end

          {result, slug} = create.(make(:post, ctx.site_b))
          assert_refused(result, "a plugin setting a post's language group")
          refute written?(BlogPost, ctx.site_a, :slug, slug)

          ours = make(:post, ctx.site_a)
          assert {{:ok, post}, _slug} = create.(ours)
          assert post.language_group_id == ours.id
        end
      )
    end

    # Every action that hands a plugin its changeset before the write is a create, and each link
    # its resource checks when the changeset is built is checked again after the plugin has run.
    test "every action a plugin rewrites checks its links after the plugin" do
      hooked =
        for resource <- Ash.Domain.Info.resources(MishkaBlog),
            action <- Ash.Resource.Info.actions(resource),
            Enum.any?(
              Map.get(action, :changes, []),
              &match?(
                %Ash.Resource.Change{
                  change: {MishkaCmsCore.Runtime.Resources.Changes.PluginBeforeHook, _}
                },
                &1
              )
            ),
            do: {resource, action}

      assert {BlogPost, :create} in Enum.map(hooked, fn {r, a} -> {r, a.name} end)
      assert {Comment, :create_public} in Enum.map(hooked, fn {r, a} -> {r, a.name} end)

      for {resource, action} <- hooked do
        assert action.type == :create, "#{inspect(resource)} #{action.name} is not a create"

        checks =
          for %{validation: {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference, opts}} =
                validation <- Ash.Resource.Info.validations(resource),
              do: {opts[:field], validation.before_action?, validation.on}

        for {field, false, _on} <- checks do
          assert Enum.any?(checks, fn {f, after_plugin?, on} ->
                   f == field and after_plugin? and :create in on
                 end),
                 "#{inspect(resource)}.#{field} is not checked after #{action.name}'s plugin"
        end
      end
    end
  end

  # AN ORIGINAL ARCHIVED UNDER A LIVE EDITION can no longer be made through the archive actions, which
  # refuse it; it still exists in data archived before that rule. Written straight to the row, as that
  # data would be.
  defp archived_before_the_rule!(record) do
    resource = record.__struct__
    repo = AshPostgres.DataLayer.Info.repo(resource)
    table = AshPostgres.DataLayer.Info.table(resource)

    Ecto.Adapters.SQL.query!(repo, "UPDATE #{table} SET archived_at = now() WHERE id = $1", [
      Ecto.UUID.dump!(record.id)
    ])

    record
  end

  defp archive!(record) do
    :ok = Ash.destroy(record, action: :destroy, tenant: record.site_id, authorize?: false)
    record
  end

  describe "a link names a live record of its own site, whoever writes it" do
    for {resource, field, target} <- @links, target != :user do
      @resource resource
      @field field
      @target target

      test "#{inspect(resource)}.#{field}: never an archived one", ctx do
        archived = archive!(make(@target, ctx.site_a))

        @resource
        |> master_create(ctx.site_a, %{@field => archived.id}, ctx.master)
        |> assert_refused_archived(
          "#{inspect(@resource)}.#{@field} naming an archived record, as a master"
        )

        @resource
        |> system_create(ctx.site_a, %{@field => archived.id})
        |> assert_refused_archived(
          "#{inspect(@resource)}.#{@field} naming an archived record, as the system"
        )

        assert {:error, _} =
                 site_create(@resource, ctx.site_a, %{@field => archived.id}, ctx.admin_a)

        record = make(kind(@resource), ctx.site_a)

        record
        |> master_update(relink(@field, archived.id), ctx.master)
        |> assert_refused_archived(
          "#{inspect(@resource)}.#{@field} pointed at an archived record"
        )

        assert Map.fetch!(reload(record), @field) == Map.fetch!(record, @field)
      end
    end

    for {join, parent, parent_field, other, other_field} <- @joins do
      @join join
      @parent parent
      @parent_field parent_field
      @other other
      @other_field other_field

      test "#{inspect(join)}: joins no archived record", ctx do
        params = %{
          @parent_field => make(@parent, ctx.site_a).id,
          @other_field => archive!(make(@other, ctx.site_a)).id
        }

        for opts <- [[actor: ctx.master], [authorize?: false]] do
          @join
          |> Ash.Changeset.for_create(:assign, params, opts)
          |> Ash.create()
          |> assert_refused_archived("#{inspect(@join)} joining an archived record")
        end

        refute joined?(@join, @other_field, params[@other_field])
      end
    end
  end

  # A new edition of `first`, whose site is `site`, in another language.
  defp edition!(first, site, master) do
    {:ok, edition} = master_create(first.__struct__, site, %{language_group_id: first.id}, master)
    edition
  end

  defp gone?(record),
    do:
      not match?(
        {:ok, _},
        Ash.get(record.__struct__, record.id, action: :master_get, authorize?: false)
      )

  describe "a language group's first edition goes last and comes back first" do
    for resource <- [Tag, Collection, BlogPost] do
      @resource resource

      test "#{inspect(resource)}: never deleted for good under a live edition", ctx do
        first = make(kind(@resource), ctx.site_a)
        edition = edition!(first, ctx.site_a, ctx.master)

        assert {:error, _} =
                 Ash.destroy(reload(first), action: :master_permanent_destroy, actor: ctx.master)

        assert {:error, _} =
                 Ash.destroy(first,
                   action: :permanent_destroy,
                   actor: ctx.admin_a,
                   tenant: ctx.site_a.id
                 )

        refute gone?(first)

        assert :ok =
                 Ash.destroy(reload(edition),
                   action: :master_permanent_destroy,
                   actor: ctx.master
                 )

        assert :ok =
                 Ash.destroy(reload(first), action: :master_permanent_destroy, actor: ctx.master)

        assert gone?(first)
      end

      test "#{inspect(resource)}: never archived under a live edition", ctx do
        first = make(kind(@resource), ctx.site_a)
        edition = edition!(first, ctx.site_a, ctx.master)

        for result <- [
              Ash.destroy(reload(first), action: :master_destroy, actor: ctx.master),
              Ash.destroy(reload(first),
                action: :destroy,
                actor: ctx.admin_a,
                tenant: ctx.site_a.id
              ),
              Ash.destroy(reload(first),
                action: :destroy,
                tenant: ctx.site_a.id,
                authorize?: false
              )
            ] do
          assert {:error, error} = result

          assert Exception.message(error) =~
                   "translation is still live, so it can't be deleted yet. Archive or delete " <>
                     "that translation first, then this one."
        end

        assert reload(first)

        assert :ok = Ash.destroy(reload(edition), action: :master_destroy, actor: ctx.master)
        assert :ok = Ash.destroy(reload(first), action: :master_destroy, actor: ctx.master)
      end

      test "#{inspect(resource)}: an edition comes back only under a live first edition", ctx do
        first = make(kind(@resource), ctx.site_a)
        edition = edition!(first, ctx.site_a, ctx.master)

        archive!(edition)
        archive!(first)

        restore = fn record ->
          record
          |> reload()
          |> Ash.Changeset.for_update(:master_unarchive, %{}, actor: ctx.master)
          |> Ash.update()
        end

        assert {:error, _} = restore.(edition)
        refute is_nil(reload(edition).archived_at)

        assert {:ok, _} = restore.(first)
        assert {:ok, _} = restore.(edition)
        assert is_nil(reload(edition).archived_at)
      end
    end
  end

  # {form's resource, field, resource it lists, kind of record it lists}
  @pickers [
    {Tag, :parent_tag_id, Tag, :tag},
    {Tag, :language_group_id, Tag, :tag},
    {Collection, :parent_collection_id, Collection, :collection},
    {Collection, :language_group_id, Collection, :collection},
    {BlogPost, :language_group_id, BlogPost, :post},
    {BlogPost, :collection_ids, Collection, :collection},
    {BlogPost, :tag_ids, Tag, :tag},
    {BlogPost, :blogger_ids, Blogger, :blogger},
    {Comment, :post_id, BlogPost, :post},
    {Comment, :parent_comment_id, Comment, :comment},
    {Comment, :author_id, MishkaCmsCore.Accounts.User, :user},
    {Blogger, :user_id, MishkaCmsCore.Accounts.User, :user},
    {Blogger, :team_ids, Team, :team}
  ]

  # The ids a form's picker offers `user`, with the site field set to `site` for a master: the
  # site picked on a new record, the record's own site on an edit.
  defp offered(resource, field_name, lists, user, site) do
    state = MishkaGervaz.Form.Web.State.init("site-links", resource, user)
    state = MishkaGervaz.Form.Web.State.update(state, field_values: %{site_id: site.id})
    field = Enum.find(state.static.fields, &(&1.name == field_name))

    {:ok, options, _more?} =
      MishkaGervaz.Form.Web.DataLoader.RelationLoader.load_paginated_options(
        field,
        state,
        lists,
        field.display_field,
        1,
        nil
      )

    {field, options |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1)}
  end

  defp value(%{language_group_id: group}, :language_group_id), do: group
  defp value(record, _field), do: record.id

  describe "an edition whose first edition is archived keeps its group" do
    for {resource, rename} <- [{Tag, :name}, {BlogPost, :title}] do
      @resource resource
      @rename rename

      test "#{inspect(resource)}: an edit that sends the group it has is saved", ctx do
        first = make(kind(@resource), ctx.site_a)
        edition = edition!(first, ctx.site_a, ctx.master)
        archived_before_the_rule!(first)

        params = %{@rename => "Edited #{@rename}", :language_group_id => first.id}

        assert {:ok, edited} = site_update(edition, params, ctx.admin_a)
        assert {:ok, _} = master_update(edited, params, ctx.master)
        assert reload(edition).language_group_id == first.id
      end
    end
  end

  # The ids a list's relation filter offers `user`, with the Site filter set to `sites`.
  defp filter_offers(resource, filter_name, lists, user, sites) do
    state = MishkaGervaz.Table.Web.State.init("site-links", resource, user)

    values =
      if sites == [],
        do: Map.delete(state.filter_values, :site_id),
        else: Map.put(state.filter_values, :site_id, Enum.map(sites, & &1.id))

    state = MishkaGervaz.Table.Web.State.update(state, filter_values: values)
    filter = Enum.find(state.static.filters, &(&1.name == filter_name))

    {:ok, %{options: options}} =
      MishkaGervaz.Table.Web.DataLoader.RelationLoader.load_paginated_options(
        filter,
        state,
        lists,
        filter.display_field,
        1,
        nil
      )

    Enum.map(options, &elem(&1, 1))
  end

  describe "a list's relation filter offers the records of the sites the list shows" do
    for {resource, filter_name, lists, target} <- [
          {BlogPost, :collection_id, Collection, :collection},
          {Comment, :post_id, BlogPost, :post}
        ] do
      @resource resource
      @filter_name filter_name
      @lists lists
      @target target

      test "#{inspect(resource)} #{filter_name}", ctx do
        ours = make(@target, ctx.site_a)
        theirs = make(@target, ctx.site_b)

        picked = filter_offers(@resource, @filter_name, @lists, ctx.master, [ctx.site_a])
        assert ours.id in picked
        refute theirs.id in picked

        every_site = filter_offers(@resource, @filter_name, @lists, ctx.master, [])
        assert ours.id in every_site
        assert theirs.id in every_site

        own_site = filter_offers(@resource, @filter_name, @lists, ctx.admin_a, [ctx.site_b])
        assert ours.id in own_site
        refute theirs.id in own_site
      end
    end
  end

  describe "a language group picker offers each live group once, by its first edition" do
    for resource <- [Tag, Collection, BlogPost] do
      @resource resource

      test "#{inspect(resource)}", ctx do
        first = make(kind(@resource), ctx.site_a)
        _edition = edition!(first, ctx.site_a, ctx.master)
        archived = archive!(make(kind(@resource), ctx.site_a))

        for {user, site} <- [{ctx.master, ctx.site_a}, {ctx.admin_a, ctx.site_a}] do
          {_field, groups} = offered(@resource, :language_group_id, @resource, user, site)

          assert Enum.count(groups, &(&1 == first.id)) == 1
          refute archived.id in groups
        end
      end
    end
  end

  describe "an admin form's picker offers only the record's own site's records" do
    for {resource, field, lists, target} <- @pickers do
      @resource resource
      @field field
      @lists lists
      @target target

      test "#{inspect(resource)}.#{field}", ctx do
        ours = make(@target, ctx.site_a)
        theirs = make(@target, ctx.site_b)

        {field, for_master} = offered(@resource, @field, @lists, ctx.master, ctx.site_a)
        {_field, for_site_user} = offered(@resource, @field, @lists, ctx.admin_a, ctx.site_b)

        assert field.depends_on == :site_id
        assert value(ours, @field) in for_master
        refute value(theirs, @field) in for_master
        assert value(ours, @field) in for_site_user
        refute value(theirs, @field) in for_site_user
      end
    end
  end
end
