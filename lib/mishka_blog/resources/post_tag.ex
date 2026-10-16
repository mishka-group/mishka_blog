# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.PostTag do
  @moduledoc """
  Manages the many-to-many relationship between blog posts and tags with full version control.

  This resource serves as the join table that associates blog posts with tags,
  enabling posts to have multiple tags and tags to categorize multiple posts.
  Each record represents a tag assignment, indicating that a post is tagged
  with a specific tag for content organization and discovery.

  The resource implements upsert functionality through the assign action, preventing
  duplicate post-tag assignments while allowing efficient bulk updates.
  The unique constraint on post_id and tag_id pairs ensures that each post
  can only be assigned a specific tag once, maintaining data integrity.

  Post-tag associations are tracked through PaperTrail integration, recording
  when tags are added to or removed from posts. This provides a complete
  audit trail for content organization changes, essential for editorial workflows
  and taxonomy management.

  Access to this resource is controlled through policies that allow manipulation
  either through the BlogPost or Tag resource relationships or by users with
  administrative privileges. This ensures that tag assignments can only be
  modified by authorized actors.
  """
  use Ash.Resource,
    otp_app: :mishka_blog,
    domain: MishkaBlog,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook]

  use Gettext, backend: MishkaCmsCore.Gettext

  # Database configuration for join table
  postgres do
    table "mishka_blog_post_tags"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :post, on_delete: :delete
    end
  end

  actions do
    defaults [:create, :read, :destroy]

    default_accept []

    create :assign do
      description "Assigns a tag to a post, updating if already exists"
      primary? true
      accept [:post_id, :tag_id]
      upsert? true
      upsert_identity :unique_post_tag
    end
  end

  # Authorization policies for post-tag associations
  policies do
    # Reached through a parent's own relationship, which has already been authorized.
    bypass always() do
      authorize_if accessing_from(MishkaBlog.BlogPost, :tags_join_assoc)
      authorize_if accessing_from(MishkaBlog.BlogPost, :tenant_tags_join_assoc)
      authorize_if accessing_from(MishkaBlog.BlogPost, :master_tags_join_assoc)
      authorize_if accessing_from(MishkaBlog.Tag, :posts_join_assoc)
    end

    policy always() do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
    end

    # A master reaches every site's rows; a site admin only the rows of its own site.
    policy action_type([:read, :destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(post_in_any_state.site_id == ^actor(:site_id))
    end
  end

  # Every write names records of the site it is made for, whatever create action it uses.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
              field: :post_id,
              resource: MishkaBlog.BlogPost,
              message: dgettext_noop("errors", "Post not found or does not belong to your site.")},
             on: [:create]

    validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
              field: :tag_id,
              resource: MishkaBlog.Tag,
              message: dgettext_noop("errors", "Tag not found or does not belong to your site.")},
             on: [:create]

    # The two records it joins are of one site, and the one it joins is not archived, whoever writes
    # the row. Checked when the row is written, so the ids a parent's relationship fills in after
    # building it are checked too.
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :tag_id,
              resource: MishkaBlog.Tag,
              label: dgettext_noop("errors", "tag"),
              read_action: :master_read,
              own: {:post_id, MishkaBlog.BlogPost, :master_get}},
             before_action?: true
  end

  attributes do
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :post, MishkaBlog.BlogPost do
      primary_key? true
      allow_nil? false
      attribute_writable? true
    end

    belongs_to :tag, MishkaBlog.Tag, primary_key?: true, allow_nil?: false

    # The same post in any state, for telling which site this row belongs to.
    belongs_to :post_in_any_state, MishkaBlog.BlogPost do
      source_attribute :post_id
      define_attribute? false
      read_action :any_state
      public? false
    end
  end

  identities do
    identity :unique_post_tag, [:post_id, :tag_id] do
      description "Ensures each post-tag pair is unique"
    end
  end
end
