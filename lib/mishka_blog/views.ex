# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Views do
  @moduledoc """
  Counts the views of a site's posts in memory and writes them once a minute, so a view costs no
  database write.

  `hit/4` adds one view to an ETS counter keyed `{site_id, post_id, day}`. A reader key (a signed-in
  reader's id or the session's token) is kept only as a hash of the key, the day and a random salt
  of this node, in a set that lives for the day, and a reader new to it adds one unique reader. No
  IP is ever read. When the buffer holds `:max_keys` keys (100,000), a hit is dropped, never
  queued; when the day's reader set holds as many, the view is counted but not its reader.

  Every `:flush_every` milliseconds (60 seconds) the GenServer takes what was counted and writes it
  with one bulk upsert of `MishkaBlog.PostViewDaily`'s `:record`. A write that fails puts its
  numbers back, so the next flush adds them, and the views of a post deleted since are dropped.
  Stopping the server flushes too. `flush/0` flushes now
  and answers once it is written.

  Both are set in the host's config:

      config :mishka_blog, MishkaBlog.Views, flush_every: :timer.seconds(60), max_keys: 100_000

  The counters are this node's: on several nodes each counts and flushes its own, and the row adds
  them up. A reader served by two nodes on one day is two unique readers.

  ## The `blog:post:viewed` event

  After a flush writes, `"blog:post:viewed"` is fired once with the batch,
  `%{views: [%{site_id:, post_id:, day:, views:, unique_readers:}]}`, so a plugin can forward the
  numbers elsewhere. It is never fired per view.
  """
  use GenServer

  require Ash.Query
  require Logger

  @counts :mishka_blog_views
  @readers :mishka_blog_view_readers
  @event "blog:post:viewed"
  @flush_every :timer.seconds(60)
  @max_keys 100_000

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Counts one view of `post_id` on `site_id` by `reader`, a term that tells one reader apart (or
  `nil` when nothing does, which counts the view but no unique reader). `:dropped` when the buffer
  is full or the server is not running.
  """
  @spec hit(String.t(), String.t(), term(), Date.t()) :: :ok | :dropped
  def hit(site_id, post_id, reader, day \\ Date.utc_today()) do
    key = {site_id, post_id, day}

    case full?(@counts) do
      false ->
        :ets.update_counter(@counts, key, {2, 1}, {key, 0, 0})
        reader(key, reader)

      true ->
        :dropped
    end
  end

  @doc "Writes what was counted now, and answers what the write returned."
  @spec flush() :: :ok | {:error, term()}
  def flush, do: GenServer.call(__MODULE__, :flush)

  @doc "The event a flush fires with its batch."
  @spec event() :: String.t()
  def event, do: @event

  defp full?(table) do
    case :ets.info(table, :size) do
      :undefined -> true
      size -> size >= config(:max_keys, @max_keys)
    end
  end

  defp reader(_key, nil), do: :ok

  defp reader({_site_id, _post_id, day} = key, reader) do
    hash = :crypto.hash(:sha256, :erlang.term_to_binary({salt(), key, reader}))

    with false <- full?(@readers),
         true <- :ets.insert_new(@readers, {{Date.to_gregorian_days(day), hash}}) do
      :ets.update_counter(@counts, key, {3, 1}, {key, 0, 0})
    end

    :ok
  end

  defp salt, do: :persistent_term.get({__MODULE__, :salt})

  defp config(key, default),
    do: :mishka_blog |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    :persistent_term.put({__MODULE__, :salt}, :crypto.strong_rand_bytes(16))
    :ets.new(@counts, [:set, :public, :named_table, write_concurrency: true])
    :ets.new(@readers, [:set, :public, :named_table, write_concurrency: true])
    {:ok, schedule()}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, write(), state}

  @impl true
  def handle_info(:flush, _state) do
    write()
    {:noreply, schedule()}
  end

  @impl true
  def terminate(_reason, _state), do: write()

  defp schedule, do: Process.send_after(self(), :flush, config(:flush_every, @flush_every))

  defp write do
    forget_old_readers()

    case take() |> of_posts() do
      [] -> :ok
      rows -> rows |> upsert() |> answer(rows)
    end
  end

  # A post deleted or archived since its view was counted takes its views with it, so they never
  # fail a write.
  defp of_posts([]), do: []

  defp of_posts(rows) do
    ids = rows |> Enum.map(fn {{_site_id, post_id, _day}, _views, _readers} -> post_id end)

    MishkaBlog.BlogPost
    |> Ash.Query.for_read(:read_any, %{}, authorize?: false)
    |> Ash.Query.filter(id in ^Enum.uniq(ids))
    |> Ash.Query.select([:id, :site_id])
    |> Ash.read(page: false)
    |> case do
      {:ok, posts} ->
        there = MapSet.new(posts, &{&1.site_id, &1.id})

        Enum.filter(rows, fn {{site_id, post_id, _day}, _v, _r} -> {site_id, post_id} in there end)

      {:error, _error} ->
        rows
    end
  end

  # What a flush takes is taken out by subtraction, so a view counted while it writes is kept for
  # the next one.
  defp take do
    rows = :ets.tab2list(@counts)

    Enum.each(rows, fn {key, views, readers} ->
      :ets.update_counter(@counts, key, [{2, -views}, {3, -readers}])
    end)

    :ets.select_delete(@counts, [{{:_, 0, 0}, [], [true]}])
    rows
  end

  defp upsert(rows) do
    rows
    |> batch()
    |> Ash.bulk_create(MishkaBlog.PostViewDaily, :record,
      authorize?: false,
      batch_size: max(length(rows), 1),
      return_errors?: true,
      stop_on_error?: true
    )
  end

  defp answer(%Ash.BulkResult{status: :success}, rows) do
    MishkaInstaller.Event.Hook.call(@event, %{views: batch(rows)}, return: false)
    :ok
  end

  defp answer(%Ash.BulkResult{errors: errors}, rows) do
    Enum.each(rows, fn {key, views, readers} ->
      :ets.update_counter(@counts, key, [{2, views}, {3, readers}], {key, 0, 0})
    end)

    Logger.warning(
      "[MishkaBlog] writing post views failed, kept for the next flush: #{inspect(errors)}"
    )

    {:error, errors}
  end

  defp batch(rows) do
    Enum.map(rows, fn {{site_id, post_id, day}, views, readers} ->
      %{site_id: site_id, post_id: post_id, day: day, views: views, unique_readers: readers}
    end)
  end

  defp forget_old_readers do
    today = Date.to_gregorian_days(Date.utc_today())
    :ets.select_delete(@readers, [{{{:"$1", :_}}, [{:<, :"$1", today}], [true]}])
  end
end
