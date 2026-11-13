# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.TermViewsTest do
  @moduledoc """
  A category, a tag, a blogger and a team count the views of their posts (`view_count`, the sum of
  the posts' `MishkaBlog.PostViewDaily` days), as the admin lists show them.
  """
  use MishkaBlog.DataCase, async: false

  setup do
    site = create_site!()
    read = create_blog_post!(site_id: site.id, status: :published)
    also = create_blog_post!(site_id: site.id, status: :published)
    unread = create_blog_post!(site_id: site.id, status: :published)

    create_post_views!(post: read, views: 7, day: Date.add(Date.utc_today(), -2))
    create_post_views!(post: read, views: 3)
    create_post_views!(post: also, views: 5)

    %{site: site, posts: [read, also], unread: unread}
  end

  defp views(record, site),
    do: Ash.load!(record, :view_count, tenant: site.id, authorize?: false).view_count

  test "a category, a tag and a blogger sum their posts' views", %{site: site, posts: posts} do
    collection = create_collection!(site_id: site.id)
    tag = create_blog_tag!(site_id: site.id)
    blogger = create_blogger!(site_id: site.id)

    for post <- posts do
      create_post_collection!(post_id: post.id, collection_id: collection.id)
      create_post_tag!(post_id: post.id, tag_id: tag.id)
      create_post_blogger!(post_id: post.id, blogger_id: blogger.id)
    end

    assert views(collection, site) == 15
    assert views(tag, site) == 15
    assert views(blogger, site) == 15
  end

  test "a team sums its members' posts' views", %{site: site, posts: [read, _also]} do
    blogger = create_blogger!(site_id: site.id)
    create_post_blogger!(post_id: read.id, blogger_id: blogger.id)
    team = create_team!(site_id: site.id)
    create_team_member!(team_id: team.id, blogger_id: blogger.id)

    assert views(team, site) == 10
  end

  test "a team counts a post its members co-wrote once", %{site: site, posts: [read, also]} do
    first = create_blogger!(site_id: site.id)
    second = create_blogger!(site_id: site.id)
    team = create_team!(site_id: site.id)

    for blogger <- [first, second] do
      create_post_blogger!(post_id: read.id, blogger_id: blogger.id)
      create_team_member!(team_id: team.id, blogger_id: blogger.id)
    end

    create_post_blogger!(post_id: also.id, blogger_id: second.id)

    assert views(team, site) == 15
  end

  test "a term with no read post is at zero", %{site: site, unread: unread} do
    tag = create_blog_tag!(site_id: site.id)
    create_post_tag!(post_id: unread.id, tag_id: tag.id)

    assert views(tag, site) == 0
  end
end
