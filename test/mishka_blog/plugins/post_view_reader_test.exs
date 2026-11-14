# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.PostViewReaderTest do
  @moduledoc """
  A connected runtime page keeps its reader (user agent and session secret) whether the connect
  info is a websocket's map or the `Plug.Conn` of a `Phoenix.LiveViewTest`; a socket without a
  session keeps `session: nil` and a not connected one keeps no reader.
  """
  use ExUnit.Case, async: true

  alias MishkaBlog.Plugins.PostViewReader
  alias Phoenix.LiveView.Socket

  defp socket(info, transport_pid \\ self()) do
    %Socket{transport_pid: transport_pid, private: %{connect_info: info}}
  end

  defp reader({:reply, %Socket{private: private}}), do: private[:mishka_blog_reader]

  test "a websocket's connect info map gives the reader" do
    info = %{user_agent: "Firefox", session: %{"_csrf_token" => "secret"}}

    assert %{session: "secret", user_agent: "Firefox"} ==
             reader(PostViewReader.call(socket(info)))
  end

  test "a Plug.Conn connect info gives the same reader without raising" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{"_csrf_token" => "secret"})
      |> Plug.Conn.put_req_header("user-agent", "Firefox")

    assert %{session: "secret", user_agent: "Firefox"} ==
             reader(PostViewReader.call(socket(conn)))
  end

  test "a socket with no session keeps session nil" do
    assert %{session: nil} = reader(PostViewReader.call(socket(%{user_agent: "Firefox"})))

    conn = Phoenix.ConnTest.build_conn()
    assert %{session: nil} = reader(PostViewReader.call(socket(conn)))
  end

  test "a not connected socket keeps no reader" do
    assert nil == reader(PostViewReader.call(socket(%{session: %{}}, nil)))
  end
end
