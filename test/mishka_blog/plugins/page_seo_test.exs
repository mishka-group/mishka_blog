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
                 "publisher" => %{
                   "@type" => "Organization",
                   "name" => "The Studio",
                   "url" => ^base
                 },
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

    test "a post in one language offers no alternates, and one with no authors no author", %{
      site: site
    } do
      post = published!(site)
      answered = answer(given(site, :post, %{"lang" => "en", "slug" => post.slug}))

      refute Enum.any?(answered.tags, &(&1.tag == "link"))
      assert contents(answered.tags, "name", "author") == []
      refute Map.has_key?(schema_of(answered, "BlogPosting"), "author")
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
      assert [_published, _modified, own_section, creator] = answered.tags
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

      assert [%{"@type" => "Article", "headline" => "Ash in production"}] =
               Enum.map(head.schema, &Jason.decode!/1)

      # `post.slug` is no variable of the post page, so the stored og:image is left out and the
      # post's featured image is the image.
      assert head.image == base() <> "/media/cover.png"

      untouched = given(site, :post, params)
      head = untouched |> answer() |> Seo.accept(untouched) |> Seo.head(base: base())

      assert head.title == "Ash in production"
      assert head.description == "What a year of Ash taught us."

      assert [%{"@type" => "BlogPosting"}, %{"@type" => "BreadcrumbList"}] =
               Enum.map(head.schema, &Jason.decode!/1)
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
      assert answered.tags == []
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
