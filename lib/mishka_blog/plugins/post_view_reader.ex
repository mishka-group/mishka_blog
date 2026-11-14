# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.PostViewReader do
  @moduledoc """
  Keeps who is reading, for `MishkaBlog.Plugins.PostViewCount`, on the connected mount of a
  runtime page (`RuntimeLive.OnMount.AfterCompile`, which `MishkaCmsWeb.RuntimeLive` fires from
  `mount/3` with the socket).

  A LiveView reads its connect info only in `mount/3`, so the reader is kept in the socket's private
  `:mishka_blog_reader` as `%{user_agent: ua | nil, session: token | nil}`: the user agent when the
  host's `/live` socket lists `:user_agent` in its `connect_info`, and the session's CSRF secret,
  which is the same for every page a browser opens in one session. Neither is ever stored; the
  counter keeps only a salted hash of the session token. The first, not connected, render keeps
  nothing.

  The connect info has two shapes, and the session is read from whichever it is. On a websocket it
  is a map holding the `:session` the host's endpoint lists in `connect_info`. Under
  `Phoenix.LiveViewTest` it is the `Plug.Conn` the test was built from, where
  `Phoenix.LiveView.get_connect_info/2` has no `:session` clause and would raise, so the session
  is read from the conn when it was fetched. Without a session the reader's `:session` is `nil`.

  No address is read, so the reader is the same behind a reverse proxy (nginx, Traefik), where
  `:peer_data` is the proxy's and the client's sits in `:x_headers`.

  Registered in `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook,
    event: "RuntimeLive.OnMount.AfterCompile",
    initial: %{priority: 50}

  alias Phoenix.LiveView

  @impl true
  def call(%LiveView.Socket{} = socket) do
    case LiveView.connected?(socket) do
      true -> {:reply, LiveView.put_private(socket, :mishka_blog_reader, reader(socket))}
      false -> {:reply, socket}
    end
  end

  def call(state), do: {:reply, state}

  defp reader(socket) do
    %{
      user_agent: LiveView.get_connect_info(socket, :user_agent),
      session: session_token(socket.private[:connect_info])
    }
  end

  defp session_token(%Plug.Conn{private: %{plug_session: session}}), do: csrf_secret(session)
  defp session_token(%{session: session}), do: csrf_secret(session)
  defp session_token(_no_session), do: nil

  defp csrf_secret(%{"_csrf_token" => token}) when is_binary(token), do: token
  defp csrf_secret(_session), do: nil
end
