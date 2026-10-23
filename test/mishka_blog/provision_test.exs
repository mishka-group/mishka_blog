# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.ProvisionTest do
  @moduledoc """
  What a site is given when it is provisioned, and — the half that matters more — what it is never
  given twice.

  `MishkaBlog.Provision.ensure!/2` is reached from two screens that can both run at any moment: the install
  wizard, for the extensions an operator ticked, and a button an admin can press as often as they
  like — both through `installer:extension:install`. So
  every case here is written around the second run: the components, pages and snippet a site already
  has must come through it untouched, including the ones an admin edited, archived or replaced.

  The templates are not rendered here. `Page :master_create` compiles every one of them through
  `Validations.PageCodeCompiles` before it writes the row, so a sample page that does not compile
  fails these tests at the moment it is created; what the components then draw is
  `MishkaBlog.LiveComponentsRenderTest`.
  """
  use MishkaBlog.DataCase, async: false

  import ExUnit.CaptureLog

  alias MishkaBlog.Plugins.{Installer, PageFrame}
  alias MishkaBlog.Provision
  alias MishkaBlog.Provision.Earlier
  alias MishkaCmsCore.Install
  alias MishkaCmsCore.Install.{Bootstrap, Extensions}
  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.ExtensionProvision
  alias MishkaCmsCore.Runtime.Handlers.UiKitUpgrade
  alias MishkaCmsCore.Runtime.Helpers
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Media
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageProvision
  alias MishkaCmsCore.Runtime.SiteLayout
  alias MishkaCmsCore.Runtime.Snippet
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaInstaller.Event.EventHandler

  require Ash.Query

  @moduletag :integration

  # THE EVENT THE PLUGIN ITSELF DECLARES, not one spelled out again here. Spelling it out would
  # test the event compiler and leave the one thing that can silently drift — whether this plugin is
  # listening where the installer fires — asserted by nothing.
  @event Installer.config(:__event__)

  setup do
    name = "provisiontown#{System.unique_integer([:positive])}"
    {:ok, site: create_site!(name: name, host: "#{name}.test", active: true)}
  end

  defp components(site), do: rows(Component, :read_any, site)
  defp archived_components(site), do: rows(Component, :master_archived, site)
  defp pages(site), do: rows(Page, :read_any, site)

  defp rows(resource, action, site) do
    resource
    |> Ash.Query.for_read(action, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(page: [limit: 100])
    |> then(& &1.results)
  end

  defp component(site, name), do: Enum.find(components(site), &(&1.name == name))

  # The `{key, language}` rows the site holds for `keys`, sorted.
  defp registered(site, keys) do
    MishkaCmsCore.Runtime.Translation
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(key in ^keys and site_id == ^site.id)
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.map(&{&1.key, &1.language})
    |> Enum.sort()
  end

  defp page(site, path), do: Enum.find(pages(site), &(&1.path == path))

  defp snippets(site) do
    Snippet
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site.id)
    |> Ash.read!(page: [limit: 100])
    |> then(& &1.results)
  end

  # THE CALLS A STORED TEMPLATE MAKES, as the templates are written: `<.component …/>` with one
  # attribute per line, which is what lets a key be taken from the start of a line and never out of
  # the middle of somebody's `empty_text`. The dispatch's own keys are not the component's
  # attributes — `LiveViewHelpers.component/1` reads `component_name` and `site` and drops them, and
  # `id` is LiveView's.
  defp component_calls(source) do
    ~r|<\.component\b(.*?)/>|s
    |> Regex.scan(source)
    |> Enum.map(fn [_whole, call] ->
      [_all, name] = Regex.run(~r/component_name="([^"]+)"/, call)

      given =
        ~r/^\s*([a-z_][a-z0-9_]*)=(.*)$/m
        |> Regex.scan(call)
        |> Enum.map(fn [_whole, key, value] -> {key, written_as(value)} end)
        |> Enum.reject(fn {key, _value} -> key in ~w(component_name site id) end)

      {name, given}
    end)
  end

  defp component_keys(source),
    do:
      Enum.map(component_calls(source), fn {name, given} ->
        {name, Enum.map(given, &elem(&1, 0))}
      end)

  # How a value is written, which for a base is half of what it means: a `"literal"` is stored in the
  # page and reaches the component as it stands, while an `{expression}` is HEEx and is evaluated per
  # request against that request's assigns. Anything else is neither, and is handed back as it was so
  # the rule refusing it can say what it found.
  defp written_as(~s(") <> rest), do: {:literal, String.trim_trailing(rest, ~s("))}
  defp written_as("{" <> rest), do: {:expression, String.trim_trailing(rest, "}")}
  defp written_as(other), do: {:neither, other}

  # Every page this module writes, and the snippet, by the name to put in a failure message.
  defp templates(site) do
    Enum.map(pages(site), &{&1.path, &1.template}) ++
      Enum.map(snippets(site), &{&1.name, &1.source})
  end

  # Both spellings, for the reason `ComponentCompiler.declared_keys/1` takes both: a declaration is a
  # map that has been through JSON and through Ash's own casting.
  # credo:disable-for-next-line ExSlop.Check.Warning.DualKeyAccess
  defp attr_name(attr), do: to_string(attr["name"] || attr[:name])

  # THE BLOG'S OWN WORDS ARE TRANSLATABLE. Its headings ask `t/1` for their text, so `/fa/blog` reads
  # Persian once somebody writes it — and creating the pages registers the words, so they are
  # waiting in Translations the moment the blog is installed. The words of the bar under the header
  # are asked for by `MishkaBlog.Plugins.PageFrame`, not by a template, so provisioning registers
  # those itself.
  describe "the blog's words" do
    test "every heading asks t/1, none is written in English", %{site: site} do
      Provision.ensure!(site)
      templates = site |> templates() |> Enum.map_join("\n", &elem(&1, 1))

      for word <- [
            "Categories",
            "Tags",
            "People",
            "Latest posts",
            "Recent posts",
            "Search",
            "Posts by %{name}",
            "The people behind it",
            "Teams",
            "Members",
            "Writers",
            "Comments",
            "Keep reading"
          ] do
        assert templates =~ ~s|t("#{word}")|, "#{word} is not asked of t/1"
      end

      refute templates =~ ~s(heading="), "a heading is still written in English"
    end

    test "are registered in the site's languages when the pages are created", %{site: site} do
      on_exit(fn ->
        MishkaCmsCore.Runtime.States.SettingsState.delete(site.id, "site.languages")
      end)

      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en", "fa"], site_id: site.id)

      Provision.ensure!(site)

      languages =
        MishkaCmsCore.Runtime.Translation
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
        |> Ash.Query.filter(key == "Categories" and site_id == ^site.id)
        |> Ash.read!(authorize?: false, page: false)
        |> Enum.map(& &1.language)
        |> Enum.sort()

      assert languages == ["en", "fa"]
    end

    test "registers the words of the bar in each language, and keeps what a translator wrote",
         %{site: site} do
      on_exit(fn ->
        MishkaCmsCore.Runtime.States.SettingsState.delete(site.id, "site.languages")
      end)

      {:ok, _} = MishkaCmsCore.Settings.put("site.languages", ["en", "fa"], site_id: site.id)
      words = PageFrame.words()

      assert Enum.sort(words) == ["Blog", "Categories", "People", "Posts", "Tags"]
      assert registered(site, words) == []

      Provision.ensure!(site)

      assert registered(site, words) ==
               for(word <- Enum.sort(words), language <- ["en", "fa"], do: {word, language})

      {:ok, _} =
        MishkaCmsCore.Runtime.Translation
        |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
        |> Ash.Query.filter(key == "Posts" and language == "fa" and site_id == ^site.id)
        |> Ash.read_one!(authorize?: false)
        |> Ash.Changeset.for_update(:update, %{value: "نوشته‌ها"}, authorize?: false)
        |> Ash.update(authorize?: false)

      Provision.ensure!(site)

      assert Enum.sort(registered(site, words)) ==
               for(word <- Enum.sort(words), language <- ["en", "fa"], do: {word, language})

      assert Ash.read_one!(
               Ash.Query.filter(
                 MishkaCmsCore.Runtime.Translation,
                 key == "Posts" and language == "fa" and site_id == ^site.id
               ),
               authorize?: false
             ).value == "نوشته‌ها"
    end
  end

  describe "the first run" do
    # THE BLOG'S OWN PERMISSION NAMES ARRIVE WITH IT, as its components do, and not with
    # the core install: the first site's run creates them, and every later site finds them.
    test "creates the blog's permission names, and another site's run creates none", %{
      site: site
    } do
      names = Enum.map(Provision.manifest().permissions, &elem(&1, 0))

      assert names != []
      assert stored_permissions(names) == []

      assert Provision.ensure!(site).permissions == names
      assert Enum.sort(stored_permissions(names)) == Enum.sort(names)

      assert Provision.ensure!(create_site!()).permissions == []
    end

    test "installs every component the bundle ships, scoped to this site", %{site: site} do
      report = Provision.ensure!(site)

      assert Enum.sort(report.components) == Enum.sort(Provision.component_names())

      for name <- Provision.component_names() do
        found = component(site, name)

        assert found, "#{name} was not installed"
        assert found.site_id == site.id
      end
    end

    test "creates the sample pages, every one of them in the blog section", %{site: site} do
      report = Provision.ensure!(site)

      assert report.pages == Provision.page_paths()

      for path <- Provision.page_paths() do
        found = page(site, path)

        assert found, "#{path} was not created"
        assert found.section == "blog"
        assert found.site_id == site.id
        assert found.active == true
      end
    end

    # THE PAGE SAYS WHAT IT SHOWS, so its SEO is the record's whatever path it is later given.
    # THE HEADER, THE LANGUAGE SWITCHER AND THE FOOTER ARE THE LAYOUT'S, so a page of the blog draws
    # none of them and is given the layout the site's own pages hang on. A site installed without
    # starter content has none, and its pages are written with no layout rather than with a wrong one.
    test "hangs every page on the site's site-main layout when it has one", %{site: site} do
      layout = create_layout!(site_id: site.id, name: "site-main")
      create_layout!(site_id: site.id, name: "another")

      Provision.ensure!(site)

      assert Enum.map(Provision.page_paths(), &page(site, &1).layout_id) ==
               List.duplicate(layout.id, length(Provision.page_paths()))
    end

    test "writes the pages with no layout when the site has no site-main", %{site: site} do
      create_layout!(site_id: site.id, name: "another")

      Provision.ensure!(site)

      assert Enum.map(Provision.page_paths(), &page(site, &1).layout_id) ==
               List.duplicate(nil, length(Provision.page_paths()))
    end

    # A SITE SET UP BEFORE ITS PAGES CARRIED A LAYOUT, or before it had one, is brought onto it by the
    # next run: `SiteLayout.adopt_pages/3` hangs the pages that have none on `site-main`. A page an
    # admin moved to another layout keeps it.
    test "hangs the pages a site holds with no layout on its site-main at the next run", %{
      site: site
    } do
      Provision.ensure!(site)
      assert Enum.all?(Provision.page_paths(), &(page(site, &1).layout_id == nil))

      layout = create_layout!(site_id: site.id, name: "site-main")
      other = create_layout!(site_id: site.id, name: "another")

      moved = page(site, "/:lang/blog/people")

      moved
      |> Ash.Changeset.for_update(:master_update, %{layout_id: other.id}, authorize?: false)
      |> Ash.update!()

      report = Provision.ensure!(site)

      assert Enum.sort(report.adopted_pages) ==
               Enum.sort(Provision.page_paths() -- ["/:lang/blog/people"])

      for path <- Provision.page_paths() -- ["/:lang/blog/people"] do
        assert page(site, path).layout_id == layout.id, "#{path} is not on site-main"
      end

      assert page(site, "/:lang/blog/people").layout_id == other.id

      assert Provision.ensure!(site).adopted_pages == []
    end

    test "marks each page that shows a record with the kind it shows", %{site: site} do
      Provision.ensure!(site)
      paths = Provision.item_paths()

      assert page(site, paths.post).extra["record"] == "blog:post"
      assert page(site, paths.category).extra["record"] == "blog:category"
      assert page(site, paths.tag).extra["record"] == "blog:tag"
      assert page(site, paths.author).extra["record"] == "blog:author"
      assert page(site, paths.team).extra["record"] == "blog:team"
      refute Map.has_key?(page(site, "/:lang/blog").extra || %{}, "record")
      refute Map.has_key?(page(site, "/:lang/blog/people").extra || %{}, "record")

      # EVERY KIND THE BLOG NAMES HAS A PAGE OF ITS OWN HERE, so none of them is offered to an
      # editor with nowhere to be shown.
      kinds = Enum.map(MishkaBlog.Plugins.PageRecords.types(site.id), & &1.id)

      shown =
        for path <- Provision.page_paths(),
            record = (page(site, path).extra || %{})["record"],
            is_binary(record),
            do: record

      assert Enum.sort(kinds) ==
               ["blog:author", "blog:category", "blog:post", "blog:tag", "blog:team"]

      assert Enum.sort(shown) == Enum.sort(kinds)
    end

    # A PAGE DRAWS STRAIGHT INTO THE LAYOUT'S COLUMN. The header, the bar under it, the footer, the
    # language switcher and the dark-mode toggle are the `site-main` layout's, and so are the column's
    # width and its gutters (`MishkaCmsCore.Runtime.SiteLayout`): a page that drew a bar of its own
    # would show the blog's name twice, and one that drew a container of its own would double the
    # gutters and set the page narrower than the header above it.
    test "draws every page with no chrome and no outer container of its own", %{site: site} do
      Provision.ensure!(site)

      for path <- Provision.page_paths() do
        template = page(site, path).template

        for tag <- ["<header", "<main", "<footer", "min-h-screen", "blog-sidebar"] do
          refute template =~ tag, "#{path} draws #{tag}, which is the layout's"
        end

        for bar <- ["blog-section-nav", ~s(aria-current="page"), "<nav"] do
          refute template =~ bar, "#{path} draws #{bar}, the bar the layout draws from the plugin"
        end

        for container <- ["mx-auto", "max-w-[1160px]", "1160px"] do
          refute template =~ container, "#{path} draws #{container}, which is the layout's"
        end

        # the elements the page begins with, at the left edge of the template
        for [opening] <- Regex.scan(~r/^<(?:div|section|article|aside)\b[^>]*>/m, template),
            [_whole, classes] <- Regex.scan(~r/\bclass="([^"]*)"/, opening) do
          refute classes =~ ~r/(?:^|\s)(?:mx-|max-w-|min-w-|w-screen|container)/,
                 "#{path} begins with a box that sets its own width: #{classes}"

          refute classes =~ ~r/(?:^|\s)(?:px|ps|pe|pl|pr)-/,
                 "#{path} begins with a box that sets its own side padding: #{classes}"
        end
      end

      people = page(site, "/:lang/blog/people").template

      assert people =~ "<h1"
      assert people =~ ~s|t("The people behind it")|
      refute people =~ ~s|heading={t("People")}|, "the block would head the page a second time"
    end

    # THE ROOMS A PAGE KEEPS ARE ITS OWN: the room above its first section, which the layout cannot
    # know, so the list pages begin with the design's `pt-16` and the home with the same.
    test "gives a page the room above its first section and nothing at its sides", %{site: site} do
      Provision.ensure!(site)

      assert page(site, "/:lang/blog").template =~ ~r/\A<section class="[^"]*\bpt-16\b/
      assert page(site, "/:lang/blog/people").template =~ ~r/\A<section class="[^"]*\bpt-16\b/
    end

    # WHO WRITES THE BLOG HAS PAGES TOO: a blogger's, a team's, and everybody at once, each drawn by
    # the block that reads it and linking to the others under the language capture.
    test "gives a blogger, a team and everybody who writes a page of their own", %{site: site} do
      Provision.ensure!(site)
      paths = Provision.item_paths()

      assert paths.author == "/:lang/blog/author/:slug"
      assert paths.team == "/:lang/blog/team/:slug"

      for {path, block} <- [
            {paths.author, "blog-author-profile"},
            {paths.team, "blog-team-profile"},
            {"/:lang/blog/people", "blog-people"}
          ] do
        calls = component_calls(page(site, path).template)
        assert Enum.any?(calls, &(elem(&1, 0) == block)), "#{path} does not draw #{block}"
      end

      {"blog-people", given} =
        Enum.find(
          component_calls(page(site, "/:lang/blog/people").template),
          &(elem(&1, 0) == "blog-people")
        )

      assert {"author_base", {:literal, "/:lang/blog/author"}} in given
      assert {"team_base", {:literal, "/:lang/blog/team"}} in given

      assert page(site, paths.author).template =~
               ~s|site_path("/:lang/blog/people", @page.language)|

      assert page(site, paths.team).template =~
               ~s|site_path("/:lang/blog/people", @page.language)|
    end

    # A PAGE IS ONE ROW FOR EVERY LANGUAGE. `:lang` is a capture the resolver fills from the URL and
    # `MishkaCmsCore.Runtime.Languages` admits only the site's own languages into — so six rows serve
    # a site publishing in five languages, and a template reads which one it was asked for.
    test "as pattern pages, so one row answers every language the site publishes in", %{
      site: site
    } do
      Provision.ensure!(site)

      for path <- Provision.page_paths() do
        assert String.starts_with?(path, "/:lang/"),
               "#{path} pins a language, so the site's other languages have no blog"
      end

      assert page(site, "/:lang/blog").template =~ "@page.language"
    end

    # AN ATTRIBUTE A COMPONENT DOES NOT DECLARE IS AN ERROR NOWHERE. `ComponentCompiler` splits what
    # a page passes by the component's own declarations and sweeps everything else into its global
    # attr, which the template renders onto its root element — so `language={@page.language}` handed
    # to a component declaring no `language` becomes `language="fa"` in the public HTML, the helper
    # reading it is given nil, and the page still draws. A rename in the bundle, or a typo here, is
    # therefore silent in every other test: a page renders, and does the older thing.
    #
    # This is the one place the two halves are held together, and it can only hold the halves in this
    # checkout — a site that already has the components keeps the ones it has (see the moduledoc).
    test "hands each component only attributes that component declares", %{site: site} do
      Provision.ensure!(site)

      declared =
        Map.new(components(site), fn component ->
          {component.name, MapSet.new(component.attrs, &attr_name/1)}
        end)

      for {where, source} <- templates(site) do
        calls = component_keys(source)

        assert calls != [],
               "no component call was read out of #{where}, so nothing is asserted of it"

        for {name, given} <- calls, key <- given do
          assert Map.has_key?(declared, name),
                 "#{where} draws #{name}, which the bundle does not ship"

          assert MapSet.member?(declared[name], key),
                 "#{where} hands #{name} an undeclared #{key}, which nothing reads"
        end
      end
    end

    # THE ONE WAY A LINK BASE MAY BE WRITTEN, held to for every call rather than for the ones
    # somebody remembered. A `*_base` is a path a component appends a row's slug to and fills the
    # `lang` segment of from THAT ROW's language, so it is a literal carrying the capture: written
    # with the reader's own language in it every translation of a post is offered under the language
    # the reader is leaving, and written with no language in it at all the link is a path this site
    # has no page at. `base` is the opposite and has to be this page's real URL, because it is what a
    # pager writes to the address bar — so it is the address `site_path/2` builds from the page's own
    # language, at the place the site's URL mode puts it.
    #
    # Which names those are is read off the components, so a base added to the bundle is covered here
    # the day it arrives rather than the day somebody remembers this test. The capture is looked for
    # as the literal `:lang` segment rather than through `Languages.captures?/1`, which is a question
    # about a page's PATH and admits `*lang` as well: `slug_href/4` in the bundle fills a base as a
    # pattern of `:name` segments, and a base is written in that one spelling.
    test "builds every link base from the language capture and every URL from the page", %{
      site: site
    } do
      Provision.ensure!(site)
      capture = ":" <> Languages.capture()

      bases =
        for component <- components(site),
            attr <- component.attrs,
            name = attr_name(attr),
            name == "base" or String.ends_with?(name, "_base"),
            into: MapSet.new(),
            do: name

      checked =
        for {where, source} <- templates(site),
            {name, given} <- component_calls(source),
            {key, value} <- given,
            MapSet.member?(bases, key) do
          case key do
            "base" ->
              assert {:expression, expression} = value,
                     "#{where} writes #{name}'s base as #{inspect(value)}, and a pager's URL is this page's own"

              assert expression =~ ~r/^site_path\(/,
                     "#{where} writes #{name} a pager URL the site's URL mode does not build: #{expression}"

              assert expression =~ "@page.language",
                     "#{where} writes #{name} a base holding no language of its own: #{expression}"

            _link_base ->
              assert {:literal, literal} = value,
                     "#{where} writes #{name}'s #{key} as #{inspect(value)}, and a link base is the same path on every request"

              assert capture in String.split(literal, "/"),
                     "#{where} hands #{name} a #{key} of #{literal}, which cannot lead to another language's edition"
          end

          key
        end

      assert checked != [],
             "no base was read out of the sample pages, so this asserts nothing of them"
    end

    # AND EVERY URL WRITTEN OUT BY HAND IS ONE OF THE PAGES THIS MODULE CREATES. A base names a row's
    # address and the rule above holds it to the capture; the pagers' and the header's URLs are the
    # other kind — they name a PAGE — so one that has drifted from the path it was copied from is a
    # link to the 404 with nothing in this suite to notice it. Read as the pattern `site_path/2` is
    # handed, which is the form the page definitions themselves are in.
    test "writes no URL of its own that it does not also create a page at", %{site: site} do
      Provision.ensure!(site)
      paths = Enum.map(Provision.page_paths(), &String.split(&1, "/", trim: true))

      written =
        for {where, source} <- templates(site),
            [_whole, address] <- Regex.scan(~r/site_path\("([^"]*)"/, source) do
          assert Enum.any?(paths, &List.starts_with?(&1, String.split(address, "/", trim: true))),
                 "#{where} links #{address}, which is no page this module creates"

          address
        end

      assert written != [],
             "no URL was read out of the sample pages, so this asserts nothing of them"
    end

    test "saves the sidebar as a snippet the page editor can offer", %{site: site} do
      report = Provision.ensure!(site)

      assert report.snippets == [Provision.snippet_name()]

      assert [snippet] = snippets(site)
      assert snippet.name == Provision.snippet_name()
      assert snippet.section == :page
      assert snippet.scope == :shared
      assert snippet.source =~ "blog-tag-cloud"
    end

    test "takes a site id as well as the record", %{site: site} do
      report = Provision.ensure!(site.id)

      assert length(report.pages) == length(Provision.page_paths())
      assert length(components(site)) == length(Provision.component_names())
    end

    test "says so rather than half-provisioning a site that is not there" do
      assert_raise ArgumentError, ~r/no site/, fn ->
        Provision.ensure!(Ash.UUID.generate())
      end
    end
  end

  describe "running it again" do
    setup %{site: site} do
      Provision.ensure!(site)
      :ok
    end

    test "creates nothing at all, and says every page is already there", %{site: site} do
      report = Provision.ensure!(site)

      assert %{components: [], pages: [], snippets: []} = report
      assert Enum.map(report.skipped_pages, & &1.path) == Provision.page_paths()

      assert length(components(site)) == length(Provision.component_names())
      assert length(pages(site)) == length(Provision.page_paths())
      assert length(snippets(site)) == 1
    end

    # THE REASON THE WHOLE MODULE IS WRITTEN THE WAY IT IS. `UiKitHandler.install_kit!/2` upserts, so
    # a second install of a name the site already has would overwrite the admin's work with the
    # bundle's copy and say nothing about it.
    test "keeps an edit an admin made to a component", %{site: site} do
      before = component(site, "blog-post-list")

      {:ok, edited} =
        Ash.update(before, %{template: ~S(<div id={@id}>mine</div>)},
          action: :master_update,
          authorize?: false,
          tenant: site.id
        )

      assert Provision.ensure!(site).components == []

      after_second = component(site, "blog-post-list")
      assert after_second.id == edited.id
      assert after_second.template == ~S(<div id={@id}>mine</div>)
    end

    test "keeps a page an admin rewrote", %{site: site} do
      before = page(site, "/:lang/blog")

      {:ok, edited} =
        Ash.update(before, %{template: ~S(<div>my own blog home</div>)},
          action: :master_update,
          authorize?: false,
          tenant: site.id
        )

      assert Provision.ensure!(site).pages == []

      after_second = page(site, "/:lang/blog")
      assert after_second.id == edited.id
      assert after_second.template == ~S(<div>my own blog home</div>)
    end

    # AND THE ONE CASE WHERE THAT EDIT CAN ACTUALLY BE LOST. Every other case here runs the
    # installer with nothing missing, where it is never called at all — so `selection:` decides
    # nothing and could be deleted without a test noticing. A site missing ONE name is where it
    # decides everything: `install_kit!/2` upserts every component of the bundle it is handed, so
    # without the selection the five rows that are already there are written over on the way to the
    # one that is not. A bundle that grows a component, or a row somebody deleted outright, is how a
    # site gets here.
    test "installs the one component that is missing and writes over none of the others", %{
      site: site
    } do
      gone = component(site, "blog-tag-cloud")
      mine = component(site, "blog-post-list")

      :ok =
        Ash.destroy!(gone, action: :master_permanent_destroy, authorize?: false, tenant: site.id)

      {:ok, _edited} =
        Ash.update(mine, %{template: ~S(<div id={@id}>mine</div>)},
          action: :master_update,
          authorize?: false,
          tenant: site.id
        )

      assert Provision.ensure!(site).components == ["blog-tag-cloud"]

      assert component(site, "blog-tag-cloud"), "the component that was gone was not installed"

      assert component(site, "blog-post-list").template == ~S(<div id={@id}>mine</div>),
             "the installer wrote the bundle's copy over an edit the admin made"
    end

    # ARCHIVING IS AN ANSWER, not an absence. The installer skips an archived row rather than
    # reviving it, so re-offering the name would report an install that did not happen — and the
    # admin who archived it would find it back in the palette.
    test "leaves a component the admin archived where they put it", %{site: site} do
      archived = component(site, "blog-tag-cloud")
      :ok = Ash.destroy!(archived, action: :master_destroy, authorize?: false, tenant: site.id)

      assert Provision.ensure!(site).components == []

      refute component(site, "blog-tag-cloud"), "an archived component came back as a new row"
      assert Enum.any?(archived_components(site), &(&1.name == "blog-tag-cloud"))
    end
  end

  # THE PAGES AS THE RELEASE BEFORE WROTE THEM: its templates, and no layout, which is what a site set
  # up then holds.
  defp age_pages!(site, paths \\ Provision.page_paths()) do
    for path <- paths do
      page = page(site, path)

      Ash.update!(
        page,
        %{
          template: Earlier.template(path, site.name),
          layout_id: nil,
          extra: Map.put(page.extra, "provisioned_version", "3.9.0")
        },
        action: :master_update,
        authorize?: false,
        tenant: site.id
      )
    end
  end

  defp edit_page!(site, path, template) do
    site
    |> page(path)
    |> Ash.update!(%{template: template},
      action: :master_update,
      authorize?: false,
      tenant: site.id
    )
  end

  # A page is stored without the newline its template ends in, so both are read that way.
  defp shipped(site),
    do: Map.new(Provision.sample_pages(site), &{&1.path, String.trim(&1.template)})

  defp earlier(site, path), do: site.name |> then(&Earlier.template(path, &1)) |> String.trim()

  # A SITE THE RELEASE BEFORE SET UP. Its pages hold the templates that release wrote, each with a
  # header of its own, and no layout: the state `Provision.ensure!/3` finds on a production site.
  # The site has the `site-main` layout its starter content wrote, unless a test says it does not.
  describe "a site the release before set up" do
    setup %{site: site} do
      layout = create_layout!(site_id: site.id, name: "site-main")
      Provision.ensure!(site)
      age_pages!(site)

      {:ok, layout: layout}
    end

    test "takes the new design on every page nobody edited, and says which", %{
      site: site,
      layout: layout
    } do
      shipped = shipped(site)
      assert Enum.all?(Provision.page_paths(), &(page(site, &1).template == earlier(site, &1)))

      report = Provision.ensure!(site)

      assert Enum.sort(report.upgraded_pages) == Enum.sort(Provision.page_paths())
      assert Enum.sort(report.adopted_pages) == Enum.sort(Provision.page_paths())

      for path <- Provision.page_paths() do
        upgraded = page(site, path)

        assert upgraded.template == shipped[path], "#{path} did not take the new template"
        assert upgraded.layout_id == layout.id

        # nothing of the page but its markup moved: where it answers, what it shows, who gave it
        assert upgraded.path == path
        assert upgraded.section == "blog"
        assert upgraded.extra["serves_all_languages"] == true
        assert PageProvision.ours?(upgraded, :mishka_blog)
        assert PageProvision.provisioned_version(upgraded) == Provision.bundle_version()

        # the header and the column of their own are the layout's now, so the page has neither
        refute upgraded.template =~ "max-w-6xl"
        refute upgraded.template =~ ~s(<header)
        refute upgraded.template =~ "bg-[#f6f5f2]"
      end

      assert page(site, Provision.item_paths().post).extra["record"] == "blog:post"
    end

    test "leaves a page alone that was edited, and the others still take it", %{site: site} do
      post = Provision.item_paths().post
      edited_tail = earlier(site, "/:lang/blog") <> "\n<p>My own footnote.</p>"
      edited_word = String.replace(earlier(site, post), "Recent posts", "Newest posts")
      assert edited_word != earlier(site, post)

      edit_page!(site, "/:lang/blog", edited_tail)
      edit_page!(site, post, edited_word)

      report = Provision.ensure!(site)

      assert Enum.sort(report.upgraded_pages) ==
               Enum.sort(Provision.page_paths() -- ["/:lang/blog", post])

      assert page(site, "/:lang/blog").template == edited_tail
      assert page(site, post).template == edited_word

      shipped = shipped(site)

      for path <- Provision.page_paths() -- ["/:lang/blog", post] do
        assert page(site, path).template == shipped[path]
      end
    end

    test "leaves a page alone that an admin moved to another layout", %{site: site} do
      other = create_layout!(site_id: site.id, name: "another")
      path = "/:lang/blog/people"

      site
      |> page(path)
      |> Ash.update!(%{layout_id: other.id},
        action: :master_update,
        authorize?: false,
        tenant: site.id
      )

      report = Provision.ensure!(site)

      assert Enum.sort(report.upgraded_pages) == Enum.sort(Provision.page_paths() -- [path])
      assert page(site, path).template == earlier(site, path)
      assert page(site, path).layout_id == other.id
    end

    test "leaves a page alone that another extension gave the site", %{site: site} do
      path = "/:lang/blog/tags"
      row = page(site, path)

      Ash.update!(row, %{extra: Map.put(row.extra, "provisioned_by", "mishka_document")},
        action: :master_update,
        authorize?: false,
        tenant: site.id
      )

      report = Provision.ensure!(site)

      assert path not in report.upgraded_pages
      assert page(site, path).template == earlier(site, path)
    end

    test "takes a page of a site that was renamed since, and one given another path", %{
      site: site
    } do
      path = "/:lang/blog/tags"

      site
      |> page(path)
      |> Ash.update!(%{path: "/:lang/journal/tags"},
        action: :master_update,
        authorize?: false,
        tenant: site.id
      )

      report = Provision.ensure!(site)

      assert "/:lang/journal/tags" in report.upgraded_pages
      assert page(site, "/:lang/journal/tags").template == shipped(site)[path]
    end

    test "changes nothing when it is run again", %{site: site} do
      first = Provision.ensure!(site)
      assert length(first.upgraded_pages) == length(Provision.page_paths())

      before = pages(site)
      second = Provision.ensure!(site)

      assert %{
               upgraded_pages: [],
               upgraded_components: [],
               adopted_pages: [],
               pages: [],
               components: []
             } = second

      assert Enum.map(pages(site), &{&1.id, &1.template, &1.updated_at}) ==
               Enum.map(before, &{&1.id, &1.template, &1.updated_at})
    end

    test "writes a page nobody edited as the admin who asked, a master or a site's own", %{
      site: site
    } do
      names = ExtensionProvision.required(Provision.manifest())
      master = create_user_with_permissions!(names, site_id: nil)
      tenant = create_user_with_permissions!(names, site_id: site.id)

      first = Provision.ensure!(site.id, %{}, actor: tenant)

      assert Enum.sort(first.upgraded_pages) == Enum.sort(Provision.page_paths())
      assert page(site, "/:lang/blog").template == shipped(site)["/:lang/blog"]

      age_pages!(site, ["/:lang/blog/tags"])
      second = Provision.ensure!(site.id, %{}, actor: master)

      assert second.upgraded_pages == ["/:lang/blog/tags"]
      assert page(site, "/:lang/blog/tags").template == shipped(site)["/:lang/blog/tags"]
    end
  end

  describe "a site the release before set up, with no site-main layout" do
    test "keeps its pages as they are, each complete in itself", %{site: site} do
      Provision.ensure!(site)
      age_pages!(site)

      report = Provision.ensure!(site)

      assert report.upgraded_pages == []
      assert report.adopted_pages == []

      for path <- Provision.page_paths() do
        assert page(site, path).template == earlier(site, path)
        assert page(site, path).layout_id == nil
      end
    end
  end

  # THE COMPONENTS THE NEW PAGES ARE WRITTEN FOR. A site installed from an older bundle is aged the
  # only way a test can age one: its rows put back to what an older bundle wrote and stamped as
  # though that bundle had written them (the same state `MishkaBlogWeb.Test.KitUpgradeButtonTest`
  # makes), so only the version is behind and nobody here touched them.
  describe "the kit components of a site set up from an older bundle" do
    setup %{site: site} do
      Provision.ensure!(site)

      for component <- components(site) do
        older = %{component | description: "as #{component.name} read at 3.9.0"}

        Ash.update!(
          component,
          %{
            description: older.description,
            extra:
              component.extra
              |> Map.put("ui_kit_version", "3.9.0")
              |> Map.put("ui_kit_digest", UiKitUpgrade.digest(older))
          },
          action: :master_update,
          authorize?: false,
          tenant: site.id
        )
      end

      :ok
    end

    test "are brought forward when nobody edited them, and said so", %{site: site} do
      report = Provision.ensure!(site)

      assert Enum.sort(report.upgraded_components) == Enum.sort(Provision.component_names())

      for component <- components(site) do
        assert component.extra["ui_kit_version"] == Provision.bundle_version()
        assert UiKitUpgrade.digest(component) == component.extra["ui_kit_digest"]
        refute component.description =~ "3.9.0"
      end

      assert Provision.ensure!(site).upgraded_components == []
    end

    test "are left where they are when an admin edited them, and the rest still move", %{
      site: site
    } do
      mine = ~S(<div id={@id}>mine</div>)

      site
      |> component("blog-post-list")
      |> Ash.update!(%{template: mine},
        action: :master_update,
        authorize?: false,
        tenant: site.id
      )

      report = Provision.ensure!(site)

      assert "blog-post-list" not in report.upgraded_components

      assert Enum.sort(report.upgraded_components) ==
               Enum.sort(Provision.component_names() -- ["blog-post-list"])

      kept = component(site, "blog-post-list")
      assert kept.template == mine
      assert kept.extra["ui_kit_version"] == "3.9.0"
    end

    test "are left where they are when an admin archived them", %{site: site} do
      archived = component(site, "blog-tag-cloud")
      :ok = Ash.destroy!(archived, action: :master_destroy, authorize?: false, tenant: site.id)

      report = Provision.ensure!(site)

      assert "blog-tag-cloud" not in report.upgraded_components
      assert "blog-tag-cloud" in Enum.map(archived_components(site), & &1.name)
      assert "blog-tag-cloud" not in Enum.map(components(site), & &1.name)
    end
  end

  describe "a path that is not free" do
    test "is left to whoever holds it, and the rest are still created", %{site: site} do
      taken = List.last(Provision.page_paths())

      mine =
        create_page!(
          site_id: site.id,
          path: taken,
          template: ~S(<div>mine</div>)
        )

      report = Provision.ensure!(site)

      refute taken in report.pages
      assert length(report.pages) == length(Provision.page_paths()) - 1
      assert page(site, taken).id == mine.id
      assert page(site, taken).template == ~S(<div>mine</div>)

      assert [held] = report.skipped_pages
      assert held.path == taken
      assert PageProvision.note(held) =~ ~s(its path "#{taken}" is taken)
    end

    # AN ARCHIVED PAGE COUNTS AS HOLDING ITS PATH, which is stricter than the index: that one is
    # partial on `(archived_at IS NULL)` and would take the write. A site that took it would hold a
    # second page at an address it has already used, and the archived one could never come back.
    test "counts a page the admin archived as holding it", %{site: site} do
      taken = hd(Provision.page_paths())

      mine = create_page!(site_id: site.id, path: taken, template: ~S(<div>mine</div>))
      :ok = Ash.destroy!(mine, action: :master_destroy, authorize?: false, tenant: site.id)

      report = Provision.ensure!(site)

      refute taken in report.pages
      refute page(site, taken)
    end
  end

  # THE OTHER IDENTITY A PAGE ROW HAS, and the one no reading of paths can see. Left as a skip, it
  # was the one that mattered: `MishkaCmsCore.Dev.Seeds` writes a page called "Blog" at `/blog` on
  # every seeded site, so on every seeded site the blog's INDEX — the one page carrying
  # `blog-featured-posts` — was the single page never written, at an address nothing had taken, and
  # no later run was ever going to write it. A held name is now answered with the next free one.
  describe "a name that is not free" do
    test "is answered with another name, at the address the blog is read at", %{site: site} do
      mine =
        create_page!(
          site_id: site.id,
          name: "Blog",
          path: "/weblog",
          template: ~S(<div>mine</div>)
        )

      report = Provision.ensure!(site)

      assert report.pages == Provision.page_paths(),
             "the definition whose name was taken was left out"

      assert report.snippets == [Provision.snippet_name()],
             "the run stopped before the snippet"

      assert report.skipped_pages == []

      index = page(site, hd(Provision.page_paths()))

      assert index, "the blog's index was not created"
      assert index.name == "blog-2"
      assert index.template =~ "blog-featured-posts"

      assert [renamed] = report.renamed_pages

      assert PageProvision.note(renamed) =~ ~s(its name "blog" is taken),
             "the admin is not told why their page is called something else"

      assert PageProvision.note(renamed) =~ ~s(so it was created as "blog-2")

      assert page(site, "/weblog").id == mine.id
      assert page(site, "/weblog").template == ~S(<div>mine</div>)
    end

    # THE NAME AS THE ROW CARRIES IT, which is not the name anybody typed: `master_create` slugifies
    # it, so "BLOG" and "Blog Post" are these definitions' names too and a comparison of the literals
    # would miss every one of them.
    test "counts one the site spelled its own way, and a second run still adds nothing", %{
      site: site
    } do
      create_page!(
        site_id: site.id,
        name: "BLOG",
        path: "/weblog",
        template: ~S(<div>mine</div>)
      )

      assert Provision.ensure!(site).pages == Provision.page_paths()

      assert %{components: [], pages: [], snippets: [], renamed_pages: []} =
               Provision.ensure!(site)
    end

    # AND A RERUN IS NOT A SECOND RENAME. The page is there at its own address now, so the PATH is
    # what holds it — a run that read only the name would find it taken all over again and write a
    # third copy of the blog's index at an address that already answers.
    test "does not write it again under yet another name on the next run", %{site: site} do
      create_page!(
        site_id: site.id,
        name: "Blog",
        path: "/weblog",
        template: ~S(<div>mine</div>)
      )

      Provision.ensure!(site)
      report = Provision.ensure!(site)

      assert report.pages == []
      assert report.renamed_pages == []
      assert Enum.map(report.skipped_pages, & &1.path) == Provision.page_paths()
      assert length(pages(site)) == length(Provision.page_paths()) + 1
    end
  end

  # REGISTERED HERE RATHER THAN RELIED ON FROM BOOT, the way `MishkaBlog.Test.HooksTest` does it:
  # `MishkaBlog.Application` starts its plugins while this suite's Mnesia registry is not up yet —
  # `test/test_helper.exs` starts that after the applications — so nothing this extension ships is
  # registered by the time a test runs. In production the registry is up first and boot does this.
  # `register/0` IS THE PLUGIN'S OWN, and it is an upsert keyed on the plugin name — so this is safe
  # whether or not the extension's supervisor already registered it at boot. `Event.write/1` is not:
  # it would leave two rows answering to one key, which is exactly what `Extensions.install/3`
  # refuses to pretend is one install.
  defp listening! do
    {:ok, _registered} = Installer.register()
    :ok = EventHandler.do_compile(@event, :start, false)
    :ok
  end

  describe "the sidebar snippet" do
    # `Snippet`'s `unique_name_per_scope` is `[:name, :site_id, :section, :document_id]` with
    # `nils_distinct? false`, so a snippet an author saved out of ONE page's editor under this name
    # holds a different key entirely — the shared one the sidebar needs is still free. Counting it
    # would leave the site with nothing to drop into a page and report `snippets: []` as though it
    # had it.
    test "is still created beside one an author saved under the same name on a page", %{
      site: site
    } do
      page = create_page!(site_id: site.id, path: "/keeper", template: ~S(<div>mine</div>))

      Snippet
      |> Ash.Changeset.for_create(
        :master_create,
        %{
          name: Provision.snippet_name(),
          source: ~S(<div>mine</div>),
          section: :page,
          scope: :page,
          document_id: page.id,
          site_id: site.id
        },
        authorize?: false
      )
      |> Ash.create!()

      assert Provision.ensure!(site).snippets == [Provision.snippet_name()]

      assert [shared] = Enum.filter(snippets(site), &is_nil(&1.document_id))
      assert shared.scope == :shared
      assert shared.source =~ "blog-tag-cloud"
    end
  end

  describe "installing on request" do
    setup do: listening!()

    # THE EVENT IS THE ONLY DOOR. Core never names this module; it fires the event and whichever
    # plugin answers to the key does the work — which is what makes a second extension nothing more
    # than a second plugin.
    test "gives the site everything when the installer names this extension", %{site: site} do
      assert {:ok, report} = Extensions.install(site.id, "mishka_blog")

      assert length(components(site)) == length(Provision.component_names())
      assert Enum.sort(Enum.map(pages(site), & &1.path)) == Enum.sort(Provision.page_paths())
      assert length(snippets(site)) == 1
      assert report.pages != []
    end

    # EVERY PLUGIN ON THE EVENT SEES EVERY CALL, so answering to somebody else's key would install
    # the blog when the operator asked for the shop.
    test "does nothing at all when the installer names another extension", %{site: site} do
      assert {:error, :no_plugin_answered} = Extensions.install(site.id, "mishka_shop")

      assert components(site) == []
      assert pages(site) == []
      assert snippets(site) == []
    end

    # THE SITE REMEMBERS, IN THE SITE'S OWN SETTINGS. That is what sends an admin to the dashboard
    # instead of the installer on every visit after the first.
    test "records the version the site was set up at", %{site: site} do
      refute Extensions.installed?(site.id, :mishka_blog)

      assert Extensions.active?(site.id, :mishka_blog),
             "an extension is wanted until switched off"

      assert {:ok, _report} = Extensions.install(site.id, "mishka_blog")

      assert Extensions.installed?(site.id, :mishka_blog)
      assert Extensions.installed_version(site.id, :mishka_blog) == Provision.bundle_version()
    end

    # A SITE THAT WAS NOT SET UP MUST NOT LOOK AS IF IT WAS, or its menu opens a dashboard onto pages
    # that are not there and never offers to finish the job.
    test "records nothing when no plugin answered", %{site: site} do
      assert {:error, :no_plugin_answered} = Extensions.install(site.id, "mishka_shop")

      refute Extensions.installed?(site.id, "mishka_shop")
    end

    # EVERY SITE THAT EXISTED BEFORE THERE WAS AN INSTALLER has this extension and no record of how
    # it got there. Asking the setting alone would show all of them the installer, which is the
    # opposite of what it is for — so a site with no record is ASKED, on this same event, and the
    # answer is written down so it is asked once.
    test "a site that already has the pages counts as installed, record or no record", %{
      site: site
    } do
      refute Extensions.installed?(site.id, :mishka_blog)

      assert {:ok, _report} = Extensions.install(site.id, "mishka_blog")

      {:ok, _} = MishkaCmsCore.Settings.put("mishka_blog.installed", "", site_id: site.id)

      assert Extensions.installed?(site.id, :mishka_blog),
             "a site running the blog was told it had never been set up"

      assert Extensions.installed_version(site.id, :mishka_blog) == "unknown",
             "the answer was not written down, so it would be asked again on every render"
    end

    # ANY OF THE PAGES IS ENOUGH, and a page of another site is not this site's.
    test "a site holding one of the pages counts as installed, and one holding none does not", %{
      site: site
    } do
      refute Extensions.installed?(site.id, :mishka_blog)

      other = create_site!(active: true)
      create_page!(site_id: other.id, path: hd(Provision.page_paths()), active: true)

      refute Extensions.installed?(site.id, :mishka_blog),
             "a page of another site made this site look set up"

      create_page!(site_id: site.id, path: hd(Provision.page_paths()), active: true)

      assert Extensions.installed?(site.id, :mishka_blog)
    end

    # THE SCREEN GETS A FIXED MESSAGE, never the exception's own text; the log has the detail. An
    # admin of another site holds every name the install asks for, so the refusal is the
    # provision's own check of whose site it is, which raises after the plugin's permission gate.
    test "a failed install reports the fixed message and logs the exception", %{site: site} do
      elsewhere =
        create_site!(name: "elsewhere#{System.unique_integer([:positive])}", active: true)

      tenant = create_user_with_permissions!(["admin:dashboard:*"], site_id: elsewhere.id)

      log =
        capture_log(fn ->
          assert {:error, {:extension_failed, message}} =
                   Extensions.install(site.id, "mishka_blog", %{}, tenant)

          assert message ==
                   "The install did not finish. Press Install again; details are in the server log."

          refute message =~ "admin:dashboard"
        end)

      assert log =~ "[MishkaBlog] install on #{site.id} failed:"
      assert log =~ "a site admin may only provision their own site"
      refute Extensions.installed?(site.id, :mishka_blog)
      assert components(site) == []
    end

    test "is offered by the installer's own registry, with the label it declared" do
      assert entry = Enum.find(Extensions.offered(), &(&1.key == "mishka_blog"))

      assert entry.label == "Blog"
      assert entry.app == :mishka_blog
      assert entry.plugin == Installer
      assert entry.fields == []
    end

    # A SITE IS NEVER SET UP BEHIND SOMEBODY'S BACK. Creating one used to queue this work; it does
    # not any more, and a site added to a running CMS waits to be asked.
    test "is not what creating a site does" do
      name = "untouched#{System.unique_integer([:positive])}"
      site = create_site!(name: name, host: "#{name}.test", active: true)

      assert components(site) == []
      assert pages(site) == []
      assert snippets(site) == []
    end
  end

  # WHO MAY ASK. A request with nobody behind it is the install wizard's own run, made before there
  # is a user, and it is answered only until the CMS is installed. After that it is refused like an
  # actor holding nothing, and nothing is written.
  describe "who may ask for an install" do
    setup do
      :persistent_term.erase(:mishka_installed)
      on_exit(fn -> :persistent_term.erase(:mishka_installed) end)

      listening!()
    end

    test "a request with nobody behind it installs while the CMS is not installed yet", %{
      site: site
    } do
      refute Install.installed?()

      assert {:ok, report} = Extensions.install(site.id, "mishka_blog")

      assert report.pages != []
      assert length(components(site)) == length(Provision.component_names())
      assert Extensions.installed?(site.id, :mishka_blog)
    end

    test "a request with nobody behind it is refused once the CMS is installed, and writes nothing",
         %{site: site} do
      Install.mark_installed!()
      names = Enum.map(Provision.manifest().permissions, &elem(&1, 0))

      assert {:error, {:extension_failed, message}} = Extensions.install(site.id, "mishka_blog")

      for name <- ExtensionProvision.required(Provision.manifest()) do
        assert message =~ name
      end

      refute Extensions.installed?(site.id, :mishka_blog)
      assert components(site) == []
      assert pages(site) == []
      assert snippets(site) == []
      assert stored_permissions(names) == []
    end

    for {who, master?} <- [{"a master", true}, {"a site admin", false}] do
      @master? master?

      test "#{who} holding every name installs once the CMS is installed", %{site: site} do
        Install.mark_installed!()

        admin =
          create_user_with_permissions!(["*"], site_id: if(@master?, do: nil, else: site.id))

        assert {:ok, report} = Extensions.install(site.id, "mishka_blog", %{}, admin)

        assert report.pages != []
        assert length(components(site)) == length(Provision.component_names())
        assert Extensions.installed?(site.id, :mishka_blog)
      end
    end

    for installed? <- [false, true] do
      @installed? installed?

      test "an actor holding none of what it writes is refused and nothing is written, #{if installed?, do: "after", else: "before"} the CMS is installed",
           %{site: site} do
        if @installed?, do: Install.mark_installed!()
        weak = create_user_with_permissions!(["admin:dashboard:blog:post"], site_id: site.id)

        assert {:error, {:extension_failed, message}} =
                 Extensions.install(site.id, "mishka_blog", %{}, weak)

        assert message =~ "needs these permissions"
        assert message =~ "admin:dashboard:runtime:component"
        refute Extensions.installed?(site.id, :mishka_blog)
        assert components(site) == []
        assert pages(site) == []
      end
    end

    test "the install wizard sets the blog up with nobody behind the request, and the same request is refused after it",
         %{site: site} do
      assert {:ok, %{site: first}} =
               Bootstrap.run(%{
                 email: "owner-#{System.unique_integer([:positive])}@example.com",
                 password: "Password123!",
                 site_name: "Blog wizard",
                 host: "wizard-#{System.unique_integer([:positive])}.example.com",
                 extensions: ["mishka_blog"]
               })

      # THE RUN COMPILES THE SITE ONTO DISK, as it does for a real one: its templates under
      # `priv/static/temp/runtime/<name>` and the media the starter content saves under
      # `uploads/<id>`. Neither goes away with the database's rollback, so each is removed here.
      on_exit(fn ->
        SiteState.delete(first.id)
        File.rm_rf(Helpers.static_temp_dir(["runtime", first.name]))
        File.rm_rf(Path.join([Media.static_dir(), "uploads", first.id]))
      end)

      assert Install.installed?()
      assert Extensions.installed?(first.id, :mishka_blog)
      # the site's own starter components (its header and footer) are there beside the blog's
      assert Provision.component_names() -- Enum.map(components(first), & &1.name) == []
      assert Provision.page_paths() -- Enum.map(pages(first), & &1.path) == []

      # AND THE BLOG'S PAGES HANG ON THE LAYOUT THE WIZARD WROTE FIRST, with its header and footer
      layout_id = SiteLayout.layout_id(first.id)
      assert <<_uuid::binary-size(36)>> = layout_id

      for path <- Provision.page_paths() do
        assert page(first, path).layout_id == layout_id, "#{path} is not on site-main"
      end

      assert {:error, {:extension_failed, _message}} = Extensions.install(site.id, "mishka_blog")

      refute Extensions.installed?(site.id, :mishka_blog)
      assert components(site) == []
    end
  end

  describe "the mark its pages carry" do
    test "says this extension gave the site the page, at the bundle's version", %{site: site} do
      MishkaBlog.Provision.ensure!(site.id)

      pages = provisioned_pages(site.id)

      assert pages != [], "the run wrote no pages to check"

      for page <- pages do
        assert MishkaCmsCore.Runtime.PageProvision.ours?(page, :mishka_blog),
               "#{page.path} carries no mark saying who gave it to the site"

        assert MishkaCmsCore.Runtime.PageProvision.provisioned_version(page) ==
                 MishkaBlog.Provision.bundle_version()
      end
    end
  end

  defp provisioned_pages(site_id) do
    paths = MishkaBlog.Provision.page_paths()

    MishkaCmsCore.Runtime.Page
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(site_id == ^site_id)
    |> Ash.read!(authorize?: false, page: [limit: 100])
    |> Map.fetch!(:results)
    |> Enum.filter(&(&1.path in paths))
  end

  # A SITE FOUND ALREADY SET UP is recorded without a run, so the names a run would have created
  # come from the answer to "is it already here?".
  describe "a site found already set up" do
    test "gets the blog's permission names it is missing", %{site: site} do
      assert {:ok, _report} = Extensions.install(site.id, "mishka_blog")
      names = Enum.map(Provision.manifest().permissions, &elem(&1, 0))

      MishkaCmsCore.Accounts.Permission
      |> Ash.Query.filter(name in ^names)
      |> Ash.read!(authorize?: false, page: false)
      |> Enum.each(&Ash.destroy!(&1, authorize?: false))

      {:ok, _} = MishkaCmsCore.Settings.put("mishka_blog.installed", "", site_id: site.id)
      assert stored_permissions(names) == []

      assert Extensions.installed?(site.id, :mishka_blog)
      assert Enum.sort(stored_permissions(names)) == Enum.sort(names)
    end
  end

  defp stored_permissions(names) do
    MishkaCmsCore.Accounts.Permission
    |> Ash.Query.filter(name in ^names)
    |> Ash.read!(authorize?: false, page: false)
    |> Enum.map(& &1.name)
  end
end
