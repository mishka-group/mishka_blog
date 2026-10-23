# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.PostPageTest do
  @moduledoc """
  The post page as a reader meets it: the page's stored template (`/:lang/blog/:slug`), drawn with
  the assigns the runtime gives every page, over the blocks it names — the article, the conversation
  under it and the posts to read next.

  It is drawn the way the admin's Preview draws a page, with no LiveView behind it
  (`MishkaCmsCore.Runtime.Compilers.LiveViewCompiler.render_template/2`), which is also how a
  crawler's first response is drawn: every block reads in step with the page, so what is asserted
  here is what the HTML already holds. What a block does once connected — posting a comment,
  asking for more of them — is `MishkaBlog.LiveComponentsRenderTest`.

  What each assertion pins is a part of the design's post screen and the runtime data it is drawn
  from: the badges above the title, the people under it, the cover, the text, the rows under the
  text, the conversation with its count, and "Keep reading". The page draws none of the site's
  header, footer or menu: the `site-main` layout does. What it draws above the article is the
  blog's own bar, with Posts marked, which every page of the blog shares.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.Provision
  alias MishkaCmsCore.Runtime.Compilers.LiveViewCompiler
  alias MishkaCmsCore.Runtime.States.{SettingsState, SiteState}
  alias MishkaCmsCore.Runtime.Translations

  @moduletag :integration

  @path "/:lang/blog/:slug"

  # A UNIQUE SITE NAME PER TEST, for the reason `MishkaBlog.LiveComponentsRenderTest` gives: a
  # component's runtime module is named from (component name, site name) and kept in the VM, while it
  # carries the id of the site it was compiled against.
  setup do
    SiteState.clear()
    name = "posttown#{System.unique_integer([:positive])}"
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

    {:ok, site: site}
  end

  # THE PAGE AS THE SITE STORES IT, drawn for `slug` in `language` as `user` — `nil` for a guest.
  # The assigns are the ones both renderers hand a page: `@page`, `@query_params`, `@page_languages`
  # and `current_user`.
  defp drawn(site, slug, opts \\ []) do
    language = Keyword.get(opts, :language, "en")
    page = Enum.find(Provision.sample_pages(site), &(&1.path == @path))

    LiveViewCompiler.render_template(page.template, %{
      page: %{language: language, title: "Blog post", path: @path},
      query_params: %{"slug" => slug, "lang" => language},
      page_languages: [],
      current_user: Keyword.get(opts, :user)
    })
  end

  defp page_of(site, slug, opts \\ []) do
    html = drawn(site, slug, opts)
    assert is_binary(html), "the page did not draw: #{inspect(html)}"
    LazyHTML.from_fragment(html)
  end

  defp role(doc, name), do: LazyHTML.query(doc, ~s([data-role="#{name}"]))

  defp texts(doc, name),
    do:
      doc |> role(name) |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))

  # WHAT A ROLE HOLDS INSIDE THE POSTS TO READ NEXT, which are `blog-post-card`s like the lists' own.
  defp next_reads(doc, name) do
    doc
    |> LazyHTML.query(~s([data-role="blog-related-items"] [data-role="#{name}"]))
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
  end

  defp hrefs(doc, selector),
    do: doc |> LazyHTML.query(selector) |> Enum.flat_map(&LazyHTML.attribute(&1, "href"))

  defp classes(doc, name),
    do: doc |> role(name) |> Enum.flat_map(&LazyHTML.attribute(&1, "class"))

  defp published!(site, title, overrides) do
    create_blog_post!(
      Keyword.merge(
        [
          site_id: site.id,
          title: title,
          status: :published,
          published_at: ~U[2026-05-22 00:00:00Z]
        ],
        overrides
      )
    )
  end

  defp filed!(post, category),
    do: create_post_collection!(post_id: post.id, collection_id: category.id)

  defp category!(site, name, overrides \\ []) do
    create_collection!(
      Keyword.merge(
        [site_id: site.id, name: name, slug: Slug.slugify(name), language: "en", status: :active],
        overrides
      )
    )
  end

  describe "the article" do
    setup %{site: site} do
      post =
        published!(site, "Phoenix LiveView Deep Dive",
          slug: "deep-dive",
          featured: true,
          excerpt: "A comprehensive guide to LiveView.",
          content: "<p>It starts simple.</p><h2>Where to begin</h2><p>Small steps.</p>"
        )

      filed!(post, category!(site, "Elixir Fundamentals"))

      tag =
        create_blog_tag!(site_id: site.id, name: "metaprogramming", slug: "meta", language: "en")

      create_post_tag!(post_id: post.id, tag_id: tag.id)

      for {name, slug, bio} <- [
            {"Dave Brown", "dave-brown", "Writes about Phoenix."},
            {"Henry Davis", "henry-davis", "<b>Writes</b> about GraphQL."}
          ] do
        blogger = create_blogger!(site_id: site.id, display_name: name, slug: slug, bio: bio)
        create_post_blogger!(post_id: post.id, blogger_id: blogger.id)
      end

      {:ok, post: post}
    end

    test "draws the badges, the title and who wrote it above the cover", %{site: site, post: post} do
      doc = page_of(site, post.slug)

      assert texts(doc, "blog-detail-title") == ["Phoenix LiveView Deep Dive"]
      assert texts(doc, "blog-detail-category") == ["Elixir Fundamentals"]

      assert hrefs(doc, ~s([data-role="blog-detail-category"])) == [
               "/blog/category/elixir-fundamentals"
             ]

      assert texts(doc, "blog-detail-featured") == ["Featured"]
      refute has_role?(doc, "blog-detail-locked")

      # the round pictures carry the first letters of the name, linking to the blogger's page
      assert texts(doc, "blog-detail-avatar") == ["DB", "HD"]

      assert hrefs(doc, ~s([data-role="blog-detail-avatar"])) ==
               ["/blog/author/dave-brown", "/blog/author/henry-davis"]

      assert texts(doc, "blog-detail-authors") == ["Dave Brown & Henry Davis"]
    end

    test "draws the date and the reading time on one line, as the design does", %{
      site: site,
      post: post
    } do
      post = Ash.Seed.update!(post, %{reading_time_minutes: 6, updated_at: post.published_at})
      doc = page_of(site, post.slug)

      assert texts(doc, "blog-detail-date") == ["22 May 2026"]
      assert texts(doc, "blog-detail-reading") == ["6 min read"]
      refute has_role?(doc, "blog-detail-updated"), "an article nobody edited says it was updated"
    end

    test "says when an article was edited after it was published", %{site: site, post: post} do
      Ash.Seed.update!(post, %{updated_at: ~U[2026-06-01 00:00:00Z]})

      assert texts(page_of(site, post.slug), "blog-detail-updated") == ["Updated 01 Jun 2026"]
    end

    test "draws the lead, the text, the tags and the people in the column of the text", %{
      site: site,
      post: post
    } do
      doc = page_of(site, post.slug)

      assert texts(doc, "blog-detail-excerpt") == ["A comprehensive guide to LiveView."]
      assert texts(doc, "blog-detail-body") == ["It starts simple.Where to beginSmall steps."]

      # a tag is written with the hash the design gives it, and leads to the tag's page
      assert texts(doc, "blog-detail-tag") == ["#metaprogramming"]
      assert hrefs(doc, ~s([data-role="blog-detail-tag"])) == ["/blog/tag/meta"]

      # a card for each blogger, with the handle and the bio as plain text
      assert texts(doc, "blog-detail-author-card") == [
               "DB Dave Brown @dave-brown Writes about Phoenix.",
               "HD Henry Davis @henry-davis Writes about GraphQL."
             ]

      assert hrefs(doc, ~s(a[data-role="blog-detail-author-card"])) ==
               ["/blog/author/dave-brown", "/blog/author/henry-davis"]
    end

    test "draws the stand-in cover with the first letter, or the post's own picture", %{
      site: site,
      post: post
    } do
      doc = page_of(site, post.slug)

      assert [stand_in] = doc |> role("blog-detail-cover") |> Enum.to_list()
      assert LazyHTML.text(stand_in) =~ "cover image"
      assert LazyHTML.text(stand_in) =~ "P"
      assert LazyHTML.attribute(stand_in, "aria-hidden") == ["true"]

      Ash.Seed.update!(post, %{featured_image_url: "https://img.example/cover.png"})
      doc = page_of(site, post.slug)

      assert [cover] = doc |> role("blog-detail-cover") |> Enum.to_list()
      assert LazyHTML.attribute(cover, "src") == ["https://img.example/cover.png"]
    end

    test "leaves the people out when there are none, and links nothing it was not told where", %{
      site: site
    } do
      lonely = published!(site, "Written by nobody", slug: "lonely")
      doc = page_of(site, lonely.slug)

      refute has_role?(doc, "blog-detail-authors")
      refute has_role?(doc, "blog-detail-author-card")
      refute has_role?(doc, "blog-detail-tags")
      refute has_role?(doc, "blog-detail-categories")
    end

    test "links back to the blog's front page in the language of the post", %{
      site: site,
      post: post
    } do
      assert hrefs(page_of(site, post.slug), ~s([data-role="blog-detail-back"])) == ["/blog"]
    end

    test "reads right to left, and turns the arrow round, in a Persian post", %{site: site} do
      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      on_exit(fn -> SettingsState.delete(site.id, "site.languages") end)

      persian = published!(site, "نوشته", slug: "neveshte", language: "fa")
      doc = page_of(site, persian.slug, language: "fa")

      assert [article] = doc |> role("blog-detail-article") |> Enum.to_list()
      assert LazyHTML.attribute(article, "dir") == ["rtl"]
      assert LazyHTML.attribute(article, "lang") == ["fa"]
      assert classes(doc, "blog-detail-back") != []

      assert doc
             |> role("blog-detail-back")
             |> LazyHTML.query("span")
             |> Enum.map(&LazyHTML.attribute(&1, "class")) ==
               [["inline-block rtl:rotate-180"]]
    end
  end

  describe "a locked post" do
    setup %{site: site} do
      {:ok,
       member: create_user_with_permissions!(["members:read"], site_id: site.id),
       locked:
         published!(site, "The release checklist",
           slug: "checklist",
           permissions: ["members:read"]
         ),
       open: published!(site, "Open to everybody", slug: "open")}
    end

    test "carries the badge for the reader who holds the permission", %{
      site: site,
      member: member,
      locked: locked,
      open: open
    } do
      assert texts(page_of(site, locked.slug, user: member), "blog-detail-locked") == [
               "Members only"
             ]

      refute has_role?(page_of(site, open.slug, user: member), "blog-detail-locked")
    end

    test "takes the lock from its category when it names none of its own", %{
      site: site,
      member: member
    } do
      members = category!(site, "Members", permissions: ["members:read"])
      inherited = published!(site, "Filed under Members", slug: "inherited")
      filed!(inherited, members)

      assert texts(page_of(site, inherited.slug, user: member), "blog-detail-locked") == [
               "Members only"
             ]
    end

    test "is not there for a guest, whose request is answered as a post that does not exist", %{
      site: site,
      locked: locked
    } do
      assert {:error, message} = drawn(site, locked.slug)
      assert message =~ "NotFoundError"
    end
  end

  describe "the conversation" do
    setup %{site: site} do
      {:ok, post: published!(site, "Talked about", slug: "talked-about")}
    end

    test "says there is nothing yet, counts nothing, and offers a guest the way in", %{
      site: site,
      post: post
    } do
      doc = page_of(site, post.slug)

      assert texts(doc, "blog-comments-heading") == ["Comments 0"]
      assert texts(doc, "blog-comments-empty") == ["No comments yet — start the conversation."]
      assert texts(doc, "blog-comments-login") == ["Sign in to comment"]
      refute has_role?(doc, "blog-comments-form")
    end

    test "counts every approved comment, replies included, and leaves out the ones nobody approved",
         %{site: site, post: post} do
      reader = create_user!(site_id: site.id)

      first =
        create_comment!(
          site_id: site.id,
          post_id: post.id,
          status: :approved,
          content: "First",
          author_id: reader.id
        )

      create_comment!(
        site_id: site.id,
        post_id: post.id,
        status: :approved,
        content: "A reply",
        parent_comment_id: first.id
      )

      create_comment!(site_id: site.id, post_id: post.id, status: :pending, content: "Waiting")
      create_comment!(site_id: site.id, post_id: post.id, status: :spam, content: "Buy now")

      doc = page_of(site, post.slug)

      assert texts(doc, "blog-comments-heading") == ["Comments 2"]
      assert texts(doc, "blog-comment-body") == ["First", "A reply"]
      refute has_role?(doc, "blog-comments-empty")
    end

    test "draws the box a signed-in reader writes in under the conversation, with the design's words",
         %{site: site, post: post} do
      reader = create_user!(site_id: site.id)
      create_comment!(site_id: site.id, post_id: post.id, status: :approved, content: "First")

      html = drawn(site, post.slug, user: reader)
      doc = LazyHTML.from_fragment(html)

      assert [textarea] = doc |> role("blog-comments-input") |> Enum.to_list()
      assert LazyHTML.attribute(textarea, "placeholder") == ["Write a comment…"]
      assert texts(doc, "blog-comments-submit") == ["Post comment"]
      refute has_role?(doc, "blog-comments-login")

      {list_at, _} = :binary.match(html, ~s(data-role="blog-comments-list"))
      {form_at, _} = :binary.match(html, ~s(data-role="blog-comments-form"))
      assert list_at < form_at, "the box to write in was drawn above the conversation"
    end
  end

  describe "keep reading" do
    setup %{site: site} do
      {:ok,
       post:
         published!(site, "Being read",
           slug: "being-read",
           published_at: ~U[2026-05-01 00:00:00Z]
         )}
    end

    test "offers the newest posts of its own category first, then the newest of the rest, never itself",
         %{site: site, post: post} do
      shared = category!(site, "Shared")
      other = category!(site, "Elsewhere")
      filed!(post, shared)

      near = published!(site, "Near", slug: "near", published_at: ~U[2026-01-01 00:00:00Z])
      filed!(near, shared)
      far = published!(site, "Far", slug: "far", published_at: ~U[2026-04-01 00:00:00Z])
      filed!(far, other)

      newest_far =
        published!(site, "Newest far", slug: "newest-far", published_at: ~U[2026-04-15 00:00:00Z])

      filed!(newest_far, other)
      published!(site, "Fourth", slug: "fourth", published_at: ~U[2026-03-01 00:00:00Z])

      doc = page_of(site, post.slug)

      assert next_reads(doc, "blog-list-title") == ["Near", "Newest far", "Far"]
      assert texts(doc, "blog-related-heading") == ["Keep reading"]

      assert hrefs(doc, ~s([data-role="blog-related-items"] a[data-role="blog-list-title"])) == [
               "/blog/near",
               "/blog/newest-far",
               "/blog/far"
             ]

      assert next_reads(doc, "blog-list-category") == ["Shared", "Elsewhere", "Elsewhere"]
      assert next_reads(doc, "blog-list-date") == ["01 Jan 2026", "15 Apr 2026", "01 Apr 2026"]
      assert next_reads(doc, "blog-list-excerpt") == [], "a post to read next has no summary"
    end

    test "offers only posts in the language of the one being read, and only ones the reader may open",
         %{site: site, post: post} do
      published!(site, "English", slug: "english")
      published!(site, "فارسی", slug: "farsi", language: "fa")
      published!(site, "Locked", slug: "locked", permissions: ["members:read"])

      assert next_reads(page_of(site, post.slug), "blog-list-title") == ["English"]

      member = create_user_with_permissions!(["members:read"], site_id: site.id)

      assert page_of(site, post.slug, user: member)
             |> next_reads("blog-list-title")
             |> Enum.sort() == ["English", "Locked"]
    end

    test "draws nothing, not even its heading, when there is nothing else to read", %{
      site: site,
      post: post
    } do
      doc = page_of(site, post.slug)

      refute has_role?(doc, "blog-related-heading")
      refute has_role?(doc, "blog-related-items")
    end

    # THE CARD IS THE LISTS' OWN `blog-post-card`, in the variant the design draws under an article: a
    # 16:8 cover, the category and the day, the title. A post to read next is not announced as featured.
    test "draws each as the card of the lists, without the badge a featured post carries in them",
         %{site: site, post: post} do
      published!(site, "Starred", slug: "starred", featured: true)

      doc = page_of(site, post.slug)

      assert next_reads(doc, "blog-list-title") == ["Starred"]
      refute has_role?(doc, "blog-list-featured")

      assert doc
             |> LazyHTML.query(
               ~s([data-role="blog-related-items"] [data-role="blog-list-nocover"])
             )
             |> LazyHTML.attribute("class")
             |> hd() =~ "aspect-[16/8]"
    end

    test "draws the stand-in picture of a post that has none, and the post's own picture when it has one",
         %{site: site, post: post} do
      published!(site, "Plain", slug: "plain")

      pictured =
        published!(site, "Pictured",
          slug: "pictured",
          featured_image_url: "https://img.example/a.png"
        )

      doc = page_of(site, post.slug)
      items = ~s([data-role="blog-related-items"])

      assert doc |> LazyHTML.query("#{items} img") |> Enum.count() == 1

      assert doc |> LazyHTML.query(~s(#{items} [data-role="blog-list-nocover"])) |> Enum.count() ==
               1

      assert next_reads(doc, "blog-list-nocover") == ["P"]
      assert pictured.slug == "pictured"
    end
  end

  describe "the admin's Preview" do
    test "assigns no captures and no visitor, and the page still draws, with nothing to say", %{
      site: site
    } do
      page = Enum.find(Provision.sample_pages(site), &(&1.path == @path))

      html =
        LiveViewCompiler.render_template(page.template, %{
          page: %{language: "en", title: "Blog post", path: @path},
          query_params: %{},
          page_languages: []
        })

      assert is_binary(html), "the Preview did not draw: #{inspect(html)}"
      doc = LazyHTML.from_fragment(html)

      assert texts(doc, "blog-detail-idle") == ["Pick a post to read it here."]
      refute has_role?(doc, "blog-comments-heading")
      refute has_role?(doc, "blog-related-heading")
    end
  end

  describe "the markup" do
    test "draws no header, footer or sidebar of its own: the layout does", %{site: site} do
      post = published!(site, "Plain page", slug: "plain-page")
      page = Enum.find(Provision.sample_pages(site), &(&1.path == @path))
      doc = page_of(site, post.slug)

      for tag <- ["<header", "<main", "<footer", "min-h-screen"] do
        refute page.template =~ tag, "the page's own template draws #{tag}"
      end

      refute has_role?(doc, "blog-sidebar")
      assert doc |> LazyHTML.query("footer, main") |> Enum.count() == 0
    end

    # THE BLOG'S OWN BAR IS THE PAGE'S, the same one the lists draw: the blog's name and its four
    # places, and a post is in Posts.
    test "begins with the blog's bar, which marks Posts", %{site: site} do
      post = published!(site, "Plain page", slug: "plain-page")
      doc = page_of(site, post.slug)

      assert texts(doc, "blog-section-nav") == ["Posts Categories Tags People"]

      assert doc
             |> LazyHTML.query(~s([data-role="blog-section-nav"] a[aria-current="page"]))
             |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim())) == ["Posts"]

      assert hrefs(doc, ~s([data-role="blog-section-nav"] a)) ==
               ["/blog", "/blog/categories", "/blog/tags", "/blog/people"]
    end

    test "is styled with classes alone, never an inline style", %{site: site} do
      post = published!(site, "Styled with classes", slug: "classes")
      reader = create_user!(site_id: site.id)
      create_comment!(site_id: site.id, post_id: post.id, status: :approved, content: "A comment")
      published!(site, "Another", slug: "another")

      html = drawn(site, post.slug, user: reader)

      refute html =~ ~r/\sstyle=/, "the page draws an inline style"
    end

    test "answers the dark theme with the twin of every colour it takes from the site's tokens",
         %{site: site} do
      post = published!(site, "Dark too", slug: "dark-too", featured: true)
      published!(site, "Another", slug: "another")
      html = drawn(site, post.slug)

      # a token with a dark twin is used with it: `bg-surface` beside `dark:bg-surface-dark`
      drawn_tokens =
        for token <- ~w(surface edge dim fg),
            Regex.match?(~r/(?<![-:\w])(?:bg|border|text)-#{token}(?![-\w])/, html),
            do: token

      assert drawn_tokens != [], "no token of the site's theme was found, so nothing is asserted"

      for token <- drawn_tokens do
        assert html =~ ~r/dark:(?:bg|border|text)-#{token}-dark/,
               "#{token} is drawn and has no dark twin anywhere"
      end
    end
  end

  defp has_role?(doc, name), do: role(doc, name) |> Enum.count() > 0
end
