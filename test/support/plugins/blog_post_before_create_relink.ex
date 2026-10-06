defmodule MishkaBlog.Test.Plugins.BlogPostBeforeCreateRelink do
  @moduledoc """
  Test plugin for the before seam `blog:blog_post:before_create` that rewrites a post's attributes
  before it is written.

  It sets the attributes a test puts under `:relink` in the changeset's context, so a test can check
  that what a plugin writes is held to the same rules as what the caller sent. A post written
  without that context passes through untouched.
  """
  use MishkaInstaller.Event.Hook, event: "blog:blog_post:before_create"

  @impl true
  def call(%Ash.Changeset{context: %{relink: attributes}} = changeset, _meta),
    do: {:reply, Ash.Changeset.force_change_attributes(changeset, attributes)}

  def call(changeset, _meta), do: {:reply, changeset}
end
