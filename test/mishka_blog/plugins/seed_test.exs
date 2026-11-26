# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.SeedTest do
  @moduledoc """
  The blog's parts on core's `installer:seed` event (`MishkaBlog.Plugins.Seed`): listed with the
  flags, installers and link the checklist and the dev header read, it answers only its own key, and
  appends exactly one report per part it runs.

  `pages` goes through `installer:extension:install`, so `MishkaBlog.Plugins.Installer` is
  registered too. `samples` runs on a site that already has a post, so it takes the re-run path
  (`:already_seeded`) instead of writing a whole blog.
  """
  use MishkaBlog.DataCase, async: false

  import MishkaBlog.Test.Factory

  alias MishkaBlog.Plugins.{Installer, Seed}
  alias MishkaBlog.Test.Plugins.ProvisionSnippetSaved
  alias MishkaCmsCore.Install.{Extensions, Seeds}
  alias MishkaCmsCore.Test.Installer, as: TestInstaller
  alias MishkaInstaller.Event.{Event, EventHandler, Hook}

  # Registered by hand for the reason `MishkaBlog.ProvisionTest`'s `listening!/0` gives: this
  # suite's registry is not up when the extension's supervisor starts its plugins. The CMS is not
  # installed yet, as during the installer's own run, so the install is answered with no actor.
  setup do
    :persistent_term.erase(:mishka_installed)

    for plugin <- [Seed, Installer] do
      {:ok, _registered} = plugin.register()
      {:ok, _started} = plugin.start()
      :ok = EventHandler.do_compile(plugin.config(:__event__), :start, false)
    end

    TestInstaller.register!(ProvisionSnippetSaved, "runtime:provision:snippets")

    on_exit(fn ->
      :persistent_term.erase(:mishka_installed)
      Event.unregister(:name, Seed, false)
    end)

    :ok
  end

  defp payload(key, part, site_id) do
    test = self()

    %{
      key: key,
      part: part,
      parts: ["pages", "samples"],
      env: :dev,
      size: :normal,
      site_id: site_id,
      users: [],
      answers: %{},
      foundation: %{},
      opts: [],
      progress: fn line -> send(test, {:progress, line}) end,
      reports: []
    }
  end

  defp blog(env) do
    env |> Seeds.plugins() |> Enum.find(&(&1.key == "mishka_blog"))
  end

  # A PRODUCTION BUILD sets neither flag; the suite's own config sets `:env_test?`.
  defp as_production_build do
    flags =
      for key <- [:env_dev?, :env_test?], do: {key, Application.get_env(:mishka_cms_core, key)}

    Enum.each(flags, fn {key, _value} -> Application.delete_env(:mishka_cms_core, key) end)

    on_exit(fn ->
      for {key, value} <- flags,
          value != nil,
          do: Application.put_env(:mishka_cms_core, key, value)
    end)
  end

  test "is one of the blog's plugins, supervised in every build" do
    assert Seed in MishkaBlog.Application.plugins()
    assert Seed.config(:__event__) == Seeds.event()
  end

  test "lists pages for both installers and samples for the dev one, both ticked, with its link" do
    assert %{parts: [pages, samples]} = blog(:dev)

    assert %{id: "pages", envs: [:dev, :prod], required: false, default: true, nav: []} = pages
    assert pages.label == "Blog pages and components"

    assert %{id: "samples", envs: [:dev], required: false, default: true} = samples
    assert samples.nav == [%{label: "Blog", path: "/blog"}]

    assert %{parts: [%{id: "pages"}]} = blog(:prod)
  end

  test "hands another extension's key back untouched" do
    sent = payload("mishka_document", "pages", Ecto.UUID.generate())

    assert Seed.call(sent) == {:reply, sent}
    refute_received {:progress, _line}
  end

  test "pages installs the blog through the installer and records the site as set up" do
    site = create_site!()
    refute Extensions.installed?(site.id, :mishka_blog)

    assert %{reports: [report]} =
             Hook.call(Seeds.event(), %{payload("mishka_blog", "pages", site.id) | env: :prod})

    assert report.pages != []
    assert Extensions.installed?(site.id, :mishka_blog)
  end

  test "pages reports the refusal as an error, and records nothing" do
    site = create_site!()
    MishkaCmsCore.Install.mark_installed!()

    assert %{reports: [%{error: {:extension_failed, _message}}]} =
             Hook.call(Seeds.event(), payload("mishka_blog", "pages", site.id))

    refute Extensions.installed?(site.id, :mishka_blog)
  end

  test "samples runs the blog's dev seed for its own key and appends exactly one report" do
    site = create_site!()
    create_blog_post!(site_id: site.id)

    assert %{reports: [:already_seeded]} =
             Hook.call(Seeds.event(), payload("mishka_blog", "samples", site.id))

    assert_received {:progress, "Installing the blog's live components…"}
  end

  test "a production build lists no samples part and refuses one that arrives anyway" do
    as_production_build()
    site = create_site!()
    create_blog_post!(site_id: site.id)

    for env <- [:dev, :prod], do: assert(%{parts: [%{id: "pages"}]} = blog(env))
    assert {:error, :dev_in_production} = Seeds.run(:dev)

    assert %{reports: [%{error: :dev_in_production}]} =
             Hook.call(Seeds.event(), payload("mishka_blog", "samples", site.id))

    refute_received {:progress, _line}
  end
end
