# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.PageSeoTest do
  @moduledoc """
  What the blog answers on `runtime:page:seo`: the head of the post, the category and the tag its
  page's `slug` names, with the permissions each opens with, and nothing on any other page.

  Each test hands the plugin the map `MishkaCmsWeb.RuntimeLive` hands it — `Seo.given/2` of the
  provisioned page — and reads what it returns.
  """
  use MishkaBlog.DataCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias MishkaBlog.Plugins.PageSeo
  alias MishkaBlog.Provision
  alias MishkaCmsCore.Runtime.Seo
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.EventHandler
  alias MishkaInstaller.Event.Hook

  @host "blog.example.com"

  setup do
    site = create_site!(active: true)

    on_exit(fn ->
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
      SettingsState.delete(site.id, "site.title")
    end)

    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
    {:ok, _} = Settings.put("site.title", "The Studio", site_id: site.id)

    {:ok, site: site}
  end

  # The map core hands the plugins for a request to the `kind` page, storing `schema`, with `params`.
  defp given(site, kind, params, schema \\ []) do
    path = Provision.item_paths()[kind]
    filled = MishkaCmsCore.Runtime.Languages.url(path, params, site.id)

    Seo.given(
      %{
        title: "Blog post",
        path: path,
        language: "en",
        seo: %{description: nil, schema: schema}
      },
      site_id: site.id,
      url: filled && base() <> filled,
      params: params,
      record: Map.get(%{post: "blog:post", category: "blog:category", tag: "blog:tag"}, kind)
    )
  end

  # The site's address as core writes it in this environment.
  defp base, do: Seo.base(@host)

  # Where English, the site's first language, puts `path` in `mode`: under no prefix while the first
  # language goes without one, under its own once every language carries one.
  defp english("prefix_others", path), do: path
  defp english("prefix_all", path), do: "/en" <> path

  defp url_mode!(site, mode),
    do: {:ok, _} = Settings.put("site.language_urls", mode, site_id: site.id)

  # A page of the blog's own kinds is answered with `:halt`; any other is handed back to the chain.
  defp answer(given) do
    case PageSeo.call(given) do
      {:reply, :halt, answered} -> answered
      {:reply, answered} -> answered
    end
  end

  defp published!(site, overrides \\ []) do
    create_blog_post!(
      [
        site_id: site.id,
        status: :published,
        language: "en",
        published_at: ~U[2026-09-01 08:30:00Z]
      ] ++ overrides
    )
  end

  defp contents(tags, key, name) do
    for %{tag: "meta", attrs: %{^key => ^name}, content: content} <- tags, do: content
  end

  defp schema_of(answered, type), do: Enum.find(answered.schema, &(&1["@type"] == type))

  defp robots(content), do: [%{tag: "meta", attrs: %{"name" => "robots"}, content: content}]

  # The head's JSON-LD without the site's own `WebSite` and `Organization`, which core may add to
  # every page.
  defp page_schema(head) do
    head.schema
    |> Enum.map(&Jason.decode!/1)
    |> Enum.reject(&(&1["@type"] in ["WebSite", "Organization"]))
  end

  # The head core builds from the answer, as `MishkaCmsWeb.RuntimeLive` builds it.
  defp head(given), do: given |> answer() |> Seo.accept(given) |> Seo.head(base: base())

  defp head_contents(head, name) do
    for {"meta", attrs} <- head.tags,
        {"name", name} in attrs,
        do: attrs |> List.keyfind("content", 0) |> elem(1)
  end

  defp keys(var_docs), do: Enum.map(var_docs, & &1.key)

  # The head as `MishkaCmsWeb.RuntimeLive.page_head/1` writes it into the page.
  defp rendered_head(head) do
    assigns = %{seo: head}

    rendered_to_string(~H"""
    <meta :for={{"meta", attrs} <- @seo.tags} {attrs} />
    <script :for={json <- @seo.schema} type="application/ld+json">
      <%= Phoenix.HTML.raw(json) %>
    </script>
    """)
  end

  defp meta_content(html, selector),
    do:
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("content")

  defp json_ld(html, type) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s(script[type="application/ld+json"]))
    |> Enum.map(&(&1 |> LazyHTML.text() |> Jason.decode!()))
    |> Enum.find(&(&1["@type"] == type))
  end

  describe "the post page" do
    for mode <- ~w(prefix_others prefix_all) do
      test "is the post's own head: its text, its people, its filing and its translations, in #{mode}",
           %{site: site} do
        url_mode!(site, unquote(mode))

        post =
          published!(site,
            title: "Ash in production",
            excerpt: "What a year of Ash taught us.",
            featured_image_url: "/media/cover.png"
          )

        persian =
          published!(site,
            title: "Ash fa",
            language: "fa",
            language_group_id: post.language_group_id || post.id
          )

        blogger = create_blogger!(site_id: site.id, display_name: "Shahryar")
        create_post_blogger!(post_id: post.id, blogger_id: blogger.id)

        category = create_collection!(site_id: site.id, status: :active, name: "Engineering")
        create_post_collection!(post_id: post.id, collection_id: category.id)

        for name <- ["elixir", "ash"] do
          tag = create_blog_tag!(site_id: site.id, name: name)
          create_post_tag!(post_id: post.id, tag_id: tag.id)
        end

        base = base()
        url = base <> english(unquote(mode), "/blog/#{post.slug}")
        image = base <> "/media/cover.png"
        organization = base <> "/#organization"
        answered = answer(given(site, :post, %{"lang" => "en", "slug" => post.slug}))

        assert answered.title == "Ash in production"
        assert answered.description == "What a year of Ash taught us."
        assert answered.image == "/media/cover.png"
        assert answered.type == "article"
        assert answered.url == url

        assert contents(answered.tags, "name", "author") == ["Shahryar"]

        assert contents(answered.tags, "property", "article:published_time") == [
                 "2026-09-01T08:30:00Z"
               ]

        assert [_modified] = contents(answered.tags, "property", "article:modified_time")
        assert contents(answered.tags, "property", "article:section") == ["Engineering"]
        assert contents(answered.tags, "property", "article:tag") == ["ash", "elixir"]

        alternates =
          for %{tag: "link", attrs: %{"rel" => "alternate"} = attrs} <- answered.tags,
              do: {attrs["hreflang"], attrs["href"]}

        assert Enum.sort(alternates) == [
                 {"en", url},
                 {"fa", base <> "/fa/blog/#{persian.slug}"},
                 {"x-default", url}
               ]

        posting = schema_of(answered, "BlogPosting")

        assert %{
                 "headline" => "Ash in production",
                 "description" => "What a year of Ash taught us.",
                 "image" => ^image,
                 "datePublished" => "2026-09-01T08:30:00Z",
                 "author" => [%{"@type" => "Person", "name" => "Shahryar"}],
                 "publisher" => %{"@id" => ^organization},
                 "mainEntityOfPage" => ^url,
                 "inLanguage" => "en",
                 "keywords" => "ash, elixir"
               } = posting

        assert %{"itemListElement" => crumbs} = schema_of(answered, "BreadcrumbList")

        assert Enum.map(crumbs, &{&1["position"], &1["name"], &1["item"]}) == [
                 {1, "Home", base},
                 {2, "Blog", base <> english(unquote(mode), "/blog")},
                 {3, "Ash in production", url}
               ]

        assert %{
                 "post.title" => "Ash in production",
                 "post.excerpt" => "What a year of Ash taught us.",
                 "post.image" => ^image,
                 "post.author" => "Shahryar",
                 "post.published_at" => "2026-09-01T08:30:00Z",
                 "post.url" => ^url,
                 "post.collection" => "Engineering",
                 "post.tags" => "ash, elixir"
               } = answered.vars

        assert keys(answered.var_docs) == [
                 "post.title",
                 "post.excerpt",
                 "post.image",
                 "post.author",
                 "post.published_at",
                 "post.modified_at",
                 "post.url",
                 "post.collection",
                 "post.tags",
                 "post.rating",
                 "post.rating_count"
               ]

        assert Enum.all?(answered.var_docs, &(is_binary(&1.label) and is_binary(&1.help)))
      end
    end

    # A title is stored as typed (`MishkaCmsCore.PlainText`), so the head escapes it once: `&amp;`
    # in the page's source, `&` to whoever reads it.
    test "writes a title with an ampersand escaped once, in the tags and in the JSON-LD", %{
      site: site
    } do
      post = published!(site, title: "MCP & AI-Ready")

      html =
        site
        |> given(:post, %{"lang" => "en", "slug" => post.slug})
        |> head()
        |> rendered_head()

      assert html =~ ~s(content="MCP &amp; AI-Ready")
      refute html =~ "&amp;amp;"
      assert html =~ ~S("headline":"MCP \u0026 AI-Ready")
      assert meta_content(html, ~s(meta[property="og:title"])) == ["MCP & AI-Ready"]
      assert %{"headline" => "MCP & AI-Ready"} = json_ld(html, "BlogPosting")
    end

    for mode <- ~w(prefix_others prefix_all) do
      test "names each author's profile on the blogger page and their links, in #{mode}", %{
        site: site
      } do
        url_mode!(site, unquote(mode))

        create_page!(
          site_id: site.id,
          path: Provision.item_paths().author,
          extra: %{"record" => "blog:author"},
          active: true,
          permissions: []
        )

        post = published!(site)

        ada =
          create_blogger!(
            site_id: site.id,
            display_name: "Ada",
            slug: "ada",
            social_links: [
              %{platform: "github", url: "https://github.com/ada"},
              %{platform: "x", url: "https://x.com/ada_x"}
            ]
          )

        bea = create_blogger!(site_id: site.id, display_name: "Bea", slug: "bea")

        for blogger <- [ada, bea],
            do: create_post_blogger!(post_id: post.id, blogger_id: blogger.id)

        posting =
          schema_of(
            answer(given(site, :post, %{"lang" => "en", "slug" => post.slug})),
            "BlogPosting"
          )

        assert posting["author"] == [
                 %{
                   "@type" => "Person",
                   "name" => "Ada",
                   "url" => base() <> english(unquote(mode), "/blog/author/ada"),
                   "sameAs" => ["https://github.com/ada", "https://x.com/ada_x"]
                 },
                 %{
                   "@type" => "Person",
                   "name" => "Bea",
                   "url" => base() <> english(unquote(mode), "/blog/author/bea")
                 }
               ]

        assert posting["publisher"] == %{"@id" => base() <> "/#organization"}
      end
    end

    test "names no profile address while no open page shows a blogger", %{site: site} do
      for {active, permissions} <- [{false, []}, {true, ["members:read"]}] do
        create_page!(
          site_id: site.id,
          path: "/:lang/writers/#{active}/:slug",
          extra: %{"record" => "blog:author"},
          active: active,
          permissions: permissions
        )
      end

      post = published!(site)
      blogger = create_blogger!(site_id: site.id, display_name: "Ada", slug: "ada")
      create_post_blogger!(post_id: post.id, blogger_id: blogger.id)

      posting =
        schema_of(
          answer(given(site, :post, %{"lang" => "en", "slug" => post.slug})),
          "BlogPosting"
        )

      assert posting["author"] == [%{"@type" => "Person", "name" => "Ada"}]
    end

    test "a post in one language offers no alternates, and one with no authors no author", %{
      site: site
    } do
      post = published!(site)
      answered = answer(given(site, :post, %{"lang" => "en", "slug" => post.slug}))

      refute Enum.any?(answered.tags, &(&1.tag == "link"))
      assert contents(answered.tags, "name", "author") == []
      refute Map.has_key?(schema_of(answered, "BlogPosting"), "author")
    end

    test "names its section in the JSON-LD as well as in the tags, and none without a category",
         %{site: site} do
      filed = published!(site)
      category = create_collection!(site_id: site.id, status: :active, name: "Engineering")
      create_post_collection!(post_id: filed.id, collection_id: category.id)
      unfiled = published!(site)

      filed = answer(given(site, :post, %{"lang" => "en", "slug" => filed.slug}))
      unfiled = answer(given(site, :post, %{"lang" => "en", "slug" => unfiled.slug}))

      assert schema_of(filed, "BlogPosting")["articleSection"] == "Engineering"
      assert contents(filed.tags, "property", "article:section") == ["Engineering"]
      refute Map.has_key?(schema_of(unfiled, "BlogPosting"), "articleSection")
    end

    test "the post's own tags replace the ones built for it, and its own schema the posting", %{
      site: site
    } do
      category = create_collection!(site_id: site.id, status: :active, name: "Engineering")

      post =
        published!(site,
          seo_tags: [
            %{tag: "meta", attrs: %{"property" => "article:section"}, content: "Own"},
            %{tag: "meta", attrs: %{"name" => "twitter:creator"}, content: "@{{post.title}}"}
          ],
          schema: [%{"@type" => "Article", "headline" => "{{post.title}}"}]
        )

      create_post_collection!(post_id: post.id, collection_id: category.id)

      answered = answer(given(site, :post, %{"lang" => "en", "slug" => post.slug}))

      assert contents(answered.tags, "property", "article:section") == ["Own"]
      assert [_published, _modified, _label, _time, own_section, creator] = answered.tags
      assert own_section.content == "Own"
      assert creator.content == "@{{post.title}}"

      assert [%{"@type" => "Article"}, %{"@type" => "BreadcrumbList"}] = answered.schema
    end

    test "is the default: what the page sets wins, and may name the post's variables", %{
      site: site
    } do
      post =
        published!(site,
          title: "Ash in production",
          excerpt: "What a year of Ash taught us.",
          featured_image_url: "/media/cover.png"
        )

      params = %{"lang" => "en", "slug" => post.slug}
      page_schema = [%{"@type" => "Article", "headline" => "{{post.title}}"}]

      given = %{
        given(site, :post, params, page_schema)
        | description: "{{post.excerpt}} Read on."
      }

      page_tags = [
        %{tag: "title", attrs: %{}, content: "{{post.title}} | Blog"},
        %{tag: "meta", attrs: %{"property" => "og:image"}, content: "/media/{{post.slug}}.png"}
      ]

      head =
        given |> answer() |> Seo.accept(given) |> Seo.head(base: base(), layers: [[], page_tags])

      assert head.title == "Ash in production | Blog"
      assert head.description == "What a year of Ash taught us. Read on."

      assert [%{"@type" => "Article", "headline" => "Ash in production"}] = page_schema(head)

      # `post.slug` is no variable of the post page, so the stored og:image is left out and the
      # post's featured image is the image.
      assert head.image == base() <> "/media/cover.png"

      untouched = given(site, :post, params)
      head = untouched |> answer() |> Seo.accept(untouched) |> Seo.head(base: base())

      assert head.title == "Ash in production"
      assert head.description == "What a year of Ash taught us."

      assert [%{"@type" => "BlogPosting"}, %{"@type" => "BreadcrumbList"}] = page_schema(head)
    end

    test "answers the post's own permissions, and the head keeps a locked one out of an index", %{
      site: site
    } do
      locked = published!(site, permissions: ["members:read"])
      open = published!(site)

      locked_given = given(site, :post, %{"lang" => "en", "slug" => locked.slug})
      open_given = given(site, :post, %{"lang" => "en", "slug" => open.slug})

      assert answer(locked_given).permissions == ["members:read"]
      assert answer(open_given).permissions == []

      assert %{permissions: ["members:read"]} = head = head(locked_given)
      assert head_contents(head, "robots") == ["noindex, nofollow"]
      refute head_contents(head(open_given), "robots") == ["noindex, nofollow"]
    end

    test "answers the same when it is handed its own answer", %{site: site} do
      post = published!(site, seo_tags: [%{tag: "meta", attrs: %{"name" => "x"}, content: "y"}])
      answered = answer(given(site, :post, %{"lang" => "en", "slug" => post.slug}))

      assert answer(answered) == answered
    end

    test "a slug that names no published post in the page's language changes nothing else", %{
      site: site
    } do
      draft = create_blog_post!(site_id: site.id, status: :draft, language: "en")
      persian = published!(site, language: "fa")

      for slug <- ["no-such-post", draft.slug, persian.slug] do
        given = given(site, :post, %{"lang" => "en", "slug" => slug})
        assert answer(given) == %{given | var_docs: answer(given).var_docs}
        assert [_ | _] = answer(given).var_docs
      end
    end

    test "with no params returns its variables and reads nothing", %{site: site} do
      published!(site)
      given = given(site, :post, %{})

      assert queries_while(fn -> send(self(), {:answered, answer(given)}) end) == []
      assert_received {:answered, answered}

      assert answered == %{given | var_docs: answered.var_docs}
      assert "post.title" in keys(answered.var_docs)
    end
  end

  describe "the link preview pairs of a post" do
    defp preview(answered) do
      for number <- 1..2,
          [label] <- [contents(answered.tags, "name", "twitter:label#{number}")],
          [value] <- [contents(answered.tags, "name", "twitter:data#{number}")],
          do: {label, value}
    end

    defp words(count), do: "<p>" <> String.duplicate("word ", count) <> "</p>"

    test "name who wrote the post and how long it takes to read, pair 1 and pair 2", %{site: site} do
      post = published!(site, content: words(450))

      for name <- ["Mona", "Shahryar"] do
        blogger = create_blogger!(site_id: site.id, display_name: name)
        create_post_blogger!(post_id: post.id, blogger_id: blogger.id)
      end

      answered = answer(given(site, :post, %{"lang" => "en", "slug" => post.slug}))

      assert preview(answered) == [
               {"Written by", "Mona, Shahryar"},
               {"Reading time", "3 min read"}
             ]
    end

    test "number the pairs known from 1: a post with no author leads with its reading time", %{
      site: site
    } do
      post = published!(site, content: words(650))
      answered = answer(given(site, :post, %{"lang" => "en", "slug" => post.slug}))

      assert preview(answered) == [{"Reading time", "4 min read"}]
      assert contents(answered.tags, "name", "twitter:label2") == []
      assert contents(answered.tags, "name", "twitter:data2") == []
    end

    test "reach the head as meta tags, once", %{site: site} do
      post = published!(site, content: words(10))
      blogger = create_blogger!(site_id: site.id, display_name: "Ava")
      create_post_blogger!(post_id: post.id, blogger_id: blogger.id)

      head = head(given(site, :post, %{"lang" => "en", "slug" => post.slug}))

      assert head_contents(head, "twitter:label1") == ["Written by"]
      assert head_contents(head, "twitter:data1") == ["Ava"]
      assert head_contents(head, "twitter:label2") == ["Reading time"]
      assert head_contents(head, "twitter:data2") == ["1 min read"]
    end

    test "are replaced by the post's own, tag by tag", %{site: site} do
      own = %{tag: "meta", attrs: %{"name" => "twitter:data2"}, content: "A coffee"}
      post = published!(site, content: words(10), seo_tags: [own])
      blogger = create_blogger!(site_id: site.id, display_name: "Ava")
      create_post_blogger!(post_id: post.id, blogger_id: blogger.id)

      answered = answer(given(site, :post, %{"lang" => "en", "slug" => post.slug}))

      assert preview(answered) == [{"Written by", "Ava"}, {"Reading time", "A coffee"}]
    end

    test "are a post's alone: a category and a tag have none", %{site: site} do
      for kind <- [:category, :tag] do
        record =
          case kind do
            :category -> create_collection!(site_id: site.id, status: :active, name: "Elixir")
            :tag -> create_blog_tag!(site_id: site.id, name: "elixir")
          end

        answered = answer(given(site, kind, %{"lang" => "en", "slug" => record.slug}))

        assert preview(answered) == []
      end
    end
  end

  describe "the category page" do
    for mode <- ~w(prefix_others prefix_all) do
      test "is the category's own head, in #{mode}", %{site: site} do
        url_mode!(site, unquote(mode))

        category =
          create_collection!(
            site_id: site.id,
            status: :active,
            name: "Engineering",
            description: "How we build.",
            seo_tags: [%{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex"}]
          )

        url = base() <> english(unquote(mode), "/blog/category/#{category.slug}")
        answered = answer(given(site, :category, %{"lang" => "en", "slug" => category.slug}))

        assert answered.title == "Engineering"
        assert answered.description == "How we build."
        assert answered.type == "website"
        assert contents(answered.tags, "name", "robots") == ["noindex"]

        assert %{"name" => "Engineering", "description" => "How we build.", "url" => ^url} =
                 schema_of(answered, "CollectionPage")

        assert %{"itemListElement" => [_home, _blog, %{"name" => "Engineering", "item" => ^url}]} =
                 schema_of(answered, "BreadcrumbList")

        assert answered.vars == %{
                 "collection.name" => "Engineering",
                 "collection.description" => "How we build.",
                 "collection.url" => url
               }

        assert keys(answered.var_docs) == [
                 "collection.name",
                 "collection.description",
                 "collection.url"
               ]
      end
    end

    test "answers the category's own permissions", %{site: site} do
      locked =
        create_collection!(site_id: site.id, status: :active, permissions: ["members:read"])

      open = create_collection!(site_id: site.id, status: :active)

      locked_given = given(site, :category, %{"lang" => "en", "slug" => locked.slug})

      assert answer(locked_given).permissions == ["members:read"]
      assert head_contents(head(locked_given), "robots") == ["noindex, nofollow"]

      assert answer(given(site, :category, %{"lang" => "en", "slug" => open.slug})).permissions ==
               []
    end

    test "a draft category changes nothing else", %{site: site} do
      category = create_collection!(site_id: site.id, status: :draft)
      given = given(site, :category, %{"lang" => "en", "slug" => category.slug})

      assert answer(given) == %{given | var_docs: answer(given).var_docs}
    end
  end

  describe "the tag page" do
    test "is the tag's own head", %{site: site} do
      tag =
        create_blog_tag!(
          site_id: site.id,
          name: "Elixir",
          description: "Posts about Elixir.",
          language: "en"
        )

      answered = answer(given(site, :tag, %{"lang" => "en", "slug" => tag.slug}))

      assert %{title: "Elixir", description: "Posts about Elixir.", language: "en"} = answered
      assert %{"name" => "Elixir"} = schema_of(answered, "CollectionPage")
      assert %{"itemListElement" => [_home, _blog, _tag]} = schema_of(answered, "BreadcrumbList")
      assert %{"tag.name" => "Elixir", "tag.description" => "Posts about Elixir."} = answered.vars
      assert answered.tags == robots("noindex, follow")
      assert answered.permissions == []
    end

    test "its own tags reach the head", %{site: site} do
      tag =
        create_blog_tag!(
          site_id: site.id,
          language: "en",
          seo_tags: [
            %{tag: "meta", attrs: %{"name" => "twitter:creator"}, content: "@{{tag.name}}"},
            %{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex"}
          ]
        )

      given = given(site, :tag, %{"lang" => "en", "slug" => tag.slug})

      assert contents(answer(given).tags, "name", "robots") == ["noindex"]

      head = head(given)

      assert head_contents(head, "twitter:creator") == ["@#{tag.name}"]
      assert head_contents(head, "robots") == ["noindex"]
    end

    test "answers the tag's own permissions", %{site: site} do
      tag = create_blog_tag!(site_id: site.id, language: "en", permissions: ["members:read"])
      given = given(site, :tag, %{"lang" => "en", "slug" => tag.slug})

      assert answer(given).permissions == ["members:read"]
      assert head_contents(head(given), "robots") == ["noindex, nofollow"]
    end
  end

  # A TAG PAGE IS KEPT OUT OF AN INDEX, its links still followed, however many posts it lists; a
  # category is indexed.
  describe "a tag kept out of an index" do
    test "a public tag says noindex, follow, whatever it holds", %{site: site} do
      tag = create_blog_tag!(site_id: site.id, language: "en")

      for _ <- 1..3 do
        post = published!(site)
        create_post_tag!(post_id: post.id, tag_id: tag.id)
      end

      given = given(site, :tag, %{"lang" => "en", "slug" => tag.slug})

      assert answer(given).tags == robots("noindex, follow")
      assert head_contents(head(given), "robots") == ["noindex, follow"]
    end

    test "its own robots wins, and a locked one stays noindex, nofollow", %{site: site} do
      own = create_blog_tag!(site_id: site.id, language: "en", seo_tags: robots("index, follow"))
      locked = create_blog_tag!(site_id: site.id, language: "en", permissions: ["members:read"])

      own_given = given(site, :tag, %{"lang" => "en", "slug" => own.slug})
      assert head_contents(head(own_given), "robots") == ["index, follow"]

      locked_given = given(site, :tag, %{"lang" => "en", "slug" => locked.slug})
      assert contents(answer(locked_given).tags, "name", "robots") == []
      assert head_contents(head(locked_given), "robots") == ["noindex, nofollow"]
    end

    test "a category is indexed", %{site: site} do
      category = create_collection!(site_id: site.id, status: :active, language: "en")
      post = published!(site)
      create_post_collection!(post_id: post.id, collection_id: category.id)

      given = given(site, :category, %{"lang" => "en", "slug" => category.slug})

      assert contents(answer(given).tags, "name", "robots") == []
      assert head_contents(head(given), "robots") == ["index, follow, max-image-preview:large"]
    end
  end

  # members (locked) → guides (names nothing); open names nothing.
  describe "what a post or a category opens with" do
    setup %{site: site} do
      members =
        create_collection!(site_id: site.id, status: :active, permissions: ["members:read"])

      guides =
        create_collection!(site_id: site.id, status: :active, parent_collection_id: members.id)

      open = create_collection!(site_id: site.id, status: :active)

      %{members: members, guides: guides, open: open}
    end

    defp filed!(site, categories, overrides \\ []) do
      post = published!(site, overrides)

      for category <- categories,
          do: create_post_collection!(post_id: post.id, collection_id: category.id)

      post
    end

    defp opens_with(site, kind, record),
      do: answer(given(site, kind, %{"lang" => "en", "slug" => record.slug})).permissions

    test "a post that names nothing opens with its locked category's, kept out of an index",
         %{site: site, members: members} do
      post = filed!(site, [members])
      given = given(site, :post, %{"lang" => "en", "slug" => post.slug})

      assert answer(given).permissions == ["members:read"]
      assert head_contents(head(given), "robots") == ["noindex, nofollow"]
    end

    test "a post's own permissions win over its category's", %{site: site, members: members} do
      post = filed!(site, [members], permissions: ["staff:read"])

      assert opens_with(site, :post, post) == ["staff:read"]
    end

    test "a post in no locked category, or in none, is public", %{site: site, open: open} do
      assert opens_with(site, :post, filed!(site, [open])) == []
      assert opens_with(site, :post, filed!(site, [])) == []
    end

    test "a category under a locked one is locked by it, and so is a post filed under it",
         %{site: site, guides: guides, open: open} do
      assert opens_with(site, :category, guides) == ["members:read"]
      assert opens_with(site, :category, open) == []
      assert opens_with(site, :post, filed!(site, [guides])) == ["members:read"]
    end

    test "a post in two locked categories opens for whoever may open either",
         %{site: site, members: members, open: open} do
      staff = create_collection!(site_id: site.id, status: :active, permissions: ["staff:read"])

      assert Enum.sort(opens_with(site, :post, filed!(site, [members, staff]))) ==
               ["members:read", "staff:read"]

      assert opens_with(site, :post, filed!(site, [open, members])) == ["members:read"]
    end

    test "a draft category still locks its posts; a deleted one no more", %{site: site} do
      draft = create_collection!(site_id: site.id, status: :draft, permissions: ["members:read"])
      post = filed!(site, [draft])

      assert opens_with(site, :post, post) == ["members:read"]

      draft
      |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
      |> Ash.destroy!()

      assert opens_with(site, :post, post) == []
    end

    test "a tag locks its own page only, not the posts it is assigned to", %{site: site} do
      tag = create_blog_tag!(site_id: site.id, language: "en", permissions: ["members:read"])
      post = published!(site)
      create_post_tag!(post_id: post.id, tag_id: tag.id)

      assert opens_with(site, :tag, tag) == ["members:read"]
      assert opens_with(site, :post, post) == []
    end
  end

  describe "a rated post" do
    test "offers its readers' average and how many rated, once one has", %{site: site} do
      post = published!(site)
      params = %{"lang" => "en", "slug" => post.slug}

      refute Map.has_key?(answer(given(site, :post, params)).vars, "post.rating")

      create_post_rating!(post_id: post.id, rating: 4)
      create_post_rating!(post_id: post.id, rating: 5)

      assert %{"post.rating" => "4.5", "post.rating_count" => 2} =
               answer(given(site, :post, params)).vars
    end
  end

  describe "the kinds it names" do
    test "are a post, a collection, a tag, a blogger and a team, named as the blog's admin names them, each with the site's own to preview with",
         %{site: site} do
      post = published!(site, title: "Ash in production")
      create_blogger!(site_id: site.id, display_name: "Mona", slug: "mona")

      assert [
               %{
                 id: "blog:post",
                 group: "Blog",
                 label: "Post",
                 captures: ["slug"],
                 samples: posts
               },
               %{id: "blog:category", group: "Blog", label: "Collection", captures: ["slug"]},
               %{id: "blog:tag", group: "Blog", label: "Tag", captures: ["slug"]},
               %{
                 id: "blog:author",
                 group: "Blog",
                 label: "Blogger",
                 captures: ["slug"],
                 samples: [%{label: "Mona", params: %{"slug" => "mona"}}]
               },
               %{id: "blog:team", group: "Blog", label: "Team", captures: ["slug"]}
             ] = MishkaBlog.Plugins.PageRecords.types(site.id)

      assert %{label: "Ash in production · en", params: %{"slug" => slug, "lang" => "en"}} =
               Enum.find(posts, &(&1.params["slug"] == post.slug))

      assert slug == post.slug

      {:reply, %{records: records}} =
        MishkaBlog.Plugins.PageRecords.call(%{site_id: site.id, records: [%{id: "other"}]})

      assert [%{id: "other"} | _blog] = records
    end
  end

  # A site that answers its primary language at the root has the blog at `/blog`, not
  # `/:lang/blog`: the page's own path says where the blog is.
  defp given_at(site, path, record, params) do
    Seo.given(
      %{title: "Blog", path: path, language: "en", seo: %{description: nil, schema: []}},
      site_id: site.id,
      url: base() <> MishkaCmsCore.Runtime.Languages.url(path, params, site.id),
      params: params,
      record: record
    )
  end

  defp blog_crumb(answered) do
    %{"itemListElement" => [_home, blog | _]} = schema_of(answered, "BreadcrumbList")
    blog
  end

  describe "a blog at the site's root" do
    test "leads its breadcrumb's Blog to /blog, from every kind of page", %{site: site} do
      post = published!(site, title: "Ash in production")
      tag = create_blog_tag!(site_id: site.id, name: "elixir")
      create_post_tag!(post_id: post.id, tag_id: tag.id)

      for {path, record, slug} <- [
            {"/blog/:slug", "blog:post", post.slug},
            {"/blog/tag/:slug", "blog:tag", tag.slug}
          ] do
        answered = answer(given_at(site, path, record, %{"slug" => slug}))

        assert blog_crumb(answered)["item"] == base() <> "/blog",
               "#{record} led Blog elsewhere"
      end
    end
  end

  describe "the blogger page" do
    test "is the blogger's own profile: name, plain bio, photo, links and expertise", %{
      site: site
    } do
      create_blogger!(
        site_id: site.id,
        display_name: "Shahryar Tavakkoli",
        slug: "shahryar",
        bio: "<p>Builds <b>Mishka</b>.</p>",
        avatar_url: "/media/shahryar.jpg",
        social_links: [%{platform: "github", url: "https://github.com/shahryarjb"}],
        expertise_areas: ["Elixir", "Phoenix"]
      )

      answered =
        answer(given_at(site, "/blog/author/:slug", "blog:author", %{"slug" => "shahryar"}))

      assert answered.title == "Shahryar Tavakkoli"
      assert answered.description == "Builds Mishka."
      assert answered.image == "/media/shahryar.jpg"
      assert answered.type == "profile"
      assert answered.permissions == []

      assert %{"mainEntity" => person} = schema_of(answered, "ProfilePage")
      assert person["@type"] == "Person"
      assert person["name"] == "Shahryar Tavakkoli"
      assert person["sameAs"] == ["https://github.com/shahryarjb"]
      assert person["knowsAbout"] == ["Elixir", "Phoenix"]
      assert person["image"] == base() <> "/media/shahryar.jpg"
      assert blog_crumb(answered)["item"] == base() <> "/blog"
      assert answered.vars["author.name"] == "Shahryar Tavakkoli"
    end

    test "reads the bio's entities once, so the head escapes them once", %{site: site} do
      create_blogger!(
        site_id: site.id,
        display_name: "Tom & Jerry",
        slug: "tom-and-jerry",
        bio: "<p>Cats &amp; mice, <b>since 1940</b>.</p>"
      )

      given = given_at(site, "/blog/author/:slug", "blog:author", %{"slug" => "tom-and-jerry"})
      answered = answer(given)

      assert answered.title == "Tom & Jerry"
      assert answered.description == "Cats & mice, since 1940."
      assert answered.vars["author.bio"] == "Cats & mice, since 1940."

      html = answered |> Seo.accept(given) |> Seo.head(base: base()) |> rendered_head()

      assert html =~ ~s(content="Cats &amp; mice, since 1940.")
      refute html =~ "&amp;amp;"
      assert meta_content(html, ~s(meta[name="description"])) == ["Cats & mice, since 1940."]

      assert %{"mainEntity" => %{"description" => "Cats & mice, since 1940."}} =
               json_ld(html, "ProfilePage")
    end

    test "is left alone for a slug no blogger has", %{site: site} do
      given = given_at(site, "/blog/author/:slug", "blog:author", %{"slug" => "nobody"})
      answered = answer(given)

      assert answered.title == given.title
      assert keys(answered.var_docs) == ~w(author.name author.bio author.image author.url)
    end
  end

  describe "the team page" do
    test "is the team as an organization, with its members", %{site: site} do
      team =
        create_team!(
          site_id: site.id,
          name: "Mishka group core",
          slug: "mishka-group-core",
          description: "The people behind Mishka.",
          status: :active
        )

      for name <- ["Mona Aghili", "Shahryar Tavakkoli"] do
        blogger = create_blogger!(site_id: site.id, display_name: name)
        create_team_member!(team_id: team.id, blogger_id: blogger.id)
      end

      answered =
        answer(given_at(site, "/blog/team/:slug", "blog:team", %{"slug" => "mishka-group-core"}))

      assert answered.title == "Mishka group core"
      assert answered.description == "The people behind Mishka."

      assert %{"mainEntity" => %{"@type" => "Organization", "member" => members}} =
               schema_of(answered, "ProfilePage")

      assert Enum.map(members, & &1["name"]) == ["Mona Aghili", "Shahryar Tavakkoli"]
      assert blog_crumb(answered)["item"] == base() <> "/blog"
    end
  end

  # `twitter:creator`: the X account of each person a post or a blogger's page is about.
  describe "the X account of whoever a page is about" do
    defp author!(site, post, name, links) do
      blogger = create_blogger!(site_id: site.id, display_name: name, social_links: links)
      create_post_blogger!(post_id: post.id, blogger_id: blogger.id)
    end

    defp post_given(site, post), do: given(site, :post, %{"lang" => "en", "slug" => post.slug})

    defp profile(site, slug),
      do: answer(given_at(site, "/blog/author/:slug", "blog:author", %{"slug" => slug}))

    defp creators(answered), do: contents(answered.tags, "name", "twitter:creator")

    test "a post names each author who has one, and nothing for one who has none", %{site: site} do
      post = published!(site)
      author!(site, post, "Ava", [%{platform: "x", url: "https://x.com/some_one"}])
      author!(site, post, "Ben", [%{platform: "github", url: "https://github.com/ben"}])

      assert creators(answer(post_given(site, post))) == ["@some_one"]
    end

    test "a post names one, the first in its authors' order who has one, and the head keeps it",
         %{
           site: site
         } do
      post = published!(site)
      author!(site, post, "Zed", [%{"platform" => "x", "url" => "https://x.com/zed_x/"}])
      author!(site, post, "Bea", [%{"platform" => "github", "url" => "https://github.com/bea"}])

      author!(site, post, "Ava", [
        %{"platform" => "website", "url" => "https://twitter.com/ava_x"}
      ])

      given = post_given(site, post)

      assert creators(answer(given)) == ["@ava_x"]
      assert head_contents(head(given), "twitter:creator") == ["@ava_x"]
    end

    test "a post's own twitter:creator replaces every one built for it", %{site: site} do
      own = %{tag: "meta", attrs: %{"name" => "twitter:creator"}, content: "@own"}
      post = published!(site, seo_tags: [own])
      author!(site, post, "Ava", [%{platform: "x", url: "https://x.com/ava_x"}])
      author!(site, post, "Ben", [%{platform: "x", url: "https://x.com/ben_x"}])

      assert creators(answer(post_given(site, post))) == ["@own"]
    end

    test "a blogger's page names their X account", %{site: site} do
      create_blogger!(
        site_id: site.id,
        slug: "abc",
        social_links: [
          %{platform: "github", url: "https://github.com/abc"},
          %{platform: "twitter", url: "https://twitter.com/Abc_12?ref=x"}
        ]
      )

      assert profile(site, "abc").tags == [
               %{tag: "meta", attrs: %{"name" => "twitter:creator"}, content: "@Abc_12"}
             ]
    end

    test "a blogger with no X account, or one X would not accept, has none", %{site: site} do
      for {slug, links} <- [
            {"no-links", []},
            {"no-x", [%{platform: "github", url: "https://github.com/abc"}]},
            {"bad-x", [%{platform: "x", url: "https://x.com/this-is-not-valid"}]}
          ] do
        create_blogger!(site_id: site.id, slug: slug, social_links: links)

        assert creators(profile(site, slug)) == [], slug
      end
    end

    test "reads the handle however the link is written, and only a handle X accepts", %{
      site: site
    } do
      cases = [
        {"x", "https://x.com/shahryar_tbiz/", "@shahryar_tbiz"},
        {" X ", "@bare_at", "@bare_at"},
        {"Twitter", "bare_word", "@bare_word"},
        {"x", "x.com/no_scheme", "@no_scheme"},
        {"website", "https://www.x.com/www_x#fragment", "@www_x"},
        {"website", "https://WWW.TWITTER.COM/upper_host", "@upper_host"},
        {"website", "https://mobile.twitter.com/mobile_one", "@mobile_one"},
        {"website", "https://x.com/abcdefghijklmno", "@abcdefghijklmno"},
        {"website", "https://x.com/abcdefghijklmnop", nil},
        {"x", "https://x.com", nil},
        {"x", "https://x.com/@at_in_path", nil},
        {"x", "https://github.com/not_x", nil},
        {"website", "https://example.com/not_x", nil},
        {"website", "bare_word", nil},
        {"x", "mailto:someone", nil},
        {"x", "https://x.com@evil.example/user_at_host", nil},
        {"x", "https://evil.example@x.com/userinfo", nil},
        {"x", "https://evil.example/x.com/path_host", nil},
        {"x", "https://x.com.evil.example/look_alike", nil},
        {"x", "javascript://x.com/script_scheme", nil},
        {"x", "ftp://x.com/ftp_scheme", nil}
      ]

      for {{platform, url, expected}, index} <- Enum.with_index(cases) do
        slug = "case-#{index}"

        create_blogger!(
          site_id: site.id,
          slug: slug,
          social_links: [%{platform: platform, url: url}]
        )

        assert creators(profile(site, slug)) == List.wrap(expected), "#{platform} #{url}"
      end
    end

    test "the first X link that names a handle wins", %{site: site} do
      create_blogger!(
        site_id: site.id,
        slug: "many",
        social_links: [
          %{platform: "x", url: "https://x.com/not-valid"},
          %{platform: "x", url: "https://x.com/first_one"},
          %{platform: "twitter", url: "https://twitter.com/second_one"}
        ]
      )

      assert creators(profile(site, "many")) == ["@first_one"]
    end

    test "a team has none", %{site: site} do
      create_team!(site_id: site.id, name: "Core", slug: "core", status: :active)

      answered = answer(given_at(site, "/blog/team/:slug", "blog:team", %{"slug" => "core"}))

      assert creators(answered) == []
    end
  end

  # What each place adds to its share card (`MishkaCmsCore.Runtime.ShareCard`); core draws it.
  describe "share cards" do
    test "a post's shows its category, its authors with their photos and teams, the day and the cover",
         %{site: site} do
      post = published!(site, title: "Ash in production", featured_image_url: "/media/cover.png")
      team = create_team!(site_id: site.id, name: "Core team", status: :active)

      for {name, avatar} <- [{"Shahryar", "/media/s.jpg"}, {"Mona", nil}] do
        blogger = create_blogger!(site_id: site.id, display_name: name, avatar_url: avatar)
        create_post_blogger!(post_id: post.id, blogger_id: blogger.id)
        create_team_member!(team_id: team.id, blogger_id: blogger.id)
      end

      category = create_collection!(site_id: site.id, status: :active, name: "Engineering")
      create_post_collection!(post_id: post.id, collection_id: category.id)

      card = answer(given(site, :post, %{"lang" => "en", "slug" => post.slug})).card

      assert card.eyebrow == "Engineering"

      assert card.people == [
               %{name: "Mona", image: nil},
               %{name: "Shahryar", image: "/media/s.jpg"}
             ]

      assert card.byline == "Core team"
      assert ["Sep 1, 2026" | _reading] = card.meta
      assert card.picture == "/media/cover.png"
    end

    test "a post's day is written in the post's own language", %{site: site} do
      post = published!(site, language: "fa")

      given = %{given(site, :post, %{"lang" => "fa", "slug" => post.slug}) | language: "fa"}
      card = answer(given).card

      assert ["۱ سپتامبر ۲۰۲۶" | _reading] = card.meta
    end

    test "a blogger's names them as the author, with their photo and teams, and no backdrop", %{
      site: site
    } do
      team = create_team!(site_id: site.id, name: "Core team", status: :active)

      blogger =
        create_blogger!(
          site_id: site.id,
          display_name: "Shahryar",
          slug: "shahryar",
          avatar_url: "/media/s.jpg"
        )

      create_team_member!(team_id: team.id, blogger_id: blogger.id)

      card =
        answer(given_at(site, "/blog/author/:slug", "blog:author", %{"slug" => "shahryar"})).card

      assert card.eyebrow == "Author"
      assert card.people == [%{name: "Shahryar", image: "/media/s.jpg"}]
      assert card.byline == "Core team"
      assert card.picture == nil
    end

    test "a team's shows its members and how many they are", %{site: site} do
      team = create_team!(site_id: site.id, name: "Core", slug: "core", status: :active)

      for name <- ["Mona", "Shahryar"] do
        blogger = create_blogger!(site_id: site.id, display_name: name)
        create_team_member!(team_id: team.id, blogger_id: blogger.id)
      end

      card = answer(given_at(site, "/blog/team/:slug", "blog:team", %{"slug" => "core"})).card

      assert card.eyebrow == "Team"
      assert Enum.map(card.people, & &1.name) == ["Mona", "Shahryar"]
      assert card.meta == ["2 members"]
      assert card.picture == nil
    end

    test "a category's and a tag's say what they are", %{site: site} do
      create_collection!(site_id: site.id, status: :active, name: "Engineering", slug: "eng")
      create_blog_tag!(site_id: site.id, name: "elixir", slug: "elixir")

      assert answer(given(site, :category, %{"lang" => "en", "slug" => "eng"})).card ==
               %{eyebrow: "Category"}

      assert answer(given(site, :tag, %{"lang" => "en", "slug" => "elixir"})).card ==
               %{eyebrow: "Tag"}
    end
  end

  describe "a page of another kind" do
    test "is handed back as it came, with nothing read, whatever its path", %{site: site} do
      post = published!(site)

      for record <- [nil, "docs:page", "blog:unknown"] do
        given = %{given(site, :post, %{"lang" => "en", "slug" => post.slug}) | record: record}

        assert queries_while(fn -> send(self(), {:answered, PageSeo.call(given)}) end) == []
        assert_received {:answered, {:reply, ^given}}
      end
    end

    test "is told apart by its kind, not its path", %{site: site} do
      post = published!(site, title: "Ash in production")

      given = %{
        given(site, :post, %{"lang" => "en", "slug" => post.slug})
        | page: %{title: "Articles", path: "/:lang/articles/:slug", language: "en", seo: %{}}
      }

      assert {:reply, :halt, %{title: "Ash in production"}} = PageSeo.call(given)
    end
  end

  describe "the plugin" do
    test "is one of the plugins this extension's supervisor starts" do
      assert PageSeo in MishkaBlog.Application.plugins()
    end

    # Registered by hand for the reason `MishkaBlog.ProvisionTest`'s `listening!/0` gives: this
    # suite's registry is not up when the extension's supervisor starts its plugins.
    test "answers `runtime:page:seo`, the event core fires", %{site: site} do
      {:ok, _registered} = PageSeo.register()
      :ok = EventHandler.do_compile(Seo.event(), :start, false)

      post = published!(site, title: "Through the hook")
      given = given(site, :post, %{"lang" => "en", "slug" => post.slug})

      assert %{title: "Through the hook", type: "article"} =
               Seo.accept(Hook.call(Seo.event(), given), given)
    end
  end
end
