# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.KitTest do
  @moduledoc """
  The bundle this extension ships, and the rows installing it writes.

  ## Why the components are data and not code

  The live components arrive as `priv/cms_ui_kits/mishka_blog.json` and are installed through the
  CMS's own kit machinery — the same path Chelekom's 136 take. Everything a component is travels in
  that file: its markup, its declarations, and its own code, including the Ash reads it runs.

  That is what makes it a component rather than a library with a component-shaped wrapper. It can be
  imported one at a time or in batches, edited in the admin like any other row, and carries no
  dependency on an Elixir module a third-party importer would not have.

  ## What is asserted here and what is not

  This suite does not start the CMS's compilers — `test/test_helper.exs` says why: they belong to
  running a site rather than to answering an API call. So what is pinned here is the bundle's shape
  and the rows the installer writes from it. Compiling them, rendering them on a page and clicking
  them is `MishkaBlog.LiveComponentsRenderTest`.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaCmsCore.Runtime.{Component, Stylesheet}

  require Ash.Query

  @moduletag :integration

  # THE TWO KINDS, AND WHICH IS WHICH. A live component runs its own query and holds what it read;
  # a function component is markup the live ones hand their rows to. Splitting them here is what
  # lets every assertion below ask the right question of each — a function component has no socket,
  # so it has no `mount/1`, no `id={@id}` and nothing to aim an event at.
  @live ~w(blog-post-list blog-featured-posts blog-post-search blog-tag-cloud blog-post-detail
           blog-category-list blog-post-comments blog-related-posts blog-author-profile blog-team-profile
           blog-people)

  @functions ~w(blog-post-card blog-post-meta blog-term-row blog-pager blog-notice
                blog-profile-card)

  @names @live ++ @functions

  # The RESOURCES a component reads through Ash. Everything else under `MishkaBlog.` is this
  # extension's Elixir, and a component that called one would stop being installable by anyone who
  # does not also have that code.
  @resources ~w(MishkaBlog.BlogPost MishkaBlog.Tag MishkaBlog.Collection MishkaBlog.Comment
                MishkaBlog.Blogger MishkaBlog.Team)

  # A read as the stored code writes it: the resource, then the action it is run for.
  @read_call ~r/MishkaBlog\.(\w+)\s*\|>\s*Ash\.Query\.for_read\(\s*:(\w+)/

  setup do
    site = create_site!(name: "blogtown", host: "blogtown.test", active: true)
    {:ok, _installed} = MishkaBlog.Kit.install!(site.id)
    {:ok, site: site}
  end

  defp bundle, do: MishkaBlog.Kit.bundle_path() |> File.read!() |> Jason.decode!()

  # The components one component's markup draws, read off the template the way
  # `MishkaCmsCore.Runtime.CssClosure` reads reachability: the literal name in the call, never a
  # name built at runtime.
  defp drawn_siblings(component) do
    ~r/component_name="([^"]+)"/
    |> Regex.scan(component["template"])
    |> Enum.map(fn [_whole, name] -> name end)
    |> Enum.uniq()
  end

  defp components, do: bundle()["components"]

  defp row(name, site) do
    Component
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(name == ^name and site_id == ^site.id)
    |> Ash.read_one!()
  end

  describe "the bundle" do
    test "is a v3 kit bundle, which is what the installer reads" do
      assert bundle()["$schema"] == "mishka.ui_kit.bundle.v3"
      assert bundle()["name"] == "mishka_blog"
    end

    test "ships exactly the seventeen components, each of the kind it is listed under" do
      assert Enum.map(components(), & &1["name"]) |> Enum.sort() == Enum.sort(@names)

      for component <- components() do
        assert component["stateful"] == component["name"] in @live,
               "#{component["name"]} is the other kind of component"
      end
    end

    # THE POINT OF THE WHOLE SHAPE. A component's stored code may call the standard library, Ash and
    # Phoenix, and its own helpers — and nothing of this extension's. The moment one reaches for a
    # `MishkaBlog.*` function it stops being installable by anyone who does not also have this
    # Elixir code, which is the coupling moving to a bundle was meant to remove.
    #
    # `@resources` are RESOURCES, not helpers: a component reads posts the way any caller does,
    # through Ash.
    test "and no component's code calls into this extension's own modules" do
      allowed = @resources

      for component <- components(), helper <- component["helpers"] do
        offenders =
          ~r/MishkaBlog\.[A-Za-z.]+/
          |> Regex.scan(helper["code"])
          |> List.flatten()
          |> Enum.reject(&(&1 in allowed))

        assert offenders == [],
               "#{component["name"]}'s #{helper["name"]} calls #{inspect(offenders)}"
      end
    end

    test "and neither does any template" do
      allowed = @resources

      for component <- components() do
        offenders =
          ~r/MishkaBlog\.[A-Za-z.]+/
          |> Regex.scan(component["template"])
          |> List.flatten()
          |> Enum.reject(&(&1 in allowed))

        assert offenders == [], "#{component["name"]}'s template calls #{inspect(offenders)}"
      end
    end

    # EVERY ASSIGN THE MARKUP READS IS DECLARED, or the component raises inside a visitor's LiveView
    # the first time a page leaves that attribute out.
    test "declares every assign its own markup reads" do
      # `streams` IS LIVEVIEW'S OWN. `Phoenix.LiveView.stream/4` puts it on the socket and there is
      # no attribute to declare it with — a block that streams its rows reads `@streams.posts` and
      # declares `posts` nowhere.
      injected = ~w(id rest myself socket flash inner_block streams)

      for component <- components() do
        declared = MapSet.new(component["attrs"], & &1["name"])
        slots = MapSet.new(component["slots"] || [], & &1["name"])
        local = MapSet.new(read_assigns(component["template"]))

        missing =
          local
          |> MapSet.difference(declared)
          |> MapSet.difference(slots)
          |> MapSet.difference(MapSet.new(injected))
          |> MapSet.difference(MapSet.new(lifecycle_assigns(component)))

        assert MapSet.size(missing) == 0,
               "#{component["name"]} reads #{inspect(MapSet.to_list(missing))} and declares none of it"
      end
    end

    # AND IN THE FORM THE BUNDLE ACTUALLY WRITES. `socket |> assign(:one, value)` is how every
    # helper here puts a single key on the socket, and the scan behind the assertion above saw only
    # `assign(socket, :one, value)` — so a component holding a piece of state that arrives that way
    # and nowhere else failed as an undeclared attribute, which is the staleness the hand-kept list
    # was replaced to end.
    test "and counts a piece of state a helper writes only in the piped form" do
      component = %{
        "helpers" => [
          %{"name" => "load", "code" => "socket |> Phoenix.Component.assign(:cursor, 1)\n"}
        ]
      }

      assert "cursor" in lifecycle_assigns(component)
    end

    # PLAIN HTML AND TAILWIND, AND NOBODY ELSE'S COMPONENTS. A site may install this extension and
    # skip Chelekom — the installer's component step offers it and nothing forces it — and the
    # blog's cards, headings, badges and empty states were drawn with `chelekom-card` and friends.
    # On such a site every post on the page came out as the runtime's red "failed to render" box,
    # and the bundle said `"dependencies": []`, so nothing anywhere admitted the coupling.
    test "and draws itself without another kit, which a production site may not have installed" do
      for component <- components() do
        refute component["template"] =~ "chelekom-",
               "#{component["name"]} calls Chelekom, and a site that skipped it renders a red box"

        for called <- drawn_siblings(component) do
          assert called in @names,
                 "#{component["name"]} draws #{called}, which this bundle does not ship"
        end
      end
    end

    # A SIBLING IT DRAWS IS A SIBLING IT NEEDS. The split gave the live blocks function components
    # to draw their rows with, and `<.component component_name="blog-post-card"/>` against a site
    # with no such row is the runtime's red "failed to render" box — so the row says what it needs,
    # in the field the admin's component list already shows and
    # `MishkaCmsCore.Runtime.Handlers.UiKitUpgrade` reads when it carries an update onto a site that
    # was installed before the split.
    test "and every component it draws is a dependency it declares, and the reverse" do
      for component <- components() do
        called = drawn_siblings(component)

        for name <- called do
          assert name in component["dependencies"],
                 "#{component["name"]} draws #{name} and declares no dependency on it"
        end

        for declared <- component["dependencies"] do
          assert declared in called,
                 "#{component["name"]} declares #{declared} and its template never draws it"
        end
      end
    end

    # NOTHING IS SHIPPED FOR NOBODY. A function component exists to be drawn by another component;
    # one no other row names is a row a site compiles, an admin reads and the palette offers, and
    # nothing draws.
    test "and every function component is drawn by another" do
      needed =
        components()
        |> Enum.flat_map(& &1["dependencies"])
        |> Enum.uniq()

      for name <- @functions do
        assert name in needed, "#{name} is drawn by nothing this bundle ships"
      end
    end

    # EDITOR HINTS ARE PART OF THE COMPONENT, not documentation kept somewhere else. The inspector
    # reads `opts.doc` for the line under a control and `opts.values` for a dropdown in place of a
    # text box — see `MishkaCmsCore.Runtime.PageBuilder.Inspector` — so an attribute shipping
    # neither is a blank field an author has to guess the accepted words for.
    test "and every author-facing attribute explains itself to the inspector" do
      for component <- components(),
          attr <- component["attrs"],
          attr["type"] != "global" do
        assert attr["opts"]["doc"] not in [nil, ""],
               "#{component["name"]}'s #{attr["name"]} has nothing to say for itself"

        assert Map.has_key?(attr["opts"], "default"),
               "#{component["name"]}'s #{attr["name"]} declares no default, so a page that leaves " <>
                 "it out raises rather than falling back"
      end
    end

    test "and the ones with a fixed set of answers offer that set" do
      for component <- components(),
          attr <- component["attrs"],
          attr["name"] in ~w(variant sort) do
        values = attr["opts"]["values"]

        assert is_list(values) and values != [],
               "#{component["name"]}'s #{attr["name"]} is a dropdown with nothing in it"

        assert attr["opts"]["default"] in values,
               "#{component["name"]}'s #{attr["name"]} defaults to a word it does not offer"
      end
    end

    # NOBODY MAY ASK FOR MORE ROWS THAN THEY WILL BE GIVEN. Every public read these components run
    # caps a page, and Ash SHRINKS a larger ask down to that cap rather than refusing it — so an
    # over-ask is silent. A comment thread asking for the whole conversation dead-ended at the
    # hundredth comment with its "load more" button still on the page; a tag cloud offering an
    # author 200 quietly drew 100; and every commenter past the hundredth was called "Reader".
    # The ceiling is read off the actions the components name, not written down here.
    test "and never asks a read for more rows than that read will hand back" do
      caps =
        for component <- components(),
            helper <- component["helpers"],
            [_whole, resource, action] <- Regex.scan(@read_call, helper["code"]),
            cap = page_cap(resource, action),
            is_integer(cap),
            do: cap

      assert caps != [], "no read was recognised, so this asserts nothing"
      ceiling = Enum.min(caps)

      for component <- components(),
          helper <- component["helpers"],
          [_whole, asked] <- Regex.scan(~r/page: \[limit: (\d+)/, helper["code"]) do
        assert String.to_integer(asked) <= ceiling,
               "#{component["name"]}'s #{helper["name"]} asks for #{asked} rows and is given #{ceiling}"
      end

      for component <- components(),
          attr <- component["attrs"],
          is_integer(attr["opts"]["max"]) do
        assert attr["opts"]["max"] <= ceiling,
               "#{component["name"]}'s #{attr["name"]} lets an author ask for " <>
                 "#{attr["opts"]["max"]}, and #{ceiling} is what one read returns"
      end
    end

    # A LOCKED RECORD IS LEFT OUT FOR THE READER THE READ NAMES. An action that keeps a list to what
    # its reader may open (`MishkaBlog.Resources.Preparations.OpenToActor`) reads as the system, and
    # lists every locked record, when it is not told who is reading.
    test "and every read that keeps to its reader names the visitor it reads for" do
      kept =
        for component <- components(),
            helper <- component["helpers"],
            {resource, action, given} <- read_calls(helper["code"]),
            keeps_to_reader?(resource, action) do
          assert given =~ "read_as(",
                 "#{component["name"]}'s #{helper["name"]} reads #{resource} through :#{action} " <>
                   "without naming the visitor"

          action
        end

      assert kept != [],
             "no read that keeps to its reader was recognised, so this asserts nothing"
    end

    # AND READS AS THAT VISITOR, through the public action's own policies. `authorize?: false` with
    # the visitor named beside it is a read of the system's that filters itself, and every rule the
    # action keeps that the filter does not repeat is skipped for every visitor at once.
    test "and reads as the visitor, never as the system" do
      for component <- components(), helper <- component["helpers"] do
        refute helper["code"] =~ "authorize?: false",
               "#{component["name"]}'s #{helper["name"]} reads as the system"
      end

      read_as =
        for component <- components(),
            helper <- component["helpers"],
            helper["name"] == "read_as",
            do: {component["name"], helper["code"]}

      assert read_as != [], "no component carries read_as/1, so this asserts nothing"

      for {name, code} <- read_as do
        assert code =~ "actor: visitor", "#{name}'s read_as/1 does not read as the visitor"
      end
    end

    # A BACKGROUND READ RUNS IN THE PAGE'S LOCALE. `MishkaGervaz.Messages.start_async/4` carries the
    # page's Gettext locales into the task; Phoenix's own leaves it in the default one. The host's
    # `MishkaCms.AsyncLocaleTest` holds compiled code to that, and a component's code is not compiled
    # until a site draws it.
    test "and starts a background read in the page's locale" do
      started =
        for component <- components(),
            helper <- component["helpers"],
            helper["code"] =~ ~r/\b(start|assign)_async\(/ do
          refute helper["code"] =~ ~r/Phoenix\.LiveView\.(start_async|assign_async)\(/,
                 "#{component["name"]}'s #{helper["name"]} starts a read through Phoenix's own"

          component["name"]
        end

      assert started != [], "no component starts a background read, so this asserts nothing"
    end

    # A READ THAT FAILS IS A TUPLE THE BLOCK DRAWS ITS ERROR FROM, on the builder's canvas as in a
    # task; anything else is a bug, and is let crash.
    test "and catches nothing: no rescue, catch or try" do
      for component <- components(), helper <- component["helpers"] do
        code = String.replace(helper["code"], ~r/^\s*#.*$/m, "")

        refute code =~ ~r/\b(rescue|catch|try)\b/,
               "#{component["name"]}'s #{helper["name"]} catches what it should let crash"
      end
    end

    # A HELPER NOBODY CALLS IS CODE A SITE STILL COMPILES AND AN ADMIN STILL READS. Six components
    # share one set of small helpers, and each carries only its own copies, so a helper dropped from
    # a template has to be dropped from the component too.
    test "and ships no helper its own template and code never call" do
      lifecycle = ~w(mount update update_many render handle_event handle_async site_id)

      for component <- components(),
          name <- Enum.uniq(Enum.map(component["helpers"], & &1["name"])),
          name not in lifecycle do
        callers =
          [
            component["template"]
            | for(h <- component["helpers"], h["name"] != name, do: h["code"])
          ]
          |> Enum.join()

        # A FUNCTION COMPONENT A HELPER DEFINES IS CALLED THE WAY HEEX CALLS IT, `<.name …/>`.
        assert callers =~ ~r/\b#{Regex.escape(name)}\s*\(|<\.#{Regex.escape(name)}\b/,
               "#{component["name"]} carries #{name}/n and calls it nowhere"
      end
    end

    # THE LAYOUT OWNS THE WIDTH OF THE PAGE (`MishkaCmsCore.Runtime.SiteLayout`): its column is the
    # 1160 px of the header and the footer, with the gutters of both, and a block is drawn straight
    # into it. A block that centred itself in a container of its own would double the gutters and
    # set the page narrower than the header above it. The columns inside a block, the text's and the
    # article's, are its own; the page's is not.
    test "and none draws a container of the page's width, or runs to the window's edges" do
      for component <- components() do
        source = component["template"] <> Enum.map_join(component["helpers"], & &1["code"])

        for container <- ["mx-auto", "max-w-[1160px]", "w-screen", "site-bleed"] do
          refute source =~ container,
                 "#{component["name"]} draws #{container}, which is the layout's"
        end
      end
    end

    # THE COLOURS THE SITE'S THEME HAS ARE ITS TOKENS (`MishkaCmsCore.Install.StarterContent`), not
    # hex values of the block's own: a theme an admin edits, or a release that moves a tint, then
    # reaches the blog too. So every token the blog names exists in the theme, and none of the
    # values the theme's shared tokens hold is written out as a hex value.
    test "and write the theme's colours as its tokens" do
      theme =
        for [name, value] <-
              Regex.scan(
                ~r/--color-([a-z0-9-]+):\s*(#[0-9a-f]{6});/,
                MishkaCmsCore.Install.StarterContent.missing_theme(""),
                capture: :all_but_first
              ),
            into: %{},
            do: {name, value}

      assert map_size(theme) > 40, "the theme was not read, so nothing is asserted of the blog"

      shared =
        ~r/^(tint-\d.*|chip-wash.*|brand-dark|body.*|edge-hover|warn-ink.*|warn-wash.*)$/

      held = for {name, value} <- theme, name =~ shared, do: value
      assert length(held) > 20

      for component <- components() do
        source = component["template"] <> Enum.map_join(component["helpers"], & &1["code"])

        for value <- held do
          refute String.contains?(source, "[#{value}]"),
                 "#{component["name"]} writes #{value}, which is a token of the theme"
        end

        used =
          ~r/(?:bg|text|border|divide|ring|from|to)-((?:tint-[1-6](?:-ink)?|chip-wash|brand|body|edge-hover|warn-ink|warn-wash)(?:-dark)?)(?![\w-])/
          |> Regex.scan(source, capture: :all_but_first)
          |> List.flatten()

        for token <- Enum.uniq(used) do
          assert Map.has_key?(theme, token),
                 "#{component["name"]} draws #{token}, which the theme does not declare"
        end
      end
    end

    # AND IT HAS TO TRAVEL. `MishkaBlog.Kit.bundle_path/0` reads the file out of `:code.priv_dir/1`,
    # and `priv` was left out of the package's `files` — so a hex install of this extension pointed
    # at a path that does not exist and gave that site no blog components at all. Nothing in this
    # suite could notice: a checkout has `priv` whether the package ships it or not.
    test "and travels inside the hex package" do
      files = Mix.Project.config()[:package][:files]

      assert Enum.any?(files, &(&1 in ~w(priv priv/cms_ui_kits))),
             "the bundle's directory is not in the package, so a hex install has nothing to read"
    end

    test "puts the id LiveView requires onto every live component's root element" do
      for component <- components(), component["stateful"] do
        assert component["template"] =~ "id={@id}",
               "#{component["name"]} has no id on its root, and a live component cannot exist without one"
      end
    end

    test "carries a mount, and aims its own controls at itself" do
      for component <- components(), component["stateful"] do
        names = Enum.map(component["helpers"], & &1["name"])

        assert "mount" in names,
               "#{component["name"]} has no mount/1, so it starts with no state"

        assert Enum.any?(
                 ["phx-target={@myself}", "target={@myself}", "patch=", "navigate="],
                 &(component["template"] =~ &1)
               ),
               "#{component["name"]} neither answers its own events nor navigates"
      end
    end

    # A FUNCTION COMPONENT HAS NOTHING TO HOLD STATE IN, and the compiler gives it a module shape
    # with no socket in it: a `mount/1` there would never be called and a `phx-target={@myself}`
    # would render `phx-target=""`. Whatever answers a click in one of them is aimed at the live
    # block above it, which is handed over as `target`.
    test "and no function component pretends to be live" do
      for component <- components(), not component["stateful"] do
        names = Enum.map(component["helpers"], & &1["name"])

        for callback <- ~w(mount update handle_event handle_async) do
          refute callback in names,
                 "#{component["name"]} declares #{callback}, which nothing will ever call"
        end

        refute component["template"] =~ "@myself",
               "#{component["name"]} aims an event at a socket it does not have"
      end
    end
  end

  describe "installing" do
    test "writes a row per component, each of its own kind and scoped to the site", %{site: site} do
      for name <- @names do
        found = row(name, site)

        assert found, "#{name} was not installed"
        assert found.stateful == name in @live
        assert found.site_id == site.id
        assert found.helpers != [], "#{name} arrived with no code"
      end
    end

    # THE COLOURS OF A HIGHLIGHTED POST travel with the components. Every class Makeup's own Monokai
    # style colours is coloured here, read off Makeup rather than listed in this test.
    test "writes the stylesheet a highlighted code block is coloured by", %{site: site} do
      reader = create_user_with_permissions!(["admin:dashboard:runtime:stylesheet"])

      sheet =
        Stylesheet
        |> Ash.Query.for_read(:read, %{}, actor: reader, tenant: site.id)
        |> Ash.Query.filter(name == "blog-code-highlight" and site_id == ^site.id)
        |> Ash.read_one!()

      assert sheet, "the stylesheet was not installed"
      assert sheet.kind == :base
      assert sheet.content =~ "background-color: #272822"

      monokai = Makeup.stylesheet(:monokai_style, "highlight")

      monokai_classes =
        Regex.scan(~r/^\.highlight \.([\w-]+) \{/m, monokai, capture: :all_but_first)

      for [class] <- monokai_classes, class != "hll" do
        assert sheet.content =~ ".highlight .#{class} {", "nothing colours .#{class}"
      end
    end

    test "twice changes nothing and raises nothing", %{site: site} do
      before = row("blog-post-list", site)

      assert {:ok, _again} = MishkaBlog.Kit.install!(site.id)

      after_second = row("blog-post-list", site)
      assert after_second.id == before.id
      assert length(after_second.helpers) == length(before.helpers)
    end

    # LAZY BY DEFAULT, like any other component. `precompile: true` is for a component a site cannot
    # afford to compile on the first request; these are ordinary and compile when first called.
    test "leaves them to compile on first use rather than at boot", %{site: site} do
      for name <- @names do
        assert row(name, site).precompile == false,
               "#{name} asks to be compiled at boot, which it does not need"
      end
    end
  end

  # How many rows one page of that action hands back, whatever a caller asks for.
  # Every read in `code`, piped or called with its resource first: the resource, the action, and
  # everything `for_read` is handed.
  defp read_calls(code) do
    for [{at, length}] <- Regex.scan(~r/Ash\.Query\.for_read\(/, code, return: :index) do
      given = code |> binary_part(at + length, byte_size(code) - at - length) |> call_body()

      case Regex.run(~r/^\s*MishkaBlog\.(\w+),\s*:(\w+)/, given) do
        [_whole, resource, action] ->
          {resource, action, given}

        nil ->
          [_whole, resource] =
            Regex.run(~r/MishkaBlog\.(\w+)\s*\|>\s*\z/, binary_part(code, 0, at))

          [_whole, action] = Regex.run(~r/^\s*:(\w+)/, given)
          {resource, action, given}
      end
    end
  end

  # What a call is handed, up to the parenthesis that closes it.
  defp call_body(rest) do
    rest
    |> String.graphemes()
    |> Enum.reduce_while({1, []}, fn
      ")", {1, taken} -> {:halt, {0, taken}}
      ")", {depth, taken} -> {:cont, {depth - 1, [")" | taken]}}
      "(", {depth, taken} -> {:cont, {depth + 1, ["(" | taken]}}
      char, {depth, taken} -> {:cont, {depth, [char | taken]}}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp keeps_to_reader?(resource, action) do
    module = Module.concat(MishkaBlog, resource)
    Code.ensure_loaded!(module)

    module
    |> Ash.Resource.Info.action(String.to_existing_atom(action))
    |> Map.fetch!(:preparations)
    |> Enum.any?(
      &match?(
        %Ash.Resource.Preparation{
          preparation: {MishkaBlog.Resources.Preparations.OpenToActor, _opts}
        },
        &1
      )
    )
  end

  defp page_cap(resource, action) do
    module = Module.concat(MishkaBlog, resource)
    Code.ensure_loaded!(module)

    case Ash.Resource.Info.action(module, String.to_existing_atom(action)) do
      %{pagination: %{max_page_size: most}} -> most
      _unpaged -> nil
    end
  end

  defp read_assigns(template) do
    ~r/@([a-z_][a-zA-Z0-9_]*)/
    |> Regex.scan(template)
    |> Enum.map(fn [_whole, name] -> name end)
    |> Enum.uniq()
  end

  # An assign a component's own lifecycle puts on the socket is not an attribute and is not
  # declared. WHICH names those are is read out of the component rather than listed here: `mount/1`
  # is where a live component states everything it holds, so its keyword list is the state, plus
  # both single-key forms a helper writes with — `assign(socket, :one, value)` and the piped
  # `socket |> assign(:one, value)`, which is what the bundle actually uses.
  #
  # A hand-kept list was the previous answer, and it went stale the moment a component grew a piece
  # of state — silently, because a name missing from it fails the assertion above rather than this
  # one, and reads like an undeclared attribute.
  defp lifecycle_assigns(component) do
    helpers = component["helpers"]

    mounted =
      helpers
      |> Enum.filter(&(&1["name"] == "mount"))
      |> Enum.flat_map(&Regex.scan(~r/([a-z_]+):\s/, &1["code"] || ""))
      |> Enum.map(fn [_whole, name] -> name end)

    single =
      helpers
      |> Enum.flat_map(&Regex.scan(~r/assign\(\s*[a-z_]+,\s*:([a-z_]+)/, &1["code"] || ""))
      |> Enum.map(fn [_whole, name] -> name end)

    piped =
      helpers
      |> Enum.flat_map(&Regex.scan(~r/assign\(\s*:([a-z_]+)/, &1["code"] || ""))
      |> Enum.map(fn [_whole, name] -> name end)

    Enum.uniq(mounted ++ single ++ piped)
  end
end
