# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.PostViewCount do
  @moduledoc """
  Counts a view of a post when its page is shown to a connected reader
  (`RuntimeLive.HandleParams.AfterCompile`, which `MishkaCmsWeb.RuntimeLive` fires at the end of
  `handle_params/3` with the socket), into `MishkaBlog.Views`.

  A view counts only on the connected render, so a crawler that runs no JavaScript never counts, and
  only once per post for one LiveView: a live patch on the same post counts nothing. The post is the
  record the page's source read for the reader (`MishkaBlog.PageSource`), so a page showing no post
  counts nothing.

  ## The `blog:post:count_view` event

  Whether the view counts is answered on `"blog:post:count_view"`. A plugin is handed
  `%{count?: boolean, site_id:, post_id:, user_agent: ua | nil, current_user: user | nil}` and
  answers the same map, `count?` changed or not. `count?` starts `false` for a user agent that names
  a bot, a crawler or a headless browser (`bot?/1`), and `true` otherwise.

  Registered in `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook,
    event: "RuntimeLive.HandleParams.AfterCompile",
    initial: %{priority: 50}

  alias Phoenix.LiveView

  @event "blog:post:count_view"
  @bots ~r/bot|crawl|spider|slurp|facebookexternalhit|preview|headless|lighthouse|pagespeed|curl|wget|python|go-http-client|axios|node-fetch|phantom|selenium|puppeteer|playwright/i

  @doc "The event a view is answered on before it counts."
  @spec event() :: String.t()
  def event, do: @event

  @doc "Whether `user_agent` names a bot, a crawler, a script or a headless browser."
  @spec bot?(String.t() | nil) :: boolean()
  def bot?(user_agent) when is_binary(user_agent), do: Regex.match?(@bots, user_agent)
  def bot?(_unknown), do: false

  @impl true
  def call(%LiveView.Socket{} = socket) do
    case viewed(socket) do
      nil -> {:reply, socket}
      {site_id, post_id} -> {:reply, count(socket, site_id, post_id)}
    end
  end

  def call(state), do: {:reply, state}

  defp viewed(
         %{assigns: %{page_source: %MishkaBlog.PageSource{kind: "blog:post"} = source}} = socket
       ) do
    case source.record do
      %{id: post_id} -> unseen(socket, source.site_id, post_id)
      nil -> nil
    end
  end

  defp viewed(_socket), do: nil

  defp unseen(socket, site_id, post_id) do
    case LiveView.connected?(socket) and socket.private[:mishka_blog_viewed] != post_id do
      true -> {site_id, post_id}
      false -> nil
    end
  end

  defp count(socket, site_id, post_id) do
    reader = Map.get(socket.private, :mishka_blog_reader, %{})
    user_agent = Map.get(reader, :user_agent)
    current_user = Map.get(socket.assigns, :current_user)

    answer =
      MishkaInstaller.Event.Hook.call(@event, %{
        count?: not bot?(user_agent),
        site_id: site_id,
        post_id: post_id,
        user_agent: user_agent,
        current_user: current_user
      })

    with %{count?: true} <- answer,
         do: MishkaBlog.Views.hit(site_id, post_id, reader_key(current_user, reader))

    LiveView.put_private(socket, :mishka_blog_viewed, post_id)
  end

  defp reader_key(%{id: id}, _reader), do: {:user, id}
  defp reader_key(_guest, %{session: token}) when is_binary(token), do: {:session, token}
  defp reader_key(_guest, _reader), do: nil
end
