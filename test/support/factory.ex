# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Factory do
  @moduledoc """
  Fixtures for this extension's suite: the blog's own records.

  The accounts and runtime records a blog record cannot exist without (a post belongs to a site, a
  bookmark belongs to a user) are the core's `MishkaCmsCore.Test.Factory`, which ships in the core's
  `lib` for an extension's suite. `MishkaBlog.DataCase` imports both factories and
  `MishkaBlog.ConnCase` the core's. The generators are not copied either: `MishkaBlog.Dev.Generator`
  ships in `lib/`, so only the `create_*!` wrappers live here.

  Blog records are tenant-scoped, so each wrapper pops `:site_id` and passes it as the Ash tenant.
  """

  import MishkaBlog.Dev.Generator, except: [generate: 1, generate: 2]

  import MishkaCmsCore.Test.Factory,
    only: [create_site!: 0, create_user!: 1, create_permission!: 0]

  import Ash.Generator, only: [generate: 1]

  # Collection factory
  def create_collection!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # Collection MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> collection(tenant)
    |> generate()
  end

  # BlogPost factory
  def create_blog_post!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # BlogPost MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> blog_post(tenant)
    |> generate()
  end

  # Blogger factory
  def create_blogger!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    {user_id, overrides} = Keyword.pop(overrides, :user_id)

    # Blogger MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    # Blogger MUST have a user_id, one of the blogger's own site
    user_id = user_id || create_user!(site_id: site_id).id

    tenant = site_id

    overrides
    |> Keyword.put(:user_id, user_id)
    |> blogger(tenant)
    |> generate()
  end

  # Team factory
  def create_team!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # Team MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> team(tenant)
    |> generate()
  end

  # BloggerFollower factory
  def create_blogger_follower!(overrides \\ []) do
    {blogger_id, overrides} = Keyword.pop(overrides, :blogger_id)
    {actor, overrides} = Keyword.pop(overrides, :actor)

    # BloggerFollower MUST have a blogger_id
    blogger_id = blogger_id || create_blogger!().id

    # BloggerFollower MUST have an actor (relate_actor will set follower_user), by default a user of
    # the blogger's site
    actor = actor || create_user!(site_id: site_of(MishkaBlog.Blogger, blogger_id))

    overrides
    |> Keyword.put(:blogger_id, blogger_id)
    |> blogger_follower(actor)
    |> generate()
  end

  # TeamFollower factory
  def create_team_follower!(overrides \\ []) do
    {team_id, overrides} = Keyword.pop(overrides, :team_id)
    {follower_user_id, overrides} = Keyword.pop(overrides, :follower_user_id)
    {actor, overrides} = Keyword.pop(overrides, :actor)

    # TeamFollower MUST have a team_id
    team_id = team_id || create_team!().id

    # If follower_user_id is provided, look up or create that user
    # Otherwise, use/create actor
    {actor, _follower_user_id} =
      cond do
        actor && follower_user_id ->
          {actor, follower_user_id}

        actor ->
          {actor, actor.id}

        follower_user_id ->
          {Ash.get!(MishkaCmsCore.Accounts.User, follower_user_id, authorize?: false),
           follower_user_id}

        true ->
          user = create_user!(site_id: site_of(MishkaBlog.Team, team_id))
          {user, user.id}
      end

    overrides
    |> Keyword.put(:team_id, team_id)
    |> team_follower(actor)
    |> generate()
  end

  # TeamMember factory
  def create_team_member!(overrides \\ []) do
    {team_id, overrides} = Keyword.pop(overrides, :team_id)
    {blogger_id, overrides} = Keyword.pop(overrides, :blogger_id)

    # TeamMember MUST have a team_id and a blogger_id, both of one site
    {team_id, blogger_id} =
      on_one_site(
        {MishkaBlog.Team, team_id, &create_team!/1},
        {MishkaBlog.Blogger, blogger_id, &create_blogger!/1}
      )

    overrides
    |> Keyword.put(:team_id, team_id)
    |> Keyword.put(:blogger_id, blogger_id)
    |> team_member()
    |> generate()
  end

  # TeamPermission factory
  def create_team_permission!(overrides \\ []) do
    {team_id, overrides} = Keyword.pop(overrides, :team_id)
    {permission_id, overrides} = Keyword.pop(overrides, :permission_id)

    # TeamPermission MUST have a team_id and permission_id
    team_id = team_id || create_team!().id
    permission_id = permission_id || create_permission!().id

    overrides
    |> Keyword.put(:team_id, team_id)
    |> Keyword.put(:permission_id, permission_id)
    |> team_permission()
    |> generate()
  end

  # AutoPosting factory
  def create_auto_posting!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)

    # AutoPosting MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> auto_posting(tenant)
    |> generate()
  end

  # PostBlogger factory
  def create_post_blogger!(overrides \\ []) do
    {post_id, overrides} = Keyword.pop(overrides, :post_id)
    {blogger_id, overrides} = Keyword.pop(overrides, :blogger_id)

    {post_id, blogger_id} =
      on_one_site(
        {MishkaBlog.BlogPost, post_id, &create_blog_post!/1},
        {MishkaBlog.Blogger, blogger_id, &create_blogger!/1}
      )

    overrides
    |> Keyword.put(:post_id, post_id)
    |> Keyword.put(:blogger_id, blogger_id)
    |> post_blogger()
    |> generate()
  end

  # PostBookmark factory
  def create_post_bookmark!(overrides \\ []) do
    {post_id, overrides} = Keyword.pop(overrides, :post_id)
    {user_id, overrides} = Keyword.pop(overrides, :user_id)
    {actor, overrides} = Keyword.pop(overrides, :actor)

    post_id = post_id || create_blog_post!().id

    # If user_id is provided, look up or create that user
    # Otherwise, use/create actor
    {actor, _user_id} =
      cond do
        actor && user_id ->
          {actor, user_id}

        actor ->
          {actor, actor.id}

        user_id ->
          {Ash.get!(MishkaCmsCore.Accounts.User, user_id, authorize?: false), user_id}

        true ->
          user = create_user!(site_id: site_of(MishkaBlog.BlogPost, post_id))
          {user, user.id}
      end

    overrides
    |> Keyword.put(:post_id, post_id)
    |> post_bookmark(actor)
    |> generate()
  end

  # PostCollection factory
  def create_post_collection!(overrides \\ []) do
    {post_id, overrides} = Keyword.pop(overrides, :post_id)
    {collection_id, overrides} = Keyword.pop(overrides, :collection_id)

    {post_id, collection_id} =
      on_one_site(
        {MishkaBlog.BlogPost, post_id, &create_blog_post!/1},
        {MishkaBlog.Collection, collection_id, &create_collection!/1}
      )

    overrides
    |> Keyword.put(:post_id, post_id)
    |> Keyword.put(:collection_id, collection_id)
    |> post_collection()
    |> generate()
  end

  # PostRating factory
  def create_post_rating!(overrides \\ []) do
    {post_id, overrides} = Keyword.pop(overrides, :post_id)
    {user_id, overrides} = Keyword.pop(overrides, :user_id)
    {actor, overrides} = Keyword.pop(overrides, :actor)

    post_id = post_id || create_blog_post!().id

    # If user_id is provided, look up or create that user
    # Otherwise, use/create actor
    {actor, _user_id} =
      cond do
        actor && user_id ->
          {actor, user_id}

        actor ->
          {actor, actor.id}

        user_id ->
          {Ash.get!(MishkaCmsCore.Accounts.User, user_id, authorize?: false), user_id}

        true ->
          user = create_user!(site_id: site_of(MishkaBlog.BlogPost, post_id))
          {user, user.id}
      end

    overrides
    |> Keyword.put(:post_id, post_id)
    |> post_rating(actor)
    |> generate()
  end

  # Tag factory
  def create_blog_tag!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    # Tag MUST have a site_id (not global)
    site_id = site_id || create_site!().id
    tenant = site_id

    overrides
    |> tag(tenant)
    |> generate()
  end

  # PostTag factory
  def create_post_tag!(overrides \\ []) do
    {post_id, overrides} = Keyword.pop(overrides, :post_id)
    {tag_id, overrides} = Keyword.pop(overrides, :tag_id)

    {post_id, tag_id} =
      on_one_site(
        {MishkaBlog.BlogPost, post_id, &create_blog_post!/1},
        {MishkaBlog.Tag, tag_id, &create_blog_tag!/1}
      )

    overrides
    |> Keyword.put(:post_id, post_id)
    |> Keyword.put(:tag_id, tag_id)
    |> post_tag()
    |> generate()
  end

  # PostView factory
  def create_post_view!(overrides \\ []) do
    {post_id, overrides} = Keyword.pop(overrides, :post_id)
    {user_id, overrides} = Keyword.pop(overrides, :user_id)

    post_id = post_id || create_blog_post!().id
    # user_id is optional for guest views

    overrides =
      overrides
      |> Keyword.put(:post_id, post_id)

    overrides =
      if user_id do
        Keyword.put(overrides, :user_id, user_id)
      else
        overrides
      end

    overrides
    |> post_view()
    |> generate()
  end

  # Comment factory
  def create_comment!(overrides \\ []) do
    {site_id, overrides} = Keyword.pop(overrides, :site_id)
    {post_id, overrides} = Keyword.pop(overrides, :post_id)

    {site_id, post_id} =
      cond do
        site_id && post_id ->
          {site_id, post_id}

        post_id ->
          post = Ash.get!(MishkaBlog.BlogPost, post_id, action: :master_get, authorize?: false)
          {post.site_id, post.id}

        site_id ->
          post = create_blog_post!(site_id: site_id)
          {site_id, post.id}

        true ->
          post = create_blog_post!()
          {post.site_id, post.id}
      end

    tenant = site_id

    overrides
    |> Keyword.put(:post_id, post_id)
    |> comment(tenant)
    |> generate()
  end

  # CommentVote factory
  def create_comment_vote!(overrides \\ []) do
    {comment_id, overrides} = Keyword.pop(overrides, :comment_id)
    {user_id, overrides} = Keyword.pop(overrides, :user_id)
    {actor, overrides} = Keyword.pop(overrides, :actor)

    comment_id = comment_id || create_comment!().id

    # If user_id is provided, look up or create that user
    # Otherwise, use/create actor
    {actor, _user_id} =
      cond do
        actor && user_id ->
          {actor, user_id}

        actor ->
          {actor, actor.id}

        user_id ->
          {Ash.get!(MishkaCmsCore.Accounts.User, user_id, authorize?: false), user_id}

        true ->
          user = create_user!(site_id: site_of(MishkaBlog.Comment, comment_id))
          {user, user.id}
      end

    overrides
    |> Keyword.put(:comment_id, comment_id)
    |> comment_vote(actor)
    |> generate()
  end

  # A row that joins two records joins two records of ONE site, as a site's own writes do; the one
  # not given is made on the site of the one that is.
  defp on_one_site({left, left_id, make_left}, {right, right_id, make_right}) do
    case {left_id, right_id} do
      {nil, nil} ->
        record = make_left.([])
        {record.id, make_right.(site_id: record.site_id).id}

      {left_id, nil} ->
        {left_id, make_right.(site_id: site_of(left, left_id)).id}

      {nil, right_id} ->
        {make_left.(site_id: site_of(right, right_id)).id, right_id}

      given ->
        given
    end
  end

  defp site_of(resource, id),
    do: Ash.get!(resource, id, action: :master_get, authorize?: false).site_id
end
