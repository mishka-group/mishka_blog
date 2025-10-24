defmodule MishkaBlog.BloggerFollower do
  @moduledoc """
  Manages user follows for bloggers.

  This resource represents follow relationships where users can follow bloggers to
  stay updated with their content. Each follow links a user to a specific blogger
  and tracks when the follow occurred and notification preferences.

  The unique constraint on follower_user_id and blogger_id ensures each user can
  only follow a specific blogger once. The notification_enabled field allows users
  to control whether they receive notifications about the blogger's new content.

  This resource has no multitenancy of its own, so a follow may only name a blogger of the site
  it is made for — see `MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation` — and
  `:by_blogger` lists only the followers of a blogger of the site it is asked on, and gives a site
  user nothing on any site but its own — see `MishkaBlog.Resources.Preparations.SiteAskedOn`.
  Database-level constraints ensure data integrity with cascade deletes when bloggers or users are
  removed.
  """
  use Ash.Resource,
    otp_app: :mishka_blog,
    domain: MishkaBlog,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource, GuardedStruct.AshResource],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook]

  require Ash.Query
  use Gettext, backend: MishkaCmsCore.Gettext

  # Database configuration for blogger_followers storage with indexing
  postgres do
    table "mishka_blog_blogger_followers"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    custom_indexes do
      index [:blogger_id]
      index [:follower_user_id]
      index [:followed_at]
      index [:notification_enabled]
    end

    references do
      reference :blogger, on_delete: :delete
      reference :follower_user, on_delete: :delete, name: "user_id"
    end
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "blogger_follower"
  end

  guardedstruct do
    auto_wire true

    field :followed_at, :utc_datetime_usec,
      derives: "validate(optional=[utc_datetime, past_datetime])"

    field :notification_enabled, :boolean, derives: "validate(boolean)"
  end

  actions do
    defaults [:read, :destroy]

    default_accept [:blogger_id, :notification_enabled]

    create :create do
      description "Follows a blogger"
      primary? true
      upsert? true
      upsert_identity :unique_follower_blogger

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :blogger_id,
                resource: MishkaBlog.Blogger,
                message:
                  dgettext_noop("errors", "Blogger not found or does not belong to your site.")}

      change relate_actor(:follower_user, allow_nil?: true)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :followed_at, DateTime.utc_now())
      end
    end

    read :by_user do
      description "Reads all bloggers followed by the current user with pagination"

      prepare fn query, context ->
        if actor = context.actor do
          Ash.Query.filter(query, follower_user_id == ^actor.id)
        else
          Ash.Query.filter(query, false)
        end
      end

      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
    end

    read :by_blogger do
      description "Reads all followers of a specific blogger of the site it is asked on"
      argument :blogger_id, :uuid, allow_nil?: false
      filter expr(blogger_id == ^arg(:blogger_id))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      # Only the site it is asked on, and a site user only on its own site.
      prepare {MishkaBlog.Resources.Preparations.SiteAskedOn, through: :blogger}
    end

    update :toggle_notifications do
      description "Toggles notification preference for a follow"
      accept [:notification_enabled]
      require_atomic? false
      primary? true
    end

    destroy :unfollow do
      description "Unfollows a blogger"
      primary? true
    end
  end

  policies do
    bypass action([:by_blogger]) do
      authorize_if always()
    end

    bypass action(:create) do
      authorize_if actor_present()
    end

    bypass action(:by_user) do
      access_type :strict
      authorize_if actor_present()
    end

    # Other actions check if actor owns the record
    policy action([:read, :toggle_notifications, :unfollow]) do
      authorize_if expr(follower_user_id == ^actor(:id))
    end
  end

  # The user a row names is a user of its blogger's site, or a master, whoever writes the row.
  # No update takes the user or the blogger, so only a create names them.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :follower_user_id,
              resource: MishkaCmsCore.Accounts.User,
              label: dgettext_noop("errors", "follower"),
              shared?: true,
              read_action: :related,
              own: {:blogger_id, MishkaBlog.Blogger, :master_get}},
             on: [:create],
             before_action?: true
  end

  attributes do
    uuid_primary_key :id

    attribute :followed_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      writable? false
      default &DateTime.utc_now/0
      description "Timestamp when the user followed the blogger"
    end

    attribute :notification_enabled, :boolean do
      default true
      public? true
      description "Whether the user wants to receive notifications about this blogger's content"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :blogger, MishkaBlog.Blogger do
      description "The blogger being followed"
      allow_nil? false
      public? true
    end

    belongs_to :follower_user, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      description "The user who is following"
      allow_nil? false
      public? true

      domain MishkaCmsCore.Accounts
    end
  end

  identities do
    identity :unique_follower_blogger, [:follower_user_id, :blogger_id] do
      description "Ensures each user can only follow a blogger once"
    end
  end
end
