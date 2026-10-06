defmodule MishkaBlog.TeamPermission do
  @moduledoc """
  Manages the many-to-many relationship between teams and permissions.

  This resource serves as the join table that attaches permissions to teams. Each record is one
  permission attached to one team. Team members do not inherit it: every gate reads the
  permissions a user holds itself.

  The resource implements upsert functionality through the assign action, preventing
  duplicate permission assignments. The unique constraint on team_id and permission_id pairs
  ensures that each team can only have a permission assigned once.

  Reading a row needs the blog's post area, `admin:<surface>:blog:post`. Writing or removing one also needs the
  permission area on the request's surface, and a site's admin attaches only permissions it holds
  itself (`MishkaCmsCore.Accounts.Validations.GrantWithinActorScope`) — whether through
  `MishkaBlog.Team` or directly.
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
    table "mishka_blog_team_permissions"
    repo Application.compile_env!(:mishka_cms_core, :repo)
  end

  actions do
    defaults [:create, :read, :destroy]

    create :assign do
      description "Assigns a permission to a team, updating if already exists"
      primary? true
      accept [:team_id, :permission_id]
      upsert? true
      upsert_identity :unique_team_permission
    end
  end

  # Authorization policies for permission assignment
  policies do
    policy always() do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
    end

    policy action_type([:create, :destroy]) do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:permission", "admin:api:permission"]}
    end

    # A master reaches every site's rows; a site admin only the rows of its own site.
    policy action_type([:read, :destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(team_in_any_state.site_id == ^actor(:site_id))
    end
  end

  # Every write names records of the site it is made for, whatever create action it uses.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
              field: :team_id,
              resource: MishkaBlog.Team,
              message: dgettext_noop("errors", "Team not found or does not belong to your site.")},
             on: [:create]

    validate &__MODULE__.within_actor_scope/2, on: [:create], before_action?: true
  end

  @doc false
  # `GrantWithinActorScope` reads the permission a grant names from its `:permission_id` argument;
  # a row names it in its attribute.
  def within_actor_scope(changeset, context) do
    permission_id = Ash.Changeset.get_attribute(changeset, :permission_id)
    named = %{changeset | arguments: Map.put(changeset.arguments, :permission_id, permission_id)}

    MishkaCmsCore.Accounts.Validations.GrantWithinActorScope.validate(named, [], context)
  end

  attributes do
    uuid_primary_key :id
    create_timestamp :created_at
  end

  relationships do
    belongs_to :team, MishkaBlog.Team do
      description "The team being granted the permission"
      primary_key? true
      allow_nil? false
      attribute_public? true
    end

    belongs_to :permission, MishkaCmsCore.Accounts.Permission do
      description "The permission being granted to the team"
      domain MishkaCmsCore.Accounts
      primary_key? true
      allow_nil? false
      attribute_public? true
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
    identity :unique_team_permission, [:team_id, :permission_id] do
      description "Ensures each team-permission pair is unique"
    end
  end
end
