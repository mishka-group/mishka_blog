# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.SharedFacesTest do
  @moduledoc """
  One post, one colour; one person, one colour — on every page of the blog that draws them.

  A post with no picture is drawn by `blog-post-card` as its first letter on a tint its slug picks,
  and a blogger with no picture by `blog-profile-card` the same way. The list's card, the posts to
  read next, a blogger's and a team's page, the head of the article and its byline are all drawn by
  those two, so the colour is decided once. These tests draw the pages as a reader is served them
  and compare what each of them says.

  The pages are drawn the way the admin's Preview draws one, with no LiveView behind them
  (`MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.render_template/2`), which draws every block on
  it inline, in step with the page.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.Provision
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Translations

  @moduletag :integration

  setup do
    SiteState.clear()
    name = "facetown#{System.unique_integer([:positive])}"
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

    Provision.ensure!(site)
    :ok = Translations.put_site(site.id)

    category =
      create_collection!(
        site_id: site.id,
        name: "Elixir",
        slug: "elixir",
        language: "en",
        status: :active
      )

    writer = create_blogger!(site_id: site.id, display_name: "Dave Brown", slug: "dave-brown")
    team = create_team!(site_id: site.id, name: "Core", slug: "core", status: :active)
    create_team_member!(team_id: team.id, blogger_id: writer.id)

    post = published!(site, "Phoenix LiveView Deep Dive", "phoenix-liveview-deep-dive")
    other = published!(site, "Containerizing Elixir Apps", "containerizing-elixir-apps")

    for each <- [post, other] do
      create_post_collection!(post_id: each.id, collection_id: category.id)
      create_post_blogger!(post_id: each.id, blogger_id: writer.id)
    end

    {:ok, site: site, post: post, other: other}
  end

  defp published!(site, title, slug) do
    create_blog_post!(
      site_id: site.id,
      title: title,
      slug: slug,
      status: :published,
      excerpt: "About #{title}.",
      published_at: ~U[2026-05-01 00:00:00Z]
    )
  end

  defp drawn(site, path, query) do
    page = Enum.find(Provision.sample_pages(site), &(&1.path == path))

    html =
      LiveViewCompiler.render_template(page.template, %{
        page: %{language: "en", title: page.title, path: path},
        query_params: Map.put(query, "lang", "en"),
        page_languages: [],
        current_user: nil
      })

    assert is_binary(html), "#{path} did not draw: #{inspect(html)}"
    LazyHTML.from_fragment(html)
  end

  # THE COLOUR OF WHAT IS FOUND, as the four classes the design's tints are written in.
  defp tint_of(nodes) do
    nodes
    |> Enum.flat_map(&LazyHTML.attribute(&1, "class"))
    |> Enum.flat_map(&String.split/1)
    |> Enum.filter(&String.match?(&1, ~r/^(dark:)?(bg|text)-\[#[0-9a-f]{6}\]$/))
    |> Enum.sort()
  end

  defp tints(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.map(&tint_of([&1]))

  # THE COVER OF EACH POST IN A BLOCK OF CARDS, by the title on the card.
  defp covers(doc, block) do
    doc
    |> LazyHTML.query(~s(#{block} [data-role="blog-list-item"]))
    |> Map.new(fn item ->
      title =
        item
        |> LazyHTML.query(~s([data-role="blog-list-title"]))
        |> LazyHTML.text()
        |> String.trim()

      {title,
       item |> LazyHTML.query(~s([data-role="blog-list-nocover"])) |> Enum.to_list() |> tint_of()}
    end)
  end

  defp one_colour(lists) do
    assert [colour] = Enum.uniq(lists)

    assert length(colour) == 4,
           "a tint is the four classes of the design's colours: #{inspect(colour)}"

    colour
  end

  test "a post is the same colour on its card, to read next, on a person's page and as the cover of its article",
       %{site: site, post: post, other: other} do
    in_the_list = covers(drawn(site, "/:lang/blog", %{}), ~s([data-role="blog-list-items"]))
    assert Map.keys(in_the_list) |> Enum.sort() == [other.title, post.title]
    colour = one_colour([in_the_list[post.title]])
    assert in_the_list[other.title] != [], "the other post drew no tint"

    as_a_cover =
      tints(
        drawn(site, "/:lang/blog/:slug", %{"slug" => post.slug}),
        ~s([data-role="blog-detail-cover"])
      )

    assert one_colour(as_a_cover) == colour

    to_read_next =
      covers(
        drawn(site, "/:lang/blog/:slug", %{"slug" => other.slug}),
        ~s([data-role="blog-related-items"])
      )

    assert to_read_next == %{post.title => colour}

    by_a_person =
      covers(
        drawn(site, "/:lang/blog/author/:slug", %{"slug" => "dave-brown"}),
        ~s([data-role="blog-author-post-items"])
      )

    by_a_team =
      covers(
        drawn(site, "/:lang/blog/team/:slug", %{"slug" => "core"}),
        ~s([data-role="blog-team-post-items"])
      )

    assert by_a_person == in_the_list
    assert by_a_team == in_the_list
  end

  test "a person is the same colour on a card's byline, in the article's byline and box, and on their own page",
       %{site: site, post: post} do
    byline = ~s([data-role="blog-list-author"] [data-role="blog-profile-initial"])

    on_a_card = tints(drawn(site, "/:lang/blog", %{}), byline)

    in_the_article =
      tints(
        drawn(site, "/:lang/blog/:slug", %{"slug" => post.slug}),
        ~s([data-role="blog-detail-avatar"] [data-role="blog-profile-initial"])
      )

    in_the_box =
      tints(
        drawn(site, "/:lang/blog/:slug", %{"slug" => post.slug}),
        ~s([data-role="blog-detail-author-card"] [data-role="blog-profile-initial"])
      )

    on_their_page =
      tints(
        drawn(site, "/:lang/blog/author/:slug", %{"slug" => "dave-brown"}),
        ~s([data-role="blog-author-card"] [data-role="blog-profile-initial"])
      )

    on_the_people_page =
      tints(
        drawn(site, "/:lang/blog/people", %{}),
        ~s([data-role="blog-people-member"] [data-role="blog-profile-initial"])
      )

    colour = one_colour(on_their_page)

    for {where, found} <- [
          {"a card's byline", on_a_card},
          {"the article's byline", in_the_article},
          {"the article's box", in_the_box},
          {"the people page", on_the_people_page}
        ] do
      assert found != [], "#{where} drew nobody"
      assert one_colour(found) == colour, "#{where} is not the colour of their own page"
    end
  end

  test "a person's letters are the same two on every page that draws them", %{
    site: site,
    post: post
  } do
    letters = fn doc, selector ->
      doc |> LazyHTML.query(selector) |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    end

    assert letters.(
             drawn(site, "/:lang/blog", %{}),
             ~s([data-role="blog-list-author"] [data-role="blog-profile-initial"])
           ) == ["DB", "DB"]

    assert letters.(
             drawn(site, "/:lang/blog/:slug", %{"slug" => post.slug}),
             ~s([data-role="blog-detail-avatar"] [data-role="blog-profile-initial"])
           ) == ["DB"]
  end

  # THE FACE KEEPS THE SIZE EACH DESIGN SETS IT AT: 22px on a card, 34px with its ring in the byline of
  # an article, 52px in the box under it — the three of them one `blog-profile-card`.
  test "draws a person at the size of the place, and a picture when they gave one", %{
    site: site,
    post: post
  } do
    ada =
      create_blogger!(
        site_id: site.id,
        display_name: "Ada Pictured",
        slug: "ada-pictured",
        avatar_url: "https://cdn.example.test/ada.png"
      )

    create_post_blogger!(post_id: post.id, blogger_id: ada.id)

    home = drawn(site, "/:lang/blog", %{})
    article = drawn(site, "/:lang/blog/:slug", %{"slug" => post.slug})

    classes = fn doc, selector ->
      doc |> LazyHTML.query(selector) |> Enum.flat_map(&LazyHTML.attribute(&1, "class"))
    end

    assert Enum.any?(
             classes.(
               home,
               ~s([data-role="blog-list-author"] img[data-role="blog-profile-image"])
             ),
             &(&1 =~ "size-[22px]")
           )

    assert classes.(home, ~s([data-role="blog-list-author"] [data-role="blog-profile-initial"]))
           |> Enum.all?(&(&1 =~ "size-[22px]"))

    assert Enum.all?(
             classes.(
               article,
               ~s([data-role="blog-detail-avatar"] [data-role="blog-profile-initial"])
             ),
             &(&1 =~ "size-[30px]")
           )

    assert Enum.all?(
             classes.(
               article,
               ~s([data-role="blog-detail-author-card"] [data-role="blog-profile-initial"])
             ),
             &(&1 =~ "size-[52px]")
           )

    # the picture says nothing of its own: the name is written beside it
    for doc <- [home, article] do
      assert doc
             |> LazyHTML.query(~s(img[data-role="blog-profile-image"]))
             |> Enum.flat_map(&LazyHTML.attribute(&1, "src")) != []

      assert doc
             |> LazyHTML.query(~s(img[data-role="blog-profile-image"]))
             |> Enum.flat_map(&LazyHTML.attribute(&1, "alt"))
             |> Enum.uniq() == [""]
    end
  end
end
