# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.ViewsTest do
  @moduledoc """
  `MishkaBlog.Views` counts views in memory and writes them with one upsert per flush
  (`MishkaBlog.PostViewDaily`); `MishkaBlog.Plugins.PostViewCount` counts only a connected reader
  of a post's page who is not a bot.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.Plugins.PostViewCount
  alias MishkaBlog.PostViewDaily
  alias MishkaBlog.Test.Plugins.BlogPostViewedProbe
  alias MishkaBlog.Views
  alias MishkaInstaller.Event.{Event, EventHandler}

  require Ash.Query

  setup do
    # What another test counted is written, or dropped with its posts, before this one counts.
    Views.flush()

    site = create_site!()
    %{site: site, post: create_blog_post!(site_id: site.id, status: :published)}
  end

  defp rows(post) do
    PostViewDaily
    |> Ash.Query.filter(post_id == ^post.id)
    |> Ash.read!(authorize?: false)
  end

  describe "the buffer and its flush" do
    test "many hits are one row with their sum, and a second flush adds to it", %{post: post} do
      for _ <- 1..25, do: :ok = Views.hit(post.site_id, post.id, nil)
      assert :ok = Views.flush()
      assert [%{views: 25}] = rows(post)

      for _ <- 1..5, do: Views.hit(post.site_id, post.id, nil)
      assert :ok = Views.flush()
      assert [%{views: 30}] = rows(post)
    end

    test "a reader is one unique reader a day, however often they read", %{post: post} do
      for _ <- 1..3, do: Views.hit(post.site_id, post.id, {:session, "one"})
      Views.hit(post.site_id, post.id, {:session, "two"})
      Views.flush()

      Views.hit(post.site_id, post.id, {:session, "one"})
      Views.flush()

      assert [%{views: 5, unique_readers: 2}] = rows(post)
    end

    test "hits are dropped, not queued, once the buffer is full", %{site: site, post: post} do
      Application.put_env(:mishka_blog, Views, max_keys: 1)
      on_exit(fn -> Application.delete_env(:mishka_blog, Views) end)

      other = create_blog_post!(site_id: site.id, status: :published)

      assert :ok = Views.hit(site.id, post.id, nil)
      assert :dropped = Views.hit(site.id, other.id, nil)
      Views.flush()

      assert [%{views: 1}] = rows(post)
      assert [] = rows(other)
    end

    @tag :capture_log
    test "a failed write keeps its counts for the next flush", %{post: post} do
      Views.hit(post.site_id, post.id, nil)
      # A count no row may hold makes the write fail as a database refusing it would.
      key = {post.site_id, post.id, Date.utc_today()}
      :ets.update_counter(:mishka_blog_views, key, {2, -5})

      assert {:error, _errors} = Views.flush()
      assert [] = rows(post)

      :ets.update_counter(:mishka_blog_views, key, {2, 5})
      Views.hit(post.site_id, post.id, nil)

      assert :ok = Views.flush()
      assert [%{views: 2}] = rows(post)
    end

    test "the views of a deleted post are dropped", %{post: post} do
      Views.hit(post.site_id, post.id, nil)
      Ash.destroy!(post, action: :permanent_destroy, tenant: post.site_id, authorize?: false)

      assert :ok = Views.flush()
      assert [] = rows(post)
    end

    test "a flush fires blog:post:viewed once with its batch", %{post: post} do
      Process.register(self(), :__blog_hook_probe__)

      {:ok, _} =
        Event.write(%{
          name: BlogPostViewedProbe,
          event: Views.event(),
          extension: :mishka_installer,
          status: :started
        })

      :ok = EventHandler.do_compile(Views.event(), :start, false)
      on_exit(fn -> Event.unregister(:name, BlogPostViewedProbe, false) end)

      for _ <- 1..3, do: Views.hit(post.site_id, post.id, nil)
      Views.flush()

      post_id = post.id
      assert_receive {:blog_post_viewed, [%{post_id: ^post_id, views: 3}]}
      refute_received {:blog_post_viewed, _another}
    end
  end

  describe "the post page" do
    defp page(post, opts) do
      %Phoenix.LiveView.Socket{
        transport_pid: Keyword.get(opts, :transport_pid, self()),
        assigns: %{
          __changed__: %{},
          current_user: nil,
          page_source: %MishkaBlog.PageSource{
            site_id: post.site_id,
            visitor: nil,
            language: "en",
            kind: "blog:post",
            record: post
          }
        },
        private: %{
          mishka_blog_reader: %{
            user_agent: Keyword.get(opts, :user_agent, "Mozilla/5.0 Firefox/140.0"),
            session: "session"
          }
        }
      }
    end

    defp show(socket) do
      {:reply, socket} = PostViewCount.call(socket)
      socket
    end

    test "a connected reader counts once per post, a live patch on it adds nothing", %{post: post} do
      post |> page([]) |> show() |> show()
      Views.flush()

      assert [%{views: 1, unique_readers: 1}] = rows(post)
    end

    test "the first, not connected, render counts nothing", %{post: post} do
      post |> page(transport_pid: nil) |> show()
      Views.flush()

      assert [] = rows(post)
    end

    test "a reader with no user agent, behind any proxy, still counts", %{post: post} do
      post |> page(user_agent: nil) |> show()
      post |> page([]) |> Map.update!(:private, &Map.delete(&1, :mishka_blog_reader)) |> show()
      Views.flush()

      assert [%{views: 2}] = rows(post)
    end

    test "a bot counts nothing", %{post: post} do
      post |> page(user_agent: "Mozilla/5.0 (compatible; Googlebot/2.1)") |> show()
      post |> page(user_agent: "Mozilla/5.0 HeadlessChrome/140.0") |> show()
      Views.flush()

      assert [] = rows(post)
    end
  end

  test "purge_expired deletes the days older than the retention", %{post: post} do
    old = Date.add(Date.utc_today(), -(PostViewDaily.retention_days() + 1))
    create_post_views!(post: post, views: 4, day: old)
    create_post_views!(post: post, views: 2)

    Ash.run_action!(Ash.ActionInput.for_action(PostViewDaily, :purge_expired, %{}),
      authorize?: false
    )

    assert [%{views: 2}] = rows(post)
  end
end
