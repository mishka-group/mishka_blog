# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.BlogPostContentFactsTest do
  @moduledoc """
  What a post's content says about it, stored when the content is written —
  `MishkaBlog.Resources.Changes.ContentFacts`: how long it takes to read, and the components, the
  icons and the classes it names, which `MishkaBlog.Plugins.ContentComponents` hands a site's stylesheet.
  Reading a post works out none of them.
  """
  use MishkaBlog.DataCase, async: false
  use Oban.Testing, repo: MishkaBlog.Repo

  alias MishkaBlog.BlogPost
  alias MishkaBlog.Plugins.ContentComponents
  alias MishkaBlog.Resources.Changes.ContentFacts
  alias MishkaCmsCore.Runtime.States.SiteState
  alias MishkaCmsCore.Runtime.Workers.RuntimeCompilerWorker

  require Ash.Query
  require Ecto.Query

  @moduletag :unit

  setup do
    site = create_site!()
    admin = create_user_with_permissions!(["*"], site_id: site.id)

    {:ok, site: site, admin: admin}
  end

  defp words(count), do: "<p>" <> String.duplicate("word ", count) <> "</p>"

  defp write!(post, action, params, %{site: site, admin: admin}) do
    post
    |> Ash.Changeset.for_update(action, params, actor: admin, tenant: site.id)
    |> Ash.update!()
  end

  defp stored(post), do: Ash.get!(BlogPost, post.id, action: :read_any, authorize?: false)

  # THIS BUILD HAS NO `deps/heroicons`, so the stock Heroicons set ships nothing here. With no set
  # configured, the `hero-` glyphs the installed Chelekom kit bundles register themselves
  # (`MishkaCmsCore.Runtime.PageBuilder.Icons.Bundled`) — what a host without heroicons draws from.
  defp bundled_icons(_context) do
    original = Application.get_env(:mishka_cms_core, :icon_libraries)
    Application.put_env(:mishka_cms_core, :icon_libraries, [])

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:mishka_cms_core, :icon_libraries)
        libraries -> Application.put_env(:mishka_cms_core, :icon_libraries, libraries)
      end
    end)

    :ok
  end

  describe "reading_time_minutes" do
    test "is set when the post is created", %{site: site} do
      post = create_blog_post!(site_id: site.id, content: words(450))

      assert post.reading_time_minutes == 3
      assert stored(post).reading_time_minutes == 3
    end

    test "is never under a minute", %{site: site} do
      assert create_blog_post!(site_id: site.id, content: "<p>Hi</p>").reading_time_minutes == 1
    end

    test "counts the words a reader reads, not the markup around them", %{site: site} do
      html = ~s(<h2 class="lead">One two</h2><pre><code><span class="k">three</span></code></pre>)

      assert ContentFacts.reading_time(html) == 1
      assert ContentFacts.reading_time(words(201)) == 2
      assert create_blog_post!(site_id: site.id, content: html).reading_time_minutes == 1
    end

    test "changes when the content does", %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: words(10))

      assert write!(post, :update, %{content: words(650)}, context).reading_time_minutes == 4
    end

    test "is left alone by a write that leaves the content alone", %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: words(450))

      updated = write!(post, :update, %{title: "Another title"}, context)

      assert updated.reading_time_minutes == 3
      assert stored(updated).reading_time_minutes == 3
    end

    test "is filled by any save when the post has none yet", %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: words(450))

      {1, _} =
        AshPostgres.DataLayer.Info.repo(BlogPost, :mutate).update_all(
          Ecto.Query.from(p in "mishka_blog_posts", where: p.id == type(^post.id, Ecto.UUID)),
          set: [reading_time_minutes: nil]
        )

      updated = write!(stored(post), :update, %{title: "Another title"}, context)

      assert updated.reading_time_minutes == 3
      assert stored(updated).reading_time_minutes == 3
    end

    test "comes back with the content a version restores", %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: words(450))
      write!(post, :update, %{content: words(10)}, context)

      [first | _later] =
        BlogPost.Version
        |> Ash.Query.for_read(:read_any)
        |> Ash.Query.filter(version_source_id == ^post.id)
        |> Ash.Query.sort(version_inserted_at: :asc)
        |> Ash.read!(authorize?: false)

      restored = write!(stored(post), :restore_version, %{version_id: first.id}, context)

      assert restored.reading_time_minutes == 3
    end
  end

  describe "content_components" do
    test "are the names the content's markers name, each once", %{site: site} do
      post =
        create_blog_post!(
          site_id: site.id,
          content:
            ~s(<p>[[component callout title="a"]]x[[/component]]</p>[[component badge /]][[component callout /]]<code>[[component shown /]]</code>)
        )

      assert stored(post).content_components == ["callout", "badge"]
    end

    test "are nothing for content that names none", %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: "[[component callout /]]")

      assert stored(write!(post, :update, %{content: "<p>plain</p>"}, context)).content_components ==
               nil
    end

    test "are left alone by a write that leaves the content alone", %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: "[[component callout /]]")

      assert stored(write!(post, :update, %{title: "Renamed"}, context)).content_components ==
               ["callout"]
    end
  end

  describe "content_icons" do
    setup :bundled_icons

    test "are the icons the content's markers and HTML name, each once", %{site: site} do
      post =
        create_blog_post!(
          site_id: site.id,
          content:
            ~s([[component breadcrumb]][[slot item icon="hero-cloud"]]Cloud[[/slot]][[/component]]) <>
              ~s(<p><span class="size-4 hero-inbox"></span> A hero-section, and hero-cloud again</p>)
        )

      assert stored(post).content_icons == ["hero-cloud", "hero-inbox"]
    end

    test "are nothing for content that names none", %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: ~s(<span class="hero-inbox"></span>))

      assert stored(write!(post, :update, %{content: "<p>plain</p>"}, context)).content_icons ==
               nil
    end

    test "are left alone by a write that leaves the content alone", %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: ~s(<span class="hero-inbox"></span>))

      assert stored(write!(post, :update, %{title: "Renamed"}, context)).content_icons ==
               ["hero-inbox"]
    end
  end

  # A COMPONENT THAT TAKES A CLASS STRING in an attribute declares `examples` for it and no `values`.
  @open_attrs [
    %{
      "name" => "size",
      "type" => "string",
      "opts" => %{"default" => "small", "examples" => ["small", "large"]}
    },
    %{
      "name" => "color",
      "type" => "string",
      "opts" => %{"default" => "base", "values" => ["base", "dark"]}
    }
  ]

  describe "content_classes" do
    test "are the classes the content's HTML, its markers' *_class and its components' open attributes write",
         %{site: site} do
      create_component!(
        name: "open-badge",
        attrs: @open_attrs,
        active: true,
        precompile: false,
        site_id: site.id
      )

      post =
        create_blog_post!(
          site_id: site.id,
          content:
            ~s(<div class="bg-[#282828] text-white">x</div>) <>
              ~s([[component slider track_class="h-1 bg-neutral-200" /]]) <>
              ~s([[component open-badge size="leading-5 py-2" color="bg-red-500" /]])
        )

      assert stored(post).content_classes == [
               "bg-[#282828]",
               "text-white",
               "h-1",
               "bg-neutral-200",
               "leading-5",
               "py-2"
             ]
    end

    test "are nothing for content that writes none, and left alone by a write that leaves it alone",
         %{site: site} = context do
      post = create_blog_post!(site_id: site.id, content: ~s(<p class="bg-[#282828]">x</p>))

      assert stored(write!(post, :update, %{title: "Renamed"}, context)).content_classes ==
               ["bg-[#282828]"]

      assert stored(write!(post, :update, %{content: "<p>plain</p>"}, context)).content_classes ==
               nil
    end
  end

  # A SITE'S STYLESHEET IS BUILT FROM WHAT IT REACHES, and a post's components are in no template.
  describe "the names a site's stylesheet hears" do
    test "are those its published posts name, each once", %{site: site} do
      create_blog_post!(
        site_id: site.id,
        status: :published,
        content: "[[component callout /]][[component badge /]]"
      )

      create_blog_post!(site_id: site.id, status: :published, content: "[[component callout /]]")
      create_blog_post!(site_id: site.id, status: :draft, content: "[[component draft-only /]]")

      create_blog_post!(
        site_id: create_site!().id,
        status: :published,
        content: "[[component theirs /]]"
      )

      assert {:reply, %{components: names}} =
               ContentComponents.call(%{
                 site: site.name,
                 site_id: site.id,
                 components: ["kept"],
                 icons: []
               })

      assert Enum.sort(names) == ["badge", "callout", "kept"]
    end
  end

  # AN ICON A POST NAMES IS IN NO TEMPLATE EITHER: a marker's `icon="hero-cloud"` reaches its
  # component as an expression, and a `<span class="hero-inbox">` in the body is never scanned.
  describe "the icons a site's stylesheet hears" do
    setup :bundled_icons

    test "are those its published posts name, each once", %{site: site} do
      create_blog_post!(
        site_id: site.id,
        status: :published,
        content: ~s([[slot item icon="hero-cloud" /]]<span class="hero-inbox"></span>)
      )

      create_blog_post!(
        site_id: site.id,
        status: :published,
        content: ~s(<span class="hero-cloud"></span>)
      )

      create_blog_post!(
        site_id: site.id,
        status: :draft,
        content: ~s(<span class="hero-envelope"></span>)
      )

      create_blog_post!(
        site_id: create_site!().id,
        status: :published,
        content: ~s(<span class="hero-star"></span>)
      )

      assert {:reply, %{components: ["kept"], icons: icons}} =
               ContentComponents.call(%{
                 site: site.name,
                 site_id: site.id,
                 components: ["kept"],
                 icons: ["hero-bell"]
               })

      assert Enum.sort(icons) == ["hero-bell", "hero-cloud", "hero-inbox"]
    end
  end

  # A CLASS A POST WRITES IS IN NO TEMPLATE EITHER: a marker's `track_class="h-1"` reaches its
  # component as an expression, and a post's body is never scanned.
  describe "the classes a site's stylesheet hears" do
    test "are those its published posts write, each once", %{site: site} do
      create_blog_post!(
        site_id: site.id,
        status: :published,
        content: ~s(<p class="bg-[#282828] p-2">[[component callout thumb_class="size-4" /]]</p>)
      )

      create_blog_post!(site_id: site.id, status: :published, content: ~s(<p class="p-2">x</p>))
      create_blog_post!(site_id: site.id, status: :draft, content: ~s(<p class="draft">x</p>))

      assert {:reply, %{components: ["callout"], classes: classes}} =
               ContentComponents.call(%{
                 site: site.name,
                 site_id: site.id,
                 components: [],
                 icons: [],
                 classes: ["kept"]
               })

      assert Enum.sort(classes) == ["bg-[#282828]", "kept", "p-2", "size-4"]
    end

    test "are not asked of a build that asks for none, which still hears the names", %{site: site} do
      create_blog_post!(
        site_id: site.id,
        status: :published,
        content: ~s(<p class="p-2">[[component callout /]]</p>)
      )

      assert {:reply, answer} =
               ContentComponents.call(%{
                 site: site.name,
                 site_id: site.id,
                 components: [],
                 icons: []
               })

      assert answer.components == ["callout"]
      refute Map.has_key?(answer, :classes)
    end
  end

  describe "a write that changes the classes a published post writes" do
    setup :open_site

    test "rebuilds the site's stylesheet when it writes one no published post did", ctx do
      write!(ctx.post, :update, %{content: ~s(<p class="hero-cloud bg-[#282828]">x</p>)}, ctx)

      assert [_job] = css_jobs(ctx.site)
    end

    test "rebuilds nothing for classes other published posts already write", ctx do
      write!(ctx.post, :update, %{content: ~s(<p class="hero-cloud hero-star m-4">x</p>)}, ctx)

      assert stored(ctx.post).content_classes == ["hero-cloud", "hero-star", "m-4"]
      assert css_jobs(ctx.site) == []
    end
  end

  # A WRITE THAT MAKES AN ICON LIVE asks for the site's stylesheet again, as one that makes a
  # component name live does. `TailwindCompiler.schedule/1` enqueues nothing under the `:env_test?`
  # flag, so it is switched off once the posts a test starts from exist.
  describe "a write that changes the icons a published post names" do
    setup [:bundled_icons, :open_site]

    test "rebuilds the site's stylesheet when it names one no published post did", ctx do
      write!(ctx.post, :update, %{content: ~s(<span class="hero-cloud hero-inbox"></span>)}, ctx)

      assert [_job] = css_jobs(ctx.site)
    end

    test "rebuilds nothing when its icons stay as they were", ctx do
      write!(ctx.post, :update, %{content: ~s(<p>New text</p><i class="hero-cloud"></i>)}, ctx)

      assert stored(ctx.post).content_icons == ["hero-cloud"]
      assert css_jobs(ctx.site) == []
    end

    test "rebuilds nothing for an icon another published post already names", ctx do
      write!(ctx.post, :update, %{content: ~s(<span class="hero-cloud hero-star"></span>)}, ctx)

      assert css_jobs(ctx.site) == []
    end
  end

  # A NAME AND HOST OF ITS OWN, active, so its create caches it in `SiteState` — a stylesheet job is
  # enqueued only for such a site.
  defp open_site(_context) do
    name = "iconsite#{System.unique_integer([:positive])}"
    site = create_site!(name: name, host: "#{name}.test", active: true)
    on_exit(fn -> SiteState.delete(site.id) end)

    post =
      create_blog_post!(
        site_id: site.id,
        status: :published,
        content: ~s(<span class="hero-cloud"></span>)
      )

    create_blog_post!(
      site_id: site.id,
      status: :published,
      content: ~s(<span class="hero-star"></span>)
    )

    create_blog_post!(site_id: site.id, status: :published, content: ~s(<p class="m-4">x</p>))

    Application.put_env(:mishka_cms_core, :env_test?, false)
    on_exit(fn -> Application.put_env(:mishka_cms_core, :env_test?, true) end)

    {:ok, site: site, post: post, admin: create_user_with_permissions!(["*"], site_id: site.id)}
  end

  defp css_jobs(site) do
    all_enqueued(worker: RuntimeCompilerWorker)
    |> Enum.filter(fn job ->
      get_in(job.args, ["data", "type"]) == "css" and
        get_in(job.args, ["data", "site_id"]) == site.id
    end)
  end

  # WHEN A WRITE ASKS FOR THE STYLESHEET AGAIN: a name a published post makes live.
  describe "newly_live/2" do
    test "is what a published post names now and did not before" do
      was = %{status: :published, content_components: ["a"]}

      assert ContentFacts.newly_live(was, %{was | content_components: ["a", "b"]}) == ["b"]
      assert ContentFacts.newly_live(was, %{was | content_components: ["a"]}) == []
      assert ContentFacts.newly_live(was, %{was | content_components: nil}) == []
    end

    test "is everything a post names once it is published, and nothing while it is not" do
      draft = %{status: :draft, content_components: ["a"]}

      assert ContentFacts.newly_live(draft, %{draft | status: :published}) == ["a"]
      assert ContentFacts.newly_live(%{draft | status: :published}, draft) == []
      assert ContentFacts.newly_live(%BlogPost{}, draft) == []
    end

    test "is the same question of the classes a post writes" do
      was = %{status: :published, content_classes: ["p-2"]}
      now = %{was | content_classes: ["p-2", "bg-[#282828]"]}

      assert ContentFacts.newly_live(was, now, :content_classes) == ["bg-[#282828]"]
      assert ContentFacts.newly_live(now, was, :content_classes) == []
    end

    test "is the same question of the icons a post names" do
      was = %{status: :published, content_components: ["a"], content_icons: ["hero-cloud"]}
      now = %{was | content_icons: ["hero-cloud", "hero-inbox"]}

      assert ContentFacts.newly_live(was, now, :content_icons) == ["hero-inbox"]
      assert ContentFacts.newly_live(was, now) == []
      assert ContentFacts.newly_live(now, was, :content_icons) == []

      assert ContentFacts.newly_live(%{now | status: :draft}, now, :content_icons) == [
               "hero-cloud",
               "hero-inbox"
             ]
    end
  end
end
