defmodule MishkaBlog.TeamFollower do
  @moduledoc """
  Manages user follows for teams.

  This resource represents follow relationships where users can follow teams to
  stay updated with the team's content. Each follow links a user to a specific team
  and tracks when the follow occurred and notification preferences.

  The unique constraint on follower_user_id and team_id ensures each user can
  only follow a specific team once. The notification_enabled field allows users
  to control whether they receive notifications about the team's new content.

  This resource has no multitenancy of its own, so a follow may only name a team of the site it
  is made for — see `MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation`.
  Database-level constraints ensure data integrity with cascade deletes when teams or users are
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

  # Database configuration for team_followers storage with indexing
  postgres do
    table "mishka_blog_team_followers"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    custom_indexes do
      index [:team_id]
      index [:follower_user_id]
      index [:followed_at]
      index [:notification_enabled]
    end

    references do
      reference :team, on_delete: :delete
      reference :follower_user, on_delete: :delete, name: "user_id"
    end
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "team_follower"

    includes [:team]
  end

  guardedstruct do
    auto_wire true

    field :followed_at, :utc_datetime_usec,
      derives: "validate(optional=[utc_datetime, past_datetime])"

    field :notification_enabled, :boolean, derives: "validate(boolean)"
  end

  actions do
    defaults [:read, :destroy]

    default_accept [:team_id, :follower_user_id, :notification_enabled]

    create :create do
      description "Follows a team"
      primary? true
      upsert? true
      accept [:team_id, :notification_enabled]
      upsert_identity :unique_follower_team

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :team_id,
                resource: MishkaBlog.Team,
                message:
                  dgettext_noop("errors", "Team not found or does not belong to your site.")}

      change relate_actor(:follower_user, allow_nil?: true)

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :followed_at, DateTime.utc_now())
      end
    end

    read :by_user do
      description "Reads all teams followed by a specific user with pagination"
      argument :follower_user_id, :uuid, allow_nil?: false
      filter expr(follower_user_id == ^arg(:follower_user_id))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
    end

    read :my_following do
      description "Reads all my following teams"
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        if actor = context.actor do
          query
          |> Ash.Query.filter(follower_user_id == ^actor.id)
          |> Ash.Query.filter(team.status == :active)
        else
          Ash.Query.filter(query, false)
        end
      end
    end

    read :by_team do
      description "Reads all followers of a specific team of the site it is asked on"
      argument :team_id, :uuid, allow_nil?: false
      filter expr(team_id == ^arg(:team_id))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      # Only the site it is asked on, and a site user only on its own site.
      prepare {MishkaBlog.Resources.Preparations.SiteAskedOn, through: :team}
    end

    update :toggle_notifications do
      description "Toggles notification preference for a follow"
      accept [:notification_enabled]
      require_atomic? false
    end

    destroy :unfollow do
      description "Unfollows a team"
      primary? true
    end
  end

  # Authorization policies - users can only manage their own follows
  policies do
    bypass action(:my_following) do
      access_type :strict
      authorize_if actor_present()
    end

    bypass action(:by_team) do
      authorize_if always()
    end

    bypass action_type(:read) do
      authorize_if expr(follower_user_id == ^actor(:id))
    end

    bypass action_type(:create) do
      authorize_if actor_present()
    end

    bypass action_type(:update) do
      authorize_if expr(follower_user_id == ^actor(:id))
    end

    bypass action_type(:destroy) do
      authorize_if expr(follower_user_id == ^actor(:id))
    end

    # Admin access
    policy always() do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
    end

    # A master reaches every site's rows; a site admin only the rows of its own site.
    policy action_type([:read, :update, :destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(team_in_any_state.site_id == ^actor(:site_id))
    end
  end

  # The user a row names is a user of its team's site, or a master, whoever writes the row.
  # No update takes the user or the team, so only a create names them.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :follower_user_id,
              resource: MishkaCmsCore.Accounts.User,
              label: dgettext_noop("errors", "follower"),
              shared?: true,
              read_action: :related,
              own: {:team_id, MishkaBlog.Team, :master_get}},
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
      description "Timestamp when the user followed the team"
    end

    attribute :notification_enabled, :boolean do
      default true
      public? true
      description "Whether the user wants to receive notifications about this team's content"
    end

    create_timestamp :inserted_at, public?: true
    update_timestamp :updated_at, public?: true
  end

  relationships do
    belongs_to :team, MishkaBlog.Team do
      description "The team being followed"
      allow_nil? false
      public? true
      read_action :public_list
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

    # The same team in any state, for telling which site this row belongs to.
    belongs_to :team_in_any_state, MishkaBlog.Team do
      source_attribute :team_id
      define_attribute? false
      read_action :any_state
      public? false
    end
  end

  identities do
    identity :unique_follower_team, [:follower_user_id, :team_id] do
      description "Ensures each user can only follow a team once"
    end
  end
end
