defmodule MishkaBlog.Plugins.ShareCardTargetsTest do
  @moduledoc """
  The blog's answer to `runtime:share_card:targets` (`MishkaBlog.Plugins.ShareCardTargets`): every
  share card it shows on a site, under `"mishka_blog"` (`MishkaBlog.ShareCards.targets/1`), named by
  slug and language, read as a visitor reads it — and only when the event asks every producer or
  this one.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.Plugins.ShareCardTargets
  alias MishkaBlog.ShareCards
  alias MishkaCmsCore.PluginRegistrations
  alias MishkaCmsCore.Runtime.ShareCard
  alias MishkaCmsCore.Runtime.States.SettingsState
  alias MishkaCmsCore.Settings
  alias MishkaInstaller.Event.{Event, EventHandler}

  setup do
    PluginRegistrations.reconcile(false)
    {:ok, _} = ShareCardTargets.register()
    on_exit(fn -> Event.unregister(:name, ShareCardTargets, false) end)
    :ok = EventHandler.do_compile(ShareCard.targets_event(), :start, false)

    site = create_site!(active: true)
    on_exit(fn -> SettingsState.delete(site.id, "site.languages") end)
    {:ok, _} = Settings.put("site.languages", ["en", "fa"], site_id: site.id)

    %{site: site}
  end

  defp asked(site_id, opts \\ []) do
    %{
      site_id: site_id,
      force: false,
      producer: Keyword.get(opts, :producer),
      names_only: Keyword.get(opts, :names_only, false),
      targets: %{}
    }
  end

  defp blog!(site) do
    create_blog_post!(site_id: site.id, status: :published, slug: "hello", language: "en")
    create_blog_post!(site_id: site.id, status: :published, slug: "salam", language: "fa")
    create_blog_post!(site_id: site.id, status: :draft, slug: "not-yet", language: "en")
    create_blog_post!(site_id: site.id, status: :published, slug: "hallo", language: "de")

    create_blog_post!(
      site_id: site.id,
      status: :published,
      slug: "locked",
      language: "en",
      permissions: ["admin:dashboard:blog:post"]
    )

    create_collection!(site_id: site.id, status: :active, slug: "eng", language: "en")
    create_collection!(site_id: site.id, status: :draft, slug: "old", language: "en")
    create_blog_tag!(site_id: site.id, slug: "elixir", language: "en")
    create_blogger!(site_id: site.id, slug: "mona")
    create_team!(site_id: site.id, status: :active, slug: "core")
    create_team!(site_id: site.id, status: :inactive, slug: "gone")
  end

  test "answers the event with every card of the site it is asked about, under its name", %{
    site: site
  } do
    blog!(site)
    other = create_site!(active: true)
    create_blog_post!(site_id: other.id, status: :published, slug: "elsewhere", language: "en")

    assert {:ok, %{"mishka_blog" => targets}} = ShareCard.targets(site.id)

    assert Enum.sort(targets) ==
             Enum.sort([
               {:record, "blog:post", %{"slug" => "hello", "lang" => "en"}},
               {:record, "blog:post", %{"slug" => "salam", "lang" => "fa"}},
               {:record, "blog:category", %{"slug" => "eng", "lang" => "en"}},
               {:record, "blog:tag", %{"slug" => "elixir", "lang" => "en"}},
               {:record, "blog:author", %{"slug" => "mona", "lang" => "en"}},
               {:record, "blog:author", %{"slug" => "mona", "lang" => "fa"}},
               {:record, "blog:team", %{"slug" => "core", "lang" => "en"}},
               {:record, "blog:team", %{"slug" => "core", "lang" => "fa"}}
             ])
  end

  test "names each card by its kind, slug and language, and nothing else", %{site: site} do
    blog!(site)

    targets = Enum.to_list(ShareCards.targets(site.id))

    assert targets != []

    for target <- targets do
      assert {:record, "blog:" <> _kind, captures} = target
      assert Map.keys(captures) |> Enum.sort() == ["lang", "slug"]
      assert Enum.all?(Map.values(captures), &is_binary/1)
    end
  end

  test "names only itself, reading nothing, for no site or when asked for names" do
    assert {:reply, %{targets: %{"mishka_blog" => []}}} =
             ShareCardTargets.call(asked(nil, names_only: true))

    assert "mishka_blog" in ShareCard.producers(nil)
    assert ShareCards.targets(nil) == []
    assert {:reply, %{targets: %{"mishka_blog" => []}}} = ShareCardTargets.call(asked(nil))
  end

  test "answers a redraw of its own cards, and stays out of another producer's", %{site: site} do
    blog!(site)

    assert {:ok, %{"mishka_blog" => [_ | _]} = mine} =
             ShareCard.targets(site.id, producer: "mishka_blog")

    assert Map.keys(mine) == ["mishka_blog"]

    assert {:reply, %{targets: targets}} =
             ShareCardTargets.call(asked(site.id, producer: "mishka_cms_core"))

    assert targets == %{}
    assert {:ok, others} = ShareCard.targets(site.id, producer: "mishka_cms_core")
    refute Map.has_key?(others, "mishka_blog")
  end
end
