defmodule MishkaBlog.Test.AreaPermissionsTest do
  @moduledoc """
  Every blog resource's data asks for the blog area it belongs to, on the surface the request came
  from: `admin:<surface>:blog:post` for the editorial side and its join, version and engagement rows,
  `admin:<surface>:blog:comment` for comments and comment votes.

  Each gate is driven with three site admins of one site: one holding only the area (allowed), one
  holding only the blog's other area and one holding only an unrelated area (both refused). The
  surface is the dashboard unless the call's shared context says `admin_surface: :api`, where only
  the `admin:api:` name is held.
  """
  use MishkaBlog.DataCase, async: false

  require Ash.Query

  alias MishkaBlog.{
    AutoPosting,
    Blogger,
    BlogPost,
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

  @post "admin:dashboard:blog:post"
  @comment "admin:dashboard:blog:comment"
  @unrelated "admin:dashboard:runtime:page"
  @api %{shared: %{admin_surface: :api}}

  setup do
    site = create_site!()

    %{
      site: site,
      editor: create_user_with_permissions!([@post], site_id: site.id),
      moderator: create_user_with_permissions!([@comment], site_id: site.id),
      outsider: create_user_with_permissions!([@unrelated], site_id: site.id)
    }
  end

  # Whether `actor` reads `record` through `resource`'s `action`, as the request's `context` names it.
  defp reads?(resource, record, actor, opts \\ []) do
    key = Map.take(record, Ash.Resource.Info.primary_key(resource))

    resource
    |> Ash.Query.for_read(Keyword.get(opts, :action, :read), %{},
      actor: actor,
      tenant: Keyword.get(opts, :tenant, record_tenant(record)),
      context: Keyword.get(opts, :context, %{})
    )
    |> Ash.Query.do_filter(Map.to_list(key))
    |> Ash.read()
    |> case do
      {:ok, rows} -> Enum.any?(rows, &(Map.take(&1, Map.keys(key)) == key))
      {:error, %Ash.Error.Forbidden{}} -> false
    end
  end

  defp record_tenant(%{site_id: site_id}), do: site_id
  defp record_tenant(_join_row), do: nil

  describe "the editorial side asks for admin:dashboard:blog:post" do
    setup %{site: site} do
      post = create_blog_post!(site_id: site.id)
      blogger = create_blogger!(site_id: site.id)
      team = create_team!(site_id: site.id)
      tag = create_blog_tag!(site_id: site.id)

      %{
        rows: [
          {BlogPost, post},
          {Collection, create_collection!(site_id: site.id)},
          {Tag, tag},
          {Blogger, blogger},
          {Team, team},
          {AutoPosting, create_auto_posting!(site_id: site.id)}
        ],
        joins: [
          {PostTag, create_post_tag!(post_id: post.id, tag_id: tag.id)},
          {PostCollection,
           create_post_collection!(
             post_id: post.id,
             collection_id: create_collection!(site_id: site.id).id
           )},
          {PostBlogger, create_post_blogger!(post_id: post.id, blogger_id: blogger.id)},
          {TeamMember, create_team_member!(team_id: team.id, blogger_id: blogger.id)},
          {TeamPermission, create_team_permission!(team_id: team.id)}
        ],
        engagement: [
          {PostView, create_post_view!(post_id: post.id)},
          {PostRating, create_post_rating!(post_id: post.id)},
          {PostBookmark, create_post_bookmark!(post_id: post.id)},
          {TeamFollower, create_team_follower!(team_id: team.id)}
        ]
      }
    end

    test "a holder of the post area alone reads every editorial row", ctx do
      for {resource, record} <- ctx.rows ++ ctx.joins ++ ctx.engagement do
        assert reads?(resource, record, ctx.editor), "#{inspect(resource)} refused an editor"
      end
    end

    test "a comment moderator and an unrelated admin read none of them", ctx do
      for {resource, record} <- ctx.rows ++ ctx.joins ++ ctx.engagement,
          actor <- [ctx.moderator, ctx.outsider] do
        refute reads?(resource, record, actor),
               "#{inspect(resource)} let #{actor_name(ctx, actor)} read it"
      end
    end

    test "writing needs the area too", %{site: site} = ctx do
      create = fn actor ->
        BlogPost
        |> Ash.Changeset.for_create(
          :create,
          %{
            title: "Area",
            slug: "area-#{System.unique_integer([:positive])}",
            content: "<p>x</p>"
          },
          actor: actor,
          tenant: site.id
        )
        |> Ash.create()
      end

      assert {:ok, _post} = create.(ctx.editor)
      assert {:error, %Ash.Error.Forbidden{}} = create.(ctx.moderator)
      assert {:error, %Ash.Error.Forbidden{}} = create.(ctx.outsider)
    end

    test "the versions of each versioned resource are read with the post area", ctx do
      for {resource, record} <- ctx.rows do
        version = Module.concat(resource, Version)

        [row | _] =
          version
          |> Ash.Query.filter(version_source_id == ^record.id)
          |> Ash.read!(authorize?: false)

        read = fn actor -> reads?(version, row, actor, action: :read_any, tenant: nil) end

        assert read.(ctx.editor), "#{inspect(version)} refused an editor"
        refute read.(ctx.moderator), "#{inspect(version)} let a moderator read it"
        refute read.(ctx.outsider), "#{inspect(version)} let an unrelated admin read it"
      end
    end

    test "every site's rows at once are a master's of the post area", %{site: site} do
      editor = create_user_with_permissions!([@post])
      moderator = create_user_with_permissions!([@comment])

      for resource <- [BlogPost, Collection] do
        record =
          resource
          |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
          |> Ash.Query.filter(site_id == ^site.id)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(authorize?: false)

        read = fn actor -> reads?(resource, record, actor, action: :read_any, tenant: nil) end

        assert read.(editor), "#{inspect(resource)} refused a master editor"
        refute read.(moderator), "#{inspect(resource)} let a master moderator read every site"
      end
    end

    test "each public profile's admin-only fields are the post area's", %{site: site} = ctx do
      for {resource, fields, record} <- [
            {Collection, [:version_count], create_collection!(site_id: site.id, status: :active)},
            {Tag, [:version_count], create_blog_tag!(site_id: site.id)},
            {Blogger, [:version_count, :can_publish_directly, :author_email],
             create_blogger!(site_id: site.id)},
            {Team, [:version_count], create_team!(site_id: site.id, status: :active)}
          ] do
        seen = fn actor ->
          resource
          |> Ash.Query.for_read(:public_get, %{}, actor: actor, tenant: site.id)
          |> Ash.Query.filter(id == ^record.id)
          |> Ash.Query.load(fields)
          |> Ash.read_one!()
          |> Map.take(fields)
        end

        assert seen.(ctx.editor) |> Map.values() |> Enum.all?(&(not forbidden?(&1))),
               "#{inspect(resource)} hid its admin fields from an editor"

        for actor <- [ctx.moderator, ctx.outsider] do
          assert seen.(actor) |> Map.values() |> Enum.all?(&forbidden?/1),
                 "#{inspect(resource)} showed its admin fields to #{actor_name(ctx, actor)}"
        end
      end
    end

    test "the admin-only fields are the post area's", %{site: site} = ctx do
      post =
        create_blog_post!(site_id: site.id, status: :published, published_at: DateTime.utc_now())

      create_comment!(post_id: post.id, status: :pending)

      fields = fn actor ->
        BlogPost
        |> Ash.Query.for_read(:public_get, %{}, actor: actor, tenant: site.id)
        |> Ash.Query.filter(id == ^post.id)
        |> Ash.Query.load([:version_count, :comment_count])
        |> Ash.read_one!()
      end

      assert %{version_count: count, comment_count: 1} = fields.(ctx.editor)
      assert is_integer(count)

      for actor <- [ctx.moderator, ctx.outsider] do
        assert %{version_count: %Ash.ForbiddenField{}, comment_count: %Ash.ForbiddenField{}} =
                 fields.(actor)
      end
    end
  end

  describe "comments ask for admin:dashboard:blog:comment" do
    setup %{site: site} do
      comment = create_comment!(site_id: site.id, status: :pending)
      voter = create_user!(site_id: site.id)

      %{
        comment: comment,
        voter: voter,
        vote: create_comment_vote!(comment_id: comment.id, actor: voter)
      }
    end

    test "a holder of the comment area alone reads comments and votes", ctx do
      assert reads?(Comment, ctx.comment, ctx.moderator)
      assert reads?(CommentVote, ctx.vote, ctx.moderator)
    end

    test "an editor and an unrelated admin read neither", ctx do
      for actor <- [ctx.editor, ctx.outsider] do
        refute reads?(Comment, ctx.comment, actor)
        refute reads?(CommentVote, ctx.vote, actor)
      end
    end

    test "moderating needs the area", ctx do
      approve = fn actor ->
        ctx.comment
        |> Ash.Changeset.for_update(:approve, %{}, actor: actor, tenant: ctx.site.id)
        |> Ash.update()
      end

      assert {:error, %Ash.Error.Forbidden{}} = approve.(ctx.editor)
      assert {:error, %Ash.Error.Forbidden{}} = approve.(ctx.outsider)
      assert {:ok, %{status: :approved}} = approve.(ctx.moderator)
    end

    test "a vote cast for somebody else is the comment area's", ctx do
      vote_for = fn actor ->
        CommentVote
        |> Ash.Changeset.for_create(
          :create_for_user,
          %{
            comment_id: ctx.comment.id,
            user_id: create_user!(site_id: ctx.site.id).id,
            vote_type: :up
          },
          actor: actor,
          tenant: ctx.site.id
        )
        |> Ash.create()
      end

      assert {:error, %Ash.Error.Forbidden{}} = vote_for.(ctx.editor)
      assert {:error, %Ash.Error.Forbidden{}} = vote_for.(ctx.outsider)
      assert {:ok, _vote} = vote_for.(ctx.moderator)
    end

    test "the sender's details are the comment area's", ctx do
      published = create_comment!(site_id: ctx.site.id, status: :approved)

      sender = fn actor ->
        Comment
        |> Ash.Query.for_read(:public_get, %{}, actor: actor, tenant: ctx.site.id)
        |> Ash.Query.filter(id == ^published.id)
        |> Ash.read_one!()
        |> Map.fetch!(:sender_data)
      end

      refute match?(%Ash.ForbiddenField{}, sender.(ctx.moderator))
      assert %Ash.ForbiddenField{} = sender.(ctx.editor)
      assert %Ash.ForbiddenField{} = sender.(ctx.outsider)
    end

    test "a master moderator reads the post of any site's comment, through the comment", ctx do
      master = create_user_with_permissions!([@comment])

      assert {:ok, %{master_post: %BlogPost{id: post_id}}} =
               Comment
               |> Ash.Query.for_read(:master_read, %{}, actor: master)
               |> Ash.Query.filter(id == ^ctx.comment.id)
               |> Ash.Query.load(:master_post)
               |> Ash.read_one()

      assert post_id == ctx.comment.post_id
    end

    test "a reader of a public comment does not reach its post through it", ctx do
      published = create_comment!(site_id: ctx.site.id, status: :approved)

      through = fn actor, relationship ->
        Comment
        |> Ash.Query.for_read(:public_get, %{}, actor: actor, tenant: ctx.site.id)
        |> Ash.Query.filter(id == ^published.id)
        |> Ash.Query.load(relationship)
        |> Ash.read_one()
      end

      for actor <- [create_user!(site_id: ctx.site.id), ctx.outsider] do
        assert {:error, %Ash.Error.Forbidden{}} = through.(actor, :post)
      end

      master = create_user_with_permissions!([@unrelated])
      assert {:error, %Ash.Error.Forbidden{}} = through.(master, :master_post)
    end

    test "a moderator reads the post a comment is on, through the comment alone", ctx do
      loaded = fn actor ->
        Comment
        |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: ctx.site.id)
        |> Ash.Query.filter(id == ^ctx.comment.id)
        |> Ash.Query.load(:post)
        |> Ash.read_one()
      end

      assert {:ok, %{post: %BlogPost{id: post_id}}} = loaded.(ctx.moderator)
      assert post_id == ctx.comment.post_id

      refute reads?(BlogPost, %{id: post_id, site_id: ctx.site.id}, ctx.moderator)
    end
  end

  describe "the surface" do
    setup %{site: site} do
      %{
        post: create_blog_post!(site_id: site.id),
        comment: create_comment!(site_id: site.id),
        api_editor: create_user_with_permissions!(["admin:api:blog:post"], site_id: site.id),
        api_moderator: create_user_with_permissions!(["admin:api:blog:comment"], site_id: site.id)
      }
    end

    test "on the API only the api name is held", ctx do
      assert reads?(BlogPost, ctx.post, ctx.api_editor, context: @api)
      refute reads?(BlogPost, ctx.post, ctx.editor, context: @api)
      refute reads?(BlogPost, ctx.post, ctx.api_moderator, context: @api)

      assert reads?(Comment, ctx.comment, ctx.api_moderator, context: @api)
      refute reads?(Comment, ctx.comment, ctx.moderator, context: @api)
      refute reads?(Comment, ctx.comment, ctx.api_editor, context: @api)
    end

    test "on the dashboard only the dashboard name is held", ctx do
      assert reads?(BlogPost, ctx.post, ctx.editor)
      refute reads?(BlogPost, ctx.post, ctx.api_editor)

      assert reads?(Comment, ctx.comment, ctx.moderator)
      refute reads?(Comment, ctx.comment, ctx.api_moderator)
    end

    test "the whole blog, a full admin and * each hold both areas on their surface", ctx do
      for {names, context} <- [
            {["admin:dashboard:blog:*"], %{}},
            {["admin:dashboard:*"], %{}},
            {["admin:api:blog:*"], @api},
            {["admin:api:*"], @api},
            {["*"], @api},
            {["*"], %{}}
          ] do
        admin = create_user_with_permissions!(names, site_id: ctx.site.id)

        assert reads?(BlogPost, ctx.post, admin, context: context), inspect(names)
        assert reads?(Comment, ctx.comment, admin, context: context), inspect(names)
      end
    end
  end

  defp forbidden?(%Ash.ForbiddenField{}), do: true
  defp forbidden?(_value), do: false

  defp actor_name(ctx, actor) do
    cond do
      actor.id == ctx.moderator.id -> "a comment moderator"
      actor.id == ctx.outsider.id -> "an unrelated admin"
      true -> "somebody"
    end
  end
end
