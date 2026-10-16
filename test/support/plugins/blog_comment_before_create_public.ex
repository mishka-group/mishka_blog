# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Plugins.BlogCommentBeforeCreatePublic do
  @moduledoc """
  Test plugin for the before/reject seam `blog:comment:before_create_public` — rejects only comments
  whose content contains the test marker (so it never blocks other comments in the shared engine),
  proving a plugin can veto an action (the WordPress `pre_comment_approved` / Joomla
  `onContentBeforeSave` seam).
  """
  use MishkaInstaller.Event.Hook, event: "blog:comment:before_create_public"

  @impl true
  def call(changeset, _meta) do
    content = Ash.Changeset.get_attribute(changeset, :content) || ""

    if String.contains?(content, "REJECT_THIS_COMMENT") do
      {:reply, Ash.Changeset.add_error(changeset, field: :content, message: "rejected by plugin")}
    else
      {:reply, changeset}
    end
  end
end
