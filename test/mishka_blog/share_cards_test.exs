defmodule MishkaBlog.ShareCardsTest do
  @moduledoc """
  The blog's share cards (`MishkaCmsCore.Runtime.ShareCard`): which card each record shows
  (`MishkaBlog.ShareCards.target/1`), the plugins that look at it again after each record is saved
  — each on its own resource's `after_save` event, so a save of another resource never reaches it —
  and the Share image field each record's edit modal draws it in.
  """
  use MishkaBlog.DataCase, async: false
  use Oban.Testing, repo: MishkaBlog.Repo

  alias MishkaBlog.{BlogPost, Blogger, Collection, ShareCards, Tag, Team}

  alias MishkaBlog.Plugins.{
    BloggerShareCard,
    CollectionShareCard,
    PostShareCard,
    TagShareCard,
    TeamShareCard
  }

  alias MishkaCmsCore.PluginRegistrations
  alias MishkaCmsCore.Runtime.Workers.ShareCardRefreshWorker
  alias MishkaGervaz.Resource.Info.Form, as: FormInfo
  alias MishkaInstaller.Event.{Event, EventHandler}

  # THE APPLICATION'S PLUGIN PROCESSES ARE NOT RUNNING IN THIS SUITE: each is registered the way the
  # CMS boot registers it, and unregistered when the test exits, since Mnesia is on disk.
  defp register(plugin) do
    PluginRegistrations.reconcile(false)
    {:ok, _} = plugin.register()
    on_exit(fn -> Event.unregister(:name, plugin, false) end)
    :ok = EventHandler.do_compile(plugin.config(:__event__), :start, false)
  end

  defp looks, do: for(job <- all_enqueued(worker: ShareCardRefreshWorker), do: job.args)

  describe "target/1" do
    test "a published post, by its slug and language" do
      post = %BlogPost{status: :published, slug: "hello", language: "fa"}

      assert ShareCards.target(post) ==
               {:record, "blog:post", %{"slug" => "hello", "lang" => "fa"}}

      assert ShareCards.target(%{post | status: :draft}) == nil
      assert ShareCards.target(%{post | status: :archived}) == nil
    end

    test "an active category, a tag, a blogger and an active team" do
      assert ShareCards.target(%Collection{status: :active, slug: "eng", language: "en"}) ==
               {:record, "blog:category", %{"slug" => "eng", "lang" => "en"}}

      assert ShareCards.target(%Collection{status: :inactive, slug: "eng", language: "en"}) ==
               nil

      assert ShareCards.target(%Tag{slug: "elixir", language: "en"}) ==
               {:record, "blog:tag", %{"slug" => "elixir", "lang" => "en"}}

      assert ShareCards.target(%Blogger{slug: "mona"}) ==
               {:record, "blog:author", %{"slug" => "mona"}}

      assert ShareCards.target(%Blogger{slug: "mona", archived_at: DateTime.utc_now()}) == nil

      assert ShareCards.target(%Team{status: :active, slug: "core"}) ==
               {:record, "blog:team", %{"slug" => "core"}}

      assert ShareCards.target(%Team{status: :inactive, slug: "core"}) == nil
      assert ShareCards.target(%{slug: "not a blog record"}) == nil
    end
  end

  describe "after a post is saved" do
    setup do
      register(PostShareCard)
      %{site: create_site!(active: true)}
    end

    test "a published post's card is looked at, and a draft's is not", %{site: site} do
      published =
        create_blog_post!(site_id: site.id, status: :published, slug: "out", language: "en")

      create_blog_post!(site_id: site.id, status: :draft, slug: "not-yet", language: "en")

      assert looks() == [
               %{
                 "site_id" => site.id,
                 "target" => %{
                   "record" => "blog:post",
                   "params" => %{"slug" => published.slug, "lang" => "en"}
                 },
                 "force" => false
               }
             ]
    end

    test "an update is looked at too", %{site: site} do
      post = create_blog_post!(site_id: site.id, status: :published, slug: "edited")

      post
      |> Ash.Changeset.for_update(:master_update, %{title: "A new title"}, authorize?: false)
      |> Ash.update!()

      assert [%{"target" => %{"params" => %{"slug" => "edited"}}}] = looks()
    end
  end

  test "each other record's plugin answers its own resource's saves only" do
    site = create_site!(active: true)

    for plugin <- [CollectionShareCard, TagShareCard, BloggerShareCard, TeamShareCard],
        do: register(plugin)

    create_collection!(site_id: site.id, status: :active, slug: "eng")
    create_blog_tag!(site_id: site.id, slug: "elixir")
    create_blogger!(site_id: site.id, slug: "mona")
    create_team!(site_id: site.id, status: :active, slug: "core")
    create_blog_post!(site_id: site.id, status: :published, slug: "no-plugin-here")

    kinds = for %{"target" => %{"record" => kind}} <- looks(), do: kind

    assert Enum.sort(kinds) == ["blog:author", "blog:category", "blog:tag", "blog:team"]
  end

  test "each record's edit modal has a Share image field, on an update" do
    for resource <- [BlogPost, Collection, Tag, Blogger, Team] do
      field = FormInfo.field(resource, :share_card)

      assert field, "#{inspect(resource)} has no Share image field"
      assert field.virtual
      assert field.show_on == :update
      assert field.ui.extra.share_card == (&ShareCards.target/1)
    end
  end
end
