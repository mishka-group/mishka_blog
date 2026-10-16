# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Plugins.BlogCommentBeforeCreatePublicRelink do
  @moduledoc """
  Test plugin for the before seam `blog:comment:before_create_public` that rewrites a comment's
  attributes before it is written.

  It sets the attributes a test puts under `:relink` in the changeset's context, so a test can check
  that what a plugin writes is held to the same rules as what the caller sent. A comment written
  without that context passes through untouched.
  """
  use MishkaInstaller.Event.Hook, event: "blog:comment:before_create_public"

  @impl true
  def call(%Ash.Changeset{context: %{relink: attributes}} = changeset, _meta),
    do: {:reply, Ash.Changeset.force_change_attributes(changeset, attributes)}

  def call(changeset, _meta), do: {:reply, changeset}
end
