# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Plugins.TranslationKeys do
  @moduledoc """
  Names the words the blog's bar looks up (`MishkaBlog.Plugins.PageFrame.words/0`) on the
  `runtime:translations:used_keys` mishka_installer hook `MishkaCmsCore.Runtime.Translations` fires
  when it works out which keys a site still uses.

  The bar is drawn by a plugin and not by a template, so no template holds its words, and without
  this the translations screen's "Remove unused" would delete them and what a translator wrote for
  them. `MishkaBlog.Provision` registers the same words when it sets a site up.

  A module because a mishka_installer hook is one. Registered in `MishkaBlog.Application`.
  """

  use MishkaInstaller.Event.Hook,
    event: "runtime:translations:used_keys",
    initial: %{priority: 50}

  alias MishkaBlog.Plugins.PageFrame

  @impl true
  def call(%{keys: keys} = data) when is_list(keys),
    do: {:reply, %{data | keys: keys ++ PageFrame.words()}}

  def call(data), do: {:reply, data}
end
