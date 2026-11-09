# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.FeedPageScopeTest do
  @moduledoc """
  The term a blog page shows is named for the head's feed links from the rows the page already
  read: a category, a tag and a blogger are, the blog's front page and a post are not, and a nested
  category is named by its own slug.
  """
  use ExUnit.Case, async: true

  alias MishkaBlog.PageSource
  alias MishkaBlog.Plugins.FeedPageScope

  defp scope(kind, record) do
    data = %{
      site: %{id: "site"},
      assigns: %{
        page_source: %PageSource{
          site_id: "site",
          visitor: nil,
          language: "en",
          kind: kind,
          record: record
        }
      },
      language: "en",
      scope: nil,
      title: nil
    }

    {:reply, %{scope: scope, title: title}} = FeedPageScope.call(data)
    {scope, title}
  end

  test "names a category, a tag and a blogger by their slug and name" do
    assert scope("blog:category", %{slug: "case-studies", name: "Case studies"}) ==
             {{"category", "case-studies"}, "Case studies"}

    assert scope("blog:tag", %{slug: "otp", name: "OTP"}) == {{"tag", "otp"}, "OTP"}

    assert scope("blog:author", %{slug: "mona", display_name: "Mona"}) ==
             {{"author", "mona"}, "Mona"}
  end

  test "leaves the front page, a post and a page with no source alone" do
    assert scope("blog:home", nil) == {nil, nil}
    assert scope("blog:post", %{slug: "hello", title: "Hello"}) == {nil, nil}

    assert {:reply, %{scope: nil}} =
             FeedPageScope.call(%{
               assigns: %{},
               scope: nil,
               title: nil,
               site: nil,
               language: "en"
             })
  end
end
