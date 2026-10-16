# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.PostView do
  @moduledoc """
  Tracks unique page views for blog posts using upsert.

  Simple and efficient view tracking:
  - For authenticated users: One view per user per post (by user_id + post_id)
  - For guests: One view per IP per post (by ip_address + post_id)
  - Uses upsert: No queries, no time checks - just insert or ignore
  - Works for both JSON API and Phoenix controllers
  """
  use Ash.Resource,
    otp_app: :mishka_blog,
    domain: MishkaBlog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource, GuardedStruct.AshResource],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook]

  use Gettext, backend: MishkaCmsCore.Gettext

  postgres do
    table "mishka_blog_post_views"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    custom_indexes do
      index [:post_id]
    end

    references do
      reference :post, on_delete: :delete
      reference :user, on_delete: :delete
    end

    # SQL translations for conditional identities
    identity_wheres_to_sql unique_user_view: "user_id IS NOT NULL",
                           unique_guest_view: "user_id IS NULL"
  end

  json_api do
    type "post_view"
  end

  guardedstruct do
    auto_wire true

    field :ip_address, :string,
      derives: "sanitize(trim) validate(string, not_empty, max_len=45, ip)"

    field :user_agent, :string,
      derives: "sanitize(trim, no_zero_width) validate(optional=[string, max_len=500])"

    field :referer, :string, derives: "sanitize(trim) validate(optional=[string, max_len=500])"
  end

  actions do
    defaults [:read]

    create :create do
      description "Track a page view (upserts automatically - no duplicates)"
      primary? true
      accept [:post_id, :user_id, :ip_address, :user_agent, :referer]

      upsert? true
      upsert_identity :unique_view
      upsert_fields []

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :post_id,
                resource: MishkaBlog.BlogPost,
                message:
                  dgettext_noop("errors", "Post not found or does not belong to your site.")}
    end
  end

  policies do
    # Anyone can track views
    policy action_type(:create) do
      authorize_if always()
    end

    # Only admins can query view data
    policy action_type(:read) do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
    end

    # A master reads every site's views; a site admin only the views of its own site's posts.
    policy action_type(:read) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(post_in_any_state.site_id == ^actor(:site_id))
    end
  end

  # The user a row names is a user of its post's site, or a master, whoever writes the row.
  # No update takes the user or the post, so only a create names them.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :user_id,
              resource: MishkaCmsCore.Accounts.User,
              label: dgettext_noop("errors", "viewer"),
              shared?: true,
              read_action: :related,
              own: {:post_id, MishkaBlog.BlogPost, :master_get}},
             on: [:create],
             before_action?: true
  end

  attributes do
    uuid_primary_key :id

    attribute :ip_address, :string do
      allow_nil? false
      public? true
      constraints max_length: 45
      description "IP address (required for guest tracking)"
    end

    attribute :user_agent, :string do
      allow_nil? true
      public? true
      constraints max_length: 500
      description "Browser user agent"
    end

    attribute :referer, :string do
      allow_nil? true
      public? true
      constraints max_length: 500
      description "HTTP referer"
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :post, MishkaBlog.BlogPost do
      description "The blog post being viewed"
      allow_nil? false
      public? true
    end

    belongs_to :user, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      description "The user who viewed (null for guests)"
      allow_nil? true
      public? true

      domain MishkaCmsCore.Accounts
    end

    # The same post in any state, for telling which site this row belongs to.
    belongs_to :post_in_any_state, MishkaBlog.BlogPost do
      source_attribute :post_id
      define_attribute? false
      read_action :any_state
      public? false
    end
  end

  identities do
    # For authenticated users: unique by user_id + post_id
    identity :unique_user_view, [:post_id, :user_id],
      where: expr(not is_nil(user_id)),
      nils_distinct?: false

    # For guests: unique by ip_address + post_id
    identity :unique_guest_view, [:post_id, :ip_address],
      where: expr(is_nil(user_id)),
      nils_distinct?: false

    # Combined identity for upsert
    identity :unique_view, [:post_id, :user_id, :ip_address], nils_distinct?: false
  end
end
