defmodule MishkaBlog.Test.Notify.SettingsGateTest do
  @moduledoc """
  Which notification types a site receives is a per-site boolean Setting (default on), checked once
  per delivery — the admin-managed, dynamic "which notifications do we want" control. There is no
  bespoke type registry or per-user matrix: turning the Setting off stops that type's delivery for
  that site, and only that site.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaCmsCore.{Notify, Settings}
  alias MishkaCmsCore.Notify.Notification

  defp feed(user) do
    Notification
    |> Ash.Query.for_read(:feed)
    |> Ash.read!(actor: user, tenant: user.site_id, page: false)
  end

  defp mute(type, site_id),
    do: Settings.put(Notify.setting_key(type), false, site_id: site_id)

  test "setting_key maps a colon type to a clean dotted settings key" do
    assert Notify.setting_key("blog:post:published") == "notify.blog.post.published"
  end

  describe "the per-site toggle gates delivery" do
    test "an unset type delivers (default on)" do
      site = create_site!()
      user = create_user!(site_id: site.id)

      assert {:ok, %{delivered: 1}} =
               Notify.deliver({:user, user.id}, %{type: "blog:post:published", title: "Live"},
                 site_id: site.id
               )

      assert [%{type: "blog:post:published"}] = feed(user)
    end

    test "muting the type stops delivery for that site and writes no row" do
      site = create_site!()
      user = create_user!(site_id: site.id)

      mute("blog:post:published", site.id)

      assert {:ok, %{delivered: 0}} =
               Notify.deliver({:user, user.id}, %{type: "blog:post:published", title: "Live"},
                 site_id: site.id
               )

      assert feed(user) == []
    end

    test "muting one type leaves the others delivering" do
      site = create_site!()
      user = create_user!(site_id: site.id)

      mute("blog:post:published", site.id)

      assert {:ok, %{delivered: 1}} =
               Notify.deliver(
                 {:user, user.id},
                 %{type: "blog:comment:created", title: "New comment"},
                 site_id: site.id
               )

      assert [%{type: "blog:comment:created"}] = feed(user)
    end

    test "muting one site does not mute another" do
      site_a = create_site!()
      site_b = create_site!()
      user_a = create_user!(site_id: site_a.id)
      user_b = create_user!(site_id: site_b.id)

      mute("blog:post:published", site_a.id)

      assert {:ok, %{delivered: 0}} =
               Notify.deliver({:user, user_a.id}, %{type: "blog:post:published", title: "A"},
                 site_id: site_a.id
               )

      assert {:ok, %{delivered: 1}} =
               Notify.deliver({:user, user_b.id}, %{type: "blog:post:published", title: "B"},
                 site_id: site_b.id
               )
    end
  end

  describe "extensions register their toggle via settings:register" do
    test "the blog toggle is a default-on boolean under the Blog tab, Notifications group" do
      definition =
        %{definitions: []}
        |> MishkaBlog.Notifiers.NotifySettings.call()
        |> then(fn {:reply, %{definitions: definitions}} -> definitions end)
        |> Enum.find(&(&1.key == Notify.setting_key("blog:post:published")))

      assert %{
               type: :boolean,
               default: true,
               scope: :both,
               category: "blog",
               group: "Notifications"
             } = definition
    end

    test "the running settings:register hook surfaces the blog toggle after load_definitions" do
      Settings.load_definitions()

      assert %{category: "blog", group: "Notifications"} =
               Settings.definition(Notify.setting_key("blog:post:published"))
    end
  end
end
