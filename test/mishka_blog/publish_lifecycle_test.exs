# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.PublishLifecycleTest do
  @moduledoc """
  A post's publish times follow its status through the create and update actions of a site's admin
  and of a master: a published post is stamped with the time it went live, a scheduled one must say
  when it will, and saving a post whose status is not changing moves neither.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.BlogPost

  @tenant_and_master [
    {:create, :update, :site},
    {:master_create, :master_update, :master}
  ]

  defp attrs(overrides) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        title: "Lifecycle #{n}",
        slug: "lifecycle-#{n}",
        content: "<p>Body</p>",
        status: :draft,
        language: "en"
      },
      Map.new(overrides)
    )
  end

  defp create(site, :site, action, overrides) do
    BlogPost
    |> Ash.Changeset.for_create(action, attrs(overrides), tenant: site.id, authorize?: false)
    |> Ash.create()
  end

  defp create(site, :master, action, overrides) do
    BlogPost
    |> Ash.Changeset.for_create(
      action,
      attrs(Map.put(overrides, :site_id, site.id)),
      authorize?: false
    )
    |> Ash.create()
  end

  defp update(post, :site, action, params) do
    post
    |> Ash.Changeset.for_update(action, params, tenant: post.site_id, authorize?: false)
    |> Ash.update()
  end

  defp update(post, :master, action, params) do
    post
    |> Ash.Changeset.for_update(action, params, authorize?: false)
    |> Ash.update()
  end

  defp future, do: DateTime.utc_now() |> DateTime.add(2 * 86_400, :second)
  defp seconds_ago(published_at), do: DateTime.diff(DateTime.utc_now(), published_at, :second)

  for {create_action, update_action, scope} <- @tenant_and_master do
    describe "#{create_action}" do
      test "stamps a published post with the time it went live" do
        site = create_site!()

        assert {:ok, post} =
                 create(site, unquote(scope), unquote(create_action), %{status: :published})

        assert %DateTime{} = post.published_at
        assert seconds_ago(post.published_at) in 0..5
        assert post.scheduled_publish_at == nil
      end

      test "keeps the published time a published post names" do
        site = create_site!()
        named = DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.truncate(:second)

        assert {:ok, post} =
                 create(site, unquote(scope), unquote(create_action), %{
                   status: :published,
                   published_at: named
                 })

        assert post.published_at == named
      end

      test "leaves a draft unpublished" do
        site = create_site!()

        assert {:ok, post} = create(site, unquote(scope), unquote(create_action), %{})
        assert post.status == :draft
        assert post.published_at == nil
      end

      test "refuses a scheduled post that does not say when" do
        site = create_site!()

        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 create(site, unquote(scope), unquote(create_action), %{status: :scheduled})

        assert Enum.any?(errors, &(Map.get(&1, :field) == :scheduled_publish_at))
      end

      test "takes a scheduled post that says when, with no published time yet" do
        site = create_site!()
        at = future() |> DateTime.truncate(:second)

        assert {:ok, post} =
                 create(site, unquote(scope), unquote(create_action), %{
                   status: :scheduled,
                   scheduled_publish_at: at
                 })

        assert post.status == :scheduled
        assert post.scheduled_publish_at == at
        assert post.published_at == nil
      end
    end

    describe "#{update_action}" do
      setup do
        site = create_site!()
        {:ok, draft} = create(site, unquote(scope), unquote(create_action), %{})
        {:ok, site: site, draft: draft}
      end

      test "stamps a draft that becomes published", %{draft: draft} do
        assert {:ok, post} =
                 update(draft, unquote(scope), unquote(update_action), %{status: :published})

        assert %DateTime{} = post.published_at
        assert seconds_ago(post.published_at) in 0..5
      end

      test "does not move the published time of a post that stays published", %{draft: draft} do
        {:ok, published} =
          update(draft, unquote(scope), unquote(update_action), %{status: :published})

        long_ago =
          DateTime.utc_now() |> DateTime.add(-86_400, :second) |> DateTime.truncate(:second)

        {:ok, published} =
          published
          |> Ash.Changeset.for_update(:master_update, %{}, authorize?: false)
          |> Ash.Changeset.force_change_attribute(:published_at, long_ago)
          |> Ash.update()

        assert {:ok, saved} =
                 update(published, unquote(scope), unquote(update_action), %{
                   title: "Saved again",
                   status: :published
                 })

        assert saved.title == "Saved again"
        assert saved.published_at == long_ago
      end

      test "does not stamp a post whose status is not changing", %{draft: draft} do
        assert {:ok, post} =
                 update(draft, unquote(scope), unquote(update_action), %{title: "Still a draft"})

        assert post.status == :draft
        assert post.published_at == nil
      end

      test "refuses a draft that becomes scheduled without saying when", %{draft: draft} do
        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 update(draft, unquote(scope), unquote(update_action), %{status: :scheduled})

        assert Enum.any?(errors, &(Map.get(&1, :field) == :scheduled_publish_at))
      end

      test "takes a draft that becomes scheduled with a time", %{draft: draft} do
        at = future() |> DateTime.truncate(:second)

        assert {:ok, post} =
                 update(draft, unquote(scope), unquote(update_action), %{
                   status: :scheduled,
                   scheduled_publish_at: at
                 })

        assert post.status == :scheduled
        assert post.scheduled_publish_at == at
        assert post.published_at == nil
      end
    end
  end
end
