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

  alias MishkaBlog.Plugins.Installer
  alias MishkaBlog.Provision
  alias MishkaCmsCore.Install.Extensions
  alias MishkaCmsCore.Runtime.Component
  alias MishkaCmsCore.Runtime.Languages
  alias MishkaCmsCore.Runtime.Page
  alias MishkaCmsCore.Runtime.PageProvision
  alias MishkaCmsCore.Runtime.Snippet
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
  defp attr_name(attr), do: to_string(attr["name"] || attr[:name])

  # THE BLOG'S OWN WORDS ARE TRANSLATABLE. Its headings and its header's links ask `t/1` for their
  # text, so `/fa/blog` reads Persian once somebody writes it — and creating the pages registers
  # the words, so they are waiting in Translations the moment the blog is installed.
  describe "the blog's words" do
    test "every heading and header link asks t/1, none is written in English", %{site: site} do
      Provision.ensure!(site)
      templates = site |> pages() |> Enum.map(& &1.template) |> Enum.join("\n")

      for word <- [
            "Categories",
            "Tags",
            "People",
            "Latest posts",
            "Recent posts",
            "Search",
            "Blog",
            "Posts",
            "Teams",
            "Members",
            "Writers"
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

      assert page(site, "/:lang/blog").template =~
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
