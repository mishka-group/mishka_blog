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
      session: session_token(LiveView.get_connect_info(socket, :session))
    }
  end

  defp session_token(%{"_csrf_token" => token}) when is_binary(token), do: token
  defp session_token(_no_session), do: nil
end
