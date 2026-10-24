# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.ListPagesTest do
  @moduledoc """
  The blog's list pages — home, category, tag, every category and every tag — as a reader is served
  them: the sample page the blog provisions, drawn by the runtime for a site that has posts, bloggers,
  categories and tags.

  They are rendered the way the admin's Preview renders a page (`LiveViewCompiler.render_template/2`
  with the assigns every renderer gives a page), which draws every block on it inline, in step with
  the page. What each block does with a click and with a socket is `MishkaBlog.LiveComponentsRenderTest`;
  what is asserted here is the screen: that the page asks the blocks for the right things, and that
  what they draw is the design's — the search box with its count, the featured strip, the row of
  categories, the cards with their category, authors and lock, the pager that says which posts it is
  showing, the cards of the categories and the cloud of the tags.
  """
  use MishkaBlog.ConnCase, async: false

  import MishkaBlog.Test.Factory

  alias MishkaBlog.Provision
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.LiveViewHelpers
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Translations

  require Ash.Query

  @moduletag :integration

  setup do
    SiteState.clear()
    name = "listtown#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)

    SiteState.save(%{
      id: site.id,
      name: site.name,
      host: site.host,
      priority: site.priority,
      active: site.active,
      master: site.master
    })

    on_exit(fn -> SiteState.clear() end)

    :ok = Translations.put_site(site.id)
    Provision.ensure!(site)

    {:ok, site: site}
  end

  # ---------------------------------------------------------------------------
  # What a page is given, and the data the design is drawn from
  # ---------------------------------------------------------------------------

  defp page(site, path) do
    Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id and path == ^path)
    |> Ash.read_one!(authorize?: false)
  end

  # THE ASSIGNS THE PREVIEW AND THE PUBLIC RENDER BOTH GIVE: the page, the query string, the
  # languages. A visitor is given only where one is asked for, which is the one assign the admin's
  # Preview leaves out.
  defp render_page(site, path, query \\ %{}, opts \\ []) do
    row = page(site, path)

    assigns = %{
      page: %{language: "en", path: String.replace(path, ":lang", "en")},
      site: site.name,
      query_params: query,
      page_languages: []
    }

    assigns =
      case Keyword.fetch(opts, :user) do
        {:ok, user} -> Map.put(assigns, :current_user, user)
        :error -> assigns
      end

    LiveViewHelpers.rendering_for(site.name, fn ->
      LiveViewCompiler.render_template(row.template, assigns)
    end)
  end

  defp parsed(html), do: LazyHTML.from_fragment(html)

  defp text(html, selector) do
    html
    |> parsed()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  defp attrs(html, selector, name) do
    html
    |> parsed()
    |> LazyHTML.query(selector)
    |> Enum.flat_map(&LazyHTML.attribute(&1, name))
  end

  defp html_classes(html, selector), do: attrs(html, selector, "class")

  defp count(html, selector), do: html |> parsed() |> LazyHTML.query(selector) |> Enum.count()

  defp titles(html), do: text(html, ~s([data-role="blog-list-title"]))

  # THE NUMBER IN THE SEARCH BOX, and the line under the list that says which posts it shows.
  defp counted(html), do: text(html, ~s([data-role="blog-search-count"]))
  defp showing(html), do: text(html, ~s([data-role="blog-list-showing"]))

  defp publish!(site, title, opts \\ []) do
    create_blog_post!(
      Keyword.merge(
        [
          site_id: site.id,
          title: title,
          status: :published,
          excerpt: "About #{title}.",
          content: words(5),
          published_at: ~U[2026-05-01 00:00:00Z]
        ],
        opts
      )
    )
  end

  # A POST THAT TAKES `minutes` TO READ: the blog counts its words at two hundred a minute.
  defp words(minutes), do: String.duplicate("word ", minutes * 200)

  defp category!(site, name, opts \\ []) do
    create_collection!(
      Keyword.merge(
        [site_id: site.id, name: name, slug: slug(name), language: "en", status: :active],
        opts
      )
    )
  end

  defp tag!(site, name),
    do: create_blog_tag!(site_id: site.id, name: name, slug: slug(name), language: "en")

  defp blogger!(site, name),
    do: create_blogger!(site_id: site.id, display_name: name, slug: slug(name))

  defp slug(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  defp file!(post, category),
    do: create_post_collection!(post_id: post.id, collection_id: category.id)

  defp tag_post!(post, tag), do: create_post_tag!(post_id: post.id, tag_id: tag.id)

  defp credit!(post, blogger),
    do: create_post_blogger!(post_id: post.id, blogger_id: blogger.id)

  # THE BLOG THE DESIGN SHOWS: three featured posts, the rest under three categories, one of which
  # is locked to members, with who wrote them and what they are about.
  defp the_design!(site) do
    elixir = category!(site, "Elixir Fundamentals")
    ideas = category!(site, "Ideas in progress")
    members = category!(site, "Members only", permissions: ["members:read"])

    dave = blogger!(site, "Dave Brown")
    henry = blogger!(site, "Henry Davis")
    alice = blogger!(site, "Alice Smith")
    carol = blogger!(site, "Carol Williams")

    phoenix = tag!(site, "phoenix")
    performance = tag!(site, "performance")
    testing = tag!(site, "testing")

    live =
      publish!(site, "Phoenix LiveView Deep Dive — Part 2",
        featured: true,
        excerpt: "A comprehensive guide covering the essential concepts of LiveView.",
        content: words(6),
        published_at: ~U[2026-05-22 00:00:00Z]
      )

    file!(live, elixir)
    credit!(live, dave)
    credit!(live, henry)
    tag_post!(live, phoenix)
    tag_post!(live, performance)

    docker =
      publish!(site, "Containerizing Elixir Apps — Part 1",
        featured: true,
        content: words(8),
        published_at: ~U[2026-03-14 00:00:00Z]
      )

    file!(docker, elixir)
    credit!(docker, alice)

    graphql =
      publish!(site, "GraphQL with Absinthe — Part 1",
        featured: true,
        content: words(7),
        published_at: ~U[2026-01-21 00:00:00Z]
      )

    file!(graphql, elixir)
    credit!(graphql, carol)
    tag_post!(graphql, phoenix)

    e2e =
      publish!(site, "Issue 103 blocks e2e",
        excerpt: "What broke the end-to-end suite, and the one-line fix that unblocked it.",
        content: words(3),
        published_at: ~U[2026-10-09 00:00:00Z]
      )

    file!(e2e, ideas)
    credit!(e2e, carol)
    tag_post!(e2e, testing)

    release =
      publish!(site, "Members only: the release checklist",
        content: words(4),
        published_at: ~U[2026-10-05 00:00:00Z]
      )

    file!(release, members)
    credit!(release, alice)

    %{
      elixir: elixir,
      ideas: ideas,
      members: members,
      live: live,
      docker: docker,
      graphql: graphql,
      e2e: e2e,
      release: release,
      phoenix: phoenix,
      testing: testing,
      member: create_user_with_permissions!(["members:read"], site_id: site.id)
    }
  end

  # ---------------------------------------------------------------------------
  # The screen
  # ---------------------------------------------------------------------------

  describe "the blog's home" do
    test "draws the title and the search box with the count of the posts, and no bar of its own",
         %{site: site} do
      the_design!(site)
      html = render_page(site, "/:lang/blog")

      assert text(html, "h1") == ["Notes, guides & long reads."]
      assert text(html, "em") == ["long reads"]
      assert text(html, ~s([data-role="blog-search-count"])) == ["4 posts"]
      assert attrs(html, ~s(input[data-role="blog-search-input"]), "name") == ["q"]
      assert attrs(html, ~s(form[role="search"]), "method") == ["get"]
      assert attrs(html, ~s(form[role="search"]), "action") == ["/blog"]

      # THE BAR UNDER THE HEADER IS THE LAYOUT'S, handed it by `MishkaBlog.Plugins.PageFrame`
      assert count(html, ~s([data-role="blog-section-nav"])) == 0
      assert html |> String.trim_leading() |> String.starts_with?("<section")
    end

    # THE BOX COUNTS EVERY POST THE READER MAY OPEN IN THIS LANGUAGE: not a draft, not a post written in
    # another language, and not a locked one to a reader who does not hold the lock. The list under the
    # strip leaves out the posts of the strip, which are on the page above it, so its pager is those
    # fewer; together they are the box's number, which is also the design's (13 posts over "Showing 9
    # of 10", the three featured ones in the strip).
    test "counts the posts the reader may open in this language, and the pager those under the strip",
         %{site: site} do
      %{member: member} = the_design!(site)

      publish!(site, "A draft", status: :draft, published_at: nil)
      publish!(site, "In Persian", language: "fa")
      for index <- 1..12, do: publish!(site, "Plain #{index}")

      # three featured, "Issue 103 blocks e2e" and twelve more; the locked post is not a guest's
      guest = render_page(site, "/:lang/blog")
      assert counted(guest) == ["16 posts"]
      assert showing(guest) == ["Showing 1–9 of 13"]

      strip = text(guest, ~s([data-role="blog-featured-items"] [data-role="blog-list-title"]))
      assert length(strip) == 3

      # a member of the lock is shown one more, in the box and in the list
      members = render_page(site, "/:lang/blog", %{}, user: member)
      assert counted(members) == ["17 posts"]
      assert showing(members) == ["Showing 1–9 of 14"]
    end

    test "says 1 post, and none at all when there is nothing to search", %{site: site} do
      assert counted(render_page(site, "/:lang/blog")) == []

      publish!(site, "Only", [])
      assert counted(render_page(site, "/:lang/blog")) == ["1 post"]

      publish!(site, "Second", [])
      assert counted(render_page(site, "/:lang/blog")) == ["2 posts"]
    end

    test "draws the newest featured post large and the next two beside it, with their authors",
         %{site: site} do
      the_design!(site)
      html = render_page(site, "/:lang/blog")

      strip = html |> parsed() |> LazyHTML.query(~s([data-role="blog-featured-items"]))
      assert Enum.count(strip) == 1

      cards = text(html, ~s([data-role="blog-featured-items"] [data-role="blog-list-title"]))

      assert cards == [
               "Phoenix LiveView Deep Dive — Part 2",
               "Containerizing Elixir Apps — Part 1",
               "GraphQL with Absinthe — Part 1"
             ]

      assert text(html, ~s([data-role="blog-featured-items"] [data-role="blog-list-author-name"])) ==
               ["Dave Brown & Henry Davis", "Alice Smith", "Carol Williams"]

      assert text(html, ~s([data-role="blog-featured-items"] [data-role="blog-list-minutes"])) ==
               ["· 6 min read", "8 min", "7 min"]

      assert text(html, ~s([data-role="blog-featured-items"] [data-role="blog-list-category"])) ==
               ["Elixir Fundamentals", "Elixir Fundamentals", "Elixir Fundamentals"]

      assert text(html, ~s([data-role="blog-list-featured"])) == ["★ Featured"]
    end

    test "lists the latest posts under a row of the categories, without the featured ones",
         %{site: site} do
      the_design!(site)
      html = render_page(site, "/:lang/blog")

      assert text(html, ~s([data-role="blog-list-heading"])) == ["Latest posts"]

      assert text(html, ~s([data-role="blog-list-chip"])) == [
               "All",
               "Elixir Fundamentals",
               "Ideas in progress"
             ]

      assert attrs(html, ~s([data-role="blog-list-chip"]), "data-selected") == [
               "true",
               "false",
               "false"
             ]

      assert titles(html) --
               text(html, ~s([data-role="blog-featured-items"] [data-role="blog-list-title"])) ==
               ["Issue 103 blocks e2e"]

      assert text(html, ~s(#blog-posts-cards [data-role="blog-list-category"])) ==
               ["Ideas in progress"]

      assert text(html, ~s(#blog-posts-cards [data-role="blog-list-author-name"])) == [
               "Carol Williams"
             ]
    end

    # THE STRIP'S POSTS ARE LEFT OUT OF THE LIST BELOW IT, AND ONLY THEY. A fourth featured post is in
    # no strip, so it has to be in the list or it is on the page nowhere.
    test "leaves out the posts of the strip from the list, and no others", %{site: site} do
      the_design!(site)

      publish!(site, "Starred long ago",
        featured: true,
        published_at: ~U[2025-01-01 00:00:00Z]
      )

      html = render_page(site, "/:lang/blog")

      assert text(html, ~s([data-role="blog-featured-items"] [data-role="blog-list-title"])) ==
               [
                 "Phoenix LiveView Deep Dive — Part 2",
                 "Containerizing Elixir Apps — Part 1",
                 "GraphQL with Absinthe — Part 1"
               ]

      assert text(html, ~s(#blog-posts-cards [data-role="blog-list-title"])) ==
               ["Issue 103 blocks e2e", "Starred long ago"]
    end

    test "draws no strip at all when nothing is featured, and no gap where it was", %{site: site} do
      publish!(site, "Plain", [])
      html = render_page(site, "/:lang/blog")

      assert count(html, ~s([data-role="blog-featured-posts"])) == 1
      assert count(html, ~s([data-role="blog-featured-items"])) == 0
      assert text(html, ~s([data-role="blog-featured-empty"])) == []
      refute html =~ "pb-16"
      assert titles(html) == ["Plain"]
    end

    test "draws a post's own picture as its cover, and the first letter of its title otherwise",
         %{site: site} do
      publish!(site, "Pictured", featured_image_url: "/uploads/cover.png")
      publish!(site, "Plain", published_at: ~U[2026-04-01 00:00:00Z])
      html = render_page(site, "/:lang/blog")

      assert attrs(html, ~s([data-role="blog-list-cover"] img), "src") == ["/uploads/cover.png"]
      assert count(html, ~s([data-role="blog-list-nocover"])) == 1
      assert text(html, ~s([data-role="blog-list-nocover"])) == ["P"]
    end

    test "gives a post the same tint wherever it is drawn", %{site: site} do
      the_design!(site)

      cover = ~s(#blog-posts-cards [data-role="blog-list-nocover"])
      once = html_classes(render_page(site, "/:lang/blog"), cover)
      twice = html_classes(render_page(site, "/:lang/blog", %{"q" => "e2e"}), cover)

      assert hd(twice) in once

      # one of the six tints of the site's theme, and its twin for the dark
      assert hd(twice) =~
               ~r/bg-tint-([1-6]) text-tint-\1-ink dark:bg-tint-\1-dark dark:text-tint-\1-ink-dark/
    end

    test "offers the roots of the categories as chips, and not the ones nobody may read",
         %{site: site} do
      %{elixir: elixir} = the_design!(site)
      child = category!(site, "Beginners", parent_collection_id: elixir.id)
      post = publish!(site, "For beginners", [])
      file!(post, child)

      html = render_page(site, "/:lang/blog")

      assert text(html, ~s([data-role="blog-list-chip"])) ==
               ["All", "Elixir Fundamentals", "Ideas in progress"]
    end

    test "draws a post's lock to a member, and leaves the post out for a guest", %{site: site} do
      %{member: member} = the_design!(site)

      guest = render_page(site, "/:lang/blog")
      refute guest =~ "Members only: the release checklist"
      assert text(guest, ~s([data-role="blog-list-locked"])) == []

      members = render_page(site, "/:lang/blog", %{}, user: member)
      assert "Members only: the release checklist" in titles(members)
      assert text(members, ~s([data-role="blog-list-locked"])) == ["Members"]
      assert "Members only" in text(members, ~s([data-role="blog-list-chip"]))
    end

    test "searches the titles and the summaries, and leaves the strip out", %{site: site} do
      the_design!(site)
      html = render_page(site, "/:lang/blog", %{"q" => "end-to-end"})

      assert titles(html) == ["Issue 103 blocks e2e"]
      assert text(html, ~s([data-role="blog-list-heading"])) == ["Results"]
      assert count(html, ~s([data-role="blog-featured-items"])) == 0
      assert attrs(html, ~s(input[data-role="blog-search-input"]), "value") == ["end-to-end"]

      shouted = render_page(site, "/:lang/blog", %{"q" => "LIVEVIEW"})
      assert titles(shouted) == ["Phoenix LiveView Deep Dive — Part 2"]
    end

    test "says no post matches, and offers the way back", %{site: site} do
      the_design!(site)
      html = render_page(site, "/:lang/blog", %{"q" => "zzzz"})

      assert titles(html) == []
      assert text(html, ~s([data-role="blog-list-empty"])) == ["No posts match. Clear filters"]
      assert attrs(html, ~s([data-role="blog-notice-action"]), "href") == ["/blog"]
    end

    test "narrows to a tag, shows it as a chip that clears it, and leaves the strip out",
         %{site: site} do
      the_design!(site)
      html = render_page(site, "/:lang/blog", %{"tag" => "testing"})

      assert titles(html) == ["Issue 103 blocks e2e"]
      assert text(html, ~s([data-role="blog-list-heading"])) == ["Tagged posts"]
      assert text(html, ~s([data-role="blog-list-tag-chip"])) == ["Tagged #testing ×"]
      assert attrs(html, ~s([data-role="blog-list-tag-clear"]), "href") == ["/blog"]
      assert count(html, ~s([data-role="blog-featured-items"])) == 0

      # the search box carries the tag through a search, so a search inside a tag stays inside it
      assert attrs(html, ~s(form[role="search"] input[type="hidden"]), "name") == ["tag"]
      assert attrs(html, ~s(form[role="search"] input[type="hidden"]), "value") == ["testing"]
    end

    # `?q[a]=b` ARRIVES AS A MAP and `?tag[]=x` AS A LIST. Neither is words or a tag, so the home is
    # drawn as if nothing was asked, strip and all; the list's read raised on them.
    test "reads a search or a tag that is not text as nothing asked", %{site: site} do
      the_design!(site)
      plain = render_page(site, "/:lang/blog")

      for query <- [
            %{"q" => %{"a" => "b"}, "tag" => %{"a" => "b"}},
            %{"q" => ["x", "y"], "tag" => ["x"]}
          ] do
        html = render_page(site, "/:lang/blog", query)

        assert titles(html) == titles(plain)
        assert text(html, ~s([data-role="blog-list-heading"])) == ["Latest posts"]
        assert count(html, ~s([data-role="blog-featured-items"])) == 1
      end
    end

    test "pages the posts at the page's own address, keeps the search and says which are shown",
         %{site: site} do
      for index <- 1..12 do
        publish!(site, "Post #{String.pad_leading("#{index}", 2, "0")}",
          published_at: DateTime.add(~U[2026-01-01 00:00:00Z], index * 86_400, :second)
        )
      end

      html = render_page(site, "/:lang/blog", %{"q" => "Post"})

      assert length(titles(html)) == 9
      assert text(html, ~s([data-role="blog-list-position"])) == ["1 / 2"]
      assert text(html, ~s([data-role="blog-list-showing"])) == ["Showing 1–9 of 12"]

      [next] = attrs(html, ~s(a[data-role="blog-list-next"]), "href")
      assert next =~ "/blog?"
      assert next =~ "page=2"
      assert next =~ "q=Post"

      second = render_page(site, "/:lang/blog", %{"q" => "Post", "page" => "2"})
      assert length(titles(second)) == 3
      assert text(second, ~s([data-role="blog-list-showing"])) == ["Showing 10–12 of 12"]
    end

    test "leaves the page number out of the pager when everything fits on one page", %{site: site} do
      the_design!(site)
      html = render_page(site, "/:lang/blog")

      assert count(html, ~s([data-role="blog-list-pager"])) == 0
    end

    test "flips the order with the sort button, which is the list's own", %{site: site} do
      the_design!(site)
      html = render_page(site, "/:lang/blog")

      assert text(html, ~s([data-role="blog-list-sort"])) == ["Newest first"]
    end
  end

  describe "a category's page" do
    test "is the home with the list narrowed to it, headed with its name and its chip marked",
         %{site: site} do
      %{ideas: ideas} = the_design!(site)
      html = render_page(site, "/:lang/blog/category/:slug", %{"slug" => ideas.slug})

      assert titles(html) == ["Issue 103 blocks e2e"]
      assert text(html, ~s([data-role="blog-list-filter-title"])) == ["Ideas in progress"]
      assert count(html, ~s([data-role="blog-featured-items"])) == 0

      assert attrs(html, ~s([data-role="blog-list-chip"]), "data-selected") == [
               "false",
               "false",
               "true"
             ]

      assert attrs(html, ~s(form[role="search"]), "action") == [
               "/blog/category/ideas-in-progress"
             ]
    end

    # THE BOX COUNTS THE CATEGORY'S POSTS, the ones its list holds and the page of categories counts
    # for it, and not the blog's: a draft filed under it, an edition in another language and a post a
    # reader may not open are not in it.
    test "counts that category's posts in the box, as the page of categories counts them",
         %{site: site} do
      %{elixir: elixir, ideas: ideas, members: members, member: member} = the_design!(site)

      draft = publish!(site, "A draft", status: :draft, published_at: nil)
      file!(draft, elixir)

      box = fn category, opts ->
        html =
          render_page(site, "/:lang/blog/category/:slug", %{"slug" => category.slug}, opts)

        {counted(html), length(titles(html))}
      end

      assert box.(elixir, []) == {["3 posts"], 3}
      assert box.(ideas, []) == {["1 post"], 1}

      # the page of categories says the same for each of them, in the same words
      cards = render_page(site, "/:lang/blog/categories")
      assert text(cards, ~s([data-role="blog-category-count"])) == ["3 posts", "1 post"]

      # an edition in another language is not a post of this page's list, nor of its box
      persian = publish!(site, "In Persian", language: "fa")
      file!(persian, elixir)
      assert box.(elixir, []) == {["3 posts"], 3}

      # a locked category is nothing to count for a guest, and one post to a reader holding the lock
      assert box.(members, []) == {[], 0}
      assert box.(members, user: member) == {["1 post"], 1}
    end

    test "says nothing is published in a category that holds nothing, with the way back",
         %{site: site} do
      the_design!(site)
      empty = category!(site, "Empty")
      html = render_page(site, "/:lang/blog/category/:slug", %{"slug" => empty.slug})

      assert text(html, ~s([data-role="blog-list-empty"])) ==
               ["Nothing is published in this category yet. Clear filters"]
    end
  end

  describe "a tag's page" do
    test "is the home with the list narrowed to the tag, drawn as the design's tag chip",
         %{site: site} do
      %{phoenix: tag} = the_design!(site)
      html = render_page(site, "/:lang/blog/tag/:slug", %{"slug" => tag.slug})

      assert Enum.sort(titles(html)) ==
               ["GraphQL with Absinthe — Part 1", "Phoenix LiveView Deep Dive — Part 2"]

      assert text(html, ~s([data-role="blog-list-heading"])) == ["Tagged posts"]
      assert text(html, ~s([data-role="blog-list-tag-chip"])) == ["Tagged #phoenix ×"]
      assert attrs(html, ~s(form[role="search"]), "action") == ["/blog/tag/phoenix"]
    end
  end

  describe "a tag's page, counted" do
    # THE SAME FOR A TAG: the box counts the posts carrying it that the reader may open.
    test "counts that tag's posts in the box, and says 1 post for one", %{site: site} do
      %{phoenix: phoenix, testing: testing} = the_design!(site)

      draft = publish!(site, "A draft", status: :draft, published_at: nil)
      tag_post!(draft, phoenix)

      box = fn tag ->
        html = render_page(site, "/:lang/blog/tag/:slug", %{"slug" => tag.slug})
        {counted(html), length(titles(html))}
      end

      assert box.(phoenix) == {["2 posts"], 2}
      assert box.(testing) == {["1 post"], 1}

      # the cloud says the same for each of them
      cloud = render_page(site, "/:lang/blog/tags")

      assert text(cloud, ~s([data-role="blog-tag"])) == [
               "phoenix 2",
               "performance 1",
               "testing 1"
             ]

      # an edition in another language is not a post of this page's list, nor of its box
      persian = publish!(site, "In Persian", language: "fa")
      tag_post!(persian, phoenix)
      assert box.(phoenix) == {["2 posts"], 2}
    end

    test "counts nothing for a tag that is not there", %{site: site} do
      the_design!(site)
      html = render_page(site, "/:lang/blog/tag/:slug", %{"slug" => "no-such-tag"})

      assert counted(html) == []
      assert titles(html) == []
    end
  end

  describe "the categories page" do
    test "draws a card for each category: tile, count, name, description, latest posts and a link",
         %{site: site} do
      the_design!(site)
      html = render_page(site, "/:lang/blog/categories")

      assert text(html, "h1") == ["Categories"]
      assert text(html, ~s([data-role="blog-category-masthead"] span)) == ["Browse"]

      assert text(html, ~s([data-role="blog-category-name"])) == [
               "Elixir Fundamentals",
               "Ideas in progress"
             ]

      assert text(html, ~s([data-role="blog-category-count"])) == ["3 posts", "1 post"]

      assert text(html, ~s([data-role="blog-category-post"])) == [
               "Phoenix LiveView Deep Dive — Part 2",
               "Containerizing Elixir Apps — Part 1",
               "GraphQL with Absinthe — Part 1",
               "Issue 103 blocks e2e"
             ]

      assert text(html, ~s([data-role="blog-category-post-date"])) ==
               ["22 May 2026", "14 Mar 2026", "21 Jan 2026", "09 Oct 2026"]

      assert text(html, ~s([data-role="blog-category-more"])) ==
               ["View all in Elixir Fundamentals →", "View all in Ideas in progress →"]

      assert attrs(html, ~s([data-role="blog-category-more"]), "href") ==
               ["/blog/category/elixir-fundamentals", "/blog/category/ideas-in-progress"]
    end
  end

  describe "the tags page" do
    test "draws the topics as a cloud in which a tag is as large as it is used", %{site: site} do
      the_design!(site)
      html = render_page(site, "/:lang/blog/tags")

      assert text(html, "h1") == ["Tags"]

      assert text(html, ~s([data-role="blog-tag-summary"])) == [
               "3 topics · larger means more posts."
             ]

      assert text(html, ~s([data-role="blog-tag"])) == ["phoenix 2", "performance 1", "testing 1"]

      classes = attrs(html, ~s([data-role="blog-tag"]), "class")
      assert Enum.at(classes, 0) =~ "text-[28px]"
      assert Enum.at(classes, 1) =~ "text-[22px]"

      assert attrs(html, ~s([data-role="blog-tag"]), "href") ==
               ["/blog/tag/phoenix", "/blog/tag/performance", "/blog/tag/testing"]
    end
  end

  describe "where the pages hang" do
    test "on the site's own layout when it has one, so its header and footer are not drawn again",
         %{site: site} do
      assert Enum.all?(Provision.page_paths(), &(page(site, &1).layout_id == nil))

      main = create_layout!(site_id: site.id, name: "site-main", path: "/layouts/site-main")
      other = create_site!(name: "secondtown#{System.unique_integer([:positive])}")

      other_main =
        create_layout!(site_id: other.id, name: "site-main", path: "/layouts/site-main")

      Provision.ensure!(other)

      for path <- Provision.page_paths() do
        assert page(other, path).layout_id == other_main.id
      end

      refute main.id == other_main.id
    end
  end
end
