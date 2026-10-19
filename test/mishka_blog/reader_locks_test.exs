# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.ReaderLocksTest do
  @moduledoc """
  The filter the database applies for a reader (`MishkaBlog.Resources.Preparations.ReaderLocks`)
  gives the answer `MishkaCmsCore.Accounts.Checks.AccessPermissions` gives, for every reader the
  generator draws and every lock: names held exactly, with a `*` segment in any place, `*` alone,
  `admin:api:…` names, names of one segment or of six, empty segments, and none at all.
  """
  use MishkaBlog.DataCase, async: false
  use ExUnitProperties

  alias MishkaBlog.BlogPost
  alias MishkaBlog.Resources.Preparations.{OpenToActor, ReaderLocks}

  require Ash.Query

  @segments ["a", "b", "members", "read", "admin", "api", "dashboard", "x.y", "p+q", "*", ""]

  defp name do
    gen all(
          size <- StreamData.integer(1..5),
          parts <- StreamData.list_of(StreamData.member_of(@segments), length: size)
        ) do
      Enum.join(parts, ":")
    end
    |> StreamData.filter(&(&1 != ""))
  end

  defp lock, do: StreamData.list_of(name(), max_length: 4)

  defp actor(names), do: %{permissions: Enum.map(names, &%{name: &1})}

  describe "the tables the filter names" do
    test "are the resources' own" do
      assert AshPostgres.DataLayer.Info.table(MishkaBlog.Collection) == "mishka_blog_collections"

      assert AshPostgres.DataLayer.Info.table(MishkaBlog.PostCollection) ==
               "mishka_blog_post_collections"

      assert [:id, :site_id, :permissions, :parent_collection_id, :archived_at] --
               Enum.map(Ash.Resource.Info.attributes(MishkaBlog.Collection), & &1.name) == []

      assert [:post_id, :collection_id] --
               Enum.map(Ash.Resource.Info.attributes(MishkaBlog.PostCollection), & &1.name) == []

      assert AshPostgres.DataLayer.Info.table(MishkaCmsCore.Runtime.Page) == "pages"

      assert [:id, :site_id, :extra, :permissions, :active, :archived_at] --
               Enum.map(Ash.Resource.Info.attributes(MishkaCmsCore.Runtime.Page), & &1.name) == []
    end
  end

  describe "a lock on a page" do
    setup do
      site = create_site!(active: true)
      post = create_blog_post!(site_id: site.id, status: :published, language: "en")

      kinds =
        for {lock, index} <- Enum.with_index([nil, [] | Enum.take(lock(), 25)]), into: %{} do
          kind = "kind-#{index}"

          create_page!(
            site_id: site.id,
            path: "/kind-#{index}/:slug",
            extra: %{"record" => kind},
            permissions: lock
          )

          {kind, lock}
        end

      %{site: site, post: post, kinds: kinds}
    end

    defp page_opens?(site, post, reader, kind) do
      BlogPost
      |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
      |> Ash.Query.filter(
        id == ^post.id and ^ReaderLocks.page_open(reader, kind, ReaderLocks.site(site.id))
      )
      |> Ash.read!(page: false)
      |> Kernel.!=([])
    end

    property "opens for the reader the checker opens it for", ctx do
      %{site: site, post: post, kinds: kinds} = ctx

      check all(held <- StreamData.list_of(name(), max_length: 5), max_runs: 100) do
        reader = ReaderLocks.of(actor(held))

        for {kind, lock} <- kinds do
          assert page_opens?(site, post, reader, kind) == OpenToActor.opens?(lock, actor(held)),
                 "#{inspect(lock)} for #{inspect(held)}"
        end
      end
    end

    test "opens for every reader when no page shows the kind", %{site: site, post: post} do
      for held <- [nil, actor([]), actor(["members:read"])] do
        assert page_opens?(site, post, ReaderLocks.of(held), "blog:post")
      end
    end

    test "is closed to a reader holding nothing by the only page that shows the kind, and open to " <>
           "one holding any of its names",
         %{site: site, post: post} do
      create_page!(
        site_id: site.id,
        path: "/blog/:slug",
        extra: %{"record" => "blog:post"},
        permissions: ["members:read", "staff:*"]
      )

      for {held, expected} <- [
            {nil, false},
            {actor([]), false},
            {actor(["others:read"]), false},
            {actor(["members:read"]), true},
            {actor(["staff:x"]), false},
            {actor(["staff:*"]), true},
            {actor(["*"]), true}
          ] do
        assert page_opens?(site, post, ReaderLocks.of(held), "blog:post") == expected,
               inspect(held)
      end
    end
  end

  describe "a lock on a record" do
    setup do
      site = create_site!(active: true)

      locks = [nil, [] | Enum.take(lock(), 120)]

      posts =
        for lock <- locks,
            do:
              create_blog_post!(
                site_id: site.id,
                status: :published,
                language: "en",
                permissions: lock
              )

      %{site: site, posts: posts}
    end

    defp seen(site, reader) do
      BlogPost
      |> Ash.Query.for_read(:read, %{}, tenant: site.id, authorize?: false)
      |> Ash.Query.filter(^ReaderLocks.opens(reader))
      |> Ash.read!(page: false)
      |> MapSet.new(& &1.id)
    end

    property "opens for the reader the checker opens it for", %{site: site, posts: posts} do
      check all(held <- StreamData.list_of(name(), max_length: 5), max_runs: 300) do
        reader = actor(held)

        expected =
          for post <- posts,
              OpenToActor.opens?(post.permissions, reader),
              into: MapSet.new(),
              do: post.id

        assert seen(site, ReaderLocks.of(reader)) == expected,
               "held #{inspect(held)}"
      end
    end

    test "opens for nobody what names something when nothing is held", %{site: site, posts: posts} do
      expected = for post <- posts, post.permissions in [nil, []], into: MapSet.new(), do: post.id
      assert seen(site, ReaderLocks.of(nil)) == expected
      assert seen(site, ReaderLocks.of(actor([]))) == expected
    end
  end
end
