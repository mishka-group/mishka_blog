# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.PageSource do
  @moduledoc """
  Reads the rows a page of the blog shows, once, through the `runtime:page:source` mishka_installer
  hook `MishkaCmsWeb.RuntimeLive` fires in `handle_params/3` before the frame and the head
  (`MishkaCmsCore.Runtime.PageSource` is the contract: the map it is handed and where what it reads
  goes).

  A page is matched by the kind of record it says it shows (`record`, its `extra`'s `"record"`):
  `"blog:post"`, `"blog:category"`, `"blog:tag"`, `"blog:author"` or `"blog:team"`, the kinds
  `MishkaBlog.Plugins.PageRecords` names and `MishkaBlog.Plugins.PageSeo` and
  `MishkaBlog.Plugins.PageFrame` answer for, whatever section the page is in; and the blog's front
  page, the page of its Posts place. Every other page is handed back untouched, before anything is
  read. What is read, and as whom, is `MishkaBlog.PageSource`'s.

  Registered in `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook, event: "runtime:page:source", initial: %{priority: 50}

  @impl true
  def call(given) do
    case MishkaBlog.PageSource.read(given) do
      nil -> {:reply, given}
      source -> {:reply, :halt, %{given | source: source}}
    end
  end
end
