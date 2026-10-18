# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.ShareCardsTest do
  @moduledoc """
  The blog's share cards (`MishkaCmsCore.Runtime.ShareCard`): which card each record shows
  (`MishkaBlog.ShareCards.target/1`), the plugins that look at it again after each record is saved
  — each on its own resource's `after_save` event, so a save of another resource never reaches it,
  and on the `:share_cards` queue — and the Share image field each record's edit modal draws it in.
  """
  use MishkaBlog.DataCase, async: false
  use Oban.Testing, repo: MishkaBlog.Repo

  alias MishkaBlog.{Blogger, BlogPost, Collection, ShareCards, Tag, Team}

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

  # Each plugin a test needs is registered the way the CMS boot registers it, and unregistered when
  # the test exits, since Mnesia is on disk. The application's own plugin processes run in this suite
  # too and register themselves once the installer is ready, so a plugin a test did not register may
  # still be answering.
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

    test "its look waits on the share-card queue, never on :assets", %{site: site} do
      create_blog_post!(site_id: site.id, status: :published, slug: "queued", language: "en")

      assert [%{queue: "share_cards"}] = all_enqueued(worker: ShareCardRefreshWorker)
      assert all_enqueued(queue: :assets) == []
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

    looked =
      for %{"target" => %{"record" => kind, "params" => %{"slug" => slug}}} <- looks(),
          do: {kind, slug}

    # The post's own plugin may be running (see `register/1`); if it is, its card is the post's alone.
    assert Enum.sort(looked -- [{"blog:post", "no-plugin-here"}]) == [
             {"blog:author", "mona"},
             {"blog:category", "eng"},
             {"blog:tag", "elixir"},
             {"blog:team", "core"}
           ]
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
