# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Workers.PublishScheduledWorkerTest do
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.BlogPost
  alias MishkaBlog.Repo
  alias MishkaBlog.Workers.PublishScheduledWorker

  # A schedule can only be written in the future (`scheduled_publish_future`), so a due post is a
  # scheduled one whose time is moved back with the check off. The check comes back NOT VALID: the
  # rows already there are kept, and every later update of them is checked again.
  defp with_schedule_check_off(fun) do
    Repo.query!("ALTER TABLE mishka_blog_posts DROP CONSTRAINT scheduled_publish_future")
    result = fun.()

    Repo.query!("""
    ALTER TABLE mishka_blog_posts ADD CONSTRAINT scheduled_publish_future
      CHECK (scheduled_publish_at IS NULL OR scheduled_publish_at > timezone('UTC', NOW())) NOT VALID
    """)

    result
  end

  defp scheduled!(site, minutes) do
    at = DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second)
    post = create_blog_post!(status: :scheduled, scheduled_publish_at: at, site_id: site.id)

    if minutes < 0 do
      due =
        DateTime.utc_now() |> DateTime.add(minutes * 60, :second) |> DateTime.truncate(:second)

      Repo.query!("UPDATE mishka_blog_posts SET scheduled_publish_at = $1 WHERE id = $2", [
        due,
        Ecto.UUID.dump!(post.id)
      ])

      %{post | scheduled_publish_at: due}
    else
      post
    end
  end

  defp row(post) do
    %{rows: [[status, published_at, scheduled_publish_at]]} =
      Repo.query!(
        "SELECT status, published_at, scheduled_publish_at FROM mishka_blog_posts WHERE id = $1",
        [Ecto.UUID.dump!(post.id)]
      )

    %{status: status, published_at: published_at, scheduled_publish_at: scheduled_publish_at}
  end

  defp run!, do: assert(:ok = PublishScheduledWorker.perform(%Oban.Job{args: %{}}))

  defp same_second?(%NaiveDateTime{} = naive, %DateTime{} = at),
    do: NaiveDateTime.compare(naive, DateTime.to_naive(at)) == :eq

  describe "a run" do
    test "publishes a due post at its scheduled time and clears its schedule" do
      site = create_site!()
      due = with_schedule_check_off(fn -> scheduled!(site, -5) end)

      run!()

      assert %{status: "published", scheduled_publish_at: nil, published_at: published_at} =
               row(due)

      assert same_second?(published_at, due.scheduled_publish_at)
    end

    test "leaves a future scheduled post, a draft, a published and an archived post alone" do
      site = create_site!()
      future = scheduled!(site, 60)
      draft = create_blog_post!(status: :draft, site_id: site.id)
      published = create_blog_post!(status: :published, site_id: site.id)

      archived =
        with_schedule_check_off(fn ->
          site
          |> scheduled!(-5)
          |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
          |> Ash.destroy!(return_destroyed?: true)
        end)

      before = Map.new([future, draft, published, archived], &{&1.id, row(&1)})

      run!()

      assert Map.new([future, draft, published, archived], &{&1.id, row(&1)}) == before
      assert %{status: "scheduled"} = row(future)
      assert %{status: "archived"} = row(archived)
    end

    test "publishes the due posts of every site" do
      [one, two] = [create_site!(), create_site!()]

      posts =
        with_schedule_check_off(fn -> [scheduled!(one, -3), scheduled!(two, -1)] end)

      run!()

      assert Enum.all?(posts, &match?(%{status: "published", scheduled_publish_at: nil}, row(&1)))
    end

    test "a second run publishes nothing more and moves no publication time" do
      site = create_site!()
      due = with_schedule_check_off(fn -> scheduled!(site, -5) end)

      run!()
      first = row(due)
      run!()

      assert row(due) == first
    end
  end

  describe "a scheduled post published by hand before its time" do
    test "loses its schedule, so a later save of it is not refused" do
      site = create_site!()
      post = scheduled!(site, 60)

      published =
        post
        |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
        |> Ash.update!()

      assert published.status == :published
      assert published.scheduled_publish_at == nil
      assert DateTime.compare(published.published_at, post.scheduled_publish_at) == :lt

      assert %{title: "Edited later"} =
               published
               |> Ash.Changeset.for_update(:update, %{title: "Edited later"},
                 tenant: site.id,
                 authorize?: false
               )
               |> Ash.update!()
    end

    test "loses its schedule through the master publish too" do
      site = create_site!()
      post = scheduled!(site, 60)

      assert %{status: :published, scheduled_publish_at: nil} =
               post
               |> Ash.Changeset.for_update(:master_publish, %{}, authorize?: false)
               |> Ash.update!()
    end
  end

  describe ":due_scheduled" do
    test "reads only the scheduled posts whose time has come" do
      site = create_site!()
      _future = scheduled!(site, 60)
      due = with_schedule_check_off(fn -> scheduled!(site, -5) end)

      assert [%{id: id}] =
               BlogPost
               |> Ash.Query.for_read(:due_scheduled, %{}, authorize?: false)
               |> Ash.read!()

      assert id == due.id
    end
  end
end
