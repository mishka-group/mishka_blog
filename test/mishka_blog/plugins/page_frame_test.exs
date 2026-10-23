# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.PageFrameTest do
  @moduledoc """
  What the blog hands the site's layout on `runtime:page:frame`: the bar under the header, and the
  languages the record a page shows is written in.

  Each test builds the map `MishkaCmsCore.Runtime.SiteLayout.given/2` hands the plugins for one of
  the pages `MishkaBlog.Provision` writes, lets the plugin answer, and reads the answer the way the
  layout does (`SiteLayout.accept/2`): a language the site does not publish is dropped there, and
  fewer than two languages is none. The map names the visitor, a guest unless a test says who.
  """
  use MishkaBlog.DataCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias MishkaBlog.Plugins.{PageFrame, TranslationKeys}
  alias MishkaBlog.Provision
  alias MishkaCmsCore.Runtime.SiteLayout
  alias MishkaCmsCore.Runtime.States.{SettingsState, TranslationsState}
  alias MishkaCmsCore.Runtime.Translations
  alias MishkaCmsCore.Settings

  @blog_path "/:lang/blog"
  @post_path "/:lang/blog/:slug"
  @category_path "/:lang/blog/category/:slug"
  @tag_path "/:lang/blog/tag/:slug"
  @author_path "/:lang/blog/author/:slug"
  @team_path "/:lang/blog/team/:slug"

  setup do
    site = create_site!(active: true)

    on_exit(fn ->
      SettingsState.delete(site.id, "site.languages")
      SettingsState.delete(site.id, "site.language_urls")
    end)

    {:ok, _} = Settings.put("site.languages", ["en", "fa", "ar"], site_id: site.id)

    {:ok, site: site}
  end

  # THE PAGE AS THE RUNTIME HANDS IT TO THE PLUGINS, read off the sample page the blog writes at
  # `path`: its section, its path and the kind of record it says it shows.
  defp given(site, path, params, opts) do
    sample = Enum.find(Provision.sample_pages(site), &(&1.path == path))
    language = Keyword.get(opts, :language, "en")

    SiteLayout.given(
      %{path: path, section: sample.section, language: language, title: sample.title},
      site_id: site.id,
      extra: sample.extra,
      params: Map.put(params, "lang", language),
      current_user: Keyword.get(opts, :as),
      translations: Keyword.get(opts, :translations, [])
    )
  end

  # What the plugin answers, read by the layout.
  defp frame(given) do
    {:reply, :halt, answered} = PageFrame.call(given)
    SiteLayout.accept(answered, given)
  end

  defp frame(site, path, params, opts \\ []), do: site |> given(path, params, opts) |> frame()

  # The bar as the `site-main` layout draws it.
  defp rendered_bar(bar) do
    assigns = %{bar: bar}

    rendered_to_string(~H"""
    <SiteLayout.section_bar bar={@bar} />
    """)
  end

  defp languages(%{translations: translations}), do: Enum.map(translations, & &1.language)

  defp addresses(%{translations: translations}),
    do: Map.new(translations, &{&1.language, &1.path})

  defp titles(%{translations: translations}), do: Map.new(translations, &{&1.language, &1.title})

  defp published!(site, language, slug, title, group \\ nil, overrides \\ []) do
    [
      site_id: site.id,
      title: title,
      slug: slug,
      language: language,
      status: :published,
      published_at: ~U[2026-09-01 08:30:00Z]
    ]
    |> in_group(group)
    |> Keyword.merge(overrides)
    |> create_blog_post!()
  end

  # A master has no group yet; an edition names its master's.
  defp in_group(attrs, nil), do: attrs
  defp in_group(attrs, group), do: Keyword.put(attrs, :language_group_id, group)

  # The key a record's translations share: the master's own id, held by the master or not.
  defp group(master), do: master.language_group_id || master.id

  describe "the languages of a post" do
    test "are its editions, each at its own slug, address and title", %{site: site} do
      english = published!(site, "en", "news-post", "News")
      published!(site, "fa", "akhbar-post", "اخبار", group(english))
      published!(site, "ar", "alakhbar-post", "الأخبار", group(english))

      for {language, slug} <- [en: "news-post", fa: "akhbar-post", ar: "alakhbar-post"] do
        reading = frame(site, @post_path, %{"slug" => slug}, language: to_string(language))

        # the same three whichever of them is read, the one being read among them
        assert languages(reading) == ["en", "fa", "ar"]

        assert addresses(reading) == %{
                 "en" => "/blog/news-post",
                 "fa" => "/fa/blog/akhbar-post",
                 "ar" => "/ar/blog/alakhbar-post"
               }

        assert titles(reading) == %{"en" => "News", "fa" => "اخبار", "ar" => "الأخبار"}
      end
    end

    test "leave out a language the post has no edition in", %{site: site} do
      english = published!(site, "en", "only-two", "Only two")
      published!(site, "fa", "faqat-do", "فقط دو", group(english))

      reading = frame(site, @post_path, %{"slug" => "only-two"})

      assert languages(reading) == ["en", "fa"]
      refute "ar" in languages(reading)
      assert addresses(reading) == %{"en" => "/blog/only-two", "fa" => "/fa/blog/faqat-do"}
    end

    test "leave out an edition nobody can read yet", %{site: site} do
      english = published!(site, "en", "unfinished", "Unfinished")
      published!(site, "fa", "nimeh-kare", "نیمه کاره", group(english))

      published!(site, "ar", "ghayr-mukhtamil", "غير مكتمل", group(english),
        status: :draft,
        published_at: nil
      )

      assert languages(frame(site, @post_path, %{"slug" => "unfinished"})) == ["en", "fa"]
    end

    test "leave out an edition in a language the site does not publish", %{site: site} do
      english = published!(site, "en", "to-russian", "To Russian")
      published!(site, "ru", "po-russki", "По-русски", group(english))
      published!(site, "fa", "be-farsi", "به فارسی", group(english))

      assert languages(frame(site, @post_path, %{"slug" => "to-russian"})) == ["en", "fa"]
    end

    test "are none for a post written in one language only", %{site: site} do
      published!(site, "en", "alone", "Alone")

      assert frame(site, @post_path, %{"slug" => "alone"}).translations == []
    end

    test "are none when the slug names no post in this language", %{site: site} do
      english = published!(site, "en", "english-only-slug", "English")
      published!(site, "fa", "farsi-slug", "فارسی", group(english))

      # the English slug asked for under /fa: there is no such Persian post, so nothing to switch to
      assert frame(site, @post_path, %{"slug" => "english-only-slug"}, language: "fa").translations ==
               []

      assert frame(site, @post_path, %{"slug" => "nothing-here"}).translations == []
      assert frame(site, @post_path, %{}).translations == []
    end

    test "follow the URL mode of the site", %{site: site} do
      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)
      english = published!(site, "en", "all-prefixed", "All prefixed")
      published!(site, "fa", "hame-pishvand", "همه پیشوند", group(english))

      assert addresses(frame(site, @post_path, %{"slug" => "all-prefixed"})) == %{
               "en" => "/en/blog/all-prefixed",
               "fa" => "/fa/blog/hame-pishvand"
             }
    end

    test "follow a page that was given another path", %{site: site} do
      english = published!(site, "en", "moved-post", "Moved")
      published!(site, "fa", "jabeja-post", "جابجا", group(english))
      moved = "/:lang/journal/:slug"

      given =
        SiteLayout.given(
          %{path: moved, section: "blog", language: "en", title: "Blog post"},
          site_id: site.id,
          extra: %{"record" => "blog:post"},
          params: %{"slug" => "moved-post", "lang" => "en"}
        )

      assert addresses(frame(given)) == %{
               "en" => "/journal/moved-post",
               "fa" => "/fa/journal/jabeja-post"
             }
    end

    # THE OTHER EDITIONS ARE READ AS THE VISITOR THE FRAME NAMES. An edition is offered to a reader
    # who may open it and to no one else, so a locked edition's address and title are not shown to
    # a reader the blog keeps it from.
    test "leave out a locked edition of an open post for a guest and for a reader without the lock",
         %{site: site} do
      open = published!(site, "en", "open-post", "Open")
      published!(site, "fa", "ghofl-post", "قفل", group(open), permissions: ["members:read"])
      published!(site, "ar", "maftuh-post", "مفتوح", group(open))

      for visitor <- [nil, create_user!(site_id: site.id)] do
        reading = frame(site, @post_path, %{"slug" => "open-post"}, as: visitor)

        assert languages(reading) == ["en", "ar"]
        refute "قفل" in Enum.map(reading.translations, & &1.title)
        refute "/fa/blog/ghofl-post" in Map.values(addresses(reading))
      end
    end

    test "offer a locked edition to the reader who holds its permission", %{site: site} do
      open = published!(site, "en", "open-post", "Open")
      published!(site, "fa", "ghofl-post", "قفل", group(open), permissions: ["members:read"])
      published!(site, "ar", "maftuh-post", "مفتوح", group(open))

      member = create_user_with_permissions!(["members:read"], site_id: site.id)
      reading = frame(site, @post_path, %{"slug" => "open-post"}, as: member)

      assert languages(reading) == ["en", "fa", "ar"]
      assert addresses(reading)["fa"] == "/fa/blog/ghofl-post"
      assert titles(reading)["fa"] == "قفل"
    end

    test "offer a wildcard holder the editions the wildcard covers", %{site: site} do
      open = published!(site, "en", "open-post", "Open")
      published!(site, "fa", "ghofl-post", "قفل", group(open), permissions: ["members:read"])

      holder = create_user_with_permissions!(["members:*"], site_id: site.id)

      assert languages(frame(site, @post_path, %{"slug" => "open-post"}, as: holder)) ==
               ["en", "fa"]
    end

    test "always offer the edition being read, locked or not", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa", "ar", "tr", "de"], site_id: site.id)
      locked = published!(site, "en", "locked-post", "Locked", nil, permissions: ["members:read"])

      # no lock, the same lock, a lock of another permission, a lock of the same one and more
      published!(site, "ar", "maftuh-post", "مفتوح", group(locked))
      published!(site, "fa", "ghofl-post", "قفل", group(locked), permissions: ["members:read"])
      published!(site, "tr", "personel", "Personel", group(locked), permissions: ["staff:read"])

      published!(site, "de", "beides", "Beides", group(locked),
        permissions: ["members:read", "staff:read"]
      )

      member = create_user_with_permissions!(["members:read"], site_id: site.id)
      staff = create_user_with_permissions!(["members:read", "staff:read"], site_id: site.id)

      # a guest is on the page the lock closes only through the page's gate: the page's own record
      # is still in its frame, and the one edition a guest can read beside it
      assert languages(frame(site, @post_path, %{"slug" => "locked-post"})) == ["en", "ar"]

      reading = frame(site, @post_path, %{"slug" => "locked-post"}, as: member)
      assert languages(reading) == ["en", "fa", "ar", "de"]
      refute "Personel" in Enum.map(reading.translations, & &1.title)

      assert languages(frame(site, @post_path, %{"slug" => "locked-post"}, as: staff)) ==
               ["en", "fa", "ar", "tr", "de"]
    end

    # A POST IS KEPT BY THE LOCK OF THE CATEGORY IT IS FILED UNDER when it names none, which the
    # edition's own permissions do not say.
    test "leave out an edition that is locked by its category", %{site: site} do
      open = published!(site, "en", "filed-post", "Filed")
      inherits = published!(site, "fa", "dar-pushe", "در پوشه", group(open))
      published!(site, "ar", "maftuh-post", "مفتوح", group(open))

      locked = category!(site, "fa", "ghofl", "قفل", nil, permissions: ["members:read"])
      create_post_collection!(post_id: inherits.id, collection_id: locked.id)

      member = create_user_with_permissions!(["members:read"], site_id: site.id)

      assert languages(frame(site, @post_path, %{"slug" => "filed-post"})) == ["en", "ar"]

      assert languages(frame(site, @post_path, %{"slug" => "filed-post"}, as: member)) ==
               ["en", "fa", "ar"]
    end
  end

  describe "the languages of a category" do
    test "are its editions, each at its own slug and under its own name", %{site: site} do
      news = category!(site, "en", "news", "News")
      category!(site, "ar", "al-akhbar", "الأخبار", group(news))
      category!(site, "fa", "akhbar", "اخبار", group(news))

      reading = frame(site, @category_path, %{"slug" => "akhbar"}, language: "fa")

      assert languages(reading) == ["en", "fa", "ar"]

      assert addresses(reading) == %{
               "en" => "/blog/category/news",
               "fa" => "/fa/blog/category/akhbar",
               "ar" => "/ar/blog/category/al-akhbar"
             }

      assert titles(reading) == %{"en" => "News", "fa" => "اخبار", "ar" => "الأخبار"}
    end

    test "leave out a language the category is not written in, and an inactive edition",
         %{site: site} do
      news = category!(site, "en", "news", "News")
      category!(site, "fa", "akhbar", "اخبار", group(news))
      category!(site, "ar", "al-akhbar", "الأخبار", group(news), status: :draft)

      assert languages(frame(site, @category_path, %{"slug" => "news"})) == ["en", "fa"]
    end

    test "leave out a locked edition for a guest, and offer it to a reader who holds the lock",
         %{site: site} do
      news = category!(site, "en", "news", "News")
      category!(site, "fa", "akhbar", "اخبار", group(news), permissions: ["members:read"])
      category!(site, "ar", "al-akhbar", "الأخبار", group(news))

      member = create_user_with_permissions!(["members:read"], site_id: site.id)

      assert languages(frame(site, @category_path, %{"slug" => "news"})) == ["en", "ar"]

      assert languages(frame(site, @category_path, %{"slug" => "news"}, as: member)) ==
               ["en", "fa", "ar"]
    end

    test "are none for a category written in one language only", %{site: site} do
      category!(site, "en", "lonely", "Lonely")

      assert frame(site, @category_path, %{"slug" => "lonely"}).translations == []
    end
  end

  describe "the languages of a tag" do
    test "are its editions, each at its own slug and under its own name", %{site: site} do
      elixir = tag!(site, "en", "elixir", "Elixir")
      tag!(site, "fa", "alixir", "الکسیر", group(elixir))

      reading = frame(site, @tag_path, %{"slug" => "elixir"})

      assert addresses(reading) == %{
               "en" => "/blog/tag/elixir",
               "fa" => "/fa/blog/tag/alixir"
             }

      assert titles(reading) == %{"en" => "Elixir", "fa" => "الکسیر"}
    end

    test "leave out a locked edition for a guest, and offer it to a reader who holds the lock",
         %{site: site} do
      elixir = tag!(site, "en", "elixir", "Elixir")
      tag!(site, "fa", "alixir", "الکسیر", group(elixir), permissions: ["members:read"])

      member = create_user_with_permissions!(["members:read"], site_id: site.id)

      assert languages(frame(site, @tag_path, %{"slug" => "elixir"})) == []

      assert languages(frame(site, @tag_path, %{"slug" => "elixir"}, as: member)) ==
               ["en", "fa"]
    end

    test "are none for a tag written in one language only", %{site: site} do
      tag!(site, "en", "solo", "Solo")

      assert frame(site, @tag_path, %{"slug" => "solo"}).translations == []
    end
  end

  # A BLOGGER AND A TEAM ARE ONE ROW IN EVERY LANGUAGE, so each language the site publishes in is
  # their edition, at the same slug.
  describe "the languages of a blogger and of a team" do
    test "are each language of the site, at the same slug", %{site: site} do
      create_blogger!(site_id: site.id, display_name: "Ada Lovelace", slug: "ada")
      create_team!(site_id: site.id, name: "Core", slug: "core", status: :active)

      blogger = frame(site, @author_path, %{"slug" => "ada"}, language: "fa")

      assert addresses(blogger) == %{
               "en" => "/blog/author/ada",
               "fa" => "/fa/blog/author/ada",
               "ar" => "/ar/blog/author/ada"
             }

      assert titles(blogger) |> Map.values() |> Enum.uniq() == ["Ada Lovelace"]

      team = frame(site, @team_path, %{"slug" => "core"})

      assert languages(team) == ["en", "fa", "ar"]
      assert addresses(team)["ar"] == "/ar/blog/team/core"
      assert titles(team)["en"] == "Core"
    end

    test "follow the languages the site publishes in", %{site: site} do
      {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      create_blogger!(site_id: site.id, display_name: "Ada Lovelace", slug: "ada")

      assert languages(frame(site, @author_path, %{"slug" => "ada"})) == ["en", "fa"]
    end

    test "are none when the slug names nobody", %{site: site} do
      assert frame(site, @author_path, %{"slug" => "nobody"}).translations == []
      assert frame(site, @team_path, %{"slug" => "nobody"}).translations == []
    end
  end

  # A LIST PAGE IS THE SAME PAGE IN EVERY LANGUAGE, so what the layout would offer is right.
  describe "a list page" do
    test "keeps the languages the layout would offer without a plugin", %{site: site} do
      same_path = [
        %{language: "en", path: "/blog"},
        %{language: "fa", path: "/fa/blog"},
        %{language: "ar", path: "/ar/blog"}
      ]

      for path <- Provision.page_paths(),
          path not in Map.values(Provision.item_paths()) do
        given = given(site, path, %{}, translations: same_path)

        assert frame(given).translations == given.translations,
               "#{path} was given languages other than the ones the layout offers"

        assert languages(frame(given)) == ["en", "fa", "ar"]
      end
    end
  end

  describe "the pages it does not own" do
    test "go back untouched, whatever the plugin chain does after", %{site: site} do
      docs =
        SiteLayout.given(
          %{path: "/:lang/docs/:slug", section: "document", language: "en", title: "Doc"},
          site_id: site.id,
          extra: %{"record" => "document:page"},
          params: %{"slug" => "install"}
        )

      assert PageFrame.call(docs) == {:reply, docs}

      plain =
        SiteLayout.given(%{path: "/about", section: nil, language: "en", title: "About"},
          site_id: site.id
        )

      assert PageFrame.call(plain) == {:reply, plain}
    end

    test "a page of another section that shows a blog record gets its languages and no bar",
         %{site: site} do
      english = published!(site, "en", "elsewhere", "Elsewhere")
      published!(site, "fa", "jaye-digar", "جای دیگر", group(english))

      given =
        SiteLayout.given(
          %{path: "/:lang/read/:slug", section: "site", language: "en", title: "Read"},
          site_id: site.id,
          extra: %{"record" => "blog:post"},
          params: %{"slug" => "elsewhere", "lang" => "en"}
        )

      reading = frame(given)

      assert addresses(reading) == %{
               "en" => "/read/elsewhere",
               "fa" => "/fa/read/jaye-digar"
             }

      assert reading.section_bar == nil
    end
  end

  describe "the bar" do
    # THE DESIGN'S: the blog's name, led to its front page, and its four places.
    test "is the blog's name and its four places, each at its page", %{site: site} do
      bar = frame(site, @blog_path, %{}).section_bar

      assert bar.title == "Blog"
      assert bar.title_path == "/blog"

      assert Enum.map(bar.links, &{&1.label, &1.path}) == [
               {"Posts", "/blog"},
               {"Categories", "/blog/categories"},
               {"Tags", "/blog/tags"},
               {"People", "/blog/people"}
             ]

      # the search is the list pages' own, and the bar has nothing trailing and no crumbs
      assert Map.take(bar, [:component, :assigns, :crumbs]) ==
               %{component: nil, assigns: %{}, crumbs: []}
    end

    test "is drawn in the language of the response, at the addresses the URL mode gives",
         %{site: site} do
      {:ok, _} = Settings.put("site.language_urls", "prefix_all", site_id: site.id)

      bar = frame(site, @blog_path, %{}, language: "fa").section_bar

      assert bar.title_path == "/fa/blog"

      assert Enum.map(bar.links, & &1.path) == [
               "/fa/blog",
               "/fa/blog/categories",
               "/fa/blog/tags",
               "/fa/blog/people"
             ]
    end

    test "says its words in the site's translations, and in English where nobody wrote them",
         %{site: site} do
      :ok = TranslationsState.put(site.id, "fa", "Blog", "وبلاگ")
      :ok = TranslationsState.put(site.id, "fa", "Posts", "نوشته‌ها")
      :ok = TranslationsState.put(site.id, "fa", "People", "افراد")

      persian = frame(site, @blog_path, %{}, language: "fa").section_bar

      assert persian.title == "وبلاگ"
      assert Enum.map(persian.links, & &1.label) == ["نوشته‌ها", "Categories", "Tags", "افراد"]

      english = frame(site, @blog_path, %{}, language: "en").section_bar

      assert english.title == "Blog"
      assert Enum.map(english.links, & &1.label) == ["Posts", "Categories", "Tags", "People"]
    end

    # A POST, A CATEGORY AND A TAG ARE IN POSTS; A BLOGGER AND A TEAM ARE IN PEOPLE; EVERY OTHER PAGE
    # IS IN THE PLACE IT IS THE FRONT OF.
    test "marks the one place the reader is in, on every page of the blog", %{site: site} do
      paths = Provision.item_paths()

      places = %{
        "/:lang/blog" => "Posts",
        paths.post => "Posts",
        paths.category => "Posts",
        paths.tag => "Posts",
        "/:lang/blog/categories" => "Categories",
        "/:lang/blog/tags" => "Tags",
        paths.author => "People",
        paths.team => "People",
        "/:lang/blog/people" => "People"
      }

      assert Enum.sort(Map.keys(places)) == Enum.sort(Provision.page_paths())

      for {path, place} <- places do
        bar = frame(site, path, %{"slug" => "anything"}).section_bar
        current = for %{current: true, label: label} <- bar.links, do: label

        assert current == [place], "#{path} is in #{place}, the bar says #{inspect(current)}"
      end
    end

    test "is on every page the blog writes, and only on the blog's section", %{site: site} do
      for path <- Provision.page_paths() do
        assert %{links: [_, _, _, _]} = frame(site, path, %{"slug" => "anything"}).section_bar
      end

      plain =
        SiteLayout.given(%{path: "/:lang/blog", section: "site", language: "en", title: "Blog"},
          site_id: site.id
        )

      assert PageFrame.call(plain) == {:reply, plain}
    end

    # THE BAR IS THE CORE'S MARKUP, so what this asserts is that what the blog hands it is drawn: one
    # nav of links, the current one marked to a screen reader, and a bar that wraps and scrolls
    # sideways rather than overflowing a phone.
    test "is drawn by the layout with the current place marked, ready for a phone", %{site: site} do
      html = rendered_bar(frame(site, @post_path, %{"slug" => "anything"}).section_bar)
      doc = LazyHTML.from_fragment(html)

      assert doc
             |> LazyHTML.query(~s([data-role="site-section-bar"] > div > a))
             |> LazyHTML.text()
             |> String.trim() == "Blog"

      links = LazyHTML.query(doc, ~s([data-role="site-section-links"] a))

      assert links |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim())) == [
               "Posts",
               "Categories",
               "Tags",
               "People"
             ]

      assert doc
             |> LazyHTML.query(~s([data-role="site-section-links"] a[aria-current="page"]))
             |> LazyHTML.text()
             |> String.trim() == "Posts"

      assert html =~ "flex-wrap"
      assert html =~ "overflow-x-auto"
    end
  end

  describe "registered" do
    test "on the event the layout fires, in the application's plugins" do
      assert PageFrame.config(:__event__) == SiteLayout.event()
      assert PageFrame in MishkaBlog.Application.plugins()
    end

    # THE BAR'S WORDS ARE IN NO TEMPLATE, so the translations screen would call them unused and
    # "Remove unused" would delete them and what a translator wrote.
    test "the bar's words are among the keys the site still uses", %{site: site} do
      assert TranslationKeys.config(:__event__) == Translations.used_keys_event()
      assert TranslationKeys in MishkaBlog.Application.plugins()

      used = Translations.used_keys(site.id)

      assert PageFrame.words() -- MapSet.to_list(used) == []
      assert Enum.sort(PageFrame.words()) == ["Blog", "Categories", "People", "Posts", "Tags"]
    end

    test "so the layout's own call reaches it and its answer is the page's", %{site: site} do
      english = published!(site, "en", "through-the-chain", "Through the chain")
      published!(site, "fa", "az-zanjir", "از زنجیر", group(english))

      frame =
        SiteLayout.frame(
          %{path: @post_path, section: "blog", language: "en", title: "Blog post"},
          site_id: site.id,
          extra: %{"record" => "blog:post"},
          params: %{"slug" => "through-the-chain", "lang" => "en"},
          translations: []
        )

      assert languages(frame) == ["en", "fa"]
      assert frame.section_bar.title == "Blog"
      assert Enum.find(frame.section_bar.links, & &1.current).label == "Posts"
    end
  end

  defp category!(site, language, slug, name, group \\ nil, overrides \\ []) do
    [site_id: site.id, name: name, slug: slug, language: language, status: :active]
    |> in_group(group)
    |> Keyword.merge(overrides)
    |> create_collection!()
  end

  defp tag!(site, language, slug, name, group \\ nil, overrides \\ []) do
    [site_id: site.id, name: name, slug: slug, language: language]
    |> in_group(group)
    |> Keyword.merge(overrides)
    |> create_blog_tag!()
  end
end
